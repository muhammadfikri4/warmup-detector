import Foundation

/// Workout types the user can pick before tapping Start Workout.
public enum WorkoutKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case outdoorRun
    case indoorRun
    case hiit
    case strength
    case racket
    case cycling

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .outdoorRun: "Outdoor Run"
        case .indoorRun: "Indoor Run"
        case .hiit: "HIIT"
        case .strength: "Strength Training"
        case .racket: "Racket Sports"
        case .cycling: "Cycling"
        }
    }

    public var symbolName: String {
        switch self {
        case .outdoorRun: "figure.run"
        case .indoorRun: "figure.run.treadmill"
        case .hiit: "figure.highintensity.intervaltraining"
        case .strength: "figure.strengthtraining.traditional"
        case .racket: "figure.badminton"
        case .cycling: "figure.outdoor.cycle"
        }
    }
}

/// Supported warm-up exercises (FR-P03).
public enum Exercise: String, CaseIterable, Codable, Sendable {
    case armCircles
    case marchInPlace
    case torsoTwist

    public var displayName: String {
        switch self {
        case .armCircles: "Arm Circles"
        case .marchInPlace: "March in Place"
        case .torsoTwist: "Torso Twist"
        }
    }

    public var instruction: String {
        switch self {
        case .armCircles: "Keep your arms straight and swing them in big circles."
        case .marchInPlace: "March in place, lift your knees to hip height and swing your arms."
        case .torsoTwist: "Bend your elbows and twist your torso left, then right."
        }
    }

    /// Estimated duration of one rep, used by the planner to turn a duration into a rep target.
    /// `nil` means this exercise is measured by active duration, not reps.
    public var secondsPerRep: Double? {
        switch self {
        case .armCircles: 2.0
        case .marchInPlace: nil
        case .torsoTwist: 2.5
        }
    }
}

/// Output labels of the motion classification model.
public enum MotionLabel: String, Codable, Sendable, CaseIterable {
    case armCircles
    case marchInPlace
    case torsoTwist
    case idle
    case other

    public init(exercise: Exercise) {
        switch exercise {
        case .armCircles: self = .armCircles
        case .marchInPlace: self = .marchInPlace
        case .torsoTwist: self = .torsoTwist
        }
    }

    /// Accepts label spelling variants from CreateML training data
    /// (e.g. `arm_circles`, `High Knees`, `torso-twist`, `random`).
    public init(classLabel: String) {
        let key = classLabel.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "armcircles", "armcircle": self = .armCircles
        case "marchinplace", "march", "highknees", "highknee": self = .marchInPlace
        case "torsotwist", "torsotwists", "twist": self = .torsoTwist
        case "idle", "diam", "rest": self = .idle
        default: self = .other
        }
    }

    public var exercise: Exercise? {
        switch self {
        case .armCircles: .armCircles
        case .marchInPlace: .marchInPlace
        case .torsoTwist: .torsoTwist
        case .idle, .other: nil
        }
    }
}

public enum ExerciseTarget: Codable, Sendable, Equatable {
    case reps(Int)
    case duration(TimeInterval)

    public var value: Double {
        switch self {
        case .reps(let n): Double(n)
        case .duration(let s): s
        }
    }
}

public struct WarmUpStep: Codable, Sendable, Equatable {
    public var exercise: Exercise
    public var target: ExerciseTarget

    public init(exercise: Exercise, target: ExerciseTarget) {
        self.exercise = exercise
        self.target = target
    }
}

public struct HeartRateSample: Codable, Sendable, Equatable {
    public var date: Date
    public var bpm: Double

    public init(date: Date, bpm: Double) {
        self.date = date
        self.bpm = bpm
    }
}

/// Personal calibration parameters (FR-S04). Defaults are used when HealthKit has no data.
public struct UserPhysiology: Codable, Sendable, Equatable {
    public var age: Int
    public var restingHR: Double
    public var ageIsEstimated: Bool
    public var restingHRIsEstimated: Bool

    public init(age: Int?, restingHR: Double?) {
        self.age = age ?? 30
        self.restingHR = restingHR ?? 65
        self.ageIsEstimated = age == nil
        self.restingHRIsEstimated = restingHR == nil
    }
}

/// Recovery data read from HealthKit to calibrate the target (FR-I01).
public struct RecoveryContext: Codable, Sendable, Equatable {
    public var workout: WorkoutKind
    public var physiology: UserPhysiology
    /// Last night's sleep duration (hours), `nil` when there is no data.
    public var sleepHours: Double?
    /// 30-day average RHR, used to detect a morning RHR that is higher than usual.
    public var restingHRBaseline: Double?
    /// Local hour (0–23) when Start was tapped.
    public var startHour: Int
    /// Latest HRV (SDNN, ms) from HealthKit, and the 30-day average as a personal baseline.
    public var hrvSDNN: Double?
    public var hrvBaseline: Double?

    public init(workout: WorkoutKind, physiology: UserPhysiology, sleepHours: Double?, restingHRBaseline: Double?,
                startHour: Int, hrvSDNN: Double? = nil, hrvBaseline: Double? = nil) {
        self.workout = workout
        self.physiology = physiology
        self.sleepHours = sleepHours
        self.restingHRBaseline = restingHRBaseline
        self.startHour = startHour
        self.hrvSDNN = hrvSDNN
        self.hrvBaseline = hrvBaseline
    }
}

enum Format {
    /// Decimal number with a fixed number of digits: 5.25 → "5.3".
    static func decimal(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }

    static func bpm(_ value: Double) -> String { "\(Int(value.rounded())) bpm" }
}
