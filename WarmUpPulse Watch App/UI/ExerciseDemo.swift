import SwiftUI
import WarmUpCore

/// Animated stick-figure demo of a warm-up move, drawn with Canvas (no image/video assets).
/// The loop runs at the same tempo the rep counter expects, so users can match the rhythm.
struct ExerciseDemoView: View {
    let exercise: Exercise
    var accent: Color = Theme.warm
    var showsTrail = true

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isLuminanceReduced || reduceMotion)) { context in
            Canvas { gc, size in
                let t = (isLuminanceReduced || reduceMotion) ? Self.restTime(exercise) : context.date.timeIntervalSinceReferenceDate
                StickFigure(exercise: exercise, time: t, accent: accent, showsTrail: showsTrail)
                    .draw(in: &gc, size: size)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("\(exercise.displayName) demonstration")
        .accessibilityHint(exercise.instruction)
    }

    /// Representative still frame when animation is paused.
    private static func restTime(_ exercise: Exercise) -> TimeInterval {
        StickFigure.period(exercise) * 0.25
    }
}

/// Pure drawing code in a 100×100 design space, scaled to the available size.
private struct StickFigure {
    let exercise: Exercise
    let time: TimeInterval
    let accent: Color
    let showsTrail: Bool

    /// Seconds per full animation cycle: one rep for arm circles / torso twist, two steps for marching.
    static func period(_ exercise: Exercise) -> TimeInterval {
        switch exercise {
        case .armCircles: exercise.secondsPerRep ?? 2.0
        case .torsoTwist: exercise.secondsPerRep ?? 2.5
        case .marchInPlace: 1.6
        }
    }

    private var phase: Double {
        let p = Self.period(exercise)
        return time.truncatingRemainder(dividingBy: p) / p * 2 * .pi
    }

    func draw(in gc: inout GraphicsContext, size: CGSize) {
        let scale = min(size.width, size.height) / 100
        gc.translateBy(x: (size.width - 100 * scale) / 2, y: (size.height - 100 * scale) / 2)
        gc.scaleBy(x: scale, y: scale)
        switch exercise {
        case .armCircles: drawArmCircles(&gc)
        case .marchInPlace: drawMarch(&gc)
        case .torsoTwist: drawTorsoTwist(&gc)
        }
    }

    // MARK: Styles

    private let bodyColor = Color.white
    private var dimColor: Color { .white.opacity(0.35) }
    private let lineWidth: CGFloat = 5

    private func limb(_ gc: inout GraphicsContext, _ points: [CGPoint], color: Color, width: CGFloat? = nil) {
        var path = Path()
        path.addLines(points)
        gc.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width ?? lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func head(_ gc: inout GraphicsContext, at c: CGPoint) {
        gc.fill(Path(ellipseIn: CGRect(x: c.x - 7.5, y: c.y - 7.5, width: 15, height: 15)), with: .color(bodyColor))
    }

    private func ground(_ gc: inout GraphicsContext) {
        limb(&gc, [CGPoint(x: 22, y: 96), CGPoint(x: 78, y: 96)], color: .white.opacity(0.2), width: 2)
    }

    private func arrowHead(_ gc: inout GraphicsContext, at tip: CGPoint, angle: Double, color: Color) {
        let a1 = angle + .pi * 0.8, a2 = angle - .pi * 0.8
        var p = Path()
        p.move(to: CGPoint(x: tip.x + 5 * cos(a1), y: tip.y + 5 * sin(a1)))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: tip.x + 5 * cos(a2), y: tip.y + 5 * sin(a2)))
        gc.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    // MARK: Arm circles — side view, straight arms sweep big forward circles around the shoulder.

    private func drawArmCircles(_ gc: inout GraphicsContext) {
        let shoulder = CGPoint(x: 50, y: 30), hip = CGPoint(x: 50, y: 60)
        let armLength: CGFloat = 26
        // θ = 0 → arm down; increases forward → up → back.
        let theta = phase
        let hand = CGPoint(x: shoulder.x + armLength * sin(theta), y: shoulder.y + armLength * cos(theta))
        let farHand = CGPoint(x: shoulder.x + armLength * sin(theta - 0.25), y: shoulder.y + armLength * cos(theta - 0.25))

        if showsTrail {
            let ring = Path(ellipseIn: CGRect(x: shoulder.x - armLength, y: shoulder.y - armLength, width: armLength * 2, height: armLength * 2))
            gc.stroke(ring, with: .color(accent.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
            // Direction arrow travelling along the circle just behind the hand.
            let trail = theta - 0.9
            let tip = CGPoint(x: shoulder.x + (armLength + 6) * sin(trail), y: shoulder.y + (armLength + 6) * cos(trail))
            arrowHead(&gc, at: tip, angle: atan2(-sin(trail), cos(trail)), color: accent.opacity(0.8))
        }

        limb(&gc, [shoulder, farHand], color: dimColor)
        ground(&gc)
        // Legs (standing, slight stance).
        limb(&gc, [hip, CGPoint(x: 47, y: 78), CGPoint(x: 46, y: 95)], color: dimColor)
        limb(&gc, [hip, CGPoint(x: 52, y: 78), CGPoint(x: 53, y: 95), CGPoint(x: 59, y: 95)], color: bodyColor)
        limb(&gc, [CGPoint(x: 50, y: 24), hip], color: bodyColor)
        head(&gc, at: CGPoint(x: 51, y: 15))
        limb(&gc, [shoulder, hand], color: accent)
    }

    // MARK: March in place — side view, knees up to hip height with opposite arm swing.

    private func drawMarch(_ gc: inout GraphicsContext) {
        let bob = 1.5 * abs(sin(phase))
        let shoulder = CGPoint(x: 50, y: 30 - bob), hip = CGPoint(x: 50, y: 58 - bob)
        let thigh: CGFloat = 19, shin: CGFloat = 19

        func leg(lift: Double) -> [CGPoint] {
            let a = lift * .pi / 2 // 0 = straight down, π/2 = thigh horizontal
            let knee = CGPoint(x: hip.x + thigh * sin(a), y: hip.y + thigh * cos(a))
            let foot = CGPoint(x: knee.x, y: knee.y + shin)
            return [hip, knee, foot, CGPoint(x: foot.x + 6, y: foot.y)]
        }
        func arm(swing: Double) -> [CGPoint] {
            let a = swing * 0.6 // radians from vertical; positive = forward
            let elbow = CGPoint(x: shoulder.x + 13 * sin(a), y: shoulder.y + 13 * cos(a))
            let b = a + 0.9 // bent elbow, forearm angled forward
            return [shoulder, elbow, CGPoint(x: elbow.x + 12 * sin(b), y: elbow.y + 12 * cos(b))]
        }

        let s = sin(phase)
        let nearLift = max(0, s), farLift = max(0, -s)

        if showsTrail {
            // Target line at hip height: knee should reach it.
            limb(&gc, [CGPoint(x: 58, y: hip.y), CGPoint(x: 80, y: hip.y)], color: accent.opacity(0.5), width: 1.5)
            arrowHead(&gc, at: CGPoint(x: 84, y: hip.y - 6), angle: -.pi / 2, color: accent.opacity(0.8))
            limb(&gc, [CGPoint(x: 84, y: hip.y - 6), CGPoint(x: 84, y: hip.y + 12)], color: accent.opacity(0.8), width: 2.5)
        }

        // Far side (dim): far leg + near arm swing opposite to the near leg.
        limb(&gc, leg(lift: farLift), color: dimColor)
        limb(&gc, arm(swing: -s), color: dimColor)
        ground(&gc)
        limb(&gc, [CGPoint(x: 50, y: 24 - bob), hip], color: bodyColor)
        head(&gc, at: CGPoint(x: 51, y: 15 - bob))
        limb(&gc, leg(lift: nearLift), color: nearLift > 0.05 ? accent : bodyColor)
        limb(&gc, arm(swing: s), color: bodyColor)
    }

    // MARK: Torso twist — front view, elbows bent, shoulders rotate left/right over still hips.

    private func drawTorsoTwist(_ gc: inout GraphicsContext) {
        let twist = sin(phase)                // −1 … 1
        let alpha = twist * 1.05              // upper-body rotation around the spine (radians)
        // Points in 3D (x = sideways, z = toward viewer), rotated around the vertical axis and projected.
        func project(_ x: CGFloat, _ z: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: 50 + x * cos(alpha) + z * sin(alpha), y: y)
        }
        let neck = project(0, 0, 26)
        let lShoulder = project(-15, 0, 29), rShoulder = project(15, 0, 29)
        let lElbow = project(-21, 9, 44), rElbow = project(21, 9, 44)
        let hands = project(0, 22, 40)
        let hipL = CGPoint(x: 43, y: 60), hipR = CGPoint(x: 57, y: 60)

        if showsTrail {
            var arc = Path()
            arc.addArc(center: CGPoint(x: 50, y: 41), radius: 30, startAngle: .degrees(205), endAngle: .degrees(335), clockwise: false)
            gc.stroke(arc, with: .color(accent.opacity(0.4)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
            let leftTip = CGPoint(x: 50 + 30 * cos(205 * CGFloat.pi / 180), y: 41 + 30 * sin(205 * CGFloat.pi / 180))
            let rightTip = CGPoint(x: 50 + 30 * cos(335 * CGFloat.pi / 180), y: 41 + 30 * sin(335 * CGFloat.pi / 180))
            arrowHead(&gc, at: twist >= 0 ? rightTip : leftTip, angle: twist >= 0 ? 0.4 : .pi - 0.4, color: accent)
        }

        ground(&gc)
        // Hips and legs stay still.
        limb(&gc, [hipL, hipR], color: bodyColor)
        limb(&gc, [hipL, CGPoint(x: 40, y: 78), CGPoint(x: 39, y: 95)], color: bodyColor)
        limb(&gc, [hipR, CGPoint(x: 60, y: 78), CGPoint(x: 61, y: 95)], color: bodyColor)
        limb(&gc, [neck, CGPoint(x: 50, y: 60)], color: bodyColor)
        head(&gc, at: project(0, 3, 15))
        limb(&gc, [lShoulder, rShoulder], color: accent)
        limb(&gc, [lShoulder, lElbow, hands], color: accent)
        limb(&gc, [rShoulder, rElbow, hands], color: accent)
    }
}

// MARK: - Screens

/// Full-screen demo card: big animation, target and how-to text.
struct ExerciseDemoCard: View {
    let step: WarmUpStep
    var caption: String?

    var body: some View {
        VStack(spacing: 4) {
            if let caption {
                Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            ExerciseDemoView(exercise: step.exercise)
                .frame(maxHeight: 110)
            Text(step.exercise.displayName).font(.headline)
            Text(Self.targetText(step.target)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.warm)
            Text(step.exercise.instruction)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    static func targetText(_ target: ExerciseTarget) -> String {
        switch target {
        case .reps(let n): "\(n) reps"
        case .duration(let s): "\(Int(s)) seconds"
        }
    }
}

/// "Preview Moves": swipe through every move in the plan before starting.
struct MovesPreviewView: View {
    let steps: [WarmUpStep]

    var body: some View {
        TabView {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                ScrollView {
                    ExerciseDemoCard(step: step, caption: "Move \(index + 1) of \(steps.count)")
                }
            }
        }
        .tabViewStyle(.verticalPage)
        .navigationTitle("How To")
    }
}
