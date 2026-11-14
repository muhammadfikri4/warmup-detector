import SwiftUI
import WarmUpCore

/// Pengaturan di watch hanya ditampilkan; semua diubah dari app iPhone lalu disinkronkan.
struct SettingsView: View {
    @Environment(AppFlow.self) private var flow
    @AppStorage(AppSettings.Key.useAppleIntelligence) private var useAI = true
    @AppStorage(AppSettings.Key.voiceGuidance) private var voice = true
    @AppStorage(AppSettings.Key.zoneMethod) private var zoneMethod = ZoneMethod.karvonen.rawValue
    @AppStorage(AppSettings.Key.settingsUpdatedAt) private var updatedAt: Double = 0

    var body: some View {
        Form {
            Section {
                Label("Diatur dari iPhone", systemImage: "iphone")
            } footer: {
                Text(updatedAt > 0
                     ? "Sinkron terakhir: \(Date(timeIntervalSinceReferenceDate: updatedAt).formatted(date: .abbreviated, time: .shortened))"
                     : "Belum pernah sinkron — memakai pengaturan bawaan.")
            }
            Section("Pelatih") {
                LabeledContent("Apple Intelligence", value: useAI ? "Aktif" : "Mati")
                LabeledContent("Status AI", value: flow.coach.availabilityText)
                LabeledContent("Panduan suara", value: voice ? "Aktif" : "Mati")
                LabeledContent("Zona HR", value: ZoneMethod(rawValue: zoneMethod)?.displayName ?? zoneMethod)
            }
            StudySettingsSection()
            Section("Classifier gerakan") {
                Text(ClassifierFactory.activeClassifierName).font(.footnote)
            }
        }
        .navigationTitle("Pengaturan")
    }
}
