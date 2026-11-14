import Foundation
import Observation
import SwiftUI
import WarmUpCore

/// Source of truth for settings, data and models on the iPhone.
@Observable
final class CompanionStore {
    private(set) var settings: CompanionSettings
    private(set) var watchStatus: WatchStatus?
    private(set) var recordings: [RecordingName] = []
    private(set) var sessionCount = 0
    private(set) var activeModel: SoftmaxModel?

    private(set) var isTraining = false
    private(set) var trainingReport: String?
    /// Structured result of the last Retrain, shown as cards and charts.
    private(set) var lastTraining: TrainingResult?
    /// A new model that PASSED evaluation and is ready to send.
    private(set) var candidate: SoftmaxModel?
    var message: String?

    var goldenParticipants: Set<String> {
        didSet { UserDefaults.standard.set(Array(goldenParticipants).sorted(), forKey: Self.goldenKey) }
    }

    let connector = WatchConnector()
    private static let settingsKey = "companionSettings"
    private static let goldenKey = "goldenParticipants"

    init() {
        var initial = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? CompanionSettings.decode($0) } ?? CompanionSettings()
        if initial.updatedAt.timeIntervalSince1970 == 0 { initial.updatedAt = .now }
        settings = initial
        goldenParticipants = Set(UserDefaults.standard.stringArray(forKey: Self.goldenKey) ?? [])
        activeModel = (try? Data(contentsOf: CompanionPaths.activeModel)).flatMap { try? SoftmaxModel.decode($0) }
        refreshInventory()

        connector.onTrainingFile = { [weak self] _ in self?.refreshInventory() }
        connector.onSessionLine = { [weak self] line in self?.receiveSessionLine(line) }
        connector.onStatus = { [weak self] status in self?.watchStatus = status }
        connector.activate()
        connector.push(settings)
    }

    // MARK: Settings → watch

    func update(_ change: (inout CompanionSettings) -> Void) {
        var next = settings
        change(&next)
        if next.participant != settings.participant { next.consent = false } // new person = ask for consent again
        if !next.consent { next.autoCollect = false }
        guard next != settings else { return }
        next.updatedAt = .now
        settings = next
        if let data = try? next.encoded() { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
        connector.push(next)
    }

    func binding<T>(_ keyPath: WritableKeyPath<CompanionSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    // MARK: Data from the watch

    func refreshInventory() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: CompanionPaths.training.path)) ?? []
        recordings = files.compactMap(RecordingName.init(fileName:)).sorted { $0.session < $1.session }
        sessionCount = loadSessions().count
    }

    private func receiveSessionLine(_ line: String) {
        // The same session can arrive twice (direct message + queued fallback): keep one copy.
        guard let entry = SessionLogEntry.decodeLines(line).entries.first,
              !loadSessions().contains(where: { $0.id == entry.id }) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: CompanionPaths.sessions.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: CompanionPaths.sessions) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: CompanionPaths.sessions)
        }
        // The watch has already reset the scenario to "Unknown"; mirror that on the iPhone.
        update { $0.scenario = .unknown }
        refreshInventory()
    }

    private func loadSessions() -> [SessionLogEntry] {
        guard let text = try? String(contentsOf: CompanionPaths.sessions, encoding: .utf8) else { return [] }
        var seen = Set<UUID>()
        return SessionLogEntry.decodeLines(text).entries.filter { seen.insert($0.id).inserted }
    }

    /// Every finished workout reported by the watch (deduplicated).
    var allSessions: [SessionLogEntry] {
        _ = sessionCount // observe: recompute when a new log arrives
        return loadSessions()
    }

    /// Latest finished workouts reported by the watch, newest first.
    var recentSessions: [SessionLogEntry] {
        _ = sessionCount // observe: recompute when a new log arrives
        return Array(loadSessions().suffix(20).reversed())
    }

    var participantsInData: [String] { Set(recordings.compactMap(\.participant)).sorted() }

    func counts(for participant: String) -> [(label: String, manual: Int, auto: Int)] {
        let mine = recordings.filter { $0.participant == participant }
        return MotionLabel.allCases.map { label in
            let items = mine.filter { MotionLabel(classLabel: $0.label) == label }
            return (label.exercise?.displayName ?? (label == .idle ? "Standing still" : "Other movement"), items.filter { !$0.isAuto }.count, items.filter(\.isAuto).count)
        }
    }

    var exportURLs: [URL] {
        let csv = recordings.map { CompanionPaths.training.appending(path: "\($0.session).csv") }
        let sessions = FileManager.default.fileExists(atPath: CompanionPaths.sessions.path) ? [CompanionPaths.sessions] : []
        return csv + sessions
    }

    var readinessReport: String {
        _ = sessionCount // observation: recompute when a new log arrives
        let entries = loadSessions()
        return entries.isEmpty ? "No session logs yet. Turn on Study Mode, then run a session on the watch." : ReadinessReport(entries: entries).formatted()
    }

    // MARK: Training (manual trigger)

    func train() {
        guard !isTraining else { return }
        isTraining = true
        candidate = nil
        trainingReport = nil
        lastTraining = nil
        let urls = recordings.map { CompanionPaths.training.appending(path: "\($0.session).csv") }
        let current = activeModel
        let golden = goldenParticipants

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.runTraining(urls: urls, current: current, golden: golden)
            }.value
            trainingReport = result.formatted()
            lastTraining = result
            candidate = result.promote ? result.model : nil
            isTraining = false
        }
    }

    /// Runs off the main thread: read CSVs → TrainingPipeline.
    nonisolated private static func runTraining(urls: [URL], current: SoftmaxModel?, golden: Set<String>) -> TrainingResult {
        var config = TrainingConfiguration()
        config.goldenParticipants = golden
        let data = urls.compactMap { url -> TrainingRecording? in
            guard let name = RecordingName(fileName: url.lastPathComponent),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return TrainingRecording(name: name, frames: MotionCSV.decode(text))
        }
        return TrainingPipeline.run(recordings: data, current: current, configuration: config)
    }

    func deployCandidate() {
        guard let candidate, let data = try? candidate.jsonData() else { return }
        do {
            try FileManager.default.createDirectory(at: CompanionPaths.activeModel.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: CompanionPaths.activeModel, options: .atomic)
        } catch {
            message = "Couldn't save the model: \(error.localizedDescription)"
            return
        }
        connector.sendModel(data)
        activeModel = candidate
        self.candidate = nil
        message = "Model v\(candidate.version) sent. The watch will use it on the next warm-up."
    }

    func resetModel() {
        try? FileManager.default.removeItem(at: CompanionPaths.activeModel)
        activeModel = nil
        connector.resetModel()
        message = "The watch is back on the built-in model."
    }
}
