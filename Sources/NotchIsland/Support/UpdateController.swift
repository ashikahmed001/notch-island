import AppKit
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

/// Automatic updates with Sparkle.
///
/// The app reads `SUFeedURL` (the appcast on the website) and `SUPublicEDKey` from
/// Info.plist. Every update must be signed with the matching private key (kept in the
/// developer's Keychain) as well as the Developer ID, so a tampered download is refused.
///
/// The updater only starts in a real .app with a public key set — never in `swift run`,
/// and never before the key exists (Sparkle would show an error instead).
#if canImport(Sparkle)
final class UpdateController: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = UpdateController()

    /// Updates are set up in this build.
    let isConfigured: Bool
    /// False while a check is already running.
    @Published private(set) var canCheck = false
    /// A scheduled check found a new version ("0.9.1"): the island announces it.
    let updateFound = PassthroughSubject<String, Never>()

    private var controller: SPUStandardUpdaterController!
    private var observation: NSKeyValueObservation?

    private override init() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        isConfigured = !key.isEmpty && !key.hasPrefix("REPLACE") && Bundle.main.bundleURL.pathExtension == "app"
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        guard isConfigured else {
            Log.island.notice("updates off in this build (no Sparkle public key, or not running as an .app)")
            return
        }
        controller.startUpdater()
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            DispatchQueue.main.async { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    var automaticallyChecks: Bool {
        get { isConfigured && controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyInstalls: Bool {
        get { isConfigured && controller.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastCheck: Date? { isConfigured ? controller.updater.lastUpdateCheckDate : nil }

    static var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        // A menu bar app isn't active; bring the update window to the front.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// Notch Island has no Dock icon, so Sparkle's window can open behind other apps.
    /// Gentle reminders let us announce the update in the island and bring the window up.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        updateFound.send(update.displayVersionString)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#else
/// Builds without Sparkle: no automatic updates; the rest of the app is unchanged.
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    let isConfigured = false
    @Published private(set) var canCheck = false
    let updateFound = PassthroughSubject<String, Never>()
    var automaticallyChecks: Bool { get { false } set {} }
    var automaticallyInstalls: Bool { get { false } set {} }
    var lastCheck: Date? { nil }

    static var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    func checkForUpdates() {}
}
#endif
