import Charts
import SwiftUI
import WarmUpCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Insights: charts of finished workouts plus a short summary written by Apple Intelligence
/// (with a built-in summary when Apple Intelligence isn't available).
struct InsightsScreen: View {
    @Environment(CompanionStore.self) private var store
    @State private var summarizer = InsightSummarizer()

    var body: some View {
        let stats = InsightStats(entries: store.allSessions)
        NavigationStack {
            ScrollView {
                if stats.total == 0 {
                    ContentUnavailableView("No insights yet", systemImage: "chart.xyaxis.line",
                                           description: Text("Finish a workout on your watch. Insights appear here."))
                        .padding(.top, 80)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        SummaryCard(summarizer: summarizer, stats: stats)
                        StatTiles(stats: stats)
                        WeeklyChart(stats: stats)
                        StartHeartRateChart(stats: stats)
                    }
                    .padding()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Insights")
            .refreshable { store.refreshInventory() }
            .task(id: stats.total) { await summarizer.summarize(stats) }
        }
    }
}

// MARK: - Summary

@MainActor @Observable
final class InsightSummarizer {
    private(set) var text = ""
    private(set) var fromAI = false
    private(set) var isWorking = false

    /// Shows the built-in summary at once, then replaces it with Apple Intelligence's when available.
    func summarize(_ stats: InsightStats) async {
        text = TemplateCoach.insightSummary(stats)
        fromAI = false
        guard stats.total > 0 else { return }
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let session = LanguageModelSession(instructions: SafetyGuardrail.instructions + """
                 You write a weekly recap for the WarmUp Pulse app in 2–3 short sentences. \
                Mention one thing that went well and one concrete tip about warming up.
                """)
            let response = try await session.respond(to: "Summarize these warm-up stats:\n" + stats.promptFacts)
            if let checked = SafetyGuardrail.validate(response.content, maxLength: 500) {
                text = checked
                fromAI = true
            }
        } catch {
            // Keep the built-in summary.
        }
        #endif
    }
}

private struct SummaryCard: View {
    let summarizer: InsightSummarizer
    let stats: InsightStats

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Summary", systemImage: "sparkles").font(.headline)
                Spacer()
                if summarizer.isWorking { ProgressView() }
            }
            Text(summarizer.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(summarizer.fromAI ? "Written by Apple Intelligence on this iPhone" : "Built-in summary")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await summarizer.summarize(stats) }
            } label: {
                Label("Refresh summary", systemImage: "arrow.clockwise")
            }
            .font(.footnote)
            .disabled(summarizer.isWorking)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 16))
    }
}

// MARK: - Numbers

private struct StatTiles: View {
    let stats: InsightStats

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            tile("Workouts", "\(stats.total)", "figure.run")
            tile("Warm-ups finished", stats.completionRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", "checkmark.circle")
            tile("Already warm", "\(stats.alreadyWarm)", "flame")
            tile("HR at Start", stats.averageStartHR.map { "\(Int($0.rounded())) bpm" } ?? "–", "heart")
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 16))
    }
}

// MARK: - Charts

private struct WeeklyChart: View {
    let stats: InsightStats

    private struct Bar: Identifiable {
        let week: Date, outcome: String, count: Int
        var id: String { "\(week.timeIntervalSince1970)-\(outcome)" }
    }

    var body: some View {
        let bars = stats.weeks.flatMap { w in [
            Bar(week: w.start, outcome: "Completed", count: w.completed),
            Bar(week: w.start, outcome: "Already warm", count: w.alreadyWarm),
            Bar(week: w.start, outcome: "Skipped", count: w.skipped),
        ] }
        VStack(alignment: .leading, spacing: 8) {
            Text("Warm-ups per week").font(.headline)
            Chart(bars) { bar in
                BarMark(x: .value("Week", bar.week, unit: .weekOfYear), y: .value("Workouts", bar.count))
                    .foregroundStyle(by: .value("Outcome", bar.outcome))
            }
            .chartForegroundStyleScale(["Completed": Color.orange, "Already warm": Color.green, "Skipped": Color.gray])
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            .frame(height: 200)
        }
        .padding()
        .background(.background, in: .rect(cornerRadius: 16))
    }
}

private struct StartHeartRateChart: View {
    let stats: InsightStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heart rate at Start").font(.headline)
            Text("Dots below the green band needed a warm-up.").font(.caption).foregroundStyle(.secondary)
            Chart {
                if let lo = stats.averageZoneLower, let hi = stats.averageZoneUpper {
                    RectangleMark(yStart: .value("Zone low", lo), yEnd: .value("Zone high", hi))
                        .foregroundStyle(.green.opacity(0.15))
                        .annotation(position: .overlay, alignment: .topLeading) {
                            Text("Ready zone").font(.caption2).foregroundStyle(.green)
                        }
                }
                ForEach(stats.startPoints) { p in
                    PointMark(x: .value("Date", p.date), y: .value("bpm", p.heartRate))
                        .foregroundStyle(p.ready ? Color.green : Color.orange)
                }
            }
            .chartYAxisLabel("bpm")
            .frame(height: 220)
        }
        .padding()
        .background(.background, in: .rect(cornerRadius: 16))
    }
}
