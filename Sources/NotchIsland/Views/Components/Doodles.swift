import SwiftUI

// MARK: - Shared empty-state layout

/// Doodle on the left, title + hint (+ optional actions) on the right.
struct DoodleEmptyState<Art: View, Actions: View>: View {
    let title: String
    let subtitle: String
    let doodle: () -> Art
    let actions: () -> Actions

    init(title: String,
         subtitle: String,
         @ViewBuilder doodle: @escaping () -> Art,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.doodle = doodle
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 18) {
            doodle()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                actions()
                    .padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shared drawing helpers for the line doodles.
enum Doodle {
    static let ink = GraphicsContext.Shading.color(.white.opacity(0.6))
    static let faint = GraphicsContext.Shading.color(.white.opacity(0.3))
    static let line = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)

    /// Four-point twinkle.
    static func sparkle(at c: CGPoint, radius r: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
        return p
    }

    /// Eighth note: filled head, stem, little flag. `at` is the centre of the head.
    static func drawNote(in context: GraphicsContext, at head: CGPoint, scale: CGFloat, shading: GraphicsContext.Shading) {
        let w = 8 * scale, h = 6 * scale
        context.fill(Path(ellipseIn: CGRect(x: head.x - w / 2, y: head.y - h / 2, width: w, height: h)), with: shading)
        let stemX = head.x + w / 2 - 0.8
        let top = CGPoint(x: stemX, y: head.y - 18 * scale)
        var stem = Path()
        stem.move(to: CGPoint(x: stemX, y: head.y))
        stem.addLine(to: top)
        stem.addQuadCurve(to: CGPoint(x: stemX + 6 * scale, y: top.y + 9 * scale),
                          control: CGPoint(x: stemX + 7 * scale, y: top.y + 2 * scale))
        context.stroke(stem, with: shading, style: line)
    }
}

extension DoodleEmptyState where Actions == EmptyView {
    /// No action buttons.
    init(title: String, subtitle: String, @ViewBuilder doodle: @escaping () -> Art) {
        self.init(title: title, subtitle: subtitle, doodle: doodle, actions: { EmptyView() })
    }
}

// MARK: - Clipboard

/// Hand-drawn style line doodle: a sheet of paper swooshing into a clipboard.
struct ClipboardDoodle: View {
    /// Feature colour for the sparkles.
    var accent: Color = .white

    var body: some View {
        Canvas { context, _ in
            let ink = GraphicsContext.Shading.color(.white.opacity(0.6))
            let faint = GraphicsContext.Shading.color(.white.opacity(0.3))
            let line = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)

            // Clipboard + clip
            context.stroke(Path(roundedRect: CGRect(x: 70, y: 10, width: 36, height: 46), cornerRadius: 6), with: ink, style: line)
            context.stroke(Path(roundedRect: CGRect(x: 80, y: 5, width: 16, height: 9), cornerRadius: 3), with: ink, style: line)

            // Wobbly "text" lines on the board
            for (index, width) in [20.0, 14.0, 18.0].enumerated() {
                let y = 25 + Double(index) * 9
                var scribble = Path()
                scribble.move(to: CGPoint(x: 78, y: y))
                scribble.addCurve(to: CGPoint(x: 78 + width, y: y),
                                  control1: CGPoint(x: 78 + width * 0.3, y: y - 3),
                                  control2: CGPoint(x: 78 + width * 0.6, y: y + 3))
                context.stroke(scribble, with: faint, style: line)
            }

            // Tilted sheet of paper, mid-flight
            let tilt = CGAffineTransform(rotationAngle: -0.35).concatenating(CGAffineTransform(translationX: 16, y: 30))
            var paper = Path(roundedRect: CGRect(x: -8, y: -10, width: 16, height: 20), cornerRadius: 2)
            var paperLines = Path()
            paperLines.move(to: CGPoint(x: -4, y: -4))
            paperLines.addLine(to: CGPoint(x: 4, y: -4))
            paperLines.move(to: CGPoint(x: -4, y: 1))
            paperLines.addLine(to: CGPoint(x: 2, y: 1))
            paper = paper.applying(tilt)
            context.stroke(paper, with: ink, style: line)
            context.stroke(paperLines.applying(tilt), with: faint, style: line)

            // Dashed swoosh into the clipboard, with an arrowhead
            var trail = Path()
            trail.move(to: CGPoint(x: 28, y: 22))
            trail.addCurve(to: CGPoint(x: 64, y: 26),
                           control1: CGPoint(x: 38, y: 4),
                           control2: CGPoint(x: 56, y: 8))
            context.stroke(trail, with: faint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [3, 4]))
            var head = Path()
            head.move(to: CGPoint(x: 64.6, y: 20))
            head.addLine(to: CGPoint(x: 64, y: 26))
            head.addLine(to: CGPoint(x: 59.1, y: 22.5))
            context.stroke(head, with: faint, style: line)

            // Sparkles
            for (center, radius) in [(CGPoint(x: 113, y: 9), 4.5), (CGPoint(x: 117, y: 28), 2.5), (CGPoint(x: 8, y: 52), 3.0)] {
                context.fill(Doodle.sparkle(at: center, radius: radius), with: .color(accent.opacity(0.85)))
            }
        }
        .frame(width: 124, height: 60)
    }
}

// MARK: - Music

/// Headphones with notes drifting out of them.
struct MusicDoodle: View {
    /// Feature colour for the sparkles.
    var accent: Color = .white

    var body: some View {
        Canvas { context, _ in
            // Headband + ear cups
            var band = Path()
            band.move(to: CGPoint(x: 66, y: 42))
            band.addCurve(to: CGPoint(x: 106, y: 42),
                          control1: CGPoint(x: 66, y: 12),
                          control2: CGPoint(x: 106, y: 12))
            context.stroke(band, with: Doodle.ink, style: Doodle.line)
            context.stroke(Path(roundedRect: CGRect(x: 61, y: 38, width: 10, height: 18), cornerRadius: 4), with: Doodle.ink, style: Doodle.line)
            context.stroke(Path(roundedRect: CGRect(x: 101, y: 38, width: 10, height: 18), cornerRadius: 4), with: Doodle.ink, style: Doodle.line)

            // Sound waves off the right cup
            for (index, radius) in [6.0, 11.0].enumerated() {
                var wave = Path()
                wave.addArc(center: CGPoint(x: 111, y: 47), radius: radius,
                            startAngle: .degrees(-35), endAngle: .degrees(35), clockwise: false)
                context.stroke(wave, with: index == 0 ? Doodle.ink : Doodle.faint, style: Doodle.line)
            }

            // Notes floating out to the left, on a dashed drift path
            var drift = Path()
            drift.move(to: CGPoint(x: 58, y: 44))
            drift.addCurve(to: CGPoint(x: 14, y: 34),
                           control1: CGPoint(x: 46, y: 56),
                           control2: CGPoint(x: 24, y: 52))
            context.stroke(drift, with: Doodle.faint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [3, 4]))
            Doodle.drawNote(in: context, at: CGPoint(x: 40, y: 36), scale: 1.0, shading: Doodle.ink)
            Doodle.drawNote(in: context, at: CGPoint(x: 18, y: 24), scale: 0.75, shading: Doodle.faint)

            // Sparkles
            for (center, radius) in [(CGPoint(x: 86, y: 8), 4.0), (CGPoint(x: 8, y: 50), 3.0), (CGPoint(x: 52, y: 12), 2.5)] {
                context.fill(Doodle.sparkle(at: center, radius: radius), with: .color(accent.opacity(0.85)))
            }
        }
        .frame(width: 124, height: 60)
    }
}

// MARK: - Calendar

/// A calendar page with a ticked-off day and a little clock.
struct CalendarDoodle: View {
    /// Feature colour for the sparkles.
    var accent: Color = .white

    var body: some View {
        Canvas { context, _ in
            // Page + binding rings
            context.stroke(Path(roundedRect: CGRect(x: 48, y: 12, width: 44, height: 42), cornerRadius: 6), with: Doodle.ink, style: Doodle.line)
            var header = Path()
            header.move(to: CGPoint(x: 48, y: 22))
            header.addLine(to: CGPoint(x: 92, y: 22))
            context.stroke(header, with: Doodle.ink, style: Doodle.line)
            for x in [60.0, 80.0] {
                var ring = Path()
                ring.move(to: CGPoint(x: x, y: 7))
                ring.addLine(to: CGPoint(x: x, y: 16))
                context.stroke(ring, with: Doodle.ink, style: Doodle.line)
            }

            // Day grid (dots) with one day ticked
            for row in 0..<3 {
                for column in 0..<4 {
                    let center = CGPoint(x: 56 + Double(column) * 9.5, y: 30 + Double(row) * 8)
                    if row == 1 && column == 2 { continue }
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 1.2, y: center.y - 1.2, width: 2.4, height: 2.4)), with: Doodle.faint)
                }
            }
            var tick = Path()
            tick.move(to: CGPoint(x: 71, y: 38))
            tick.addLine(to: CGPoint(x: 74.5, y: 41.5))
            tick.addLine(to: CGPoint(x: 80, y: 34))
            context.stroke(tick, with: Doodle.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // Little clock, overlapping the page corner
            let clock = CGRect(x: 86, y: 38, width: 20, height: 20)
            context.fill(Path(ellipseIn: clock), with: .color(.black))
            context.stroke(Path(ellipseIn: clock), with: Doodle.ink, style: Doodle.line)
            var hands = Path()
            hands.move(to: CGPoint(x: 96, y: 42.5))
            hands.addLine(to: CGPoint(x: 96, y: 48))
            hands.addLine(to: CGPoint(x: 100, y: 50))
            context.stroke(hands, with: Doodle.ink, style: Doodle.line)

            // Sparkles
            for (center, radius) in [(CGPoint(x: 30, y: 20), 4.0), (CGPoint(x: 112, y: 14), 3.0), (CGPoint(x: 26, y: 48), 2.5)] {
                context.fill(Doodle.sparkle(at: center, radius: radius), with: .color(accent.opacity(0.85)))
            }
        }
        .frame(width: 124, height: 60)
    }
}
