import Foundation
import FoundationModels
import WarmUpCore

/// Pilar 3 — Interpretation (FR-I01 … FR-I04).
///
/// Catatan platform: di watchOS 27, `SystemLanguageModel` (on-device) TIDAK tersedia; yang tersedia adalah
/// `PrivateCloudComputeLanguageModel` (Apple Private Cloud Compute — server Apple, bukan pihak ketiga).
/// Karena itu:
/// 1. Teks template deterministik selalu tampil lebih dulu (instan, offline).
/// 2. Bila diizinkan pengguna & tersedia, Apple Intelligence menyempurnakan teks/rencana di belakang layar.
/// 3. Hanya angka turunan yang dikirim (HR, RHR, jam tidur, jenis olahraga, jam) — tanpa identitas.
/// 4. Semua keluaran AI melewati `SafetyGuardrail` + `WarmUpPlanner` (NFR-04); gagal → tetap template.
final class CoachService {
    struct PlanSuggestion: Sendable {
        var message: String
        var plan: WarmUpPlan
        var cues: [String]
    }

    var isEnabled: Bool { AppSettings.useAppleIntelligence }

    var availabilityText: String {
        switch PrivateCloudComputeLanguageModel().availability {
        case .available: "Tersedia"
        case .unavailable(.deviceNotEligible): "Perangkat tidak mendukung"
        case .unavailable(.systemNotReady): "Belum siap"
        case .unavailable: "Tidak tersedia"
        }
    }

    private var canUseAI: Bool { isEnabled && PrivateCloudComputeLanguageModel().isAvailable }

    /// FR-I01 + FR-I02 + FR-I03: penjelasan, durasi, urutan gerakan, dan cue suara.
    func suggestPlan(for context: CoachContext, timeout: TimeInterval = 8) async -> PlanSuggestion? {
        guard canUseAI else { return nil }
        let prompt = Self.planPrompt(context)
        let generated = await withTimeout(timeout) {
            let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(),
                                               instructions: SafetyGuardrail.instructions)
            return try await session.respond(to: prompt, generating: AIWarmUpPlan.self).content
        }
        guard let generated, let message = SafetyGuardrail.validate(generated.explanation) else { return nil }

        let plan = WarmUpPlanner().plan(exercises: generated.exercises.map(\.exercise),
                                        durationMinutes: generated.durationMinutes,
                                        adjustments: context.plan.adjustments)
        let cues = generated.cues.compactMap { SafetyGuardrail.validate($0, maxLength: 140) }
        return PlanSuggestion(message: message, plan: plan, cues: cues.count == plan.steps.count ? cues : [])
    }

    /// FR-I04: catatan singkat untuk riwayat latihan.
    func summaryNote(_ summary: WarmUpSummary, workout: WorkoutKind) async -> String {
        let fallback = TemplateCoach.summary(summary)
        guard canUseAI, !summary.skipped else { return fallback }
        let prompt = """
        Rangkum respons tubuh selama pemanasan sebelum \(workout.displayName) dalam 1 kalimat (maks 160 karakter).
        Data: \(fallback)
        Laju kenaikan HR: \(summary.riseBpmPerMinute.map { String(format: "%.1f bpm/menit", $0) } ?? "tidak diketahui").
        """
        let text = await withTimeout(8) {
            let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(),
                                               instructions: SafetyGuardrail.instructions)
            return try await session.respond(to: prompt).content
        }
        return text.flatMap { SafetyGuardrail.validate($0, maxLength: 200) } ?? fallback
    }

    private static func planPrompt(_ ctx: CoachContext) -> String {
        let r = ctx.recovery
        let a = ctx.assessment
        return """
        Pengguna akan \(r.workout.displayName) pukul \(r.startHour).00 dan belum pemanasan.
        HR saat ini: \(a.heartRate.map { "\(Int($0)) bpm" } ?? "belum terbaca"); zona siap: \(a.zones.rangeText).
        RHR pagi ini: \(Int(r.physiology.restingHR)) bpm\(r.restingHRBaseline.map { " (rata-rata 30 hari \(Int($0)) bpm)" } ?? "").
        Tidur semalam: \(r.sleepHours.map { String(format: "%.1f jam", $0) } ?? "tidak ada data").
        HRV (SDNN): \(r.hrvSDNN.map { "\(Int($0)) ms" } ?? "tidak ada data")\(r.hrvBaseline.map { " (rata-rata 30 hari \(Int($0)) ms)" } ?? "").
        Rencana dasar: \(ctx.plan.durationMinutes) menit, \(ctx.plan.exerciseListText).
        Penyesuaian dari data pemulihan: \(ctx.plan.adjustments.isEmpty ? "tidak ada" : String(describing: ctx.plan.adjustments)).
        Pilih 2–3 gerakan paling relevan dengan olahraga ini (fokus Arm Circles & Torso Twist untuk raket/beban, \
        March in Place untuk lari/sepeda), tentukan durasi 3–5 menit (lebih panjang bila kurang tidur atau pagi hari), \
        tulis penjelasan ramah maks 2 kalimat, dan satu instruksi suara singkat per gerakan.
        """
    }
}

@Generable
struct AIWarmUpPlan {
    @Guide(description: "Penjelasan ramah maks 2 kalimat mengapa perlu pemanasan, menyebut angka HR yang diberikan.")
    var explanation: String

    @Guide(description: "Durasi pemanasan dalam menit.", .range(3...5))
    var durationMinutes: Int

    @Guide(description: "Urutan gerakan pemanasan.", .minimumCount(2), .maximumCount(3))
    var exercises: [AIExercise]

    @Guide(description: "Satu instruksi suara singkat (maks 12 kata) untuk tiap gerakan, urutan sama dengan exercises.")
    var cues: [String]
}

@Generable
enum AIExercise {
    case armCircles
    case marchInPlace
    case torsoTwist

    var exercise: Exercise {
        switch self {
        case .armCircles: .armCircles
        case .marchInPlace: .marchInPlace
        case .torsoTwist: .torsoTwist
        }
    }
}

/// Menjalankan operasi async dengan batas waktu; `nil` bila timeout atau error.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
