import Foundation
import WarmUpCore

/// Saves the evaluation log (JSON Lines) to Documents/evaluation/sessions.jsonl.
/// Data stays on the watch; pull it via Xcode › Download Container, then run `warmup-eval`.
enum SessionLogger {
    static var directory: URL { URL.documentsDirectory.appending(path: "evaluation", directoryHint: .isDirectory) }
    static var fileURL: URL { directory.appending(path: "sessions.jsonl") }

    static func append(_ entry: SessionLogEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = try entry.jsonLine()
        let data = Data((line + "\n").utf8)
        PhoneConnector.shared.sendSessionLine(line)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    static var count: Int {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        return text.split(whereSeparator: \.isNewline).count
    }
}
