import SwiftUI
import WarmUpCore

enum Theme {
    static let warm = Color.orange
    static let ready = Color.green
    static let headline = Font.system(size: 24, weight: .bold, design: .rounded)
    static let counter = Font.system(size: 52, weight: .heavy, design: .rounded)
}

struct RootView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        NavigationStack {
            Group {
                switch flow.phase {
                case .home: HomeView()
                case .checking: CheckingView()
                case .unready: UnreadyView()
                case .warmingUp: WarmUpView()
                case .confirming: ConfirmView()
                case .ready: ReadyView()
                case .workout: WorkoutView()
                case .finished: FinishedView()
                }
            }
            .animation(.easeInOut, value: flow.phase)
        }
    }
}

struct HeartRateLabel: View {
    let bpm: Double?

    var body: some View {
        Label(bpm.map { "\(Int($0))" } ?? "--", systemImage: "heart.fill")
            .font(.system(.body, design: .rounded).weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.red)
    }
}

/// Pipeline tahap 2: celah & data yang dibuang tetap terlihat, tidak disembunyikan.
struct DataQualityNote: View {
    let quality: HeartRateQuality?

    var body: some View {
        if let quality, quality.removedCount > 0 || quality.longestGapMinutes >= 3 {
            Label {
                Text([
                    quality.removedCount > 0 ? "\(quality.removedCount) sampel HR dibuang" : nil,
                    quality.longestGapMinutes >= 3 ? "celah data \(Int(quality.longestGapMinutes)) mnt" : nil,
                ].compactMap { $0 }.joined(separator: " · "))
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

struct StudyBadge: View {
    var body: some View {
        if AppSettings.isStudyLogging {
            Label("\(AppSettings.participant) · \(AppSettings.scenario.displayName)", systemImage: "list.clipboard")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 1. Home / Workout Trigger

struct HomeView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        @Bindable var flow = flow
        List {
            Section {
                StudyBadge()
                ForEach(WorkoutKind.allCases) { kind in
                    Button { flow.start(kind) } label: {
                        Label(kind.displayName, systemImage: kind.symbolName)
                            .font(.headline)
                    }
                }
            } header: {
                Text("Mulai Workout")
            }
            Section {
                NavigationLink { SettingsView() } label: { Label("Pengaturan", systemImage: "gearshape") }
                NavigationLink { RecorderView() } label: { Label("Rekam Data Latih", systemImage: "waveform.path.ecg") }
            }
        }
        .navigationTitle("WarmUp Pulse")
        .task { await flow.prepare() }
        .alert("Perhatian", isPresented: Binding(get: { flow.errorMessage != nil }, set: { if !$0 { flow.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(flow.errorMessage ?? "")
        }
    }
}

// MARK: - 2–3. Akuisisi & evaluasi

struct CheckingView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Mengecek kesiapan…")
                .font(.headline)
            HeartRateLabel(bpm: flow.heartRate)
        }
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Batal", systemImage: "xmark") { flow.cancel() } }
        }
    }
}

// MARK: - 4. Peringatan & rencana

struct UnreadyView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "thermometer.low")
                    Text("Belum Pemanasan")
                }
                .font(Theme.headline)
                .foregroundStyle(Theme.warm)
                .minimumScaleFactor(0.7)

                Text(flow.message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if flow.isRefiningWithAI {
                    Label("Apple Intelligence menyesuaikan…", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if flow.messageFromAI {
                    Label("Disesuaikan Apple Intelligence", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                DataQualityNote(quality: flow.assessment?.hrQuality)

                if let plan = flow.plan {
                    Text("\(plan.durationMinutes) menit · \(plan.exerciseListText)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.warm)
                }

                Button("Mulai Pemanasan") { flow.beginWarmUp() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.warm)
                Button("Lewati") { flow.skipWarmUp() }
                    .buttonStyle(.bordered)
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Batal", systemImage: "xmark") { flow.cancel() } }
        }
    }
}

// MARK: - 5. Guided Warm-Up

struct WarmUpView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        if let step = flow.currentStep, let plan = flow.activePlan {
            VStack(spacing: 2) {
                HStack {
                    Text("Gerakan \(flow.stepIndex + 1)/\(plan.steps.count)")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    HeartRateLabel(bpm: flow.heartRate)
                }

                Text(step.exercise.displayName)
                    .font(Theme.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(progressText(step))
                        .font(Theme.counter)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(targetText(step))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: min(flow.stepProgress / step.target.value, 1))
                    .tint(flow.isPaused ? .gray : Theme.warm)

                if flow.isPaused {
                    Text("Dijeda — ayo gerak lagi!")
                        .font(.headline)
                        .foregroundStyle(.yellow)
                } else if let p = flow.lastPrediction {
                    Text("\(label(p.label)) \(Int(p.confidence * 100))%\(flow.lastInferenceMilliseconds.map { String(format: " · %.0f ms", $0) } ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .containerBackground(Theme.warm.gradient, for: .navigation)
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Lewati", systemImage: "forward.end") { flow.skipWarmUp() } }
            }
        }
    }

    private func progressText(_ step: WarmUpStep) -> String {
        switch step.target {
        case .reps: "\(Int(flow.stepProgress))"
        case .duration: "\(Int(flow.stepProgress))"
        }
    }

    private func targetText(_ step: WarmUpStep) -> String {
        switch step.target {
        case .reps(let n): "/\(n)"
        case .duration(let s): "/\(Int(s))s"
        }
    }

    private func label(_ l: MotionLabel) -> String {
        l.exercise?.displayName ?? (l == .idle ? "Diam" : "Gerakan lain")
    }
}

// MARK: - 6. Konfirmasi akhir

struct ConfirmView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if flow.confirmTimedOut {
                    Text(flow.message)
                        .font(.body)
                    Button("Tambah 1 Menit") { flow.addExtraMinute() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.warm)
                    Button("Mulai Sekarang") { flow.enterWorkout() }
                        .buttonStyle(.bordered)
                } else {
                    ProgressView()
                    Text("Memvalidasi detak jantung…")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    HeartRateLabel(bpm: flow.heartRate)
                    if let zones = flow.zones {
                        Text("Target ≥ \(Int(zones.lowerBound)) bpm")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .containerBackground(Theme.warm.gradient, for: .navigation)
        .navigationBarBackButtonHidden()
    }
}

struct ReadyView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                Text("Siap Olahraga")
                    .font(Theme.headline)
                Text(flow.message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("Mulai") { flow.enterWorkout() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.3))
            }
            .foregroundStyle(.white)
        }
        .containerBackground(Theme.ready.gradient, for: .navigation)
        .navigationBarBackButtonHidden()
    }
}

// MARK: - Latihan inti

struct WorkoutView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                Label(flow.workout.displayName, systemImage: flow.workout.symbolName)
                    .font(.footnote)
                    .foregroundStyle(Theme.ready)
                Text(Duration.seconds(flow.workoutManager.elapsedTime(at: context.date))
                    .formatted(.time(pattern: .hourMinuteSecond)))
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                HeartRateLabel(bpm: flow.heartRate)
                    .font(.title2)
                Spacer(minLength: 0)
                Button("Akhiri", role: .destructive) { flow.endWorkout() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationBarBackButtonHidden()
    }
}

struct FinishedView: View {
    @Environment(AppFlow.self) private var flow
    @State private var references: [Int: Int] = [:]

    var body: some View {
        List {
            Section {
                Label("Workout tersimpan", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.ready)
                if let note = flow.summaryNote {
                    Text(note).font(.footnote)
                }
            }
            if flow.isStudyLogging, flow.stepLogs.contains(where: { if case .reps = $0.target { true } else { false } }) {
                ReferenceCountsSection(steps: flow.stepLogs, references: $references)
            }
            Button(flow.isStudyLogging ? "Simpan & Selesai" : "Selesai") { flow.backHome(references: references) }
                .buttonStyle(.borderedProminent)
        }
        .navigationBarBackButtonHidden()
    }
}
