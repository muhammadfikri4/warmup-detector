import AVFoundation
import WatchKit

/// Haptik sesuai PRD: .notification (belum pemanasan), .success (target tercapai + chime),
/// .click (pengingat lembut saat diam), .start (siap olahraga).
enum Haptics {
    static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}

/// FR-I03 — instruksi suara (Text-to-Speech) di setiap transisi gerakan.
final class SpeechCoach {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "id-ID") ?? AVSpeechSynthesisVoice(language: nil)

    func speak(_ text: String) {
        guard AppSettings.voiceGuidance else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? session.setActive(true)
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
