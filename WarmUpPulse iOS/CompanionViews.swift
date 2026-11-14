import SwiftUI
import WarmUpCore

@main
struct WarmUpPulseCompanionApp: App {
    @State private var store = CompanionStore()
    @Environment(\.scenePhase) private var scenePhase
    /// Launch with `-tab data|model|evaluation` to open on a tab (used for screenshots).
    @State private var tab = UserDefaults.standard.string(forKey: "tab") ?? "settings"

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                Tab("Settings", systemImage: "gearshape", value: "settings") { SettingsScreen() }
                Tab("Insights", systemImage: "chart.xyaxis.line", value: "insights") { InsightsScreen() }
                Tab("Data", systemImage: "tray.full", value: "data") { DataScreen() }
                Tab("Model", systemImage: "brain", value: "model") { ModelScreen() }
                Tab("Evaluation", systemImage: "checkmark.seal", value: "evaluation") { EvaluationScreen() }
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
                    ForEach(WorkoutKind.allCases) { kind in
                        NavigationLink {
                            SportZoneEditor(kind: kind)
                        } label: {
                            LabeledContent {
                                Text(zoneText(store.settings.zoneBaseline(for: kind)))
                            } label: {
                                Label(kind.displayName, systemImage: kind.symbolName)
                            }
                        }
                    }
                } header: {
                    Text("Ready zone per sport")
                } footer: {
                    Text("The heart-rate range that counts as warmed up for each sport, from where it starts to where it ends. Auto calculates it from age and resting heart rate with the HR zone method above.")
                }

                Section {
                    TargetPicker(title: "Arm Circles", unit: "reps", choices: MoveTargets.repChoices,
                                 selection: store.binding(\.moveTargets.armCirclesReps))
                    TargetPicker(title: "Torso Twist", unit: "reps", choices: MoveTargets.repChoices,
                                 selection: store.binding(\.moveTargets.torsoTwistReps))
                    TargetPicker(title: "March in Place", unit: "s", choices: MoveTargets.secondChoices,
                                 selection: store.binding(\.moveTargets.marchInPlaceSeconds))
                } header: {
                    Text("Warm-up targets")
                } footer: {
                    Text("How many reps (or seconds) each move needs before the watch moves on. Auto sizes each move to fit a 3–5 minute plan.")
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
        Section {
            LabeledContent("Installed", value: c.isPaired ? (c.isWatchAppInstalled ? "App installed" : "App not installed") : "No watch paired")
            LabeledContent("Reachable", value: c.isReachable ? "Yes" : "No (messages sent when connected)")
            if let status = store.watchStatus {
                LabeledContent("Classifier", value: status.classifierName)
                LabeledContent("Settings applied",
                               value: status.settingsUpdatedAt.map { $0 >= store.settings.updatedAt.addingTimeInterval(-1) ? "Up to date" : "Waiting to sync" } ?? "Not yet")
            }
        } header: {
            Text("Apple Watch")
        } footer: {
            // Fallback guidance so a missing connection never looks like a silent failure.
            if !c.isPaired {
                Label("No Apple Watch is paired with this iPhone. Pair one in the Watch app, then reopen WarmUp Pulse.", systemImage: "applewatch.slash")
            } else if !c.isWatchAppInstalled {
                Label("Install WarmUp Pulse on the watch: Watch app › My Watch › Available Apps.", systemImage: "arrow.down.app")
            } else if !c.isReachable {
                Text("Changes are saved and will reach the watch the next time it connects.")
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
                if store.participantsInData.isEmpty && store.recentSessions.isEmpty {
                    ContentUnavailableView("No data yet", systemImage: "waveform.path.ecg",
                                           description: Text("Finish a workout on the watch, record training data, or turn on auto-record."))
                }
                if !store.recentSessions.isEmpty {
                    Section("Recent workouts") {
                        ForEach(store.recentSessions, id: \.id) { SessionRow(entry: $0) }
                    }
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

                if let result = store.lastTraining {
                    TrainingResultSections(result: result, canSend: store.candidate != nil,
                                           details: store.trainingReport, send: store.deployCandidate)
                }
            }
            .navigationTitle("Model")
        }
    }
}

// MARK: - Readiness evaluation


/// Picker for one move's target; "Auto" = sized by the watch's planner.
struct TargetPicker: View {
    let title: String
    let unit: String
    let choices: [Int]
    @Binding var selection: Int?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Auto").tag(Int?.none)
            ForEach(choices, id: \.self) { Text("\($0) \(unit)").tag(Int?($0)) }
        }
    }
}

/// One finished workout as reported by the watch.
struct SessionRow: View {
    let entry: SessionLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.workout.displayName).font(.headline)
                Spacer()
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text([entry.warmUp.displayName, entry.heartRate.map { "HR at start \(Int($0.rounded())) bpm" }, entry.participant]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let summary = entry.summary {
                Text(summary).font(.footnote)
            }
        }
        .padding(.vertical, 2)
    }
}

func zoneText(_ b: ZoneBaseline) -> String {
    switch (b.startBPM, b.endBPM) {
    case (nil, nil): "Auto"
    case let (s?, e?): "\(s)–\(e) bpm"
    case let (s?, nil): "from \(s) bpm"
    case let (nil, e?): "up to \(e) bpm"
    }
}

/// Edits one sport's ready zone (start and end bpm).
struct SportZoneEditor: View {
    @Environment(CompanionStore.self) private var store
    let kind: WorkoutKind

    var body: some View {
        let baseline = store.settings.zoneBaseline(for: kind)
        Form {
            Section {
                bpmPicker("Starts at", value: baseline.startBPM) { new in set(start: new, end: baseline.endBPM) }
                bpmPicker("Ends at", value: baseline.endBPM) { new in set(start: baseline.startBPM, end: new) }
            } footer: {
                if !baseline.isValid {
                    Label("The end must be higher than the start. The watch uses Auto until this is fixed.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text("Below the start the watch suggests a warm-up; between start and end you’re ready. Leave Auto to calculate it from age and resting heart rate.")
                }
            }
            if !baseline.isAutomatic {
                Button("Reset to Auto", role: .destructive) { set(start: nil, end: nil) }
            }
        }
        .navigationTitle(kind.displayName)
    }

    private func bpmPicker(_ title: String, value: Int?, onChange: @escaping (Int?) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: onChange)) {
            Text("Auto").tag(Int?.none)
            ForEach(ZoneBaseline.bpmChoices, id: \.self) { Text("\($0) bpm").tag(Int?($0)) }
        }
    }

    private func set(start: Int?, end: Int?) {
        store.update { settings in
            let b = ZoneBaseline(startBPM: start, endBPM: end)
            settings.sportZones[kind.rawValue] = b.isAutomatic ? nil : b
        }
    }
}
