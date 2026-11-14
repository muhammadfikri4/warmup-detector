import Foundation

/// Classifier berbasis aturan sebagai fallback sampai `WarmUpClassifier.mlmodel` (CreateML) dilatih.
/// Akurasinya TIDAK ditargetkan memenuhi NFR-03 (≥ 85%); itu tugas model CreateML.
///
/// Intuisi fisik (jam di pergelangan kiri/kanan):
/// - Arm Circles  → orientasi pergelangan berputar penuh → rentang gravitasi besar, rotasi tinggi.
/// - Torso Twist  → pergelangan berayun horizontal → rotasi didominasi sumbu vertikal (yaw).
/// - March/High Knees → ayunan lengan ritmis → akselerasi sedang, rotasi non-yaw.
/// - Idle → akselerasi & rotasi hampir nol.
public final class HeuristicMotionClassifier: MotionClassifying {
    public let name = "Heuristik (fallback)"
    public let windowSize: Int

    public init(windowSize: Int = 100) {
        self.windowSize = windowSize
    }

    public func classify(_ window: [MotionFrame]) -> MotionPrediction? {
        guard let last = window.last else { return nil }
        let f = MotionFeatures(window)
        let (label, confidence) = Self.decide(f)
        return MotionPrediction(label: label, confidence: confidence, timestamp: last.timestamp)
    }

    static func decide(_ f: MotionFeatures) -> (MotionLabel, Double) {
        let idle = min(above(0.06, f.accelerationMean, scale: -0.015), above(0.6, f.rotationMean, scale: -0.15))
        if idle >= 0.5 { return (.idle, idle) }

        let arm = min(above(2.0, f.gravityRange, scale: 0.25), above(2.0, f.rotationMean, scale: 0.4))
        let twist = min(above(0.55, f.yawFraction, scale: 0.06), above(1.0, f.rotationMean, scale: 0.25))
        let march = min(above(0.08, f.accelerationMean, scale: 0.03), above(0.5, 1 - f.yawFraction, scale: 0.08))

        let candidates: [(MotionLabel, Double)] = [(.armCircles, arm), (.torsoTwist, twist), (.marchInPlace, march)]
        let best = candidates.max { $0.1 < $1.1 }!
        return best.1 >= 0.5 ? best : (.other, 1 - best.1)
    }

    /// Sigmoid: 0,5 tepat di ambang; mendekati 1 bila nilai jauh di atas ambang (atau di bawah bila scale negatif).
    private static func above(_ threshold: Double, _ value: Double, scale: Double) -> Double {
        1 / (1 + exp(-(value - threshold) / scale))
    }
}
