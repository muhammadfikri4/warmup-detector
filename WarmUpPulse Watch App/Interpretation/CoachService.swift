import Foundation
import FoundationModels
import WarmUpCore

/// Pillar 3 — Interpretation (FR-I01 … FR-I04).
///
/// Platform note: on watchOS 27, the on-device `SystemLanguageModel` is NOT available; what is available is
/// `PrivateCloudComputeLanguageModel` (Apple Private Cloud Compute — Apple servers, not a third party).
/// Therefore:
/// 1. Deterministic template text always shows first (instant, offline).
/// 2. If the user allows it and it's available, Apple Intelligence refines the text/plan in the background.
/// 3. Only derived numbers are sent (HR, RHR, sleep hours, workout type, hour) — no identity.
/// 4. All AI output goes through `SafetyGuardrail` + `WarmUpPlanner` (NFR-04); on failure → keep the template.
final class CoachService {
    struct PlanSuggestion: Sendable {
        var message: String
        var plan: WarmUpPlan
        var cues: [String]
    }

    var isEnabled: Bool { AppSettings.useAppleIntelligence }

    var availabilityText: String {
        switch PrivateCloudComputeLanguageModel().availability {
        case .available: "Available"
        case .unavailable(.deviceNotEligible): "Device not supported"
        case .unavailable(.systemNotReady): "Not ready yet"
        case .unavailable: "Unavailable"
        }
    }

    private var canUseAI: Bool { isEnabled && PrivateCloudComputeLanguageModel().isAvailable }

    /// FR-I01 + FR-I02 + FR-I03: explanation, duration, exercise order, and voice cues.
    func suggestPlan(for context: CoachContext, timeout: TimeInterval = 8) async -> PlanSuggestion? {
        guard canUseAI else { return nil }
        let prompt = Self.planPrompt(context)
        let generated = await withTimeout(timeout) {
            let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(),
                                               instructions: SafetyGuardrail.instructions)
            return try await session.respond(to: prompt, generating: AIWarmUpPlan.self).content
        }
        guard let generated, let message = SafetyGuardrail.validate(generated.explanation) else { return nil }

        let plan = WarmUpPlanner().plan(exercises: generated.exercises.map(\.exercise),
                                        durationMinutes: generated.durationMinutes,
                                        adjustments: context.plan.adjustments)
        let cues = generated.cues.compactMap { SafetyGuardrail.validate($0, maxLength: 140) }
        return PlanSuggestion(message: message, plan: plan, cues: cues.count == plan.steps.count ? cues : [])
    }

    /// FR-I04: short note for workout history.
    func summaryNote(_ summary: WarmUpSummary, workout: WorkoutKind) async -> String {
        let fallback = TemplateCoach.summary(summary)
        guard canUseAI, !summary.skipped else { return fallback }
        let prompt = """
        In English, summarize the body's response during the warm-up before \(workout.displayName) in 1 short, \
        casual, encouraging sentence (max 160 characters).
        Data: \(fallback)
        HR rise rate: \(summary.riseBpmPerMinute.map { String(format: "%.1f bpm/min", $0) } ?? "unknown").
        """
        let text = await withTimeout(8) {
            let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(),
                                               instructions: SafetyGuardrail.instructions)
            return try await session.respond(to: prompt).content
        }
        return text.flatMap { SafetyGuardrail.validate($0, maxLength: 200) } ?? fallback
    }

    private static func planPrompt(_ ctx: CoachContext) -> String {
        let r = ctx.recovery
        let a = ctx.assessment
        return """
        The user is about to do \(r.workout.displayName) at \(r.startHour):00 and hasn't warmed up yet.
        Current HR: \(a.heartRate.map { "\(Int($0)) bpm" } ?? "not read yet"); ready zone: \(a.zones.rangeText).
        Resting HR this morning: \(Int(r.physiology.restingHR)) bpm\(r.restingHRBaseline.map { " (30-day average \(Int($0)) bpm)" } ?? "").
        Sleep last night: \(r.sleepHours.map { String(format: "%.1f h", $0) } ?? "no data").
        HRV (SDNN): \(r.hrvSDNN.map { "\(Int($0)) ms" } ?? "no data")\(r.hrvBaseline.map { " (30-day average \(Int($0)) ms)" } ?? "").
        Base plan: \(ctx.plan.durationMinutes) min, \(ctx.plan.exerciseListText).
        Adjustments from recovery data: \(ctx.plan.adjustments.isEmpty ? "none" : String(describing: ctx.plan.adjustments)).
        Pick the 2–3 exercises most relevant to this workout (focus on Arm Circles & Torso Twist for racket/strength, \
        March in Place for running/cycling), set a duration of 3–5 minutes (longer after poor sleep or in the morning), \
        write a friendly explanation of max 2 sentences, and one short voice cue per exercise.
        Write everything in English: casual, short, and encouraging.
        """
    }
}

@Generable
struct AIWarmUpPlan {
    @Guide(description: "A friendly, casual, encouraging explanation in English (max 2 short sentences) of why a warm-up is needed, mentioning the given HR numbers.")
    var explanation: String

    @Guide(description: "Warm-up duration in minutes.", .range(3...5))
    var durationMinutes: Int

    @Guide(description: "Order of warm-up exercises.", .minimumCount(2), .maximumCount(3))
    var exercises: [AIExercise]

    @Guide(description: "One short, upbeat English voice cue (max 12 words) per exercise, in the same order as exercises.")
    var cues: [String]
}

@Generable
enum AIExercise {
    case armCircles
    case marchInPlace
    case torsoTwist

    var exercise: Exercise {
        switch self {
        case .armCircles: .armCircles
        case .marchInPlace: .marchInPlace
        case .torsoTwist: .torsoTwist
        }
    }
}

/// Runs an async operation with a time limit; `nil` on timeout or error.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
