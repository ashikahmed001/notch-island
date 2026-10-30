import AppKit
import SwiftUI

// Custom "stacked history" clipboard icon (design B): a faded card behind,
// a front card with a clip and two lines. Drawn on a 24 × 24 grid.

/// Drawn in SwiftUI; used by the island (tabs, welcome) and Settings.
struct ClipboardStackIcon: View {
    var color: Color = .white
    /// Stroke width in 24-pt design units.
    var lineWidth: CGFloat = 1.9

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 24
            let origin = CGPoint(x: (size.width - 24 * s) / 2, y: (size.height - 24 * s) / 2)
            func card(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: origin.x + x * s, y: origin.y + y * s, width: w * s, height: h * s),
                     cornerRadius: r * s, style: .continuous)
            }
            let stroke = StrokeStyle(lineWidth: lineWidth * s, lineCap: .round, lineJoin: .round)

            // Back card (the "history")
            context.stroke(card(8.5, 3, 12, 14, 2.5), with: .color(color.opacity(0.5)), style: stroke)

            // Front card: punch a hole first so the back card doesn't show through
            var punch = context
            punch.blendMode = .destinationOut
            punch.fill(card(3.5, 7, 12, 14, 2.5), with: .color(.black))
            context.stroke(card(3.5, 7, 12, 14, 2.5), with: .color(color), style: stroke)

            // Clip
            context.fill(card(7, 5.5, 5, 3, 1.3), with: .color(color))

            // Lines of "text"
            var lines = Path()
            lines.move(to: CGPoint(x: origin.x + 6.5 * s, y: origin.y + 13 * s))
            lines.addLine(to: CGPoint(x: origin.x + 12.5 * s, y: origin.y + 13 * s))
            lines.move(to: CGPoint(x: origin.x + 6.5 * s, y: origin.y + 16.5 * s))
            lines.addLine(to: CGPoint(x: origin.x + 10.5 * s, y: origin.y + 16.5 * s))
            context.stroke(lines, with: .color(color), style: stroke)
        }
    }
}

/// A feature's icon: the custom clipboard drawing, or the SF Symbol for everything else.
struct FeatureGlyph: View {
    let feature: Feature
    var symbol: String? = nil
    var size: CGFloat = 11
    var color: Color = .white

    var body: some View {
        if feature == .clipboard {
            ClipboardStackIcon(color: color)
                .frame(width: size + 3, height: size + 3)
        } else {
            Image(systemName: symbol ?? feature.symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}
