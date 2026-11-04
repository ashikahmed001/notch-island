import SwiftUI

struct ExpandedView: View {
    @ObservedObject var vm: IslandViewModel
    let ns: Namespace.ID

    var body: some View {
        if let welcome = vm.welcome {
            WelcomeView(vm: vm, welcome: welcome)
                .padding(.top, vm.notchSize.height + 4)
                .padding(.bottom, 4)
                .transition(.blurMorph)
        } else if vm.showsFileTray {
            FileTrayView(targeted: vm.fileTrayTargeted)
                .padding(.top, vm.notchSize.height + 6)
                .transition(.blurMorph)
        } else {
            mainContent
                .transition(.blurMorph)
        }
    }

    /// Layout O (capsule on top):
    ///   [ date ]  ( camera )  [ battery ]   ← the "ears" beside the notch
    ///         ( ♪  📅  📋  ⏱ )              ← floating colour capsule
    ///            current panel
    private var mainContent: some View {
        VStack(spacing: 0) {
            ears
                .frame(height: vm.notchSize.height)

            Group {
                switch vm.visibleTab {
                case nil:
                    Placeholder(symbol: "switch.2", text: "All features are off — turn some on from the menu bar icon")
                case .home:
                    HomePanel(vm: vm)
                case .agents:
                    AgentPanel(vm: vm, api: vm.api)
                case .downloads:
                    DownloadsList(downloads: vm.downloads)
                case .nowPlaying:
                    nowPlaying
                case .calendar:
                    CalendarPanel(calendar: vm.calendar)
                case .clipboard:
                    ClipboardPanel(vm: vm, clipboard: vm.clipboard)
                case .timer:
                    TimerPanel(timer: vm.timer, live: vm.mode == .expanded)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 10)
        }
    }

    /// Date on the left of the camera, battery on the right.
    private var ears: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(Date(), format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if vm.visibleTab == .home {
                    HomeEditButton(vm: vm)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear
                .frame(width: vm.notchSize.width)
            Group {
                if vm.showsBattery {
                    BatteryBadge(battery: vm.battery, compact: true)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    static func symbol(for tab: IslandViewModel.Tab, vm: IslandViewModel) -> String {
        switch tab {
        case .home: return "square.grid.2x2"
        case .agents: return vm.showsAgentActivity ? "sparkles" : "checklist"
        case .downloads: return "arrow.down.circle"
        case .nowPlaying: return "music.note"
        case .calendar: return vm.showsMeetingActivity ? "calendar.badge.clock" : "calendar"
        case .clipboard: return "clipboard"
        case .timer: return vm.showsTimerActivity ? "timer.circle.fill" : "timer"
        }
    }

    @ViewBuilder
    private var nowPlaying: some View {
        if let track = vm.nowPlaying.track {
            NowPlayingPanel(vm: vm, track: track, ns: ns)
        } else {
            MusicEmptyState()
        }
    }
}

struct MusicEmptyState: View {
    private let installed = MediaSource.allCases.filter { $0.isInstalled && !$0.isBrowser }

    var body: some View {
        DoodleEmptyState(
            title: "Nothing playing",
            subtitle: "Play something in Music or Spotify."
        ) {
            MusicDoodle(accent: Feature.nowPlaying.tint)
        } actions: {
            HStack(spacing: 6) {
                ForEach(installed, id: \.self) { source in
                    Button {
                        source.launch()
                    } label: {
                        TintedCapsuleLabel(title: "Open \(source.displayName)", symbol: source.symbol, tint: Feature.nowPlaying.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Floating tab bar under the open island: the selected tab shows its name.
struct TabBar: View {
    @ObservedObject var vm: IslandViewModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(vm.availableTabs, id: \.self) { tab in
                let selected = vm.visibleTab == tab
                Button {
                    withAnimation(IslandViewModel.spring) { vm.tab = tab }
                } label: {
                    HStack(spacing: 6) {
                        FeatureGlyph(feature: tab.feature, symbol: ExpandedView.symbol(for: tab, vm: vm), size: 12,
                                     color: selected ? Color.white : Color.white.opacity(0.55))
                        if selected {
                            Text(tab.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .fixedSize()
                                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                        }
                    }
                    .padding(.horizontal, selected ? 12 : 10)
                    .frame(height: IslandViewModel.tabBarHeight - 8)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.14) : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(4)
        .frame(height: IslandViewModel.tabBarHeight)
        // Solid black, like the island itself (no glass, no see-through).
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

/// Dashed drop zone shown while a file is dragged to the notch.
struct FileTrayView: View {
    let targeted: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.fill")
                .font(.system(size: 20, weight: .semibold))
            Text(targeted ? "Drop to add" : "Files Tray")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Color.white.opacity(targeted ? 1 : 0.8))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(targeted ? 0.6 : 0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(targeted ? 0.08 : 0.03)))
        )
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
    }
}
