import SwiftUI
import WarmUpCore

/// Identitas samaran + consent (diatur di iPhone; watch hanya menampilkan).
struct ParticipantSection: View {
    @AppStorage(AppSettings.Key.participant) private var participant = Participant.codes[0]
    @AppStorage(AppSettings.Key.wrist) private var wrist = Wrist.left.rawValue
    @AppStorage(AppSettings.Key.consent) private var consent = false

    var body: some View {
        Section {
            LabeledContent("Partisipan", value: participant)
            LabeledContent("Pergelangan", value: Wrist(rawValue: wrist)?.displayName ?? wrist)
            LabeledContent("Persetujuan", value: consent ? "✓ Setuju" : "✗ Belum")
        } header: {
            Text("Partisipan")
        } footer: {
            if !consent { Text("Centang persetujuan partisipan di app iPhone.") }
        }
    }
}

struct RecorderView: View {
    @Environment(AppFlow.self) private var flow
    @State private var recorder: TrainingRecorder?

    var body: some View {
        Group {
            if let recorder {
                RecorderContent(recorder: recorder)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Rekam Data")
        .onAppear { if recorder == nil { recorder = TrainingRecorder(store: flow.health.store) } }
        .onDisappear { recorder?.cancel() }
    }
}

private struct RecorderContent: View {
    @Bindable var recorder: TrainingRecorder
    @AppStorage(AppSettings.Key.consent) private var consent = false
    @AppStorage(AppSettings.Key.participant) private var participant = Participant.codes[0]

    var body: some View {
        switch recorder.state {
        case .countdown(let n):
            Text("\(n)").font(Theme.counter)
        case .recording(let remaining):
            VStack(spacing: 6) {
                Text(recorder.label.rawValue).font(.headline)
                Text("\(remaining)").font(Theme.counter).monospacedDigit()
                Button("Batal", role: .destructive) { recorder.cancel() }
            }
        case .idle, .saved, .failed:
            Form {
                ParticipantSection()
                Section("Rekaman") {
                    Picker("Label", selection: $recorder.label) {
                        ForEach(MotionLabel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Durasi \(recorder.durationSeconds) dtk", value: $recorder.durationSeconds, in: 10...120, step: 10)
                    Button("Rekam") { recorder.start() }
                        .tint(Theme.warm)
                        .disabled(!consent)
                }
                Section {
                    if case .saved(let info) = recorder.state { Text("Tersimpan: \(info)").font(.footnote) }
                    if case .failed(let error) = recorder.state { Text(error).font(.footnote).foregroundStyle(.red) }
                    let counts = recorder.countsForCurrentParticipant()
                    ForEach(MotionLabel.allCases, id: \.self) { label in
                        LabeledContent(label.rawValue, value: "\(counts[label, default: 0])")
                            .font(.footnote)
                    }
                } header: {
                    Text("Rekaman \(participant)")
                } footer: {
                    Text("Target ≥ 5 sesi per label per partisipan, dari beberapa orang & kedua pergelangan.")
                }
            }
        }
    }
}

/// Status Mode Studi (diatur di iPhone): skenario referensi ditentukan peneliti SEBELUM menekan Start.
struct StudySettingsSection: View {
    @AppStorage(AppSettings.Key.studyMode) private var studyMode = false
    @AppStorage(AppSettings.Key.scenario) private var scenario = ReferenceScenario.unknown.rawValue
    @AppStorage(AppSettings.Key.autoCollect) private var autoCollect = false

    var body: some View {
        Section {
            LabeledContent("Mode Studi", value: studyMode ? "Aktif" : "Mati")
            if studyMode {
                LabeledContent("Skenario", value: ReferenceScenario(rawValue: scenario)?.displayName ?? scenario)
                LabeledContent("Log tersimpan", value: "\(SessionLogger.count) sesi")
            }
            LabeledContent("Rekam otomatis", value: autoCollect ? "Aktif" : "Mati")
        } header: {
            Text("Evaluasi & data")
        }
        if studyMode || autoCollect { ParticipantSection() }
    }
}

/// Input hitungan manual peneliti (referensi) untuk gerakan berbasis repetisi.
struct ReferenceCountsSection: View {
    let steps: [StepLog]
    @Binding var references: [Int: Int]

    var body: some View {
        Section {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if case .reps = step.target {
                    let binding = Binding(get: { references[index] ?? Int(step.counted) }, set: { references[index] = $0 })
                    Stepper(value: binding, in: 0...200) {
                        VStack(alignment: .leading) {
                            Text(step.exercise.displayName).font(.footnote)
                            Text("App \(Int(step.counted)) · Manual \(binding.wrappedValue)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Hitungan manual")
        } footer: {
            Text("Isi sesuai hitungan peneliti/video sebagai referensi.")
        }
    }
}
