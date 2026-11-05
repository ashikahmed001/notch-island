import AppKit
import ApplicationServices
import Combine

/// Live progress from AI coding agents (Claude Code, Copilot CLI), fed by their hooks
/// through `notch agent <name>` → POST /v1/agent.
///
/// Events: prompt (a new task), step (a tool finished), input (needs you), stop (done).
struct AgentSession: Identifiable, Equatable {
    enum State: Equatable { case working, needsInput, done }

    struct Step: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    let id: String
    let agent: String
    var project: String
    var title: String
    var steps: [Step] = []
    /// The step running right now ("Running swift build"), and since when.
    var current: String?
    var currentStarted: Date?
    var state: State = .working
    var message: String?
    /// Last reply, filled in when the agent stops (Claude: read from its transcript).
    var summary: String?
    var files = Set<String>()
    /// The app the agent runs in (Terminal, iTerm, VS Code…) — for the icon and "Open".
    var hostBundleID: String?
    var updated = Date()
    /// When this task began (the prompt): the island's clock counts the whole task.
    var started = Date()

    /// "Claude", "Copilot"…
    var displayName: String {
        switch agent.lowercased() {
        case "claude", "claude-app": return "Claude"
        case "copilot": return "Copilot"
        default: return agent.capitalized
        }
    }

    var tint: String { agent.lowercased() == "copilot" ? "blue" : "orange" }

    /// The agent's own Mac app if installed (Claude), otherwise the terminal it runs in.
    var icon: NSImage? {
        let candidates = (agent.lowercased().hasPrefix("claude") ? ["com.anthropic.claudefordesktop"] : []) + [hostBundleID].compactMap { $0 }
        for id in candidates {
            if let cached = Self.iconCache[id] { return cached }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                Self.iconCache[id] = icon
                return icon
            }
        }
        return nil
    }

    private static var iconCache: [String: NSImage] = [:]

    /// The app(s) whose window shows this agent: the Claude app for Claude app chats,
    /// otherwise the terminal / editor the hooks ran in.
    var hostBundleIDs: [String] {
        var ids: [String] = []
        if agent.lowercased() == "claude-app" { ids.append("com.anthropic.claudefordesktop") }
        if let hostBundleID, !ids.contains(hostBundleID) { ids.append(hostBundleID) }
        return ids
    }

    /// Bring the terminal / editor / Claude app running the agent to the front, with its
    /// window restored if it was minimized.
    func openHost() {
        guard let id = hostBundleIDs.first(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
                ?? hostBundleIDs.first else { return }
        HostWindow.open(bundleID: id)
    }

    /// The agent's window is what you're looking at (then the island stays quiet about it).
    var isHostInFront: Bool { HostWindow.isInFront(hostBundleIDs) }

    /// "Refactored the notch geometry · 3 files"
    var finishedLine: String? {
        let files = self.files.count
        let fileText = files > 0 ? "\(files) file\(files == 1 ? "" : "s")" : nil
        let parts = [summary.map { Self.firstSentence($0, max: 70) } ?? title, fileText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Describing steps

    /// "Edit IslandView.swift", "Run swift build", "Search notchSize"…
    static func describe(tool: String, target: String?) -> String {
        let name = tool.lowercased()
        let target = target.flatMap { IslandAPIService.clean($0, max: 70) }
        let file = target.map { ($0 as NSString).lastPathComponent }
        switch name {
        case "bash", "shell", "run", "powershell": return "Run \(target ?? "a command")"
        case "read", "view", "notebookread": return "Read \(file ?? "a file")"
        case "edit", "multiedit", "str_replace", "notebookedit": return "Edit \(file ?? "a file")"
        case "write", "create": return "Write \(file ?? "a file")"
        case "grep", "glob", "search", "find": return "Search \(target ?? "the project")"
        case "webfetch", "fetch", "web_fetch": return "Fetch \(target.flatMap { URL(string: $0)?.host } ?? "a page")"
        case "websearch", "web_search": return "Search the web"
        case "task", "agent": return "Run a subagent"
        case "todowrite": return "Update the plan"
        default: return [tool, target].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// Present tense, for the step in progress: "Running swift build", "Editing IslandView.swift".
    static func describeRunning(tool: String, target: String?) -> String {
        let name = tool.lowercased()
        let target = target.flatMap { IslandAPIService.clean($0, max: 60) }
        let file = target.map { ($0 as NSString).lastPathComponent }
        switch name {
        case "bash", "shell", "run", "powershell": return target.map { "Running \($0)" } ?? "Running a command"
        case "read", "view", "notebookread": return "Reading \(file ?? "a file")"
        case "edit", "multiedit", "str_replace", "notebookedit": return "Editing \(file ?? "a file")"
        case "write", "create": return "Writing \(file ?? "a file")"
        case "grep", "glob", "search", "find": return "Searching \(target ?? "the project")"
        case "webfetch", "fetch", "web_fetch": return "Fetching \(target.flatMap { URL(string: $0)?.host } ?? "a page")"
        case "websearch", "web_search": return "Searching the web"
        case "task", "agent": return "Running a subagent"
        case "todowrite": return "Updating the plan"
        default: return "Using \(tool)"
        }
    }

    /// "8s", "1m 05s", "1h 02m"
    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return String(format: "%dm %02ds", seconds / 60, seconds % 60) }
        return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
    }

    static func isFileChange(_ tool: String) -> Bool {
        ["edit", "multiedit", "write", "create", "str_replace", "notebookedit"].contains(tool.lowercased())
    }

    /// First sentence (or line) of a reply, markdown stripped.
    static func firstSentence(_ text: String, max: Int) -> String {
        var plain = text
        for token in ["**", "__", "`", "#"] { plain = plain.replacingOccurrences(of: token, with: "") }
        let line = plain.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        var sentence = line
        if let end = line.range(of: ". ") { sentence = String(line[..<end.lowerBound]) }
        return IslandAPIService.clean(sentence, max: max) ?? ""
    }

    enum TurnState { case running, finished, interrupted }

    /// Whether Claude Code's turn is over, from the end of its transcript — for when the
    /// "Stop" hook never comes (Esc pressed, a step cancelled or rejected).
    ///   - the last message is "[Request interrupted by user…]" → interrupted;
    ///   - the last message is Claude's reply with no tool call pending, and the transcript
    ///     has been quiet for `quietFor` seconds → finished.
    /// A long-running tool (a build) leaves a pending tool call, so it stays "running".
    static func turnState(transcript path: String, quietFor: TimeInterval = 20) -> TurnState {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let claudeFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").standardizedFileURL.path
        guard url.path.hasPrefix(claudeFolder + "/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let handle = try? FileHandle(forReadingFrom: url) else { return .running }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return .running }

        for line in text.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  let message = object["message"] as? [String: Any] else { continue }
            let content = message["content"] as? [[String: Any]] ?? []
            let texts = content.compactMap { $0["text"] as? String } + [message["content"] as? String].compactMap { $0 }
            if type == "user" {
                if texts.contains(where: { $0.contains("[Request interrupted by user") }) { return .interrupted }
                return .running   // a tool result or a new prompt: Claude is about to answer
            }
            let pendingTool = content.contains { $0["type"] as? String == "tool_use" }
            if pendingTool { return .running }
            return Date().timeIntervalSince(modified) >= quietFor ? .finished : .running
        }
        return .running
    }

    /// The last thing Claude said, from the end of its transcript (JSON lines).
    static func lastAssistantText(transcript path: String) -> String? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        // Only Claude's own transcripts.
        let claudeFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").standardizedFileURL.path
        guard url.path.hasPrefix(claudeFolder + "/"), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 512 * 1024
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"assistant\""),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if let last = texts.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return last
            }
        }
        return nil
    }
}

extension IslandAPIService {
    enum AgentEvent {
        case started(AgentSession)
        case needsInput(AgentSession)
        case finished(AgentSession)
    }
}

/// The app window something is happening in (a terminal, an editor, the Claude app).
enum HostWindow {
    /// Bring the app to the front, with its windows un-minimized.
    ///
    /// `NSRunningApplication.activate()` is ignored on macOS 14+ when the caller isn't the
    /// active app (and Notch Island never is), so open it through Launch Services instead —
    /// that always brings a running app forward.
    static func open(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            guard let app else { return }
            DispatchQueue.main.async { restoreWindows(of: app) }
        }
    }

    /// Un-minimize the app's windows and raise the first one (needs Accessibility; harmless without).
    private static func restoreWindows(of app: NSRunningApplication) {
        guard AXIsProcessTrusted() else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        var raised = false
        for window in windows {
            var minimized: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
               (minimized as? Bool) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                if !raised {
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    raised = true
                }
            }
        }
    }

    /// One of these apps is in front with a visible (not minimized) window.
    static func isInFront(_ bundleIDs: [String]) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let id = front.bundleIdentifier, bundleIDs.contains(id) else { return false }
        // In front but with its window minimized or closed → you can't see it.
        guard AXIsProcessTrusted() else { return true }
        let element = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let window = raw as! AXUIElement
        var minimized: AnyObject?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            return false
        }
        return true
    }
}
