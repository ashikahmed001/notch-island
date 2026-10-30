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
    private let lock = LockService()
    private let screenshots = ScreenshotService()
    private let downloads = DownloadsService()
    /// Services stay off until the launch greeting has started them.
    private var servicesStarted = false
    private var settingsWindow: NSWindow?
    private var permissionsWindow: NSWindow?
    private lazy var permissionsModel = PermissionsModel(calendarService: calendar)
    private static let launchedBeforeKey = "hasLaunchedBefore"
    private static let greetedBootKey = "greetedBootTime"

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        clipboard.isEnabled = flags.isOn(.clipboard)
        calendar.isEnabled = flags.isOn(.calendar)
        timer.playsSound = flags.isOn(.timerSound)
        screenshots.isEnabled = flags.isOn(.screenshotShelf)
        downloads.isEnabled = flags.isOn(.downloads)
        if !flags.isOn(.timer) { timer.stop() }

        // Nobody can see the island while locked. Timer, calendar and battery keep running.
        let paused = lock.isLocked && flags.isOn(.pauseWhileLocked)
        nowPlaying.isPaused = paused
        clipboard.isPaused = paused
    }

    // MARK: - Launch

    /// Say hello first (only on the first launch after the Mac starts up),
    /// then start the services so permission prompts come after the greeting.
    private func greetThenStart() {
        let start = { [weak self] in
            guard let self else { return }
            self.servicesStarted = true
            self.applyFlags()
        }
        let defaults = UserDefaults.standard
        let firstRun = !defaults.bool(forKey: Self.launchedBeforeKey)
        defaults.set(true, forKey: Self.launchedBeforeKey)

        // Same boot as last greeting → the app was just relaunched; stay quiet.
        let boot = Self.bootTime().map { $0.timeIntervalSince1970.rounded() }
        let greetedBoot = defaults.object(forKey: Self.greetedBootKey) as? Double
        let freshBoot = boot == nil || boot != greetedBoot
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
                canOpenAtLogin: canOpenAtLogin,
                showWelcome: { [weak self] in self?.showWelcomeNow() },
                showPermissions: { [weak self] in self?.openPermissions() }
            )
            settingsWindow = AppWindows.make(title: "Notch Island Settings", size: NSSize(width: 520, height: 500), content: view)
        }
        if let settingsWindow { AppWindows.present(settingsWindow) }
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

    @objc private func screensChanged() {
        rebuildWindows()
    }

    /// One island on the notched built-in display; falls back to the main screen
    /// (with a virtual notch) on Macs / setups without a notch.
    private func rebuildWindows() {
        controllers.forEach { $0.close() }
        controllers.removeAll()
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let controller = NotchWindowController(
            screen: screen,
            nowPlaying: nowPlaying,
            battery: battery,
            clipboard: clipboard,
            timer: timer,
            calendar: calendar,
            lock: lock,
            screenshots: screenshots,
            downloads: downloads,
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

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let permissions = NSMenuItem(title: "Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notch Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
