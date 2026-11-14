import Charts
import SwiftUI
import WarmUpCore

/// Readable name for a motion class label (e.g. "armCircles" → "Arm Circles").
func moveName(_ label: String) -> String {
    let motion = MotionLabel(classLabel: label)
    return motion.exercise?.displayName ?? (motion == .idle ? "Standing still" : "Other movement")
}

func percent(_ value: Double?) -> String {
    value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
}

// MARK: - Model › Retrain results

/// The outcome of one Retrain: a verdict, an accuracy comparison against the 85% bar, and per-move accuracy.
struct TrainingResultSections: View {
    let result: TrainingResult
    let canSend: Bool
    let details: String?
    let send: () -> Void

    private struct Bar: Identifiable {
        let name: String, accuracy: Double, highlight: Bool
        var id: String { name }
    }

    var body: some View {
        let accuracy = result.candidate.accuracy
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: result.promote ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(result.promote ? .green : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.promote ? "Ready to send to the watch" : "Not good enough yet")
                        .font(.headline)
                    Text(result.promote
                         ? "The new model recognised \(percent(accuracy)) of moves from people it never trained on."
                         : verdictHint(accuracy))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            if canSend {
                Button(action: send) {
                    Label("Send to Watch", systemImage: "applewatch.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        } header: {
            Text("Result")
        }

        if result.candidate.total > 0 {
            Section {
                let bars = comparison()
                Chart {
                    ForEach(bars) { bar in
                        BarMark(x: .value("Accuracy", bar.accuracy * 100), y: .value("Model", bar.name))
                            .foregroundStyle(bar.highlight ? Color.accentColor : Color.gray.opacity(0.5))
                            .annotation(position: .trailing) { Text(percent(bar.accuracy)).font(.caption) }
                    }
                    RuleMark(x: .value("Target", 85))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) { Text("85% target").font(.caption2).foregroundStyle(.green) }
                }
                .chartXScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                    }
                }
                .frame(height: CGFloat(bars.count) * 44 + 30)
            } header: {
                Text("Accuracy on new people")
            } footer: {
                Text("Tested on people the model has never seen, so the score reflects how it will work for someone new.")
            }

            Section("How well each move is recognised") {
                ForEach(result.candidate.labels, id: \.self) { label in
                    let value = result.candidate.sensitivity(of: label) ?? 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(moveName(label))
                            Spacer()
                            Text(percent(value)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView(value: value).tint(value >= 0.85 ? .green : .orange)
                    }
                }
            }
        }

        if !result.rejected.isEmpty || details != nil {
            Section {
                if !result.rejected.isEmpty {
                    LabeledContent("Recordings left out", value: "\(result.rejected.count)")
                }
                if let details {
                    DisclosureGroup("Technical details") {
                        ScrollView(.horizontal) {
                            Text(details).font(.caption2.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            } footer: {
                if !result.rejected.isEmpty {
                    Text("Recordings that were too short, too slow or had gaps are not used for training.")
                }
            }
        }
    }

    private func verdictHint(_ accuracy: Double?) -> String {
        guard result.candidate.total > 0 else { return "Collect data from at least 2 participants with 2 or more moves, then retrain." }
        return "It recognised \(percent(accuracy)) of moves, below the 85% target or not better than the current model. Collect more recordings and retrain."
    }

    private func comparison() -> [Bar] {
        var bars = [Bar(name: "New model", accuracy: result.candidate.accuracy ?? 0, highlight: true)]
        if let current = result.current, let a = current.accuracy { bars.append(Bar(name: "Current model", accuracy: a, highlight: false)) }
        if let a = result.baseline.accuracy { bars.append(Bar(name: "Built-in", accuracy: a, highlight: false)) }
        return bars
    }
}

// MARK: - Evaluation

/// How well the readiness check and rep counting match what really happened in Study Mode sessions.
struct EvaluationScreen: View {
    @Environment(CompanionStore.self) private var store

    var body: some View {
        let report = ReadinessReport(entries: store.allSessions)
        let referenced = report.sessions - report.withoutReference
        NavigationStack {
            List {
                if referenced == 0 {
                    ContentUnavailableView("No study sessions yet", systemImage: "checkmark.seal",
                                           description: Text("Turn on Study Mode, pick a scenario before each session, and finish the workout on the watch. Results appear here."))
                } else {
                    Section {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            tile("Correct calls", percent(report.overall.accuracy), "checkmark.circle", "Watch matched reality")
                            tile("Caught cold starts", percent(report.overall.sensitivity), "thermometer.low", "Not-warm users flagged")
                            tile("No false alarms", percent(report.overall.specificity), "bell.slash", "Warm users let through")
                            tile("Fast check", percent(report.latencyWithinBudget), "timer", "Decided within 3 s")
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text("\(referenced) study session\(referenced == 1 ? "" : "s") with a known scenario.")
                    }

                    Section("Watch said vs. what was true") {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                Text("")
                                Text("Said “warm up”").font(.caption).foregroundStyle(.secondary)
                                Text("Said “ready”").font(.caption).foregroundStyle(.secondary)
                            }
                            GridRow {
                                Text("Was cold").font(.subheadline)
                                cell(report.overall.truePositive, good: true)
                                cell(report.overall.falseNegative, good: false)
                            }
                            GridRow {
                                Text("Was warm").font(.subheadline)
                                cell(report.overall.falsePositive, good: false)
                                cell(report.overall.trueNegative, good: true)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if !report.perParticipant.isEmpty {
                        Section("Per participant") {
                            ForEach(report.perParticipant.keys.sorted(), id: \.self) { person in
                                let m = report.perParticipant[person]!
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(person)
                                        Spacer()
                                        Text("\(percent(m.accuracy)) of \(m.total)").monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    ProgressView(value: m.accuracy ?? 0).tint((m.accuracy ?? 0) >= 0.8 ? .green : .orange)
                                }
                            }
                        }
                    }

                    if !report.repErrors.isEmpty {
                        Section {
                            ForEach(report.repErrors.keys.sorted { $0.displayName < $1.displayName }, id: \.self) { exercise in
                                let errors = report.repErrors[exercise] ?? []
                                let mean = errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count)
                                LabeledContent(exercise.displayName, value: String(format: "± %.1f reps", mean))
                            }
                        } header: {
                            Text("Rep counting")
                        } footer: {
                            Text("Average difference between the watch’s count and the researcher’s manual count.")
                        }
                    }

                    Section {
                        LabeledContent("Heart rate confirmed after warm-up",
                                       value: "\(report.finalConfirmation.confirmed) of \(report.finalConfirmation.total)")
                        LabeledContent("Sessions with heart-rate gaps", value: "\(report.sessionsWithGaps)")
                        DisclosureGroup("Technical details") {
                            ScrollView(.horizontal) {
                                Text(store.readinessReport).font(.caption2.monospaced()).textSelection(.enabled)
                            }
                        }
                    } header: {
                        Text("Data quality")
                    }
                }
            }
            .navigationTitle("Evaluation")
            .refreshable { store.refreshInventory() }
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func cell(_ n: Int, good: Bool) -> some View {
        Text("\(n)")
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background((good ? Color.green : Color.orange).opacity(0.15), in: .rect(cornerRadius: 8))
    }
}
