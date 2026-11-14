// swift-tools-version: 6.0
// WarmUpCore — pure logic (no HealthKit/CoreMotion) for the
// Prediction & Interpretation pillars, so it can be tested with `swift test` on a Mac.
//
// Mac tools (data pipeline):
//   swift run warmup-train <csv-folder> [output.mlmodel]   — clean → model → evaluate (leave-one-person-out)
//   swift run warmup-eval <sessions.jsonl>...              — readiness evaluation vs reference
import PackageDescription

let package = Package(
    name: "WarmUpCore",
    platforms: [.watchOS(.v10), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WarmUpCore", targets: ["WarmUpCore"]),
        .executable(name: "warmup-train", targets: ["WarmUpTrain"]),
        .executable(name: "warmup-eval", targets: ["WarmUpEval"]),
    ],
    targets: [
        .target(name: "WarmUpCore"),
        .executableTarget(name: "WarmUpTrain", dependencies: ["WarmUpCore"]),
        .executableTarget(name: "WarmUpEval", dependencies: ["WarmUpCore"]),
        .testTarget(name: "WarmUpCoreTests", dependencies: ["WarmUpCore"]),
    ]
)
