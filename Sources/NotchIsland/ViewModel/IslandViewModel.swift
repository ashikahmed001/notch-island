import SwiftUI
import Combine

final class IslandViewModel: ObservableObject {
    enum Mode { case collapsed, expanded }
    enum Peek { case charging, charged, lowBattery, copied, timerDone, unlocked, screenshot, downloaded }

    /// Launch greeting.
    struct Welcome {
        let greeting: String
        let name: String
        let subtitle: String
        /// Enabled features, lit up one by one as they start.
        let features: [Feature]
        let isFirstRun: Bool
        /// Hour it was shown at; picks the colour palette.
        let hour: Int
    }

    /// Shown on unlock: how long you were away and anything you missed.
    struct AwaySummary {
        let awayFor: TimeInterval
        let missed: [String]
        /// Tab to open if the island is hovered while the summary shows.
        let tab: Tab?

        /// Only worth mentioning after a real break.
        var showsAwayTime: Bool { awayFor >= 600 }
    }
    enum Tab { case nowPlaying, calendar, clipboard, timer }

    /// One spring for every size change: critically-damped-ish, no wobble.
    /// Dynamic Island feel: opening overshoots a touch and settles…
    static let spring = Animation.spring(response: 0.46, dampingFraction: 0.74, blendDuration: 0.1)
    /// …closing is quicker and almost un-bouncy, so it tucks back into the notch.
    static let collapseSpring = Animation.spring(response: 0.36, dampingFraction: 0.86, blendDuration: 0.1)
    /// Content swaps inside the island (music ↔ timer ↔ alerts).
    static let contentSpring = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let expandedWidth: CGFloat = 460

    @Published var mode: Mode = .collapsed
    @Published var tab: Tab = .nowPlaying
    @Published private(set) var peek: Peek?
    /// What was just copied — shown in the "Copied" peek.
    @Published private(set) var lastCopied: ClipItem?
    /// Cyan outline flash around the island when something is copied.
    @Published private(set) var copyPulse = false
    /// Increments on each timer chime; the island shakes once per step.
    @Published private(set) var shakeTrigger: CGFloat = 0
    @Published private(set) var awaySummary: AwaySummary?
    @Published private(set) var welcome: Welcome?
    /// How many of the welcome feature icons are lit.
    @Published private(set) var welcomeLit = 0
    @Published private(set) var waveTrigger: CGFloat = 0
    /// Entrance choreography: 0 nothing → 1 greeting → 2 name → 3 subtitle & icons.
    @Published private(set) var welcomePhase = 0
    /// "3 meetings · first at 9:00 AM" — filled in once services have started.
    @Published private(set) var welcomeContext: String?
    /// Set by the window controller: close the greeting early (click).
    var dismissWelcome: (() -> Void)?
    /// Drives the padlock: closed → springs open on unlock.
    @Published private(set) var lockOpen = false

    let notchSize: CGSize
    let nowPlaying: NowPlayingService
    let battery: BatteryService
    let clipboard: ClipboardService
    let timer: TimerService
    let calendar: CalendarService
    let lock: LockService
    let screenshots: ScreenshotService
    let downloads: DownloadsService
    let flags: FeatureFlags

    private var timerFinishedWhileLocked = false

    /// Set by the window controller: closes the island and ignores hover until the mouse leaves.
    var collapseHandler: (() -> Void)?
    /// True while a clipboard card is being dragged out (keeps the island open).
    var isDragging = false

    private var cancellables = Set<AnyCancellable>()
    private var peekWork: DispatchWorkItem?

    init(notchSize: CGSize,
         nowPlaying: NowPlayingService,
         battery: BatteryService,
         clipboard: ClipboardService,
         timer: TimerService,
         calendar: CalendarService,
         lock: LockService,
         screenshots: ScreenshotService,
         downloads: DownloadsService,
         flags: FeatureFlags) {
        self.notchSize = notchSize
        self.nowPlaying = nowPlaying
        self.battery = battery
        self.clipboard = clipboard
        self.timer = timer
        self.calendar = calendar
        self.lock = lock
        self.screenshots = screenshots
        self.downloads = downloads
        self.flags = flags

        // Re-render the island whenever a data source changes.
        for publisher in [nowPlaying.objectWillChange.eraseToAnyPublisher(),
                          battery.objectWillChange.eraseToAnyPublisher(),
                          clipboard.objectWillChange.eraseToAnyPublisher(),
                          timer.objectWillChange.eraseToAnyPublisher(),
                          calendar.objectWillChange.eraseToAnyPublisher(),
                          downloads.objectWillChange.eraseToAnyPublisher(),
                          flags.objectWillChange.eraseToAnyPublisher()] {
            publisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        // Charger plugged in.
        battery.$isPluggedIn
            .removeDuplicates()
            .dropFirst()
            .filter { [weak self] plugged in plugged && self?.flags.isOn(.chargingAlerts) == true }
            .sink { [weak self] _ in self?.showPeek(.charging) }
            .store(in: &cancellables)

        // Reached 100% while plugged in.
        battery.$isFull
            .removeDuplicates()
            .dropFirst()
            .filter { [weak self] full in full && self?.flags.isOn(.chargingAlerts) == true }
            .sink { [weak self] _ in self?.showPeek(.charged) }
            .store(in: &cancellables)

        // Crossed 20% / 10% / 5% on battery power.
        battery.$level
            .removeDuplicates()
            .scan((0, 0)) { ($0.1, $1) }
            .dropFirst()
            .sink { [weak self] previous, current in
                guard let self, !self.battery.isPluggedIn, self.flags.isOn(.lowBatteryAlerts) else { return }
                if [20, 10, 5].contains(where: { previous > $0 && current <= $0 }) {
                    self.showPeek(.lowBattery, duration: 5)
                }
            }
            .store(in: &cancellables)

        // Something new on the clipboard.
        clipboard.copied
            .sink { [weak self] item in
                guard let self, self.flags.isOn(.copyPreview) else { return }
                self.lastCopied = item
                self.showPeek(.copied, duration: 2.2)
                self.pulseOutline()
            }
            .store(in: &cancellables)

        // New screenshot → drop it from the notch and add it to the shelf.
        screenshots.captured
            .sink { [weak self] url in
                guard let self, self.flags.isOn(.screenshotShelf) else { return }
                let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Screenshot")
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }
                self.lastCopied = self.clipboard.addShelfFile(url, source: "Screenshot", icon: icon)
                self.showPeek(.screenshot, duration: 3)
                self.pulseOutline()
            }
            .store(in: &cancellables)

        // Download finished → "Downloaded" peek, and the file joins the shelf.
        downloads.finished
            .sink { [weak self] url in
                guard let self, self.flags.isOn(.downloads) else { return }
                let icon = NSWorkspace.shared.icon(forFile: DownloadsService.downloadsFolder.path)
                self.lastCopied = self.clipboard.addShelfFile(url, source: "Downloads", icon: icon)
                self.showPeek(.downloaded, duration: 3.5)
            }
            .store(in: &cancellables)

        // Lock / unlock.
        lock.$isLocked
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.timerFinishedWhileLocked = false }
            .store(in: &cancellables)
        lock.unlocked
            .sink { [weak self] unlock in self?.handleUnlock(unlock) }
            .store(in: &cancellables)

        // Timer reached zero → the window controller opens the island (see isAlerting).
        timer.finished
            .sink { [weak self] in
                guard let self else { return }
                if self.lock.isLocked { self.timerFinishedWhileLocked = true }
                guard self.flags.isOn(.timerAlert) else { return }
                self.tab = .timer
            }
            .store(in: &cancellables)

        // Each chime → shake the island + a haptic tick (felt if a finger is on the trackpad).
        timer.chimed
            .sink { [weak self] in
                guard let self, self.flags.isOn(.timerAlert) else { return }
                withAnimation(.linear(duration: 0.65)) { self.shakeTrigger += 1 }
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            .store(in: &cancellables)
    }

    // MARK: - Geometry

    var expandedSize: CGSize {
        CGSize(width: Self.expandedWidth, height: notchSize.height + 148)
    }

    /// Outward flare where the island meets the top edge of the screen.
    var topRadius: CGFloat { mode == .expanded ? 14 : 6 }
    var bottomRadius: CGFloat {
        if mode == .expanded { return 30 }
        return hasPreviewRow ? 18 : 11
    }

    /// The collapsed island currently drops down with a second line.
    var hasPreviewRow: Bool {
        isShelfPeek || (peek == .unlocked && awaySummary?.missed.isEmpty == false)
    }

    /// Extra height under the notch for peeks that show a preview line.
    static let previewHeight: CGFloat = 32

    /// Copied peek: a chip line, or a taller row with a thumbnail for images.
    var copiedPreviewHeight: CGFloat {
        lastCopied?.thumbnail != nil ? 50 : Self.previewHeight
    }

    private func pulseOutline() {
        withAnimation(.easeOut(duration: 0.18)) { copyPulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            withAnimation(.easeIn(duration: 0.6)) { self?.copyPulse = false }
        }
    }

    /// Identity of what the collapsed island is showing; changing it morphs the content.
    var compactKey: String {
        if let peek { return "peek-\(peek)" }
        if showsTimerActivity { return "timer" }
        if showsDownloadActivity { return "download" }
        if showsMeetingActivity { return "meeting" }
        if showsMusicActivity { return "music" }
        return "idle"
    }

    /// Copied / screenshot / downloaded: the peeks that preview a shelf item.
    var isShelfPeek: Bool {
        peek == .copied || peek == .screenshot || peek == .downloaded
    }

    /// A browser download is in progress.
    var showsDownloadActivity: Bool {
        flags.isOn(.downloads) && downloads.active != nil
    }

    /// Music in the collapsed island.
    var showsMusicActivity: Bool {
        flags.isOn(.musicInCompact) && nowPlaying.isActivelyPlaying
    }

    var showsBattery: Bool { flags.isOn(.battery) }

    /// Tabs for the features that are switched on, in display order.
    var availableTabs: [Tab] {
        var tabs: [Tab] = []
        if flags.isOn(.nowPlaying) { tabs.append(.nowPlaying) }
        if flags.isOn(.calendar) { tabs.append(.calendar) }
        if flags.isOn(.clipboard) { tabs.append(.clipboard) }
        if flags.isOn(.timer) { tabs.append(.timer) }
        return tabs
    }

    /// The selected tab if its feature is on, else the first available one.
    var visibleTab: Tab? {
        let tabs = availableTabs
        return tabs.contains(tab) ? tab : tabs.first
    }

    /// A meeting starts within 10 minutes (or just started).
    var showsMeetingActivity: Bool {
        flags.isOn(.meetingInCompact) && calendar.isSoon && calendar.next != nil
    }

    /// Timer is ringing: keep the island open until the user acts.
    var isAlerting: Bool { (welcome != nil && mode == .expanded) || (timer.state == .ringing && flags.isOn(.timerAlert)) }

    /// Collapsed island grows sideways to show a "live activity".
    var showsTimerActivity: Bool { flags.isOn(.timer) && timer.state != .idle }

    var currentSize: CGSize {
        if mode == .expanded { return expandedSize }
        var width = notchSize.width + 2 * topRadius
        if isShelfPeek {
            // Drops down to show what was copied (taller for image thumbnails).
            return CGSize(width: width + 200, height: notchSize.height + copiedPreviewHeight)
        } else if peek == .unlocked && awaySummary?.missed.isEmpty == false {
            return CGSize(width: width + 200, height: notchSize.height + Self.previewHeight)
        } else if peek == .unlocked {
            width += awaySummary?.showsAwayTime == true ? 110 : 44
        } else if peek != nil {
            width += 130
        } else if showsTimerActivity || showsDownloadActivity || showsMeetingActivity || showsMusicActivity {
            width += 84
        }
        return CGSize(width: width, height: notchSize.height)
    }

    // MARK: - Opening

    /// Like tapping a Live Activity on iPhone: open on whatever the compact island
    /// is showing. With nothing in particular showing, keep the last-used tab.
    func selectTabForCurrentActivity() {
        if peek == .unlocked, let target = awaySummary?.tab, availableTabs.contains(target) {
            tab = target
        } else if isShelfPeek {
            tab = .clipboard
        } else if showsTimerActivity {
            tab = .timer
        } else if showsMeetingActivity {
            tab = .calendar
        } else if showsMusicActivity {
            tab = .nowPlaying
        }
    }

    // MARK: - Welcome

    func beginWelcome(firstRun: Bool) {
        let subtitle = firstRun
            ? "Welcome to Notch Island — hover over the notch anytime."
            : Date().formatted(.dateTime.weekday(.wide).day().month(.wide))
        welcome = Welcome(
            greeting: Self.greeting(for: Date()),
            name: Self.firstName(),
            subtitle: subtitle,
            // Lock & Unlock has nothing to "start" — leave it out of the greeting.
            features: Feature.features.filter { flags.isOn($0) && $0 != .lockUnlock },
            isFirstRun: firstRun,
            hour: Calendar.current.component(.hour, from: Date())
        )
        welcomeContext = nil
        welcomeLit = 0
        welcomePhase = 0
    }

    func advanceWelcome() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) { welcomePhase += 1 }
        if welcomePhase == 1 {
            withAnimation(.linear(duration: 1.6)) { waveTrigger += 1 }
        }
    }

    func lightWelcomeFeature() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { welcomeLit += 1 }
    }

    /// A one-line look at the day, built from the services that just started.
    func refreshWelcomeContext() {
        var parts: [String] = []
        if flags.isOn(.calendar), calendar.hasAccess {
            let today = calendar.upcoming.filter { Calendar.current.isDateInToday($0.start) || $0.isInProgress(at: Date()) }
            if let first = today.first {
                let count = today.count
                let when = first.isInProgress(at: Date())
                    ? "one on now"
                    : "first at \(first.start.formatted(date: .omitted, time: .shortened))"
                parts.append("\(count) meeting\(count == 1 ? "" : "s") · \(when)")
            } else {
                parts.append("No more meetings today")
            }
        }
        if flags.isOn(.battery), battery.hasBattery, battery.level <= 30, !battery.isPluggedIn {
            parts.append("Battery \(battery.level)%")
        }
        withAnimation(.easeInOut(duration: 0.35)) {
            welcomeContext = parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
        }
    }

    func endWelcome() {
        welcome = nil
    }

    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hello"
        }
    }

    /// First name of the macOS account ("Ashik Ahmed" → "Ashik").
    static func firstName() -> String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        if let first = full.split(separator: " ").first { return String(first) }
        return NSUserName()
    }

    // MARK: - Lock & unlock

    private func handleUnlock(_ unlock: LockService.Unlock) {
        guard flags.isOn(.lockUnlock) else { return }

        var missed: [String] = []
        var tabHint: Tab?
        if flags.isOn(.awaySummary) {
            // A timer that ended while locked (and has stopped ringing by now).
            if timerFinishedWhileLocked && timer.state != .ringing {
                missed.append("Timer finished")
                tabHint = .timer
            }
            // A meeting that started while locked and is still going.
            if let meeting = calendar.next,
               flags.isOn(.calendar),
               meeting.isInProgress(at: Date()),
               meeting.start > unlock.lockedAt {
                let minutes = max(1, Int(Date().timeIntervalSince(meeting.start) / 60))
                missed.append("“\(meeting.title)” started \(minutes) min ago")
                tabHint = .calendar
            }
        }
        timerFinishedWhileLocked = false

        let summary = AwaySummary(awayFor: unlock.awayFor, missed: missed, tab: tabHint)
        // Nothing missed and the animation is off → stay quiet.
        guard !missed.isEmpty || flags.isOn(.unlockAnimation) else { return }

        awaySummary = summary
        lockOpen = false
        let duration: TimeInterval = !missed.isEmpty ? 5 : (summary.showsAwayTime ? 2.5 : 1.3)
        showPeek(.unlocked, duration: duration)
        // Let the closed padlock land first, then spring it open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { self?.lockOpen = true }
        }
    }

    static func formatAway(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    // MARK: - Clipboard actions

    /// Click: paste into the app you were using (falls back to copy without
    /// Accessibility permission). ⌥-click: copy only.
    func useClip(_ item: ClipItem, copyOnly: Bool) {
        if copyOnly || !flags.isOn(.clickToPaste) {
            clipboard.copy(item)
            return
        }
        if clipboard.paste(item) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.collapseHandler?()
            }
        }
    }

    // MARK: - Transient activities

    func showPeek(_ newPeek: Peek, duration: TimeInterval = 3) {
        peekWork?.cancel()
        withAnimation(Self.spring) { peek = newPeek }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(Self.spring) { self?.peek = nil }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
