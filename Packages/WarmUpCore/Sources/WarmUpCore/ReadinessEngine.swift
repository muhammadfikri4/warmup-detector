import Foundation

public enum ReadinessStatus: String, Codable, Sendable {
    case ready
    case notWarmedUp
}

public enum ReadinessReason: Codable, Sendable, Equatable {
    case inTargetZone
    case aboveTargetZone
    /// HR bertahan di atas ambang hangat selama sekian menit dalam 10 menit terakhir.
    case sustainedElevation(minutes: Double)
    /// Tren kenaikan HR bertahap (bpm/menit) dalam 10 menit terakhir.
    case gradualRise(bpmPerMinute: Double)
    /// Ada aktivitas (Active Energy) yang cukup dalam 10 menit terakhir.
    case recentActivity(kcal: Double)
    case belowTargetZone
    case noRecentHeartRate
}

public struct ReadinessInput: Sendable {
    /// HR live dari HKLiveWorkoutBuilder (bila sudah tersedia).
    public var currentHR: HeartRateSample?
    /// Riwayat HR 10 menit sebelum Start.
    public var history: [HeartRateSample]
    /// Active Energy (kkal) 10 menit sebelum Start.
    public var recentActiveEnergy: Double?
    public var zones: HeartRateZones
    public var now: Date

    public init(currentHR: HeartRateSample?, history: [HeartRateSample], recentActiveEnergy: Double?, zones: HeartRateZones, now: Date) {
        self.currentHR = currentHR
        self.history = history
        self.recentActiveEnergy = recentActiveEnergy
        self.zones = zones
        self.now = now
    }
}

public struct ReadinessAssessment: Sendable, Equatable {
    public var status: ReadinessStatus
    public var heartRate: Double?
    public var zones: HeartRateZones
    public var reasons: [ReadinessReason]
    public var minutesAboveWarm: Double
    public var trendBpmPerMinute: Double?
    /// Hasil pembersihan data HR (sampel dibuang, celah) — supaya keputusan bisa diaudit.
    public var hrQuality: HeartRateQuality
}

/// Pilar 2 — Pre-Workout Readiness Prediction (FR-P01) & Final Readiness Confirmation (FR-P06).
///
/// Aturan: pengguna **Belum Pemanasan** jika HR saat ini di bawah batas bawah Zona 1–2
/// DAN tidak ada tanda kenaikan bertahap sebelumnya. Tanda kenaikan bertahap =
/// HR saat ini ≥ ambang hangat dan salah satu dari: bertahan ≥ 3 menit di atas ambang,
/// tren naik ≥ 1,5 bpm/menit, atau Active Energy ≥ 20 kkal dalam 10 menit terakhir.
public struct ReadinessEngine: Sendable {
    public var lookback: TimeInterval = 10 * 60
    public var minimumSustainedMinutes: Double = 3
    public var minimumRiseBpmPerMinute: Double = 1.5
    public var minimumActiveEnergy: Double = 20
    /// Sampel HR dianggap "saat ini" bila umurnya ≤ nilai ini.
    public var currentSampleMaxAge: TimeInterval = 120
    /// Satu sampel HealthKit mewakili paling lama durasi ini (sampel latar belakang jarang).
    public var sampleHoldCap: TimeInterval = 150
    public var cleaner = HeartRateCleaner()

    public init() {}

    public func evaluate(_ input: ReadinessInput) -> ReadinessAssessment {
        let windowStart = input.now.addingTimeInterval(-lookback)
        var raw = input.history.filter { $0.date >= windowStart && $0.date <= input.now }
        if let live = input.currentHR { raw.append(live) }
        let (samples, quality) = cleaner.clean(raw, until: input.now)

        // HR live yang dibuang pembersih (di luar rentang fisiologis) tidak dipakai.
        let liveValid = input.currentHR.flatMap { live in samples.contains(live) ? live : nil }
        let current = liveValid ?? samples.last.flatMap {
            input.now.timeIntervalSince($0.date) <= currentSampleMaxAge ? $0 : nil
        }
        let zones = input.zones
        let minutesAbove = minutesAbove(zones.warmBound, in: samples, now: input.now)
        let slope = Self.trend(samples)

        func result(_ status: ReadinessStatus, _ reasons: [ReadinessReason]) -> ReadinessAssessment {
            ReadinessAssessment(status: status, heartRate: current?.bpm, zones: zones, reasons: reasons,
                                minutesAboveWarm: minutesAbove, trendBpmPerMinute: slope, hrQuality: quality)
        }

        guard let hr = current?.bpm else { return result(.notWarmedUp, [.noRecentHeartRate]) }

        if hr > zones.upperBound { return result(.ready, [.aboveTargetZone]) }
        if hr >= zones.lowerBound { return result(.ready, [.inTargetZone]) }

        if hr >= zones.warmBound {
            var reasons: [ReadinessReason] = []
            if minutesAbove >= minimumSustainedMinutes { reasons.append(.sustainedElevation(minutes: minutesAbove)) }
            if let slope, slope >= minimumRiseBpmPerMinute { reasons.append(.gradualRise(bpmPerMinute: slope)) }
            if let kcal = input.recentActiveEnergy, kcal >= minimumActiveEnergy { reasons.append(.recentActivity(kcal: kcal)) }
            if !reasons.isEmpty { return result(.ready, reasons) }
        }
        return result(.notWarmedUp, [.belowTargetZone])
    }

    /// FR-P06: validasi ulang setelah rangkaian gerakan selesai.
    public func confirmAfterWarmUp(heartRate: Double?, zones: HeartRateZones) -> Bool {
        guard let heartRate else { return false }
        return zones.isInReadyZone(heartRate)
    }

    func minutesAbove(_ threshold: Double, in samples: [HeartRateSample], now: Date) -> Double {
        var seconds: TimeInterval = 0
        for (i, sample) in samples.enumerated() where sample.bpm >= threshold {
            let next = i + 1 < samples.count ? samples[i + 1].date : now
            seconds += min(max(0, next.timeIntervalSince(sample.date)), sampleHoldCap)
        }
        return seconds / 60
    }

    /// Kemiringan regresi linear HR (bpm/menit). Butuh ≥ 3 sampel yang membentang ≥ 2 menit.
    static func trend(_ samples: [HeartRateSample]) -> Double? {
        guard samples.count >= 3, let first = samples.first, let last = samples.last,
              last.date.timeIntervalSince(first.date) >= 120 else { return nil }
        let xs = samples.map { $0.date.timeIntervalSince(first.date) / 60 }
        let ys = samples.map(\.bpm)
        let n = Double(samples.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) {
            num += (x - meanX) * (y - meanY)
            den += (x - meanX) * (x - meanX)
        }
        return den > 0 ? num / den : nil
    }
}
