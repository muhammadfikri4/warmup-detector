import Foundation

/// Satu rekaman untuk training. Rekaman otomatis (dari pemanasan terpandu) berlabel lemah:
/// labelnya = gerakan yang DIINSTRUKSIKAN, bukan hasil prediksi model.
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
    /// Partisipan yang DIKUNCI untuk pengujian dan tidak pernah dipakai melatih.
    public var goldenParticipants: Set<String> = []
    /// Bobot data otomatis (label lemah) relatif terhadap data manual.
    public var autoWeight = 0.5
    /// Batas jendela per partisipan per label, supaya satu orang tidak mendominasi.
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
    /// Model yang sedang aktif di watch, diuji pada data uji yang sama.
    public var current: ClassificationReport?
    public var model: SoftmaxModel?
    public var promote = false
    public var reasons: [String] = []

    public func formatted() -> String {
        var l: [String] = ["== 1–2. Collect & Clean =="] + summary
        for r in rejected { l.append("  ✘ \(r.file): \(r.reason)") }
        l += ["", "== 3–4. Features & Model ==",
              "Logistic regression, \(MotionFeatureVector.names.count) fitur per jendela 2 dtk.",
              "", "== 5. Evaluate: \(evaluationKind) ==",
              baseline.formatted(title: "Baseline heuristik"), "",
              candidate.formatted(title: "Model baru")]
        if let current { l += ["", current.formatted(title: "Model aktif saat ini")] }
        l += ["", promote ? "✔ LAYAK dikirim ke watch" : "✘ TIDAK dikirim"] + reasons.map { "  • \($0)" }
        return l.joined(separator: "\n")
    }
}

/// Pipeline training di iPhone: Clean → Features → Model → Evaluate → keputusan promosi.
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
        // Detik penuh: versi model = epoch detik, dan ISO-8601 tidak menyimpan pecahan detik.
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
        result.summary.append("\(recordings.count) rekaman (\(autoCount) otomatis), \(result.rejected.count) ditolak, \(windows.count) jendela")
        result.summary.append("Partisipan: \(people.joined(separator: ", ")); label: \(labels.joined(separator: ", "))")

        guard labels.count >= 2 else {
            result.reasons.append("Butuh minimal 2 label.")
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
            result.evaluationKind = "golden set \(golden.sorted().joined(separator: ", ")) (tidak pernah dipakai melatih)"
            guard Set(trainable.map(\.label)).count >= 2 else {
                result.reasons.append("Data latih di luar golden set kurang dari 2 label.")
                return result
            }
            evaluate(train(trainable, evaluation: "", accuracy: nil), on: windows.filter { golden.contains($0.person) })
        } else {
            let known = people.filter { $0 != "?" }
            guard known.count >= 2 else {
                result.evaluationKind = "tidak bisa (partisipan < 2)"
                result.reasons.append("Butuh ≥ 2 partisipan untuk menguji pada orang baru.")
                return result
            }
            result.evaluationKind = "leave-one-person-out (\(known.count) fold)"
            for person in known {
                let foldTrain = windows.filter { $0.person != person }
                guard Set(foldTrain.map(\.label)).count >= 2 else { continue }
                evaluate(train(foldTrain, evaluation: "", accuracy: nil), on: windows.filter { $0.person == person })
            }
        }

        // Model final: semua data KECUALI golden set.
        let accuracy = result.candidate.accuracy
        result.model = train(trainable, evaluation: "\(result.evaluationKind), akurasi \(pct(accuracy))", accuracy: accuracy)

        // Keputusan promosi.
        let comparator = result.current ?? result.baseline
        let comparatorName = result.current == nil ? "baseline heuristik" : "model aktif"
        let ok = (accuracy ?? 0) >= config.minimumAccuracy
        let better = (accuracy ?? 0) >= (comparator.accuracy ?? 0)
        result.reasons.append("Akurasi \(pct(accuracy)) \(ok ? "≥" : "<") \(pct(config.minimumAccuracy)) (NFR-03)")
        result.reasons.append("\(better ? "≥" : "<") \(comparatorName) \(pct(comparator.accuracy)) pada data uji yang sama")
        result.promote = ok && better
        return result
    }
}
