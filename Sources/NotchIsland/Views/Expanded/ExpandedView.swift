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

            if vm.availableTabs.count > 1 {
                TabCapsule(vm: vm, symbol: symbol(for:))
                    .padding(.top, 4)
            }

            Group {
                switch vm.visibleTab {
                case nil:
                    Placeholder(symbol: "switch.2", text: "All features are off — turn some on from the menu bar icon")
                case .nowPlaying:
                    nowPlaying
                case .calendar:
                    CalendarPanel(calendar: vm.calendar)
                case .clipboard:
                    ClipboardPanel(vm: vm, clipboard: vm.clipboard)
                case .timer:
                    TimerPanel(timer: vm.timer)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 10)
        }
    }

    /// Date on the left of the camera, battery on the right.
    private var ears: some View {
        HStack(spacing: 0) {
            Text(Date(), format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
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

    private func symbol(for tab: IslandViewModel.Tab) -> String {
        switch tab {
        case .nowPlaying: return "music.note"
        case .calendar: return vm.showsMeetingActivity ? "calendar.badge.clock" : "calendar"
        case .clipboard: return "clipboard"
        case .timer: return vm.showsTimerActivity ? "timer.circle.fill" : "timer"
        }
    }

    @ViewBuilder
    private var nowPlaying: some View {
        if let track = vm.nowPlaying.track {
            NowPlayingPanel(track: track, artwork: vm.nowPlaying.artwork, ns: ns) { command in
                vm.nowPlaying.send(command)
            }
        } else {
            MusicEmptyState()
        }
    }
}

struct TabButton: View {
    let symbol: String
    let tab: IslandViewModel.Tab
    @ObservedObject var vm: IslandViewModel

    var body: some View {
        let selected = vm.visibleTab == tab
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { vm.tab = tab }
        } label: {
            FeatureGlyph(feature: tab.feature, symbol: symbol, size: 11,
                         color: selected ? Color.white : tab.tint.opacity(0.6))
                .frame(width: 30, height: 22)
                .background(Capsule().fill(tab.tint.opacity(selected ? 0.85 : 0)))
                .shadow(color: selected ? tab.tint.opacity(0.4) : .clear, radius: 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct MusicEmptyState: View {
    private let installed = MediaSource.allCases.filter(\.isInstalled)

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

/// Floating capsule of colour-coded tabs at the bottom of the island.
struct TabCapsule: View {
    @ObservedObject var vm: IslandViewModel
    let symbol: (IslandViewModel.Tab) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(vm.availableTabs, id: \.self) { tab in
                TabButton(symbol: symbol(tab), tab: tab, vm: vm)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}
