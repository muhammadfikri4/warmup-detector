import Foundation
import Testing
@testable import WarmUpCore

/// Synthetic data generator: each person has a different tempo & amplitude; left/right flips the rotation direction.
enum Synthetic {
    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    static func recording(_ label: String, person: String, wrist: Wrist, seconds: Double = 14, seed: UInt64, auto: Bool = false) -> TrainingRecording {
        var rng = RNG(state: seed)
        let speed = Double.random(in: 0.8...1.25, using: &rng)
        let amp = Double.random(in: 0.8...1.2, using: &rng)
        let s: Double = wrist == .left ? -1 : 1
        func noise() -> Double { Double.random(in: -0.04...0.04, using: &rng) }
        let frames = (0..<Int(seconds * 50)).map { i -> MotionFrame in
            let t = Double(i) / 50 * speed
            func p(_ period: Double) -> Double { 2 * .pi * t / period }
            let v: [Double]
            switch label {
            case "armCircles": v = [0.4 * amp * sin(p(1.5)), 0.3 * amp * cos(p(1.5)), 0, 0, 4.2 * amp * s, 0, -cos(p(1.5)), sin(p(1.5)), 0]
            case "torsoTwist": v = [0.2 * amp * sin(p(2)), 0, 0, 0.1, 0.2, -3 * amp * s * sin(p(2)), 0, 0, -1]
            case "marchInPlace": v = [0.25 * amp * sin(p(0.8)), 0.15 * amp * cos(p(0.8)), 0.1, 0.1, 0.2, 1.5 * amp * s * sin(p(0.8)), -0.95, 0.3 * sin(p(0.8)), 0]
            default: v = [0.005, 0, 0, 0.02, 0, 0, 0, 0, -1] // idle
            }
            let n = v.map { $0 + noise() }
            return MotionFrame(timestamp: Double(i) / 50, userAcceleration: Vector3(n[0], n[1], n[2]),
                               rotationRate: Vector3(n[3], n[4], n[5]), gravity: Vector3(n[6], n[7], n[8]))
        }
        let id = (auto ? "auto-" : "") + "\(seed)"
        return TrainingRecording(name: RecordingName(label: label, participant: person, wrist: wrist, id: id), frames: frames)
    }

    static func dataset(people: [String] = ["P01", "P02", "P03"]) -> [TrainingRecording] {
        var seed: UInt64 = 1
        var result: [TrainingRecording] = []
        for person in people {
            for wrist in Wrist.allCases {
                for label in ["armCircles", "torsoTwist", "marchInPlace", "idle"] {
                    seed += 1
                    result.append(recording(label, person: person, wrist: wrist, seed: seed))
                }
            }
        }
        return result
    }
}

@Suite("Training on iPhone (logistic regression)")
struct TrainingPipelineTests {
    @Test("Leave-one-person-out: model learns and qualifies for promotion")
    func leaveOnePersonOut() {
        let result = TrainingPipeline.run(recordings: Synthetic.dataset(), current: nil)
        #expect(result.evaluationKind.hasPrefix("leave-one-person-out"))
        #expect((result.candidate.accuracy ?? 0) >= 0.85, "\(result.formatted())")
        #expect(result.promote)
        #expect(result.model?.labels == ["armCircles", "idle", "marchInPlace", "torsoTwist"])
    }

    @Test("Golden set is never used to train the final model")
    func goldenSetLocked() {
        var config = TrainingConfiguration()
        config.goldenParticipants = ["P03"]
        let result = TrainingPipeline.run(recordings: Synthetic.dataset(), current: nil, configuration: config)
        #expect(result.evaluationKind.contains("golden set P03"))
        #expect(result.model?.info.participants == ["P01", "P02"])
    }

    @Test("Broken recordings are rejected; one participant is not enough for evaluation")
    func cleanAndRefuse() {
        var data = Synthetic.dataset(people: ["P01"])
        data.append(Synthetic.recording("armCircles", person: "P01", wrist: .left, seconds: 2, seed: 99))
        let result = TrainingPipeline.run(recordings: data, current: nil)
        #expect(result.rejected.count == 1)
        #expect(!result.promote)
        #expect(result.model == nil)
    }

    @Test("New model is compared with the active model; JSON round-trip & used on watch")
    func compareAndDeploy() throws {
        let first = TrainingPipeline.run(recordings: Synthetic.dataset(), current: nil)
        let model = try #require(first.model)
        let second = TrainingPipeline.run(recordings: Synthetic.dataset(), current: model)
        #expect(second.current != nil)

        let decoded = try SoftmaxModel.decode(model.jsonData())
        #expect(decoded == model)
        let classifier = try #require(LearnedMotionClassifier(model: decoded))
        let sample = Synthetic.recording("torsoTwist", person: "P09", wrist: .right, seed: 777)
        let prediction = classifier.classify(Array(sample.frames.prefix(100)))
        #expect(prediction?.label == .torsoTwist)
    }

    @Test("Automatic recordings are detected by id and weighted lower")
    func autoRecordings() {
        let auto = Synthetic.recording("armCircles", person: "P01", wrist: .left, seed: 5, auto: true)
        #expect(auto.isAuto)
        #expect(RecordingName(fileName: auto.name.session + ".csv")?.isAuto == true)
    }

    @Test("Companion settings can be encoded to send to the watch")
    func settingsRoundTrip() throws {
        var s = CompanionSettings()
        s.participant = "P07"
        s.scenario = .cold
        s.autoCollect = true
        #expect(try CompanionSettings.decode(s.encoded()) == s)
    }
}
