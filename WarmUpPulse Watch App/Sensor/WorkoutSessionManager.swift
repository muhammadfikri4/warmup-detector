import Foundation
import HealthKit
import Observation
import WarmUpCore

/// FR-S01 & FR-S02 — HKWorkoutSession + HKLiveWorkoutBuilder untuk aliran HR berlatensi rendah.
///
/// Satu sesi workout menaungi seluruh alur: pengecekan → pemanasan (sub-aktivitas) → latihan inti.
/// Dengan begitu pemanasan ikut tercatat di riwayat workout sebagai segmen terpisah.
@Observable
final class WorkoutSessionManager: NSObject {
    private let store: HKHealthStore
    private(set) var session: HKWorkoutSession?
    private(set) var builder: HKLiveWorkoutBuilder?
    private(set) var latestHeartRate: HeartRateSample?
    private(set) var state: HKWorkoutSessionState = .notStarted

    @ObservationIgnored var onHeartRate: ((HeartRateSample) -> Void)?
    @ObservationIgnored private var configuration: HKWorkoutConfiguration?
    @ObservationIgnored private var warmUpActivityActive = false
    @ObservationIgnored private var endContinuation: CheckedContinuation<Void, Never>?

    init(store: HKHealthStore) {
        self.store = store
    }

    var isRunning: Bool { session != nil }

    func start(_ kind: WorkoutKind) async throws {
        if session != nil { discard() }
        let config = HKWorkoutConfiguration()
        config.activityType = kind.healthKitActivityType
        config.locationType = kind.locationType

        let session = try HKWorkoutSession(healthStore: store, configuration: config)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
        session.delegate = self
        builder.delegate = self

        self.session = session
        self.builder = builder
        self.configuration = config
        latestHeartRate = nil

        let start = Date()
        session.startActivity(with: start)
        try await builder.beginCollection(at: start)
    }

    /// Menunggu sampel HR live pertama (maks `timeout` detik) — bagian dari anggaran ≤ 3 detik FR-P01.
    func waitForHeartRate(timeout: TimeInterval) async -> HeartRateSample? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hr = latestHeartRate { return hr }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return latestHeartRate
    }

    func beginWarmUpActivity() {
        guard let session, let configuration, !warmUpActivityActive else { return }
        session.beginNewActivity(configuration: configuration, date: .now, metadata: [MetadataKey.phase: "warmup"])
        warmUpActivityActive = true
    }

    func endWarmUpActivity() {
        guard let session, warmUpActivityActive else { return }
        session.endCurrentActivity(on: .now)
        warmUpActivityActive = false
    }

    func elapsedTime(at date: Date) -> TimeInterval {
        builder?.elapsedTime(at: date) ?? 0
    }

    func addMetadata(_ metadata: [String: Any]) async {
        try? await builder?.addMetadata(metadata)
    }

    /// Mengakhiri & menyimpan workout ke HealthKit.
    @discardableResult
    func end() async -> HKWorkout? {
        guard let session, let builder else { return nil }
        endWarmUpActivity()
        await withCheckedContinuation { continuation in
            endContinuation = continuation
            session.end()
        }
        defer { reset() }
        do {
            try await builder.endCollection(at: .now)
            return try await builder.finishWorkout()
        } catch {
            return nil
        }
    }

    /// Membatalkan tanpa menyimpan (mis. pengguna kembali ke menu).
    func discard() {
        session?.end()
        builder?.discardWorkout()
        reset()
    }

    private func reset() {
        session = nil
        builder = nil
        configuration = nil
        warmUpActivityActive = false
        state = .notStarted
    }

    private func didChange(to newState: HKWorkoutSessionState) {
        state = newState
        if newState == .ended || newState == .stopped, let c = endContinuation {
            endContinuation = nil
            c.resume()
        }
    }

    private func didCollect(heartRate bpm: Double, at date: Date) {
        let sample = HeartRateSample(date: date, bpm: bpm)
        latestHeartRate = sample
        onHeartRate?(sample)
    }

    enum MetadataKey {
        static let phase = "WarmUpPulsePhase"
        static let summary = "WarmUpPulseSummary"
        static let skipped = "WarmUpPulseSkipped"
    }
}

extension WorkoutSessionManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in self.didChange(to: toState) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        Task { @MainActor in self.didChange(to: .ended) }
    }
}

extension WorkoutSessionManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hrType),
              let stats = workoutBuilder.statistics(for: hrType),
              let quantity = stats.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: .count().unitDivided(by: .minute()))
        let date = stats.mostRecentQuantityDateInterval()?.end ?? .now
        Task { @MainActor in self.didCollect(heartRate: bpm, at: date) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

extension WorkoutKind {
    var healthKitActivityType: HKWorkoutActivityType {
        switch self {
        case .outdoorRun, .indoorRun: .running
        case .hiit: .highIntensityIntervalTraining
        case .strength: .traditionalStrengthTraining
        case .racket: .badminton
        case .cycling: .cycling
        }
    }

    var locationType: HKWorkoutSessionLocationType {
        switch self {
        case .outdoorRun, .cycling: .outdoor
        case .indoorRun, .hiit, .strength, .racket: .indoor
        }
    }
}
