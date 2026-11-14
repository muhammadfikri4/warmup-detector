import AVFoundation
import WatchKit

/// Haptics per the PRD: .notification (not warmed up), .success (target reached + chime),
/// .click (gentle nudge when idle), .start (ready to work out).
enum Haptics {
    static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}

/// FR-I03 — spoken (text-to-speech) instructions at every exercise transition, in English.
///
/// Siri voices are not exposed to third-party apps, so this picks the BEST installed system voice
/// for English: Premium → Enhanced → Default, excluding novelty voices and Personal Voice.
final class SpeechCoach {
    private let synthesizer = AVSpeechSynthesizer()
    private lazy var voice = Self.bestVoice()

    func speak(_ text: String) {
        guard AppSettings.voiceGuidance else { return }
        let session = AVAudioSession.sharedInstance()
        // Spoken-audio mode at full gain (voicePrompt mode plays quieter on the watch speaker);
        // other audio is ducked so the cue stands out.
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.volume = 1.0
        // Slightly slower and brighter: easier to understand from a wrist speaker while moving.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 1.1
        // Let a haptic or chime finish first so it doesn't mask the first word.
        utterance.preUtteranceDelay = 0.25
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    static let languageCode = "en-US"

    /// Highest-quality English voice; en-US is preferred over other English dialects.
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en")
                && !$0.voiceTraits.contains(.isNoveltyVoice)
                && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let best = candidates.max { a, b in
            (a.quality.rawValue, a.language == languageCode ? 1 : 0) < (b.quality.rawValue, b.language == languageCode ? 1 : 0)
        }
        return best ?? AVSpeechSynthesisVoice(language: languageCode)
    }

    static var voiceDescription: String {
        guard let voice = bestVoice() else { return "System default" }
        let quality = switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Standard"
        }
        return "\(voice.name) · \(quality)"
    }
}
