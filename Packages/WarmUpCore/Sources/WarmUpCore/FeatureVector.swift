import Foundation

/// Pipeline stage 3 (Features) for the model trained on iPhone:
/// numeric summary per 2-second window, computed identically on iPhone (training) and watch (inference).
public enum MotionFeatureVector {
    private static let channels: [(String, @Sendable (MotionFrame) -> Double)] = [
        ("acc_x", { $0.userAcceleration.x }), ("acc_y", { $0.userAcceleration.y }), ("acc_z", { $0.userAcceleration.z }),
        ("rot_x", { $0.rotationRate.x }), ("rot_y", { $0.rotationRate.y }), ("rot_z", { $0.rotationRate.z }),
        ("grav_x", { $0.gravity.x }), ("grav_y", { $0.gravity.y }), ("grav_z", { $0.gravity.z }),
        ("acc_mag", { $0.userAcceleration.magnitude }), ("rot_mag", { $0.rotationRate.magnitude }), ("yaw", { $0.yawRate }),
    ]
    /// Channels whose oscillation frequency is computed (Hz estimated from the mean-crossing rate).
    private static let frequencyChannels = ["acc_mag", "rot_mag", "yaw"]

    public static let names: [String] =
        channels.flatMap { ["\($0.0)_mean", "\($0.0)_std"] }
        + frequencyChannels.map { "\($0)_hz" }
        + ["yaw_fraction", "gravity_range"]

    public static func extract(_ frames: [MotionFrame]) -> [Double] {
        guard frames.count >= 2 else { return Array(repeating: 0, count: names.count) }
        let n = Double(frames.count)
        let duration = max(frames.last!.timestamp - frames.first!.timestamp, 1e-3)
        var result: [Double] = []
        result.reserveCapacity(names.count)
        var series: [String: [Double]] = [:]

        for (name, value) in channels {
            let v = frames.map(value)
            let mean = v.reduce(0, +) / n
            let std = (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n).squareRoot()
            result += [mean, std]
            if frequencyChannels.contains(name) { series[name] = v.map { $0 - mean } }
        }
        for name in frequencyChannels {
            let centered = series[name]!
            let crossings = zip(centered, centered.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
            result.append(Double(crossings) / 2 / duration)
        }
        let summary = MotionFeatures(frames)
        result += [summary.yawFraction, summary.gravityRange]
        return result
    }
}
