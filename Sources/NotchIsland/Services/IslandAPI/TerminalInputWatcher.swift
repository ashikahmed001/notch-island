import AppKit
import Combine

/// Notices a terminal command that's waiting for you to type something — a password,
/// a [y/N], an `npm init` question — and says so in the island.
///
/// The zsh hook reports each command as it starts (its terminal device, e.g. /dev/ttys003,
/// the shell's process and the app it runs in). Commands still running after a few
/// seconds are checked with `ps`: a foreground process blocked reading the terminal shows
/// the wait channel "ttyin". Waiting for 3 seconds, while that terminal isn't the window
/// you're looking at → announced. It clears as soon as the command moves on or ends.
final class TerminalInputWatcher: ObservableObject {
    static let shared = TerminalInputWatcher()

    struct Waiting: Equatable, Identifiable {
        let tty: String
        let command: String
        /// The app the terminal runs in (Terminal, iTerm, VS Code…).
        let hostBundleID: String?
        var id: String { tty }

        var appName: String {
            guard let id = hostBundleID,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return "Terminal" }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }

        var icon: NSImage? {
            guard let id = hostBundleID,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    /// Commands waiting for input right now (newest first).
    @Published private(set) var waiting: [Waiting] = []
    /// Just started waiting (once per wait): the island drops a banner.
    let startedWaiting = PassthroughSubject<Waiting, Never>()

    var isEnabled = true {
        didSet { if !isEnabled { reset() } }
    }

    private struct Tracked {
        let command: String
        let shellPID: pid_t
        let hostBundleID: String?
        let started: Date
        var waitingSince: Date?
        var announced = false
    }
    private var tracked: [String: Tracked] = [:]
    private var timer: Timer?
    private var checking = false
    /// Waiting this long counts (a program may read the terminal for a moment).
    private static let waitThreshold: TimeInterval = 3
    /// Commands shorter than this are never checked.
    private static let startDelay: TimeInterval = 3

    private init() {}

    // MARK: - From the shell hook

    func commandStarted(tty: String, shellPID: pid_t, command: String, hostBundleID: String?) {
        guard isEnabled, tty.hasPrefix("/dev/tty") else { return }
        tracked[tty] = Tracked(command: command, shellPID: shellPID, hostBundleID: hostBundleID, started: Date())
        clearWaiting(tty)
        updateTimer()
    }

    // MARK: - Checking

    private func updateTimer() {
        if !tracked.isEmpty, timer == nil {
            let interval: TimeInterval = Energy.saver ? 3 : 2
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.check() }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if tracked.isEmpty, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func check() {
        guard !checking else { return }
        let now = Date()
        let due = tracked.filter { now.timeIntervalSince($0.value.started) >= Self.startDelay }
        guard !due.isEmpty else { return }
        checking = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var states: [String: ForegroundState] = [:]
            for (tty, item) in due { states[tty] = Self.foregroundState(tty: tty, shellPID: item.shellPID) }
            DispatchQueue.main.async { self?.apply(states) }
        }
    }

    private func apply(_ states: [String: ForegroundState]) {
        checking = false
        let now = Date()
        for (tty, state) in states {
            guard var item = tracked[tty] else { continue }
            switch state {
            case .finished:
                tracked[tty] = nil
                clearWaiting(tty)
                continue
            case .running:
                item.waitingSince = nil
                item.announced = false
                clearWaiting(tty)
            case .waitingForInput:
                if item.waitingSince == nil { item.waitingSince = now }
                let long = now.timeIntervalSince(item.waitingSince ?? now) >= Self.waitThreshold
                let ids = [item.hostBundleID].compactMap { $0 }
                let visible = !ids.isEmpty && HostWindow.isInFront(ids)
                if long && !visible {
                    let entry = Waiting(tty: tty, command: item.command, hostBundleID: item.hostBundleID)
                    if !waiting.contains(where: { $0.tty == tty }) { waiting.insert(entry, at: 0) }
                    if !item.announced {
                        item.announced = true
                        Log.api.notice("command waiting for input: \(item.command, privacy: .public)")
                        startedWaiting.send(entry)
                    }
                } else if visible {
                    // You're looking at it: no need for the island.
                    clearWaiting(tty)
                }
            }
            tracked[tty] = item
        }
        updateTimer()
    }

    private func clearWaiting(_ tty: String) {
        if waiting.contains(where: { $0.tty == tty }) { waiting.removeAll { $0.tty == tty } }
    }

    private func reset() {
        tracked.removeAll()
        waiting.removeAll()
        updateTimer()
    }

    // MARK: - Reading the terminal's foreground job

    enum ForegroundState { case running, waitingForInput, finished }

    /// `ps -t ttys003 -o pid=,pgid=,tpgid=,wchan=`: the foreground job is the processes whose
    /// group is the terminal's foreground group. Back at the shell → finished.
    static func foregroundState(tty: String, shellPID: pid_t) -> ForegroundState {
        let device = tty.replacingOccurrences(of: "/dev/", with: "")
        guard let output = SystemProgressService.run("/bin/ps", ["-t", device, "-o", "pid=,pgid=,tpgid=,wchan="], timeout: 3) else {
            return .running
        }
        var foreground: [(pid: pid_t, wchan: String)] = []
        var anyProcess = false
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = pid_t(fields[0]), let pgid = pid_t(fields[1]), let tpgid = pid_t(fields[2]) else { continue }
            anyProcess = true
            if pgid == tpgid {
                foreground.append((pid, fields.count > 3 ? String(fields[3]) : ""))
            }
        }
        // Terminal closed, or the shell itself is in front again (the command ended).
        guard anyProcess, !foreground.isEmpty, !foreground.contains(where: { $0.pid == shellPID }) else { return .finished }
        return foreground.contains { $0.wchan.hasPrefix("ttyin") || $0.wchan.hasPrefix("ttyrd") } ? .waitingForInput : .running
    }

    // MARK: - Going there

    /// Brings the terminal forward — in Terminal and iTerm, the exact tab that's waiting.
    func open(_ item: Waiting) {
        let tty = item.tty
        let script: String?
        switch item.hostBundleID {
        case "com.apple.Terminal":
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            set miniaturized of w to false
                        end if
                    end repeat
                end repeat
                activate
            end tell
            """
        case "com.googlecode.iterm2":
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                            end if
                        end repeat
                    end repeat
                end repeat
                activate
            end tell
            """
        default:
            script = nil
        }
        if let script {
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&error)
                if let error { Log.api.notice("couldn't select the terminal tab: \(error.description, privacy: .public)") }
            }
        }
        if let id = item.hostBundleID { HostWindow.open(bundleID: id) }
    }
}
