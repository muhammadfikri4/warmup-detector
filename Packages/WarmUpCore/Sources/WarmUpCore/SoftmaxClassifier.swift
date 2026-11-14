import Accelerate
import Foundation

/// Pipeline tahap 4 (Model): multinomial logistic regression — "start simple".
/// Dilatih di iPhone, dikirim ke watch sebagai JSON kecil (tidak perlu kompilasi Core ML di watch).
public struct SoftmaxModel: Codable, Sendable, Equatable {
    public struct Info: Codable, Sendable, Equatable {
        public var trainedAt: Date
        public var trainingWindows: Int
        public var participants: [String]
        public var evaluation: String
        public var accuracy: Double?
    }

    /// Versi = detik epoch saat dilatih.
    public var version: Int
    public var labels: [String]
    public var featureNames: [String]
    public var means: [Double]
    public var scales: [Double]
    /// [kelas][fitur]
    public var weights: [[Double]]
    public var biases: [Double]
    public var info: Info

    public func probabilities(_ features: [Double]) -> [Double] {
        let x = zip(zip(features, means), scales).map { ($0.0 - $0.1) / $1 }
        let logits = zip(weights, biases).map { w, b in zip(w, x).reduce(b) { $0 + $1.0 * $1.1 } }
        let maxLogit = logits.max() ?? 0
        let exps = logits.map { exp($0 - maxLogit) }
        let sum = exps.reduce(0, +)
        return exps.map { $0 / sum }
    }

    public func predict(_ features: [Double]) -> (label: String, confidence: Double) {
        let p = probabilities(features)
        let best = p.indices.max { p[$0] < p[$1] } ?? 0
        return (labels[best], p[best])
    }

    public var isCompatible: Bool { featureNames == MotionFeatureVector.names }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SoftmaxModel {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SoftmaxModel.self, from: data)
    }
}

/// Gradient descent full-batch dengan regularisasi L2. Perkalian matriks memakai Accelerate (vDSP)
/// supaya tetap cepat walau build Debug.
public struct SoftmaxTrainer: Sendable {
    public var epochs = 300
    public var learningRate = 0.5
    public var l2 = 1e-3

    public init() {}

    public func train(features: [[Double]], labels: [String], sampleWeights: [Double]? = nil,
                      info: SoftmaxModel.Info) -> SoftmaxModel {
        let classes = Array(Set(labels)).sorted()
        let n = features.count, f = MotionFeatureVector.names.count, k = classes.count
        precondition(n > 0 && features.allSatisfy { $0.count == f })

        // Standarisasi fitur.
        var means = [Double](repeating: 0, count: f)
        var scales = [Double](repeating: 1, count: f)
        for j in 0..<f {
            let column = features.map { $0[j] }
            let mean = column.reduce(0, +) / Double(n)
            let std = (column.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n)).squareRoot()
            means[j] = mean
            scales[j] = std > 1e-6 ? std : 1
        }
        var x = [Double](repeating: 0, count: n * f) // N×F
        for i in 0..<n { for j in 0..<f { x[i * f + j] = (features[i][j] - means[j]) / scales[j] } }

        let classIndex = Dictionary(uniqueKeysWithValues: classes.enumerated().map { ($1, $0) })
        let y = labels.map { classIndex[$0]! }
        // Bobot sampel × penyeimbang kelas (kelas jarang tidak kalah oleh kelas dominan).
        var classCounts = [Double](repeating: 0, count: k)
        for c in y { classCounts[c] += 1 }
        var w = (0..<n).map { (sampleWeights?[$0] ?? 1) * Double(n) / (Double(k) * classCounts[y[$0]]) }
        let wSum = w.reduce(0, +)
        w = w.map { $0 / wSum }

        var weights = [Double](repeating: 0, count: k * f) // K×F
        var biases = [Double](repeating: 0, count: k)
        var weightsT = [Double](repeating: 0, count: f * k)
        var logits = [Double](repeating: 0, count: n * k)
        var gradT = [Double](repeating: 0, count: k * n)
        var gradW = [Double](repeating: 0, count: k * f)

        for _ in 0..<epochs {
            vDSP_mtransD(weights, 1, &weightsT, 1, vDSP_Length(f), vDSP_Length(k))
            vDSP_mmulD(x, 1, weightsT, 1, &logits, 1, vDSP_Length(n), vDSP_Length(k), vDSP_Length(f)) // N×K
            var gradB = [Double](repeating: 0, count: k)
            for i in 0..<n {
                var maxLogit = -Double.infinity
                for c in 0..<k { logits[i * k + c] += biases[c]; maxLogit = max(maxLogit, logits[i * k + c]) }
                var sum = 0.0
                for c in 0..<k { logits[i * k + c] = exp(logits[i * k + c] - maxLogit); sum += logits[i * k + c] }
                for c in 0..<k {
                    let g = w[i] * (logits[i * k + c] / sum - (c == y[i] ? 1 : 0))
                    gradT[c * n + i] = g
                    gradB[c] += g
                }
            }
            vDSP_mmulD(gradT, 1, x, 1, &gradW, 1, vDSP_Length(k), vDSP_Length(f), vDSP_Length(n)) // K×F
            for idx in 0..<(k * f) { weights[idx] -= learningRate * (gradW[idx] + l2 * weights[idx]) }
            for c in 0..<k { biases[c] -= learningRate * gradB[c] }
        }

        return SoftmaxModel(
            version: Int(info.trainedAt.timeIntervalSince1970), labels: classes, featureNames: MotionFeatureVector.names,
            means: means, scales: scales,
            weights: (0..<k).map { Array(weights[($0 * f)..<(($0 + 1) * f)]) }, biases: biases, info: info
        )
    }
}

/// Classifier watch yang memakai model hasil training di iPhone.
public final class LearnedMotionClassifier: MotionClassifying {
    public let model: SoftmaxModel
    public let windowSize = 100
    public var name: String { "Model iPhone v\(model.version)" }

    public init?(model: SoftmaxModel) {
        guard model.isCompatible else { return nil }
        self.model = model
    }

    public func classify(_ window: [MotionFrame]) -> MotionPrediction? {
        guard window.count >= windowSize, let last = window.last else { return nil }
        let (label, confidence) = model.predict(MotionFeatureVector.extract(Array(window.suffix(windowSize))))
        return MotionPrediction(label: MotionLabel(classLabel: label), confidence: confidence, timestamp: last.timestamp)
    }
}
