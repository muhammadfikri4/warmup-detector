import Foundation
import Testing
@testable import WarmUpCore

/// Test scenarios from PRD §5 (Evaluation Matrix).
@Suite("PRD §5 Evaluation Matrix")
struct EvaluationMatrixTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let physiology = UserPhysiology(age: 30, restingHR: 65)
    var zones: HeartRateZones { HeartRateZones(physiology: physiology) }

    func samples(_ points: [(minutesAgo: Double, bpm: Double)]) -> [HeartRateSample] {
        points.map { HeartRateSample(date: now.addingTimeInterval(-$0.minutesAgo * 60), bpm: $0.bpm) }
    }

    @Test("1. Cold Start: sitting still, HR ~70 → Not ready, suggests March in Place + Arm Circles")
    func coldStart() {
        let history = samples([(9, 68), (6, 71), (3, 69), (1, 70)])
        let input = ReadinessInput(currentHR: HeartRateSample(date: now, bpm: 70), history: history,
                                   recentActiveEnergy: 4, zones: zones, now: now)
        let assessment = ReadinessEngine().evaluate(input)
        #expect(assessment.status == .notWarmedUp)
        #expect(assessment.reasons == [.belowTargetZone])

        let recovery = RecoveryContext(workout: .outdoorRun, physiology: physiology, sleepHours: 7.5,
                                       restingHRBaseline: 64, startHour: 17)
        let plan = WarmUpPlanner().plan(for: recovery)
        #expect(plan.durationMinutes == 3)
        #expect(plan.steps.map(\.exercise) == [.marchInPlace, .armCircles])

        let message = TemplateCoach.unreadyMessage(CoachContext(recovery: recovery, assessment: assessment, plan: plan))
        #expect(message.contains("70 bpm"))
        #expect(message.contains("3-minute"))
        #expect(SafetyGuardrail.validate(message) != nil)
    }

    @Test("3. Warm Start: brisk walk 6 minutes, HR ~118 → Ready without interruption")
    func warmStart() {
        let history = samples([(10, 70), (8, 72), (6, 88), (5, 101), (4, 108), (3, 112), (2, 115), (1, 117)])
        let input = ReadinessInput(currentHR: HeartRateSample(date: now, bpm: 118), history: history,
                                   recentActiveEnergy: 32, zones: zones, now: now)
        let assessment = ReadinessEngine().evaluate(input)
        #expect(assessment.status == .ready)
        #expect(assessment.reasons.contains { if case .sustainedElevation = $0 { true } else { false } })
    }

    @Test("2. Guided Execution: 15x Arm Circles → .success at count 15, next exercise, idle 6 s → pause + reminder")
    func guidedExecution() {
        let plan = WarmUpPlan(steps: [WarmUpStep(exercise: .armCircles, target: .reps(15)),
                                      WarmUpStep(exercise: .torsoTwist, target: .reps(15))],
                              durationMinutes: 3, adjustments: [])
        let engine = GuidedWarmUpEngine(plan: plan)
        var events: [GuidedWarmUpEngine.Event] = []
        let hz = 50.0
        let period = 1.5 // seconds per arm circle
        var t = 0.0

        // 20 circles simulated; only 15 may count toward the first exercise.
        while t < period * 17 {
            if Int(t * hz) % 25 == 0 {
                events += engine.ingest(prediction: MotionPrediction(label: .armCircles, confidence: 0.92, timestamp: t))
            }
            let phase = 2 * Double.pi * t / period
            let frame = MotionFrame(timestamp: t, userAcceleration: Vector3(0.3 * sin(phase), 0, 0),
                                    rotationRate: Vector3(0, 4, 0), gravity: Vector3(-cos(phase), sin(phase), 0))
            events += engine.ingest(frame: frame)
            t += 1 / hz
            if engine.currentIndex == 1 { break }
        }

        let counts = events.compactMap { if case .progress(0, let v, _) = $0 { Int(v) } else { nil } }
        #expect(counts == Array(1...15))
        #expect(events.contains(.stepCompleted(index: 0)))
        #expect(events.contains(.stepStarted(index: 1)))
        #expect(engine.currentIndex == 1)

        // User stays idle for 6 seconds during the 2nd exercise.
        events.removeAll()
        let idleStart = t
        while t < idleStart + 6 {
            if Int(t * hz) % 25 == 0 {
                events += engine.ingest(prediction: MotionPrediction(label: .idle, confidence: 0.97, timestamp: t))
            }
            events += engine.ingest(frame: MotionFrame(timestamp: t, userAcceleration: .zero, rotationRate: .zero,
                                                       gravity: Vector3(0, 0, -1)))
            t += 1 / hz
        }
        #expect(events.contains(.paused(index: 1)))
        #expect(events.contains(.idleReminder(index: 1)))
        #expect(engine.isPaused)
        #expect(engine.progressValue == 0)
    }
}

@Suite("Anti-cheat & components")
struct ComponentTests {
    @Test("Confidence < 80% or wrong exercise does not increase the count")
    func lowConfidenceDoesNotCount() {
        let plan = WarmUpPlan(steps: [WarmUpStep(exercise: .marchInPlace, target: .duration(10))], durationMinutes: 3, adjustments: [])
        let engine = GuidedWarmUpEngine(plan: plan)
        var t = 0.0
        while t < 5 {
            _ = engine.ingest(prediction: MotionPrediction(label: .marchInPlace, confidence: 0.6, timestamp: t))
            _ = engine.ingest(frame: MotionFrame(timestamp: t, userAcceleration: Vector3(0.2, 0, 0), rotationRate: .zero, gravity: Vector3(-1, 0, 0)))
            t += 0.02
        }
        #expect(engine.progressValue == 0)

        while t < 8 {
            _ = engine.ingest(prediction: MotionPrediction(label: .armCircles, confidence: 0.95, timestamp: t))
            _ = engine.ingest(frame: MotionFrame(timestamp: t, userAcceleration: Vector3(0.2, 0, 0), rotationRate: .zero, gravity: Vector3(-1, 0, 0)))
            t += 0.02
        }
        #expect(engine.progressValue == 0)

        var completed = false
        while t < 20, !completed {
            _ = engine.ingest(prediction: MotionPrediction(label: .marchInPlace, confidence: 0.9, timestamp: t))
            completed = engine.ingest(frame: MotionFrame(timestamp: t, userAcceleration: Vector3(0.2, 0, 0), rotationRate: .zero, gravity: Vector3(-1, 0, 0))).contains(.allCompleted)
            t += 0.02
        }
        #expect(completed)
        #expect(abs(t - 18) < 0.1) // 10 active seconds after t = 8
    }

    @Test("Karvonen: RHR 65, age 30 → Max HR 187, zone 126–150")
    func karvonen() {
        let z = HeartRateZones(physiology: UserPhysiology(age: 30, restingHR: 65))
        #expect(z.maxHR == 187)
        #expect(Int(z.lowerBound.rounded()) == 126)
        #expect(Int(z.upperBound.rounded()) == 150)
        let pct = HeartRateZones(physiology: UserPhysiology(age: 30, restingHR: 65), configuration: ZoneConfiguration(method: .percentMaxHR))
        #expect(Int(pct.lowerBound.rounded()) == 94)
    }

    @Test("Short sleep & early morning → duration extended 3 → 5 minutes")
    func calibration() {
        let ctx = RecoveryContext(workout: .racket, physiology: UserPhysiology(age: 25, restingHR: 60),
                                  sleepHours: 5.2, restingHRBaseline: 58, startHour: 6)
        let plan = WarmUpPlanner().plan(for: ctx)
        #expect(plan.durationMinutes == 5)
        #expect(plan.adjustments.count == 2)
        #expect(plan.steps.first?.exercise == .armCircles)
    }

    @Test("Planner rejects out-of-bounds AI output")
    func plannerClamps() {
        let plan = WarmUpPlanner().plan(exercises: [.torsoTwist, .torsoTwist], durationMinutes: 12, adjustments: [])
        #expect(plan.durationMinutes == 5)
        #expect(plan.steps.count == 2)
        #expect(Set(plan.steps.map(\.exercise)).count == 2)
    }

    @Test("Guardrail rejects medical claims")
    func guardrail() {
        #expect(SafetyGuardrail.validate("You might have an arrhythmia, get checked right away.") == nil)
        #expect(SafetyGuardrail.validate("Let's warm up for 3 minutes so your muscles aren't caught off guard!") != nil)
    }

    @Test("Heuristic distinguishes idle, arm circles, torso twist, march")
    func heuristic() {
        let c = HeuristicMotionClassifier()
        func window(_ make: (Double) -> MotionFrame) -> [MotionFrame] { (0..<100).map { make(Double($0) / 50) } }

        let idle = window { MotionFrame(timestamp: $0, userAcceleration: Vector3(0.01, 0, 0), rotationRate: Vector3(0.05, 0, 0), gravity: Vector3(0, 0, -1)) }
        #expect(c.classify(idle)?.label == .idle)

        let arm = window { t in
            let p = 2 * Double.pi * t / 1.5
            return MotionFrame(timestamp: t, userAcceleration: Vector3(0.4 * sin(p), 0.3 * cos(p), 0), rotationRate: Vector3(0, 4.2, 0), gravity: Vector3(-cos(p), sin(p), 0))
        }
        let armPrediction = c.classify(arm)
        #expect(armPrediction?.label == .armCircles)
        #expect((armPrediction?.confidence ?? 0) >= 0.8)

        let twist = window { t in
            let p = 2 * Double.pi * t / 2
            return MotionFrame(timestamp: t, userAcceleration: Vector3(0.2 * sin(p), 0, 0), rotationRate: Vector3(0.1, 0.2, -3 * sin(p)), gravity: Vector3(0, 0, -1))
        }
        #expect(c.classify(twist)?.label == .torsoTwist)

        let march = window { t in
            let p = 2 * Double.pi * t / 0.8
            return MotionFrame(timestamp: t, userAcceleration: Vector3(0.25 * sin(p), 0.15 * cos(p), 0.1), rotationRate: Vector3(0.1, 0.2, 1.5 * sin(p)), gravity: Vector3(-0.95, 0.3 * sin(p), 0))
        }
        #expect(c.classify(march)?.label == .marchInPlace)
    }

    @Test("CreateML labels are normalized")
    func labels() {
        #expect(MotionLabel(classLabel: "arm_circles") == .armCircles)
        #expect(MotionLabel(classLabel: "High Knees") == .marchInPlace)
        #expect(MotionLabel(classLabel: "random") == .other)
    }
}
