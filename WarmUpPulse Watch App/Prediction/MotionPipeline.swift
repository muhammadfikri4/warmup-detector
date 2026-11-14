import Foundation
import WarmUpCore

/// Connects 50 Hz samples → 2-second sliding window → classifier → GuidedWarmUpEngine.
/// All processing runs on MotionSampler's serial queue (not the main thread) so
/// inference + feedback latency stays < 200 ms (NFR-02). Results reach the UI via `onUpdate`.
nonisolated final class MotionPipeline: @unchecked Sendable {
    struct Update: Sendable {
        var events: [GuidedWarmUpEngine.Event]
        var prediction: MotionPrediction?
        var inferenceMilliseconds: Double?
        /// Sensor data for one completed exercise (for auto-recording), excluding paused periods.
        var completedStep: (exercise: Exercise, frames: [MotionFrame])?
    }

    private let engine: GuidedWarmUpEngine
    private let classifier: any MotionClassifying
    private var window: SlidingWindow
    private let onUpdate: @Sendable (Update) -> Void
    private let collectFrames: Bool
    private var stepFrames: [MotionFrame] = []

    init(plan: WarmUpPlan, classifier: any MotionClassifying = ClassifierFactory.make(), collectFrames: Bool = false,
         onUpdate: @escaping @Sendable (Update) -> Void) {
        self.engine = GuidedWarmUpEngine(plan: plan)
        self.collectFrames = collectFrames
        self.classifier = classifier
        self.window = SlidingWindow(size: classifier.windowSize, hop: 25) // inference every 0.5 seconds
        self.onUpdate = onUpdate
    }

    func process(_ frame: MotionFrame) {
        var update = Update(events: [], prediction: nil, inferenceMilliseconds: nil, completedStep: nil)
        // Auto-recording label = the instructed exercise; paused (idle) periods are left out.
        if collectFrames, !engine.isPaused { stepFrames.append(frame) }
        if let samples = window.append(frame) {
            let started = DispatchTime.now().uptimeNanoseconds
            if let prediction = classifier.classify(samples) {
                update.inferenceMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                update.prediction = prediction
                update.events += engine.ingest(prediction: prediction)
            }
        }
        update.events += engine.ingest(frame: frame)
        if collectFrames {
            for case .stepCompleted(let index) in update.events {
                update.completedStep = (engine.plan.steps[index].exercise, stepFrames)
                stepFrames.removeAll(keepingCapacity: true)
            }
        }
        if !update.events.isEmpty || update.prediction != nil { onUpdate(update) }
    }
}

/// Measures motion intensity during the initial check (≈ 2 seconds) — extra context for the explanation.
nonisolated final class MotionIntensityMeter: @unchecked Sendable {
    private var frames: [MotionFrame] = []
    private let lock = NSLock()

    func add(_ frame: MotionFrame) {
        lock.withLock { frames.append(frame) }
    }

    var features: MotionFeatures? {
        lock.withLock { frames.count >= 25 ? MotionFeatures(frames) : nil }
    }
}
