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
                case .failed(let issue): FailureView(issue: issue)
                }
            }
            .animation(.easeInOut, value: flow.phase)
        }
    }
}

/// Live heart rate from the workout session, updating as each sample arrives.
/// Until the first live sample, it shows the latest Health reading (dimmed) or "Measuring…".
struct HeartRateLabel: View {
    @Environment(AppFlow.self) private var flow
    var size: Font = .system(.body, design: .rounded).weight(.semibold)

    var body: some View {
        let reading = flow.displayHeartRate
        HStack(spacing: 4) {
            Image(systemName: "heart.fill")
                .symbolEffect(.pulse, options: .repeating, isActive: reading?.isLive ?? true)
            if let reading {
                Text("\(Int(reading.bpm.rounded()))")
                    .contentTransition(.numericText())
                    .animation(.default, value: Int(reading.bpm.rounded()))
                if !reading.isLive {
                    Text("last").font(.caption2)
                }
            } else {
                Text("Measuring…").font(.footnote)
            }
        }
        .font(size)
        .monospacedDigit()
        .foregroundStyle(reading?.isLive == false ? Color.gray : Color.red)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(reading.map { "Heart rate \(Int($0.bpm.rounded())) beats per minute" } ?? "Measuring heart rate")
    }
}

/// Pipeline stage 2: gaps & discarded data stay visible, never hidden.
struct DataQualityNote: View {
    let quality: HeartRateQuality?

    var body: some View {
        if let quality, quality.removedCount > 0 || quality.longestGapMinutes >= 3 {
            Label("Some heart-rate readings were missing", systemImage: "exclamationmark.circle")
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
                Text("Start Workout")
            }
            Section {
                NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
                NavigationLink { RecorderView() } label: { Label("Record Training Data", systemImage: "waveform.path.ecg") }
            }
        }
        .navigationTitle("WarmUp Pulse")
        .task {
            await flow.prepare()
            #if DEBUG
            flow.loadDemoIfRequested()
            #endif
        }
        .alert("Heads Up", isPresented: Binding(get: { flow.errorMessage != nil }, set: { if !$0 { flow.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(flow.errorMessage ?? "")
        }
    }
}

// MARK: - 2–3. Acquisition & evaluation

struct CheckingView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Checking readiness…")
                .font(.headline)
            HeartRateLabel()
        }
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { flow.cancel() } }
        }
    }
}

// MARK: - 4. Warning & plan

struct UnreadyView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "thermometer.low")
                    Text("Not Warmed Up")
                }
                .font(Theme.headline)
                .foregroundStyle(Theme.warm)
                .minimumScaleFactor(0.7)

                HeartRateLabel()

                Text(flow.message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if flow.isRefiningWithAI {
                    Label("Personalizing…", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if flow.messageFromAI {
                    Label("Personalized for you", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                DataQualityNote(quality: flow.assessment?.hrQuality)

                if let plan = flow.plan {
                    Text("\(plan.durationMinutes) min · \(plan.exerciseListText)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.warm)
                }

                if let plan = flow.plan, !plan.steps.isEmpty {
                    NavigationLink {
                        MovesPreviewView(steps: plan.steps)
                    } label: {
                        Label("Preview Moves", systemImage: "figure.cooldown")
                    }
                }
                Button("Start Warm-Up") { flow.beginWarmUp() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.warm)
                Button("Skip") { flow.skipWarmUp() }
                    .buttonStyle(.bordered)
            }
        }
        .defaultScrollAnchor(.top)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { flow.cancel() } }
        }
    }
}

// MARK: - 5. Guided Warm-Up

struct WarmUpView: View {
    @Environment(AppFlow.self) private var flow
    /// Step whose big intro demo is showing (first ~3 s of each move).
    @State private var introStep: Int?
    @State private var showsDemo = false

    var body: some View {
        if let step = flow.currentStep, let plan = flow.activePlan {
            content(step: step, plan: plan)
                .overlay {
                    if introStep == flow.stepIndex {
                        ExerciseDemoCard(step: step, caption: flow.stepIndex == 0 ? "First move" : "Next move")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.ignoresSafeArea())
                            .onTapGesture { introStep = nil }
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: introStep)
                .task(id: flow.stepIndex) {
                    introStep = flow.stepIndex
                    try? await Task.sleep(for: .seconds(3))
                    if introStep == flow.stepIndex { introStep = nil }
                }
                .sheet(isPresented: $showsDemo) {
                    ScrollView { ExerciseDemoCard(step: step) }
                }
        }
    }

    @ViewBuilder
    private func content(step: WarmUpStep, plan: WarmUpPlan) -> some View {
        Group {
            VStack(spacing: 2) {
                HStack {
                    Text("Move \(flow.stepIndex + 1)/\(plan.steps.count)")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    HeartRateLabel()
                }

                Text(step.exercise.displayName)
                    .font(Theme.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                HStack(spacing: 6) {
                    Button { showsDemo = true } label: {
                        ExerciseDemoView(exercise: step.exercise, accent: .white, showsTrail: false)
                            .frame(width: 54, height: 54)
                            .background(.black.opacity(0.25), in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show how to do \(step.exercise.displayName)")

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(progressText(step))
                            .font(Theme.counter)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(targetText(step))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                }

                ProgressView(value: min(flow.stepProgress / step.target.value, 1))
                    .tint(flow.isPaused ? .gray : Theme.warm)

                if flow.isPaused {
                    Text("Paused — keep moving!")
                        .font(.headline)
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 4)
            .containerBackground(Theme.warm.gradient, for: .navigation)
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip", systemImage: "forward.end") { flow.skipWarmUp() } }
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

}

// MARK: - 6. Final confirmation

struct ConfirmView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if flow.confirmTimedOut {
                    Text(flow.message)
                        .font(.body)
                    Button("Add 1 Minute") { flow.addExtraMinute() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.warm)
                    Button("Start Now") { flow.enterWorkout() }
                        .buttonStyle(.bordered)
                        .handGestureShortcut(.primaryAction)
                } else {
                    Label("Warm-up complete", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Button {
                        flow.enterWorkout()
                    } label: {
                        Label("Start Workout", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ready)
                    .handGestureShortcut(.primaryAction) // double tap starts the workout hands-free
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking heart rate…").font(.footnote)
                    }
                    HeartRateLabel(size: .system(.title3, design: .rounded).weight(.semibold))
                    if let zones = flow.zones {
                        Text("Goal: \(Int(zones.lowerBound)) bpm")
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
                Text("Ready to Go")
                    .font(Theme.headline)
                HeartRateLabel()
                Text(flow.message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("Start") { flow.enterWorkout() }
                    .handGestureShortcut(.primaryAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.3))
            }
            .foregroundStyle(.white)
        }
        .containerBackground(Theme.ready.gradient, for: .navigation)
        .navigationBarBackButtonHidden()
    }
}

// MARK: - Main workout

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
                HeartRateLabel(size: .system(.title2, design: .rounded).weight(.semibold))
                Spacer(minLength: 0)
                Button("End", role: .destructive) { flow.endWorkout() }
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
                Label("Workout saved", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.ready)
                if let note = flow.summaryNote {
                    Text(note).font(.footnote)
                }
            }
            if flow.isStudyLogging, flow.stepLogs.contains(where: { if case .reps = $0.target { true } else { false } }) {
                ReferenceCountsSection(steps: flow.stepLogs, references: $references)
            }
            Button(flow.isStudyLogging ? "Save & Finish" : "Done") { flow.backHome(references: references) }
                .buttonStyle(.borderedProminent)
        }
        .navigationBarBackButtonHidden()
    }
}

// MARK: - Failure fallback

/// Shown instead of an error alert: says what happened in plain words and offers a way forward.
struct FailureView: View {
    @Environment(AppFlow.self) private var flow
    let issue: AppFlow.FlowIssue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Theme.warm)
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
                Button("Back to Home") { flow.cancel() }
                    .buttonStyle(.bordered)
            }
        }
        .navigationBarBackButtonHidden()
    }

    private var icon: String {
        switch issue {
        case .healthAccess: "heart.text.square"
        case .workoutStart: "exclamationmark.arrow.circlepath"
        case .noHeartRate: "heart.slash"
        case .motionUnavailable: "figure.stand"
        }
    }

    private var title: String {
        switch issue {
        case .healthAccess: "Heart rate access needed"
        case .workoutStart: "Couldn’t start the workout"
        case .noHeartRate: "No heart rate yet"
        case .motionUnavailable: "Can’t track movement"
        }
    }

    private var message: String {
        switch issue {
        case .healthAccess:
            "Allow WarmUp Pulse to read heart rate in Settings › Health › Apps › WarmUp Pulse, then try again."
        case .workoutStart(let detail):
            "Another workout may be running, or the watch is busy. Close other workout apps and try again. (\(detail))"
        case .noHeartRate:
            "Wear the watch snugly above the wrist bone and keep still for a moment. You can also warm up without the check."
        case .motionUnavailable:
            "Movement sensors aren’t available right now, so reps can’t be counted. You can skip the warm-up or try again."
        }
    }

    @ViewBuilder private var actions: some View {
        switch issue {
        case .healthAccess, .workoutStart:
            Button("Try Again") { flow.retry() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.warm)
        case .noHeartRate:
            Button("Try Again") { flow.retry() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.warm)
            Button("Warm Up Anyway") { flow.warmUpWithoutHeartRate() }
                .buttonStyle(.bordered)
            Button("Start Workout") { flow.enterWorkout() }
                .buttonStyle(.bordered)
        case .motionUnavailable:
            Button("Skip Warm-Up") { flow.skipWarmUp() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ready)
            Button("Try Again") { flow.retry() }
                .buttonStyle(.bordered)
        }
    }
}
