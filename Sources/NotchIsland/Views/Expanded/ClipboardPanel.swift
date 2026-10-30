import AppKit
import SwiftUI

struct ClipboardPanel: View {
    @ObservedObject var vm: IslandViewModel
    @ObservedObject var clipboard: ClipboardService

    var body: some View {
        if clipboard.items.isEmpty {
            ClipboardEmptyState()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(clipboard.items) { item in
                        ClipCard(
                            item: item,
                            flash: clipboard.flashedID == item.id ? (clipboard.lastActionWasPaste ? "Pasted" : "Copied") : nil
                        )
                        .onTapGesture {
                            vm.useClip(item, copyOnly: NSEvent.modifierFlags.contains(.option))
                        }
                        .onDrag {
                            vm.isDragging = true
                            return item.itemProvider
                        }
                        .contextMenu { menu(for: item) }
                        .help("Click to paste · ⌥-click to copy · drag out · right-click for more")
                    }

                    if clipboard.hasUnpinned {
                        ClearCard { withAnimation(IslandViewModel.contentSpring) { clipboard.clearUnpinned() } }
                    }
                }
                .animation(IslandViewModel.contentSpring, value: clipboard.items.map(\.id))
            }
        }
    }

    @ViewBuilder
    private func menu(for item: ClipItem) -> some View {
        Button("Paste") { vm.useClip(item, copyOnly: false) }
        Button("Copy") { vm.useClip(item, copyOnly: true) }
        if let link = item.link {
            Button("Open Link") { NSWorkspace.shared.open(link) }
        }
        if case .files(let urls) = item.content {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        Divider()
        Button(item.isPinned ? "Unpin" : "Pin") {
            withAnimation(IslandViewModel.contentSpring) { clipboard.togglePin(item) }
        }
        Button("Delete") {
            withAnimation(IslandViewModel.contentSpring) { clipboard.delete(item) }
        }
        if clipboard.hasUnpinned {
            Divider()
            Button("Clear History (keeps pins)") {
                withAnimation(IslandViewModel.contentSpring) { clipboard.clearUnpinned() }
            }
        }
    }
}

struct ClipCard: View {
    let item: ClipItem
    /// "Copied" / "Pasted" confirmation, shown briefly after a click.
    let flash: String?

    private let tint = Feature.clipboard.tint

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let thumbnail = item.thumbnail {
                // Images and image files: the picture is the card.
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 104, height: 86)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                footer.padding(8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    footer
                }
                .padding(8)
            }

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                    .rotationEffect(.degrees(35))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if let flash {
                ZStack {
                    Color.black.opacity(0.55)
                    Label(flash, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .transition(.opacity)
            }
        }
        .frame(width: 104, height: 86)
        .background(Color.white.opacity(item.isPinned ? 0.11 : 0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(item.isPinned ? 0.45 : 0), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.15), value: flash)
    }

    /// Source app icon (or type symbol) + friendly age.
    private var footer: some View {
        HStack(spacing: 4) {
            if let icon = item.sourceIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 12, height: 12)
                    .help(item.sourceApp.map { "Copied from \($0)" } ?? "")
            } else {
                Image(systemName: item.isPinned ? "pin" : item.symbol)
            }
            TimelineView(.everyMinute) { context in
                Text(item.isPinned ? "Pinned" : Self.age(of: item.date, now: context.date))
            }
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let color = item.color {
                // Colour codes: show the colour.
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: color))
                        .frame(height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 1))
                    Text(trimmed.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            } else if let link = item.link {
                // Links: the site, then the path.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tint)
                        Text((link.host ?? "").replacingOccurrences(of: "www.", with: ""))
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    Text(link.path.isEmpty || link.path == "/" ? link.absoluteString : link.path)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            } else if item.isPath {
                // Paths: the name matters most, then where it lives.
                let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(2)
                    Text(Self.abbreviated(url.deletingLastPathComponent().path))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            } else {
                Text(trimmed)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
            }
        case .image:
            EmptyView()   // handled by the thumbnail branch
        case .files(let urls):
            VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: urls[0].path))
                    .resizable()
                    .frame(width: 28, height: 28)
                Text(urls.count > 1 ? "\(urls.count) files" : urls[0].lastPathComponent)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    static func age(of date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "Just now"
        case ..<60: return "\(minutes)m ago"
        case ..<1440: return "\(minutes / 60)h ago"
        default: return "\(minutes / 1440)d ago"
        }
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Trailing "Clear" tile at the end of the history (pinned items stay).
struct ClearCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                Text("Clear")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(width: 56, height: 86)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Clear history (pinned items stay)")
    }
}

struct ClipboardEmptyState: View {
    var body: some View {
        DoodleEmptyState(
            title: "Nothing copied yet",
            subtitle: "Press ⌘C anywhere — it lands here."
        ) {
            ClipboardDoodle(accent: Feature.clipboard.tint)
        }
    }
}
