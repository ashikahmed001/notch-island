import SwiftUI
import Combine

final class IslandViewModel: ObservableObject {
    enum Mode { case collapsed, expanded }
    enum Peek { case charging, charged, lowBattery, copied, timerDone, unlocked, screenshot, downloaded, apiAlert, notice, banner, device, tray, alert }

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
    enum Tab { case home, nowPlaying, calendar, clipboard, timer, downloads, agents }

    /// The big drop-down that announces a live activity, then shrinks to the compact view.
    struct Banner: Equatable {
        /// `tile`: a symbol on a rounded square tinted with its colour.
        enum Icon { case symbol(String, Color), tile(String, Color), image(NSImage?, fallback: String), artwork }
        /// `label`: a short word on the right ("Done", "Failed").
        enum Trailing { case ring(Double?, Color, String?), check(Color), symbol(String, Color), spinner(Color), label(String, Color), none }
        struct Badge { let symbol: String; let color: Color }

        let id = UUID()
        var icon: Icon
        var badge: Badge? = nil
        /// Small line above the title ("Connected").
        var caption: String? = nil
        var title: String
        /// Line under the title.
        var subtitle: String? = nil
        var trailing: Trailing = .none
        var duration: TimeInterval = 3.5
        /// A compact peek to shrink into afterwards (for things with no live activity).
        var followUp: Peek? = nil
        /// Announces something that finished (gets the frosted bottom edge).
        var finished = false
        /// Content that keeps updating while the banner shows.
        var live: Live? = nil

        enum Live { case download }

        static func == (lhs: Banner, rhs: Banner) -> Bool { lhs.id == rhs.id }
    }

    /// Headphones that just connected (banner + compact peek).
    struct ConnectedDevice: Equatable {
        let name: String
        let symbol: String
        var battery: Int?
    }

    /// A new meeting or a due reminder. Clicking it opens the item in its app.
    struct Notice: Equatable {
        enum Kind: Equatable {
            case newMeeting(Meeting)
            case reminder(ReminderService.DueReminder)
        }
        let kind: Kind
        /// Others that arrived together ("+2").
        let more: Int

        var isReminder: Bool {
            if case .reminder = kind { return true }
            return false
        }
        var feature: Feature { isReminder ? .reminders : .calendar }
        var symbol: String { isReminder ? "checklist" : "calendar.badge.plus" }
        var label: String {
            let base = isReminder ? String(localized: "Reminder") : String(localized: "New meeting")
            return more > 0 ? "\(base) +\(more)" : base
        }
        var title: String {
            switch kind {
            case .newMeeting(let meeting): return meeting.title
            case .reminder(let reminder): return reminder.title
            }
        }
        /// "Tue 3:00 PM" for a meeting; the list name for a reminder.
        var detail: String {
            switch kind {
            case .newMeeting(let meeting): return meeting.shortStart
            case .reminder(let reminder): return reminder.list
            }
        }
        var color: NSColor {
            switch kind {
            case .newMeeting(let meeting): return meeting.color
            case .reminder(let reminder): return reminder.color
            }
        }
        /// Reminders wait longer: they're something to act on.
        var duration: TimeInterval { isReminder ? 12 : 7 }
    }

    /// One spring for every size change: critically-damped-ish, no wobble.
    /// Dynamic Island feel: opening overshoots a touch and settles…
    static let spring = Animation.spring(response: 0.5, dampingFraction: 0.72, blendDuration: 0.1)
    /// Something drops down while collapsed (alerts, banners, live activities): a touch more
    /// bounce, like the iPhone's island stretching out.
    static let peekSpring = Animation.spring(response: 0.5, dampingFraction: 0.66, blendDuration: 0.1)
    /// …closing is quicker and almost un-bouncy, so it tucks back into the notch.
    static let collapseSpring = Animation.spring(response: 0.4, dampingFraction: 0.88, blendDuration: 0.1)
    /// Content swaps inside the island (music ↔ timer ↔ alerts).
    static let contentSpring = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let expandedWidth: CGFloat = 460
    /// Calendar tab: agenda + month side by side.
    static let wideExpandedWidth: CGFloat = 560
    /// The window is sized once for the largest island.
    static let maxExpandedSize = CGSize(width: 1120, height: 470)

    @Published var mode: Mode = .collapsed
    @Published var tab: Tab = .nowPlaying
    @Published private(set) var peek: Peek?
    /// What was just copied — shown in the "Copied" peek.
    @Published private(set) var lastCopied: ClipItem?
    /// The Island API alert being shown.
    @Published private(set) var apiAlert: IslandAPIService.Alert?
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
    @Published private(set) var notice: Notice?

    /// An iPhone-style alert in the island: icon, title, message, buttons. Stays until dismissed.
    struct IslandAlert: Equatable {
        enum Action: Equatable {
            case dismiss, open(URL)
            /// Quit these apps (may be none), then eject the drive again.
            case quitAndEject([pid_t], URL)
        }
        struct Choice: Equatable, Identifiable {
            let title: String
            let action: Action
            var prominent = false
            var id: String { title }
        }
        let symbol: String
        let tint: Color
        let title: String
        let message: String
        let choices: [Choice]
    }
    @Published private(set) var islandAlert: IslandAlert?
    let network = NetworkService()
    @Published private(set) var banner: Banner?
    @Published private(set) var connectedDevice: ConnectedDevice?
    /// A file is being dragged toward the notch: show the Files Tray drop zone.
    @Published var showsFileTray = false
    /// The Files Tray drop zone has a file over it.
    @Published var fileTrayTargeted = false
    /// Home: Focus / Break timer settings.
    enum FocusMode { case focus, rest }
    @Published var focusMode: FocusMode = .focus
    @Published var focusMinutes: Double = 25
    /// Home: the "add a task" field.
    @Published var isAddingTodo = false
    @Published var newTodoText = ""
    /// Command Bar: open, what's typed, what it found, and which row Enter runs.
    @Published private(set) var showsCommandBar = false
    @Published var commandText = "" {
        didSet {
            guard commandText != oldValue else { return }
            commandResults = CommandEngine.results(for: commandText)
            commandSelection = 0
            commandMessage = nil
        }
    }
    @Published private(set) var commandResults: [CommandResult] = CommandEngine.examples
    @Published var commandSelection = 0
    /// A one-line note after running something that needs attention ("Allow Reminders…").
    @Published private(set) var commandMessage: String?
    /// The mouse is resting on a notice (set by the window controller).
    @Published var noticeHovered = false
    /// Notices that arrived while another was showing, or while locked.
    private var noticeQueue: [Notice] = []

    let notchSize: CGSize
    /// false on screens without a notch (the island draws a virtual one). Set by the window controller.
    var hasHardwareNotch = true
    let nowPlaying: NowPlayingService
    let battery: BatteryService
    let clipboard: ClipboardService
    let timer: TimerService
    let calendar: CalendarService
    let reminders: ReminderService
    let audioOutputs: AudioOutputService
    let stats: SystemStatsService
    let todos: TodoService
    let home = HomeSettings.shared
    let lock: LockService
    let screenshots: ScreenshotService
    let downloads: DownloadsService
    let privacy = PrivacyService.shared
    let systemProgress = SystemProgressService.shared
    let api: IslandAPIService
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
         reminders: ReminderService,
         audioOutputs: AudioOutputService,
         stats: SystemStatsService,
         todos: TodoService,
         lock: LockService,
         screenshots: ScreenshotService,
         downloads: DownloadsService,
         api: IslandAPIService,
         flags: FeatureFlags) {
        self.notchSize = notchSize
        self.nowPlaying = nowPlaying
        self.battery = battery
        self.clipboard = clipboard
        self.timer = timer
        self.calendar = calendar
        self.reminders = reminders
        self.audioOutputs = audioOutputs
        self.stats = stats
        self.todos = todos
        self.lock = lock
        self.screenshots = screenshots
        self.downloads = downloads
        self.api = api
        self.flags = flags

        // Re-render the island whenever a data source changes.
        for publisher in [nowPlaying.objectWillChange.eraseToAnyPublisher(),
                          battery.objectWillChange.eraseToAnyPublisher(),
                          clipboard.objectWillChange.eraseToAnyPublisher(),
                          timer.objectWillChange.eraseToAnyPublisher(),
                          calendar.objectWillChange.eraseToAnyPublisher(),
                          audioOutputs.objectWillChange.eraseToAnyPublisher(),
                          todos.objectWillChange.eraseToAnyPublisher(),
                          HomeSettings.shared.objectWillChange.eraseToAnyPublisher(),
                          ThemeSettings.shared.objectWillChange.eraseToAnyPublisher(),
                          // Downloads tick ~4×/s: the island only needs to know when one starts,
                          // stops or the count changes — the ring and lists watch the service themselves.
                          downloads.$active.map { $0?.count }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                          // CPU / battery graphs (stats) are watched by their own cards only.
                          api.objectWillChange.eraseToAnyPublisher(),
                          privacy.objectWillChange.eraseToAnyPublisher(),
                          systemProgress.objectWillChange.eraseToAnyPublisher(),
                          flags.objectWillChange.eraseToAnyPublisher()] {
            publisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        // Charger plugged in.
        battery.chargerConnected
            .sink { [weak self] in
                guard let self else { return }
                guard self.flags.isOn(.chargingAlerts) else {
                    Log.battery.notice("charger connected, but Charging alerts is off (Settings ▸ Features ▸ Battery)")
                    return
                }
                Log.battery.notice("charger connected → showing the charging alert")
                self.showPeek(.charging, duration: 3.5)
            }
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
                self.showsCopiedQR = false
                // Long enough to reach the buttons; hovering keeps it open.
                self.showPeek(.copied, duration: 3.5)
                self.pulseOutline()
            }
            .store(in: &cancellables)

        // New screenshot → drop it from the notch and add it to the shelf.
        screenshots.captured
            .sink { [weak self] url in
                guard let self, self.flags.isOn(.screenshotShelf) else { return }
                let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Screenshot")
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }
                self.lastCopied = self.clipboard.addShelfFile(url, source: String(localized: "Screenshot"), icon: icon)
                self.showPeek(.screenshot, duration: 3)
                self.pulseOutline()
            }
            .store(in: &cancellables)

        // Download finished → String(localized: "Downloaded") peek, and the file joins the shelf.
        downloads.finished
            .sink { [weak self] url in
                guard let self, self.flags.isOn(.downloads) else { return }
                let icon = NSWorkspace.shared.icon(forFile: DownloadsService.downloadsFolder.path)
                self.lastCopied = self.clipboard.addShelfFile(url, source: "Downloads", icon: icon)
                self.lastDownload = url
                // A finished download replaces its own String(localized: "Downloading") banner.
                if self.peek == .banner, self.banner?.live == .download { self.peek = nil }
                // Longer than other peeks: there are Open / Show in Finder buttons to reach.
                self.showPeek(.downloaded, duration: 6)
            }
            .store(in: &cancellables)

        // Island API: scripts, `notch`, the shell hook, Claude Code / Copilot hooks.
        api.alerts
            .sink { [weak self] alert in
                guard let self, self.flags.isOn(.islandAPI) else { return }
                if let caption = alert.caption {
                    // A finished terminal command: the big drop-down banner.
                    let tint = IslandAPIService.swiftUIColor(alert.color)
                    self.showBanner(Banner(icon: .tile(alert.icon, tint), caption: caption, title: alert.title,
                                           trailing: .label(alert.status ?? "", tint),
                                           duration: alert.duration, finished: alert.succeeded), always: true)
                    return
                }
                self.apiAlert = alert
                self.showPeek(.apiAlert, duration: alert.duration)
            }
            .store(in: &cancellables)

        // An invite landed / a meeting was added on another device.
        calendar.newMeetings
            .sink { [weak self] meetings in
                guard let self, self.flags.isOn(.newMeetingAlerts), let first = meetings.first else { return }
                self.showNotice(Notice(kind: .newMeeting(first), more: meetings.count - 1))
            }
            .store(in: &cancellables)

        installBannerTriggers()

        // Internet connection lost / back.
        network.wentOffline
            .sink { [weak self] in
                guard let self, self.flags.isOn(.networkAlerts), !self.lock.isLocked else { return }
                let settings = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")
                    ?? URL(string: "x-apple.systempreferences:com.apple.preference.network")!
                self.showAlert(IslandAlert(
                    symbol: "antenna.radiowaves.left.and.right",
                    tint: .green,
                    title: String(localized: "No Internet Connection"),
                    message: String(localized: "Connect to Wi-Fi, Ethernet, or Personal Hotspot to continue."),
                    choices: [.init(title: String(localized: "OK"), action: .dismiss),
                              .init(title: String(localized: "Settings"), action: .open(settings), prominent: true)]
                ))
            }
            .store(in: &cancellables)
        network.cameOnline
            .sink { [weak self] in
                guard let self, self.flags.isOn(.networkAlerts) else { return }
                let wasShowing = self.peek == .alert && self.islandAlert?.symbol == "antenna.radiowaves.left.and.right"
                if wasShowing { self.dismissAlert() }
                DispatchQueue.main.asyncAfter(deadline: .now() + (wasShowing ? 0.45 : 0)) { [weak self] in
                    guard let self else { return }
                    self.showBanner(Banner(icon: .symbol("wifi", .green), caption: String(localized: "Back online"),
                                           title: self.network.connectionName, trailing: .check(.green),
                                           duration: 2.5), always: true)
                }
            }
            .store(in: &cancellables)

        // A new version of Notch Island is out (daily check found it).
        UpdateController.shared.updateFound
            .receive(on: RunLoop.main)
            .sink { [weak self] version in
                self?.showBanner(Banner(icon: .tile("arrow.down", .blue),
                                        caption: String(localized: "Update available"),
                                        title: "Notch Island \(version)",
                                        trailing: .symbol("arrow.down.circle", .blue), duration: 5), always: true)
            }
            .store(in: &cancellables)

        // Finished copying onto a drive.
        systemProgress.copyFinished
            .sink { [weak self] volume, items in
                guard let self, self.flags.isOn(.copyProgress) else { return }
                self.showBanner(Banner(icon: .tile("externaldrive.fill", .green),
                                       caption: String(localized: "Copied to \(volume)"),
                                       title: items == 1 ? String(localized: "1 item") : String(localized: "\(items) items"),
                                       trailing: .check(.green), duration: 3, finished: true))
            }
            .store(in: &cancellables)

        // A drive was ejected / couldn't be ejected.
        DiskService.shared.unmounted
            .sink { [weak self] name in
                guard let self, self.flags.isOn(.ejectAlerts), !self.lock.isLocked else { return }
                self.showBanner(Banner(icon: .tile("eject.fill", .green),
                                       caption: String(localized: "Safe to unplug"),
                                       title: name, trailing: .check(.green), duration: 3, finished: true), always: true)
            }
            .store(in: &cancellables)
        DiskService.shared.ejectFailed
            .sink { [weak self] volume, blockers in
                guard let self, self.flags.isOn(.ejectAlerts), !self.lock.isLocked else { return }
                self.showAlert(Self.ejectAlert(volume: volume, blockers: blockers))
            }
            .store(in: &cancellables)

        // An app started using the microphone or camera.
        privacy.started
            .sink { [weak self] event in
                guard let self, self.flags.isOn(.privacyAlerts), !self.lock.isLocked else { return }
                switch event {
                case .mic(let app):
                    self.showBanner(Banner(icon: app.map { Banner.Icon.image($0.icon, fallback: "mic.fill") } ?? Banner.Icon.symbol("mic.fill", .orange),
                                           badge: app == nil ? nil : Banner.Badge(symbol: "mic.fill", color: .orange),
                                           caption: String(localized: "Using your microphone"),
                                           title: app?.name ?? String(localized: "Microphone"),
                                           trailing: .symbol("mic.fill", .orange),
                                           duration: 3), always: true)
                case .camera:
                    self.showBanner(Banner(icon: .symbol("video.fill", .green),
                                           caption: String(localized: "In use"),
                                           title: String(localized: "Camera"),
                                           trailing: .symbol("video.fill", .green),
                                           duration: 3), always: true)
                }
            }
            .store(in: &cancellables)

        // A reminder fell due.
        reminders.becameDue
            .sink { [weak self] due in
                guard let self, self.flags.isOn(.reminders), let first = due.first else { return }
                self.showNotice(Notice(kind: .reminder(first), more: due.count - 1))
            }
            .store(in: &cancellables)

        // Lock / unlock.
        lock.$isLocked
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.timerFinishedWhileLocked = false }
            .store(in: &cancellables)
        lock.unlocked
            .sink { [weak self] unlock in
                guard let self else { return }
                self.handleUnlock(unlock)
                // No unlock peek → show what arrived while locked right away.
                if self.peek == nil { self.showNextNotice() }
            }
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
        CGSize(width: expandedWidthNow, height: notchSize.height + expandedContentHeight)
    }

    private var expandedWidthNow: CGFloat {
        if welcome != nil || showsFileTray { return Self.expandedWidth }
        switch visibleTab {
        case .calendar where calendar.hasAccess: return Self.wideExpandedWidth
        case .home: return homeWidth
        case .agents: return 520
        default: return Self.expandedWidth
        }
    }

    /// Height below the notch: panel + top/bottom padding (the tab bar floats underneath).
    private var expandedContentHeight: CGFloat {
        if welcome != nil { return 148 }
        if showsFileTray { return 116 }
        switch visibleTab {
        case .calendar where calendar.hasAccess:
            return 220
        case .nowPlaying where nowPlaying.track != nil:
            return 146 + (showsAudioPicker ? audioPickerHeight : 0)
        case .home:
            return 196
        case .agents:
            return 186
        case .downloads:
            // Header + one row per download (up to 4, then it scrolls).
            return max(128, 62 + 36 * CGFloat(min(downloads.all.count, 4)))
        default:
            return 128
        }
    }

    /// Home: room for the widgets (+ the "add widget" column while customizing).
    var homeContentWidth: CGFloat {
        let widgets = home.widgets
        var content = widgets.reduce(CGFloat(0)) { $0 + $1.width } + CGFloat(max(widgets.count - 1, 0)) * Self.homeGap
        if isEditingHome && widgets.count < HomeSettings.Widget.allCases.count {
            content += (widgets.isEmpty ? 0 : Self.homeGap) + Self.homeAddColumnWidth
        }
        return content
    }

    /// Home grows with its widgets, up to the widest island.
    var homeWidth: CGFloat {
        min(max(homeContentWidth + 52, Self.expandedWidth), Self.maxExpandedSize.width)
    }

    /// Too many widgets for the widest island → shrink them all a little instead of clipping.
    var homeScale: CGFloat {
        let content = homeContentWidth
        return content > 0 ? min(1, (homeWidth - 52) / content) : 1
    }

    static let homeGap: CGFloat = 25
    static let homeAddColumnWidth: CGFloat = 130

    /// Home ▸ customize: remove, reorder and add widgets right in the island.
    @Published var isEditingHome = false

    /// Floating tab bar under the open island.
    var showsTabBar: Bool {
        mode == .expanded && welcome == nil && !showsFileTray && availableTabs.count > 1
    }
    static let tabBarHeight: CGFloat = 38
    static let tabBarGap: CGFloat = 8

    // MARK: - Music output picker

    enum AudioPickerTab { case output, apps }

    /// The Output / Apps list under the music controls.
    @Published var showsAudioPicker = false
    @Published var audioPickerTab: AudioPickerTab = .output

    static let audioRowHeight: CGFloat = 34
    /// Rows shown before the list scrolls.
    static let audioVisibleRows = 4

    var audioPickerRows: Int {
        switch audioPickerTab {
        case .output: return max(1, audioOutputs.devices.count + nowPlaying.airPlayTargets.count)
        case .apps: return max(1, MediaSource.allCases.filter(\.isInstalled).count)
        }
    }

    /// Divider + segmented control + rows.
    var audioPickerHeight: CGFloat {
        1 + 10 + 28 + 8 + CGFloat(min(audioPickerRows, Self.audioVisibleRows)) * Self.audioRowHeight
    }

    /// Outward flare where the island meets the top edge of the screen.
    var topRadius: CGFloat { mode == .expanded ? 14 : 6 }
    var bottomRadius: CGFloat {
        if mode == .expanded { return 30 }
        return hasPreviewRow ? 18 : 11
    }

    /// The collapsed island currently drops down with a second line.
    var hasPreviewRow: Bool {
        showsCommandBar || isShelfPeek || apiAlertHasRow || peek == .notice || peek == .banner || peek == .alert || (peek == .unlocked && awaySummary?.missed.isEmpty == false)
    }

    /// Extra height under the notch for peeks that show a preview line.
    static let previewHeight: CGFloat = 32

    /// Copied peek: a chip line, or a taller row with a thumbnail for images.
    var copiedPreviewHeight: CGFloat {
        if peek == .downloaded && lastDownload != nil { return 50 }
        if peek == .copied {
            if showsCopiedQR { return 156 }
            if lastCopied?.thumbnail != nil { return 92 }
            // Two-line text needs a little more room than one line.
            let text = lastCopied?.text ?? ""
            let twoLines = text.count > 48 || text.contains("\n")
            return twoLines ? 100 : 84
        }
        return lastCopied?.thumbnail != nil ? 50 : Self.previewHeight
    }

    // MARK: - Finished downloads

    /// The file the String(localized: "Downloaded") alert is about.
    @Published private(set) var lastDownload: URL?

    func openDownload() {
        guard let url = lastDownload else { return }
        NSWorkspace.shared.open(url)
        endPeek()
        collapseHandler?()
    }

    func revealDownload() {
        guard let url = lastDownload else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        endPeek()
        collapseHandler?()
    }

    private func pulseOutline() {
        withAnimation(.easeOut(duration: 0.18)) { copyPulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            withAnimation(.easeIn(duration: 0.6)) { self?.copyPulse = false }
        }
    }

    /// Identity of what the collapsed island is showing; changing it morphs the content.
    // MARK: - Split island

    /// Ongoing activities that can live in the collapsed island, most important first.
    enum LiveActivity: String {
        case timer, download, system, apiProgress, agent, privacy, meeting, music
    }

    var liveActivities: [LiveActivity] {
        var list: [LiveActivity] = []
        if showsTimerActivity { list.append(.timer) }
        if showsDownloadActivity { list.append(.download) }
        if systemActivity != nil { list.append(.system) }
        if showsAPIProgress { list.append(.apiProgress) }
        if showsAgentActivity { list.append(.agent) }
        if showsPrivacyActivity { list.append(.privacy) }
        if showsMeetingActivity { list.append(.meeting) }
        if showsMusicActivity { list.append(.music) }
        return list
    }

    /// The second activity, shown in its own bubble beside the island (iPhone-style).
    /// Hidden while expanded or while an alert is showing.
    var secondaryActivity: LiveActivity? {
        guard flags.isOn(.splitIsland), mode == .collapsed, peek == nil else { return nil }
        let list = liveActivities
        return list.count > 1 ? list[1] : nil
    }

    static let bubbleGap: CGFloat = 6
    static let bubbleFlare: CGFloat = 6

    /// Bubble = a notch-height circle hanging from the top edge (flares included).
    var bubbleSize: CGSize {
        CGSize(width: notchSize.height + 2 * Self.bubbleFlare, height: notchSize.height)
    }

    /// Bubble centre relative to the island centre: a 6-pt gap between the two bodies.
    var bubbleOffset: CGFloat {
        currentSize.width / 2 - topRadius + Self.bubbleGap + bubbleSize.width / 2 - Self.bubbleFlare
    }

    func tab(for activity: LiveActivity) -> Tab? {
        switch activity {
        case .timer: return .timer
        case .meeting: return .calendar
        case .music: return .nowPlaying
        case .download: return .downloads
        case .apiProgress: return nil
        case .agent: return .agents
        case .privacy: return nil
        case .system: return nil
        }
    }

    var compactKey: String {
        if let peek { return "peek-\(peek)" }
        if showsTimerActivity { return "timer" }
        if showsDownloadActivity { return "download" }
        if systemActivity != nil { return "system" }
        if showsAPIProgress { return "api-progress" }
        if showsAgentActivity { return "agent" }
        if showsPrivacyActivity { return "privacy" }
        if showsMeetingActivity { return compactJoinMeeting != nil ? "meeting-join" : "meeting" }
        if showsMusicActivity { return "music" }
        return "idle"
    }

    /// Copied / screenshot / downloaded / dropped on the tray: the peeks that preview a shelf item.
    var isShelfPeek: Bool {
        peek == .copied || peek == .screenshot || peek == .downloaded || peek == .tray
    }

    static let bannerHeight: CGFloat = 62
    static let alertHeight: CGFloat = 132

    /// "Something finished" moments get the frosted bottom edge: an agent done, a download
    /// done, a script's `notch done`, or a terminal command that succeeded.
    var showsFinishedGlow: Bool {
        switch peek {
        case .banner: return banner?.finished == true
        case .downloaded: return true
        case .apiAlert:
            guard let alert = apiAlert else { return false }
            return alert.badge == "Done" || alert.icon == "checkmark.circle.fill"
        default: return false
        }
    }

    /// A script is reporting progress through the Island API.
    var showsAPIProgress: Bool {
        flags.isOn(.islandAPI) && api.progress != nil
    }

    /// API alerts with a subtitle / badge / long title drop down a second line.
    var apiAlertHasRow: Bool {
        peek == .apiAlert && apiAlert.map { !$0.isCompact } == true
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

    /// Liquid Glass controls (macOS 26+, switched on).
    var usesGlass: Bool { LiquidGlass.isActive }
    /// The island itself is glass only where there's no camera housing to hide.
    var usesGlassSurface: Bool { usesGlass && !hasHardwareNotch }

    /// Tabs for the features that are switched on, in display order.
    var availableTabs: [Tab] {
        var tabs: [Tab] = []
        if flags.isOn(.homeDashboard) && !home.widgets.isEmpty { tabs.append(.home) }
        if flags.isOn(.nowPlaying) { tabs.append(.nowPlaying) }
        if flags.isOn(.calendar) { tabs.append(.calendar) }
        if flags.isOn(.clipboard) { tabs.append(.clipboard) }
        if flags.isOn(.timer) { tabs.append(.timer) }
        // Only while something is downloading.
        if flags.isOn(.downloads) && !downloads.all.isEmpty { tabs.append(.downloads) }
        if flags.isOn(.islandAPI) && !api.agentSessions.isEmpty { tabs.append(.agents) }
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
        if showsCommandBar { return commandBarSize }
        if mode == .expanded { return expandedSize }
        var width = notchSize.width + 2 * topRadius
        if isShelfPeek {
            // Drops down to show what was copied (taller for image thumbnails).
            let extra: CGFloat = peek == .copied ? 280 : 200
            return CGSize(width: width + extra, height: notchSize.height + copiedPreviewHeight)
        } else if apiAlertHasRow || peek == .notice {
            return CGSize(width: width + 200, height: notchSize.height + Self.previewHeight)
        } else if peek == .banner {
            return CGSize(width: width + 240, height: notchSize.height + Self.bannerHeight)
        } else if peek == .alert {
            return CGSize(width: width + 300, height: notchSize.height + Self.alertHeight)
        } else if peek == .unlocked && awaySummary?.missed.isEmpty == false {
            return CGSize(width: width + 200, height: notchSize.height + Self.previewHeight)
        } else if peek == .unlocked && awaySummary?.showsAwayTime != true {
            width += 44
        } else if peek != nil {
            // Both ears grow together so the island stays centred on the camera.
            let ear = batteryPeekEar ?? peekEarText.map { Self.textWidth($0) + Self.earInset } ?? 0
            width += max(130, 2 * ear)
        } else if compactJoinMeeting != nil {
            width += 150    // room for the Join button beside the camera
        } else if liveActivities.first == .agent, latestAgent?.currentStarted != nil {
            width += 140    // spinner + "1m 05s" beside the camera
        } else if !liveActivities.isEmpty {
            width += 84
        }
        return CGSize(width: width, height: notchSize.height)
    }

    /// String(localized: "Charging") / String(localized: "Plugged in") / String(localized: "Fully charged") / String(localized: "Low battery") — left of the camera.
    var batteryPeekLabel: String? {
        switch peek {
        case .charging: return battery.isCharging || !battery.isFull ? String(localized: "Charging") : String(localized: "Plugged in")
        case .charged: return String(localized: "Fully charged")
        case .lowBattery: return String(localized: "Low battery")
        default: return nil
        }
    }

    /// Battery peeks: ⚡ label on the left, "81% ▭" on the right — the wider side sets both ears.
    private var batteryPeekEar: CGFloat? {
        guard let label = batteryPeekLabel else { return nil }
        let left = 14 + 6 + Self.textWidth(label)
        let right = Self.textWidth("\(battery.level)%") + 6 + 26
        return max(left, right) + Self.earInset
    }

    /// Text shown in the right ear (beside the camera) by the current peek.
    private var peekEarText: String? {
        switch peek {
        case .apiAlert: return apiAlert.flatMap { $0.isCompact ? $0.title : nil }
        case .screenshot: return String(localized: "Screenshot")
        case .downloaded: return String(localized: "Downloaded")
        case .tray: return String(localized: "Added to tray")
        case .unlocked: return awaySummary.map { "Away \(Self.formatAway($0.awayFor))" }
        default: return nil
        }
    }

    /// Ear = text + content padding (topRadius + 8) − topRadius + a gap from the notch.
    private static let earInset: CGFloat = 8 + 8

    /// Width of compact-island text (12 pt semibold, rounded) — what CompactView draws.
    static func textWidth(_ text: String) -> CGFloat {
        // Measured once per string: sizes are computed on every render and mouse move.
        if let cached = textWidths[text] { return cached }
        let width = ceil((text as NSString).size(withAttributes: [.font: compactFont]).width)
        if textWidths.count > 200 { textWidths.removeAll() }
        textWidths[text] = width
        return width
    }

    private static var textWidths: [String: CGFloat] = [:]
    private static let compactFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 12) } ?? base
    }()

    // MARK: - Agents

    var latestAgent: AgentSession? { api.agentSessions.first }

    /// An AI agent is working (or waiting for you) in a terminal.
    /// A Time Machine backup or a copy onto a drive (whichever is switched on; copies first).
    var systemActivity: SystemProgressService.Activity? {
        guard flags.isOn(.systemEvents) else { return nil }
        if flags.isOn(.copyProgress), let copy = systemProgress.copy { return copy }
        if flags.isOn(.backupProgress), let backup = systemProgress.backup { return backup }
        return nil
    }

    /// An app is using the microphone or camera.
    var showsPrivacyActivity: Bool {
        flags.isOn(.privacyInCompact) && privacy.isActive
    }

    var showsAgentActivity: Bool {
        flags.isOn(.islandAPI) && latestAgent.map { $0.state != .done } == true && !agentHostInFront
    }

    /// The running agent's window is the one in front (then the island leaves it out).
    @Published private(set) var agentHostInFront = false
    private var agentFocusTimer: Timer?

    /// Re-checks whether the agent's window is in front: on every app switch, and every
    /// 2 s while an agent is working (minimizing a window doesn't announce itself).
    private func refreshAgentFocus() {
        let active = latestAgent.map { $0.state != .done } == true
        let inFront = active && latestAgent?.isHostInFront == true
        if agentHostInFront != inFront { agentHostInFront = inFront }
        if active, agentFocusTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshAgentFocus() }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            agentFocusTimer = timer
        } else if !active, let timer = agentFocusTimer {
            timer.invalidate()
            agentFocusTimer = nil
        }
    }

    // MARK: - One-click Join

    /// The collapsed island is showing a meeting with a video link → a Join button.
    var compactJoinMeeting: Meeting? {
        guard mode == .collapsed, peek == nil, liveActivities.first == .meeting,
              let meeting = calendar.next, meeting.joinURL != nil else { return nil }
        return meeting
    }

    func joinFromCompact() {
        guard let meeting = compactJoinMeeting else { return }
        calendar.join(meeting)
        collapseHandler?()
    }

    // MARK: - Files Tray

    /// Files dropped on the tray join the shelf.
    func dropOnTray(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var last: ClipItem?
        for url in urls {
            last = clipboard.addShelfFile(url, source: "Files Tray", icon: NSWorkspace.shared.icon(forFile: url.path))
        }
        withAnimation(Self.spring) {
            showsFileTray = false
            fileTrayTargeted = false
        }
        collapseHandler?()
        lastCopied = last ?? lastCopied
        showPeek(.tray, duration: 2.5)
    }

    // MARK: - Banners

    /// Drops the island down with details; it shrinks back to the compact view after a moment.
    /// - Parameter always: show even with "Live activity banners" off (agent results replace an alert).
    func showBanner(_ newBanner: Banner, always: Bool = false) {
        guard always || flags.isOn(.liveBanners), mode == .collapsed, welcome == nil else { return }
        banner = newBanner
        showPeek(.banner, duration: newBanner.duration)
    }

    private func installBannerTriggers() {
        // Timer started.
        timer.$state
            .removeDuplicates()
            .scan((TimerService.State.idle, TimerService.State.idle)) { ($0.1, $1) }
            .dropFirst()
            .sink { [weak self] previous, current in
                guard let self, previous == .idle, current == .running else { return }
                let minutes = max(1, Int((self.timer.lastDuration / 60).rounded()))
                self.showBanner(Banner(icon: .symbol("timer", .orange), caption: String(localized: "Timer started"),
                                       title: "\(minutes) min", subtitle: "Ends at \(Date().addingTimeInterval(self.timer.lastDuration).formatted(date: .omitted, time: .shortened))",
                                       trailing: .ring(1, .orange, nil)))
            }
            .store(in: &cancellables)

        // Download started.
        downloads.$active
            .map { $0 != nil }      // started — not every rename / progress tick
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] started in
                guard let self, started, self.flags.isOn(.downloads) else { return }
                // Skip the banner for downloads that finish within a second — the
                // String(localized: "Downloaded") alert is enough for those.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.downloads.active != nil else { return }
                    // Live banner: name, size, time left and the ring keep updating while it shows.
                    self.showBanner(Banner(icon: .symbol("arrow.down.circle.fill", Feature.downloads.tint),
                                           title: "", duration: 4, live: .download))
                }
            }
            .store(in: &cancellables)

        // Download cancelled, or stopped without saving a file.
        downloads.failed
            .sink { [weak self] failure in
                guard let self, self.flags.isOn(.downloads) else { return }
                if self.peek == .banner, self.banner?.live == .download { self.peek = nil }
                self.showBanner(Banner(icon: .symbol(failure.cancelled ? "xmark.circle.fill" : "exclamationmark.triangle.fill",
                                                     failure.cancelled ? .gray : .red),
                                       caption: failure.cancelled ? String(localized: "Download cancelled") : String(localized: "Download failed"),
                                       title: failure.name,
                                       subtitle: failure.cancelled ? nil : String(localized: "It stopped before finishing — try again in the browser"),
                                       trailing: .symbol("xmark", failure.cancelled ? .gray : .red),
                                       duration: failure.cancelled ? 2.5 : 4.5), always: true)
            }
            .store(in: &cancellables)

        // Music started playing.
        nowPlaying.$track
            .map { $0?.isPlaying == true }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] playing in
                guard let self, playing, self.flags.isOn(.musicInCompact), let track = self.nowPlaying.track else { return }
                self.showBanner(Banner(icon: .artwork, caption: String(localized: "Now Playing"), title: track.title,
                                       subtitle: track.subtitle, trailing: .symbol("waveform", Feature.nowPlaying.tint)))
            }
            .store(in: &cancellables)

        // A meeting is about to start.
        calendar.$isSoon
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] soon in
                guard let self, soon, self.flags.isOn(.meetingInCompact), let meeting = self.calendar.next else { return }
                let tint = Color(nsColor: meeting.color)
                self.showBanner(Banner(icon: .symbol("calendar.badge.clock", tint), caption: meeting.relativeLabel(at: Date()),
                                       title: meeting.title, subtitle: meeting.timeRange,
                                       trailing: meeting.joinURL != nil ? .symbol("video.fill", .green) : .none, duration: 5))
            }
            .store(in: &cancellables)

        // A script started reporting progress.
        api.$progress
            .map { $0?.id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] id in
                guard let self, id != nil, let activity = self.api.progress else { return }
                let tint = IslandAPIService.swiftUIColor(activity.color)
                self.showBanner(Banner(icon: .symbol(activity.icon, tint), caption: String(localized: "In progress"), title: activity.title,
                                       trailing: .ring(activity.value, tint, nil)))
            }
            .store(in: &cancellables)

        // AI agents: started / needs you / finished.
        // Agents: stay quiet while their window is the one you're looking at.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.refreshAgentFocus() }
            .store(in: &cancellables)
        api.$agentSessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAgentFocus() }
            .store(in: &cancellables)

        api.agentEvents
            .sink { [weak self] event in
                guard let self, self.flags.isOn(.islandAPI) else { return }
                let session: AgentSession
                switch event {
                case .started(let s), .needsInput(let s), .finished(let s): session = s
                }
                // You're looking at its window: no banner.
                if session.isHostInFront { return }
                switch event {
                case .started(let session):
                    let tint = IslandAPIService.swiftUIColor(session.tint)
                    self.showBanner(Banner(icon: .image(session.icon, fallback: "sparkles"),
                                           caption: [session.displayName, session.project].filter { !$0.isEmpty }.joined(separator: " · "),
                                           title: session.title, trailing: .spinner(tint)))
                case .needsInput(let session):
                    self.showBanner(Banner(icon: .image(session.icon, fallback: "sparkles"),
                                           badge: .init(symbol: "hand.raised.fill", color: .yellow),
                                           title: "\(session.displayName) needs your input",
                                           subtitle: session.message ?? session.project,
                                           trailing: .symbol("hand.raised.fill", .yellow), duration: 8), always: true)
                case .finished(let session):
                    self.showBanner(Banner(icon: .image(session.icon, fallback: "sparkles"),
                                           badge: .init(symbol: "checkmark", color: .green),
                                           title: "\(session.displayName) finished",
                                           subtitle: session.finishedLine ?? session.project,
                                           trailing: .check(.green), duration: 6, finished: true), always: true)
                }
            }
            .store(in: &cancellables)

        // Headphones connected → banner with battery, then shrink to icon + ring.
        audioOutputs.connected
            .sink { [weak self] device in
                guard let self, self.flags.isOn(.deviceAlerts) else { return }
                BluetoothBattery.level(of: device.name) { [weak self] level in
                    guard let self else { return }
                    self.connectedDevice = ConnectedDevice(name: device.name, symbol: device.symbol, battery: level)
                    let fraction = level.map { Double($0) / 100 }
                    let tint: Color = (level ?? 100) <= 20 ? .red : .green
                    self.showBanner(Banner(icon: .symbol(device.symbol, .white), caption: String(localized: "Connected"), title: device.name,
                                           trailing: .ring(fraction, tint, level.map { "\($0)" }),
                                           duration: 3.5, followUp: .device), always: true)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Opening

    /// Like tapping a Live Activity on iPhone: open on whatever the compact island
    /// is showing. With nothing in particular showing, keep the last-used tab.
    /// - Parameter preferSecondary: the mouse is over the split bubble → open its activity.
    func selectTabForCurrentActivity(preferSecondary: Bool = false) {
        if preferSecondary, let secondary = secondaryActivity,
           let target = tab(for: secondary), availableTabs.contains(target) {
            tab = target
            return
        }
        if peek == .unlocked, let target = awaySummary?.tab, availableTabs.contains(target) {
            tab = target
        } else if isShelfPeek {
            tab = .clipboard
        } else if let primary = liveActivities.first,
                  let target = tab(for: primary), availableTabs.contains(target) {
            // Whatever the collapsed island is showing: timer, download (→ the downloads
            // list in Clipboard), agent, meeting, music.
            tab = target
        }
    }

    // MARK: - Welcome

    func beginWelcome(firstRun: Bool) {
        let subtitle = firstRun
            ? "Welcome to Notch Island — hover over the notch anytime."
            : Date().formatted(.dateTime.weekday(.wide).day().month(.wide))
        welcome = Welcome(
            greeting: Self.welcomeGreeting(),
            name: ThemeSettings.shared.name.trimmingCharacters(in: .whitespaces).isEmpty
                ? Self.firstName() : ThemeSettings.shared.name.trimmingCharacters(in: .whitespaces),
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

    /// Your own greeting, else a festival's ("Happy Diwali"), else the time of day.
    static func welcomeGreeting() -> String {
        let custom = ThemeSettings.shared.greeting.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        if ThemeSettings.shared.seasonal, let festive = Season.current()?.greeting { return festive }
        return greeting(for: Date())
    }

    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return String(localized: "Good morning")
        case 12..<17: return String(localized: "Good afternoon")
        case 17..<22: return String(localized: "Good evening")
        default: return String(localized: "Hello")
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
        // An alert waits for an answer; nothing else replaces it.
        if peek == .alert && newPeek != .alert {
            Log.island.notice("\(String(describing: newPeek), privacy: .public) skipped — an alert is showing")
            return
        }
        // A meeting / reminder notice waits for you; quick peeks don't knock it off.
        if peek == .notice && newPeek != .notice && newPeek != .alert {
            Log.island.notice("\(String(describing: newPeek), privacy: .public) skipped — a meeting/reminder notice is showing")
            return
        }
        Log.island.notice("show \(String(describing: newPeek), privacy: .public) for \(duration, privacy: .public)s — island \(self.mode == .expanded ? "open" : "closed", privacy: .public), size \(Int(self.currentSize.width), privacy: .public)×\(Int(self.currentSize.height), privacy: .public)")
        withAnimation(Self.peekSpring) { peek = newPeek }
        scheduleEndOfPeek(after: duration)
    }

    private func scheduleEndOfPeek(after duration: TimeInterval) {
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endPeek() }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func endPeek() {
        peekWork?.cancel()
        peekWork = nil
        Log.island.notice("end \(self.peek.map { String(describing: $0) } ?? "nothing", privacy: .public)")
        // A banner shrinks into its compact follow-up (e.g. AirPods icon + battery ring).
        if peek == .banner, let next = banner?.followUp {
            banner = nil
            withAnimation(Self.spring) { peek = next }
            scheduleEndOfPeek(after: 4)
            return
        }
        withAnimation(Self.collapseSpring) { peek = nil }
        noticeHovered = false
        showsCopiedQR = false
        // Let the island settle, then show anything that queued up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.peek == nil else { return }
            self.showNextNotice()
        }
    }

    /// Hovering a notice keeps it up; leaving gives a moment before it tucks away.
    func holdPeek(_ hold: Bool) {
        guard peek != nil else { return }
        if hold {
            peekWork?.cancel()
            peekWork = nil
        } else if peek != .alert {   // alerts stay until answered
            scheduleEndOfPeek(after: 2.5)
        }
    }

    // MARK: - Notices (new meetings, due reminders)

    /// Collapsed island takes clicks while this shows (instead of opening on hover).
    var isClickablePeek: Bool {
        (peek == .notice || peek == .copied || peek == .alert || (peek == .downloaded && lastDownload != nil)) && mode == .collapsed
    }

    // MARK: - Alerts

    /// "Couldn't eject “Backup” — Photos is using it."
    static func ejectAlert(volume: DiskService.Volume, blockers: [DiskService.Blocker]) -> IslandAlert {
        let apps = blockers.filter(\.isApp)
        let names = (apps.isEmpty ? blockers : apps).prefix(3).map(\.name)
        let list = ListFormatter.localizedString(byJoining: Array(names))
        let message: String
        if names.isEmpty {
            message = String(localized: "Something is still using it, often Spotlight indexing. Try again in a moment.")
        } else if names.count == 1 {
            message = String(localized: "\(list) is using it.")
        } else {
            message = String(localized: "\(list) are using it.")
        }
        var choices: [IslandAlert.Choice] = [.init(title: String(localized: "OK"), action: .dismiss)]
        if apps.count == 1, let app = apps.first {
            choices.append(.init(title: String(localized: "Quit \(app.name)"), action: .quitAndEject([app.pid], volume.url), prominent: true))
        } else if apps.count > 1 {
            choices.append(.init(title: String(localized: "Quit Apps"), action: .quitAndEject(apps.map(\.pid), volume.url), prominent: true))
        } else {
            choices.append(.init(title: String(localized: "Try Again"), action: .quitAndEject([], volume.url), prominent: true))
        }
        return IslandAlert(symbol: "externaldrive.badge.exclamationmark", tint: .orange,
                           title: String(localized: "Couldn’t eject “\(volume.name)”"),
                           message: message, choices: choices)
    }

    /// Shows an alert in the island (closing the open island first, like an incoming iPhone alert).
    func showAlert(_ alert: IslandAlert) {
        let wasOpen = mode == .expanded
        if wasOpen { collapseHandler?() }
        // Let the open island tuck away first, then drop the alert down.
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasOpen ? 0.3 : 0)) { [weak self] in
            guard let self else { return }
            self.islandAlert = alert
            self.showPeek(.alert, duration: 3600)
        }
    }

    func perform(_ choice: IslandAlert.Choice) {
        switch choice.action {
        case .open(let url): NSWorkspace.shared.open(url)
        case .quitAndEject(let pids, let url): DiskService.shared.quitAndEject(pids, volume: url)
        case .dismiss: break
        }
        dismissAlert()
    }

    func dismissAlert() {
        guard peek == .alert else { return }
        endPeek()
        collapseHandler?()
    }

    // MARK: - Command Bar

    static let commandFieldHeight: CGFloat = 44
    static let commandRowHeight: CGFloat = 42
    static let commandMaxRows = 5

    var commandBarSize: CGSize {
        let rows = CGFloat(min(commandResults.count, Self.commandMaxRows))
        let message: CGFloat = commandMessage == nil ? 0 : 26
        return CGSize(width: max(560, notchSize.width + 2 * topRadius + 320),
                      height: notchSize.height + Self.commandFieldHeight + rows * Self.commandRowHeight + message + 12)
    }

    func toggleCommandBar() {
        showsCommandBar ? closeCommandBar() : openCommandBar()
    }

    func openCommandBar() {
        guard flags.isOn(.commandBar), welcome == nil, peek != .alert else { return }
        if mode == .expanded { mode = .collapsed }
        if peek != nil { endPeek() }
        commandText = ""
        commandResults = CommandEngine.examples
        commandSelection = 0
        commandMessage = nil
        showsCommandBar = true
    }

    func closeCommandBar() {
        guard showsCommandBar else { return }
        showsCommandBar = false
        commandMessage = nil
    }

    func moveCommandSelection(_ delta: Int) {
        let count = min(commandResults.count, Self.commandMaxRows)
        guard count > 0 else { return }
        commandSelection = (commandSelection + delta + count) % count
    }

    func runSelectedCommand() {
        guard commandResults.indices.contains(commandSelection) else { return }
        run(commandResults[commandSelection])
    }

    func run(_ result: CommandResult) {
        switch result.action {
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            closeCommandBar()
        case .timer(let seconds):
            timer.start(seconds: seconds)
            closeCommandBar()
        case .reminder(let title, let due):
            switch reminders.create(title: title, due: due) {
            case .added:
                closeCommandBar()
                showBanner(Banner(icon: .tile("checklist", .yellow), caption: String(localized: "Reminder added"),
                                  title: title, subtitle: due.formatted(date: .abbreviated, time: .shortened),
                                  trailing: .check(.yellow), duration: 3, finished: true), always: true)
            case .needsAccess:
                commandMessage = String(localized: "Allow Notch Island to use Reminders, then press Enter again.")
            case .failed:
                commandMessage = String(localized: "Couldn’t add the reminder. Is there a default list in Reminders?")
            }
        case .fill(let text):
            commandText = text
        case .none:
            break
        }
    }

    // MARK: - Copied card actions

    /// The Copied card is showing a QR code instead of the preview.
    @Published var showsCopiedQR = false

    func pinCopied() {
        guard let item = lastCopied else { return }
        clipboard.togglePin(item)
    }

    /// Copy again with line breaks and runs of spaces collapsed (the new copy shows its own card).
    func copyOneLine() {
        guard let text = lastCopied?.text else { return }
        let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(oneLine, forType: .string)
    }

    func toggleCopiedQR() {
        withAnimation(Self.spring) { showsCopiedQR.toggle() }
    }

    /// The ✕ on a card: put it away now.
    func dismissPeek() {
        endPeek()
        collapseHandler?()
    }

    func showNotice(_ newNotice: Notice) {
        // Nobody would see it while locked, or it's another notice's turn.
        if lock.isLocked || peek == .notice {
            noticeQueue.append(newNotice)
            return
        }
        notice = newNotice
        showPeek(.notice, duration: newNotice.duration)
    }

    private func showNextNotice() {
        guard !lock.isLocked, !noticeQueue.isEmpty else { return }
        showNotice(noticeQueue.removeFirst())
    }

    /// Click: open the meeting in Calendar / the reminder in Reminders.
    func openNotice() {
        guard peek == .notice, let notice else { return }
        switch notice.kind {
        case .newMeeting(let meeting): calendar.open(meeting)
        case .reminder(let reminder): reminders.open(reminder)
        }
        endPeek()
        collapseHandler?()
    }

    /// The ✓ on a reminder notice.
    func completeNoticeReminder() {
        guard let notice, case .reminder(let reminder) = notice.kind else { return }
        reminders.complete(reminder)
        endPeek()
        collapseHandler?()
    }
}
