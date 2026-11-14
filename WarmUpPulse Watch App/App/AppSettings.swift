import Foundation
import WarmUpCore

enum AppSettings {
    enum Key {
        static let useAppleIntelligence = "useAppleIntelligence"
        static let voiceGuidance = "voiceGuidance"
        static let zoneMethod = "zoneMethod"
        // Study Mode — also used by the training data recorder.
        static let studyMode = "studyMode"
        static let participant = "studyParticipant"
        static let wrist = "studyWrist"
        static let consent = "studyConsent"
        static let scenario = "studyScenario"
        static let autoCollect = "autoCollect"
        static let settingsUpdatedAt = "settingsUpdatedAt"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.useAppleIntelligence: true,
            Key.voiceGuidance: true,
            Key.zoneMethod: ZoneMethod.karvonen.rawValue,
            Key.studyMode: false,
            Key.participant: Participant.codes[0],
            Key.wrist: Wrist.left.rawValue,
            Key.consent: false,
            Key.scenario: ReferenceScenario.unknown.rawValue,
            Key.autoCollect: false,
        ])
    }

    /// Applies settings from iPhone (the source of truth for settings).
    static func apply(_ s: CompanionSettings) {
        defaults.set(s.useAppleIntelligence, forKey: Key.useAppleIntelligence)
        defaults.set(s.voiceGuidance, forKey: Key.voiceGuidance)
        defaults.set(s.zoneMethod.rawValue, forKey: Key.zoneMethod)
        defaults.set(s.studyMode, forKey: Key.studyMode)
        defaults.set(s.participant, forKey: Key.participant)
        defaults.set(s.wrist.rawValue, forKey: Key.wrist)
        defaults.set(s.consent, forKey: Key.consent)
        defaults.set(s.scenario.rawValue, forKey: Key.scenario)
        defaults.set(s.autoCollect, forKey: Key.autoCollect)
        defaults.set(s.updatedAt.timeIntervalSinceReferenceDate, forKey: Key.settingsUpdatedAt)
    }

    static var settingsUpdatedAt: Date? {
        let t = defaults.double(forKey: Key.settingsUpdatedAt)
        return t > 0 ? Date(timeIntervalSinceReferenceDate: t) : nil
    }

    /// Auto-record guided warm-up data only when enabled AND the participant has consented.
    static var isAutoCollecting: Bool { defaults.bool(forKey: Key.autoCollect) && consent }

    private static var defaults: UserDefaults { .standard }

    static var useAppleIntelligence: Bool { defaults.bool(forKey: Key.useAppleIntelligence) }
    static var voiceGuidance: Bool { defaults.bool(forKey: Key.voiceGuidance) }
    static var zoneConfiguration: ZoneConfiguration {
        let method = defaults.string(forKey: Key.zoneMethod).flatMap(ZoneMethod.init) ?? .karvonen
        return ZoneConfiguration(method: method)
    }

    static var studyMode: Bool { defaults.bool(forKey: Key.studyMode) }
    static var participant: String { defaults.string(forKey: Key.participant) ?? Participant.codes[0] }
    static var wrist: Wrist { defaults.string(forKey: Key.wrist).flatMap(Wrist.init) ?? .left }
    static var consent: Bool { defaults.bool(forKey: Key.consent) }
    static var scenario: ReferenceScenario {
        get { defaults.string(forKey: Key.scenario).flatMap(ReferenceScenario.init) ?? .unknown }
        set { defaults.set(newValue.rawValue, forKey: Key.scenario) }
    }

    /// The evaluation log is only written when Study Mode is on AND the participant has consented.
    static var isStudyLogging: Bool { studyMode && consent }
}
