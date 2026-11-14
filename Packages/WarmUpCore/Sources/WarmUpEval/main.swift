// warmup-eval — evaluasi prediksi kesiapan terhadap referensi (pipeline tahap 5).
//
//   swift run --package-path Packages/WarmUpCore warmup-eval path/ke/sessions.jsonl [lainnya.jsonl ...]
//
// Log berasal dari Mode Studi di jam: Documents/evaluation/sessions.jsonl
// (Xcode › Devices and Simulators › WarmUp Pulse › Download Container).
import Foundation
import WarmUpCore

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    print("Pemakaian: warmup-eval <sessions.jsonl> [lainnya.jsonl ...]")
    exit(2)
}

var entries: [SessionLogEntry] = []
var invalid = 0
for path in paths {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("Tidak bisa membaca \(path)")
        exit(2)
    }
    let decoded = SessionLogEntry.decodeLines(text)
    entries += decoded.entries
    invalid += decoded.invalidLines
}

// Satu sesi bisa tercatat ganda bila log digabung dari beberapa unduhan.
var seen = Set<UUID>()
entries = entries.filter { seen.insert($0.id).inserted }

print("Membaca \(entries.count) sesi dari \(paths.count) berkas\(invalid > 0 ? " (\(invalid) baris rusak dilewati)" : "").\n")
print(ReadinessReport(entries: entries).formatted())
