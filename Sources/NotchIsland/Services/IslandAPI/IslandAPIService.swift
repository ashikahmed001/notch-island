import AppKit
import Combine

/// The Island API: lets scripts, the `notch` command, the shell hook and Shortcuts
/// show alerts and progress on the island.
///
///   POST /v1/show               title, subtitle?, icon?, color?, duration?
///   POST /v1/progress           id, title, value (0.4 | 40 | 40%), icon?, color?
///   POST /v1/done               id, title?, icon?, color?
///   POST /v1/clear
///   POST /v1/command-finished   cmd, seconds, exit, dir      (from the shell hook)
///   POST /v1/agent              agent, event, session, cwd, prompt?, tool?, target?, message?, transcript?, host?
///                               (from Claude Code / Copilot hooks via `notch agent`)
///   GET  /v1/ping               no auth — "is the app running?"
///
/// Every request except ping needs `Authorization: Bearer <~/.notchisland/token>`.
final class IslandAPIService: ObservableObject {
    struct Alert: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String?
        /// Short text for the right side of the notch, e.g. "1m 12s".
        let badge: String?
        let icon: String
        let color: String
        let duration: TimeInterval
        /// Set for alerts shown as a full drop-down banner (a finished terminal command):
        /// small line above the title, and a word on the right ("Done", "Failed").
        var caption: String? = nil
        var status: String? = nil
        var succeeded = false

        /// Fits beside the camera with no drop-down row.
        var isCompact: Bool { subtitle == nil && badge == nil && title.count <= 18 }
    }

    struct ProgressActivity: Equatable {
        let id: String
        var title: String
        /// nil = indeterminate.
        var value: Double?
        var icon: String
        var color: String
        var updated: Date
    }

    // MARK: - Published state

    /// The most recently updated progress activity (shown in the collapsed island).
    @Published private(set) var progress: ProgressActivity?
    @Published private(set) var isListening = false
    @Published private(set) var serverError: String?

    /// Fires for every alert to show.
    let alerts = PassthroughSubject<Alert, Never>()

    /// AI agents at work, most recent first (at most 3).
    @Published private(set) var agentSessions: [AgentSession] = []
    let agentEvents = PassthroughSubject<AgentEvent, Never>()

    // MARK: - Feature flags

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                server.start()
            } else {
                server.stop()
                activities.removeAll()
                publishProgress()
            }
        }
    }
    var terminalAlertsEnabled = true
    var onlyWhenTerminalInBackground = false

    // MARK: - Private

    private lazy var server: IslandAPIServer = {
        let server = IslandAPIServer { [weak self] request in
            self?.handle(request) ?? .error(503, "unavailable")
        }
        server.onStateChange = { [weak self] listening, error in
            self?.isListening = listening
            self?.serverError = error
        }
        return server
    }()
    private var activities: [String: ProgressActivity] = [:]
    private var recentRequests: [Date] = []
    private var sweepTimer: Timer?

    static let colors = ["green", "red", "blue", "orange", "yellow", "pink", "purple", "cyan", "teal", "indigo", "mint", "gray", "white"]
    private static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "io.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview",
        "com.google.android.studio",
    ]
    /// IntelliJ, PyCharm, WebStorm, GoLand, Rider, CLion… all have a built-in terminal.
    private static let terminalAppPrefixes = ["com.jetbrains."]

    private static func isTerminal(_ bundleID: String) -> Bool {
        terminalApps.contains(bundleID) || terminalAppPrefixes.contains { bundleID.hasPrefix($0) }
    }

    init() {
        // Forget progress activities that stopped updating 10 minutes ago.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.sweep() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    deinit { sweepTimer?.invalidate() }

    // MARK: - Routing (main thread)

    private func handle(_ request: IslandAPIServer.Request) -> IslandAPIServer.Response {
        // Browsers always send Origin; scripts don't. Refusing it stops web pages from
        // poking the island, even via DNS-rebinding tricks.
        if request.headers["origin"] != nil {
            return .error(403, "browser requests are not allowed")
        }
        if let host = request.headers["host"], !(host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost")) {
            return .error(403, "unexpected host")
        }
        if request.path == "/v1/ping" {
            return .ok(["app": "Notch Island", "version": 1])
        }
        guard request.headers["authorization"] == "Bearer \(APIFiles.token)" else {
            Log.api.error("\(request.path, privacy: .public) rejected — missing or wrong token")
            return .error(401, "missing or wrong token (see ~/.notchisland/token)")
        }
        guard request.method == "POST" else {
            return .error(405, "use POST")
        }

        // At most 10 requests a second, so a runaway loop can't flood the island.
        let now = Date()
        recentRequests = recentRequests.filter { now.timeIntervalSince($0) < 1 }
        guard recentRequests.count < 10 else { return .error(429, "slow down") }
        recentRequests.append(now)

        let params = IslandAPIServer.parameters(of: request)
        switch request.path {
        case "/v1/show": return show(params)
        case "/v1/progress": return updateProgress(params)
        case "/v1/done": return finish(params)
        case "/v1/clear":
            activities.removeAll()
            publishProgress()
            return .ok()
        case "/v1/command-finished": return commandFinished(params)
        case "/v1/command-started":
            if let tty = params["tty"], let shell = pid_t(params["shell"] ?? "") {
                TerminalInputWatcher.shared.commandStarted(tty: tty, shellPID: shell,
                                                           command: Self.clean(params["cmd"], max: 60) ?? "A command",
                                                           hostBundleID: Self.clean(params["host"], max: 80))
            }
            return .ok()
        case "/v1/agent": return agentEvent(params)
        default: return .error(404, "unknown endpoint \(request.path)")
        }
    }

    private func show(_ p: [String: String]) -> IslandAPIServer.Response {
        guard let title = Self.clean(p["title"], max: 80) else { return .error(400, "title is required") }
        let duration = min(max(Double(p["duration"] ?? "") ?? 3.5, 1), 15)
        alerts.send(Alert(
            title: title,
            subtitle: Self.clean(p["subtitle"], max: 80),
            badge: Self.clean(p["badge"], max: 16),
            icon: Self.symbol(p["icon"], fallback: "bell.fill"),
            color: Self.color(p["color"], fallback: "teal"),
            duration: duration
        ))
        return .ok()
    }

    private func updateProgress(_ p: [String: String]) -> IslandAPIServer.Response {
        guard let id = Self.clean(p["id"], max: 40) else { return .error(400, "id is required") }
        let existing = activities[id]
        guard let title = Self.clean(p["title"], max: 60) ?? existing?.title else { return .error(400, "title is required") }
        let value = Self.fraction(p["value"])
        activities[id] = ProgressActivity(
            id: id,
            title: title,
            value: value ?? existing?.value,
            icon: Self.symbol(p["icon"], fallback: existing?.icon ?? "arrow.triangle.2.circlepath"),
            color: Self.color(p["color"], fallback: existing?.color ?? "teal"),
            updated: Date()
        )
        publishProgress()
        return .ok()
    }

    private func finish(_ p: [String: String]) -> IslandAPIServer.Response {
        guard let id = Self.clean(p["id"], max: 40) else { return .error(400, "id is required") }
        let existing = activities.removeValue(forKey: id)
        publishProgress()
        let title = Self.clean(p["title"], max: 80) ?? existing?.title ?? "Done"
        alerts.send(Alert(
            title: title,
            subtitle: Self.clean(p["subtitle"], max: 80),
            badge: "Done",
            icon: Self.symbol(p["icon"], fallback: "checkmark.circle.fill"),
            color: Self.color(p["color"], fallback: "green"),
            duration: 3.5
        ))
        return .ok()
    }

    /// From the shell hook: ✓ "npm install · 1m 12s" or ✗ "swift build · exit 1".
    private func commandFinished(_ p: [String: String]) -> IslandAPIServer.Response {
        guard terminalAlertsEnabled else { return .ok(["ignored": "terminal alerts are off"]) }
        if onlyWhenTerminalInBackground,
           let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Self.isTerminal(front) {
            return .ok(["ignored": "terminal is in front"])
        }
        let command = Self.clean(p["cmd"], max: 60) ?? "Command"
        let seconds = Int(Double(p["seconds"] ?? "") ?? 0)
        let exit = Int(p["exit"] ?? "") ?? 0
        let folder = Self.clean(p["dir"], max: 30)
        let took = Self.formatDuration(seconds)

        // "Command finished · 2m 14s · my-app" above the command; "Done" / "Failed" on the right.
        func caption(_ what: String, _ extra: String? = nil) -> String {
            [what, extra, took, folder].compactMap { $0 }.joined(separator: " · ")
        }
        let alert: Alert
        switch exit {
        case 0:
            alert = Alert(title: command, subtitle: nil, badge: took, icon: "checkmark", color: "green", duration: 4,
                          caption: caption(String(localized: "Command finished")),
                          status: String(localized: "Done"), succeeded: true)
        case 130, 137, 143:
            alert = Alert(title: command, subtitle: nil, badge: took, icon: "stop.fill", color: "orange", duration: 5,
                          caption: caption(String(localized: "Command stopped")),
                          status: String(localized: "Stopped"))
        default:
            alert = Alert(title: command, subtitle: nil, badge: took, icon: "xmark", color: "red", duration: 6,
                          caption: caption(String(localized: "Command failed"), "exit \(exit)"),
                          status: String(localized: "Failed"))
        }
        alerts.send(alert)
        return .ok()
    }

    // MARK: - Agents

    /// For agents watched from inside the app (the Claude desktop app).
    func ingestAgentEvent(_ params: [String: String]) {
        _ = agentEvent(params)
    }

    private func agentEvent(_ p: [String: String]) -> IslandAPIServer.Response {
        let agent = Self.clean(p["agent"], max: 20) ?? "agent"
        let folder = p["cwd"].map { ($0 as NSString).lastPathComponent } ?? ""
        // Copilot has no session id: one session per agent + folder.
        let id = Self.clean(p["session"], max: 80) ?? "\(agent)|\(folder)"
        let event = (p["event"] ?? "").lowercased()
        if let transcript = p["transcript"], !transcript.isEmpty { transcripts[id] = transcript }
        let host = Self.clean(p["host"], max: 80)
        Log.api.notice("agent \(agent, privacy: .public): \(event.isEmpty ? "(no event)" : event, privacy: .public) \(p["tool"] ?? "", privacy: .public) in \(folder, privacy: .public)")

        var session = agentSessions.first { $0.id == id }
            ?? AgentSession(id: id, agent: agent, project: folder, title: "Working…")
        if let host { session.hostBundleID = host }
        if !folder.isEmpty { session.project = folder }
        session.updated = Date()

        switch event {
        case "userpromptsubmit", "userpromptsubmitted", "prompt":
            session = AgentSession(id: id, agent: agent, project: session.project,
                                   title: Self.clean(p["prompt"], max: 60) ?? "New task",
                                   hostBundleID: session.hostBundleID)
            store(session)
            agentEvents.send(.started(session))

        case "pretooluse", "start":
            // A step started: show it live with a ticking timer.
            guard let tool = Self.clean(p["tool"], max: 40) else { return .ok() }
            let isNew = !agentSessions.contains { $0.id == id } || session.state == .done
            if session.state == .done {
                session = AgentSession(id: id, agent: agent, project: session.project, title: "Working…",
                                       hostBundleID: session.hostBundleID)
            }
            session.state = .working
            session.current = AgentSession.describeRunning(tool: tool, target: p["target"])
            session.currentStarted = Date()
            store(session)
            if isNew { agentEvents.send(.started(session)) }

        case "posttooluse", "step":
            guard let tool = Self.clean(p["tool"], max: 40) else { return .ok() }
            session.current = nil
            session.currentStarted = nil
            let isNew = !agentSessions.contains { $0.id == id } || session.state == .done
            if session.state == .done {   // a new turn without a prompt event
                session = AgentSession(id: id, agent: agent, project: session.project, title: "Working…",
                                       hostBundleID: session.hostBundleID)
            }
            session.state = .working
            session.steps.append(.init(text: AgentSession.describe(tool: tool, target: p["target"])))
            if session.steps.count > 30 { session.steps.removeFirst(session.steps.count - 30) }
            if AgentSession.isFileChange(tool), let target = p["target"], !target.isEmpty {
                session.files.insert(target)
            }
            store(session)
            if isNew { agentEvents.send(.started(session)) }

        case "status":
            // A status line read from an app ("Running a command on your computer").
            guard let text = Self.clean(p["message"], max: 80) else { return .ok() }
            let isNew = !agentSessions.contains { $0.id == id } || session.state == .done
            if session.state == .done {
                session = AgentSession(id: id, agent: agent, project: session.project, title: "Working…",
                                       hostBundleID: session.hostBundleID)
            }
            if let current = session.current, current != text {
                session.steps.append(.init(text: current))
                if session.steps.count > 30 { session.steps.removeFirst(session.steps.count - 30) }
            }
            session.state = .working
            if session.current != text {
                session.current = text
                session.currentStarted = Date()
            }
            store(session)
            if isNew { agentEvents.send(.started(session)) }

        case "notification", "input":
            session.current = nil
            session.currentStarted = nil
            session.state = .needsInput
            session.message = Self.clean(p["message"], max: 90)
            store(session)
            agentEvents.send(.needsInput(session))

        case "stop", "agentstop", "sessionend", "done":
            if let current = session.current { session.steps.append(.init(text: current)) }
            session.current = nil
            session.currentStarted = nil
            session.state = .done
            store(session)
            if let transcript = p["transcript"], !transcript.isEmpty {
                // Reading the transcript can take a moment — off the main thread.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let summary = AgentSession.lastAssistantText(transcript: transcript)
                    DispatchQueue.main.async {
                        guard let self, var current = self.agentSessions.first(where: { $0.id == id }) else { return }
                        current.summary = summary
                        self.store(current)
                        self.agentEvents.send(.finished(current))
                    }
                }
            } else {
                agentEvents.send(.finished(session))
            }

        default:
            Log.api.error("agent event not understood: '\(event, privacy: .public)'")
            return .error(400, "unknown agent event \(event)")
        }
        return .ok()
    }

    private func store(_ session: AgentSession) {
        var list = agentSessions.filter { $0.id != session.id }
        list.insert(session, at: 0)
        if list.count > 3 { list.removeLast(list.count - 3) }
        agentSessions = list
        updateLivenessChecks()
    }

    // MARK: - Agents that never said "done"

    /// Transcript file per session (Claude Code sends it with every hook).
    private var transcripts: [String: String] = [:]
    private var livenessTimer: Timer?
    private var checkingLiveness = false

    /// While a task looks active, check every 5 s whether it really still is.
    private func updateLivenessChecks() {
        let active = agentSessions.contains { $0.state != .done }
        if active, livenessTimer == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.checkLiveness() }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            livenessTimer = timer
        } else if !active, let timer = livenessTimer {
            timer.invalidate()
            livenessTimer = nil
        }
    }

    private func checkLiveness() {
        guard !checkingLiveness else { return }
        let now = Date()
        // No transcript to check (Copilot, the Claude app) and nothing heard for 15 minutes:
        // it's not running any more. (Claude Code's transcript shows a long build is still going.)
        for session in agentSessions where session.state != .done && transcripts[session.id] == nil
            && now.timeIntervalSince(session.updated) > 15 * 60 {
            Log.api.notice("agent \(session.agent, privacy: .public): no news for 15 min — ending its activity")
            endQuietly(session.id)
        }
        let candidates = agentSessions.filter { $0.state != .done }.compactMap { session in
            transcripts[session.id].map { (session.id, $0) }
        }
        guard !candidates.isEmpty else { return }
        checkingLiveness = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let results = candidates.map { ($0.0, AgentSession.turnState(transcript: $0.1)) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingLiveness = false
                for (id, state) in results {
                    switch state {
                    case .running:
                        continue
                    case .interrupted:
                        Log.api.notice("agent session interrupted (no Stop hook) — ending its activity")
                        self.endQuietly(id)
                    case .finished:
                        Log.api.notice("agent session finished without a Stop hook — finishing it")
                        _ = self.agentEvent(["event": "stop", "session": id,
                                             "agent": self.agentSessions.first { $0.id == id }?.agent ?? "claude",
                                             "transcript": self.transcripts[id] ?? ""])
                    }
                }
            }
        }
    }

    /// Mark a session done without a "finished" banner (it was stopped, not completed).
    private func endQuietly(_ id: String) {
        guard var session = agentSessions.first(where: { $0.id == id }), session.state != .done else { return }
        session.current = nil
        session.currentStarted = nil
        session.state = .done
        store(session)
    }

    // MARK: - Helpers

    private func publishProgress() {
        let latest = activities.values.max { $0.updated < $1.updated }
        if latest != progress { progress = latest }
    }

    private func sweep() {
        let cutoff = Date().addingTimeInterval(-600)
        // Finished agent sessions fade out after 10 minutes, stalled ones after 30.
        let agents = agentSessions.filter {
            $0.updated > ($0.state == .done ? cutoff : Date().addingTimeInterval(-1800))
        }
        if agents.count != agentSessions.count { agentSessions = agents }
        let before = activities.count
        activities = activities.filter { $0.value.updated > cutoff }
        if activities.count != before { publishProgress() }
    }

    /// Trimmed, single-line, length-capped; nil if empty.
    static func clean(_ text: String?, max: Int) -> String? {
        guard let text else { return nil }
        let single = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !single.isEmpty else { return nil }
        return single.count > max ? String(single.prefix(max - 1)) + "…" : single
    }

    /// Only real SF Symbols are allowed.
    static func symbol(_ name: String?, fallback: String) -> String {
        guard let name = clean(name, max: 60), NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
            return fallback
        }
        return name
    }

    static func color(_ name: String?, fallback: String) -> String {
        guard let name = name?.lowercased(), colors.contains(name) else { return fallback }
        return name
    }

    /// "0.4", "40" or "40%" → 0.4
    static func fraction(_ text: String?) -> Double? {
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let percent = text.hasSuffix("%")
        if percent { text.removeLast() }
        guard let number = Double(text) else { return nil }
        let value = (percent || number > 1) ? number / 100 : number
        return min(max(value, 0), 1)
    }

    static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
