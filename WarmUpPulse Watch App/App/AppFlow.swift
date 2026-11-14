import Foundation
import Observation
import WarmUpCore

/// End-to-end flow orchestrator (PRD §2):
/// Workout Trigger → Initial Acquisition → Readiness Check → Warning & Plan → Guided Warm-Up → Final Confirmation.
@Observable
final class AppFlow {
    enum Phase: Equatable {
        case home, checking, unready, warmingUp, confirming, ready, workout, finished
        /// Something went wrong; a fallback screen explains it and offers a way forward.
        case failed(FlowIssue)
    }

    /// Problems the flow can recover from without crashing or getting stuck.
    enum FlowIssue: Equatable {
        case healthAccess
        case workoutStart(String)
        case noHeartRate
        case motionUnavailable
    }

    // MARK: UI state
    private(set) var phase: Phase = .home
    private(set) var workout: WorkoutKind = .outdoorRun
    private(set) var assessment: ReadinessAssessment?
    private(set) var message = ""
    private(set) var isRefiningWithAI = false
    private(set) var messageFromAI = false
    private(set) var plan: WarmUpPlan?
    private(set) var activePlan: WarmUpPlan?
    private(set) var stepIndex = 0
    private(set) var stepProgress: Double = 0
    private(set) var isPaused = false
    private(set) var lastPrediction: MotionPrediction?
    private(set) var lastInferenceMilliseconds: Double?
    private(set) var confirmTimedOut = false
    private(set) var summaryNote: String?
    /// Per-exercise results (app-counted) — compared against the manual count in Study Mode.
    private(set) var stepLogs: [StepLog] = []
    var errorMessage: String?

    var isStudyLogging: Bool { AppSettings.isStudyLogging }

    /// Live heart rate from the workout session. Decisions use only this value.
    var heartRate: Double? { workoutManager.latestHeartRate?.bpm }
    /// Latest Health reading from before the live stream started (display only).
    private(set) var lastKnownHeartRate: HeartRateSample?
    /// What the UI shows: the live value as soon as it exists, else the last known reading.
    var displayHeartRate: (bpm: Double, isLive: Bool)? {
        if let live = workoutManager.latestHeartRate { return (live.bpm, true) }
        #if DEBUG
        if demoMode, let last = lastKnownHeartRate { return (last.bpm, true) }
        #endif
        return lastKnownHeartRate.map { ($0.bpm, false) }
    }
    #if DEBUG
    @ObservationIgnored private var demoMode = false
    #endif
    var zones: HeartRateZones? { assessment?.zones }
    var currentStep: WarmUpStep? { activePlan.flatMap { stepIndex < $0.steps.count ? $0.steps[stepIndex] : nil } }

    // MARK: Dependencies
    let health = HealthDataService()
    let workoutManager: WorkoutSessionManager
    private let motion = MotionSampler()
    let coach = CoachService()
    private let speech = SpeechCoach()
    private let readiness = ReadinessEngine()
    private let planner = WarmUpPlanner()

    @ObservationIgnored private var recovery: RecoveryContext?
    @ObservationIgnored private var cues: [String] = []
    @ObservationIgnored private var heartRateLog: [HeartRateSample] = []
    @ObservationIgnored private var warmUpStart: Date?
    @ObservationIgnored private var warmUpSkipped = false
    @ObservationIgnored private var pipeline: MotionPipeline?
    @ObservationIgnored private var flowTask: Task<Void, Never>?
    @ObservationIgnored private var authorized = false
    @ObservationIgnored private var checkStartedAt = Date()
    @ObservationIgnored private var checkLatency: TimeInterval = 0
    @ObservationIgnored private var warmUpCompleted = false
    @ObservationIgnored private var finalConfirmed: Bool?
    @ObservationIgnored private var classifierName = ""
    @ObservationIgnored private var sessionLogged = false

    init() {
        workoutManager = WorkoutSessionManager(store: health.store)
        workoutManager.onHeartRate = { [weak self] sample in self?.heartRateLog.append(sample) }
    }

    // MARK: Permissions
    func prepare() async {
        guard !authorized, health.isAvailable else { return }
        do {
            try await health.requestAuthorization()
            authorized = true
        } catch {
            // Handled by the fallback screen when the user taps Start.
        }
    }

    // MARK: 1–3. Trigger, initial acquisition, readiness check (≤ 3 seconds)
    func start(_ kind: WorkoutKind) {
        resetSession()
        workout = kind
        phase = .checking
        checkStartedAt = Date()
        flowTask = Task { await runReadinessCheck() }
    }

    private func runReadinessCheck() async {
        await prepare()
        guard authorized else {
            fail(.healthAccess)
            return
        }
        let startedAt = Date()
        do {
            try await workoutManager.start(workout)
        } catch {
            fail(.workoutStart(error.localizedDescription))
            return
        }

        let meter = MotionIntensityMeter()
        motion.start { meter.add($0) }

        let since = startedAt.addingTimeInterval(-10 * 60)
        async let history = health.heartRates(since: since, until: startedAt)
        async let energy = health.activeEnergy(since: since, until: startedAt)
        async let context = health.recoveryContext(for: workout, now: startedAt)
        let live = await workoutManager.waitForHeartRate(timeout: 2.5)
        let (samples, kcal, recovery) = await (history, energy, context)
        motion.stop()
        guard !Task.isCancelled, phase == .checking else { return }

        self.recovery = recovery
        heartRateLog = samples + heartRateLog
        lastKnownHeartRate = samples.last
        let zones = HeartRateZones(physiology: recovery.physiology, configuration: AppSettings.zoneConfiguration)
            .overriding(AppSettings.zoneBaseline(for: workout))
        let result = readiness.evaluate(ReadinessInput(currentHR: live, history: samples, recentActiveEnergy: kcal,
                                                       zones: zones, now: .now))
        assessment = result
        checkLatency = Date().timeIntervalSince(checkStartedAt)

        // No live or recent heart rate: don't guess. Let the user retry or choose what to do.
        if result.reasons.contains(where: { if case .noRecentHeartRate = $0 { true } else { false } }) {
            fail(.noHeartRate)
            return
        }

        if result.status == .ready {
            message = TemplateCoach.readyMessage(workout: workout, heartRate: result.heartRate, zones: zones, afterWarmUp: false)
            showReady()
        } else {
            presentUnready(result, recovery: recovery)
        }
    }

    // MARK: 4. Warning & plan
    private func presentUnready(_ result: ReadinessAssessment, recovery: RecoveryContext) {
        let targets = AppSettings.moveTargets
        let basePlan = planner.plan(for: recovery).applying(targets)
        plan = basePlan
        cues = []
        let context = CoachContext(recovery: recovery, assessment: result, plan: basePlan)
        message = TemplateCoach.unreadyMessage(context)
        phase = .unready
        Haptics.play(.notification)

        guard coach.isEnabled else { return }
        isRefiningWithAI = true
        Task {
            let suggestion = await coach.suggestPlan(for: context)
            isRefiningWithAI = false
            guard phase == .unready, let suggestion else { return }
            message = suggestion.message
            plan = suggestion.plan.applying(targets)
            // AI cues mention the automatic targets, so they're only used when nothing was set on the iPhone.
            cues = targets.isAutomatic ? suggestion.cues : []
            messageFromAI = true
        }
    }

    // MARK: 5. Guided Warm-Up
    func beginWarmUp() {
        guard let plan else { return }
        warmUpStart = warmUpStart ?? .now
        workoutManager.beginWarmUpActivity()
        run(plan)
    }

    func addExtraMinute() {
        run(planner.extraMinute())
    }

    private func run(_ plan: WarmUpPlan) {
        activePlan = plan
        stepIndex = 0
        stepProgress = 0
        isPaused = false
        confirmTimedOut = false
        phase = .warmingUp
        announce(stepIndex: 0)

        let classifier = ClassifierFactory.make()
        classifierName = classifier.name
        let pipeline = MotionPipeline(plan: plan, classifier: classifier, collectFrames: AppSettings.isAutoCollecting) { [weak self] update in
            Task { @MainActor in self?.handle(update) }
        }
        self.pipeline = pipeline
        if !motion.start(handler: { pipeline.process($0) }) {
            stopMotion()
            speech.stop()
            fail(.motionUnavailable)
        }
    }

    private func handle(_ update: MotionPipeline.Update) {
        guard phase == .warmingUp, let activePlan else { return }
        if let p = update.prediction { lastPrediction = p }
        if let ms = update.inferenceMilliseconds { lastInferenceMilliseconds = ms }
        if let step = update.completedStep { saveAutoRecording(step.exercise, frames: step.frames) }

        for event in update.events {
            switch event {
            case .progress(_, let value, _):
                stepProgress = value
            case .paused:
                isPaused = true
            case .idleReminder(let index):
                Haptics.play(.click)
                speech.speak(TemplateCoach.idleReminder(activePlan.steps[index]))
            case .resumed:
                isPaused = false
            case .stepCompleted(let index):
                Haptics.play(.success) // FR-P05: success haptic + system chime
                let step = activePlan.steps[index]
                stepLogs.append(StepLog(exercise: step.exercise, target: step.target, counted: step.target.value, completed: true))
            case .stepStarted(let index):
                stepIndex = index
                stepProgress = 0
                isPaused = false
                announce(stepIndex: index)
            case .allCompleted:
                warmUpCompleted = true
                finishWarmUp()
            }
        }
    }

    private func announce(stepIndex index: Int) {
        guard let activePlan else { return }
        let usesAICues = activePlan == plan && cues.count == activePlan.steps.count
        speech.speak(usesAICues ? cues[index] : TemplateCoach.stepCue(activePlan.steps[index], isFirst: index == 0))
    }

    // MARK: 6. Final confirmation
    private func finishWarmUp() {
        stopMotion() // NFR-01: turn off the 50 Hz sensor right away
        phase = .confirming
        confirmTimedOut = false
        Haptics.play(.success)
        speech.speak("Warm-up complete. Tap Start Workout, or double tap, to begin now.")
        flowTask = Task { await confirmReadiness() }
    }

    private func confirmReadiness() async {
        guard let zones else { return }
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, phase == .confirming, !Task.isCancelled {
            if readiness.confirmAfterWarmUp(heartRate: heartRate, zones: zones) {
                finalConfirmed = true
                message = TemplateCoach.readyMessage(workout: workout, heartRate: heartRate, zones: zones, afterWarmUp: true)
                showReady()
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        guard phase == .confirming else { return }
        confirmTimedOut = true
        finalConfirmed = false
        message = TemplateCoach.notInZoneMessage(heartRate: heartRate, zones: zones)
        Haptics.play(.directionUp)
    }

    private func showReady() {
        phase = .ready
        Haptics.play(.start)
        speech.speak(message)
        flowTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if phase == .ready, !Task.isCancelled { enterWorkout() }
        }
    }

    // MARK: Main workout
    // MARK: Fallbacks
    private func fail(_ issue: FlowIssue) {
        flowTask?.cancel()
        Haptics.play(.failure)
        phase = .failed(issue)
    }

    /// Runs the readiness check again for the same workout.
    func retry() {
        start(workout)
    }

    /// No heart rate: go ahead with the normal warm-up plan anyway.
    func warmUpWithoutHeartRate() {
        guard let assessment, let recovery else { return start(workout) }
        presentUnready(assessment, recovery: recovery)
    }

    func skipWarmUp() {
        warmUpSkipped = true
        enterWorkout()
    }

    func enterWorkout() {
        guard phase != .workout else { return }
        recordPartialStep()
        flowTask?.cancel()
        stopMotion()
        speech.stop()
        workoutManager.endWarmUpActivity()
        phase = .workout

        let now = Date()
        let summary = WarmUpSummary(samples: heartRateLog, start: warmUpStart ?? now, end: now,
                                    zoneLowerBound: zones?.lowerBound ?? 0, skipped: warmUpSkipped)
        let workout = workout
        let alreadyReady = warmUpStart == nil && !warmUpSkipped
        Task {
            let note = alreadyReady
                ? (heartRate.map { "Already ready at start (HR \(Int($0)) bpm), no extra warm-up needed." }
                    ?? "Started without a warm-up check.")
                : await coach.summaryNote(summary, workout: workout)
            summaryNote = note
            await workoutManager.addMetadata([
                WorkoutSessionManager.MetadataKey.summary: note,
                WorkoutSessionManager.MetadataKey.skipped: warmUpSkipped ? "true" : "false",
            ])
        }
    }

    func endWorkout() {
        Task {
            await workoutManager.end()
            phase = .finished
            // Personal history goes to the iPhone right away. Study sessions wait for Save & Finish
            // so the researcher's manual counts are included.
            if !AppSettings.isStudyLogging { logSession(references: [:]) }
        }
    }

    func cancel() {
        recordPartialStep()
        flowTask?.cancel()
        stopMotion()
        speech.stop()
        workoutManager.discard()
        logSession(references: [:])
        phase = .home
    }

    /// Returns to the menu; in Study Mode also saves the researcher's manual count as the reference.
    func backHome(references: [Int: Int] = [:]) {
        logSession(references: references)
        phase = .home
    }

    /// Weakly labeled auto-recording (label = instruction), sent to iPhone for the next training run.
    private func saveAutoRecording(_ exercise: Exercise, frames: [MotionFrame]) {
        guard AppSettings.isAutoCollecting, MotionRecordingQuality(frames).rejectionReason() == nil else { return }
        let name = RecordingName(label: MotionLabel(exercise: exercise).rawValue, participant: AppSettings.participant,
                                 wrist: AppSettings.wrist, id: "auto-\(Int(Date().timeIntervalSince1970))")
        let url = TrainingRecorder.directory.appending(path: "\(name.session).csv")
        do {
            try FileManager.default.createDirectory(at: TrainingRecorder.directory, withIntermediateDirectories: true)
            try MotionCSV.encode(frames, name: name).write(to: url, atomically: true, encoding: .utf8)
            PhoneConnector.shared.sendTrainingFile(url)
        } catch {
            // Auto-recording is optional; a failure must never interrupt the warm-up.
        }
    }

    private func recordPartialStep() {
        guard phase == .warmingUp, let step = currentStep else { return }
        stepLogs.append(StepLog(exercise: step.exercise, target: step.target, counted: stepProgress, completed: false))
    }

    // MARK: Evaluation log (Study Mode)
    private func logSession(references: [Int: Int]) {
        guard !sessionLogged, let assessment else { return }
        sessionLogged = true
        // Study fields (participant, wrist, reference scenario) only with Study Mode + consent.
        let study = AppSettings.isStudyLogging

        let outcome: WarmUpOutcome =
            if warmUpSkipped { .skipped }
            else if warmUpCompleted { .completed }
            else if assessment.status == .ready && warmUpStart == nil { .notNeeded }
            else { .abandoned }
        let steps = stepLogs.enumerated().map { index, step -> StepLog in
            var step = step
            if case .reps = step.target { step.referenceReps = references[index] }
            return step
        }
        let entry = SessionLogEntry(
            date: checkStartedAt, participant: study ? AppSettings.participant : nil, wrist: study ? AppSettings.wrist : nil,
            scenario: study ? AppSettings.scenario : .unknown, workout: workout, assessment: assessment, checkLatency: checkLatency,
            classifier: classifierName.isEmpty ? ClassifierFactory.activeClassifierName : classifierName,
            warmUp: outcome, finalConfirmed: finalConfirmed, steps: steps, summary: summaryNote
        )
        do {
            try SessionLogger.append(entry)
        } catch {
            errorMessage = "Couldn't save the workout log: \(error.localizedDescription)"
        }
        // The scenario reference applies to one session only, so it doesn't carry over to the next one by mistake.
        if study { AppSettings.scenario = .unknown }
    }

    private func stopMotion() {
        motion.stop()
        pipeline = nil
    }

    private func resetSession() {
        flowTask?.cancel()
        stopMotion()
        assessment = nil
        message = ""
        isRefiningWithAI = false
        messageFromAI = false
        plan = nil
        activePlan = nil
        cues = []
        heartRateLog = []
        lastKnownHeartRate = nil
        warmUpStart = nil
        warmUpSkipped = false
        summaryNote = nil
        lastPrediction = nil
        lastInferenceMilliseconds = nil
        errorMessage = nil
        stepLogs = []
        checkLatency = 0
        warmUpCompleted = false
        finalConfirmed = nil
        classifierName = ""
        sessionLogged = false
    }
}

#if DEBUG
// MARK: - Screenshot mode (debug builds only)
extension AppFlow {
    /// Launch with `-demoScreen unready|warmup|confirm|ready|workout|finished` to show a screen with sample values,
    /// e.g. `xcrun simctl launch <watch> <bundle-id> -demoScreen warmup`.
    func loadDemoIfRequested() {
        guard let screen = UserDefaults.standard.string(forKey: "demoScreen") else { return }
        demoMode = true
        workout = .outdoorRun
        let demoPlan = planner.plan(exercises: [.marchInPlace, .armCircles], durationMinutes: 5, adjustments: [])
        let hr: (Double) -> HeartRateSample = { HeartRateSample(date: .now, bpm: $0) }
        switch screen {
        case "unready":
            plan = demoPlan
            message = "Your heart rate is still 72 bpm, below the ready zone (126–150 bpm), and you only slept 5.3 hours last night. Let’s do a 5-minute warm-up first (March in Place + Arm Circles) so your muscles don’t cramp."
            lastKnownHeartRate = hr(72)
            phase = .unready
        case "warmup":
            plan = demoPlan
            activePlan = demoPlan
            stepIndex = 0
            stepProgress = 32
            lastKnownHeartRate = hr(104)
            phase = .warmingUp
        case "confirm":
            lastKnownHeartRate = hr(118)
            phase = .confirming
        case "ready":
            message = "Warm-up done! Heart rate 128 bpm is in the ready zone. Enjoy your outdoor run!"
            lastKnownHeartRate = hr(128)
            phase = .ready
        case "workout":
            lastKnownHeartRate = hr(142)
            phase = .workout
        case "finished":
            summaryNote = "5-minute warm-up: HR rose from 72 to 128 bpm, reached the ready zone in 4 min."
            phase = .finished
        case "fail-hr": phase = .failed(.noHeartRate)
        case "fail-health": phase = .failed(.healthAccess)
        case "fail-motion": phase = .failed(.motionUnavailable)
        case "endtest":
            // Simulates a finished workout and logs it, to check that the history reaches the iPhone.
            let zones = HeartRateZones(physiology: UserPhysiology(age: 30, restingHR: 65))
            assessment = readiness.evaluate(ReadinessInput(currentHR: hr(72), history: [], recentActiveEnergy: nil, zones: zones, now: .now))
            warmUpStart = .now
            warmUpCompleted = true
            finalConfirmed = true
            summaryNote = "5-minute warm-up: HR rose from 72 to 128 bpm, reached the ready zone in 4 min."
            phase = .finished
            logSession(references: [:])
        default:
            break
        }
    }
}
#endif
