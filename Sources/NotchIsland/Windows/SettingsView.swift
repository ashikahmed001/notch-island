import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var flags: FeatureFlags
    let canOpenAtLogin: Bool
    let showWelcome: () -> Void
    let showPermissions: () -> Void

    var body: some View {
        TabView {
            FeatureSettings(flags: flags)
                .tabItem { Label("Features", systemImage: "square.grid.2x2") }
            GeneralSettings(flags: flags, canOpenAtLogin: canOpenAtLogin,
                            showWelcome: showWelcome, showPermissions: showPermissions)
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 500)
    }
}

/// Binding straight to a flag's stored switch.
private func binding(_ flags: FeatureFlags, _ feature: Feature) -> Binding<Bool> {
    Binding(get: { flags.storedValue(feature) }, set: { flags.set(feature, $0) })
}

private struct FeatureSettings: View {
    @ObservedObject var flags: FeatureFlags

    var body: some View {
        Form {
            ForEach(Feature.features, id: \.self) { feature in
                Section {
                    Toggle(isOn: binding(flags, feature)) {
                        HStack(spacing: 10) {
                            FeatureGlyph(feature: feature, size: 12, color: .white)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(feature.tint))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(feature.title)
                                if let subtitle = feature.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    ForEach(feature.options, id: \.self) { option in
                        Toggle(option.title, isOn: binding(flags, option))
                            .padding(.leading, 36)
                            .disabled(!flags.isOn(feature))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var flags: FeatureFlags
    let canOpenAtLogin: Bool
    let showWelcome: () -> Void
    let showPermissions: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: binding(flags, .openAtLogin))
                    .disabled(!canOpenAtLogin)
                if !canOpenAtLogin {
                    Text("Available in the .app build (scripts/bundle.sh).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(Feature.welcomeGreeting.title, isOn: binding(flags, .welcomeGreeting))
                Toggle(Feature.hoverHaptics.title, isOn: binding(flags, .hoverHaptics))
            }
            Section {
                Button("Show welcome now", action: showWelcome)
                Button("Review permissions…", action: showPermissions)
            }
            Section {
                Button("Reset all to defaults", role: .destructive) { flags.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        guard let short else { return "Development build" }
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Notch Island")
                .font(.title2.weight(.semibold))
            Text(version)
                .foregroundStyle(.secondary)
            Text("A Dynamic Island for your MacBook's notch.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
