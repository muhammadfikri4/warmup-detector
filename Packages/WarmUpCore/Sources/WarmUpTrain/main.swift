// warmup-train — motion data pipeline: Collect → Clean → Features → Model → Evaluate.
//
//   swift run --package-path Packages/WarmUpCore warmup-train <csv-folder> [output.mlmodel] [--iterations N]
//
// 1. Collect  : CSV `<label>_<participant>_<L|R>_<id>.csv` from the "Record Training Data" screen.
// 2. Clean    : reject broken recordings (too short, sampling < 40 Hz, dropped samples, NaN),
//               trim the first & last second (start/stop transitions).
// 3. Features : the CreateML Activity Classifier learns its own features from 6 raw channels
//               (acceleration + rotation), 2 s windows @ 50 Hz.
// 4. Model    : simple baseline (heuristic classifier) vs CreateML on the SAME test data.
// 5. Evaluate : leave-one-person-out — the model is tested on people it wasn't trained on,
//               reporting sensitivity & PPV per exercise. Fails (exit 1) when accuracy < 85% (NFR-03).
// Finally, the final model is trained on ALL data and saved.
#if os(macOS)
import CreateML
import Foundation
import WarmUpCore

let featureColumns = ["acc_x", "acc_y", "acc_z", "rot_x", "rot_y", "rot_z"]
let trimSeconds: TimeInterval = 1
let fm = FileManager.default

// MARK: Arguments
var positional: [String] = []
var iterations = 40
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    if arg == "--iterations", let n = args.next().flatMap(Int.init) { iterations = n } else { positional.append(arg) }
}
guard let sourcePath = positional.first else {
    print("Usage: warmup-train <csv-folder> [output.mlmodel] [--iterations N]")
    exit(2)
}
let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
let output = URL(fileURLWithPath: positional.count > 1 ? positional[1] : "WarmUpPulse Watch App/WarmUpClassifier.mlmodel")

struct Recording {
    var name: RecordingName
    var frames: [MotionFrame]
    var person: String { name.participant ?? "?" }
}

// MARK: 1. Collect
print("== 1. Collect ==")
let files = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "csv" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !files.isEmpty else {
    print("No CSV files in \(source.path)")
    exit(2)
}

// MARK: 2. Clean
var recordings: [Recording] = []
var rejected: [(String, String)] = []
for url in files {
    guard let name = RecordingName(fileName: url.lastPathComponent) else {
        rejected.append((url.lastPathComponent, "file name does not follow the convention"))
        continue
    }
    let frames = MotionCSV.decode(try String(contentsOf: url, encoding: .utf8))
    if let reason = MotionRecordingQuality(frames).rejectionReason() {
        rejected.append((url.lastPathComponent, reason))
        continue
    }
    let start = frames.first!.timestamp + trimSeconds
    let end = frames.last!.timestamp - trimSeconds
    recordings.append(Recording(name: name, frames: frames.filter { $0.timestamp >= start && $0.timestamp <= end }))
}

let people = Set(recordings.map(\.person)).sorted()
let labels = Set(recordings.map(\.name.label)).sorted()
print("\(files.count) files, \(recordings.count) passed, \(rejected.count) rejected; \(people.count) participants; labels: \(labels.joined(separator: ", "))")
for label in labels {
    let perPerson = people.map { p in "\(p)×\(recordings.filter { $0.person == p && $0.name.label == label }.count)" }
    print("  • \(label): \(perPerson.joined(separator: " "))")
}

print("\n== 2. Clean ==")
print("Trimming the first & last \(Int(trimSeconds)) s of each recording.")
for (file, reason) in rejected { print("  ✘ \(file): \(reason)") }
if rejected.isEmpty { print("  All recordings passed the quality check.") }
guard labels.count >= 2 else {
    print("Need at least 2 labels to train the classifier.")
    exit(2)
}

let work = fm.temporaryDirectory.appending(path: "warmup-train-\(UUID().uuidString)")
defer { try? fm.removeItem(at: work) }

/// Writes recordings in the CreateML `labeledDirectories` layout: <root>/<label>/<session>.csv
@MainActor func writeLabeledDirectory(_ items: [Recording], to root: URL) throws {
    for r in items {
        let dir = root.appending(path: r.name.label)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try MotionCSV.encode(r.frames, name: r.name).write(to: dir.appending(path: "\(r.name.session).csv"), atomically: true, encoding: .utf8)
    }
}

@MainActor func parameters(validation: URL?) -> MLActivityClassifier.ModelParameters {
    // 2 seconds × 50 Hz = 100 samples per window (FR-P03)
    if let validation {
        return MLActivityClassifier.ModelParameters(validationData: .labeledDirectories(at: validation),
                                                    batchSize: 32, maximumIterations: iterations, predictionWindowSize: 100)
    }
    return MLActivityClassifier.ModelParameters(validation: .none, batchSize: 32, maximumIterations: iterations, predictionWindowSize: 100)
}

func normalized(_ label: String) -> String { MotionLabel(classLabel: label).rawValue }

/// Simple baseline: heuristic classifier on 2 s windows (1 s hop).
func heuristicReport(_ items: [Recording]) -> ClassificationReport {
    let classifier = HeuristicMotionClassifier()
    var report = ClassificationReport()
    for r in items {
        var i = 0
        while i + 100 <= r.frames.count {
            if let p = classifier.classify(Array(r.frames[i..<(i + 100)])) {
                report.add(truth: normalized(r.name.label), predicted: p.label.rawValue)
            }
            i += 50
        }
    }
    return report
}

func createMLReport(_ metrics: MLClassifierMetrics) -> ClassificationReport {
    var report = ClassificationReport()
    let frame = metrics.confusionDataFrame
    let names = frame.columns.map(\.name)
    // CreateML uses the columns "class" (truth), "predicted_class", and "count".
    guard let predictedColumn = names.first(where: { $0.lowercased().contains("predict") }),
          let truthColumn = names.first(where: { ["class", "true_label", "true label", "target"].contains($0.lowercased()) }),
          let countColumn = names.first(where: { $0.lowercased().contains("count") }) else {
        print("  (unknown CreateML confusion format: \(names))")
        return report
    }
    for row in frame.rows {
        guard let truth = row[truthColumn].map({ "\($0)" }),
              let predicted = row[predictedColumn].map({ "\($0)" }),
              let count = row[countColumn].flatMap({ ($0 as? Int) ?? Int("\($0)") }) else { continue }
        report.add(truth: normalized(truth), predicted: normalized(predicted), count: count)
    }
    return report
}

// MARK: 3–5. Features, Model, Evaluate
print("\n== 3. Features ==")
print("CreateML Activity Classifier: channels \(featureColumns.joined(separator: ", ")), 100-sample window (2 s).")

print("\n== 4–5. Model & Evaluate ==")
var modelReport = ClassificationReport()
var baselineReport = ClassificationReport()
var evaluationKind: String

let knownPeople = people.filter { $0 != "?" }
if knownPeople.count >= 2 {
    evaluationKind = "leave-one-person-out (\(knownPeople.count) fold)"
    print("Evaluation \(evaluationKind): in each fold, one person is the test data and is NOT used for training.")
    for person in knownPeople {
        let train = recordings.filter { $0.person != person }
        let test = recordings.filter { $0.person == person }
        guard Set(train.map(\.name.label)).count >= 2 else { continue }
        let fold = work.appending(path: "fold-\(person)")
        try writeLabeledDirectory(train, to: fold.appending(path: "train"))
        try writeLabeledDirectory(test, to: fold.appending(path: "test"))

        let model = try MLActivityClassifier(trainingData: .labeledDirectories(at: fold.appending(path: "train")),
                                             featureColumns: featureColumns, parameters: parameters(validation: nil))
        let metrics = model.evaluation(on: .labeledDirectories(at: fold.appending(path: "test")), featureColumns: featureColumns)
        let foldModel = createMLReport(metrics)
        let foldBaseline = heuristicReport(test)
        modelReport.merge(foldModel)
        baselineReport.merge(foldBaseline)
        print("  fold \(person): CreateML \(pct(foldModel.accuracy)) | heuristic \(pct(foldBaseline.accuracy)) (n = \(foldModel.total) windows)")
    }
} else {
    // Fallback: can't "test on new people" yet — split per session.
    evaluationKind = "per session (⚠︎ participants < 2: NOT tested on new people, results are likely too optimistic)"
    print("Evaluation \(evaluationKind)")
    var train: [Recording] = []
    var test: [Recording] = []
    for label in labels {
        let items = recordings.filter { $0.name.label == label }
        for (i, r) in items.enumerated() {
            if items.count >= 2 && (i == items.count - 1 || i % 5 == 4) { test.append(r) } else { train.append(r) }
        }
    }
    let fold = work.appending(path: "session-split")
    try writeLabeledDirectory(train, to: fold.appending(path: "train"))
    try writeLabeledDirectory(test, to: fold.appending(path: "test"))
    let model = try MLActivityClassifier(trainingData: .labeledDirectories(at: fold.appending(path: "train")),
                                         featureColumns: featureColumns, parameters: parameters(validation: nil))
    modelReport = createMLReport(model.evaluation(on: .labeledDirectories(at: fold.appending(path: "test")), featureColumns: featureColumns))
    baselineReport = heuristicReport(test)
}

print("")
print(baselineReport.formatted(title: "Heuristic baseline"))
print("")
print(modelReport.formatted(title: "CreateML"))

// Final model with all data.
print("\nTraining the final model on all data…")
let all = work.appending(path: "all")
try writeLabeledDirectory(recordings, to: all)
let finalModel = try MLActivityClassifier(trainingData: .labeledDirectories(at: all),
                                          featureColumns: featureColumns, parameters: parameters(validation: nil))
let metadata = MLModelMetadata(
    author: "WarmUp Pulse",
    shortDescription: "Warm-up exercise classification (2 s @ 50 Hz). Evaluation: \(evaluationKind), accuracy \(pct(modelReport.accuracy)).",
    version: "1.0"
)
try finalModel.write(to: output, metadata: metadata)
print("Model saved: \(output.path)")

let accuracy = modelReport.accuracy ?? 0
if accuracy < 0.85 {
    print("\n✘ NFR-03 not met: accuracy \(pct(accuracy)) < 85%. Add more data / participants / exercise variation.")
    exit(1)
}
if (baselineReport.accuracy ?? 0) >= accuracy {
    print("\n⚠︎ CreateML is not better than the heuristic baseline — consider keeping the baseline.")
}
print("\n✔ NFR-03 met (\(pct(accuracy)), \(evaluationKind)).")
#else
print("warmup-train only runs on macOS (requires CreateML).")
#endif
