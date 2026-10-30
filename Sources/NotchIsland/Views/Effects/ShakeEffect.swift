import SwiftUI

/// iPhone-style "no" shake: a few fast, decaying side-to-side wiggles per trigger step.
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = animatableData - floor(animatableData)   // 0→1 within one shake
        let x = sin(t * .pi * 8) * 7 * (1 - t)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}
