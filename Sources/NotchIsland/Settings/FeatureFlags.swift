import Combine
import Foundation

/// Every switchable part of the app. Top-level features own a set of options;
/// an option is only effective while its parent feature is on.
enum Feature: String, CaseIterable {
    // Features
    case nowPlaying
    case calendar
    case clipboard
    case timer
    case battery
    case downloads
    case lockUnlock

    // Options
    case musicInCompact
    case artworkLookup
    case meetingInCompact
    case copyPreview
    case screenshotShelf
    case clickToPaste
    case timerAlert
    case timerSound
    case chargingAlerts
    case lowBatteryAlerts
    case unlockAnimation
    case awaySummary
    case pauseWhileLocked

    // General
    case hoverHaptics
    case welcomeGreeting
    case openAtLogin

    /// Features shown as main toggles, in menu order.
    static let features: [Feature] = [.nowPlaying, .calendar, .clipboard, .timer, .battery, .downloads, .lockUnlock]
    /// App-wide toggles that don't belong to a feature.
    static let general: [Feature] = [.openAtLogin, .welcomeGreeting, .hoverHaptics]

    var title: String {
        switch self {
        case .nowPlaying: return "Music"
        case .calendar: return "Calendar"
        case .clipboard: return "Clipboard"
        case .timer: return "Timer"
        case .battery: return "Battery"
        case .downloads: return "Downloads"
        case .lockUnlock: return "Lock & Unlock"
        case .musicInCompact: return "Show music when collapsed"
        case .artworkLookup: return "Look up missing artwork online"
        case .meetingInCompact: return "Meeting countdown when collapsed"
        case .copyPreview: return "“Copied” preview"
        case .clickToPaste: return "Click to paste"
        case .screenshotShelf: return "Screenshot shelf"
        case .timerAlert: return "Open & shake when done"
        case .timerSound: return "Chime when done"
        case .chargingAlerts: return "Charging alerts"
        case .lowBatteryAlerts: return "Low battery alerts"
        case .unlockAnimation: return "Unlock animation"
        case .awaySummary: return "“While you were away” summary"
        case .pauseWhileLocked: return "Pause background checks while locked"
        case .hoverHaptics: return "Haptic tick on hover"
        case .welcomeGreeting: return "Greeting after Mac starts"
        case .openAtLogin: return "Open at login"
        }
    }

    /// One-line description for Settings.
    var subtitle: String? {
        switch self {
        case .nowPlaying: return "Apple Music and Spotify: artwork, progress and controls"
        case .calendar: return "Next meeting countdown and one-click Join"
        case .clipboard: return "Your recent copies, pins, and drag and drop"
        case .timer: return "Quick timers that chime and shake when done"
        case .battery: return "Charging, full and low-battery alerts"
        case .downloads: return "Progress while a browser downloads a file"
        case .lockUnlock: return "Unlock animation and what you missed"
        case .screenshotShelf: return "New screenshots drop from the notch, ready to drag"
        default: return nil
        }
    }

    /// SF Symbol for the menu.
    var symbol: String {
        switch self {
        case .nowPlaying: return "music.note"
        case .calendar: return "calendar"
        case .clipboard: return "clipboard"   // the island draws a custom icon (ClipboardStackIcon)
        case .timer: return "timer"
        case .battery: return "battery.75percent"
        case .lockUnlock: return "lock"
        case .downloads: return "arrow.down.circle"
        default: return "gearshape"
        }
    }

    /// The feature this option belongs to; nil for features and general toggles.
    var parent: Feature? {
        switch self {
        case .musicInCompact, .artworkLookup: return .nowPlaying
        case .meetingInCompact: return .calendar
        case .copyPreview, .clickToPaste, .screenshotShelf: return .clipboard
        case .timerAlert, .timerSound: return .timer
        case .chargingAlerts, .lowBatteryAlerts: return .battery
        case .unlockAnimation, .awaySummary, .pauseWhileLocked: return .lockUnlock
        default: return nil
        }
    }

    var options: [Feature] {
        Feature.allCases.filter { $0.parent == self }
    }

    var defaultValue: Bool {
        switch self {
        case .openAtLogin: return false   // never register a login item without asking
        default: return true
        }
    }
}

/// Persistent on/off switches (UserDefaults). Observe it to react to changes.
final class FeatureFlags: ObservableObject {
    @Published private var stored: [Feature: Bool]

    private let defaults: UserDefaults
    private static let keyPrefix = "feature."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var values: [Feature: Bool] = [:]
        for feature in Feature.allCases {
            values[feature] = defaults.object(forKey: Self.keyPrefix + feature.rawValue) as? Bool ?? feature.defaultValue
        }
        stored = values
    }

    /// Effective state: an option only counts while its parent feature is on.
    func isOn(_ feature: Feature) -> Bool {
        guard storedValue(feature) else { return false }
        if let parent = feature.parent { return isOn(parent) }
        return true
    }

    /// The switch itself, ignoring the parent (what the menu checkmark shows).
    func storedValue(_ feature: Feature) -> Bool {
        stored[feature] ?? feature.defaultValue
    }

    func set(_ feature: Feature, _ on: Bool) {
        stored[feature] = on
        defaults.set(on, forKey: Self.keyPrefix + feature.rawValue)
    }

    func toggle(_ feature: Feature) {
        set(feature, !storedValue(feature))
    }

    func resetToDefaults() {
        for feature in Feature.allCases {
            defaults.removeObject(forKey: Self.keyPrefix + feature.rawValue)
            stored[feature] = feature.defaultValue
        }
    }
}
