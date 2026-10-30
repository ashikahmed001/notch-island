import AppKit
import ImageIO

struct ClipItem: Identifiable, Equatable {
    enum Content {
        case text(String)
        case image(NSImage)
        case files([URL])
    }

    let id = UUID()
    let content: Content
    /// Small preview for images and image files, made once when the item is captured.
    let thumbnail: NSImage?
    /// App that was frontmost when this was copied.
    var sourceApp: String? = nil
    var sourceIcon: NSImage? = nil
    /// Pinned items stay at the front, never age out, and survive restarts (text only).
    var isPinned = false
    var date = Date()

    /// Same item *and* same state, so SwiftUI redraws when an item is pinned or reused.
    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool {
        lhs.id == rhs.id && lhs.isPinned == rhs.isPinned && lhs.date == rhs.date
    }

    var symbol: String {
        switch content {
        case .text: return isPath ? "folder" : (link != nil ? "link" : "text.alignleft")
        case .image: return "photo"
        case .files: return thumbnail != nil ? "photo" : "doc"
        }
    }

    /// Icon for the copy preview: link, colour, path, file, or quoted text.
    var previewSymbol: String {
        switch content {
        case .text:
            if link != nil { return "link" }
            if color != nil { return "paintpalette.fill" }
            if isPath { return "folder.fill" }
            return "text.quote"
        case .image: return "photo"
        case .files: return "doc.fill"
        }
    }

    /// The whole text is a single web link.
    var link: URL? {
        guard case .text(let string) = content else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    /// The whole text is a hex colour like #FF8800 or #f80.
    var color: NSColor? {
        guard case .text(let string) = content else { return nil }
        var hex = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Pixel size of a copied image or image file ("1440 × 900").
    var imageDimensions: String? {
        switch content {
        case .image(let image):
            guard let rep = image.representations.first, rep.pixelsWide > 0 else { return nil }
            return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
        case .files(let urls):
            guard thumbnail != nil, let url = urls.first,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            return "\(w) × \(h)"
        case .text:
            return nil
        }
    }

    /// Name shown next to an image thumbnail.
    var imageTitle: String {
        if case .files(let urls) = content, let url = urls.first { return url.lastPathComponent }
        return "Image"
    }

    var text: String? {
        if case .text(let string) = content { return string }
        return nil
    }

    /// Single-line text that looks like a file system path.
    var isPath: Bool {
        guard case .text(let string) = content else { return false }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")) && !trimmed.contains("\n")
    }

    /// What a drag out of the island carries.
    var itemProvider: NSItemProvider {
        switch content {
        case .text(let string):
            return NSItemProvider(object: string as NSString)
        case .image(let image):
            return NSItemProvider(object: image)
        case .files(let urls):
            return NSItemProvider(contentsOf: urls[0]) ?? NSItemProvider(object: urls[0] as NSURL)
        }
    }
}

extension ClipItem {
    /// Short single-line description for previews.
    var summary: String {
        switch content {
        case .text(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if isPath {
                let home = NSHomeDirectory()
                return trimmed.hasPrefix(home) ? "~" + trimmed.dropFirst(home.count) : trimmed
            }
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            return "\u{201C}" + firstLine + "\u{201D}"
        case .image:
            return "Image"
        case .files(let urls):
            return urls.count > 1 ? "\(urls.count) files" : urls[0].lastPathComponent
        }
    }
}
