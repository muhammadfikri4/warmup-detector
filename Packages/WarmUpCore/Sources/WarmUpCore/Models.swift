import Foundation

/// Jenis olahraga yang bisa dipilih pengguna sebelum menekan Start Workout.
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
        case .outdoorRun: "Lari Outdoor"
        case .indoorRun: "Lari Indoor"
        case .hiit: "HIIT"
        case .strength: "Latihan Beban"
        case .racket: "Olahraga Raket"
        case .cycling: "Bersepeda"
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

/// Gerakan pemanasan yang didukung (FR-P03).
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
        case .armCircles: "Putar lengan lurus membentuk lingkaran besar."
        case .marchInPlace: "Jalan di tempat, angkat lutut setinggi pinggul dan ayunkan lengan."
        case .torsoTwist: "Tekuk siku, putar badan ke kiri lalu ke kanan."
        }
    }

    /// Perkiraan durasi satu repetisi, dipakai planner untuk mengubah durasi jadi target repetisi.
    /// `nil` berarti gerakan ini diukur dengan durasi aktif, bukan repetisi.
    public var secondsPerRep: Double? {
        switch self {
        case .armCircles: 2.0
        case .marchInPlace: nil
        case .torsoTwist: 2.5
        }
    }
}

/// Label keluaran model klasifikasi gerakan.
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

    /// Menerima variasi penulisan label dari data latih CreateML
    /// (mis. `arm_circles`, `High Knees`, `torso-twist`, `random`).
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

/// Parameter kalibrasi personal (FR-S04). Nilai default dipakai bila data HealthKit kosong.
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

/// Data pemulihan yang dibaca dari HealthKit untuk kalibrasi target (FR-I01).
public struct RecoveryContext: Codable, Sendable, Equatable {
    public var workout: WorkoutKind
    public var physiology: UserPhysiology
    /// Durasi tidur semalam (jam), `nil` bila tidak ada data.
    public var sleepHours: Double?
    /// Rata-rata RHR 30 hari terakhir, untuk mendeteksi RHR pagi yang lebih tinggi dari biasanya.
    public var restingHRBaseline: Double?
    /// Jam lokal (0–23) saat tombol Start ditekan.
    public var startHour: Int
    /// HRV terbaru (SDNN, ms) dari HealthKit, dan rata-rata 30 hari sebagai baseline pribadi.
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
    /// Angka desimal gaya Indonesia: 5.25 → "5,3".
    static func decimal(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    static func bpm(_ value: Double) -> String { "\(Int(value.rounded())) bpm" }
}
