import Foundation

// Pipeline tahap 1 (Collect) — identitas samaran, consent, dan log sesi untuk evaluasi.

public enum Wrist: String, Codable, Sendable, CaseIterable {
    case left = "L"
    case right = "R"

    public var displayName: String { self == .left ? "Kiri" : "Kanan" }
}

/// Kode partisipan samaran (P01…P30). Nama asli TIDAK pernah disimpan di jam maupun di data.
public enum Participant {
    public static let codes = (1...30).map { String(format: "P%02d", $0) }

    public static func isValid(_ code: String) -> Bool {
        code.count == 3 && code.hasPrefix("P") && Int(code.dropFirst()) != nil
    }
}

/// Konvensi nama berkas rekaman: `<label>_<partisipan>_<pergelangan>_<epoch>.csv`,
/// mis. `armCircles_P03_L_1731550000.csv`. Format lama `<label>_<epoch>.csv` tetap terbaca (tanpa partisipan).
public struct RecordingName: Sendable, Equatable {
    public var label: String
    public var participant: String?
    public var wrist: Wrist?
    public var id: String

    public init(label: String, participant: String?, wrist: Wrist?, id: String) {
        self.label = label
        self.participant = participant
        self.wrist = wrist
        self.id = id
    }

    public var session: String {
        [label, participant, wrist?.rawValue, id].compactMap { $0 }.joined(separator: "_")
    }

    public init?(fileName: String) {
        let base = fileName.hasSuffix(".csv") ? String(fileName.dropLast(4)) : fileName
        let parts = base.split(separator: "_").map(String.init)
        guard parts.count >= 2, let label = parts.first else { return nil }
        if parts.count >= 4, Participant.isValid(parts[1]), let wrist = Wrist(rawValue: parts[2]) {
            self.init(label: label, participant: parts[1], wrist: wrist, id: parts[3...].joined(separator: "_"))
        } else {
            self.init(label: label, participant: nil, wrist: nil, id: parts[1...].joined(separator: "_"))
        }
    }
}

/// Format CSV data latih — satu sumber kebenaran untuk perekam (jam) dan script training (Mac).
public enum MotionCSV {
    public static let header = "session,participant,wrist,timestamp,acc_x,acc_y,acc_z,rot_x,rot_y,rot_z,grav_x,grav_y,grav_z,label"

    public static func row(_ f: MotionFrame, name: RecordingName) -> String {
        let values = [f.userAcceleration.x, f.userAcceleration.y, f.userAcceleration.z,
                      f.rotationRate.x, f.rotationRate.y, f.rotationRate.z,
                      f.gravity.x, f.gravity.y, f.gravity.z].map { String(format: "%.5f", $0) }
        return ([name.session, name.participant ?? "", name.wrist?.rawValue ?? "", String(format: "%.3f", f.timestamp)]
                + values + [name.label]).joined(separator: ",")
    }

    public static func encode(_ frames: [MotionFrame], name: RecordingName) -> String {
        ([header] + frames.map { row($0, name: name) }).joined(separator: "\n") + "\n"
    }

    /// Membaca CSV berdasarkan nama kolom (urutan bebas; format lama tanpa participant/wrist juga didukung).
    public static func decode(_ text: String) -> [MotionFrame] {
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard let headerLine = lines.next() else { return [] }
        let columns = headerLine.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        func index(_ name: String) -> Int? { columns.firstIndex(of: name) }
        guard let t = index("timestamp") else { return [] }
        let names = ["acc_x", "acc_y", "acc_z", "rot_x", "rot_y", "rot_z", "grav_x", "grav_y", "grav_z"]
        let idx = names.map(index)

        var frames: [MotionFrame] = []
        while let line = lines.next() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            func value(_ i: Int?) -> Double { i.flatMap { $0 < fields.count ? Double(fields[$0]) : nil } ?? .nan }
            let v = idx.map(value)
            frames.append(MotionFrame(timestamp: value(t),
                                      userAcceleration: Vector3(v[0], v[1], v[2]),
                                      rotationRate: Vector3(v[3], v[4], v[5]),
                                      gravity: idx[6] == nil ? Vector3(0, 0, -1) : Vector3(v[6], v[7], v[8])))
        }
        return frames
    }
}

/// Referensi kebenaran untuk evaluasi kesiapan, ditentukan peneliti SEBELUM sesi (skenario terkontrol PRD §5).
public enum ReferenceScenario: String, Codable, Sendable, CaseIterable {
    case unknown
    /// Duduk diam ≥ 5 menit sebelum Start → seharusnya "Belum Pemanasan".
    case cold
    /// Jalan cepat ≥ 6 menit sebelum Start → seharusnya "Siap".
    case warm

    public var displayName: String {
        switch self {
        case .unknown: "Tidak diketahui"
        case .cold: "Dingin (duduk 5 mnt)"
        case .warm: "Hangat (jalan cepat 6 mnt)"
        }
    }

    public var expectedStatus: ReadinessStatus? {
        switch self {
        case .unknown: nil
        case .cold: .notWarmedUp
        case .warm: .ready
        }
    }
}

public enum WarmUpOutcome: String, Codable, Sendable {
    /// Sudah siap saat Start, tidak perlu pemanasan.
    case notNeeded
    case skipped
    case completed
    /// Sesi dibatalkan sebelum selesai.
    case abandoned
}

public struct StepLog: Codable, Sendable, Equatable {
    public var exercise: Exercise
    public var target: ExerciseTarget
    /// Repetisi atau detik aktif yang dihitung aplikasi.
    public var counted: Double
    public var completed: Bool
    /// Hitungan manual peneliti (referensi), hanya untuk gerakan berbasis repetisi.
    public var referenceReps: Int?

    public init(exercise: Exercise, target: ExerciseTarget, counted: Double, completed: Bool, referenceReps: Int? = nil) {
        self.exercise = exercise
        self.target = target
        self.counted = counted
        self.completed = completed
        self.referenceReps = referenceReps
    }
}

/// Satu baris log evaluasi (JSON Lines). Hanya ditulis saat Mode Studi aktif.
public struct SessionLogEntry: Codable, Sendable, Equatable {
    public var id: UUID
    public var date: Date
    public var participant: String?
    public var wrist: Wrist?
    public var scenario: ReferenceScenario
    public var workout: WorkoutKind
    public var predicted: ReadinessStatus
    public var heartRate: Double?
    public var zoneLower: Double
    public var zoneUpper: Double
    public var reasons: [ReadinessReason]
    public var checkLatency: TimeInterval
    public var hrQuality: HeartRateQuality
    public var classifier: String
    public var warmUp: WarmUpOutcome
    public var finalConfirmed: Bool?
    public var steps: [StepLog]

    public init(id: UUID = UUID(), date: Date, participant: String?, wrist: Wrist?, scenario: ReferenceScenario,
                workout: WorkoutKind, assessment: ReadinessAssessment, checkLatency: TimeInterval, classifier: String,
                warmUp: WarmUpOutcome, finalConfirmed: Bool?, steps: [StepLog]) {
        self.id = id
        self.date = date
        self.participant = participant
        self.wrist = wrist
        self.scenario = scenario
        self.workout = workout
        self.predicted = assessment.status
        self.heartRate = assessment.heartRate
        self.zoneLower = assessment.zones.lowerBound
        self.zoneUpper = assessment.zones.upperBound
        self.reasons = assessment.reasons
        self.checkLatency = checkLatency
        self.hrQuality = assessment.hrQuality
        self.classifier = classifier
        self.warmUp = warmUp
        self.finalConfirmed = finalConfirmed
        self.steps = steps
    }

    public static func decodeLines(_ text: String) -> (entries: [SessionLogEntry], invalidLines: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [SessionLogEntry] = []
        var invalid = 0
        for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if let e = try? decoder.decode(SessionLogEntry.self, from: Data(line.utf8)) { entries.append(e) } else { invalid += 1 }
        }
        return (entries, invalid)
    }

    public func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
