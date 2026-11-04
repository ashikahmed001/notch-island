import Foundation
import Combine

/// Which widgets the Home tab shows, in order. Edited in Settings ▸ Home.
final class HomeSettings: ObservableObject {
    static let shared = HomeSettings()

    enum Widget: String, CaseIterable, Identifiable {
        case music, nextMeeting, cpu, battery, focus, todos

        var id: String { rawValue }

        var title: String {
            switch self {
            case .music: return String(localized: "Now playing")
            case .nextMeeting: return String(localized: "Next meeting")
            case .cpu: return String(localized: "CPU")
            case .battery: return String(localized: "Battery")
            case .focus: return String(localized: "Focus timer")
            case .todos: return String(localized: "To-dos")
            }
        }

        var symbol: String {
            switch self {
            case .music: return "music.note"
            case .nextMeeting: return "calendar"
            case .cpu: return "cpu"
            case .battery: return "battery.75percent"
            case .focus: return "timer"
            case .todos: return "checklist"
            }
        }

        /// Width on the Home tab (points).
        var width: CGFloat {
            switch self {
            case .music: return 250
            case .nextMeeting: return 200
            case .cpu, .battery: return 112
            case .focus: return 270
            case .todos: return 210
            }
        }
    }

    static let defaultWidgets: [Widget] = [.music, .cpu, .battery, .focus, .todos]
    private static let key = "home.widgets"

    /// Shown widgets, in order.
    @Published private(set) var widgets: [Widget]

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.key) {
            widgets = saved.compactMap(Widget.init(rawValue:))
        } else {
            widgets = Self.defaultWidgets
        }
    }

    func isShown(_ widget: Widget) -> Bool { widgets.contains(widget) }

    func setShown(_ widget: Widget, _ shown: Bool) {
        if shown, !widgets.contains(widget) {
            widgets.append(widget)
        } else if !shown {
            widgets.removeAll { $0 == widget }
        }
        save()
    }

    /// Move a widget one place left (-1) or right (+1).
    func move(_ widget: Widget, by offset: Int) {
        guard let index = widgets.firstIndex(of: widget) else { return }
        let target = index + offset
        guard widgets.indices.contains(target) else { return }
        widgets.swapAt(index, target)
        save()
    }

    func reset() {
        widgets = Self.defaultWidgets
        save()
    }

    private func save() {
        UserDefaults.standard.set(widgets.map(\.rawValue), forKey: Self.key)
    }
}
