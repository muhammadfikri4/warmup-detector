import Foundation

/// Settings configured on iPhone and applied on the watch (WatchConnectivity application context).
public struct CompanionSettings: Codable, Sendable, Equatable {
    public var useAppleIntelligence = true
    public var voiceGuidance = true
    public var zoneMethod: ZoneMethod = .karvonen
    public var studyMode = false
    public var participant = Participant.codes[0]
    public var wrist: Wrist = .left
    public var consent = false
    public var scenario: ReferenceScenario = .unknown
    /// Automatically save guided warm-up sensor data as training data (requires consent).
    public var autoCollect = false
    /// Reps / seconds per move set on the iPhone (nil = automatic).
    public var moveTargets = MoveTargets()
    /// Ready-zone baseline per sport, keyed by `WorkoutKind.rawValue` (missing = automatic).
    public var sportZones: [String: ZoneBaseline] = [:]
    public var updatedAt = Date(timeIntervalSince1970: 0)

    public init() {}

    public func zoneBaseline(for workout: WorkoutKind) -> ZoneBaseline {
        sportZones[workout.rawValue] ?? ZoneBaseline()
    }

    private enum CodingKeys: String, CodingKey {
        case useAppleIntelligence, voiceGuidance, zoneMethod, studyMode, participant, wrist, consent, scenario, autoCollect, moveTargets, sportZones, updatedAt
    }

    /// Missing keys (settings saved by an older version) fall back to defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CompanionSettings()
        useAppleIntelligence = try c.decodeIfPresent(Bool.self, forKey: .useAppleIntelligence) ?? d.useAppleIntelligence
        voiceGuidance = try c.decodeIfPresent(Bool.self, forKey: .voiceGuidance) ?? d.voiceGuidance
        zoneMethod = try c.decodeIfPresent(ZoneMethod.self, forKey: .zoneMethod) ?? d.zoneMethod
        studyMode = try c.decodeIfPresent(Bool.self, forKey: .studyMode) ?? d.studyMode
        participant = try c.decodeIfPresent(String.self, forKey: .participant) ?? d.participant
        wrist = try c.decodeIfPresent(Wrist.self, forKey: .wrist) ?? d.wrist
        consent = try c.decodeIfPresent(Bool.self, forKey: .consent) ?? d.consent
        scenario = try c.decodeIfPresent(ReferenceScenario.self, forKey: .scenario) ?? d.scenario
        autoCollect = try c.decodeIfPresent(Bool.self, forKey: .autoCollect) ?? d.autoCollect
        moveTargets = try c.decodeIfPresent(MoveTargets.self, forKey: .moveTargets) ?? d.moveTargets
        sportZones = try c.decodeIfPresent([String: ZoneBaseline].self, forKey: .sportZones) ?? d.sportZones
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? d.updatedAt
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> CompanionSettings {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(CompanionSettings.self, from: data)
    }
}

/// Watch status reported back to iPhone.
public struct WatchStatus: Codable, Sendable, Equatable {
    public var classifierName: String
    public var learnedModelVersion: Int?
    public var settingsUpdatedAt: Date?
    public var reportedAt: Date

    public init(classifierName: String, learnedModelVersion: Int?, settingsUpdatedAt: Date?, reportedAt: Date) {
        self.classifierName = classifierName
        self.learnedModelVersion = learnedModelVersion
        self.settingsUpdatedAt = settingsUpdatedAt
        self.reportedAt = reportedAt
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> WatchStatus {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(WatchStatus.self, from: data)
    }
}

/// WatchConnectivity message keys between iPhone and watch.
public enum SyncKey {
    public static let kind = "kind"
    public static let data = "data"
    public static let settings = "settings"
    public static let status = "status"
    public static let model = "model"
    public static let resetModel = "resetModel"
    public static let session = "session"
    public static let training = "training"
    public static let fileName = "fileName"
}

extension RecordingName {
    /// Automatic recordings from guided warm-ups are marked with an id prefixed `auto-`.
    public var isAuto: Bool { id.hasPrefix("auto-") }
}
