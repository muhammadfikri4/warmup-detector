// warmup-eval — evaluates readiness predictions against the reference (pipeline stage 5).
//
//   swift run --package-path Packages/WarmUpCore warmup-eval path/to/sessions.jsonl [more.jsonl ...]
//
// Logs come from Study Mode on the watch: Documents/evaluation/sessions.jsonl
// (Xcode › Devices and Simulators › WarmUp Pulse › Download Container).
import Foundation
import WarmUpCore

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    print("Usage: warmup-eval <sessions.jsonl> [more.jsonl ...]")
    exit(2)
}

var entries: [SessionLogEntry] = []
var invalid = 0
for path in paths {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("Cannot read \(path)")
        exit(2)
    }
    let decoded = SessionLogEntry.decodeLines(text)
    entries += decoded.entries
    invalid += decoded.invalidLines
}

// A session can appear twice when logs are merged from several downloads.
var seen = Set<UUID>()
entries = entries.filter { seen.insert($0.id).inserted }

print("Read \(entries.count) sessions from \(paths.count) files\(invalid > 0 ? " (\(invalid) corrupt lines skipped)" : "").\n")
print(ReadinessReport(entries: entries).formatted())
