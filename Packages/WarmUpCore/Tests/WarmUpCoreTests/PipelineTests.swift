import Foundation
import Testing
@testable import WarmUpCore

@Suite("Pipeline: Collect")
struct CollectTests {
    @Test("File name includes participant code & wrist, no real name")
    func recordingName() {
        let name = RecordingName(label: "armCircles", participant: "P03", wrist: .left, id: "1731550000")
        #expect(name.session == "armCircles_P03_L_1731550000")
        #expect(RecordingName(fileName: "armCircles_P03_L_1731550000.csv") == name)

        let legacy = RecordingName(fileName: "idle_1731550000.csv")
        #expect(legacy?.label == "idle")
        #expect(legacy?.participant == nil)
    }

    @Test("CSV round-trip")
    func csvRoundTrip() {
        let frames = (0..<5).map { i in
            MotionFrame(timestamp: Double(i) * 0.02, userAcceleration: Vector3(0.1, -0.2, 0.3),
                        rotationRate: Vector3(1, 2, 3), gravity: Vector3(0, 0, -1))
        }
        let name = RecordingName(label: "idle", participant: "P01", wrist: .right, id: "1")
        let decoded = MotionCSV.decode(MotionCSV.encode(frames, name: name))
        #expect(decoded.count == 5)
        #expect(decoded[4].rotationRate == Vector3(1, 2, 3))
        #expect(abs(decoded[4].timestamp - 0.08) < 1e-9)
    }

    @Test("JSON Lines session log can be read back")
    func sessionLogRoundTrip() throws {
        let zones = HeartRateZones(physiology: UserPhysiology(age: 30, restingHR: 65))
        let assessment = ReadinessAssessment(status: .notWarmedUp, heartRate: 70, zones: zones, reasons: [.belowTargetZone],
                                             minutesAboveWarm: 0, trendBpmPerMinute: nil, hrQuality: HeartRateQuality())
        let entry = SessionLogEntry(date: Date(timeIntervalSince1970: 1_800_000_000), participant: "P02", wrist: .left,
                                    scenario: .cold, workout: .outdoorRun, assessment: assessment, checkLatency: 2.4,
                                    classifier: "heuristic", warmUp: .completed, finalConfirmed: true,
                                    steps: [StepLog(exercise: .armCircles, target: .reps(15), counted: 15, completed: true, referenceReps: 14)])
        let text = try entry.jsonLine() + "\n{corrupt}\n"
        let decoded = SessionLogEntry.decodeLines(text)
        #expect(decoded.entries == [entry])
        #expect(decoded.invalidLines == 1)
    }
}

@Suite("Pipeline: Clean")
struct CleanTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Drop out-of-range values and isolated spikes; gaps stay visible")
    func heartRateCleaning() {
        let samples = [
            HeartRateSample(date: t0, bpm: 72),
            HeartRateSample(date: t0.addingTimeInterval(10), bpm: 74),
            HeartRateSample(date: t0.addingTimeInterval(20), bpm: 150), // artifact spike
            HeartRateSample(date: t0.addingTimeInterval(30), bpm: 75),
            HeartRateSample(date: t0.addingTimeInterval(40), bpm: 0),   // sensor failure
            HeartRateSample(date: t0.addingTimeInterval(400), bpm: 78), // after a 370 s gap
        ]
        let (clean, quality) = HeartRateCleaner().clean(samples)
        #expect(clean.map(\.bpm) == [72, 74, 75, 78])
        #expect(quality.removedOutOfRange == 1)
        #expect(quality.removedSpikes == 1)
        #expect(quality.gaps.count == 1)
        #expect(quality.longestGapMinutes > 6)
    }

    @Test("A normal (gradual) HR rise is not treated as a spike")
    func gradualRiseKept() {
        let samples = (0..<6).map { HeartRateSample(date: t0.addingTimeInterval(Double($0) * 10), bpm: 80 + Double($0) * 8) }
        #expect(HeartRateCleaner().clean(samples).samples.count == 6)
    }

    @Test("An implausible live HR does not produce Ready")
    func implausibleLiveHRIgnored() {
        let zones = HeartRateZones(physiology: UserPhysiology(age: 30, restingHR: 65))
        let history = [HeartRateSample(date: t0.addingTimeInterval(-60), bpm: 70)]
        let input = ReadinessInput(currentHR: HeartRateSample(date: t0, bpm: 250), history: history,
                                   recentActiveEnergy: nil, zones: zones, now: t0)
        let a = ReadinessEngine().evaluate(input)
        #expect(a.status == .notWarmedUp)
        #expect(a.heartRate == 70)
        #expect(a.hrQuality.removedOutOfRange == 1)
    }

    @Test("Motion recordings that are too short / have dropped samples are rejected")
    func motionQuality() {
        func frames(_ n: Int, dt: Double) -> [MotionFrame] {
            (0..<n).map { MotionFrame(timestamp: Double($0) * dt, userAcceleration: .zero, rotationRate: .zero, gravity: Vector3(0, 0, -1)) }
        }
        #expect(MotionRecordingQuality(frames(500, dt: 0.02)).rejectionReason() == nil)
        #expect(MotionRecordingQuality(frames(100, dt: 0.02)).rejectionReason() != nil)  // 2 s
        #expect(MotionRecordingQuality(frames(300, dt: 0.05)).rejectionReason() != nil)  // 20 Hz
    }
}

@Suite("Pipeline: Features")
struct FeatureTests {
    @Test("HRV ≥ 20% below personal baseline → warm-up extended")
    func lowHRV() {
        let ctx = RecoveryContext(workout: .outdoorRun, physiology: UserPhysiology(age: 30, restingHR: 60), sleepHours: 8,
                                  restingHRBaseline: 60, startHour: 17, hrvSDNN: 32, hrvBaseline: 50)
        let plan = WarmUpPlanner().plan(for: ctx)
        #expect(plan.durationMinutes == 5)
        #expect(plan.adjustments == [.lowHRV(percentBelow: 36)])
    }
}

@Suite("Pipeline: Evaluate")
struct EvaluateTests {
    @Test("Sensitivity & PPV are computed from the confusion matrix")
    func classificationReport() {
        var r = ClassificationReport()
        r.add(truth: "armCircles", predicted: "armCircles", count: 8)
        r.add(truth: "armCircles", predicted: "idle", count: 2)
        r.add(truth: "idle", predicted: "idle", count: 9)
        r.add(truth: "idle", predicted: "armCircles", count: 1)
        #expect(r.accuracy == 0.85)
        #expect(r.sensitivity(of: "armCircles") == 0.8)
        #expect(r.ppv(of: "armCircles") == 8.0 / 9.0)
        #expect(r.formatted(title: "test").contains("sensitivity"))
    }

    @Test("Readiness evaluation vs reference scenario & manual count")
    func readinessReport() {
        let zones = HeartRateZones(physiology: UserPhysiology(age: 30, restingHR: 65))
        func entry(_ scenario: ReferenceScenario, predicted: ReadinessStatus, person: String, latency: Double = 2) -> SessionLogEntry {
            let a = ReadinessAssessment(status: predicted, heartRate: 80, zones: zones, reasons: [], minutesAboveWarm: 0,
                                        trendBpmPerMinute: nil, hrQuality: HeartRateQuality())
            return SessionLogEntry(date: .now, participant: person, wrist: .left, scenario: scenario, workout: .outdoorRun,
                                   assessment: a, checkLatency: latency, classifier: "x", warmUp: .completed, finalConfirmed: nil,
                                   steps: [StepLog(exercise: .armCircles, target: .reps(15), counted: 15, completed: true, referenceReps: 12)])
        }
        let report = ReadinessReport(entries: [
            entry(.cold, predicted: .notWarmedUp, person: "P01"),          // TP
            entry(.cold, predicted: .ready, person: "P02"),                // FN
            entry(.warm, predicted: .ready, person: "P01"),                // TN
            entry(.warm, predicted: .notWarmedUp, person: "P02", latency: 4), // FP
            entry(.unknown, predicted: .ready, person: "P03"),             // no reference
        ])
        #expect(report.overall.sensitivity == 0.5)
        #expect(report.overall.ppv == 0.5)
        #expect(report.withoutReference == 1)
        #expect(report.perParticipant["P01"]?.accuracy == 1)
        #expect(report.latencyWithinBudget == 0.8)
        #expect(report.repErrors[.armCircles]?.first == 3)
    }
}
