// swift-tools-version: 6.0
// WarmUpCore — logika murni (tanpa HealthKit/CoreMotion) untuk pilar
// Prediction & Interpretation, sehingga bisa diuji dengan `swift test` di Mac.
//
// Tool Mac (pipeline data):
//   swift run warmup-train <folder-csv> [output.mlmodel]   — clean → model → evaluate (leave-one-person-out)
//   swift run warmup-eval <sessions.jsonl>...              — evaluasi kesiapan vs referensi
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
