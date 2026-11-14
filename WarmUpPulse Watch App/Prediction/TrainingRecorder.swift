import Foundation
import HealthKit
import Observation
import WarmUpCore

/// Perekam data latih untuk CreateML (pipeline tahap 1: Collect).
/// Menulis CSV 50 Hz ke Documents/training/ dengan nama `<label>_<P01>_<L|R>_<epoch>.csv`.
/// Identitas hanya berupa kode samaran; nama asli tidak pernah disimpan.
/// Ambil berkas lewat Xcode › Devices and Simulators › WarmUp Pulse › Download Container,
/// lalu jalankan `swift run warmup-train` (lihat README).
@Observable
final class TrainingRecorder {
    enum State: Equatable {
        case idle
        case countdown(Int)
        case recording(remaining: Int)
        case saved(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    var label: MotionLabel = .armCircles
    var durationSeconds = 30

    private let motion = MotionSampler()
    private let workout: WorkoutSessionManager
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: HKHealthStore) {
        workout = WorkoutSessionManager(store: store)
    }

    static var directory: URL {
        URL.documentsDirectory.appending(path: "training", directoryHint: .isDirectory)
    }

    /// Jumlah rekaman per label untuk partisipan aktif — untuk melihat label mana yang masih kurang.
    func countsForCurrentParticipant() -> [MotionLabel: Int] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        var counts: [MotionLabel: Int] = [:]
        for file in files {
            guard let name = RecordingName(fileName: file), name.participant == AppSettings.participant else { continue }
            counts[MotionLabel(classLabel: name.label), default: 0] += 1
        }
        return counts
    }

    func start() {
        guard AppSettings.consent else {
            state = .failed("Centang persetujuan partisipan dulu.")
            return
        }
        task?.cancel()
        task = Task { await record() }
    }

    func cancel() {
        task?.cancel()
        motion.stop()
        workout.discard()
        state = .idle
    }

    private func record() async {
        for i in stride(from: 3, through: 1, by: -1) {
            state = .countdown(i)
            Haptics.play(.click)
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }

        // Sesi workout menjaga app tetap berjalan saat layar mati (lengan bergerak).
        try? await workout.start(.hiit)
        let name = RecordingName(label: label.rawValue, participant: AppSettings.participant,
                                 wrist: AppSettings.wrist, id: String(Int(Date().timeIntervalSince1970)))
        let buffer = FrameBuffer()
        Haptics.play(.start)
        motion.start { buffer.append($0) }

        for remaining in stride(from: durationSeconds, to: 0, by: -1) {
            state = .recording(remaining: remaining)
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }
        motion.stop()
        workout.discard()
        Haptics.play(.success)

        let frames = buffer.frames
        let quality = MotionRecordingQuality(frames)
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let url = Self.directory.appending(path: "\(name.session).csv")
            try MotionCSV.encode(frames, name: name).write(to: url, atomically: true, encoding: .utf8)
            PhoneConnector.shared.sendTrainingFile(url)
            let warning = quality.rejectionReason().map { " ⚠︎ \($0)" } ?? ""
            state = .saved(String(format: "%@ · %d sampel · %.0f Hz%@", name.session, quality.sampleCount, quality.effectiveHz, warning))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

nonisolated final class FrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MotionFrame] = []

    func append(_ frame: MotionFrame) {
        lock.withLock { storage.append(frame) }
    }

    var frames: [MotionFrame] { lock.withLock { storage } }
}
