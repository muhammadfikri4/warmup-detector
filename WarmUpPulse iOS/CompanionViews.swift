import SwiftUI
import WarmUpCore

@main
struct WarmUpPulseCompanionApp: App {
    @State private var store = CompanionStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Settings", systemImage: "gearshape") { SettingsScreen() }
                Tab("Data", systemImage: "tray.full") { DataScreen() }
                Tab("Model", systemImage: "brain") { ModelScreen() }
                Tab("Evaluation", systemImage: "checkmark.seal") { EvaluationScreen() }
            }
            .environment(store)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    store.connector.refresh()
                    store.refreshInventory()
                }
            }
            .alert("WarmUp Pulse", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.message ?? "")
            }
        }
    }
}

// MARK: - Settings (source of truth; synced to the watch)

struct SettingsScreen: View {
    @Environment(CompanionStore.self) private var store

    var body: some View {
        NavigationStack {
            Form {
                WatchStatusSection()

                Section {
                    Toggle("Apple Intelligence", isOn: store.binding(\.useAppleIntelligence))
                    Toggle("Voice guidance", isOn: store.binding(\.voiceGuidance))
                    Picker("HR zone", selection: store.binding(\.zoneMethod)) {
                        ForEach(ZoneMethod.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text("Coach")
                } footer: {
                    Text("On watchOS, Apple Intelligence runs via Apple's Private Cloud Compute; only summary numbers are sent. Ready zone = 50–70% of the selected method. Voice guidance uses the best English system voice installed on the watch (Siri voices aren't available to third-party apps).")
                }

                Section {
                    Picker("Participant", selection: store.binding(\.participant)) {
                        ForEach(Participant.codes, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Wrist", selection: store.binding(\.wrist)) {
                        ForEach(Wrist.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Participant consent", isOn: store.binding(\.consent))
                } header: {
                    Text("Participant")
                } footer: {
                    Text("Use a pseudonymous code, not a name. Changing the participant automatically revokes consent.")
                }

                Section {
                    Toggle("Study Mode", isOn: store.binding(\.studyMode))
                    if store.settings.studyMode {
                        Picker("Next session scenario", selection: store.binding(\.scenario)) {
                            ForEach(ReferenceScenario.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                } header: {
                    Text("Readiness evaluation")
                } footer: {
                    Text("Pick a scenario before the participant taps Start on the watch. Once the session is logged, the scenario resets to \"Unknown\".")
                }

                Section {
                    Toggle("Auto-record during warm-up", isOn: store.binding(\.autoCollect))
                        .disabled(!store.settings.consent)
                    if !store.settings.consent {
                        Label("Turn on \"Participant consent\" in the Participant section first.", systemImage: "lock.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Automatic training data")
                } footer: {
                    Text("Sensor data from each completed movement is saved, labeled as the instructed movement (weak label, weight 0.5 in training), then sent to the iPhone. Requires participant consent.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct WatchStatusSection: View {
    @Environment(CompanionStore.self) private var store

    var body: some View {
        let c = store.connector
        Section("Apple Watch") {
            LabeledContent("Installed", value: c.isPaired ? (c.isWatchAppInstalled ? "App installed" : "App not installed") : "No watch paired")
            LabeledContent("Reachable", value: c.isReachable ? "Yes" : "No (messages sent when connected)")
            if let status = store.watchStatus {
                LabeledContent("Classifier", value: status.classifierName)
                LabeledContent("Settings applied",
                               value: status.settingsUpdatedAt.map { $0 >= store.settings.updatedAt.addingTimeInterval(-1) ? "Up to date" : "Waiting to sync" } ?? "Not yet")
            }
        }
    }
}

// MARK: - Data

struct DataScreen: View {
    @Environment(CompanionStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                if store.participantsInData.isEmpty {
                    ContentUnavailableView("No data yet", systemImage: "waveform.path.ecg",
                                           description: Text("Record training data on the watch or turn on auto-record."))
                }
                ForEach(store.participantsInData, id: \.self) { person in
                    Section(person) {
                        ForEach(store.counts(for: person), id: \.label) { row in
                            LabeledContent(row.label, value: "\(row.manual) manual · \(row.auto) auto")
                        }
                    }
                }
                Section("Evaluation log") {
                    LabeledContent("Sessions logged", value: "\(store.sessionCount)")
                }
            }
            .navigationTitle("Data")
            .toolbar {
                if !store.exportURLs.isEmpty {
                    ShareLink(items: store.exportURLs) { Label("Export", systemImage: "square.and.arrow.up") }
                }
            }
            .refreshable { store.refreshInventory() }
        }
    }
}

// MARK: - Model (manual training trigger)

struct ModelScreen: View {
    @Environment(CompanionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            List {
                Section("Active model on watch") {
                    if let model = store.activeModel {
                        LabeledContent("Version", value: "v\(model.version)")
                        LabeledContent("Trained", value: model.info.trainedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Training data", value: "\(model.info.trainingWindows) windows · \(model.info.participants.joined(separator: ", "))")
                        Text(model.info.evaluation).font(.footnote).foregroundStyle(.secondary)
                        Button("Revert to built-in model", role: .destructive) { store.resetModel() }
                    } else {
                        Text("Built-in (Core ML if available, otherwise heuristic)")
                    }
                }

                Section {
                    if store.participantsInData.isEmpty {
                        Text("No participants yet.").foregroundStyle(.secondary)
                    }
                    ForEach(store.participantsInData, id: \.self) { person in
                        Toggle(person, isOn: Binding(
                            get: { store.goldenParticipants.contains(person) },
                            set: { on in if on { store.goldenParticipants.insert(person) } else { store.goldenParticipants.remove(person) } }
                        ))
                    }
                } header: {
                    Text("Golden set")
                } footer: {
                    Text("Selected participants are held out for testing only and are NEVER used for training. Leave empty for leave-one-person-out evaluation.")
                }

                Section {
                    Button {
                        store.train()
                    } label: {
                        if store.isTraining {
                            HStack { ProgressView(); Text("Training…") }
                        } else {
                            Label("Retrain", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(store.isTraining || store.recordings.isEmpty)
                } footer: {
                    Text("Clean → features → logistic regression → evaluation on unseen people. A model can only be sent if accuracy is ≥ 85% and no worse than the active model.")
                }

                if let report = store.trainingReport {
                    Section("Results") {
                        if store.candidate != nil {
                            Button("Send to Watch") { store.deployCandidate() }
                                .buttonStyle(.borderedProminent)
                        }
                        ScrollView(.horizontal) {
                            Text(report).font(.caption2.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Model")
        }
    }
}

// MARK: - Readiness evaluation

struct EvaluationScreen: View {
    @Environment(CompanionStore.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(store.readinessReport)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("Evaluation")
            .refreshable { store.refreshInventory() }
        }
    }
}
