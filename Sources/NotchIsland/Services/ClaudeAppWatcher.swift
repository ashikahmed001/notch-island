import AppKit
import ApplicationServices

/// Shows what the Claude desktop app is doing ("Running a command on your computer · 39s")
/// by reading its window through macOS Accessibility — the app has no hooks or API for this.
///
/// - "Working": the chat shows a Stop button.
/// - Current step: the newest status line ("Running…", "Searching…", "Thinking…").
/// - Needs you: an Allow / Deny prompt is showing.
/// - Finished: the Stop button has been gone for a couple of checks.
///
/// Best effort: it depends on the Claude app's on-screen wording (English), so an app
/// update can change what it finds. It never touches the app — it only reads.
/// What the watcher can see right now — shown under the switch in Settings.
final class ClaudeAppStatus: ObservableObject {
    static let shared = ClaudeAppStatus()

    enum State: Equatable {
        case off, starting, needsAccessibility, claudeNotRunning, noWindow, watching, working, waitingForYou, slow
    }
    @Published fileprivate(set) var state: State = .off
    /// Status line read from the Claude window last time it was working.
    @Published fileprivate(set) var lastStatus: String?

    fileprivate func set(_ new: State) {
        if state != new { state = new }
    }
}

final class ClaudeAppWatcher {
    static let bundleID = "com.anthropic.claudefordesktop"
    private let status = ClaudeAppStatus.shared
    /// A scan that hasn't come back by now is abandoned (the Claude app isn't answering).
    private static let scanTimeout: TimeInterval = 15
    /// Each scan reads for at most this long, however big the chat is.
    private static let scanBudget: TimeInterval = 1.5

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { start() } else { stop() }
        }
    }

    private let api: IslandAPIService
    private let queue = DispatchQueue(label: "NotchIsland.ClaudeApp", qos: .utility)
    private var timer: Timer?
    private var scanning = false
    private var working = false
    private var waiting = false
    private var lastStatus: String?
    private var idleScans = 0
    private var accessibilityEnabledFor = Set<pid_t>()
    /// Last reason we couldn't look (logged once per change).
    private var lastProblem: String?
    private var lastSummary: String?
    private var scanStarted: Date?
    private var scanGeneration = 0
    private var promptedForAccessibility = false

    init(api: IslandAPIService) {
        self.api = api
    }

    // MARK: - Polling

    private func start() {
        guard timer == nil else { return }
        Log.claude.notice("watching for the Claude app")
        status.set(.starting)
        // Every Accessibility call waits at most half a second (the default is 6 s per call,
        // which can stall a scan of a busy Electron window for minutes).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        lastProblem = nil
        lastSummary = nil
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        scanning = false
        scanGeneration += 1
        if working { finish() }
        status.set(.off)
        Log.claude.notice("stopped watching the Claude app")
    }

    private func tick() {
        if scanning {
            guard let started = scanStarted, Date().timeIntervalSince(started) > Self.scanTimeout else { return }
            Log.claude.notice("the Claude window didn't answer for \(Int(Self.scanTimeout))s — trying again")
            scanning = false
            scanGeneration += 1
            status.set(.slow)
        }
        guard AXIsProcessTrusted() else {
            report("Accessibility isn't allowed for Notch Island — System Settings ▸ Privacy & Security ▸ Accessibility")
            status.set(.needsAccessibility)
            if !promptedForAccessibility {
                // Once per launch: macOS's own "allow Accessibility" prompt.
                promptedForAccessibility = true
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            if working { finish() }
            return
        }
        guard let app = Self.claudeApp() else {
            report("Claude app not running (looked for \(Self.bundleID))")
            status.set(.claudeNotRunning)
            if working { finish() }
            return
        }
        report(nil)
        scanning = true
        scanStarted = Date()
        scanGeneration += 1
        let generation = scanGeneration
        let pid = app.processIdentifier
        // Electron apps only build their accessibility tree when asked (once per launch).
        let enable = accessibilityEnabledFor.insert(pid).inserted
        queue.async { [weak self] in
            let scan = Self.scan(pid: pid, enableAccessibility: enable)
            DispatchQueue.main.async {
                guard let self, generation == self.scanGeneration else { return }
                self.scanning = false
                self.apply(scan)
            }
        }
    }

    // MARK: - Turning scans into agent events

    private func report(_ problem: String?) {
        guard problem != lastProblem else { return }
        lastProblem = problem
        if let problem { Log.claude.notice("\(problem, privacy: .public)") }
    }

    /// The Claude desktop app (by bundle id, or by name in case the id differs).
    static func claudeApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            ?? NSWorkspace.shared.runningApplications.first {
                $0.localizedName == "Claude" && $0.activationPolicy == .regular
            }
    }

    private func apply(_ scan: Scan) {
        let summary = "windows \(scan.windows), read \(scan.visited) items — working: \(scan.isWorking), approval: \(scan.needsApproval), status: \(scan.status ?? "none")"
        if summary != lastSummary {
            lastSummary = summary
            Log.claude.notice("scan: \(summary, privacy: .public)")
        }
        if scan.windows == 0 { status.set(.noWindow) }
        else if scan.needsApproval { status.set(.waitingForYou) }
        else if scan.isWorking { status.set(.working) }
        else { status.set(.watching) }
        if let line = scan.status, status.lastStatus != line { status.lastStatus = line }
        guard scan.isWorking || scan.needsApproval else {
            // The Stop button can blink off between steps — wait for two quiet checks.
            idleScans += 1
            if working && idleScans >= 2 { finish() }
            return
        }
        idleScans = 0
        if !working {
            working = true
            waiting = false
            lastStatus = nil
            send("userpromptsubmit", ["prompt": scan.title ?? "Working on your request"])
        }
        if scan.needsApproval {
            if !waiting {
                waiting = true
                send("notification", ["message": "Waiting for you to allow or deny"])
            }
            return
        }
        waiting = false
        if let status = scan.status, status != lastStatus {
            lastStatus = status
            send("status", ["message": status])
        }
    }

    private func finish() {
        working = false
        waiting = false
        lastStatus = nil
        idleScans = 0
        send("stop", [:])
    }

    private func send(_ event: String, _ extra: [String: String]) {
        var params = ["agent": "claude-app", "event": event, "session": "claude-app", "host": Self.bundleID]
        params.merge(extra) { $1 }
        api.ingestAgentEvent(params)
    }

    // MARK: - Reading the window (background queue)

    struct Scan {
        var windows = 0
        var visited = 0
        var isWorking = false
        var needsApproval = false
        var status: String?
        var title: String?
    }

    private static let statusVerbs: Set<String> = [
        "running", "thinking", "searching", "reading", "writing", "editing", "creating", "fetching",
        "analyzing", "analysing", "working", "using", "looking", "checking", "browsing", "calling",
        "updating", "generating", "planning", "reviewing", "researching", "exploring", "opening",
        "saving", "building", "compiling", "installing", "downloading", "uploading", "drafting",
    ]

    private static func scan(pid: pid_t, enableAccessibility: Bool) -> Scan {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if enableAccessibility {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var result = Scan()
        let deadline = Date().addingTimeInterval(scanBudget)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return result }
        result.windows = windows.count

        for window in windows {
            if result.title == nil, let title = value(window, kAXTitleAttribute) as? String,
               !title.isEmpty, title != "Claude" {
                result.title = String(title.prefix(60))
            }
            // Depth-first, newest (bottom) content first; capped so a long chat stays cheap.
            var stack: [(element: AXUIElement, depth: Int)] = [(window, 0)]
            var visited = 0
            while visited < 2500, Date() < deadline, let item = stack.popLast() {
                let element = item.element
                let depth = item.depth
                visited += 1
                result.visited += 1
                let role = value(element, kAXRoleAttribute) as? String ?? ""
                if role == kAXButtonRole {
                    let label = [value(element, kAXTitleAttribute), value(element, kAXDescriptionAttribute)]
                        .compactMap { $0 as? String }
                        .joined(separator: " ")
                        .lowercased()
                        .trimmingCharacters(in: .whitespaces)
                    if label == "stop" || label.hasPrefix("stop ") || label.contains("stop response") || label.contains("stop generating") {
                        result.isWorking = true
                    }
                    if label == "allow" || label.hasPrefix("allow once") || label.hasPrefix("allow always") || label == "deny" {
                        result.needsApproval = true
                    }
                } else if role == kAXStaticTextRole, result.status == nil,
                          let text = (value(element, kAXValueAttribute) as? String) ?? (value(element, kAXTitleAttribute) as? String),
                          let status = statusLine(text) {
                    result.status = status
                }
                if result.isWorking && result.status != nil { return result }
                if depth < 60, let children = value(element, kAXChildrenAttribute) as? [AXUIElement] {
                    for child in children { stack.append((child, depth + 1)) }
                }
            }
            if result.isWorking || result.needsApproval { break }
        }
        return result
    }

    /// "Running a command on your computer" → kept; chat text and past steps → nil.
    ///
    /// Chat text can look like a status ("Uploading build" inside a code sample), so only
    /// plain, short, sentence-like lines count: they start with a capitalised verb, and
    /// contain no quotes or code characters.
    private static let codeCharacters = CharacterSet(charactersIn: "\"'`“”‘’$=/\\<>{}[]|_#*%")

    private static func statusLine(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...80).contains(trimmed.count), !trimmed.contains("\n"),
              trimmed.rangeOfCharacter(from: codeCharacters) == nil,
              let first = trimmed.split(separator: " ").first,
              let initial = first.first, initial.isUppercase else { return nil }
        let verb = first.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard statusVerbs.contains(verb) else { return nil }
        // Live statuses are short ("Running a command…"); longer lines are prose.
        let words = trimmed.split(separator: " ").count
        let endsWithEllipsis = trimmed.hasSuffix("…") || trimmed.hasSuffix("...")
        guard endsWithEllipsis || words <= 7 else { return nil }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "…. "))
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}
