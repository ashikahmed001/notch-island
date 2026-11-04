import AppKit
import Combine

/// Settings ▸ Terminal: hook options plus the connect / disconnect actions.
final class TerminalSettings: ObservableObject {
    struct Values {
        var minSeconds: Int
        var showCommand: Bool
        var ignore: String
    }

    static let defaultIgnore = "vim nvim vi nano emacs less more man top htop btop ssh tmux screen watch tail claude copilot"

    @Published var minSeconds: Int { didSet { save() } }
    @Published var showCommand: Bool { didSet { save() } }
    @Published var ignore: String { didSet { save() } }

    @Published private(set) var shellHookInstalled = APIFiles.isShellHookInstalled
    @Published private(set) var claudeConnected = APIFiles.isClaudeConnected
    @Published private(set) var copilotConnected = APIFiles.isCopilotConnected
    /// Short confirmation or error shown under the buttons.
    @Published private(set) var message: String?

    private let defaults = UserDefaults.standard

    var values: Values { Values(minSeconds: minSeconds, showCommand: showCommand, ignore: ignore) }

    init() {
        let saved = defaults.integer(forKey: "terminal.minSeconds")
        minSeconds = saved > 0 ? saved : 30
        showCommand = defaults.object(forKey: "terminal.showCommand") as? Bool ?? true
        ignore = defaults.string(forKey: "terminal.ignore") ?? Self.defaultIgnore
    }

    private func save() {
        defaults.set(minSeconds, forKey: "terminal.minSeconds")
        defaults.set(showCommand, forKey: "terminal.showCommand")
        defaults.set(ignore, forKey: "terminal.ignore")
        APIFiles.writeConfig(values)
    }

    func refreshStatus() {
        shellHookInstalled = APIFiles.isShellHookInstalled
        claudeConnected = APIFiles.isClaudeConnected
        copilotConnected = APIFiles.isCopilotConnected
    }

    // MARK: - Actions

    func toggleShellHook() {
        run(shellHookInstalled ? "Removed from ~/.zshrc. Open a new terminal tab."
                               : "Added to ~/.zshrc. Open a new terminal tab to start.") {
            if APIFiles.isShellHookInstalled { try APIFiles.uninstallShellHook() } else { try APIFiles.installShellHook() }
        }
    }

    func toggleClaude() {
        run(claudeConnected ? "Claude Code disconnected." : "Connected. Restart any running Claude Code sessions.") {
            if APIFiles.isClaudeConnected { try APIFiles.disconnectClaude() } else { try APIFiles.connectClaude() }
        }
    }

    func toggleCopilot() {
        run(copilotConnected ? "Copilot CLI disconnected." : "Connected. Restart any running Copilot CLI sessions.") {
            if APIFiles.isCopilotConnected { try APIFiles.disconnectCopilot() } else { try APIFiles.connectCopilot() }
        }
    }

    func copy(_ text: String, note: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = note
    }

    func regenerateToken() {
        APIFiles.regenerateToken()
        message = "New token created. Scripts using the old one will stop working."
    }

    private func run(_ success: String, _ action: () throws -> Void) {
        do {
            try action()
            message = success
        } catch {
            message = "Couldn't update: \(error.localizedDescription)"
        }
        refreshStatus()
    }
}
