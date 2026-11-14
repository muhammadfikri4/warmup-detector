import Foundation

/// Pillar 2 — Repetition Counting & Anti-Cheat (FR-P04) and Milestone Completion (FR-P05).
///
/// - Reps/active duration only increase when the latest prediction = the instructed exercise
///   with confidence ≥ 80%.
/// - Idle > 5 seconds → counting paused + reminder event (repeated every `reminderInterval`).
/// - Target reached → `stepCompleted`, then automatically move on to the next exercise.
public final class GuidedWarmUpEngine {
    public enum Event: Sendable, Equatable {
        case stepStarted(index: Int)
        case progress(index: Int, value: Double, target: Double)
        case paused(index: Int)
        case idleReminder(index: Int)
        case resumed(index: Int)
        case stepCompleted(index: Int)
        case allCompleted
    }

    public struct Configuration: Sendable {
        public var minimumConfidence: Double = 0.8
        public var idleTimeout: TimeInterval = 5
        public var reminderInterval: TimeInterval = 10
        /// Predictions older than this are stale (they don't open the counting gate).
        public var predictionMaxAge: TimeInterval = 1.5
        public init() {}
    }

    public let plan: WarmUpPlan
    public let configuration: Configuration
    public private(set) var currentIndex = 0
    public private(set) var progressValue: Double = 0
    public private(set) var isPaused = false
    public private(set) var isFinished = false
    public private(set) var lastPrediction: MotionPrediction?

    private var detector: RepetitionDetector
    private var idleSince: TimeInterval?
    private var lastReminder: TimeInterval?
    private var lastFrameTime: TimeInterval?
    private var lastReportedSecond = -1

    public init(plan: WarmUpPlan, configuration: Configuration = Configuration()) {
        precondition(!plan.steps.isEmpty, "Warm-up plan must not be empty")
        self.plan = plan
        self.configuration = configuration
        self.detector = RepetitionDetector(exercise: plan.steps[0].exercise)
    }

    public var currentStep: WarmUpStep? { isFinished ? nil : plan.steps[currentIndex] }

    /// Anti-cheat gate.
    public func isMatching(at time: TimeInterval) -> Bool {
        guard let step = currentStep, let p = lastPrediction else { return false }
        return p.label == MotionLabel(exercise: step.exercise)
            && p.confidence >= configuration.minimumConfidence
            && time - p.timestamp <= configuration.predictionMaxAge
    }

    public func ingest(prediction: MotionPrediction) -> [Event] {
        guard !isFinished else { return [] }
        lastPrediction = prediction
        var events: [Event] = []
        let t = prediction.timestamp

        if prediction.label == .idle {
            if idleSince == nil { idleSince = t }
        } else {
            idleSince = nil
        }

        if let since = idleSince, t - since > configuration.idleTimeout {
            if !isPaused {
                isPaused = true
                lastReminder = t
                events += [.paused(index: currentIndex), .idleReminder(index: currentIndex)]
            } else if let last = lastReminder, t - last >= configuration.reminderInterval {
                lastReminder = t
                events.append(.idleReminder(index: currentIndex))
            }
        } else if isPaused, isMatching(at: t) {
            isPaused = false
            lastReminder = nil
            events.append(.resumed(index: currentIndex))
        }
        return events
    }

    public func ingest(frame: MotionFrame) -> [Event] {
        guard let step = currentStep else { return [] }
        let t = frame.timestamp
        let dt = lastFrameTime.map { min(max(0, t - $0), 0.1) } ?? 0
        lastFrameTime = t
        let counting = !isPaused && isMatching(at: t)

        switch step.target {
        case .reps(let target):
            // The detector always gets samples so its phase stays in sync; the count only increases when the gate passes.
            guard detector.process(frame), counting else { return [] }
            progressValue += 1
            var events: [Event] = [.progress(index: currentIndex, value: progressValue, target: Double(target))]
            if progressValue >= Double(target) { events += advance() }
            return events

        case .duration(let target):
            guard counting else { return [] }
            progressValue += dt
            if progressValue >= target {
                return [.progress(index: currentIndex, value: target, target: target)] + advance()
            }
            let second = Int(progressValue)
            guard second != lastReportedSecond else { return [] }
            lastReportedSecond = second
            return [.progress(index: currentIndex, value: progressValue, target: target)]
        }
    }

    private func advance() -> [Event] {
        var events: [Event] = [.stepCompleted(index: currentIndex)]
        if currentIndex + 1 < plan.steps.count {
            currentIndex += 1
            progressValue = 0
            lastReportedSecond = -1
            idleSince = nil
            isPaused = false
            detector = RepetitionDetector(exercise: plan.steps[currentIndex].exercise)
            events.append(.stepStarted(index: currentIndex))
        } else {
            isFinished = true
            events.append(.allCompleted)
        }
        return events
    }
}
