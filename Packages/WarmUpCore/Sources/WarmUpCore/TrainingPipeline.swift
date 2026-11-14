import Foundation

/// One recording for training. Automatic recordings (from guided warm-ups) are weakly labeled:
/// the label = the INSTRUCTED exercise, not the model's prediction.
public struct TrainingRecording: Sendable {
    public var name: RecordingName
    public var frames: [MotionFrame]

    public init(name: RecordingName, frames: [MotionFrame]) {
        self.name = name
        self.frames = frames
    }

    public var person: String { name.participant ?? "?" }
    public var isAuto: Bool { name.isAuto }
}

public struct TrainingConfiguration: Sendable {
    /// Participants LOCKED for testing and never used for training.
    public var goldenParticipants: Set<String> = []
    /// Weight of automatic (weakly labeled) data relative to manual data.
    public var autoWeight = 0.5
    /// Window cap per participant per label, so one person doesn't dominate.
    public var maxWindowsPerPersonLabel = 300
    public var minimumAccuracy = 0.85
    public var trimSeconds: TimeInterval = 1
    public var windowSize = 100
    public var hop = 50
    public var trainer = SoftmaxTrainer()

    public init() {}
}

public struct TrainingResult: Sendable {
    public var rejected: [(file: String, reason: String)] = []
    public var summary: [String] = []
    public var evaluationKind = ""
    public var candidate = ClassificationReport()
    public var baseline = ClassificationReport()
    /// The model currently active on the watch, tested on the same test data.
    public var current: ClassificationReport?
    public var model: SoftmaxModel?
    public var promote = false
    public var reasons: [String] = []

    public func formatted() -> String {
        var l: [String] = ["== 1–2. Collect & Clean =="] + summary
        for r in rejected { l.append("  ✘ \(r.file): \(r.reason)") }
        l += ["", "== 3–4. Features & Model ==",
              "Logistic regression, \(MotionFeatureVector.names.count) features per 2-second window.",
              "", "== 5. Evaluate: \(evaluationKind) ==",
              baseline.formatted(title: "Heuristic baseline"), "",
              candidate.formatted(title: "New model")]
        if let current { l += ["", current.formatted(title: "Current active model")] }
        l += ["", promote ? "✔ READY to send to the watch" : "✘ NOT sent"] + reasons.map { "  • \($0)" }
        return l.joined(separator: "\n")
    }
}

/// Training pipeline on iPhone: Clean → Features → Model → Evaluate → promotion decision.
public enum TrainingPipeline {
    struct Window {
        var features: [Double]
        var label: String
        var person: String
        var weight: Double
        var heuristic: String
        var current: String?
    }

    public static func run(recordings: [TrainingRecording], current: SoftmaxModel?,
                           configuration config: TrainingConfiguration = TrainingConfiguration(),
                           now: Date = .now) -> TrainingResult {
        var result = TrainingResult()
        // Whole seconds: model version = epoch seconds, and ISO-8601 doesn't store fractional seconds.
        let now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let heuristic = HeuristicMotionClassifier()
        let currentModel = current.flatMap { $0.isCompatible ? $0 : nil }

        // 2. Clean + 3. Features
        var windows: [Window] = []
        var perGroup: [String: [Window]] = [:]
        for r in recordings {
            if let reason = MotionRecordingQuality(r.frames).rejectionReason() {
                result.rejected.append((r.name.session, reason))
                continue
            }
            let start = r.frames.first!.timestamp + config.trimSeconds
            let end = r.frames.last!.timestamp - config.trimSeconds
            let frames = r.frames.filter { $0.timestamp >= start && $0.timestamp <= end }
            let label = MotionLabel(classLabel: r.name.label).rawValue
            var i = 0
            while i + config.windowSize <= frames.count {
                let slice = Array(frames[i..<(i + config.windowSize)])
                let features = MotionFeatureVector.extract(slice)
                let window = Window(features: features, label: label, person: r.person,
                                    weight: r.isAuto ? config.autoWeight : 1,
                                    heuristic: heuristic.classify(slice).map { $0.label.rawValue } ?? "other",
                                    current: currentModel.map { MotionLabel(classLabel: $0.predict(features).label).rawValue })
                perGroup["\(r.person)|\(label)", default: []].append(window)
                i += config.hop
            }
        }
        for (_, group) in perGroup.sorted(by: { $0.key < $1.key }) {
            if group.count <= config.maxWindowsPerPersonLabel {
                windows += group
            } else {
                let stride = Double(group.count) / Double(config.maxWindowsPerPersonLabel)
                windows += (0..<config.maxWindowsPerPersonLabel).map { group[Int(Double($0) * stride)] }
            }
        }

        let people = Set(windows.map(\.person)).sorted()
        let labels = Set(windows.map(\.label)).sorted()
        let autoCount = recordings.filter(\.isAuto).count
        result.summary.append("\(recordings.count) recordings (\(autoCount) automatic), \(result.rejected.count) rejected, \(windows.count) windows")
        result.summary.append("Participants: \(people.joined(separator: ", ")); labels: \(labels.joined(separator: ", "))")

        guard labels.count >= 2 else {
            result.reasons.append("Needs at least 2 labels.")
            return result
        }

        func train(_ items: [Window], evaluation: String, accuracy: Double?) -> SoftmaxModel {
            config.trainer.train(features: items.map(\.features), labels: items.map(\.label), sampleWeights: items.map(\.weight),
                                 info: .init(trainedAt: now, trainingWindows: items.count,
                                             participants: Set(items.map(\.person)).sorted(),
                                             evaluation: evaluation, accuracy: accuracy))
        }
        func evaluate(_ model: SoftmaxModel, on test: [Window]) {
            for w in test {
                result.candidate.add(truth: w.label, predicted: MotionLabel(classLabel: model.predict(w.features).label).rawValue)
                result.baseline.add(truth: w.label, predicted: w.heuristic)
                if let c = w.current {
                    if result.current == nil { result.current = ClassificationReport() }
                    result.current!.add(truth: w.label, predicted: c)
                }
            }
        }

        // 5. Evaluate
        let golden = config.goldenParticipants.intersection(people)
        let trainable = windows.filter { !golden.contains($0.person) }
        if !golden.isEmpty {
            result.evaluationKind = "golden set \(golden.sorted().joined(separator: ", ")) (never used for training)"
            guard Set(trainable.map(\.label)).count >= 2 else {
                result.reasons.append("Training data outside the golden set has fewer than 2 labels.")
                return result
            }
            evaluate(train(trainable, evaluation: "", accuracy: nil), on: windows.filter { golden.contains($0.person) })
        } else {
            let known = people.filter { $0 != "?" }
            guard known.count >= 2 else {
                result.evaluationKind = "not possible (participants < 2)"
                result.reasons.append("Needs ≥ 2 participants to test on new people.")
                return result
            }
            result.evaluationKind = "leave-one-person-out (\(known.count) fold)"
            for person in known {
                let foldTrain = windows.filter { $0.person != person }
                guard Set(foldTrain.map(\.label)).count >= 2 else { continue }
                evaluate(train(foldTrain, evaluation: "", accuracy: nil), on: windows.filter { $0.person == person })
            }
        }

        // Final model: all data EXCEPT the golden set.
        let accuracy = result.candidate.accuracy
        result.model = train(trainable, evaluation: "\(result.evaluationKind), accuracy \(pct(accuracy))", accuracy: accuracy)

        // Promotion decision.
        let comparator = result.current ?? result.baseline
        let comparatorName = result.current == nil ? "heuristic baseline" : "active model"
        let ok = (accuracy ?? 0) >= config.minimumAccuracy
        let better = (accuracy ?? 0) >= (comparator.accuracy ?? 0)
        result.reasons.append("Accuracy \(pct(accuracy)) \(ok ? "≥" : "<") \(pct(config.minimumAccuracy)) (NFR-03)")
        result.reasons.append("\(better ? "≥" : "<") \(comparatorName) \(pct(comparator.accuracy)) on the same test data")
        result.promote = ok && better
        return result
    }
}
