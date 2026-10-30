import AppKit
import SwiftUI

struct CompactView: View {
    @ObservedObject var vm: IslandViewModel

    var body: some View {
        VStack(spacing: 0) {
            topRow
                .frame(height: vm.notchSize.height)
            if vm.peek == .unlocked, let summary = vm.awaySummary, !summary.missed.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.orange)
                    Text(summary.missed.joined(separator: "  ·  "))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: IslandViewModel.previewHeight - 4)
                .transition(.blurMorph)
            }
            if vm.isShelfPeek, let item = vm.lastCopied {
                CopiedPreview(item: item)
                    .frame(height: vm.copiedPreviewHeight - 4)
                    .transition(.blurMorph)
            }
        }
    }

    private var topRow: some View {
        ZStack {
            activity
                .id(vm.compactKey)
                .transition(.blurMorph)
        }
        .animation(IslandViewModel.contentSpring, value: vm.compactKey)
    }

    private var activity: some View {
        HStack(spacing: 0) {
            if let peek = vm.peek {
                switch peek {
                case .charging, .charged, .lowBattery:
                    BatteryGlyph(level: vm.battery.level,
                                 showBolt: peek != .lowBattery,
                                 fill: peek == .lowBattery ? .red : .green,
                                 width: 28)
                    Spacer(minLength: vm.notchSize.width)
                    Text(peek == .charged ? "Full" : "\(vm.battery.level)%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(peek == .lowBattery ? Color.red : Color.green)
                case .copied:
                    Image(systemName: vm.lastCopied?.thumbnail != nil ? "checkmark.circle.fill" : (vm.lastCopied?.previewSymbol ?? "checkmark.circle.fill"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Feature.clipboard.tint)
                    Spacer(minLength: vm.notchSize.width)
                    Text("Copied")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Feature.clipboard.tint)
                case .screenshot:
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Feature.clipboard.tint)
                    Spacer(minLength: vm.notchSize.width)
                    Text("Screenshot")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Feature.clipboard.tint)
                        .fixedSize()
                case .downloaded:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Feature.downloads.tint)
                    Spacer(minLength: vm.notchSize.width)
                    Text("Downloaded")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Feature.downloads.tint)
                        .fixedSize()
                case .unlocked:
                    LockGlyph(open: vm.lockOpen)
                        .frame(width: 16, height: 16)
                    Spacer(minLength: vm.notchSize.width)
                    if let summary = vm.awaySummary, summary.showsAwayTime || !summary.missed.isEmpty {
                        Text(summary.showsAwayTime ? "Away \(IslandViewModel.formatAway(summary.awayFor))" : "Welcome back")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                case .timerDone:
                    Image(systemName: "bell.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.orange)
                    Spacer(minLength: vm.notchSize.width)
                    Text("Done")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.orange)
                }
            } else if vm.showsTimerActivity {
                TimerRing(timer: vm.timer, lineWidth: 2.5)
                    .frame(width: 16, height: 16)
                Spacer(minLength: vm.notchSize.width)
                TimerText(timer: vm.timer, size: 12)
            } else if vm.showsDownloadActivity, let download = vm.downloads.active {
                DownloadRing(fraction: download.fraction)
                    .frame(width: 15, height: 15)
                    .help(download.name)
                Spacer(minLength: vm.notchSize.width)
                Text(download.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "…")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Feature.downloads.tint)
            } else if vm.showsMeetingActivity, let meeting = vm.calendar.next {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: meeting.color))
                Spacer(minLength: vm.notchSize.width)
                TimelineView(.everyMinute) { context in
                    Text(meeting.shortLabel(at: context.date))
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color(nsColor: meeting.color))
                }
            } else if vm.showsMusicActivity {
                ArtworkView(image: vm.nowPlaying.artwork, cornerRadius: 5)
                    .frame(width: 22, height: 22)
                Spacer(minLength: vm.notchSize.width)
                AudioBars(colors: vm.nowPlaying.artworkColors)
                    .frame(width: 20, height: 14)
            } else {
                Color.clear
            }
        }
    }
}

/// What was just copied:
/// - P6: images get a real thumbnail with name and size;
/// - P2: everything else gets a tinted, type-aware chip.
struct CopiedPreview: View {
    let item: ClipItem
    private let tint = Feature.clipboard.tint

    var body: some View {
        Group {
            if let thumbnail = item.thumbnail {
                imagePreview(thumbnail)
            } else {
                chip
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }

    private func imagePreview(_ thumbnail: NSImage) -> some View {
        HStack(spacing: 9) {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.imageTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = item.imageDimensions {
                    Text(size)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chip: some View {
        HStack(spacing: 5) {
            if let color = item.color {
                Circle()
                    .fill(Color(nsColor: color))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
            } else {
                Image(systemName: item.previewSymbol)
                    .font(.system(size: 10, weight: .semibold))
            }
            chipText
                .lineLimit(1)
                .truncationMode(item.isPath ? .head : .tail)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint.opacity(0.9))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.14)))
    }

    /// Links: bold site + dim path. Others: the one-line summary.
    private var chipText: Text {
        if let link = item.link {
            let host = (link.host ?? "").replacingOccurrences(of: "www.", with: "")
            let path = link.path == "/" ? "" : link.path
            return Text(host).foregroundColor(.white).fontWeight(.semibold)
                + Text(path).foregroundColor(tint.opacity(0.75))
        }
        return Text(item.summary)
    }
}

/// Padlock that springs open: the closed lock fades/shrinks out as the open one pops in.
struct LockGlyph: View {
    let open: Bool

    var body: some View {
        ZStack {
            Image(systemName: "lock.fill")
                .opacity(open ? 0 : 1)
                .scaleEffect(open ? 0.7 : 1)
            Image(systemName: "lock.open.fill")
                .opacity(open ? 1 : 0)
                .scaleEffect(open ? 1 : 1.25)
                .rotationEffect(.degrees(open ? 0 : -12), anchor: .bottom)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Feature.lockUnlock.tint)
    }
}

/// Download progress ring (an arrow while the size is unknown).
struct DownloadRing: View {
    let fraction: Double?
    private let tint = Feature.downloads.tint

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.25), lineWidth: 2.5)
            if let fraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: fraction)
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
    }
}
