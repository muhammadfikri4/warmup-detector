import Foundation
import Observation
import WarmUpCore

/// Orkestrator alur end-to-end (PRD §2):
/// Workout Trigger → Akuisisi Awal → Evaluasi Kesiapan → Peringatan & Rencana → Guided Warm-Up → Konfirmasi Akhir.
@Observable
final class AppFlow {
    enum Phase: Equatable {
        case home, checking, unready, warmingUp, confirming, ready, workout, finished
    }

    // MARK: State untuk UI
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
    /// Hasil tiap gerakan (dihitung app) — dibandingkan dengan hitungan manual di Mode Studi.
    private(set) var stepLogs: [StepLog] = []
    var errorMessage: String?

    var isStudyLogging: Bool { AppSettings.isStudyLogging }

    var heartRate: Double? { workoutManager.latestHeartRate?.bpm }
    var zones: HeartRateZones? { assessment?.zones }
    var currentStep: WarmUpStep? { activePlan.flatMap { stepIndex < $0.steps.count ? $0.steps[stepIndex] : nil } }

    // MARK: Dependensi
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

    // MARK: Izin
    func prepare() async {
        guard !authorized, health.isAvailable else { return }
        do {
            try await health.requestAuthorization()
            authorized = true
        } catch {
            errorMessage = "Izin HealthKit diperlukan untuk membaca detak jantung."
        }
    }

    // MARK: 1–3. Trigger, akuisisi awal, evaluasi kesiapan (≤ 3 detik)
    func start(_ kind: WorkoutKind) {
        resetSession()
        workout = kind
        phase = .checking
        checkStartedAt = Date()
        flowTask = Task { await runReadinessCheck() }
    }

    private func runReadinessCheck() async {
        await prepare()
        let startedAt = Date()
        do {
            try await workoutManager.start(workout)
        } catch {
            errorMessage = "Gagal memulai sesi workout: \(error.localizedDescription)"
            phase = .home
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
        let zones = HeartRateZones(physiology: recovery.physiology, configuration: AppSettings.zoneConfiguration)
        let result = readiness.evaluate(ReadinessInput(currentHR: live, history: samples, recentActiveEnergy: kcal,
                                                       zones: zones, now: .now))
        assessment = result
        checkLatency = Date().timeIntervalSince(checkStartedAt)

        if result.status == .ready {
            message = TemplateCoach.readyMessage(workout: workout, heartRate: result.heartRate, zones: zones, afterWarmUp: false)
            showReady()
        } else {
            presentUnready(result, recovery: recovery)
        }
    }

    // MARK: 4. Peringatan & rencana
    private func presentUnready(_ result: ReadinessAssessment, recovery: RecoveryContext) {
        let basePlan = planner.plan(for: recovery)
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
            plan = suggestion.plan
            cues = suggestion.cues
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
            errorMessage = "Sensor gerak tidak tersedia di perangkat ini."
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
                Haptics.play(.success) // FR-P05: haptik sukses + chime sistem
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

    // MARK: 6. Konfirmasi akhir
    private func finishWarmUp() {
        stopMotion() // NFR-01: matikan sensor 50 Hz segera
        phase = .confirming
        confirmTimedOut = false
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

    // MARK: Latihan inti
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
                ? "Sudah siap saat mulai (HR \(heartRate.map { "\(Int($0))" } ?? "–") bpm), tanpa pemanasan tambahan."
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

    /// Kembali ke menu; di Mode Studi sekaligus menyimpan hitungan manual peneliti sebagai referensi.
    func backHome(references: [Int: Int] = [:]) {
        logSession(references: references)
        phase = .home
    }

    /// Rekaman otomatis berlabel lemah (label = instruksi), dikirim ke iPhone untuk training berikutnya.
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
            // Rekaman otomatis bersifat opsional; kegagalan tidak boleh mengganggu pemanasan.
        }
    }

    private func recordPartialStep() {
        guard phase == .warmingUp, let step = currentStep else { return }
        stepLogs.append(StepLog(exercise: step.exercise, target: step.target, counted: stepProgress, completed: false))
    }

    // MARK: Log evaluasi (Mode Studi)
    private func logSession(references: [Int: Int]) {
        guard AppSettings.isStudyLogging, !sessionLogged, let assessment else { return }
        sessionLogged = true

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
            date: checkStartedAt, participant: AppSettings.participant, wrist: AppSettings.wrist,
            scenario: AppSettings.scenario, workout: workout, assessment: assessment, checkLatency: checkLatency,
            classifier: classifierName.isEmpty ? ClassifierFactory.activeClassifierName : classifierName,
            warmUp: outcome, finalConfirmed: finalConfirmed, steps: steps
        )
        do {
            try SessionLogger.append(entry)
        } catch {
            errorMessage = "Gagal menyimpan log evaluasi: \(error.localizedDescription)"
        }
        // Referensi skenario berlaku untuk satu sesi saja, supaya tidak terbawa salah ke sesi berikutnya.
        AppSettings.scenario = .unknown
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
