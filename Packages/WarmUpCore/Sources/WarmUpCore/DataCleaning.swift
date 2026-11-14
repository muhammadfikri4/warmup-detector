import Foundation

/// HR data quality report — keeps gaps & discarded data visible (pipeline stage 2: Clean).
public struct HeartRateQuality: Codable, Sendable, Equatable {
    public var inputCount: Int
    public var removedOutOfRange: Int
    public var removedSpikes: Int
    /// Intervals without samples longer than `gapThreshold`. Gaps are NOT filled/interpolated.
    public var gaps: [DateInterval]

    public init(inputCount: Int = 0, removedOutOfRange: Int = 0, removedSpikes: Int = 0, gaps: [DateInterval] = []) {
        self.inputCount = inputCount
        self.removedOutOfRange = removedOutOfRange
        self.removedSpikes = removedSpikes
        self.gaps = gaps
    }

    public var removedCount: Int { removedOutOfRange + removedSpikes }
    public var longestGapMinutes: Double { (gaps.map(\.duration).max() ?? 0) / 60 }
}

/// Cleans HR samples:
/// 1. Filter to the body's physiological range (default 35–220 bpm).
/// 2. Drop isolated spikes: a single sample that differs by > 30 bpm from both its left & right neighbors
///    (≤ 60 s), while the two neighbors agree with each other — a sign of a sensor artifact (loose watch).
/// 3. Record gaps > 150 s without filling them.
public struct HeartRateCleaner: Sendable {
    public var validRange: ClosedRange<Double> = 35...220
    public var spikeThreshold: Double = 30
    public var spikeNeighborWindow: TimeInterval = 60
    public var gapThreshold: TimeInterval = 150

    public init() {}

    public func clean(_ samples: [HeartRateSample], until end: Date? = nil) -> (samples: [HeartRateSample], quality: HeartRateQuality) {
        let sorted = samples.sorted { $0.date < $1.date }
        let inRange = sorted.filter { $0.bpm.isFinite && validRange.contains($0.bpm) }

        var kept: [HeartRateSample] = []
        var spikes = 0
        for i in inRange.indices {
            let s = inRange[i]
            if i > 0, i < inRange.count - 1 {
                let prev = inRange[i - 1], next = inRange[i + 1]
                let neighborsClose = s.date.timeIntervalSince(prev.date) <= spikeNeighborWindow
                    && next.date.timeIntervalSince(s.date) <= spikeNeighborWindow
                if neighborsClose,
                   abs(s.bpm - prev.bpm) > spikeThreshold,
                   abs(s.bpm - next.bpm) > spikeThreshold,
                   abs(prev.bpm - next.bpm) <= spikeThreshold {
                    spikes += 1
                    continue
                }
            }
            kept.append(s)
        }

        var gaps: [DateInterval] = []
        for (a, b) in zip(kept, kept.dropFirst()) where b.date.timeIntervalSince(a.date) > gapThreshold {
            gaps.append(DateInterval(start: a.date, end: b.date))
        }
        if let end, let last = kept.last, end.timeIntervalSince(last.date) > gapThreshold {
            gaps.append(DateInterval(start: last.date, end: end))
        }

        let quality = HeartRateQuality(inputCount: samples.count, removedOutOfRange: sorted.count - inRange.count,
                                       removedSpikes: spikes, gaps: gaps)
        return (kept, quality)
    }
}

/// Quality check for one motion recording (used by the training script).
public struct MotionRecordingQuality: Sendable, Equatable {
    public var sampleCount: Int
    public var duration: TimeInterval
    public var effectiveHz: Double
    /// Number of inter-sample gaps > 0.1 s (dropped samples).
    public var droppedGaps: Int
    public var nonFiniteSamples: Int

    public init(_ frames: [MotionFrame]) {
        sampleCount = frames.count
        duration = (frames.last?.timestamp ?? 0) - (frames.first?.timestamp ?? 0)
        effectiveHz = duration > 0 ? Double(frames.count - 1) / duration : 0
        droppedGaps = zip(frames, frames.dropFirst()).filter { $1.timestamp - $0.timestamp > 0.1 }.count
        nonFiniteSamples = frames.filter { f in
            ![f.userAcceleration, f.rotationRate, f.gravity].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        }.count
    }

    /// Rejection reason, or `nil` when the recording is usable.
    public func rejectionReason(minimumDuration: TimeInterval = 5, minimumHz: Double = 40) -> String? {
        if nonFiniteSamples > 0 { return "\(nonFiniteSamples) non-numeric samples" }
        if duration < minimumDuration { return String(format: "duration %.1f s < %.0f s", duration, minimumDuration) }
        if effectiveHz < minimumHz { return String(format: "sampling %.0f Hz < %.0f Hz", effectiveHz, minimumHz) }
        if Double(droppedGaps) > Double(sampleCount) * 0.05 { return "\(droppedGaps) dropped-sample gaps (> 5%)" }
        return nil
    }
}
