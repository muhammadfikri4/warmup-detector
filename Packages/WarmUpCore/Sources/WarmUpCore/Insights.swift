import Foundation

/// Aggregates the finished workouts the watch reports, for the iPhone Insights tab.
public struct InsightStats: Sendable, Equatable {
    public struct Week: Sendable, Equatable, Identifiable {
        public var start: Date
        public var completed: Int
        public var skipped: Int
        public var alreadyWarm: Int
        public var id: Date { start }
        public var total: Int { completed + skipped + alreadyWarm }
    }

    public struct StartPoint: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var date: Date
        public var heartRate: Double
        public var ready: Bool
    }

    public var total: Int
    public var completed: Int
    public var skipped: Int
    public var alreadyWarm: Int
    public var cancelled: Int
    public var averageStartHR: Double?
    public var averageZoneLower: Double?
    public var averageZoneUpper: Double?
    public var weeks: [Week]
    public var startPoints: [StartPoint]
    /// Most frequent workout, e.g. "Outdoor Run".
    public var topWorkout: WorkoutKind?

    /// Share of sessions that needed a warm-up and actually completed it.
    public var completionRate: Double? {
        let needed = completed + skipped + cancelled
        return needed > 0 ? Double(completed) / Double(needed) : nil
    }

    public init(entries: [SessionLogEntry], calendar: Calendar = .current) {
        let sorted = entries.sorted { $0.date < $1.date }
        total = sorted.count
        completed = sorted.filter { $0.warmUp == .completed }.count
        skipped = sorted.filter { $0.warmUp == .skipped }.count
        alreadyWarm = sorted.filter { $0.warmUp == .notNeeded }.count
        cancelled = sorted.filter { $0.warmUp == .abandoned }.count

        let hrs = sorted.compactMap(\.heartRate)
        averageStartHR = hrs.isEmpty ? nil : hrs.reduce(0, +) / Double(hrs.count)
        averageZoneLower = sorted.isEmpty ? nil : sorted.map(\.zoneLower).reduce(0, +) / Double(sorted.count)
        averageZoneUpper = sorted.isEmpty ? nil : sorted.map(\.zoneUpper).reduce(0, +) / Double(sorted.count)

        var byWeek: [Date: Week] = [:]
        for e in sorted {
            let start = calendar.dateInterval(of: .weekOfYear, for: e.date)?.start ?? calendar.startOfDay(for: e.date)
            var w = byWeek[start] ?? Week(start: start, completed: 0, skipped: 0, alreadyWarm: 0)
            switch e.warmUp {
            case .completed: w.completed += 1
            case .skipped, .abandoned: w.skipped += 1
            case .notNeeded: w.alreadyWarm += 1
            }
            byWeek[start] = w
        }
        weeks = byWeek.values.sorted { $0.start < $1.start }
        startPoints = sorted.compactMap { e in
            e.heartRate.map { StartPoint(id: e.id, date: e.date, heartRate: $0, ready: e.predicted == .ready) }
        }
        let counts = Dictionary(grouping: sorted, by: \.workout).mapValues(\.count)
        topWorkout = counts.max { a, b in a.value == b.value ? a.key.rawValue > b.key.rawValue : a.value < b.value }?.key
    }

    /// Plain numbers handed to Apple Intelligence (no dates, names or raw samples).
    public var promptFacts: String {
        var lines = [
            "Workouts logged: \(total)",
            "Already warm at Start: \(alreadyWarm)",
            "Warm-ups completed: \(completed)",
            "Warm-ups skipped or cancelled: \(skipped + cancelled)",
        ]
        if let rate = completionRate { lines.append("Warm-up completion rate: \(Int((rate * 100).rounded()))%") }
        if let hr = averageStartHR { lines.append("Average heart rate at Start: \(Int(hr.rounded())) bpm") }
        if let lo = averageZoneLower, let hi = averageZoneUpper { lines.append("Ready zone: \(Int(lo.rounded()))–\(Int(hi.rounded())) bpm") }
        if let top = topWorkout { lines.append("Most frequent workout: \(top.displayName)") }
        return lines.joined(separator: "\n")
    }
}

extension TemplateCoach {
    /// Deterministic weekly summary, shown instantly and used when Apple Intelligence is unavailable.
    public static func insightSummary(_ s: InsightStats) -> String {
        guard s.total > 0 else { return "No workouts yet. Finish a workout on your watch to see insights here." }
        var parts = ["You logged \(s.total) workout\(s.total == 1 ? "" : "s")."]
        if s.alreadyWarm > 0 { parts.append("You were already warm at Start \(s.alreadyWarm) time\(s.alreadyWarm == 1 ? "" : "s").") }
        if let rate = s.completionRate {
            let pct = Int((rate * 100).rounded())
            parts.append(pct >= 80
                ? "When a warm-up was needed, you finished it \(pct)% of the time. Nice consistency."
                : "When a warm-up was needed, you finished it \(pct)% of the time. Try not to skip it before hard sessions.")
        }
        if let hr = s.averageStartHR, let lo = s.averageZoneLower {
            parts.append("Your heart rate at Start averaged \(Int(hr.rounded())) bpm, against a ready zone that begins at \(Int(lo.rounded())) bpm.")
        }
        return parts.joined(separator: " ")
    }
}
