import CoreML
import Foundation
import WarmUpCore

/// FR-P03 — On-device inference with `WarmUpClassifier` (a CreateML Activity Classifier).
///
/// The model is loaded dynamically: just drop `WarmUpClassifier.mlmodel` into the
/// "WarmUpPulse Watch App" folder and Xcode compiles it. Until the model exists,
/// `ClassifierFactory` uses `HeuristicMotionClassifier`.
///
/// Recognized feature column names (case & underscores ignored):
/// acc_x/y/z, rot_x/y/z, grav_x/y/z — same as the CSV header from the Record Data screen.
nonisolated final class CoreMLMotionClassifier: MotionClassifying {
    let name = "CoreML · WarmUpClassifier"
    let windowSize: Int

    private let model: MLModel
    private let featureInputs: [(name: String, extract: (MotionFrame) -> Double)]
    private let stateInputName: String?
    private let labelName: String
    private let probabilityName: String?
    private var state: MLMultiArray?

    init?(bundle: Bundle = .main, resource: String = "WarmUpClassifier") {
        guard let url = bundle.url(forResource: resource, withExtension: "mlmodelc") else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: config) else { return nil }
        let description = model.modelDescription

        var features: [(String, (MotionFrame) -> Double)] = []
        var window = 100
        var stateName: String?
        for (name, input) in description.inputDescriptionsByName {
            if name.lowercased().hasPrefix("state") {
                stateName = name
                continue
            }
            guard let extract = Self.extractor(for: name) else { return nil }
            features.append((name, extract))
            if let shape = input.multiArrayConstraint?.shape.first?.intValue { window = shape }
        }
        guard !features.isEmpty, let label = description.predictedFeatureName else { return nil }

        self.model = model
        self.featureInputs = features
        self.windowSize = window
        self.stateInputName = stateName
        self.labelName = label
        self.probabilityName = description.predictedProbabilitiesName
        if let stateName, let constraint = description.inputDescriptionsByName[stateName]?.multiArrayConstraint {
            state = try? MLMultiArray(shape: constraint.shape, dataType: .double)
            if let state { for i in 0..<state.count { state[i] = 0 } }
        }
    }

    func classify(_ window: [MotionFrame]) -> MotionPrediction? {
        guard window.count >= windowSize, let last = window.last else { return nil }
        let frames = window.suffix(windowSize)
        var inputs: [String: MLFeatureValue] = [:]
        for (name, extract) in featureInputs {
            guard let array = try? MLMultiArray(shape: [NSNumber(value: windowSize)], dataType: .double) else { return nil }
            for (i, frame) in frames.enumerated() { array[i] = NSNumber(value: extract(frame)) }
            inputs[name] = MLFeatureValue(multiArray: array)
        }
        if let stateInputName, let state { inputs[stateInputName] = MLFeatureValue(multiArray: state) }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: inputs),
              let output = try? model.prediction(from: provider),
              let label = output.featureValue(for: labelName)?.stringValue else { return nil }

        if let next = output.featureNames.first(where: { $0.lowercased().hasPrefix("stateout") }) {
            state = output.featureValue(for: next)?.multiArrayValue
        }
        let probabilities = probabilityName.flatMap { output.featureValue(for: $0)?.dictionaryValue }
        let confidence = probabilities?[label as NSString]?.doubleValue ?? (probabilities?[label]?.doubleValue ?? 0)
        return MotionPrediction(label: MotionLabel(classLabel: label), confidence: confidence, timestamp: last.timestamp)
    }

    private static func extractor(for featureName: String) -> ((MotionFrame) -> Double)? {
        switch featureName.lowercased().replacingOccurrences(of: "_", with: "") {
        case "accx", "useraccelerationx": { $0.userAcceleration.x }
        case "accy", "useraccelerationy": { $0.userAcceleration.y }
        case "accz", "useraccelerationz": { $0.userAcceleration.z }
        case "rotx", "rotationratex", "gyrox": { $0.rotationRate.x }
        case "roty", "rotationratey", "gyroy": { $0.rotationRate.y }
        case "rotz", "rotationratez", "gyroz": { $0.rotationRate.z }
        case "gravx", "gravityx": { $0.gravity.x }
        case "gravy", "gravityy": { $0.gravity.y }
        case "gravz", "gravityz": { $0.gravity.z }
        default: nil
        }
    }
}

/// Priority: model sent from iPhone → bundled CoreML model (CreateML path on Mac) → heuristic.
enum ClassifierFactory {
    nonisolated static func make() -> any MotionClassifying {
        if let model = ModelStore.load(), let learned = LearnedMotionClassifier(model: model) { return learned }
        return CoreMLMotionClassifier() ?? HeuristicMotionClassifier()
    }

    static var activeClassifierName: String { make().name }
}
