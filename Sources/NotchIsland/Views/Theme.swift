import SwiftUI

// One accent colour per feature, used everywhere: welcome, tabs, peeks,
// progress bars, buttons and doodles.

extension Feature {
    /// The feature's colour in the chosen theme (Settings ▸ Appearance).
    var tint: Color {
        let root = parent ?? self
        if let palette = ThemeSettings.shared.theme.palette,
           let index = Feature.features.firstIndex(of: root) {
            return palette[index % palette.count]
        }
        return classicTint
    }

    /// Each feature's own colour (the Classic theme).
    var classicTint: Color {
        switch self {
        case .homeDashboard: return .indigo
        case .nowPlaying: return .pink
        case .calendar: return .red
        case .reminders: return .yellow
        case .clipboard: return .cyan
        case .timer: return .orange
        case .battery: return .green
        case .lockUnlock: return .purple
        case .downloads: return .blue
        case .islandAPI: return .teal
        case .privacy: return .mint
        case .systemEvents: return .brown
        case .commandBar: return .gray
        default: return parent?.classicTint ?? .gray
        }
    }
}

extension IslandViewModel.Tab {
    var feature: Feature {
        switch self {
        case .home: return .homeDashboard
        case .nowPlaying: return .nowPlaying
        case .calendar: return .calendar
        case .clipboard: return .clipboard
        case .timer: return .timer
        case .downloads: return .downloads
        case .agents: return .islandAPI
        }
    }

    var tint: Color { feature.tint }

    /// Name shown on the selected tab in the floating tab bar.
    var title: String {
        switch self {
        case .home: return String(localized: "Home")
        case .nowPlaying: return String(localized: "Music")
        case .calendar: return String(localized: "Calendar")
        case .clipboard: return String(localized: "Clipboard")
        case .timer: return String(localized: "Timer")
        case .downloads: return String(localized: "Downloads")
        case .agents: return String(localized: "Agents")
        }
    }
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
            .glassBackground(Capsule(), fallback: tint.opacity(0.18), tint: tint.opacity(0.35))
            .contentShape(Capsule())
    }
}

extension IslandAPIService {
    /// Colour names accepted by the API → SwiftUI colours.
    static func swiftUIColor(_ name: String) -> Color {
        switch name {
        case "green": return .green
        case "red": return .red
        case "blue": return .blue
        case "orange": return .orange
        case "yellow": return .yellow
        case "pink": return .pink
        case "purple": return .purple
        case "cyan": return .cyan
        case "indigo": return .indigo
        case "mint": return .mint
        case "gray": return .gray
        case "white": return .white
        default: return .teal
        }
    }
}
