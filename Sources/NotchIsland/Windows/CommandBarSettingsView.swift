import SwiftUI

extension Notification.Name {
    static let commandBarShortcutChanged = Notification.Name("NotchIsland.commandBarShortcutChanged")
}

/// The chosen Command Bar shortcut, for Settings.
final class CommandBarShortcut: ObservableObject {
    static let shared = CommandBarShortcut()

    @Published var preset: HotKey.Preset = HotKey.Preset.saved {
        didSet {
            guard preset != oldValue else { return }
            HotKey.Preset.saved = preset
            NotificationCenter.default.post(name: .commandBarShortcutChanged, object: nil)
        }
    }
}

/// Settings ▸ Command Bar: switch, shortcut, and what you can type.
struct CommandBarSettingsView: View {
    @ObservedObject var flags: FeatureFlags
    @ObservedObject var shortcut: CommandBarShortcut

    var body: some View {
        Form {
            Section {
                Toggle(isOn: flagBinding(flags, .commandBar)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Feature.commandBar.title).font(.system(size: 13, weight: .semibold))
                        if let subtitle = Feature.commandBar.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Picker("Shortcut", selection: $shortcut.preset) {
                    ForEach(HotKey.Preset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Text("Works in any app. If nothing happens, another app may already use this shortcut: pick another. You can also open it from the menu bar icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!flags.isOn(.commandBar))
            Section("Try typing") {
                ForEach(CommandEngine.examples) { example in
                    HStack(spacing: 10) {
                        Image(systemName: example.symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.black)
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(example.tint))
                        Text(example.title).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(example.subtitle ?? "").foregroundStyle(.secondary)
                    }
                }
                Text("Everything is worked out on your Mac. Enter runs the highlighted line: copy a result, start a timer, or add a reminder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
