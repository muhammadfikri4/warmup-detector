import SwiftUI
import WarmUpCore

/// Settings are read-only on the watch; everything is changed in the iPhone app and synced.
struct SettingsView: View {
    @Environment(AppFlow.self) private var flow
    @AppStorage(AppSettings.Key.useAppleIntelligence) private var useAI = true
    @AppStorage(AppSettings.Key.voiceGuidance) private var voice = true
    @AppStorage(AppSettings.Key.zoneMethod) private var zoneMethod = ZoneMethod.karvonen.rawValue
    @AppStorage(AppSettings.Key.settingsUpdatedAt) private var updatedAt: Double = 0

    var body: some View {
        Form {
            Section {
                Label("Managed from iPhone", systemImage: "iphone")
            } footer: {
                Text(updatedAt > 0
                     ? "Last synced: \(Date(timeIntervalSinceReferenceDate: updatedAt).formatted(date: .abbreviated, time: .shortened))"
                     : "Never synced — using default settings.")
            }
            Section("Coach") {
                LabeledContent("Apple Intelligence", value: useAI ? "On" : "Off")
                LabeledContent("AI Status", value: flow.coach.availabilityText)
                LabeledContent("Voice guidance", value: voice ? "On" : "Off")
                if voice {
                    LabeledContent("Voice", value: SpeechCoach.voiceDescription)
                }
                LabeledContent("HR zone", value: ZoneMethod(rawValue: zoneMethod)?.displayName ?? zoneMethod)
            }
            StudySettingsSection()
            Section("Motion classifier") {
                Text(ClassifierFactory.activeClassifierName).font(.footnote)
            }
        }
        .navigationTitle("Settings")
    }
}
