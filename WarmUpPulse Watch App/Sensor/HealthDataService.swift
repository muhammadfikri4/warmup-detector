import Foundation
import HealthKit
import WarmUpCore

/// FR-S02 (riwayat 10 menit HR & Active Energy) dan FR-S04 (RHR, tidur, usia).
final class HealthDataService {
    let store = HKHealthStore()

    private let heartRateType = HKQuantityType(.heartRate)
    private let activeEnergyType = HKQuantityType(.activeEnergyBurned)
    private let restingHRType = HKQuantityType(.restingHeartRate)
    private let sleepType = HKCategoryType(.sleepAnalysis)
    private let hrvType = HKQuantityType(.heartRateVariabilitySDNN)
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        let read: Set<HKObjectType> = [
            heartRateType, activeEnergyType, restingHRType, sleepType, hrvType,
            HKCharacteristicType(.dateOfBirth), HKObjectType.workoutType(),
        ]
        let share: Set<HKSampleType> = [HKObjectType.workoutType(), heartRateType, activeEnergyType]
        try await store.requestAuthorization(toShare: share, read: read)
    }

    func heartRates(since start: Date, until end: Date = .now) async -> [HeartRateSample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: heartRateType, predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .forward)]
        )
        let samples = (try? await descriptor.result(for: store)) ?? []
        return samples.map { HeartRateSample(date: $0.endDate, bpm: $0.quantity.doubleValue(for: bpmUnit)) }
    }

    func activeEnergy(since start: Date, until end: Date = .now) async -> Double? {
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: activeEnergyType, predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
            options: .cumulativeSum
        )
        return try? await descriptor.result(for: store)?.sumQuantity()?.doubleValue(for: .kilocalorie())
    }

    func physiology() async -> UserPhysiology {
        let age: Int? = (try? store.dateOfBirthComponents()).flatMap { components in
            guard let birth = Calendar.current.date(from: components) else { return nil }
            return Calendar.current.dateComponents([.year], from: birth, to: .now).year
        }
        return UserPhysiology(age: age, restingHR: await latestRestingHR())
    }

    func recoveryContext(for workout: WorkoutKind, now: Date = .now) async -> RecoveryContext {
        async let physiology = physiology()
        async let sleep = sleepHoursLastNight(now: now)
        async let baseline = restingHRBaseline(now: now)
        async let hrv = latestHRV(now: now)
        async let hrvBaseline = hrvBaseline(now: now)
        return RecoveryContext(workout: workout, physiology: await physiology, sleepHours: await sleep,
                               restingHRBaseline: await baseline,
                               startHour: Calendar.current.component(.hour, from: now),
                               hrvSDNN: await hrv, hrvBaseline: await hrvBaseline)
    }

    /// HRV (SDNN, ms) terbaru dalam 48 jam — Apple Watch mengukurnya beberapa kali sehari / saat tidur.
    private func latestHRV(now: Date) async -> Double? {
        let start = now.addingTimeInterval(-48 * 3600)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: hrvType, predicate: HKQuery.predicateForSamples(withStart: start, end: now))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        return try? await descriptor.result(for: store).first?.quantity.doubleValue(for: .secondUnit(with: .milli))
    }

    /// Baseline pribadi: rata-rata HRV 30 hari.
    private func hrvBaseline(now: Date) async -> Double? {
        let start = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: hrvType, predicate: HKQuery.predicateForSamples(withStart: start, end: now)),
            options: .discreteAverage
        )
        return try? await descriptor.result(for: store)?.averageQuantity()?.doubleValue(for: .secondUnit(with: .milli))
    }

    private func latestRestingHR() async -> Double? {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: restingHRType, predicate: HKQuery.predicateForSamples(withStart: start, end: .now))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        return try? await descriptor.result(for: store).first?.quantity.doubleValue(for: bpmUnit)
    }

    private func restingHRBaseline(now: Date) async -> Double? {
        let start = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: restingHRType, predicate: HKQuery.predicateForSamples(withStart: start, end: now)),
            options: .discreteAverage
        )
        return try? await descriptor.result(for: store)?.averageQuantity()?.doubleValue(for: bpmUnit)
    }

    /// Total tidur (gabungan interval tanpa tumpang tindih antar sumber) sejak pukul 18.00 kemarin.
    private func sleepHoursLastNight(now: Date) async -> Double? {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 18, minute: 0, second: 0,
                                  of: calendar.date(byAdding: .day, value: -1, to: now)!)!
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleepType, predicate: HKQuery.predicateForSamples(withStart: start, end: now))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        guard let samples = try? await descriptor.result(for: store) else { return nil }
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        let intervals = samples.filter { asleep.contains($0.value) }.map { ($0.startDate, $0.endDate) }
        guard !intervals.isEmpty else { return nil }

        var total: TimeInterval = 0
        var current = intervals[0]
        for next in intervals.dropFirst() {
            if next.0 <= current.1 {
                current.1 = max(current.1, next.1)
            } else {
                total += current.1.timeIntervalSince(current.0)
                current = next
            }
        }
        total += current.1.timeIntervalSince(current.0)
        return total / 3600
    }
}
