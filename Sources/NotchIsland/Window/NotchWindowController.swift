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
    private var cancellables = Set<AnyCancellable>()

    init(screen: NSScreen,
         nowPlaying: NowPlayingService,
         battery: BatteryService,
         clipboard: ClipboardService,
         timer: TimerService,
         calendar: CalendarService,
         lock: LockService,
         screenshots: ScreenshotService,
         downloads: DownloadsService,
         flags: FeatureFlags) {
        self.screen = screen
        viewModel = IslandViewModel(
            notchSize: NotchGeometry.notchSize(for: screen),
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

        let expanded = viewModel.expandedSize
        let size = CGSize(width: expanded.width + 2 * Self.margin, height: expanded.height + Self.margin)
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
    }

    private func evaluateMouse() {
        let point = NSEvent.mouseLocation

        if suppressHoverUntilExit {
            if !hotRect().contains(point) { suppressHoverUntilExit = false }
            return
        }

        // Ringing timer: stay open regardless of where the mouse is.
        if viewModel.isAlerting {
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

        if hotRect().contains(point) {
            collapseWork?.cancel()
            collapseWork = nil
            if viewModel.mode != .expanded { setExpanded(true) }
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
        return NSRect(
            x: screen.frame.midX - size.width / 2 - pad,
            y: screen.frame.maxY - size.height - pad,
            width: size.width + 2 * pad,
            height: size.height + pad + 4   // +4 so the very top pixel row counts
        )
    }

    private func setExpanded(_ expanded: Bool) {
        if expanded, viewModel.mode != .expanded {
            viewModel.selectTabForCurrentActivity()
        }
        withAnimation(expanded ? IslandViewModel.spring : IslandViewModel.collapseSpring) {
            viewModel.mode = expanded ? .expanded : .collapsed
        }
        panel.ignoresMouseEvents = !expanded
        if expanded, viewModel.flags.isOn(.hoverHaptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}
