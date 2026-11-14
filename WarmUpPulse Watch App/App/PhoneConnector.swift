import Foundation
import Observation
import WarmUpCore
import WatchConnectivity

/// Jembatan watch ↔ iPhone.
/// - Menerima: pengaturan (application context), model hasil training & perintah reset (user info).
/// - Mengirim: CSV data latih (file transfer), baris log evaluasi (user info), status watch (application context).
@Observable
final class PhoneConnector: NSObject {
    static let shared = PhoneConnector()

    private(set) var isActivated = false
    private(set) var lastSettingsDate: Date?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Kirim ke iPhone

    func sendTrainingFile(_ url: URL) {
        guard isActivated else { return }
        WCSession.default.transferFile(url, metadata: [SyncKey.kind: SyncKey.training, SyncKey.fileName: url.lastPathComponent])
    }

    func sendSessionLine(_ line: String) {
        guard isActivated else { return }
        WCSession.default.transferUserInfo([SyncKey.kind: SyncKey.session, SyncKey.data: line])
    }

    func reportStatus() {
        guard isActivated else { return }
        let status = WatchStatus(classifierName: ClassifierFactory.activeClassifierName,
                                 learnedModelVersion: ModelStore.load()?.version,
                                 settingsUpdatedAt: AppSettings.settingsUpdatedAt, reportedAt: .now)
        if let data = try? status.encoded() {
            try? WCSession.default.updateApplicationContext([SyncKey.status: data])
        }
    }

    // MARK: Terima dari iPhone

    private func didActivate(context: Data?) {
        isActivated = true
        if let context { applySettings(context) }
        reportStatus()
    }

    private func applySettings(_ data: Data) {
        guard let settings = try? CompanionSettings.decode(data) else { return }
        AppSettings.apply(settings)
        lastSettingsDate = settings.updatedAt
        reportStatus()
    }

    private func didReceive(kind: String?, data: Data?) {
        switch kind {
        case SyncKey.model:
            if let data, (try? ModelStore.save(data)) != nil { Haptics.play(.success) }
        case SyncKey.resetModel:
            ModelStore.reset()
        default:
            return
        }
        reportStatus()
    }

    private func didFinishTransfer(of url: URL) {
        // Rekaman otomatis dihapus setelah sampai di iPhone agar penyimpanan watch tidak penuh.
        // Rekaman manual tetap disimpan agar jumlahnya terlihat di layar perekam.
        if RecordingName(fileName: url.lastPathComponent)?.isAuto == true {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension PhoneConnector: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let context = session.receivedApplicationContext[SyncKey.settings] as? Data
        Task { @MainActor in self.didActivate(context: context) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[SyncKey.settings] as? Data else { return }
        Task { @MainActor in self.applySettings(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let kind = userInfo[SyncKey.kind] as? String
        let data = userInfo[SyncKey.data] as? Data
        Task { @MainActor in self.didReceive(kind: kind, data: data) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        guard error == nil else { return }
        let url = fileTransfer.file.fileURL
        Task { @MainActor in self.didFinishTransfer(of: url) }
    }
}

/// Model logistic regression kiriman iPhone, disimpan di Documents/models/learned.json.
enum ModelStore {
    nonisolated static var url: URL {
        URL.documentsDirectory.appending(path: "models/learned.json")
    }

    nonisolated static func load() -> SoftmaxModel? {
        guard let data = try? Data(contentsOf: url), let model = try? SoftmaxModel.decode(data), model.isCompatible else { return nil }
        return model
    }

    static func save(_ data: Data) throws {
        let model = try SoftmaxModel.decode(data)
        guard model.isCompatible else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func reset() {
        try? FileManager.default.removeItem(at: url)
    }
}
