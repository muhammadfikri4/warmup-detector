import Foundation
import Observation
import WarmUpCore
import WatchConnectivity

/// Data locations on the iPhone.
enum CompanionPaths {
    nonisolated static var training: URL { URL.documentsDirectory.appending(path: "training", directoryHint: .isDirectory) }
    nonisolated static var sessions: URL { URL.documentsDirectory.appending(path: "evaluation/sessions.jsonl") }
    nonisolated static var activeModel: URL { URL.documentsDirectory.appending(path: "models/active.json") }
}

/// iPhone ↔ watch bridge.
/// - Sends: settings (application context), models and reset commands (user info).
/// - Receives: training-data CSVs (files), evaluation log lines (user info), watch status (application context).
@Observable
final class WatchConnector: NSObject {
    private(set) var isPaired = false
    private(set) var isWatchAppInstalled = false
    private(set) var isReachable = false

    @ObservationIgnored var onTrainingFile: ((URL) -> Void)?
    @ObservationIgnored var onSessionLine: ((String) -> Void)?
    @ObservationIgnored var onStatus: ((WatchStatus) -> Void)?
    @ObservationIgnored private var pendingSettings: CompanionSettings?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Refresh pairing state (e.g. the watch turned on after the iPhone app was opened).
    func refresh() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        refreshState(.default)
    }

    func push(_ settings: CompanionSettings) {
        guard WCSession.default.activationState == .activated else {
            pendingSettings = settings
            return
        }
        if let data = try? settings.encoded() {
            try? WCSession.default.updateApplicationContext([SyncKey.settings: data])
        }
    }

    func sendModel(_ data: Data) {
        WCSession.default.transferUserInfo([SyncKey.kind: SyncKey.model, SyncKey.data: data])
    }

    func resetModel() {
        WCSession.default.transferUserInfo([SyncKey.kind: SyncKey.resetModel])
    }

    private func refreshState(_ session: WCSession) {
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
    }

    private func didActivate(status: Data?) {
        refreshState(.default)
        if let pendingSettings {
            self.pendingSettings = nil
            push(pendingSettings)
        }
        if let status, let decoded = try? WatchStatus.decode(status) { onStatus?(decoded) }
    }
}

extension WatchConnector: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let status = session.receivedApplicationContext[SyncKey.status] as? Data
        Task { @MainActor in self.didActivate(status: status) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // The user switched Apple Watches: reactivate for the new watch.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshState(.default) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshState(.default) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[SyncKey.status] as? Data, let status = try? WatchStatus.decode(data) else { return }
        Task { @MainActor in self.onStatus?(status) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo[SyncKey.kind] as? String == SyncKey.session, let line = userInfo[SyncKey.data] as? String else { return }
        Task { @MainActor in self.onSessionLine?(line) }
    }

    /// Same payload as user info, sent directly while the iPhone app is reachable.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message[SyncKey.kind] as? String == SyncKey.session, let line = message[SyncKey.data] as? String else { return }
        Task { @MainActor in self.onSessionLine?(line) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The temporary file is only valid while this method runs → move it right away.
        guard file.metadata?[SyncKey.kind] as? String == SyncKey.training,
              let name = file.metadata?[SyncKey.fileName] as? String,
              RecordingName(fileName: name) != nil else { return }
        let destination = CompanionPaths.training.appending(path: name)
        let fm = FileManager.default
        try? fm.createDirectory(at: CompanionPaths.training, withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        guard (try? fm.moveItem(at: file.fileURL, to: destination)) != nil else { return }
        Task { @MainActor in self.onTrainingFile?(destination) }
    }
}
