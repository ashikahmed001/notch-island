import SwiftUI

/// Settings pages, System Settings style: one per area and one per feature.
enum SettingsPage: Hashable {
    case general, appearance, feature(Feature), about

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .appearance: return String(localized: "Appearance")
        case .feature(let feature): return feature.title
        case .about: return String(localized: "About")
        }
    }
}

/// Which page is showing (kept outside the view so no @State is needed).
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage? = .general
}

/// Binding straight to a flag's stored switch.
func flagBinding(_ flags: FeatureFlags, _ feature: Feature) -> Binding<Bool> {
    Binding(get: { flags.storedValue(feature) }, set: { flags.set(feature, $0) })
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var flags: FeatureFlags
    @ObservedObject var appearance = ThemeSettings.shared

    var body: some View {
        List(selection: $navigation.page) {
            Section {
                row(.general, symbol: "gearshape.fill", tint: .gray)
                row(.appearance, symbol: "paintpalette.fill", tint: .purple)
            }
            Section("Features") {
                ForEach(Feature.features, id: \.self) { feature in
                    row(.feature(feature), feature: feature)
                }
            }
            Section {
                row(.about, symbol: "info.circle.fill", tint: .blue)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ page: SettingsPage, symbol: String? = nil, tint: Color = .gray, feature: Feature? = nil) -> some View {
        HStack(spacing: 9) {
            Group {
                if let feature {
                    FeatureGlyph(feature: feature, size: 11, color: .white)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white)
                }
            }
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(feature?.tint ?? tint))
            Text(page.title)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let feature, !flags.isOn(feature) {
                Text("Off")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .tag(page)
    }
}

// MARK: - Feature page

/// One feature: live preview, the main switch, its options, and anything special it has.
struct FeaturePage: View {
    let feature: Feature
    @ObservedObject var flags: FeatureFlags

    var body: some View {
        Form {
            Section {
                Toggle(isOn: flagBinding(flags, feature)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title).font(.system(size: 13, weight: .semibold))
                        if let subtitle = feature.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !feature.options.isEmpty {
                Section("Options") {
                    ForEach(feature.options, id: \.self) { option in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(option.title, isOn: flagBinding(flags, option))
                            if let subtitle = option.subtitle {
                                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!flags.isOn(feature))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Live preview

/// A small mock of the island showing what this page changes (follows the theme and switches).
struct IslandPreview: View {
    let page: SettingsPage
    @ObservedObject var flags: FeatureFlags
    @ObservedObject var appearance = ThemeSettings.shared

    private var isOff: Bool {
        if case .feature(let feature) = page { return !flags.isOn(feature) }
        return false
    }

    var body: some View {
        ZStack(alignment: .top) {
            // A calm "desktop" behind the island.
            LinearGradient(colors: [Color(red: 0.2, green: 0.22, blue: 0.36), Color(red: 0.38, green: 0.26, blue: 0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(Color.black.opacity(0.35)).frame(height: 14)   // menu bar
            island
                .animation(.spring(response: 0.45, dampingFraction: 0.72), value: isOff)
                .animation(.spring(response: 0.45, dampingFraction: 0.72), value: appearance.theme)
            VStack {
                Spacer()
                Text(isOff ? String(localized: "Off") : caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.bottom, 8)
            }
        }
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var caption: String {
        switch page {
        case .general: return String(localized: "Hover the notch to open the island")
        case .appearance: return appearance.theme.title
        case .about: return ""
        case .feature(let feature): return feature.title
        }
    }

    @ViewBuilder
    private var island: some View {
        if isOff {
            shape(width: 150, height: 26) { EmptyView() }
                .opacity(0.6)
        } else {
            switch page {
            case .general, .about:
                shape(width: 150, height: 26) { EmptyView() }
            case .appearance:
                compact(left: AnyView(RoundedRectangle(cornerRadius: 4).fill(Feature.nowPlaying.tint).frame(width: 16, height: 16)),
                        right: AnyView(bars(Feature.nowPlaying.tint)))
            case .feature(let feature):
                featureIsland(feature)
            }
        }
    }

    @ViewBuilder
    private func featureIsland(_ feature: Feature) -> some View {
        let tint = feature.tint
        switch feature {
        case .homeDashboard:
            shape(width: 300, height: 82) {
                HStack(spacing: 8) {
                    ForEach(0..<4) { index in
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(index == 0 ? tint.opacity(0.35) : Color.white.opacity(0.08))
                            .frame(height: 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 30)
            }
        case .nowPlaying:
            compact(left: AnyView(RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [tint, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 16, height: 16)),
                    right: AnyView(bars(tint)))
        case .calendar:
            compact(left: AnyView(symbol("calendar.badge.clock", tint)),
                    right: AnyView(Text("Join").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white)
                        .padding(.horizontal, 7).frame(height: 15).background(Capsule().fill(Color.green))))
        case .reminders:
            dropDown(symbol: "checklist", tint: tint, label: String(localized: "Reminder"), row: "Call the bank")
        case .clipboard:
            dropDown(symbol: "doc.on.clipboard", tint: tint, label: String(localized: "Copied"), row: "notch \"Hello\" --icon sparkles")
        case .timer:
            compact(left: AnyView(ring(tint, 0.7)),
                    right: AnyView(Text("4:59").font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(tint)))
        case .battery:
            compact(left: AnyView(HStack(spacing: 3) {
                        Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(tint)
                        Text("Charging").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.white)
                    }),
                    right: AnyView(Text("81%").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(tint)))
        case .downloads:
            compact(left: AnyView(ring(tint, 0.42)),
                    right: AnyView(Text("42%").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Color.white)))
        case .islandAPI:
            dropDown(symbol: "checkmark.circle.fill", tint: .green, label: "1m 12s", row: "npm install · done")
        case .lockUnlock:
            compact(left: AnyView(symbol("lock.open.fill", tint)),
                    right: AnyView(Text("Away 12 min").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.white.opacity(0.7))))
        case .privacy:
            compact(left: AnyView(RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom))
                        .frame(width: 15, height: 15)
                        .overlay(Image(systemName: "video.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(Color.white))),
                    right: AnyView(HStack(spacing: 4) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                    }))
        case .systemEvents:
            compact(left: AnyView(ZStack {
                        ring(.green, 0.64)
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 6, weight: .bold)).foregroundStyle(Color.green)
                    }),
                    right: AnyView(Text("64%").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Color.white)))
        case .commandBar:
            shape(width: 300, height: 82) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "command").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.white.opacity(0.5))
                        Text("5 km to mi").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.white)
                    }
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.cyan).frame(width: 14, height: 14)
                        Text("3.107 mi").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white)
                        Spacer()
                        Text("Copy ⏎").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.white.opacity(0.5))
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
                }
                .padding(.horizontal, 16)
                .padding(.top, 30)
            }
        default:
            shape(width: 150, height: 26) { EmptyView() }
        }
    }

    // MARK: Pieces

    private func shape<Content: View>(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .top) {
            NotchShape(topRadius: 5, bottomRadius: height > 30 ? 16 : 10).fill(Color.black)
            content()
        }
        .frame(width: width, height: height)
    }

    /// Collapsed island: something left of the camera, something right of it.
    private func compact(left: AnyView, right: AnyView) -> some View {
        shape(width: 250, height: 26) {
            HStack {
                left
                Spacer()
                right
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
        }
    }

    /// An alert that drops a line down under the notch.
    private func dropDown(symbol name: String, tint: Color, label: String, row: String) -> some View {
        shape(width: 280, height: 58) {
            VStack(spacing: 6) {
                HStack {
                    symbol(name, tint)
                    Spacer()
                    Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(tint)
                }
                .frame(height: 26)
                Text(row)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
            }
            .padding(.horizontal, 14)
        }
    }

    private func symbol(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
    }

    private func ring(_ tint: Color, _ fraction: Double) -> some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: fraction).stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
    }

    private func bars(_ tint: Color) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach([0.5, 0.9, 0.35, 0.7], id: \.self) { height in
                Capsule().fill(tint).frame(width: 2.5, height: 12 * height)
            }
        }
    }
}
