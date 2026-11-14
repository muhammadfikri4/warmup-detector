import Foundation

/// Counts cycles (1 cycle = 1 rep) in a scalar signal using zero-crossing with hysteresis.
/// A rep is counted when the signal rises above +threshold after previously dropping below −threshold.
public struct CycleCounter: Sendable {
    public var minimumAmplitude: Double
    public var minimumPeriod: TimeInterval

    private var baseline: Double?
    private var smoothed: Double = 0
    private var amplitude: Double = 0
    private var armed = false
    private var lastRepTime: TimeInterval = -.infinity

    public init(minimumAmplitude: Double, minimumPeriod: TimeInterval = 0.6) {
        self.minimumAmplitude = minimumAmplitude
        self.minimumPeriod = minimumPeriod
    }

    /// Returns `true` when this sample closes a cycle.
    public mutating func process(_ value: Double, at time: TimeInterval) -> Bool {
        smoothed = baseline == nil ? value : smoothed + 0.3 * (value - smoothed)
        baseline = baseline.map { $0 + 0.01 * (smoothed - $0) } ?? value
        let centered = smoothed - baseline!
        amplitude = max(abs(centered), amplitude * 0.995)
        let threshold = max(minimumAmplitude, 0.35 * amplitude)

        if centered < -threshold {
            armed = true
        } else if armed, centered > threshold, time - lastRepTime >= minimumPeriod {
            armed = false
            lastRepTime = time
            return true
        }
        return false
    }

    public mutating func reset() { self = CycleCounter(minimumAmplitude: minimumAmplitude, minimumPeriod: minimumPeriod) }
}

/// Picks the most informative signal per exercise and counts its reps.
public struct RepetitionDetector: Sendable {
    public let exercise: Exercise
    private var counter: CycleCounter
    private var axisVariance = [0.0, 0.0, 0.0]
    private var axisMean = [0.0, 0.0, 0.0]
    private var lockedAxis: Int?
    private var samples = 0

    public init(exercise: Exercise) {
        self.exercise = exercise
        switch exercise {
        case .armCircles: counter = CycleCounter(minimumAmplitude: 0.35, minimumPeriod: 0.7)
        case .torsoTwist: counter = CycleCounter(minimumAmplitude: 0.8, minimumPeriod: 0.9)
        case .marchInPlace: counter = CycleCounter(minimumAmplitude: 0.15, minimumPeriod: 0.4)
        }
    }

    public mutating func process(_ frame: MotionFrame) -> Bool {
        let value: Double
        switch exercise {
        case .armCircles:
            // One arm circle = one full cycle of the gravity component on the most variable axis.
            value = frame.gravity[dominantAxis(frame.gravity)]
        case .torsoTwist:
            // Left + right = one cycle of yaw rate.
            value = frame.yawRate
        case .marchInPlace:
            value = frame.userAcceleration.magnitude
        }
        return counter.process(value, at: frame.timestamp)
    }

    private mutating func dominantAxis(_ v: Vector3) -> Int {
        samples += 1
        for axis in 0..<3 {
            let x = v[axis]
            axisMean[axis] += 0.05 * (x - axisMean[axis])
            axisVariance[axis] += 0.05 * ((x - axisMean[axis]) * (x - axisMean[axis]) - axisVariance[axis])
        }
        let best = axisVariance.indices.max { axisVariance[$0] < axisVariance[$1] }!
        if let locked = lockedAxis {
            // Switch axes only when another axis is much more dominant, to avoid false counts.
            if axisVariance[best] > 2 * axisVariance[locked] {
                lockedAxis = best
                counter.reset()
            }
        } else if samples >= 50 {
            lockedAxis = best
        }
        return lockedAxis ?? best
    }
}
