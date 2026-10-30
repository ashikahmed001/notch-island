import SwiftUI

struct NowPlayingPanel: View {
    let track: TrackInfo
    let artwork: NSImage?
    let ns: Namespace.ID
    /// Progress bar colours. Empty (the default) → the Music pink, matching the app theme.
    /// Pass artwork colours here to tint it like the audio bars instead.
    var colors: [NSColor] = []
    let onCommand: (NowPlayingService.Command) -> Void

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(image: artwork, cornerRadius: 10)
                .frame(width: 72, height: 72)
                .overlay(alignment: .bottomTrailing) {
                    SourceBadge(source: track.source)
                        .offset(x: 6, y: 6)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(track.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressRow(track: track, colors: colors)
                HStack(spacing: 22) {
                    controlButton("backward.fill", .previous)
                    controlButton(track.isPlaying ? "pause.fill" : "play.fill", .playPause, size: 18)
                    controlButton("forward.fill", .next)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func controlButton(_ symbol: String, _ command: NowPlayingService.Command, size: CGFloat = 14) -> some View {
        Button {
            onCommand(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProgressRow: View {
    let track: TrackInfo
    var colors: [NSColor] = []

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
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    Text(Self.format(track.currentPosition(at: context.date)))
                    Capsule().fill(Color.white.opacity(0.2)).frame(height: 4)
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
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
