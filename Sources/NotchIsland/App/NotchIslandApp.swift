import AppKit
import Combine
import ServiceManagement

@main
enum NotchIslandMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()          // retained for the lifetime of run()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon, no app switcher entry
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controllers: [NotchWindowController] = []
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    private let flags = FeatureFlags()
    private let nowPlaying = NowPlayingService()
    private let battery = BatteryService()
    private let clipboard = ClipboardService()
    private let timer = TimerService()
    private let calendar = CalendarService()
    private let reminders = ReminderService()
    private let audioOutputs = AudioOutputService()
    private lazy var stats = SystemStatsService(battery: battery)
    private let todos = TodoService()
    private lazy var claudeWatcher = ClaudeAppWatcher(api: api)
    private let lock = LockService()
    private let screenshots = ScreenshotService()
    private let downloads = DownloadsService()
    private let api = IslandAPIService()
    private let terminalSettings = TerminalSettings()
    /// Services stay off until the launch greeting has started them.
    private var servicesStarted = false
    /// Command Bar shortcut (nil while the feature is off).
    private var commandHotKey: HotKey?
    private var commandHotKeyPreset: HotKey.Preset?
    private var settingsWindow: NSWindow?
    private let settingsNavigation = SettingsNavigation()
    private var permissionsWindow: NSWindow?
    private lazy var permissionsModel = PermissionsModel(calendarService: calendar, reminderService: reminders)
    private static let launchedBeforeKey = "hasLaunchedBefore"
    private static let greetedBootKey = "greetedBootTime"
    /// Which copy of the app last ran (path + file number) and its build: a reinstall or an
    /// update makes a new copy, even though macOS keeps the preferences when an app is deleted.
    private static let installKey = "installFingerprint"
    private static let installBuildKey = "installBuild"

    func applicationDidFinishLaunching(_ notification: Notification) {
        LiquidGlass.flags = flags
        Energy.flags = flags
        _ = UpdateController.shared   // starts daily update checks (release builds)
        // Refresh ~/.notchisland (token, `notch` command, shell hook) so they match this version.
        APIFiles.writeSupportFiles(settings: terminalSettings.values)
        APIFiles.upgradeAgentHooks()

        // objectWillChange fires *before* the change; hop a run-loop turn to read new values.
        flags.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyFlags() }
            .store(in: &cancellables)
        lock.$isLocked
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyFlags() }
            .store(in: &cancellables)

        setupStatusItem()
        NotificationCenter.default.addObserver(forName: .commandBarShortcutChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateCommandHotKey()
        }
        rebuildWindows()
        greetThenStart()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    // MARK: - Feature flags → services

    /// Turns services fully on/off so disabled features cost nothing
    /// (no polling, no AppleScript, no permission prompts).
    private func applyFlags() {
        syncLoginItem()
        guard servicesStarted else { return }
        nowPlaying.isEnabled = flags.isOn(.nowPlaying)
        nowPlaying.allowsOnlineLookup = flags.isOn(.artworkLookup)
        nowPlaying.includesBrowsers = flags.isOn(.browserMedia)
        clipboard.isEnabled = flags.isOn(.clipboard)
        calendar.isEnabled = flags.isOn(.calendar)
        calendar.announcesNewMeetings = flags.isOn(.newMeetingAlerts)
        reminders.isEnabled = flags.isOn(.reminders)
        timer.playsSound = flags.isOn(.timerSound)
        screenshots.isEnabled = flags.isOn(.screenshotShelf)
        downloads.isEnabled = flags.isOn(.downloads)
        PrivacyService.shared.isEnabled = flags.isOn(.privacy) && !lock.isLocked
        SystemProgressService.shared.watchesBackups = flags.isOn(.backupProgress) && !lock.isLocked
        SystemProgressService.shared.watchesCopies = flags.isOn(.copyProgress)
        DiskService.shared.isEnabled = flags.isOn(.ejectAlerts)
        updateCommandHotKey()
        api.isEnabled = flags.isOn(.islandAPI)
        api.terminalAlertsEnabled = flags.isOn(.terminalAlerts)
        api.onlyWhenTerminalInBackground = flags.isOn(.terminalOnlyInBackground)
        TerminalInputWatcher.shared.isEnabled = flags.isOn(.terminalInputAlerts)
        claudeWatcher.isEnabled = flags.isOn(.claudeAppActivity) && !lock.isLocked
        if !flags.isOn(.timer) { timer.stop() }

        // Nobody can see the island while locked. Timer, calendar and battery keep running.
        let paused = lock.isLocked && flags.isOn(.pauseWhileLocked)
        nowPlaying.isPaused = paused
        clipboard.isPaused = paused
    }

    // MARK: - Command Bar

    /// (Re)registers the shortcut when the feature or the chosen keys change.
    private func updateCommandHotKey() {
        let wanted = flags.isOn(.commandBar) ? HotKey.Preset.saved : nil
        guard wanted != commandHotKeyPreset else { return }
        commandHotKey = nil
        commandHotKeyPreset = wanted
        guard let preset = wanted else { return }
        commandHotKey = HotKey(modifiers: preset.modifiers) { [weak self] in self?.toggleCommandBar() }
    }

    @objc private func toggleCommandBar() {
        // On the screen with the pointer (or the first one).
        let mouse = NSEvent.mouseLocation
        let controller = controllers.first { $0.screenFrame.contains(mouse) } ?? controllers.first
        controller?.toggleCommandBar()
    }

    // MARK: - Launch

    /// Say hello first (only on the first launch after the Mac starts up),
    /// then start the services so permission prompts come after the greeting.
    /// "/Applications/Notch Island.app#12345678" for an installed copy; nil for development
    /// builds (anywhere outside an Applications folder).
    private static func installFingerprint() -> String? {
        let path = Bundle.main.bundleURL.path
        guard path.hasPrefix("/Applications/") || path.contains("/Applications/") else { return nil }
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return "\(path)#\(info.st_ino)"
    }

    private func greetThenStart() {
        let start = { [weak self] in
            guard let self else { return }
            self.servicesStarted = true
            self.applyFlags()
        }
        let defaults = UserDefaults.standard
        let launchedBefore = defaults.bool(forKey: Self.launchedBeforeKey)
        defaults.set(true, forKey: Self.launchedBeforeKey)

        // A fresh copy in Applications: reinstalled (same build) or updated (new build).
        // Development builds in build/ are rebuilt constantly, so they don't count.
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let fingerprint = Self.installFingerprint()
        let installChanged = fingerprint != nil && defaults.string(forKey: Self.installKey) != fingerprint
        let previousBuild = defaults.string(forKey: Self.installBuildKey)
        if let fingerprint { defaults.set(fingerprint, forKey: Self.installKey) }
        defaults.set(build, forKey: Self.installBuildKey)
        let reinstalled = launchedBefore && installChanged && previousBuild == build
        let updated = launchedBefore && installChanged && previousBuild != nil && previousBuild != build
        if reinstalled || updated {
            Log.island.notice("\(reinstalled ? "reinstalled" : "updated", privacy: .public) — showing the welcome again")
        }
        // A reinstall gets the full first-run welcome (and the permissions check).
        let firstRun = !launchedBefore || reinstalled

        // Same boot as last greeting → the app was just relaunched; stay quiet.
        let boot = Self.bootTime().map { $0.timeIntervalSince1970.rounded() }
        let greetedBoot = defaults.object(forKey: Self.greetedBootKey) as? Double
        let freshBoot = boot == nil || boot != greetedBoot || updated
        if let boot { defaults.set(boot, forKey: Self.greetedBootKey) }

        guard flags.isOn(.welcomeGreeting), firstRun || freshBoot, let controller = controllers.first else {
            start()
            if firstRun {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openPermissions() }
            }
            return
        }
        controller.playWelcome(firstRun: firstRun, initialize: start)
        if firstRun {
            // First launch ever: explain permissions once the greeting has finished.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.openPermissions() }
        }
    }

    /// When the Mac last started (kern.boottime).
    private static func bootTime() -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }

    // MARK: - Settings & permissions windows

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                flags: flags,
                navigation: settingsNavigation,
                api: api,
                terminal: terminalSettings,
                canOpenAtLogin: canOpenAtLogin,
                showWelcome: { [weak self] in self?.showWelcomeNow() },
                showPermissions: { [weak self] in self?.openPermissions() }
            )
            settingsWindow = AppWindows.make(title: String(localized: "Notch Island Settings"), size: NSSize(width: 800, height: 600), content: view)
        }
        if let settingsWindow { AppWindows.present(settingsWindow) }
    }

    @objc private func checkForUpdates() {
        UpdateController.shared.checkForUpdates()
    }

    @objc private func openPermissions() {
        if permissionsWindow == nil {
            let view = PermissionsView(model: permissionsModel) { [weak self] in
                self?.permissionsWindow?.close()
            }
            permissionsWindow = AppWindows.make(title: "Permissions", size: NSSize(width: 500, height: 480), content: view)
        }
        if let permissionsWindow { AppWindows.present(permissionsWindow) }
    }

    @objc private func showWelcomeNow() {
        controllers.first?.playWelcome(firstRun: false, initialize: {})
    }

    // MARK: - Open at login

    /// Login items need a real .app (scripts/bundle.sh); `swift run` binaries can't register.
    private var canOpenAtLogin: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func syncLoginItem() {
        guard canOpenAtLogin else { return }
        let service = SMAppService.mainApp
        let wanted = flags.isOn(.openAtLogin)
        let registered = service.status == .enabled
        guard wanted != registered else { return }
        do {
            if wanted { try service.register() } else { try service.unregister() }
        } catch {
            NSLog("NotchIsland: login item update failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Windows

    /// Which screen the island is on, its size and notch. macOS posts "screen parameters
    /// changed" for many things that don't matter here (e.g. plugging in the charger switches
    /// the display's power profile) — rebuilding then would throw away whatever the island is showing.
    private var screenSignature: String?

    @objc private func screensChanged() {
        guard Self.signature(of: NotchGeometry.preferredScreen()) != screenSignature else {
            Log.island.notice("screen parameters changed — same screen, island kept")
            return
        }
        Log.island.notice("screen changed — rebuilding the island")
        rebuildWindows()
    }

    private static func signature(of screen: NSScreen?) -> String {
        guard let screen else { return "none" }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")].map { "\($0)" } ?? "?"
        return "\(id)|\(screen.frame)|\(screen.safeAreaInsets.top)"
    }

    /// One island on the notched built-in display; falls back to the main screen
    /// (with a virtual notch) on Macs / setups without a notch.
    private func rebuildWindows() {
        controllers.forEach { $0.close() }
        controllers.removeAll()
        guard let screen = NotchGeometry.preferredScreen() else { return }
        screenSignature = Self.signature(of: screen)
        let controller = NotchWindowController(
            screen: screen,
            nowPlaying: nowPlaying,
            battery: battery,
            clipboard: clipboard,
            timer: timer,
            calendar: calendar,
            reminders: reminders,
            audioOutputs: audioOutputs,
            stats: stats,
            todos: todos,
            lock: lock,
            screenshots: screenshots,
            downloads: downloads,
            api: api,
            flags: flags
        )
        controllers.append(controller)
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage.notchLineArt()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Kept short: everything configurable lives in the Settings window.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        if flags.isOn(.commandBar) {
            let command = NSMenuItem(title: String(localized: "Command Bar"), action: #selector(toggleCommandBar), keyEquivalent: "")
            command.target = self
            menu.addItem(command)
        }

        let permissions = NSMenuItem(title: String(localized: "Permissions…"), action: #selector(openPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        if UpdateController.shared.isConfigured {
            let update = NSMenuItem(title: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
            update.target = self
            update.isEnabled = UpdateController.shared.canCheck
            menu.addItem(update)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Notch Island"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

extension NSImage {
    /// Menu bar icon: the app icon's line-art notch, as a template image.
    static func notchLineArt(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            // Same path as the app icon (200-pt design grid → menu bar size).
            let s = size / 120
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 12 * s, y: 38 * s))
            path.line(to: NSPoint(x: 108 * s, y: 38 * s))
            path.move(to: NSPoint(x: 26 * s, y: 38 * s))
            path.line(to: NSPoint(x: 26 * s, y: 46 * s))
            path.curve(to: NSPoint(x: 48 * s, y: 68 * s),
                       controlPoint1: NSPoint(x: 26 * s, y: 60.7 * s),
                       controlPoint2: NSPoint(x: 33.3 * s, y: 68 * s))
            path.line(to: NSPoint(x: 72 * s, y: 68 * s))
            path.curve(to: NSPoint(x: 94 * s, y: 46 * s),
                       controlPoint1: NSPoint(x: 86.7 * s, y: 68 * s),
                       controlPoint2: NSPoint(x: 94 * s, y: 60.7 * s))
            path.line(to: NSPoint(x: 94 * s, y: 38 * s))
            path.lineWidth = 11 * s
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notch Island"
        return image
    }
}
