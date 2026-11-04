import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// "Copied" (design B): a two-line preview of what you copied, with quick actions.
/// Hover the island to keep it open and click the buttons.
struct CopiedCard: View {
    @ObservedObject var vm: IslandViewModel
    @ObservedObject var clipboard: ClipboardService
    let item: ClipItem
    private let tint = Feature.clipboard.tint

    /// Pin state as it is now in the clipboard history (the card's copy can be stale).
    private var isPinned: Bool {
        clipboard.items.first { $0.id == item.id }?.isPinned ?? item.isPinned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.showsCopiedQR, let text = item.qrText, let qr = QRCode.image(for: text) {
                qrView(qr)
            } else {
                preview
            }
            actions
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        if let thumbnail = item.thumbnail {
            HStack(spacing: 10) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.imageTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let size = item.imageDimensions {
                        Text(size)
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 38)
        } else {
            box {
                if let color = item.color {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(nsColor: color))
                            .frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                        Text(item.text ?? "").font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    }
                } else if let link = item.link {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.host ?? link.absoluteString)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Text(link.path.isEmpty ? link.absoluteString : link.path + (link.query.map { "?" + $0 } ?? ""))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else if case .files(let urls) = item.content {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: urls.first?.path ?? ""))
                            .resizable().frame(width: 22, height: 22)
                        Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(text)
                        .font(item.looksLikeCode
                              ? .system(size: 11.5, design: .monospaced)
                              : .system(size: 12.5))
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                        .truncationMode(item.isPath ? .head : .tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func qrView(_ image: NSImage) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
            VStack(alignment: .leading, spacing: 3) {
                Text("Scan with your phone")
                    .font(.system(size: 13, weight: .semibold))
                Text("Point the camera at the code to open or copy it there.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 6) {
            action(isPinned ? "Pinned" : "Pin", symbol: isPinned ? "pin.fill" : "pin", on: isPinned) {
                withAnimation(.easeInOut(duration: 0.15)) { vm.pinCopied() }
            }
            if item.canJoinLines {
                action("One line", symbol: "text.alignleft") { vm.copyOneLine() }
                    .help("Copy again with line breaks and extra spaces removed")
            }
            if item.qrText != nil {
                action(vm.showsCopiedQR ? "Preview" : "QR", symbol: vm.showsCopiedQR ? "text.quote" : "qrcode",
                       on: vm.showsCopiedQR) { vm.toggleCopiedQR() }
                    .help("Show a QR code to scan with your phone")
            }
            if case .files(let urls) = item.content {
                action("Show", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            }
            Spacer(minLength: 0)
            Button { vm.dismissPeek() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    private func action(_ title: String, symbol: String, on: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? tint : Color.white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(on ? tint.opacity(0.2) : Color.white.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension ClipItem {
    /// Text worth turning into a QR code (links and text up to ~1,500 characters).
    var qrText: String? {
        if let link { return link.absoluteString }
        guard let text, !text.isEmpty, text.count <= 1500 else { return nil }
        return text
    }

    /// Multi-line text, or text with runs of spaces: "One line" helps.
    var canJoinLines: Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return text.contains("\n") || text.contains("  ") || text.contains("\t")
    }

    /// Commands, code and paths read better in a monospaced font.
    var looksLikeCode: Bool {
        guard let text else { return false }
        if isPath { return true }
        let markers = [" --", " -", "$ ", "{", "};", "=>", "()", "</", "::", "#!/", "&&", " | "]
        return markers.contains { text.contains($0) }
    }
}

enum QRCode {
    private static var cache: (text: String, image: NSImage)?

    static func image(for text: String) -> NSImage? {
        if let cache, cache.text == text { return cache.image }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        cache = (text, image)
        return image
    }
}
