import AppKit
import SwiftUI

/// Equalizer bars animated by Core Animation on the render server (zero
/// main-thread work per frame), tinted with a gradient taken from the album art.
struct AudioBars: NSViewRepresentable {
    /// Gradient colours (usually from the artwork). Empty → white.
    var colors: [NSColor] = []

    func makeNSView(context: Context) -> AudioBarsView { AudioBarsView() }

    func updateNSView(_ nsView: AudioBarsView, context: Context) {
        nsView.setColors(colors)
    }
}

final class AudioBarsView: NSView {
    private let gradient = CAGradientLayer()
    /// The bars only act as a mask; the gradient underneath provides the colour.
    private let barMask = CALayer()
    private var bars: [CALayer] = []
    private let durations: [CFTimeInterval] = [0.45, 0.62, 0.38, 0.54]
    private var currentColors: [NSColor] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        gradient.colors = [NSColor.white.cgColor, NSColor.white.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)   // bottom-left
        gradient.endPoint = CGPoint(x: 1, y: 1)     // → top-right
        gradient.mask = barMask
        layer?.addSublayer(gradient)

        for (index, duration) in durations.enumerated() {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = 1.5
            barMask.addSublayer(bar)
            bars.append(bar)

            let bounce = CABasicAnimation(keyPath: "transform.scale.y")
            bounce.fromValue = 0.3
            bounce.toValue = 1.0
            bounce.duration = duration
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bounce.beginTime = CACurrentMediaTime() + Double(index) * 0.11
            bounce.isRemovedOnCompletion = false
            bar.add(bounce, forKey: "bounce")
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Cross-fades to new colours (e.g. when the track — and its artwork — changes).
    func setColors(_ colors: [NSColor]) {
        guard colors != currentColors else { return }
        currentColors = colors
        let stops: [NSColor]
        switch colors.count {
        case 0: stops = [.white, .white]
        case 1: stops = [colors[0], colors[0]]
        default: stops = Array(colors.prefix(2))
        }
        let cgColors = stops.map(\.cgColor)
        let fade = CABasicAnimation(keyPath: "colors")
        fade.fromValue = gradient.presentation()?.colors ?? gradient.colors
        fade.toValue = cgColors
        fade.duration = 0.6
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradient.colors = cgColors
        gradient.add(fade, forKey: "colors")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        barMask.frame = bounds
        let width: CGFloat = 3, spacing: CGFloat = 2
        let total = CGFloat(bars.count) * width + CGFloat(bars.count - 1) * spacing
        var x = (bounds.width - total) / 2
        for bar in bars {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: x + width / 2, y: bounds.midY)
            x += width + spacing
        }
        CATransaction.commit()
    }
}

extension NSImage {
    /// The two most vivid colours in the image, brightened to read on black.
    /// Mostly grey / black-and-white images return an empty array.
    func vibrantColors(count: Int = 2) -> [NSColor] {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Bucket pixels by hue, weighted by how colourful and bright they are.
        struct Bucket { var r = 0.0, g = 0.0, b = 0.0, weight = 0.0 }
        var buckets = [Bucket](repeating: Bucket(), count: 12)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            guard s > 0.25, v > 0.2 else { continue }
            let weight = Double(s * v)
            let index = min(11, Int(h * 12))
            buckets[index].r += r * weight
            buckets[index].g += g * weight
            buckets[index].b += b * weight
            buckets[index].weight += weight
        }

        let total = buckets.reduce(0) { $0 + $1.weight }
        guard total > 4 else { return [] }   // not colourful enough

        let picks = buckets
            .filter { $0.weight > total * 0.08 }
            .sorted { $0.weight > $1.weight }
            .prefix(count)
            .map { bucket -> NSColor in
                let base = NSColor(srgbRed: bucket.r / bucket.weight, green: bucket.g / bucket.weight,
                                   blue: bucket.b / bucket.weight, alpha: 1)
                var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
                base.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
                // Lift so it glows on the black island.
                return NSColor(hue: h, saturation: min(max(s, 0.45), 0.9), brightness: max(v, 0.88), alpha: 1)
            }

        if picks.count == 1, let only = picks.first {
            // One dominant colour: pair it with a lighter, slightly shifted shade.
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            only.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            let partner = NSColor(hue: (h + 0.06).truncatingRemainder(dividingBy: 1), saturation: s * 0.6, brightness: 1, alpha: 1)
            return [only, partner]
        }
        return Array(picks)
    }
}
