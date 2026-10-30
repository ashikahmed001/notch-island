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
