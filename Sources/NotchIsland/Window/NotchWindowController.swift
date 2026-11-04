import AppKit
import SwiftUI
import Combine

/// Owns the panel for one screen and drives hover → expand / collapse.
final class NotchWindowController {
    private static let margin: CGFloat = 30   // room for the expanded shadow

    private let screen: NSScreen
    private let panel: NotchPanel
    private let viewModel: IslandViewModel
    private var monitors: [Any] = []
    private var collapseWork: DispatchWorkItem?
    /// After a forced collapse (e.g. paste), don't re-open until the mouse leaves the notch.
    private var suppressHoverUntilExit = false
    private var dragWatch: Timer?
    private var welcomeWork: DispatchWorkItem?
    /// Drag pasteboard count when the button went down: a change means a drag started.
    private var dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    private var fileDragActive = false
    private var cancellables = Set<AnyCancellable>()

    init(screen: NSScreen,
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
        self.screen = screen
        viewModel = IslandViewModel(
            notchSize: NotchGeometry.notchSize(for: screen),
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

        viewModel.hasHardwareNotch = NotchGeometry.hasNotch(screen)

        let expanded = IslandViewModel.maxExpandedSize
        let size = CGSize(width: expanded.width + 2 * Self.margin,
                          height: expanded.height + IslandViewModel.tabBarHeight + IslandViewModel.tabBarGap + Self.margin)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        panel = NotchPanel(contentRect: frame)
        let host = FirstMouseHostingView(rootView: IslandView(vm: viewModel))
        host.frame = NSRect(origin: .zero, size: size)
        // Don't let SwiftUI resize/re-constrain the window while the island animates.
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        installMouseMonitors()

        // Timer alert: pop the island open and hold it there until dismissed.
        timer.$state
            .map { [weak self] state in state == .ringing && self?.viewModel.flags.isOn(.timerAlert) == true }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] ringing in
                guard let self else { return }
                if ringing {
                    self.suppressHoverUntilExit = false
                    self.collapseWork?.cancel()
                    self.collapseWork = nil
                    self.setExpanded(true)
                } else if self.viewModel.mode == .expanded,
                          !self.hotRect().contains(NSEvent.mouseLocation) {
                    self.setExpanded(false)
                }
            }
            .store(in: &cancellables)

        // Home ▸ Add a task: let the panel take typing, and stop when focus leaves.
        viewModel.$isAddingTodo
            .removeDuplicates()
            .sink { [weak self] adding in
                guard let self else { return }
                self.panel.allowsKey = adding
                if adding { self.panel.makeKey() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                guard let self, self.viewModel.isAddingTodo else { return }
                self.viewModel.isAddingTodo = false
            }
            .store(in: &cancellables)

        // Command Bar: take typing and clicks while it's open; close it when focus leaves.
        viewModel.$showsCommandBar
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] showing in
                guard let self else { return }
                self.collapseWork?.cancel()
                self.collapseWork = nil
                self.panel.allowsKey = showing || self.viewModel.isAddingTodo
                if showing {
                    self.panel.ignoresMouseEvents = false
                    self.panel.makeKey()
                } else {
                    self.panel.ignoresMouseEvents = self.viewModel.mode == .collapsed && !self.viewModel.isClickablePeek
                    // Don't pop the island open just because the pointer happens to be there.
                    self.suppressHoverUntilExit = self.hotRect().contains(NSEvent.mouseLocation)
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in self?.viewModel.closeCommandBar() }
            .store(in: &cancellables)

        // CPU is only sampled while the Home tab is on screen.
        viewModel.$tab
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatsSampling() }
            }
            .store(in: &cancellables)

        viewModel.collapseHandler = { [weak self] in
            guard let self else { return }
            self.collapseWork?.cancel()
            self.collapseWork = nil
            self.suppressHoverUntilExit = true
            self.setExpanded(false)
        }
    }

    /// Launch greeting. Timeline (seconds):
    ///   0.00  island opens
    ///   0.30  "Good evening,"  + hand waves
    ///   0.70  name
    ///   1.10  date + feature icons appear (dim)
    ///   1.20  services start; icons light up one by one
    ///   4.00  "All set" has had a moment; island tucks away (5.5 s on first run)
    /// Clicking the greeting dismisses it early; services still start.
    func playWelcome(firstRun: Bool, initialize: @escaping () -> Void) {
        viewModel.beginWelcome(firstRun: firstRun)
        setExpanded(true)

        for (index, delay) in [0.3, 0.7, 1.1].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.viewModel.welcome != nil, self.viewModel.welcomePhase == index else { return }
                self.viewModel.advanceWelcome()
            }
        }

        let features = viewModel.welcome?.features.count ?? 0
        let initializeAt = 1.2
        DispatchQueue.main.asyncAfter(deadline: .now() + initializeAt) { [weak self] in
            initialize()
            // Calendar loads synchronously when enabled; give it a beat, then summarise the day.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let self, self.viewModel.welcome != nil else { return }
                self.viewModel.refreshWelcomeContext()
            }
        }
        for index in 0..<features {
            DispatchQueue.main.asyncAfter(deadline: .now() + initializeAt + 0.25 + Double(index) * 0.22) { [weak self] in
                guard let self, self.viewModel.welcome != nil else { return }
                self.viewModel.lightWelcomeFeature()
            }
        }

        let total = max(firstRun ? 5.5 : 4.0, initializeAt + 0.25 + Double(features) * 0.22 + 1.0)
        let finish = DispatchWorkItem { [weak self] in self?.finishWelcome() }
        welcomeWork = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + total, execute: finish)

        viewModel.dismissWelcome = { [weak self] in
            self?.welcomeWork?.cancel()
            self?.finishWelcome()
        }
    }

    private func finishWelcome() {
        guard viewModel.welcome != nil else { return }
        welcomeWork = nil
        if hotRect().contains(NSEvent.mouseLocation) {
            // Hovering: swap straight to the normal island.
            withAnimation(IslandViewModel.contentSpring) { viewModel.endWelcome() }
        } else {
            setExpanded(false)
            // Drop the greeting once it's out of sight, so it doesn't flash the tabs.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.viewModel.endWelcome()
            }
        }
    }

    /// The screen this island lives on (to open the Command Bar where the pointer is).
    var screenFrame: NSRect { screen.frame }

    func toggleCommandBar() {
        viewModel.toggleCommandBar()
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        collapseWork?.cancel()
        dragWatch?.invalidate()
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: - Hover tracking

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        // Global: mouse is over other apps / the menu bar (panel is click-through).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.evaluateMouse()
        }) {
            monitors.append(global)
        }
        // Local: mouse is over our own panel (when expanded).
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.evaluateMouse()
            return event
        }) {
            monitors.append(local)
        }
        // Button down / up: tells file drags (→ Files Tray) apart from ordinary clicks.
        if let buttons = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDown {
                self.dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
            } else if self.fileDragActive {
                self.endFileDrag()
            }
        }) {
            monitors.append(buttons)
        }
    }

    private func evaluateMouse() {
        let point = NSEvent.mouseLocation

        // Dragging a file toward the notch → Files Tray.
        if trackFileDrag(at: point) { return }

        // Fast path (this runs on every mouse move): island closed, nothing being held,
        // and the pointer is well below the top of this screen → nothing to do.
        if viewModel.mode == .collapsed, !fileDragActive, !viewModel.noticeHovered, !viewModel.isAlerting,
           !viewModel.showsCommandBar,
           !screen.frame.contains(point) || point.y < screen.frame.maxY - 240 {
            suppressHoverUntilExit = false
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            return
        }

        if suppressHoverUntilExit {
            if !hotRect().contains(point) { suppressHoverUntilExit = false }
            return
        }

        // Ringing timer, or typing a to-do: stay open regardless of where the mouse is.
        if viewModel.isAlerting || viewModel.isAddingTodo || viewModel.showsCommandBar {
            collapseWork?.cancel()
            collapseWork = nil
            return
        }

        // Dragging a clipboard card out: keep the island open until the drop.
        if viewModel.isDragging {
            collapseWork?.cancel()
            collapseWork = nil
            watchDragEnd()
            return
        }

        // Meeting about to start: the Join button beside the camera takes clicks.
        if viewModel.compactJoinMeeting != nil, joinRect().contains(point) {
            panel.ignoresMouseEvents = false
            collapseWork?.cancel()
            collapseWork = nil
            return
        }

        // A meeting / reminder notice: hovering holds it and makes it clickable,
        // instead of opening the island.
        if viewModel.isClickablePeek {
            let inside = hotRect().contains(point)
            panel.ignoresMouseEvents = !inside
            if inside != viewModel.noticeHovered {
                withAnimation(.easeOut(duration: 0.15)) { viewModel.noticeHovered = inside }
                viewModel.holdPeek(inside)
            }
            return
        } else if viewModel.mode == .collapsed, !panel.ignoresMouseEvents {
            panel.ignoresMouseEvents = true
        }

        if hotRect().contains(point) {
            collapseWork?.cancel()
            collapseWork = nil
            if viewModel.mode != .expanded {
                setExpanded(true, preferSecondary: bubbleRect()?.contains(point) == true)
            }
        } else if viewModel.mode == .expanded, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.collapseWork = nil
                self?.setExpanded(false)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    /// Drag sessions swallow mouse-up events, so poll the button state instead.
    private func watchDragEnd() {
        guard dragWatch == nil else { return }
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            self.dragWatch = nil
            self.viewModel.isDragging = false
            self.evaluateMouse()
        }
    }

    /// Area (in global screen coordinates) that counts as "hovering the island".
    private func hotRect() -> NSRect {
        let size = viewModel.mode == .expanded ? viewModel.expandedSize : viewModel.currentSize
        let pad: CGFloat = viewModel.mode == .expanded ? 8 : 4
        // The floating tab bar under the open island counts too.
        let bar = viewModel.showsTabBar ? IslandViewModel.tabBarHeight + IslandViewModel.tabBarGap : 0
        let island = NSRect(
            x: screen.frame.midX - size.width / 2 - pad,
            y: screen.frame.maxY - size.height - bar - pad,
            width: size.width + 2 * pad,
            height: size.height + bar + pad + 4   // +4 so the very top pixel row counts
        )
        return bubbleRect().map { island.union($0) } ?? island
    }

    /// The right "ear" of the collapsed island, where the Join button sits.
    private func joinRect() -> NSRect {
        let notch = viewModel.notchSize
        let half = viewModel.currentSize.width / 2
        return NSRect(x: screen.frame.midX + notch.width / 2, y: screen.frame.maxY - notch.height - 2,
                      width: half - notch.width / 2 + 4, height: notch.height + 4)
    }

    // MARK: - Files Tray

    /// - Returns: true while a file drag is being handled (skip normal hover logic).
    private func trackFileDrag(at point: NSPoint) -> Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0, !viewModel.isDragging, viewModel.flags.isOn(.clipboard) else {
            if fileDragActive { endFileDrag() }
            return false
        }
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != dragCountAtMouseDown, board.types?.contains(.fileURL) == true else { return false }

        // Close to the notch, or over the open tray.
        let near = NSRect(x: screen.frame.midX - 280, y: screen.frame.maxY - 150, width: 560, height: 150)
        if near.contains(point) || (fileDragActive && hotRect().contains(point)) {
            if !fileDragActive {
                fileDragActive = true
                collapseWork?.cancel()
                collapseWork = nil
                withAnimation(IslandViewModel.spring) { viewModel.showsFileTray = true }
                if viewModel.mode != .expanded { setExpanded(true) }
            }
        } else if fileDragActive {
            endFileDrag()
        }
        return fileDragActive
    }

    /// The drag ended or left: put the tray away (after a beat, so a drop can land first).
    private func endFileDrag() {
        fileDragActive = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.viewModel.showsFileTray else { return }
            withAnimation(IslandViewModel.spring) {
                self.viewModel.showsFileTray = false
                self.viewModel.fileTrayTargeted = false
            }
            if !self.hotRect().contains(NSEvent.mouseLocation) { self.setExpanded(false) }
        }
    }

    private func updateStatsSampling() {
        viewModel.stats.isActive = viewModel.mode == .expanded && viewModel.visibleTab == .home && viewModel.welcome == nil
    }

    /// The split bubble's area, when one is showing.
    private func bubbleRect() -> NSRect? {
        guard viewModel.secondaryActivity != nil else { return nil }
        let size = viewModel.bubbleSize
        let centerX = screen.frame.midX + viewModel.bubbleOffset
        return NSRect(x: centerX - size.width / 2 - 4, y: screen.frame.maxY - size.height - 4,
                      width: size.width + 8, height: size.height + 8)
    }

    private func setExpanded(_ expanded: Bool, preferSecondary: Bool = false) {
        if expanded, viewModel.mode != .expanded {
            viewModel.selectTabForCurrentActivity(preferSecondary: preferSecondary)
        }
        withAnimation(expanded ? IslandViewModel.spring : IslandViewModel.collapseSpring) {
            viewModel.mode = expanded ? .expanded : .collapsed
        }
        panel.ignoresMouseEvents = !expanded
        updateStatsSampling()
        if !expanded {
            // Once tucked away, reset the calendar to today and close the output list.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.viewModel.mode == .collapsed else { return }
                self.viewModel.showsAudioPicker = false
                self.viewModel.isEditingHome = false
                self.viewModel.calendar.resetDashboard()
            }
        }
        if expanded, viewModel.flags.isOn(.hoverHaptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}
