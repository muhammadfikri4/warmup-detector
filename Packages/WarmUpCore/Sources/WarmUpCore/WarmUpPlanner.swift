import Foundation

public enum PlanAdjustment: Codable, Sendable, Equatable {
    case shortSleep(hours: Double)
    case earlyMorning(hour: Int)
    case elevatedRestingHR(delta: Double)
    /// Today's HRV is this many percent below the personal baseline (a sign of incomplete recovery).
    case lowHRV(percentBelow: Double)
}

public struct WarmUpPlan: Codable, Sendable, Equatable {
    public var steps: [WarmUpStep]
    public var durationMinutes: Int
    public var adjustments: [PlanAdjustment]

    public init(steps: [WarmUpStep], durationMinutes: Int, adjustments: [PlanAdjustment]) {
        self.steps = steps
        self.durationMinutes = durationMinutes
        self.adjustments = adjustments
    }

    public var exerciseListText: String { steps.map(\.exercise.displayName).joined(separator: " + ") }

    /// Replaces automatic targets with the ones set on the iPhone. The plan length follows the new targets.
    public func applying(_ targets: MoveTargets) -> WarmUpPlan {
        guard !targets.isAutomatic else { return self }
        let newSteps = steps.map { step in
            targets.target(for: step.exercise).map { WarmUpStep(exercise: step.exercise, target: $0) } ?? step
        }
        let seconds = newSteps.reduce(0) { $0 + $1.estimatedSeconds }
        return WarmUpPlan(steps: newSteps, durationMinutes: max(1, Int((seconds / 60).rounded(.up))), adjustments: adjustments)
    }
}

/// Per-move targets set on the iPhone. `nil` = automatic (sized from the 3–5 minute plan).
public struct MoveTargets: Codable, Sendable, Equatable {
    public var armCirclesReps: Int?
    public var torsoTwistReps: Int?
    public var marchInPlaceSeconds: Int?

    public init(armCirclesReps: Int? = nil, torsoTwistReps: Int? = nil, marchInPlaceSeconds: Int? = nil) {
        self.armCirclesReps = armCirclesReps
        self.torsoTwistReps = torsoTwistReps
        self.marchInPlaceSeconds = marchInPlaceSeconds
    }

    public var isAutomatic: Bool { armCirclesReps == nil && torsoTwistReps == nil && marchInPlaceSeconds == nil }

    public func target(for exercise: Exercise) -> ExerciseTarget? {
        switch exercise {
        case .armCircles: armCirclesReps.map { .reps($0) }
        case .torsoTwist: torsoTwistReps.map { .reps($0) }
        case .marchInPlace: marchInPlaceSeconds.map { .duration(TimeInterval($0)) }
        }
    }

    /// Choices offered on the iPhone.
    public static let repChoices = [5, 10, 15, 20, 25, 30, 40, 50]
    public static let secondChoices = [30, 45, 60, 90, 120, 180]
}

extension WarmUpStep {
    /// Rough time a step takes, used to show the plan length.
    public var estimatedSeconds: Double {
        switch target {
        case .reps(let n): Double(n) * (exercise.secondsPerRep ?? 2)
        case .duration(let s): s
        }
    }
}

/// Deterministic planner. Used directly as the fallback, and as the validator/target calculator
/// for Apple Intelligence suggestions (the AI only picks exercise order & duration; target numbers are computed here).
public struct WarmUpPlanner: Sendable {
    public static let baseMinutes = 3
    public static let extendedMinutes = 5
    public static let allowedMinutes = 3...5

    public var shortSleepHours: Double = 6
    public var earlyMorningBeforeHour = 9
    public var elevatedRHRDelta: Double = 5
    /// HRV counts as low when it is ≥ 20% below the personal baseline.
    public var lowHRVFraction: Double = 0.2

    public init() {}

    /// FR-I01: calibrate duration from recovery data.
    public func adjustments(for context: RecoveryContext) -> [PlanAdjustment] {
        var result: [PlanAdjustment] = []
        if let sleep = context.sleepHours, sleep < shortSleepHours { result.append(.shortSleep(hours: sleep)) }
        if (4..<earlyMorningBeforeHour).contains(context.startHour) { result.append(.earlyMorning(hour: context.startHour)) }
        if let baseline = context.restingHRBaseline, !context.physiology.restingHRIsEstimated {
            let delta = context.physiology.restingHR - baseline
            if delta >= elevatedRHRDelta { result.append(.elevatedRestingHR(delta: delta)) }
        }
        if let hrv = context.hrvSDNN, let baseline = context.hrvBaseline, baseline > 0 {
            let below = (baseline - hrv) / baseline
            if below >= lowHRVFraction { result.append(.lowHRV(percentBelow: below * 100)) }
        }
        return result
    }

    /// FR-I03 (rule-based version): the exercises most relevant to the target workout.
    public static func recommendedExercises(for workout: WorkoutKind, extended: Bool) -> [Exercise] {
        switch workout {
        case .outdoorRun, .indoorRun, .cycling:
            extended ? [.marchInPlace, .armCircles, .torsoTwist] : [.marchInPlace, .armCircles]
        case .racket, .strength:
            extended ? [.armCircles, .torsoTwist, .marchInPlace] : [.armCircles, .torsoTwist]
        case .hiit:
            [.marchInPlace, .armCircles, .torsoTwist]
        }
    }

    public func plan(for context: RecoveryContext) -> WarmUpPlan {
        let adjustments = adjustments(for: context)
        let minutes = adjustments.isEmpty ? Self.baseMinutes : Self.extendedMinutes
        let exercises = Self.recommendedExercises(for: context.workout, extended: minutes > Self.baseMinutes)
        return plan(exercises: exercises, durationMinutes: minutes, adjustments: adjustments)
    }

    /// Builds a plan from a list of exercises & a duration (e.g. AI output) with guardrails:
    /// 2–3 unique exercises, 3–5 minutes long.
    public func plan(exercises: [Exercise], durationMinutes: Int, adjustments: [PlanAdjustment]) -> WarmUpPlan {
        var unique: [Exercise] = []
        for e in exercises where !unique.contains(e) { unique.append(e) }
        if unique.count < 2 {
            for e in [Exercise.marchInPlace, .armCircles] where !unique.contains(e) && unique.count < 2 { unique.append(e) }
        }
        unique = Array(unique.prefix(3))
        let minutes = min(max(durationMinutes, Self.allowedMinutes.lowerBound), Self.allowedMinutes.upperBound)

        let weight: (Exercise) -> Double = { $0 == .marchInPlace ? 1.5 : 1.0 }
        let totalWeight = unique.map(weight).reduce(0, +)
        let budget = Double(minutes * 60)

        let steps = unique.map { exercise -> WarmUpStep in
            let seconds = budget * weight(exercise) / totalWeight
            if let perRep = exercise.secondsPerRep {
                let reps = max(10, Int((seconds / perRep / 5).rounded()) * 5)
                return WarmUpStep(exercise: exercise, target: .reps(reps))
            }
            return WarmUpStep(exercise: exercise, target: .duration(max(30, (seconds / 5).rounded() * 5)))
        }
        return WarmUpPlan(steps: steps, durationMinutes: minutes, adjustments: adjustments)
    }

    /// One extra exercise when HR hasn't entered the zone after the warm-up is done.
    public func extraMinute() -> WarmUpPlan {
        WarmUpPlan(steps: [WarmUpStep(exercise: .marchInPlace, target: .duration(60))], durationMinutes: 1, adjustments: [])
    }
}
