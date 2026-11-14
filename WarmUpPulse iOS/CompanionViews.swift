import SwiftUI
import WarmUpCore

@main
struct WarmUpPulseCompanionApp: App {
    @State private var store = CompanionStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Pengaturan", systemImage: "gearshape") { SettingsScreen() }
                Tab("Data", systemImage: "tray.full") { DataScreen() }
                Tab("Model", systemImage: "brain") { ModelScreen() }
                Tab("Evaluasi", systemImage: "checkmark.seal") { EvaluationScreen() }
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

// MARK: - Pengaturan (sumber kebenaran; disinkronkan ke watch)

struct SettingsScreen: View {
    @Environment(CompanionStore.self) private var store

    var body: some View {
        NavigationStack {
            Form {
                WatchStatusSection()

                Section {
                    Toggle("Apple Intelligence", isOn: store.binding(\.useAppleIntelligence))
                    Toggle("Panduan suara", isOn: store.binding(\.voiceGuidance))
                    Picker("Zona HR", selection: store.binding(\.zoneMethod)) {
                        ForEach(ZoneMethod.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text("Pelatih")
                } footer: {
                    Text("Di watchOS, Apple Intelligence diproses lewat Private Cloud Compute Apple; hanya angka ringkas yang dikirim. Zona siap = 50–70% dari metode yang dipilih.")
                }

                Section {
                    Picker("Partisipan", selection: store.binding(\.participant)) {
                        ForEach(Participant.codes, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Pergelangan", selection: store.binding(\.wrist)) {
                        ForEach(Wrist.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Partisipan setuju (consent)", isOn: store.binding(\.consent))
                } header: {
                    Text("Partisipan")
                } footer: {
                    Text("Pakai kode samaran, bukan nama. Mengganti partisipan otomatis mencabut persetujuan.")
                }

                Section {
                    Toggle("Mode Studi", isOn: store.binding(\.studyMode))
                    if store.settings.studyMode {
                        Picker("Skenario sesi berikutnya", selection: store.binding(\.scenario)) {
                            ForEach(ReferenceScenario.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                } header: {
                    Text("Evaluasi kesiapan")
                } footer: {
                    Text("Pilih skenario sebelum partisipan menekan Start di watch. Setelah sesi tercatat, skenario kembali ke \"Tidak diketahui\".")
                }

                Section {
                    Toggle("Rekam otomatis saat pemanasan", isOn: store.binding(\.autoCollect))
                        .disabled(!store.settings.consent)
                    if !store.settings.consent {
                        Label("Nyalakan \"Partisipan setuju (consent)\" di bagian Partisipan dulu.", systemImage: "lock.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Data latih otomatis")
                } footer: {
                    Text("Data sensor tiap gerakan yang selesai disimpan dengan label = gerakan yang diinstruksikan (label lemah, bobot 0,5 saat training) lalu dikirim ke iPhone. Butuh persetujuan partisipan.")
                }
            }
            .navigationTitle("Pengaturan")
        }
    }
}

struct WatchStatusSection: View {
    @Environment(CompanionStore.self) private var store

    var body: some View {
        let c = store.connector
        Section("Apple Watch") {
            LabeledContent("Terpasang", value: c.isPaired ? (c.isWatchAppInstalled ? "App terpasang" : "App belum terpasang") : "Tidak ada watch")
            LabeledContent("Terjangkau", value: c.isReachable ? "Ya" : "Tidak (pesan dikirim saat tersambung)")
            if let status = store.watchStatus {
                LabeledContent("Classifier", value: status.classifierName)
                LabeledContent("Pengaturan diterapkan",
                               value: status.settingsUpdatedAt.map { $0 >= store.settings.updatedAt.addingTimeInterval(-1) ? "Terbaru" : "Menunggu sinkron" } ?? "Belum")
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
                    ContentUnavailableView("Belum ada data", systemImage: "waveform.path.ecg",
                                           description: Text("Rekam di watch (Rekam Data Latih) atau aktifkan rekam otomatis."))
                }
                ForEach(store.participantsInData, id: \.self) { person in
                    Section(person) {
                        ForEach(store.counts(for: person), id: \.label) { row in
                            LabeledContent(row.label, value: "\(row.manual) manual · \(row.auto) otomatis")
                        }
                    }
                }
                Section("Log evaluasi") {
                    LabeledContent("Sesi tercatat", value: "\(store.sessionCount)")
                }
            }
            .navigationTitle("Data")
            .toolbar {
                if !store.exportURLs.isEmpty {
                    ShareLink(items: store.exportURLs) { Label("Ekspor", systemImage: "square.and.arrow.up") }
                }
            }
            .refreshable { store.refreshInventory() }
        }
    }
}

// MARK: - Model (pemicu training manual)

struct ModelScreen: View {
    @Environment(CompanionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            List {
                Section("Model aktif di watch") {
                    if let model = store.activeModel {
                        LabeledContent("Versi", value: "v\(model.version)")
                        LabeledContent("Dilatih", value: model.info.trainedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Data latih", value: "\(model.info.trainingWindows) jendela · \(model.info.participants.joined(separator: ", "))")
                        Text(model.info.evaluation).font(.footnote).foregroundStyle(.secondary)
                        Button("Kembali ke model bawaan", role: .destructive) { store.resetModel() }
                    } else {
                        Text("Bawaan (CoreML bila ada, selain itu heuristik)")
                    }
                }

                Section {
                    if store.participantsInData.isEmpty {
                        Text("Belum ada partisipan.").foregroundStyle(.secondary)
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
                    Text("Partisipan terpilih dikunci khusus untuk pengujian dan TIDAK PERNAH dipakai melatih. Kosongkan untuk evaluasi leave-one-person-out.")
                }

                Section {
                    Button {
                        store.train()
                    } label: {
                        if store.isTraining {
                            HStack { ProgressView(); Text("Melatih…") }
                        } else {
                            Label("Latih Ulang", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(store.isTraining || store.recordings.isEmpty)
                } footer: {
                    Text("Clean → fitur → logistic regression → evaluasi pada orang baru. Model hanya bisa dikirim bila akurasi ≥ 85% dan tidak lebih buruk dari model aktif.")
                }

                if let report = store.trainingReport {
                    Section("Hasil") {
                        if store.candidate != nil {
                            Button("Kirim ke Watch") { store.deployCandidate() }
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

// MARK: - Evaluasi kesiapan

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
            .navigationTitle("Evaluasi")
            .refreshable { store.refreshInventory() }
        }
    }
}
