import Foundation

/// Pengaturan yang diatur di iPhone lalu diterapkan di watch (WatchConnectivity application context).
public struct CompanionSettings: Codable, Sendable, Equatable {
    public var useAppleIntelligence = true
    public var voiceGuidance = true
    public var zoneMethod: ZoneMethod = .karvonen
    public var studyMode = false
    public var participant = Participant.codes[0]
    public var wrist: Wrist = .left
    public var consent = false
    public var scenario: ReferenceScenario = .unknown
    /// Simpan otomatis data sensor pemanasan terpandu sebagai data latih (butuh consent).
    public var autoCollect = false
    public var updatedAt = Date(timeIntervalSince1970: 0)

    public init() {}

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

/// Status watch yang dilaporkan balik ke iPhone.
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

/// Kunci pesan WatchConnectivity antara iPhone dan watch.
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
    /// Rekaman otomatis dari pemanasan terpandu ditandai dengan id berawalan `auto-`.
    public var isAuto: Bool { id.hasPrefix("auto-") }
}
