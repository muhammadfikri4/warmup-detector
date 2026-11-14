import Foundation

public struct Vector3: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(0, 0, 0)
    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
    public func dot(_ o: Vector3) -> Double { x * o.x + y * o.y + z * o.z }
    public subscript(axis: Int) -> Double { axis == 0 ? x : (axis == 1 ? y : z) }
}

/// Satu sampel CMDeviceMotion (50 Hz). Satuan: g untuk akselerasi/gravitasi, rad/s untuk rotasi.
public struct MotionFrame: Codable, Sendable, Equatable {
    public var timestamp: TimeInterval
    public var userAcceleration: Vector3
    public var rotationRate: Vector3
    public var gravity: Vector3

    public init(timestamp: TimeInterval, userAcceleration: Vector3, rotationRate: Vector3, gravity: Vector3) {
        self.timestamp = timestamp
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
        self.gravity = gravity
    }

    /// Kecepatan rotasi di sekitar sumbu vertikal (yaw) — dominan saat Torso Twist.
    public var yawRate: Double {
        let g = gravity.magnitude
        return g > 0.1 ? rotationRate.dot(gravity) / g : 0
    }
}

public struct MotionPrediction: Codable, Sendable, Equatable {
    public var label: MotionLabel
    public var confidence: Double
    public var timestamp: TimeInterval

    public init(label: MotionLabel, confidence: Double, timestamp: TimeInterval) {
        self.label = label
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

/// Kontrak classifier gerakan. Implementasi: CoreML (`WarmUpClassifier.mlmodel`) atau heuristik fallback.
public protocol MotionClassifying: AnyObject {
    var name: String { get }
    /// Jumlah sampel per jendela prediksi (2 detik × 50 Hz = 100).
    var windowSize: Int { get }
    func classify(_ window: [MotionFrame]) -> MotionPrediction?
}

/// Buffer sliding window berukuran tetap dengan hop (jarak antar inferensi).
public struct SlidingWindow: Sendable {
    public let size: Int
    public let hop: Int
    private var buffer: [MotionFrame] = []
    private var sinceLastEmit = 0

    public init(size: Int = 100, hop: Int = 25) {
        self.size = size
        self.hop = hop
        buffer.reserveCapacity(size + 1)
    }

    /// Menambahkan sampel; mengembalikan isi jendela bila sudah waktunya inferensi.
    public mutating func append(_ frame: MotionFrame) -> [MotionFrame]? {
        buffer.append(frame)
        if buffer.count > size { buffer.removeFirst(buffer.count - size) }
        sinceLastEmit += 1
        guard buffer.count == size, sinceLastEmit >= hop else { return nil }
        sinceLastEmit = 0
        return buffer
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        sinceLastEmit = 0
    }
}

/// Fitur ringkas dari satu jendela, dipakai classifier heuristik dan pengukur intensitas awal.
public struct MotionFeatures: Sendable, Equatable {
    public var accelerationMean: Double
    public var accelerationStd: Double
    public var rotationMean: Double
    /// Porsi rotasi di sekitar sumbu vertikal (0–1).
    public var yawFraction: Double
    /// Jumlah rentang (max − min) komponen gravitasi di tiga sumbu — besar saat orientasi pergelangan berputar penuh.
    public var gravityRange: Double

    public init(_ frames: [MotionFrame]) {
        let n = Double(max(frames.count, 1))
        let acc = frames.map(\.userAcceleration.magnitude)
        let rot = frames.map(\.rotationRate.magnitude)
        let accMean = acc.reduce(0, +) / n
        let rotMean = rot.reduce(0, +) / n
        let yaw = frames.map { abs($0.yawRate) }.reduce(0, +) / n
        accelerationMean = accMean
        accelerationStd = (acc.map { ($0 - accMean) * ($0 - accMean) }.reduce(0, +) / n).squareRoot()
        rotationMean = rotMean
        yawFraction = rotMean > 0.05 ? min(1, yaw / rotMean) : 0
        gravityRange = (0..<3).map { axis -> Double in
            let values = frames.map { $0.gravity[axis] }
            return (values.max() ?? 0) - (values.min() ?? 0)
        }.reduce(0, +)
    }
}
