import Foundation

/// Full context translated by the Interpretation pillar.
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

/// Summary of the body's response during the warm-up (FR-I04).
public struct WarmUpSummary: Codable, Sendable, Equatable {
    public var startHR: Double?
    public var endHR: Double?
    public var duration: TimeInterval
    /// Time from the start of the warm-up until HR first enters the ready zone.
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

/// Deterministic text (no AI) — used as the instant default and as the fallback when Apple Intelligence
/// is unavailable, fails, or its output is rejected by the guardrail.
public enum TemplateCoach {
    public static func unreadyMessage(_ ctx: CoachContext) -> String {
        let a = ctx.assessment
        var parts: [String] = []
        if let hr = a.heartRate {
            parts.append("Your heart rate is \(Format.bpm(hr)), below the ready zone (\(a.zones.rangeText))")
        } else {
            parts.append("No heart rate reading yet and no sign of a warm-up")
        }
        for adj in ctx.plan.adjustments {
            switch adj {
            case .shortSleep(let h): parts.append("you only slept \(Format.decimal(h)) hours last night")
            case .earlyMorning: parts.append("muscles tend to be stiffer in the morning")
            case .elevatedRestingHR(let d): parts.append("your resting heart rate is \(Int(d.rounded())) bpm higher than usual")
            case .lowHRV(let p): parts.append("your HRV is \(Int(p.rounded()))% below usual")
            }
        }
        let reason = parts.count > 1
            ? parts.dropLast().joined(separator: ", ") + " and " + parts.last!
            : parts[0]
        return "\(reason). Let's do a \(ctx.plan.durationMinutes)-minute warm-up first (\(ctx.plan.exerciseListText)) so your muscles don't cramp."
    }

    public static func stepCue(_ step: WarmUpStep, isFirst: Bool) -> String {
        let lead = isFirst ? "Let's start with" : "Nice work! Now"
        switch step.target {
        case .reps(let n): return "\(lead) \(step.exercise.displayName), \(n) reps. \(step.exercise.instruction)"
        case .duration(let s): return "\(lead) \(step.exercise.displayName) for \(Int(s)) seconds. \(step.exercise.instruction)"
        }
    }

    public static func idleReminder(_ step: WarmUpStep) -> String {
        "Counting paused. Keep going with \(step.exercise.displayName)."
    }

    public static func readyMessage(workout: WorkoutKind, heartRate: Double?, zones: HeartRateZones, afterWarmUp: Bool) -> String {
        let hr = heartRate.map { "Heart rate \(Format.bpm($0))" } ?? "Your body"
        if afterWarmUp {
            return "Warm-up done! \(hr) is in the ready zone. Enjoy your \(workout.displayName.lowercased())!"
        }
        return "\(hr) is in the optimal zone. You're ready for your \(workout.displayName.lowercased())."
    }

    public static func notInZoneMessage(heartRate: Double?, zones: HeartRateZones) -> String {
        let hr = heartRate.map(Format.bpm) ?? "Heart rate"
        return "\(hr) hasn't reached \(Int(zones.lowerBound.rounded())) bpm yet. Add 1 more minute of marching in place, or start now."
    }

    public static func summary(_ s: WarmUpSummary) -> String {
        if s.skipped { return "Warm-up skipped." }
        var text = "\(Int((s.duration / 60).rounded()))-minute warm-up"
        if let start = s.startHR, let end = s.endHR {
            text += ": HR rose from \(Int(start.rounded())) to \(Int(end.rounded())) bpm"
        }
        if let t = s.timeToZone {
            text += ", reached the ready zone in \(Int((t / 60).rounded(.up))) min"
        } else {
            text += ", didn't reach the ready zone"
        }
        return text + "."
    }
}

/// NFR-04: language guardrail — AI output must be educational/preventive, never a medical claim.
public enum SafetyGuardrail {
    public static let disallowedTerms = [
        "diagnos", "disease", "arrhythmia", "heart attack", "heart failure", "coronary",
        "hypertension", "diabetes", "medication", "medicine", "prescription", "dosage", "therapy",
        "medical emergency", "disorder", "syndrome", "stroke",
    ]

    public static let instructions = """
    You are a fitness coach on Apple Watch. Write in casual, short, encouraging English. \
    Focus on injury-prevention education (cold muscles, cramps, sudden heart rate spikes). \
    NEVER give a medical diagnosis, name diseases or clinical conditions, or suggest medication. \
    Don't invent numbers; use only the numbers you are given.
    """

    /// Returns the trimmed text, or `nil` when it must be replaced by the template.
    public static func validate(_ text: String, maxLength: Int = 280) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        let lower = trimmed.lowercased()
        guard !disallowedTerms.contains(where: lower.contains) else { return nil }
        return trimmed
    }
}
