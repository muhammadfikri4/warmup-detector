import Foundation

// Pipeline tahap 5 (Evaluate) — sensitivity, PPV, dan perbandingan dengan referensi.

/// Metrik biner. Kelas positif = kondisi yang ingin dideteksi.
public struct BinaryMetrics: Codable, Sendable, Equatable {
    public var truePositive = 0
    public var falsePositive = 0
    public var trueNegative = 0
    public var falseNegative = 0

    public init() {}

    public mutating func add(truth: Bool, predicted: Bool) {
        switch (truth, predicted) {
        case (true, true): truePositive += 1
        case (false, true): falsePositive += 1
        case (false, false): trueNegative += 1
        case (true, false): falseNegative += 1
        }
    }

    public var total: Int { truePositive + falsePositive + trueNegative + falseNegative }
    /// Dari yang benar-benar positif, berapa yang tertangkap.
    public var sensitivity: Double? { ratio(truePositive, truePositive + falseNegative) }
    public var specificity: Double? { ratio(trueNegative, trueNegative + falsePositive) }
    /// Dari yang diprediksi positif, berapa yang benar.
    public var ppv: Double? { ratio(truePositive, truePositive + falsePositive) }
    public var npv: Double? { ratio(trueNegative, trueNegative + falseNegative) }
    public var accuracy: Double? { ratio(truePositive + trueNegative, total) }
}

/// Laporan klasifikasi multi-kelas (confusion matrix + sensitivity/PPV per kelas).
public struct ClassificationReport: Sendable, Equatable {
    /// truth → predicted → jumlah
    public private(set) var counts: [String: [String: Int]] = [:]

    public init() {}

    public mutating func add(truth: String, predicted: String, count: Int = 1) {
        counts[truth, default: [:]][predicted, default: 0] += count
    }

    public mutating func merge(_ other: ClassificationReport) {
        for (t, row) in other.counts { for (p, n) in row { add(truth: t, predicted: p, count: n) } }
    }

    public var labels: [String] {
        Set(counts.keys).union(counts.values.flatMap(\.keys)).sorted()
    }

    public var total: Int { counts.values.flatMap(\.values).reduce(0, +) }
    public var correct: Int { counts.reduce(0) { $0 + ($1.value[$1.key] ?? 0) } }
    public var accuracy: Double? { ratio(correct, total) }

    public func support(of label: String) -> Int { counts[label]?.values.reduce(0, +) ?? 0 }
    public func sensitivity(of label: String) -> Double? { ratio(counts[label]?[label] ?? 0, support(of: label)) }
    public func ppv(of label: String) -> Double? {
        ratio(counts[label]?[label] ?? 0, counts.values.reduce(0) { $0 + ($1[label] ?? 0) })
    }

    public var macroSensitivity: Double? {
        let values = labels.filter { support(of: $0) > 0 }.compactMap(sensitivity(of:))
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    public func formatted(title: String) -> String {
        var lines = ["\(title) — akurasi \(pct(accuracy)), rata-rata sensitivity \(pct(macroSensitivity)), n = \(total) jendela"]
        lines.append(pad("kelas", 14) + pad("n", 7) + pad("sensitivity", 13) + "PPV")
        for label in labels {
            lines.append(pad(label, 14) + pad("\(support(of: label))", 7) + pad(pct(sensitivity(of: label)), 13) + pct(ppv(of: label)))
        }
        lines.append("confusion (baris = kebenaran, kolom = prediksi):")
        lines.append(pad("", 14) + labels.map { pad(String($0.prefix(6)), 8) }.joined())
        for t in labels {
            lines.append(pad(t, 14) + labels.map { pad("\(counts[t]?[$0] ?? 0)", 8) }.joined())
        }
        return lines.joined(separator: "\n")
    }
}

/// Evaluasi log sesi Mode Studi terhadap referensi.
public struct ReadinessReport: Sendable {
    /// Positif = "Belum Pemanasan" (kondisi berisiko yang ingin ditangkap).
    public var overall = BinaryMetrics()
    public var perParticipant: [String: BinaryMetrics] = [:]
    public var sessions = 0
    public var withoutReference = 0
    public var latencies: [TimeInterval] = []
    public var repErrors: [Exercise: [Double]] = [:]
    public var repRelativeErrors: [Exercise: [Double]] = [:]
    public var sessionsWithGaps = 0
    public var removedHRSamples = 0
    public var finalConfirmation = (confirmed: 0, total: 0)

    public init(entries: [SessionLogEntry]) {
        sessions = entries.count
        for e in entries {
            latencies.append(e.checkLatency)
            if !e.hrQuality.gaps.isEmpty { sessionsWithGaps += 1 }
            removedHRSamples += e.hrQuality.removedCount
            if let c = e.finalConfirmed {
                finalConfirmation.total += 1
                if c { finalConfirmation.confirmed += 1 }
            }
            for step in e.steps {
                guard let reference = step.referenceReps, case .reps = step.target else { continue }
                let error = abs(step.counted - Double(reference))
                repErrors[step.exercise, default: []].append(error)
                if reference > 0 { repRelativeErrors[step.exercise, default: []].append(error / Double(reference)) }
            }
            guard let expected = e.scenario.expectedStatus else {
                withoutReference += 1
                continue
            }
            let truth = expected == .notWarmedUp
            let predicted = e.predicted == .notWarmedUp
            overall.add(truth: truth, predicted: predicted)
            perParticipant[e.participant ?? "?", default: BinaryMetrics()].add(truth: truth, predicted: predicted)
        }
    }

    public var latencyWithinBudget: Double? {
        ratio(latencies.filter { $0 <= 3 }.count, latencies.count)
    }

    public func formatted() -> String {
        var l: [String] = []
        l.append("== Kesiapan (positif = Belum Pemanasan) ==")
        l.append("Sesi: \(sessions), berlabel referensi: \(overall.total), tanpa referensi: \(withoutReference)")
        l.append("TP \(overall.truePositive)  FP \(overall.falsePositive)  TN \(overall.trueNegative)  FN \(overall.falseNegative)")
        l.append("Sensitivity \(pct(overall.sensitivity))  Specificity \(pct(overall.specificity))  PPV \(pct(overall.ppv))  NPV \(pct(overall.npv))  Akurasi \(pct(overall.accuracy))")
        if !perParticipant.isEmpty {
            l.append("Per partisipan:")
            for (p, m) in perParticipant.sorted(by: { $0.key < $1.key }) {
                l.append("  \(p): n=\(m.total) sensitivity \(pct(m.sensitivity)) PPV \(pct(m.ppv)) akurasi \(pct(m.accuracy))")
            }
        }
        l.append("")
        l.append("== Latensi pengecekan (target ≤ 3 dtk) ==")
        let sorted = latencies.sorted()
        if !sorted.isEmpty {
            l.append(String(format: "median %.2f dtk, maks %.2f dtk, ≤ 3 dtk: %@", sorted[sorted.count / 2], sorted.last!, pct(latencyWithinBudget)))
        }
        l.append("")
        l.append("== Hitungan repetisi vs hitungan manual ==")
        if repErrors.isEmpty { l.append("Belum ada referensi manual.") }
        for (exercise, errors) in repErrors.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let mae = errors.reduce(0, +) / Double(errors.count)
            let rel = repRelativeErrors[exercise] ?? []
            let mape = rel.isEmpty ? nil : rel.reduce(0, +) / Double(rel.count)
            l.append(String(format: "%@: n=%d, rata-rata selisih %.1f rep, galat relatif %@", exercise.displayName, errors.count, mae, pct(mape)))
        }
        l.append("")
        l.append("== Kualitas data HR ==")
        l.append("Sesi dengan celah data: \(sessionsWithGaps)/\(sessions), sampel HR dibuang: \(removedHRSamples)")
        if finalConfirmation.total > 0 {
            l.append("Konfirmasi akhir masuk zona: \(finalConfirmation.confirmed)/\(finalConfirmation.total)")
        }
        return l.joined(separator: "\n")
    }
}

func ratio(_ a: Int, _ b: Int) -> Double? { b > 0 ? Double(a) / Double(b) : nil }

public func pct(_ value: Double?) -> String {
    value.map { String(format: "%.1f%%", $0 * 100) } ?? "–"
}

private func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
}
