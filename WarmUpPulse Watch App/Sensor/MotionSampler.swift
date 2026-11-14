import CoreMotion
import Foundation
import WarmUpCore

/// FR-S03 — CMMotionManager 50 Hz (userAcceleration + rotationRate + gravity).
/// NFR-01: pemanggil wajib `stop()` begitu Guided Warm-Up selesai.
nonisolated final class MotionSampler: @unchecked Sendable {
    static let sampleRate = 50.0

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "WarmUpPulse.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isRunning: Bool { manager.isDeviceMotionActive }

    /// `handler` dipanggil di antrean serial latar belakang (bukan main thread).
    @discardableResult
    func start(handler: @escaping @Sendable (MotionFrame) -> Void) -> Bool {
        guard manager.isDeviceMotionAvailable else { return false }
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        manager.deviceMotionUpdateInterval = 1 / Self.sampleRate
        manager.startDeviceMotionUpdates(to: queue) { motion, _ in
            guard let motion else { return }
            handler(MotionFrame(
                timestamp: motion.timestamp,
                userAcceleration: Vector3(motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z),
                rotationRate: Vector3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z),
                gravity: Vector3(motion.gravity.x, motion.gravity.y, motion.gravity.z)
            ))
        }
        return true
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
