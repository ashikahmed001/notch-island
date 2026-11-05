import AppKit
import SwiftUI

/// Settings, System Settings style: sidebar on the left, the page on the right,
/// with a live preview of the island at the top of each feature.
struct SettingsView: View {
    @ObservedObject var flags: FeatureFlags
    @ObservedObject var navigation: SettingsNavigation
    let api: IslandAPIService
    let terminal: TerminalSettings
    let canOpenAtLogin: Bool
    let showWelcome: () -> Void
    let showPermissions: () -> Void

    var body: some View {
        // The sidebar always stays open (no collapse button jumping around the toolbar).
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                // Pinned above the page so it never slides under the title bar.
                if let page = navigation.page, page != .about {
                    IslandPreview(page: page, flags: flags)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                }
                detail
            }
            .navigationTitle(navigation.page?.title ?? "")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 800, height: 600)
    }

    @ViewBuilder
    private var sidebar: some View {
        let list = SettingsSidebar(navigation: navigation, flags: flags)
            .navigationSplitViewColumnWidth(214)
        if #available(macOS 14.0, *) {
            list.toolbar(removing: .sidebarToggle)
        } else {
            list
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.page ?? .general {
        case .general:
            GeneralSettings(flags: flags, canOpenAtLogin: canOpenAtLogin,
                            showWelcome: showWelcome, showPermissions: showPermissions)
        case .appearance:
            AppearanceSettings(appearance: ThemeSettings.shared, flags: flags)
        case .feature(.homeDashboard):
            HomeWidgetSettings(home: HomeSettings.shared, flags: flags)
        case .feature(.islandAPI):
            TerminalSettingsView(api: api, settings: terminal, flags: flags)
        case .feature(.commandBar):
            CommandBarSettingsView(flags: flags, shortcut: CommandBarShortcut.shared)
        case .feature(let feature):
            FeaturePage(feature: feature, flags: flags)
        case .about:
            AboutSettings()
        }
    }
}

/// Binding straight to a flag's stored switch.
private func binding(_ flags: FeatureFlags, _ feature: Feature) -> Binding<Bool> {
    flagBinding(flags, feature)
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
                Toggle(Feature.splitIsland.title, isOn: binding(flags, .splitIsland))
                Toggle(Feature.liveBanners.title, isOn: binding(flags, .liveBanners))
                Toggle(Feature.deviceAlerts.title, isOn: binding(flags, .deviceAlerts))
                Toggle(Feature.networkAlerts.title, isOn: binding(flags, .networkAlerts))
                Toggle(Feature.headerDate.title, isOn: binding(flags, .headerDate))
                Toggle(Feature.headerBattery.title, isOn: binding(flags, .headerBattery))
                Toggle(Feature.liquidGlass.title, isOn: binding(flags, .liquidGlass))
                    .disabled(!LiquidGlass.isSupported)
                Text(LiquidGlass.isSupported
                     ? "Glass buttons and tabs. On screens without a notch, the whole island turns to glass."
                     : "Needs macOS 26, and a build made with the macOS 26 SDK (Xcode 26 or its Command Line Tools).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(Feature.hoverHaptics.title, isOn: binding(flags, .hoverHaptics))
            }
            Section {
                Toggle(Feature.batterySaver.title, isOn: binding(flags, .batterySaver))
                Text("Music bars at 30 fps, nothing ticks while the island is closed, fewer music checks, and in Low Power Mode decorative motion stands still and the clipboard is checked less often. The island looks the same.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            UpdatesSection(updates: UpdateController.shared)
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

/// Settings ▸ Appearance: theme colours, seasonal touches, greeting.
private struct AppearanceSettings: View {
    @ObservedObject var appearance: ThemeSettings
    @ObservedObject var flags: FeatureFlags

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                    ForEach(ThemeSettings.Theme.allCases) { theme in
                        Button { appearance.theme = theme } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 4) {
                                    ForEach(Array(theme.swatch.prefix(5).enumerated()), id: \.offset) { _, color in
                                        Circle().fill(color).frame(width: 14, height: 14)
                                    }
                                }
                                Text(theme.title).font(.system(size: 12, weight: .semibold))
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
                            .foregroundStyle(Color.white)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(appearance.theme == theme ? Color.accentColor : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Colours for the island's icons, rings and buttons. The island itself stays black so it blends with the notch.")
            }

            Section {
                Toggle("Seasonal touches", isOn: $appearance.seasonal)
                if let upcoming = Season.upcoming() {
                    Text(Calendar.current.isDateInToday(upcoming.1)
                         ? "Today: \(upcoming.0.name)"
                         : "Next: \(upcoming.0.name), \(upcoming.1.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Snow in December, sparkles for Diwali, Eid and Lunar New Year, colour for Holi, confetti at New Year — inside the open island, and in the greeting.")
            }

            Section("Language") {
                Picker("Language", selection: $appearance.language) {
                    Text("System default").tag("")
                    ForEach(ThemeSettings.languages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                if appearance.languageChanged {
                    HStack {
                        Text("Restart Notch Island to switch languages.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart now") { ThemeSettings.relaunch() }
                    }
                }
            }

            Section("Greeting") {
                TextField("Greeting", text: $appearance.greeting, prompt: Text("Good morning / Good evening…"))
                TextField("Name", text: $appearance.name, prompt: Text(IslandViewModel.firstName()))
                Text("Leave empty to use the time of day and your Mac account's first name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings ▸ Home: pick the dashboard's widgets and their order.
private struct HomeWidgetSettings: View {
    @ObservedObject var home: HomeSettings
    @ObservedObject var flags: FeatureFlags

    var body: some View {
        Form {
            Section {
                Toggle("Show the Home tab", isOn: binding(flags, .homeDashboard))
            } footer: {
                Text("Widgets appear left to right in this order. The island grows to fit them.")
            }
            Section("Shown") {
                if home.widgets.isEmpty {
                    Text("No widgets — add some below.").foregroundStyle(.secondary)
                }
                ForEach(Array(home.widgets.enumerated()), id: \.element) { index, widget in
                    HStack {
                        Label(widget.title, systemImage: widget.symbol)
                        Spacer()
                        Button { home.move(widget, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                            .help("Move left")
                        Button { home.move(widget, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == home.widgets.count - 1)
                            .help("Move right")
                        Button { home.setShown(widget, false) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help("Remove")
                    }
                }
            }
            let hidden = HomeSettings.Widget.allCases.filter { !home.isShown($0) }
            if !hidden.isEmpty {
                Section("Available") {
                    ForEach(hidden) { widget in
                        HStack {
                            Label(widget.title, systemImage: widget.symbol)
                            Spacer()
                            Button { home.setShown(widget, true) } label: { Image(systemName: "plus.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.green)
                                .help("Add")
                        }
                    }
                }
            }
            Section {
                Button("Restore default widgets") { home.reset() }
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

/// Settings ▸ General ▸ Updates.
private struct UpdatesSection: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        Section("Updates") {
            if updates.isConfigured {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }))
                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { updates.automaticallyInstalls }, set: { updates.automaticallyInstalls = $0 }))
                    .disabled(!updates.automaticallyChecks)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version \(UpdateController.currentVersion)")
                        if let last = updates.lastCheck {
                            Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Check Now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheck)
                }
            } else {
                Text("Version \(UpdateController.currentVersion). To update, download the latest version from the website.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
