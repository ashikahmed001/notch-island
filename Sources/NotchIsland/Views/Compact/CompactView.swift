import AppKit
import SwiftUI

struct CompactView: View {
    @ObservedObject var vm: IslandViewModel

    var body: some View {
        if vm.showsCommandBar {
            CommandBarView(vm: vm)
                .transition(.islandContent)
        } else {
            content
        }
    }

    private var content: some View {
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
                .transition(.islandContent)
            }
            if vm.apiAlertHasRow, let alert = vm.apiAlert {
                APIAlertRow(alert: alert)
                    .frame(height: IslandViewModel.previewHeight - 4)
                    .transition(.islandContent)
            }
            if vm.peek == .downloaded, let url = vm.lastDownload {
                DownloadedRow(vm: vm, url: url, thumbnail: vm.lastCopied?.thumbnail)
                    .frame(height: vm.copiedPreviewHeight - 4)
                    .transition(.islandContent)
            } else if vm.peek == .copied, let item = vm.lastCopied {
                CopiedCard(vm: vm, clipboard: vm.clipboard, item: item)
                    .frame(height: vm.copiedPreviewHeight - 6, alignment: .top)
                    .transition(.islandContent)
            } else if vm.isShelfPeek, let item = vm.lastCopied {
                CopiedPreview(item: item)
                    .frame(height: vm.copiedPreviewHeight - 4)
                    .transition(.islandContent)
            }
            if vm.peek == .alert, let alert = vm.islandAlert {
                AlertCard(vm: vm, alert: alert)
                    .frame(height: IslandViewModel.alertHeight - 6)
                    .transition(.islandContent)
            }
            if vm.peek == .banner, let banner = vm.banner {
                BannerRow(vm: vm, banner: banner)
                    .frame(height: IslandViewModel.bannerHeight - 4)
                    .transition(.islandContent)
            }
            if vm.peek == .notice, let notice = vm.notice {
                NoticeRow(vm: vm, notice: notice)
                    .frame(height: IslandViewModel.previewHeight - 4)
                    .transition(.islandContent)
            }
        }
        // Notices are clickable: open the meeting / reminder in its app.
        .contentShape(Rectangle())
        .onTapGesture { vm.openNotice() }
        .allowsHitTesting(vm.isClickablePeek || vm.compactJoinMeeting != nil)
    }

    private var topRow: some View {
        ZStack {
            activity
                .id(vm.compactKey)
                .transition(.islandContent)
        }
        .animation(IslandViewModel.contentSpring, value: vm.compactKey)
    }

    private var activity: some View {
        HStack(spacing: 0) {
            if let peek = vm.peek {
                switch peek {
                case .charging, .charged, .lowBattery:
                    // ⚡ Charging            81% ▭
                    let tint: Color = peek == .lowBattery ? .red : .green
                    HStack(spacing: 6) {
                        if peek == .lowBattery {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(tint)
                        } else {
                            PulsingBolt(tint: tint)
                        }
                        Text(vm.batteryPeekLabel ?? "")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .fixedSize()
                    }
                    Spacer(minLength: vm.notchSize.width)
                    HStack(spacing: 6) {
                        Text("\(vm.battery.level)%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(tint)
                            .fixedSize()
                        BatteryGlyph(level: vm.battery.level,
                                     showBolt: peek != .lowBattery,
                                     fill: tint,
                                     width: 24)
                    }
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
                case .apiAlert:
                    if let alert = vm.apiAlert {
                        let tint = IslandAPIService.swiftUIColor(alert.color)
                        Image(systemName: alert.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tint)
                        Spacer(minLength: vm.notchSize.width)
                        if alert.isCompact {
                            Text(alert.title)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(tint)
                                .lineLimit(1)
                                .fixedSize()
                        } else if let badge = alert.badge {
                            Text(badge)
                                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(tint)
                                .lineLimit(1)
                                .fixedSize()
                        } else {
                            Circle().fill(tint).frame(width: 7, height: 7)
                        }
                    }
                case .banner, .alert:
                    Color.clear   // the content sits under the notch
                case .device:
                    if let device = vm.connectedDevice {
                        Image(systemName: device.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white)
                        Spacer(minLength: vm.notchSize.width)
                        let level = device.battery ?? 100
                        ProgressRing(fraction: device.battery.map { Double($0) / 100 }, tint: level <= 20 ? .red : .green)
                            .frame(width: 15, height: 15)
                    }
                case .tray:
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Feature.clipboard.tint)
                    Spacer(minLength: vm.notchSize.width)
                    Text("Added to tray")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Feature.clipboard.tint)
                        .fixedSize()
                case .notice:
                    if let notice = vm.notice {
                        let tint = notice.feature.tint
                        Image(systemName: notice.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tint)
                        Spacer(minLength: vm.notchSize.width)
                        Text(notice.label)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(tint)
                            .lineLimit(1)
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
            } else if vm.showsDownloadActivity {
                CompactDownload(downloads: vm.downloads, notchWidth: vm.notchSize.width)
            } else if let activity = vm.systemActivity {
                CompactSystemProgress(activity: activity, notchWidth: vm.notchSize.width)
            } else if vm.showsAPIProgress, let activity = vm.api.progress {
                let tint = IslandAPIService.swiftUIColor(activity.color)
                ZStack {
                    ProgressRing(fraction: activity.value, tint: tint)
                    if activity.value == nil {
                        Image(systemName: activity.icon)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 15, height: 15)
                .help(activity.title)
                Spacer(minLength: vm.notchSize.width)
                Text(activity.value.map { "\(Int(($0 * 100).rounded()))%" } ?? activity.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .frame(maxWidth: 70, alignment: .trailing)
            } else if vm.showsAgentActivity, let session = vm.latestAgent {
                AgentIcon(session: session, size: 18)
                Spacer(minLength: vm.notchSize.width)
                if session.state == .needsInput {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                } else {
                    HStack(spacing: 6) {
                        Spinner(tint: IslandAPIService.swiftUIColor(session.tint))
                            .frame(width: 12, height: 12)
                        if let started = session.currentStarted {
                            TimelineView(.periodic(from: started, by: 1)) { context in
                                Text(AgentSession.elapsed(since: started, now: context.date))
                                    // Monospaced like a terminal clock (matches the website).
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.75))
                                    .fixedSize()
                            }
                        }
                    }
                    .help(session.current ?? session.title)
                }
            } else if vm.showsPrivacyActivity {
                CompactPrivacy(privacy: vm.privacy, notchWidth: vm.notchSize.width)
            } else if let meeting = vm.compactJoinMeeting {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: meeting.color))
                Spacer(minLength: vm.notchSize.width)
                JoinButton(height: 22) { vm.joinFromCompact() }
                    .help("Join “\(meeting.title)”")
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
            }
            // The arrow always sits inside, gently dropping — "something is coming in".
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: Motion.reduced)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                let drop = (1 - cos(phase * 2 * .pi)) / 2
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(tint)
                    .offset(y: -1 + 2 * drop)
            }
        }
    }
}

/// Second line of an Island API alert: title, then subtitle in grey.
/// Second line of a new-meeting / reminder notice: what it is, and when or where.
struct NoticeRow: View {
    @ObservedObject var vm: IslandViewModel
    let notice: IslandViewModel.Notice

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(nsColor: notice.color))
                .frame(width: 6, height: 6)
            Text(notice.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
            Text(notice.detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            if notice.isReminder {
                Button { vm.completeNoticeReminder() } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(notice.feature.tint)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Mark as done")
            } else {
                // Appears on hover: "click to open".
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .opacity(vm.noticeHovered ? 1 : 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(vm.noticeHovered ? 0.08 : 0))
                .padding(.horizontal, 4)
        )
    }
}

struct APIAlertRow: View {
    let alert: IslandAPIService.Alert

    var body: some View {
        HStack(spacing: 6) {
            Text(alert.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
            if let subtitle = alert.subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }
}

/// Generic progress ring (Island API activities).
struct ProgressRing: View {
    let fraction: Double?
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: 2.5)
            if let fraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: fraction)
            }
        }
    }
}

// MARK: - Banners

/// The drop-down that announces a live activity: icon, caption, title, subtitle, and a
/// ring / check / symbol on the right.
struct BannerRow: View {
    @ObservedObject var vm: IslandViewModel
    let banner: IslandViewModel.Banner

    var body: some View {
        if banner.live == .download {
            DownloadBanner(downloads: vm.downloads)
        } else {
            standard
        }
    }

    private var standard: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottomTrailing) {
                    if let badge = banner.badge {
                        Image(systemName: badge.symbol)
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(Color.black)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(badge.color))
                            .overlay(Circle().stroke(Color.black, lineWidth: 2))
                            .offset(x: 4, y: 4)
                    }
                }

            VStack(alignment: .leading, spacing: 1) {
                if let caption = banner.caption {
                    Text(caption)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(banner.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                if let subtitle = banner.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var icon: some View {
        switch banner.icon {
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(color)
        case .tile(let name, let color):
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.18))
                .overlay(
                    Image(systemName: name)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Color.black)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(color))
                )
        case .image(let image, let fallback):
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: fallback)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.orange)
            }
        case .artwork:
            ArtworkView(image: vm.nowPlaying.artwork, cornerRadius: 8)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch banner.trailing {
        case .ring(let fraction, let tint, let label):
            ZStack {
                Circle().stroke(tint.opacity(0.25), lineWidth: 3)
                if let fraction {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 34, height: 34)
        case .check(let tint):
            ZStack {
                Circle().stroke(tint, lineWidth: 2.5)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
        case .spinner(let tint):
            Spinner(tint: tint)
                .frame(width: 22, height: 22)
                .frame(width: 34, height: 34)
        case .label(let text, let tint):
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 4)
        case .none:
            EmptyView()
        }
    }
}

/// A small rotating arc (no @State: driven by TimelineView).
struct Spinner: View {
    let tint: Color

    var body: some View {
        // 30 fps is plenty for a small spinner (it can run for minutes while an agent works).
        // Slower in Low Power Mode / Reduce motion, but still turning: it means "working".
        TimelineView(.animation(minimumInterval: Motion.reduced ? 1.0 / 10 : 1.0 / 30)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
    }
}

/// The agent's app icon (Claude app, or the terminal it runs in).
struct AgentIcon: View {
    let session: AgentSession
    var size: CGFloat = 18

    var body: some View {
        if let icon = session.icon {
            Image(nsImage: icon).resizable().interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.7, weight: .semibold))
                .foregroundStyle(IslandAPIService.swiftUIColor(session.tint))
                .frame(width: size, height: size)
        }
    }
}

/// The charging bolt: breathes in and out with a soft glow while the alert shows.
struct PulsingBolt: View {
    let tint: Color
    /// Seconds per breath.
    private static let period = 1.1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: Motion.reduced)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.period) / Self.period
            let wave = (1 - cos(phase * 2 * .pi)) / 2          // 0 → 1 → 0, smooth
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .scaleEffect(0.85 + 0.3 * wave)
                .opacity(0.55 + 0.45 * wave)
                .shadow(color: tint.opacity(0.9 * wave), radius: 2 + 4 * wave)
        }
        .frame(width: 14, height: 14)
    }
}

/// The download banner, kept live: browser icon, file name, "12 MB of 240 MB · 2 min left",
/// and a ring with the percentage.
struct DownloadBanner: View {
    @ObservedObject var downloads: DownloadsService
    private let tint = Feature.downloads.tint

    var body: some View {
        let download = downloads.active
        HStack(spacing: 12) {
            icon(download)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(download?.browserName.map { "Downloading · \($0)" } ?? (download == nil ? "Download" : "Downloading"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(download?.name ?? "Finishing…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(download?.detail ?? "Starting…")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)
            ring(download)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        // No blanket animation: the ring animates itself; text and icon just update in place.
    }

    /// App icons, fetched once (a fresh NSImage on every update made the icon flicker).
    private static var iconCache: [String: NSImage] = [:]

    static func appIcon(_ bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }

    @ViewBuilder
    private func icon(_ download: DownloadsService.Download?) -> some View {
        if let id = download?.browserBundleID, let appIcon = Self.appIcon(id) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(tint))
                        .overlay(Circle().stroke(Color.black, lineWidth: 2))
                        .offset(x: 4, y: 4)
                }
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.white, tint)
        }
    }

    @ViewBuilder
    private func ring(_ download: DownloadsService.Download?) -> some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: 3)
            if let fraction = download?.fraction {
                Circle()
                    .trim(from: 0, to: max(fraction, 0.02))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: fraction)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white)
            } else if download == nil {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.green)
            } else {
                Spinner(tint: tint).padding(4)
            }
        }
        .frame(width: 36, height: 36)
    }
}

/// "Downloaded": the file, its size, and Open / Show in Finder (hover the island to click).
struct DownloadedRow: View {
    @ObservedObject var vm: IslandViewModel
    let url: URL
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    Text(DownloadsService.Download.bytes(Int64(size)))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            action("Open", symbol: "arrow.up.forward.square") { vm.openDownload() }
            action("Show", symbol: "folder") { vm.revealDownload() }
                .help("Show in Finder")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }

    private func action(_ title: String, symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(vm.noticeHovered ? 0.18 : 0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Collapsed island while downloading: ↓ ring (with a count badge for several) … 42%.
/// Watches the downloads itself, so progress ticks don't redraw the whole island.
struct CompactDownload: View {
    @ObservedObject var downloads: DownloadsService
    let notchWidth: CGFloat

    var body: some View {
        if let download = downloads.active {
            HStack(spacing: 0) {
                DownloadRing(fraction: download.fraction)
                    .frame(width: 18, height: 18)
                    .overlay(alignment: .topTrailing) {
                        if download.count > 1 {
                            Text("\(download.count)")
                                .font(.system(size: 8, weight: .heavy).monospacedDigit())
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 3)
                                .frame(minWidth: 12, minHeight: 12)
                                .background(Capsule().fill(Feature.downloads.tint))
                                .offset(x: 6, y: -4)
                        }
                    }
                    .help(download.name)
                Spacer(minLength: notchWidth)
                Text(download.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "…")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.9))   // the ring carries the colour
            }
        }
    }
}

/// The download ring in the split bubble (also watches the service itself).
struct BubbleDownloadRing: View {
    @ObservedObject var downloads: DownloadsService

    var body: some View {
        DownloadRing(fraction: downloads.active?.fraction)
    }
}

/// iPhone-style alert: big icon, title and message, then two wide buttons.
struct AlertCard: View {
    @ObservedObject var vm: IslandViewModel
    let alert: IslandViewModel.IslandAlert

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                Image(systemName: alert.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(alert.tint)
                    .frame(width: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(alert.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Text(alert.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                ForEach(alert.choices) { choice in
                    Button { vm.perform(choice) } label: {
                        Text(choice.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(choice.prominent ? Color.blue : Color.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(Capsule().fill(choice.prominent ? Color.blue.opacity(0.2) : Color.white.opacity(0.12)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

// MARK: - Mic & camera

/// Collapsed island while the mic or camera is in use: the app on the left,
/// macOS-style dots on the right (orange = microphone, green = camera).
struct CompactPrivacy: View {
    @ObservedObject var privacy: PrivacyService
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            leading
                .help(PrivacyDots.summary(privacy))
            Spacer(minLength: notchWidth)
            PrivacyDots(privacy: privacy)
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let app = privacy.micApps.first, let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .overlay(alignment: .topTrailing) {
                    if privacy.micApps.count > 1 {
                        Text("\(privacy.micApps.count)")
                            .font(.system(size: 8, weight: .heavy).monospacedDigit())
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(Capsule().fill(Color.orange))
                            .offset(x: 6, y: -4)
                    }
                }
        } else {
            Image(systemName: privacy.micInUse ? "mic.fill" : "video.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(privacy.micInUse ? Color.orange : Color.green)
        }
    }
}

/// The orange / green dots, as in the menu bar.
struct PrivacyDots: View {
    @ObservedObject var privacy: PrivacyService

    var body: some View {
        HStack(spacing: 4) {
            if privacy.micInUse { Circle().fill(Color.orange).frame(width: 7, height: 7) }
            if privacy.cameraInUse { Circle().fill(Color.green).frame(width: 7, height: 7) }
        }
    }

    /// "Zoom is using the microphone · Camera is on" (tooltip).
    static func summary(_ privacy: PrivacyService) -> String {
        var parts: [String] = []
        if !privacy.micApps.isEmpty {
            let names = privacy.micApps.map(\.name).joined(separator: ", ")
            parts.append(String(localized: "Microphone: \(names)"))
        } else if privacy.micInUse {
            parts.append(String(localized: "Microphone in use"))
        }
        if privacy.cameraInUse { parts.append(String(localized: "Camera in use")) }
        return parts.joined(separator: " · ")
    }
}
