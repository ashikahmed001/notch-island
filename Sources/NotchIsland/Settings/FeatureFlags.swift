import Combine
import Foundation

/// Every switchable part of the app. Top-level features own a set of options;
/// an option is only effective while its parent feature is on.
enum Feature: String, CaseIterable {
    // Features
    case homeDashboard
    case nowPlaying
    case calendar
    case reminders
    case clipboard
    case timer
    case battery
    case downloads
    case islandAPI
    case lockUnlock
    case privacy
    case systemEvents
    case commandBar

    // Options
    case musicInCompact
    case artworkLookup
    case browserMedia
    case meetingInCompact
    case newMeetingAlerts
    case copyPreview
    case screenshotShelf
    case terminalAlerts
    case terminalOnlyInBackground
    case terminalInputAlerts
    case claudeAppActivity
    case clickToPaste
    case timerAlert
    case timerSound
    case chargingAlerts
    case lowBatteryAlerts
    case unlockAnimation
    case awaySummary
    case pauseWhileLocked
    case privacyAlerts
    case privacyInCompact
    case backupProgress
    case copyProgress
    case ejectAlerts

    // General
    case hoverHaptics
    case welcomeGreeting
    case openAtLogin
    case splitIsland
    case liquidGlass
    case batterySaver
    case networkAlerts
    case liveBanners
    case deviceAlerts
    case headerDate
    case headerBattery

    /// Features shown as main toggles, in menu order.
    static let features: [Feature] = [.homeDashboard, .nowPlaying, .calendar, .reminders, .clipboard, .timer, .battery, .downloads, .islandAPI, .lockUnlock, .privacy, .systemEvents, .commandBar]
    /// App-wide toggles that don't belong to a feature.
    static let general: [Feature] = [.openAtLogin, .welcomeGreeting, .splitIsland, .liveBanners, .deviceAlerts, .networkAlerts, .headerDate, .headerBattery, .liquidGlass, .batterySaver, .hoverHaptics]

    var title: String {
        switch self {
        case .homeDashboard: return String(localized: "Home")
        case .nowPlaying: return String(localized: "Music")
        case .calendar: return String(localized: "Calendar")
        case .reminders: return String(localized: "Reminders")
        case .clipboard: return String(localized: "Clipboard")
        case .timer: return String(localized: "Timer")
        case .battery: return String(localized: "Battery")
        case .downloads: return String(localized: "Downloads")
        case .islandAPI: return String(localized: "Terminal & Island API")
        case .lockUnlock: return String(localized: "Lock & Unlock")
        case .privacy: return String(localized: "Mic & Camera")
        case .systemEvents: return String(localized: "Backups & Drives")
        case .commandBar: return String(localized: "Command Bar")
        case .backupProgress: return String(localized: "Time Machine backup progress")
        case .copyProgress: return String(localized: "Progress when copying to a drive")
        case .ejectAlerts: return String(localized: "“Safe to unplug” and failed-eject alerts")
        case .privacyAlerts: return String(localized: "Pop down when an app starts using them")
        case .privacyInCompact: return String(localized: "Show an indicator while in use")
        case .musicInCompact: return String(localized: "Show music when collapsed")
        case .artworkLookup: return String(localized: "Look up missing artwork online")
        case .browserMedia: return String(localized: "Media in Safari, Chrome, Edge and Brave")
        case .meetingInCompact: return String(localized: "Meeting countdown when collapsed")
        case .newMeetingAlerts: return String(localized: "New meeting alerts")
        case .copyPreview: return String(localized: "“Copied” preview")
        case .clickToPaste: return String(localized: "Click to paste")
        case .screenshotShelf: return String(localized: "Screenshot shelf")
        case .terminalAlerts: return String(localized: "Long-running command alerts")
        case .terminalOnlyInBackground: return String(localized: "Only when the terminal isn't in front")
        case .terminalInputAlerts: return String(localized: "Alert when a command needs your input")
        case .claudeAppActivity: return String(localized: "Claude app activity (experimental)")
        case .timerAlert: return String(localized: "Open & shake when done")
        case .timerSound: return String(localized: "Chime when done")
        case .chargingAlerts: return String(localized: "Charging alerts")
        case .lowBatteryAlerts: return String(localized: "Low battery alerts")
        case .unlockAnimation: return String(localized: "Unlock animation")
        case .awaySummary: return String(localized: "“While you were away” summary")
        case .pauseWhileLocked: return String(localized: "Pause background checks while locked")
        case .hoverHaptics: return String(localized: "Haptic tick on hover")
        case .welcomeGreeting: return String(localized: "Greeting after Mac starts")
        case .openAtLogin: return String(localized: "Open at login")
        case .splitIsland: return String(localized: "Show two activities at once")
        case .liquidGlass: return String(localized: "Liquid Glass")
        case .batterySaver: return String(localized: "Battery saver")
        case .networkAlerts: return String(localized: "Internet connection alerts")
        case .liveBanners: return String(localized: "Pop down when something starts")
        case .deviceAlerts: return String(localized: "Headphones connected (with battery)")
        case .headerDate: return String(localized: "Show the date in the open island")
        case .headerBattery: return String(localized: "Show the battery in the open island")
        }
    }

    /// One-line description for Settings.
    var subtitle: String? {
        switch self {
        case .homeDashboard: return String(localized: "Your own dashboard: music, CPU, battery, focus timer, to-dos")
        case .nowPlaying: return String(localized: "Apple Music and Spotify: artwork, progress and controls")
        case .calendar: return String(localized: "Next meeting countdown and one-click Join")
        case .reminders: return String(localized: "A nudge in the notch when a reminder is due")
        case .newMeetingAlerts: return String(localized: "When an invite lands — click to open it in Calendar")
        case .clipboard: return String(localized: "Your recent copies, pins, and drag and drop")
        case .timer: return String(localized: "Quick timers that chime and shake when done")
        case .battery: return String(localized: "Charging, full and low-battery alerts")
        case .downloads: return String(localized: "Progress while a browser downloads a file")
        case .islandAPI: return String(localized: "Alerts from scripts, Terminal, Shortcuts and AI agents")
        case .claudeAppActivity: return String(localized: "Reads the Claude app's status line through Accessibility")
        case .terminalInputAlerts: return String(localized: "A password, a [y/N] or a question, while that terminal isn't in front. Click to go to it.")
        case .lockUnlock: return String(localized: "Unlock animation and what you missed")
        case .privacy: return String(localized: "See which app is using your microphone or camera")
        case .systemEvents: return String(localized: "Time Machine and copy progress, and when a drive is safe to unplug")
        case .commandBar: return String(localized: "Press a shortcut, then calculate, convert, start timers, add reminders")
        case .copyProgress: return String(localized: "Copies made in Finder to the top folder of an external drive")
        case .ejectAlerts: return String(localized: "If an eject fails, see which app is using the drive")
        case .privacyInCompact: return String(localized: "Orange dot for the microphone, green for the camera")
        case .screenshotShelf: return String(localized: "New screenshots drop from the notch, ready to drag")
        case .splitIsland: return String(localized: "A second activity gets its own bubble beside the notch")
        default: return nil
        }
    }

    /// SF Symbol for the menu.
    var symbol: String {
        switch self {
        case .homeDashboard: return "square.grid.2x2"
        case .nowPlaying: return "music.note"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .clipboard: return "clipboard"   // the island draws a custom icon (ClipboardStackIcon)
        case .timer: return "timer"
        case .battery: return "battery.75percent"
        case .lockUnlock: return "lock"
        case .downloads: return "arrow.down.circle"
        case .islandAPI: return "terminal"
        case .privacy: return "mic.fill"
        case .systemEvents: return "externaldrive"
        case .commandBar: return "command"
        default: return "gearshape"
        }
    }

    /// The feature this option belongs to; nil for features and general toggles.
    var parent: Feature? {
        switch self {
        case .musicInCompact, .artworkLookup, .browserMedia: return .nowPlaying
        case .meetingInCompact, .newMeetingAlerts: return .calendar
        case .copyPreview, .clickToPaste, .screenshotShelf: return .clipboard
        case .terminalAlerts, .terminalOnlyInBackground, .terminalInputAlerts, .claudeAppActivity: return .islandAPI
        case .timerAlert, .timerSound: return .timer
        case .chargingAlerts, .lowBatteryAlerts: return .battery
        case .unlockAnimation, .awaySummary, .pauseWhileLocked: return .lockUnlock
        case .privacyAlerts, .privacyInCompact: return .privacy
        case .backupProgress, .copyProgress, .ejectAlerts: return .systemEvents
        default: return nil
        }
    }

    var options: [Feature] {
        Feature.allCases.filter { $0.parent == self }
    }

    var defaultValue: Bool {
        switch self {
        case .openAtLogin: return false   // never register a login item without asking
        case .terminalOnlyInBackground: return false
        case .claudeAppActivity: return false   // experimental: reads the Claude app's window
        case .headerDate, .headerBattery: return false   // the menu bar already shows both
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
