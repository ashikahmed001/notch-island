import Combine
import Foundation

/// Watches the folder macOS saves screenshots to and reports each new one.
/// (Screenshots taken straight to the clipboard already arrive via ClipboardService.)
final class ScreenshotService {
    /// A new screenshot (or screen recording) file.
    let captured = PassthroughSubject<URL, Never>()

    /// Feature flag. Starts off; the app enables it after launch.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { start() } else { stop() }
        }
    }

    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var folder = ScreenshotService.screenshotFolder

    /// The user's screenshot location (Screenshot app ▸ Options ▸ Save to), or the Desktop.
    static var screenshotFolder: URL {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !location.isEmpty {
            return URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    private func start() {
        folder = Self.screenshotFolder
        known = Set(names())
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.scan() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func stop() {
        source?.cancel()
        source = nil
    }

    private func names() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private func scan() {
        let current = Set(names())
        let added = current.subtracting(known)
        known = current
        // macOS writes a hidden temp file first, then renames it — ignore dot files.
        for name in added.sorted() where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            if Self.isScreenshot(url) { captured.send(url) }
        }
    }

    /// macOS tags its captures with kMDItemIsScreenCapture; fall back to the default names.
    static func isScreenshot(_ url: URL) -> Bool {
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0 { return true }
        let name = url.lastPathComponent
        return name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot") || name.hasPrefix("Screen Recording")
    }
}
