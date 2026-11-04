import Foundation
import Security

/// Everything the Island API keeps on disk, in ~/.notchisland/:
///
///   token          secret for API requests (readable only by you)
///   bin/notch      the `notch` command
///   hook.zsh       the shell hook (long-command alerts)
///   config.zsh     the hook's settings, rewritten when you change them in Settings
///
/// It also connects / disconnects ~/.zshrc, Claude Code and Copilot CLI.
enum APIFiles {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let folder = home.appendingPathComponent(".notchisland", isDirectory: true)
    static let binFolder = folder.appendingPathComponent("bin", isDirectory: true)
    static let tokenFile = folder.appendingPathComponent("token")
    static let cliFile = binFolder.appendingPathComponent("notch")
    static let hookFile = folder.appendingPathComponent("hook.zsh")
    static let agentScriptFile = folder.appendingPathComponent("agent.js")
    static let configFile = folder.appendingPathComponent("config.zsh")
    static let zshrc = home.appendingPathComponent(".zshrc")
    static let claudeSettings = home.appendingPathComponent(".claude/settings.json")
    static let copilotHooks = home.appendingPathComponent(".copilot/hooks/notch-island.json")

    /// The command other tools use, with a path that works even without PATH set up.
    static let notchCommand = "~/.notchisland/bin/notch"

    // MARK: - Token

    private static var cachedToken: String?

    static var token: String {
        if let cachedToken { return cachedToken }
        if let saved = try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           saved.count >= 32 {
            cachedToken = saved
            return saved
        }
        return regenerateToken()
    }

    @discardableResult
    static func regenerateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        ensureFolders()
        write(token + "\n", to: tokenFile, permissions: 0o600)
        cachedToken = token
        return token
    }

    // MARK: - Support files (rewritten on every launch, so updates reach them)

    static func writeSupportFiles(settings: TerminalSettings.Values) {
        ensureFolders()
        _ = token
        write(cliScript, to: cliFile, permissions: 0o755)
        write(hookScript, to: hookFile, permissions: 0o644)
        write(agentScript, to: agentScriptFile, permissions: 0o644)
        writeConfig(settings)
    }

    static func writeConfig(_ settings: TerminalSettings.Values) {
        ensureFolders()
        let ignore = settings.ignore
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map { String($0).replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
            .map { "'\($0)'" }
            .joined(separator: " ")
        let config = """
        # Written by Notch Island ▸ Settings ▸ Terminal. Changes here are overwritten.
        NOTCH_MIN_SECONDS=\(settings.minSeconds)
        NOTCH_SHOW_COMMAND=\(settings.showCommand ? 1 : 0)
        NOTCH_IGNORE=(\(ignore))

        """
        write(config, to: configFile, permissions: 0o644)
    }

    // MARK: - ~/.zshrc

    static let zshrcLine = "[ -f ~/.notchisland/hook.zsh ] && source ~/.notchisland/hook.zsh  # Notch Island"

    static var isShellHookInstalled: Bool {
        ((try? String(contentsOf: zshrc, encoding: .utf8)) ?? "").contains(".notchisland/hook.zsh")
    }

    static func installShellHook() throws {
        var text = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        guard !text.contains(".notchisland/hook.zsh") else { return }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\n" + zshrcLine + "\n"
        try text.write(to: zshrc, atomically: true, encoding: .utf8)
    }

    static func uninstallShellHook() throws {
        guard let text = try? String(contentsOf: zshrc, encoding: .utf8) else { return }
        let kept = text.components(separatedBy: "\n").filter { !$0.contains(".notchisland/hook.zsh") }
        try kept.joined(separator: "\n").write(to: zshrc, atomically: true, encoding: .utf8)
    }

    // MARK: - Claude Code (~/.claude/settings.json hooks)

    /// The prompt, every finished tool step, "needs you" and "done" — the island shows
    /// live progress and a summary at the end.
    private static let claudeHooks: [(event: String, command: String)] = [
        ("UserPromptSubmit", "\(notchCommand) agent claude"),
        ("PreToolUse", "\(notchCommand) agent claude"),
        ("PostToolUse", "\(notchCommand) agent claude"),
        ("Notification", "\(notchCommand) agent claude"),
        ("Stop", "\(notchCommand) agent claude"),
    ]

    /// Hooks written by an older version → rewrite them (called at launch).
    static func upgradeAgentHooks() {
        let claudeText = (try? String(contentsOf: claudeSettings, encoding: .utf8)) ?? ""
        if isClaudeConnected, !(claudeText.contains("notch agent claude") && claudeText.contains("PreToolUse")) {
            try? disconnectClaude()
            try? connectClaude()
        }
        if isCopilotConnected,
           !((try? String(contentsOf: copilotHooks, encoding: .utf8)) ?? "").contains("agent copilot start") {
            try? connectCopilot()
        }
    }

    static var isClaudeConnected: Bool {
        ((try? String(contentsOf: claudeSettings, encoding: .utf8)) ?? "").contains(".notchisland/bin/notch")
    }

    static func connectClaude() throws {
        var root = try readJSON(claudeSettings)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, command) in claudeHooks {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let already = groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(".notchisland/bin/notch") == true }
            }
            if !already {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
                if event.hasSuffix("ToolUse") { group["matcher"] = "*" }   // every tool
                groups.append(group)
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try backup(claudeSettings)
        try writeJSON(root, to: claudeSettings)
    }

    static func disconnectClaude() throws {
        var root = try readJSON(claudeSettings)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { group in
                !(group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(".notchisland/bin/notch") == true }
            }
            if kept.isEmpty { hooks[event] = nil } else { hooks[event] = kept }
        }
        if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        try backup(claudeSettings)
        try writeJSON(root, to: claudeSettings)
    }

    // MARK: - GitHub Copilot CLI (~/.copilot/hooks/notch-island.json)

    static var isCopilotConnected: Bool {
        FileManager.default.fileExists(atPath: copilotHooks.path)
    }

    static func connectCopilot() throws {
        func hook(_ event: String) -> [[String: Any]] {
            [["type": "command", "bash": "\(notchCommand) agent copilot \(event)", "timeoutSec": 5]]
        }
        let file: [String: Any] = [
            "version": 1,
            "hooks": [
                "userPromptSubmitted": hook("prompt"),
                "preToolUse": hook("start"),
                "postToolUse": hook("step"),
                "agentStop": hook("stop"),
            ],
        ]
        try FileManager.default.createDirectory(at: copilotHooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeJSON(file, to: copilotHooks)
    }

    static func disconnectCopilot() throws {
        if isCopilotConnected { try FileManager.default.removeItem(at: copilotHooks) }
    }

    // MARK: - File helpers

    private static func ensureFolders() {
        try? FileManager.default.createDirectory(at: binFolder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    private static func write(_ text: String, to url: URL, permissions: Int) {
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: permissions])
        try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// One-time safety copy before we first touch someone else's settings file.
    private static func backup(_ url: URL) throws {
        let copy = url.appendingPathExtension("before-notch-island")
        guard FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: copy.path) else { return }
        try FileManager.default.copyItem(at: url, to: copy)
    }
}
