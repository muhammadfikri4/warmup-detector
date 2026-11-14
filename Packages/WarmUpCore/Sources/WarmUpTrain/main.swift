// warmup-train — pipeline data gerak: Collect → Clean → Features → Model → Evaluate.
//
//   swift run --package-path Packages/WarmUpCore warmup-train <folder-csv> [output.mlmodel] [--iterations N]
//
// 1. Collect  : CSV `<label>_<partisipan>_<L|R>_<id>.csv` dari layar "Rekam Data Latih".
// 2. Clean    : tolak rekaman rusak (durasi pendek, sampling < 40 Hz, sampel hilang, NaN),
//               potong 1 detik awal & akhir (transisi mulai/berhenti).
// 3. Features : Activity Classifier CreateML belajar fiturnya sendiri dari 6 kanal mentah
//               (akselerasi + rotasi), jendela 2 dtk @ 50 Hz.
// 4. Model    : baseline sederhana (classifier heuristik) vs CreateML pada data uji yang SAMA.
// 5. Evaluate : leave-one-person-out — model diuji pada orang yang tidak ikut dilatih,
//               dilaporkan sensitivity & PPV per gerakan. Gagal (exit 1) bila akurasi < 85% (NFR-03).
// Terakhir, model final dilatih dengan SEMUA data dan disimpan.
#if os(macOS)
import CreateML
import Foundation
import WarmUpCore

let featureColumns = ["acc_x", "acc_y", "acc_z", "rot_x", "rot_y", "rot_z"]
let trimSeconds: TimeInterval = 1
let fm = FileManager.default

// MARK: Argumen
var positional: [String] = []
var iterations = 40
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    if arg == "--iterations", let n = args.next().flatMap(Int.init) { iterations = n } else { positional.append(arg) }
}
guard let sourcePath = positional.first else {
    print("Pemakaian: warmup-train <folder-csv> [output.mlmodel] [--iterations N]")
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
    print("Tidak ada CSV di \(source.path)")
    exit(2)
}

// MARK: 2. Clean
var recordings: [Recording] = []
var rejected: [(String, String)] = []
for url in files {
    guard let name = RecordingName(fileName: url.lastPathComponent) else {
        rejected.append((url.lastPathComponent, "nama berkas tidak sesuai konvensi"))
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
print("\(files.count) berkas, \(recordings.count) lolos, \(rejected.count) ditolak; \(people.count) partisipan; label: \(labels.joined(separator: ", "))")
for label in labels {
    let perPerson = people.map { p in "\(p)×\(recordings.filter { $0.person == p && $0.name.label == label }.count)" }
    print("  • \(label): \(perPerson.joined(separator: " "))")
}

print("\n== 2. Clean ==")
print("Potong \(Int(trimSeconds)) dtk awal & akhir tiap rekaman.")
for (file, reason) in rejected { print("  ✘ \(file): \(reason)") }
if rejected.isEmpty { print("  Semua rekaman lolos pemeriksaan kualitas.") }
guard labels.count >= 2 else {
    print("Butuh minimal 2 label untuk melatih classifier.")
    exit(2)
}

let work = fm.temporaryDirectory.appending(path: "warmup-train-\(UUID().uuidString)")
defer { try? fm.removeItem(at: work) }

/// Menulis rekaman ke struktur `labeledDirectories` CreateML: <root>/<label>/<sesi>.csv
@MainActor func writeLabeledDirectory(_ items: [Recording], to root: URL) throws {
    for r in items {
        let dir = root.appending(path: r.name.label)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try MotionCSV.encode(r.frames, name: r.name).write(to: dir.appending(path: "\(r.name.session).csv"), atomically: true, encoding: .utf8)
    }
}

@MainActor func parameters(validation: URL?) -> MLActivityClassifier.ModelParameters {
    // 2 detik × 50 Hz = 100 sampel per jendela (FR-P03)
    if let validation {
        return MLActivityClassifier.ModelParameters(validationData: .labeledDirectories(at: validation),
                                                    batchSize: 32, maximumIterations: iterations, predictionWindowSize: 100)
    }
    return MLActivityClassifier.ModelParameters(validation: .none, batchSize: 32, maximumIterations: iterations, predictionWindowSize: 100)
}

func normalized(_ label: String) -> String { MotionLabel(classLabel: label).rawValue }

/// Baseline sederhana: classifier heuristik pada jendela 2 dtk (hop 1 dtk).
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
    // CreateML memakai kolom "class" (kebenaran), "predicted_class", dan "count".
    guard let predictedColumn = names.first(where: { $0.lowercased().contains("predict") }),
          let truthColumn = names.first(where: { ["class", "true_label", "true label", "target"].contains($0.lowercased()) }),
          let countColumn = names.first(where: { $0.lowercased().contains("count") }) else {
        print("  (format confusion CreateML tak dikenal: \(names))")
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
print("CreateML Activity Classifier: kanal \(featureColumns.joined(separator: ", ")), jendela 100 sampel (2 dtk).")

print("\n== 4–5. Model & Evaluate ==")
var modelReport = ClassificationReport()
var baselineReport = ClassificationReport()
var evaluationKind: String

let knownPeople = people.filter { $0 != "?" }
if knownPeople.count >= 2 {
    evaluationKind = "leave-one-person-out (\(knownPeople.count) fold)"
    print("Evaluasi \(evaluationKind): tiap fold, satu orang jadi data uji dan TIDAK ikut dilatih.")
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
        print("  fold \(person): CreateML \(pct(foldModel.accuracy)) | heuristik \(pct(foldBaseline.accuracy)) (n = \(foldModel.total) jendela)")
    }
} else {
    // Fallback: belum bisa "test on new people" — pisah per sesi.
    evaluationKind = "per sesi (⚠︎ partisipan < 2: BELUM menguji orang baru, hasil cenderung terlalu optimis)"
    print("Evaluasi \(evaluationKind)")
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
print(baselineReport.formatted(title: "Baseline heuristik"))
print("")
print(modelReport.formatted(title: "CreateML"))

// Model final dengan semua data.
print("\nMelatih model final dengan semua data…")
let all = work.appending(path: "all")
try writeLabeledDirectory(recordings, to: all)
let finalModel = try MLActivityClassifier(trainingData: .labeledDirectories(at: all),
                                          featureColumns: featureColumns, parameters: parameters(validation: nil))
let metadata = MLModelMetadata(
    author: "WarmUp Pulse",
    shortDescription: "Klasifikasi gerakan pemanasan (2 dtk @ 50 Hz). Evaluasi: \(evaluationKind), akurasi \(pct(modelReport.accuracy)).",
    version: "1.0"
)
try finalModel.write(to: output, metadata: metadata)
print("Model tersimpan: \(output.path)")

let accuracy = modelReport.accuracy ?? 0
if accuracy < 0.85 {
    print("\n✘ NFR-03 belum terpenuhi: akurasi \(pct(accuracy)) < 85%. Tambah data / partisipan / variasi gerakan.")
    exit(1)
}
if (baselineReport.accuracy ?? 0) >= accuracy {
    print("\n⚠︎ CreateML tidak lebih baik dari baseline heuristik — pertimbangkan tetap memakai baseline.")
}
print("\n✔ NFR-03 terpenuhi (\(pct(accuracy)), \(evaluationKind)).")
#else
print("warmup-train hanya berjalan di macOS (butuh CreateML).")
#endif
