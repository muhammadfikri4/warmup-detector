import Foundation

public enum ReadinessStatus: String, Codable, Sendable {
    case ready
    case notWarmedUp
}

public enum ReadinessReason: Codable, Sendable, Equatable {
    case inTargetZone
    case aboveTargetZone
    /// HR stayed above the warm threshold for this many minutes within the last 10 minutes.
    case sustainedElevation(minutes: Double)
    /// Gradual HR rise trend (bpm/minute) within the last 10 minutes.
    case gradualRise(bpmPerMinute: Double)
    /// Enough activity (Active Energy) within the last 10 minutes.
    case recentActivity(kcal: Double)
    case belowTargetZone
    case noRecentHeartRate
}

public struct ReadinessInput: Sendable {
    /// Live HR from HKLiveWorkoutBuilder (when available).
    public var currentHR: HeartRateSample?
    /// HR history for the 10 minutes before Start.
    public var history: [HeartRateSample]
    /// Active Energy (kcal) for the 10 minutes before Start.
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
    /// HR data cleaning result (removed samples, gaps) — so the decision can be audited.
    public var hrQuality: HeartRateQuality
}

/// Pilar 2 — Pre-Workout Readiness Prediction (FR-P01) & Final Readiness Confirmation (FR-P06).
///
/// Rule: the user is **Not ready** if the current HR is below the lower bound of Zone 1–2
/// AND there is no prior sign of a gradual rise. Sign of a gradual rise =
/// current HR ≥ warm threshold and one of: ≥ 3 minutes above the threshold,
/// a rising trend ≥ 1.5 bpm/minute, or Active Energy ≥ 20 kcal within the last 10 minutes.
public struct ReadinessEngine: Sendable {
    public var lookback: TimeInterval = 10 * 60
    public var minimumSustainedMinutes: Double = 3
    public var minimumRiseBpmPerMinute: Double = 1.5
    public var minimumActiveEnergy: Double = 20
    /// An HR sample counts as "current" when its age is ≤ this value.
    public var currentSampleMaxAge: TimeInterval = 120
    /// One HealthKit sample represents at most this duration (background samples are sparse).
    public var sampleHoldCap: TimeInterval = 150
    public var cleaner = HeartRateCleaner()

    public init() {}

    public func evaluate(_ input: ReadinessInput) -> ReadinessAssessment {
        let windowStart = input.now.addingTimeInterval(-lookback)
        var raw = input.history.filter { $0.date >= windowStart && $0.date <= input.now }
        if let live = input.currentHR { raw.append(live) }
        let (samples, quality) = cleaner.clean(raw, until: input.now)

        // A live HR discarded by the cleaner (outside the physiological range) is not used.
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

    /// FR-P06: re-validate after the exercise sequence is finished.
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

    /// Linear regression slope of HR (bpm/minute). Needs ≥ 3 samples spanning ≥ 2 minutes.
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
