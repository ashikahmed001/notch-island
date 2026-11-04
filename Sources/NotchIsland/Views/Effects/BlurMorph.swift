import SwiftUI

/// Blur + scale + fade: content "resolves" in and dissolves out, like iOS.
struct BlurMorph: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 8 : 0)
            .scaleEffect(active ? 0.82 : 1)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    static var blurMorph: AnyTransition {
        .modifier(active: BlurMorph(active: true), identity: BlurMorph(active: false))
    }
}

/// Quick fade + slight shrink for content on its way out (no blur: cheaper, and it's gone fast).
struct FadeShrink: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.94 : 1)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    /// Dynamic Island content: arrives a beat after the island has started to grow, resolving
    /// out of a blur; leaves first with a quick fade so the shape can shrink around nothing.
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurMorph(active: true), identity: BlurMorph(active: false))
                .animation(.spring(response: 0.42, dampingFraction: 0.8).delay(0.09)),
            removal: .modifier(active: FadeShrink(active: true), identity: FadeShrink(active: false))
                .animation(.easeOut(duration: 0.14))
        )
    }
}
