import Foundation

/// Rule-based classifier used as the fallback until `WarmUpClassifier.mlmodel` (CreateML) is trained.
/// Its accuracy is NOT expected to meet NFR-03 (≥ 85%); that is the CreateML model's job.
///
/// Physical intuition (watch on the left/right wrist):
/// - Arm Circles  → wrist orientation rotates fully → large gravity range, high rotation.
/// - Torso Twist  → wrist swings horizontally → rotation dominated by the vertical axis (yaw).
/// - March/High Knees → rhythmic arm swing → moderate acceleration, non-yaw rotation.
/// - Idle → acceleration & rotation near zero.
public final class HeuristicMotionClassifier: MotionClassifying {
    public let name = "Heuristic (fallback)"
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

    /// Sigmoid: 0.5 exactly at the threshold; approaches 1 when the value is far above it (or below, if scale is negative).
    private static func above(_ threshold: Double, _ value: Double, scale: Double) -> Double {
        1 / (1 + exp(-(value - threshold) / scale))
    }
}
