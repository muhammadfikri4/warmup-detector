import Foundation
import WarmUpCore

/// Menyambungkan sampel 50 Hz → sliding window 2 detik → classifier → GuidedWarmUpEngine.
/// Seluruh pemrosesan berjalan di antrean serial MotionSampler (bukan main thread) agar
/// latensi inferensi + umpan balik tetap < 200 ms (NFR-02). Hasil dikirim ke UI lewat `onUpdate`.
nonisolated final class MotionPipeline: @unchecked Sendable {
    struct Update: Sendable {
        var events: [GuidedWarmUpEngine.Event]
        var prediction: MotionPrediction?
        var inferenceMilliseconds: Double?
        /// Data sensor satu gerakan yang selesai (untuk rekaman otomatis), di luar periode dijeda.
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
        self.window = SlidingWindow(size: classifier.windowSize, hop: 25) // inferensi tiap 0,5 detik
        self.onUpdate = onUpdate
    }

    func process(_ frame: MotionFrame) {
        var update = Update(events: [], prediction: nil, inferenceMilliseconds: nil, completedStep: nil)
        // Label rekaman otomatis = gerakan yang diinstruksikan; periode dijeda (diam) tidak ikut.
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

/// Mengukur intensitas gerak selama pengecekan awal (≈ 2 detik) — konteks tambahan untuk penjelasan.
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
