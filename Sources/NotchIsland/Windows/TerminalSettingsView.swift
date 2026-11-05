import AppKit
import SwiftUI

/// Settings ▸ Terminal: Island API status, shell hook, AI agents, examples.
struct TerminalSettingsView: View {
    @ObservedObject var api: IslandAPIService
    @ObservedObject var settings: TerminalSettings
    @ObservedObject var flags: FeatureFlags

    private let example = #"notch "Hello from Terminal" --icon hand.wave --color pink"#
    private let shortcutCommand = #"~/.notchisland/bin/notch "Leaving home" --icon house --color blue"#

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { flags.storedValue(.islandAPI) }, set: { flags.set(.islandAPI, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Feature.islandAPI.title).font(.system(size: 13, weight: .semibold))
                        if let subtitle = Feature.islandAPI.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle(Feature.terminalAlerts.title, isOn: Binding(
                    get: { flags.storedValue(.terminalAlerts) }, set: { flags.set(.terminalAlerts, $0) }))
                    .disabled(!flags.isOn(.islandAPI))
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(Feature.terminalInputAlerts.title, isOn: Binding(
                        get: { flags.storedValue(.terminalInputAlerts) }, set: { flags.set(.terminalInputAlerts, $0) }))
                    if let subtitle = Feature.terminalInputAlerts.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!flags.isOn(.islandAPI))
            }
            Section("Island API") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(api.isListening ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .foregroundStyle(api.serverError == nil ? Color.primary : Color.red)
                }
                HStack {
                    Button("Copy token") { settings.copy(APIFiles.token, note: "Token copied.") }
                    Button("New token") { settings.regenerateToken() }
                    Spacer()
                    Button("Copy curl example") {
                        settings.copy(
                            #"curl -s localhost:47290/v1/show -H "Authorization: Bearer $(cat ~/.notchisland/token)" -d title="Hello from curl" -d icon=sparkles"#,
                            note: "curl example copied.")
                    }
                }
            }

            Section("Long-running commands") {
                row(title: "Shell hook (zsh)",
                    detail: settings.shellHookInstalled ? "Installed in ~/.zshrc" : "Alerts when a slow command finishes",
                    connected: settings.shellHookInstalled,
                    action: settings.toggleShellHook)
                Picker("Notify after", selection: $settings.minSeconds) {
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                }
                Toggle("Show the command text", isOn: $settings.showCommand)
                Toggle(Feature.terminalOnlyInBackground.title, isOn: Binding(
                    get: { flags.storedValue(.terminalOnlyInBackground) },
                    set: { flags.set(.terminalOnlyInBackground, $0) }))
                TextField("Ignore", text: $settings.ignore)
                    .font(.system(.body, design: .monospaced))
            }

            Section("AI agents") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(Feature.claudeAppActivity.title, isOn: Binding(
                        get: { flags.storedValue(.claudeAppActivity) }, set: { flags.set(.claudeAppActivity, $0) }))
                    if let subtitle = Feature.claudeAppActivity.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    if flags.isOn(.claudeAppActivity) {
                        ClaudeAppStatusRow(status: ClaudeAppStatus.shared)
                            .padding(.top, 4)
                    }
                }
                .disabled(!flags.isOn(.islandAPI))
                row(title: "Claude Code",
                    detail: "When Claude finishes, or needs your input",
                    connected: settings.claudeConnected,
                    action: settings.toggleClaude)
                row(title: "GitHub Copilot CLI",
                    detail: "When Copilot finishes responding",
                    connected: settings.copilotConnected,
                    action: settings.toggleCopilot)
            }

            Section("Try it") {
                codeRow(example, note: "Command copied. Paste it into Terminal.")
                Text("In the Shortcuts app, add a **Run Shell Script** action with:")
                    .font(.callout)
                codeRow(shortcutCommand, note: "Shortcuts command copied.")
            }

            if let message = settings.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { settings.refreshStatus() }
    }

    private var statusText: String {
        if let error = api.serverError { return error }
        if api.isListening { return "Listening on 127.0.0.1:\(IslandAPIServer.port)" }
        return flags.isOn(.islandAPI) ? "Starting…" : "Off. Turn on Terminal & Island API in Features."
    }

    private func row(title: String, detail: String, connected: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if connected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .font(.callout)
            }
            Button(connected ? "Disconnect" : "Connect", action: action)
        }
    }

    private func codeRow(_ code: String, note: String) -> some View {
        HStack {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer()
            Button("Copy") { settings.copy(code, note: note) }
        }
    }
}

/// What the Claude app watcher can see, with a fix when it can't.
struct ClaudeAppStatusRow: View {
    @ObservedObject var status: ClaudeAppStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(message).font(.caption)
            }
            if status.state == .needsAccessibility {
                Text("Turn on Notch Island in Privacy & Security ▸ Accessibility. If it's already on, remove it with − and add it again: rebuilding the app resets the permission.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var message: String {
        switch status.state {
        case .off: return String(localized: "Not running")
        case .starting: return String(localized: "Starting…")
        case .needsAccessibility: return String(localized: "Needs Accessibility permission")
        case .claudeNotRunning: return String(localized: "Waiting for the Claude app to open")
        case .noWindow: return String(localized: "Claude is open, but its window can't be read yet")
        case .watching: return String(localized: "Watching the Claude app")
        case .working: return status.lastStatus.map { String(localized: "Claude is working: \($0)") } ?? String(localized: "Claude is working")
        case .waitingForYou: return String(localized: "Claude is waiting for you")
        case .slow: return String(localized: "The Claude app isn't responding, retrying")
        }
    }

    private var color: Color {
        switch status.state {
        case .watching, .working, .waitingForYou: return .green
        case .starting, .claudeNotRunning, .noWindow, .slow: return .orange
        case .needsAccessibility: return .red
        case .off: return .gray
        }
    }
}
