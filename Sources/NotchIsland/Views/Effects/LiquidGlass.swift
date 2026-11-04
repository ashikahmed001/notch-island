import AppKit
import SwiftUI

/// Liquid Glass (macOS 26 Tahoe). Compiles with older SDKs too: there it is
/// simply never active and every view keeps its classic flat look.
enum LiquidGlass {
    /// Set once at launch; the "Liquid Glass" switch in Settings ▸ General.
    static weak var flags: FeatureFlags?

    /// Built with the macOS 26 SDK (Swift 6.2+) and running on macOS 26 or later.
    static var isSupported: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    /// Supported and switched on.
    static var isActive: Bool {
        isSupported && flags?.isOn(.liquidGlass) == true
    }
}

extension View {
    /// Glass behind a control when Liquid Glass is on; otherwise the old flat fill.
    /// - Parameters:
    ///   - tint: colours the glass (buttons with a meaning: Join, Restart…). nil = clear glass.
    ///   - interactive: the glass reacts to the pointer (subtle shine and press).
    func glassBackground<S: Shape>(_ shape: S, fallback: Color, tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(GlassBackground(shape: shape, fallback: fallback, tint: tint, interactive: interactive))
    }
}

private struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S
    let fallback: Color
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if LiquidGlass.isActive {
            if #available(macOS 26.0, *) {
                content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
            } else {
                content.background(shape.fill(fallback))
            }
        } else {
            content.background(shape.fill(fallback))
        }
        #else
        content.background(shape.fill(fallback))
        #endif
    }
}

/// The island's own body: always black over a real notch (it has to blend with the
/// camera housing, like the iPhone's Dynamic Island). On screens without a notch it
/// can be a floating piece of dark glass instead.
///
/// When something finishes (Claude done, a download done…), the dropped-down island's
/// bottom edge turns faintly frosted — the desktop shows through a little — with a thin
/// light rim along the curve.
struct IslandSurface: ViewModifier {
    let glass: Bool
    let shape: NotchShape
    /// Current island height and the notch's, to keep the frosted band below the camera.
    var height: CGFloat = 0
    var notchHeight: CGFloat = 0
    /// Something just finished (Claude done, download done…): add the frosted edge.
    var frosted = false

    /// Only for finished moments, and only once there's room below the notch line.
    private var showsGlassEdge: Bool { frosted && height > notchHeight + 12 }
    private var bandHeight: CGFloat { min(46, max(0, height - notchHeight)) }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if glass {
            if #available(macOS 26.0, *) {
                content
                    .clipShape(shape)
                    // Darkened so the white text stays readable over any wallpaper.
                    .glassEffect(Glass.regular.tint(Color.black.opacity(0.45)), in: shape)
            } else {
                blackIsland(content)
            }
        } else {
            blackIsland(content)
        }
        #else
        blackIsland(content)
        #endif
    }

    private func blackIsland(_ content: Content) -> some View {
        content
            .background(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    Color.black
                    // Frosted band hugging the bottom edge (follows it as the island animates).
                    // Only created while needed: a live behind-window blur costs the window
                    // server work even when it's invisible.
                    if showsGlassEdge {
                        ZStack {
                            BehindWindowBlur()
                            LinearGradient(colors: [Color.black, Color.black.opacity(0.62)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                        .frame(height: bandHeight)
                        .transition(.opacity)
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                // Thin light rim, strongest at the very bottom, gone by mid-height.
                shape
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.55),
                        .init(color: .white, location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    .opacity(showsGlassEdge ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.25), value: showsGlassEdge)
    }
}

/// Real blur of whatever is behind the window (the desktop / app under the island).
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
