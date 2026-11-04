import SwiftUI
import CoreAudio

struct NowPlayingPanel: View {
    @ObservedObject var vm: IslandViewModel
    let track: TrackInfo
    let ns: Namespace.ID

    private var player: NowPlayingService { vm.nowPlaying }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ArtworkView(image: player.artwork, cornerRadius: 10)
                    .frame(width: 56, height: 56)
                    .overlay(alignment: .bottomTrailing) {
                        SourceBadge(source: track.source)
                            .offset(x: 6, y: 6)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(track.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressRow(track: track, live: vm.mode == .expanded)
                }

                if track.isPlaying {
                    AudioBars(colors: player.artworkColors)
                        .frame(width: 18, height: 14)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(height: 56)

            controls

            if vm.showsAudioPicker {
                AudioPicker(vm: vm)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// repeat · shuffle   ◀◀  ( ❚❚ )  ▶▶   output
    private var controls: some View {
        HStack(spacing: 0) {
            if track.source.isBrowser {
                // Web players: no shuffle / repeat to control — show where it's playing.
                Label(track.source.displayName, systemImage: track.source.symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .frame(width: 60, alignment: .leading)
            } else {
                toggleButton(track.repeatMode.symbol, on: track.repeatMode != .off, help: "Repeat") { player.cycleRepeat() }
                toggleButton("shuffle", on: track.shuffle, help: "Shuffle") { player.toggleShuffle() }
            }
            Spacer(minLength: 8)
            skipButton("backward.fill") { player.send(.previous) }
            Button { player.send(.playPause) } label: {
                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .glassBackground(Circle(), fallback: Color.white.opacity(0.12))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            skipButton("forward.fill") { player.send(.next) }
            Spacer(minLength: 8)
            outputButton
        }
        .frame(height: 42)
    }

    private var outputButton: some View {
        let open = vm.showsAudioPicker
        let symbol = player.isOnAirPlaySpeaker ? "airplayaudio" : (vm.audioOutputs.current?.symbol ?? "speaker.wave.2.fill")
        return Button {
            withAnimation(IslandViewModel.spring) { vm.showsAudioPicker.toggle() }
            if vm.showsAudioPicker { player.loadAirPlayTargets() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(open ? Color.black : Color.white)
                .frame(width: 34, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(open ? Color.white : Color.white.opacity(0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sound output")
    }

    private func toggleButton(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Feature.nowPlaying.tint : Color.white.opacity(0.45))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func skipButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Output | Apps: where the sound goes, and which player is in charge.
struct AudioPicker: View {
    @ObservedObject var vm: IslandViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                .padding(.top, 2)
            segmented
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    switch vm.audioPickerTab {
                    case .output: outputRows
                    case .apps: appRows
                    }
                }
            }
            .frame(height: CGFloat(min(vm.audioPickerRows, IslandViewModel.audioVisibleRows)) * IslandViewModel.audioRowHeight)
        }
    }

    private var segmented: some View {
        HStack(spacing: 2) {
            segment("Output", .output)
            segment("Apps", .apps)
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .frame(height: 28)
    }

    private func segment(_ title: String, _ tab: IslandViewModel.AudioPickerTab) -> some View {
        let selected = vm.audioPickerTab == tab
        return Button {
            withAnimation(IslandViewModel.spring) { vm.audioPickerTab = tab }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.5))
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Capsule().fill(selected ? Color.white.opacity(0.16) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var outputRows: some View {
        let outputs = vm.audioOutputs
        let player = vm.nowPlaying
        let onSpeaker = player.isOnAirPlaySpeaker
        ForEach(outputs.devices) { device in
            AudioRow(symbol: device.symbol, title: device.name,
                     selected: !onSpeaker && device.id == outputs.currentID,
                     accent: device.transport == kAudioDeviceTransportTypeBuiltIn) {
                if onSpeaker { player.selectAirPlay(nil) }
                outputs.select(device)
            }
        }
        ForEach(player.airPlayTargets) { target in
            AudioRow(symbol: target.symbol, title: target.name, detail: "AirPlay · Music",
                     selected: target.isSelected, accent: false) {
                player.selectAirPlay(target)
            }
        }
    }

    @ViewBuilder
    private var appRows: some View {
        let player = vm.nowPlaying
        ForEach(MediaSource.allCases.filter(\.isInstalled), id: \.self) { source in
            let isCurrent = player.track?.source == source
            let detail = player.browsersNeedingSetup.contains(source)
                ? "Needs “Allow JavaScript from Apple Events”"
                : isCurrent
                ? (player.track?.isPlaying == true ? "Playing" : "Paused")
                : (source.isRunning ? "Open" : "Not running")
            AudioRow(icon: source.appIcon, symbol: source.symbol, title: source.displayName, detail: detail,
                     selected: isCurrent, accent: false) {
                player.switchTo(source)
            }
            .help(source.isBrowser ? "To show what plays in \(source.displayName): \(source.javaScriptSetting)" : "")
        }
    }
}

/// One line in the picker: icon tile, name, ✓.
struct AudioRow: View {
    var icon: NSImage? = nil
    let symbol: String
    let title: String
    var detail: String? = nil
    let selected: Bool
    let accent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected && accent ? Color.blue : Color.white.opacity(selected ? 0.18 : 0.08)))
                    }
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
            }
            .frame(height: IslandViewModel.audioRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProgressRow: View {
    let track: TrackInfo
    var colors: [NSColor] = []
    /// false while the island is closed: this view stays loaded but nobody sees it.
    var live = true

    /// Identity of the current palette, used to cross-fade between palettes.
    private var paletteKey: String {
        colors.map { color in
            let c = color.usingColorSpace(.sRGB) ?? color
            return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }.joined(separator: "-")
    }

    /// Gradient stops: the artwork's colours, or the Music pink.
    private var stops: [Color] {
        switch colors.count {
        case 0: return [Feature.nowPlaying.tint, Feature.nowPlaying.tint]
        case 1: return [Color(nsColor: colors[0]), Color(nsColor: colors[0])]
        default: return colors.prefix(2).map { Color(nsColor: $0) }
        }
    }

    var body: some View {
        if track.isLive {
            HStack {
                Text("LIVE")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(track.isPlaying ? 0.9 : 0.4)))
                Spacer()
            }
            .frame(height: 14)
        } else if track.duration <= 0 {
            // Length unknown: show elapsed time only, no fake progress bar.
            TimelineView(LiveSchedule(live: live && track.isPlaying)) { context in
                HStack(spacing: 8) {
                    Text(Self.format(track.currentPosition(at: context.date)))
                    Capsule().fill(Color.white.opacity(0.2)).frame(height: 4)
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        } else {
            TimelineView(LiveSchedule(live: live && track.isPlaying)) { context in
                let position = track.currentPosition(at: context.date)
                let fraction = track.duration > 0 ? min(max(position / track.duration, 0), 1) : 0
                HStack(spacing: 8) {
                    Text(Self.format(position))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.2))
                            // The gradient spans the whole track and is revealed as the song plays,
                            // so the playhead colour shifts from the first to the second artwork colour.
                            ZStack {
                                LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
                                    .id(paletteKey)                 // new palette → new layer…
                                    .transition(.opacity)           // …that cross-fades over the old one
                            }
                            .animation(.easeInOut(duration: 0.7), value: paletteKey)
                            .frame(width: geo.size.width)
                            .mask(alignment: .leading) {
                                Capsule()
                                    .frame(width: geo.size.width * fraction)
                                    .animation(.linear(duration: 1), value: fraction)   // glide, don't tick
                                    .id(track.id)   // new song → start fresh, no sliding backwards
                            }
                        }
                    }
                    .frame(height: 4)
                    Text("-" + Self.format(max(track.duration - position, 0)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Design A: the player's app icon, badged on the artwork's corner.
/// Click to bring Spotify / Music to the front.
struct SourceBadge: View {
    let source: MediaSource

    var body: some View {
        if let icon = source.appIcon {
            Button {
                source.launch()
            } label: {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
                    .padding(1.5)
                    .background(Circle().fill(Color.black))   // separates it from the artwork
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Playing in \(source.displayName) — click to open")
        }
    }
}
