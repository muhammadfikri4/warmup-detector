import Foundation

public enum PlanAdjustment: Codable, Sendable, Equatable {
    case shortSleep(hours: Double)
    case earlyMorning(hour: Int)
    case elevatedRestingHR(delta: Double)
    /// HRV hari ini sekian persen di bawah baseline pribadi (tanda pemulihan belum optimal).
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
}

/// Planner deterministik. Dipakai langsung sebagai fallback, dan sebagai validator/penghitung target
/// untuk saran Apple Intelligence (AI hanya memilih urutan gerakan & durasi; angka target dihitung di sini).
public struct WarmUpPlanner: Sendable {
    public static let baseMinutes = 3
    public static let extendedMinutes = 5
    public static let allowedMinutes = 3...5

    public var shortSleepHours: Double = 6
    public var earlyMorningBeforeHour = 9
    public var elevatedRHRDelta: Double = 5
    /// HRV dianggap rendah bila ≥ 20% di bawah baseline pribadi.
    public var lowHRVFraction: Double = 0.2

    public init() {}

    /// FR-I01: kalibrasi durasi dari data pemulihan.
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

    /// FR-I03 (versi rule-based): gerakan yang paling relevan dengan olahraga tujuan.
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

    /// Membuat rencana dari daftar gerakan & durasi (misal hasil AI) dengan guardrail:
    /// 2–3 gerakan unik, durasi 3–5 menit.
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

    /// Satu gerakan tambahan bila HR belum masuk zona setelah pemanasan selesai.
    public func extraMinute() -> WarmUpPlan {
        WarmUpPlan(steps: [WarmUpStep(exercise: .marchInPlace, target: .duration(60))], durationMinutes: 1, adjustments: [])
    }
}
