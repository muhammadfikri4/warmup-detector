import SwiftUI
import WarmUpCore

/// Pseudonymous ID + consent (set on iPhone; the watch only displays them).
struct ParticipantSection: View {
    @AppStorage(AppSettings.Key.participant) private var participant = Participant.codes[0]
    @AppStorage(AppSettings.Key.wrist) private var wrist = Wrist.left.rawValue
    @AppStorage(AppSettings.Key.consent) private var consent = false

    var body: some View {
        Section {
            LabeledContent("Participant", value: participant)
            LabeledContent("Wrist", value: Wrist(rawValue: wrist)?.displayName ?? wrist)
            LabeledContent("Consent", value: consent ? "✓ Given" : "✗ Not yet")
        } header: {
            Text("Participant")
        } footer: {
            if !consent { Text("Give participant consent in the iPhone app.") }
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
        .navigationTitle("Record Data")
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
                Button("Cancel", role: .destructive) { recorder.cancel() }
            }
        case .idle, .saved, .failed:
            Form {
                ParticipantSection()
                Section("Recording") {
                    Picker("Label", selection: $recorder.label) {
                        ForEach(MotionLabel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Duration \(recorder.durationSeconds)s", value: $recorder.durationSeconds, in: 10...120, step: 10)
                    Button("Record") { recorder.start() }
                        .tint(Theme.warm)
                        .disabled(!consent)
                }
                Section {
                    if case .saved(let info) = recorder.state { Text("Saved: \(info)").font(.footnote) }
                    if case .failed(let error) = recorder.state { Text(error).font(.footnote).foregroundStyle(.red) }
                    let counts = recorder.countsForCurrentParticipant()
                    ForEach(MotionLabel.allCases, id: \.self) { label in
                        LabeledContent(label.rawValue, value: "\(counts[label, default: 0])")
                            .font(.footnote)
                    }
                } header: {
                    Text("Recordings · \(participant)")
                } footer: {
                    Text("Aim for ≥ 5 sessions per label per participant, from several people & both wrists.")
                }
            }
        }
    }
}

/// Study Mode status (set on iPhone): the researcher picks the reference scenario BEFORE pressing Start.
struct StudySettingsSection: View {
    @AppStorage(AppSettings.Key.studyMode) private var studyMode = false
    @AppStorage(AppSettings.Key.scenario) private var scenario = ReferenceScenario.unknown.rawValue
    @AppStorage(AppSettings.Key.autoCollect) private var autoCollect = false

    var body: some View {
        Section {
            LabeledContent("Study Mode", value: studyMode ? "On" : "Off")
            if studyMode {
                LabeledContent("Scenario", value: ReferenceScenario(rawValue: scenario)?.displayName ?? scenario)
                LabeledContent("Logged sessions", value: "\(SessionLogger.count)")
            }
            LabeledContent("Auto-record", value: autoCollect ? "On" : "Off")
        } header: {
            Text("Evaluation & Data")
        }
        if studyMode || autoCollect { ParticipantSection() }
    }
}

/// Researcher's manual count input (reference) for rep-based exercises.
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
            Text("Manual count")
        } footer: {
            Text("Enter the researcher/video count as the reference.")
        }
    }
}
