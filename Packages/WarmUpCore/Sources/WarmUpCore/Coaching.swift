import Foundation

/// Konteks lengkap yang diterjemahkan pilar Interpretation.
public struct CoachContext: Sendable, Equatable {
    public var recovery: RecoveryContext
    public var assessment: ReadinessAssessment
    public var plan: WarmUpPlan

    public init(recovery: RecoveryContext, assessment: ReadinessAssessment, plan: WarmUpPlan) {
        self.recovery = recovery
        self.assessment = assessment
        self.plan = plan
    }
}

/// Ringkasan respons tubuh selama pemanasan (FR-I04).
public struct WarmUpSummary: Codable, Sendable, Equatable {
    public var startHR: Double?
    public var endHR: Double?
    public var duration: TimeInterval
    /// Waktu sejak mulai pemanasan sampai HR pertama kali masuk zona siap.
    public var timeToZone: TimeInterval?
    public var riseBpmPerMinute: Double?
    public var skipped: Bool

    public init(samples: [HeartRateSample], start: Date, end: Date, zoneLowerBound: Double, skipped: Bool = false) {
        let window = samples.filter { $0.date >= start && $0.date <= end }.sorted { $0.date < $1.date }
        self.startHR = window.first?.bpm
        self.endHR = window.last?.bpm
        self.duration = end.timeIntervalSince(start)
        self.timeToZone = window.first { $0.bpm >= zoneLowerBound }.map { $0.date.timeIntervalSince(start) }
        self.riseBpmPerMinute = ReadinessEngine.trend(window)
        self.skipped = skipped
    }
}

/// Teks deterministik (tanpa AI) — dipakai sebagai default instan dan fallback bila Apple Intelligence
/// tidak tersedia, gagal, atau keluarannya ditolak guardrail.
public enum TemplateCoach {
    public static func unreadyMessage(_ ctx: CoachContext) -> String {
        let a = ctx.assessment
        var parts: [String] = []
        if let hr = a.heartRate {
            parts.append("Detak jantungmu masih \(Format.bpm(hr)), di bawah zona siap (\(a.zones.rangeText))")
        } else {
            parts.append("Detak jantungmu belum terbaca dan belum ada tanda pemanasan")
        }
        for adj in ctx.plan.adjustments {
            switch adj {
            case .shortSleep(let h): parts.append("semalam tidurmu hanya \(Format.decimal(h)) jam")
            case .earlyMorning: parts.append("otot cenderung lebih kaku di pagi hari")
            case .elevatedRestingHR(let d): parts.append("detak istirahatmu \(Int(d.rounded())) bpm lebih tinggi dari biasanya")
            case .lowHRV(let p): parts.append("HRV-mu \(Int(p.rounded()))% di bawah biasanya")
            }
        }
        let reason = parts.count > 1
            ? parts.dropLast().joined(separator: ", ") + " dan " + parts.last!
            : parts[0]
        return "\(reason)—yuk pemanasan \(ctx.plan.durationMinutes) menit dulu (\(ctx.plan.exerciseListText)) agar otot tidak kram."
    }

    public static func stepCue(_ step: WarmUpStep, isFirst: Bool) -> String {
        let lead = isFirst ? "Ayo mulai" : "Bagus! Sekarang"
        switch step.target {
        case .reps(let n): return "\(lead) \(step.exercise.displayName), \(n) kali. \(step.exercise.instruction)"
        case .duration(let s): return "\(lead) \(step.exercise.displayName) selama \(Int(s)) detik. \(step.exercise.instruction)"
        }
    }

    public static func idleReminder(_ step: WarmUpStep) -> String {
        "Hitungan dijeda. Lanjutkan \(step.exercise.displayName) ya."
    }

    public static func readyMessage(workout: WorkoutKind, heartRate: Double?, zones: HeartRateZones, afterWarmUp: Bool) -> String {
        let hr = heartRate.map { "Detak jantung \(Format.bpm($0))" } ?? "Tubuhmu"
        if afterWarmUp {
            return "Pemanasan selesai! \(hr) sudah di zona siap. Selamat \(workout.displayName.lowercased())!"
        }
        return "\(hr) sudah di zona optimal—tubuhmu siap untuk \(workout.displayName.lowercased())."
    }

    public static func notInZoneMessage(heartRate: Double?, zones: HeartRateZones) -> String {
        let hr = heartRate.map(Format.bpm) ?? "Detak jantung"
        return "\(hr) belum mencapai \(Int(zones.lowerBound.rounded())) bpm. Tambah 1 menit jalan di tempat atau mulai sekarang."
    }

    public static func summary(_ s: WarmUpSummary) -> String {
        if s.skipped { return "Pemanasan dilewati." }
        var text = "Pemanasan \(Int((s.duration / 60).rounded())) menit"
        if let start = s.startHR, let end = s.endHR {
            text += ": HR naik dari \(Int(start.rounded())) ke \(Int(end.rounded())) bpm"
        }
        if let t = s.timeToZone {
            text += ", masuk zona siap dalam \(Int((t / 60).rounded(.up))) menit"
        } else {
            text += ", belum sempat masuk zona siap"
        }
        return text + "."
    }
}

/// NFR-04: guardrail bahasa — keluaran AI harus edukatif/preventif, bukan klaim medis.
public enum SafetyGuardrail {
    public static let disallowedTerms = [
        "diagnos", "penyakit", "aritmia", "serangan jantung", "gagal jantung", "jantung koroner",
        "hipertensi", "diabetes", "obat", "resep", "dosis", "terapi", "darurat medis", "kelainan",
        "gangguan jantung", "sindrom", "stroke",
    ]

    public static let instructions = """
    Kamu adalah pelatih kebugaran di Apple Watch. Tulis dalam Bahasa Indonesia santai, singkat, \
    dan menyemangati. Fokus pada edukasi pencegahan cedera (otot dingin, kram, lonjakan detak jantung). \
    DILARANG membuat diagnosis medis, menyebut penyakit atau kondisi klinis, atau menyarankan obat. \
    Jangan mengarang angka; gunakan hanya angka yang diberikan.
    """

    /// Mengembalikan teks yang sudah dirapikan, atau `nil` bila harus diganti template.
    public static func validate(_ text: String, maxLength: Int = 280) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        let lower = trimmed.lowercased()
        guard !disallowedTerms.contains(where: lower.contains) else { return nil }
        return trimmed
    }
}
