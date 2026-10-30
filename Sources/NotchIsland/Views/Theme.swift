import SwiftUI

// One accent colour per feature, used everywhere: welcome, tabs, peeks,
// progress bars, buttons and doodles.

extension Feature {
    var tint: Color {
        switch self {
        case .nowPlaying: return .pink
        case .calendar: return .red
        case .clipboard: return .cyan
        case .timer: return .orange
        case .battery: return .green
        case .lockUnlock: return .purple
        case .downloads: return .blue
        default: return parent?.tint ?? .gray
        }
    }
}

extension IslandViewModel.Tab {
    var feature: Feature {
        switch self {
        case .nowPlaying: return .nowPlaying
        case .calendar: return .calendar
        case .clipboard: return .clipboard
        case .timer: return .timer
        }
    }

    var tint: Color { feature.tint }
}

/// Small pill button tinted with a feature colour.
struct TintedCapsuleLabel: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(tint.opacity(0.18)))
            .contentShape(Capsule())
    }
}
