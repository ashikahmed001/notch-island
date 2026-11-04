import AppKit
import Combine

/// Download progress from any browser that publishes file progress to Finder
/// (Safari, Chrome, Edge, Arc, Brave…), via NSProgress file subscriptions on ~/Downloads.
final class DownloadsService: ObservableObject {
    struct Download: Equatable {
        let name: String
        /// nil while the total size is unknown.
        var fraction: Double?
        var bytesDone: Int64?
        var bytesTotal: Int64?
        /// Estimated from the average speed so far (nil for the first couple of seconds).
        var secondsLeft: Double?
        /// The browser that was in front when the download started (for its icon).
        var browserBundleID: String?
        /// How many downloads this stands for (the combined one shows "3 downloads").
        var count = 1

        /// "12.4 MB of 240 MB · 2 min left"
        var detail: String? {
            var parts: [String] = []
            if let done = bytesDone, let total = bytesTotal, total > 0 {
                parts.append("\(Self.bytes(done)) of \(Self.bytes(total))")
            } else if let done = bytesDone, done > 0 {
                parts.append(Self.bytes(done))
            }
            if let left = secondsLeft { parts.append(Self.timeLeft(left)) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        var browserName: String? {
            guard let id = browserBundleID,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }

        static func bytes(_ count: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
        }

        static func timeLeft(_ seconds: Double) -> String {
            if seconds < 10 { return "almost done" }
            if seconds < 60 { return "\(Int(seconds)) s left" }
            let minutes = Int((seconds / 60).rounded(.up))
            if minutes < 60 { return "\(minutes) min left" }
            return "\(minutes / 60) h \(minutes % 60) min left"
        }
    }

    /// Browsers whose icon we show (whichever was in front when the download began).
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// Everything in progress, as one: a single download, or "3 downloads" with combined progress.
    @Published private(set) var active: Download?
    /// Each download in progress, oldest first.
    @Published private(set) var all: [Download] = []

    /// A download finished and the file is in place.
    let finished = PassthroughSubject<URL, Never>()
    /// A download was cancelled, or stopped without producing a file.
    let failed = PassthroughSubject<(name: String, cancelled: Bool), Never>()

    /// Feature flag. Starts off; the app enables it after launch.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { start() } else { stop() }
        }
    }

    private struct Entry {
        let progress: Progress
        let url: URL?
        let started: Date
        let startBytes: Int64
        let browser: String?
        let observation: NSKeyValueObservation
    }

    private var subscriber: Any?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var lastPublish = Date.distantPast

    /// Temporary extensions browsers use while downloading.
    private static let tempExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Lifecycle

    private func start() {
        Log.downloads.notice("watching \(Self.downloadsFolder.path, privacy: .public)")
        subscriber = Progress.addSubscriber(forFileURL: Self.downloadsFolder) { [weak self] progress in
            DispatchQueue.main.async { self?.track(progress) }
            return { DispatchQueue.main.async { self?.untrack(progress) } }
        }
    }

    private func stop() {
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        entries.values.forEach { $0.observation.invalidate() }
        entries.removeAll()
        active = nil
    }

    // MARK: - Tracking

    private func track(_ progress: Progress) {
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.publish() }
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        entries[ObjectIdentifier(progress)] = Entry(
            progress: progress, url: progress.fileURL, started: Date(),
            startBytes: progress.completedUnitCount,
            browser: front.flatMap { Self.browsers.contains($0) ? $0 : nil },
            observation: observation
        )
        Log.downloads.notice("download started: \(progress.fileURL?.lastPathComponent ?? "unknown", privacy: .public)")
        publish(force: true)
    }

    private func untrack(_ progress: Progress) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(progress)) else { return }
        entry.observation.invalidate()
        publish(force: true)

        Log.downloads.notice("download ended: \(entry.url?.lastPathComponent ?? "unknown", privacy: .public) — \(progress.isCancelled ? "cancelled" : "done", privacy: .public) at \(Int(progress.fractionCompleted * 100), privacy: .public)%")
        let name = snapshot(entry, now: Date()).name
        guard !progress.isCancelled else {
            failed.send((name, true))
            return
        }
        let reachedEnd = progress.isFinished || progress.fractionCompleted >= 0.99

        // Browsers rename the temp file right after finishing ("Unconfirmed 123.crdownload",
        // "x.download" → the real name), so look by the latest name, the first name, and
        // finally for the newest file that appeared in Downloads since the download began.
        let candidates = [progress.fileURL, entry.url].compactMap { $0 }.map(Self.finalURL)
        let started = entry.started
        let lookup: () -> URL? = {
            for url in candidates where FileManager.default.fileExists(atPath: url.path)
                && !Self.tempExtensions.contains(url.pathExtension.lowercased()) {
                return url
            }
            return Self.newestFile(since: started)
        }
        let deliver: (URL) -> Void = { [weak self] url in
            guard let self, self.announced.insert(url.path).inserted else { return }
            Log.downloads.notice("download saved: \(url.lastPathComponent, privacy: .public)")
            self.finished.send(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let url = lookup() { return deliver(url) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let url = lookup() { deliver(url) } else {
                    Log.downloads.notice("download ended but no new file found in Downloads")
                    // Stopped part-way with nothing saved: the browser gave up (network, disk…).
                    if !reachedEnd { self.failed.send((name, false)) }
                }
            }
        }
    }

    /// Paths already announced as finished (a rename can look like a second download).
    private var announced = Set<String>()

    /// The newest real file (not a browser temp file) added to Downloads since `date`.
    private static func newestFile(since date: Date) -> URL? {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: downloadsFolder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        let cutoff = date.addingTimeInterval(-2)
        return items
            .filter { !tempExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true || values.isPackage == true else { return nil }
                let stamp = max(values.creationDate ?? .distantPast, values.contentModificationDate ?? .distantPast)
                return stamp >= cutoff ? (url, stamp) : nil
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// Throttled to ~4 updates a second so the island isn't redrawn on every byte.
    private func publish(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublish) > 0.25 else { return }
        lastPublish = now

        let sorted = entries.values.sorted { $0.started < $1.started }
        guard let newest = sorted.last else {
            if active != nil { active = nil }
            if !all.isEmpty { all = [] }
            return
        }
        let list = sorted.map { snapshot($0, now: now) }
        if list != all { all = list }

        var combined: Download
        if list.count == 1 {
            combined = list[0]
        } else {
            // Byte-weighted progress when every download knows its size, else the average.
            let totals = list.compactMap(\.bytesTotal)
            let fraction: Double?
            if totals.count == list.count, totals.reduce(0, +) > 0 {
                fraction = Double(list.compactMap(\.bytesDone).reduce(0, +)) / Double(totals.reduce(0, +))
            } else {
                let known = list.compactMap(\.fraction)
                fraction = known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
            }
            combined = Download(
                name: "\(list.count) downloads",
                fraction: fraction.map { min(max($0, 0), 1) },
                bytesDone: totals.count == list.count ? list.compactMap(\.bytesDone).reduce(0, +) : nil,
                bytesTotal: totals.count == list.count ? totals.reduce(0, +) : nil,
                secondsLeft: list.compactMap(\.secondsLeft).max(),
                browserBundleID: newest.browser
            )
            combined.count = list.count
        }
        if combined != active { active = combined }
    }

    private func snapshot(_ entry: Entry, now: Date) -> Download {
        let progress = entry.progress
        // The browser may only name the file a moment after starting — read it fresh each time.
        // Chrome keeps "Unconfirmed 123456.crdownload" until the end; then try the address it's
        // downloading from, and finally "File from Chrome".
        let fileURL = progress.fileURL ?? entry.url
        var name = fileURL.map { Self.displayName(for: $0) }
        if name == nil || name == Self.unnamed {
            name = fileURL.flatMap(Self.nameFromSource)
        }
        if name == nil || name == Self.unnamed {
            name = entry.browser.flatMap { id in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map {
                    "File from " + FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
                }
            } ?? "Downloading file"
        }
        let finalName = name ?? "Downloading file"
        let fraction = progress.isIndeterminate ? nil : min(max(progress.fractionCompleted, 0), 1)

        // File progress counts bytes; small totals are likely percent-style units, so skip those.
        let total = progress.totalUnitCount
        let done = progress.completedUnitCount
        let countsBytes = total > 1024 || (total <= 0 && done > 1024)
        var secondsLeft: Double?
        let elapsed = now.timeIntervalSince(entry.started)
        if countsBytes, total > 0, elapsed > 2, done > entry.startBytes {
            let speed = Double(done - entry.startBytes) / elapsed
            if speed > 0 { secondsLeft = Double(total - done) / speed }
        }
        return Download(
            name: finalName,
            fraction: fraction,
            bytesDone: countsBytes ? done : nil,
            bytesTotal: countsBytes && total > 0 ? total : nil,
            secondsLeft: secondsLeft,
            browserBundleID: entry.browser
        )
    }

    private static let unnamed = "\u{0}unnamed"

    /// "report.pdf" — or `unnamed` while Chrome still calls it "Unconfirmed 123456".
    static func displayName(for url: URL) -> String {
        let name = finalURL(for: url).lastPathComponent
        return name.hasPrefix("Unconfirmed ") || name.isEmpty ? unnamed : name
    }

    /// The file name from the address the browser is downloading from, if it tagged the file
    /// with one ("Where from" in Finder's Get Info). Cached per file.
    private static var sourceNames: [String: String?] = [:]

    static func nameFromSource(_ url: URL) -> String? {
        if let cached = sourceNames[url.path] { return cached }
        var result: String?
        let attribute = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        if size > 0 {
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, 0) }
            if read > 0,
               let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String],
               let source = list.first.flatMap(URL.init(string:)) {
                let last = source.lastPathComponent.removingPercentEncoding ?? source.lastPathComponent
                if !last.isEmpty, last != "/", last.contains(".") { result = last }
            }
        }
        // Only remember a hit; a miss may turn into a hit once the browser tags the file.
        if result != nil { sourceNames[url.path] = result }
        return result
    }

    static func finalURL(for url: URL) -> URL {
        var result = url
        while tempExtensions.contains(result.pathExtension.lowercased()) {
            result = result.deletingPathExtension()
        }
        return result
    }
}
