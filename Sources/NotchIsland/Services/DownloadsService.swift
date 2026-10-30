import AppKit
import Combine

/// Download progress from any browser that publishes file progress to Finder
/// (Safari, Chrome, Edge, Arc, Brave…), via NSProgress file subscriptions on ~/Downloads.
final class DownloadsService: ObservableObject {
    struct Download: Equatable {
        let name: String
        /// nil while the total size is unknown.
        var fraction: Double?
    }

    /// The download in progress (most recent if several).
    @Published private(set) var active: Download?

    /// A download finished and the file is in place.
    let finished = PassthroughSubject<URL, Never>()

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
        entries[ObjectIdentifier(progress)] = Entry(progress: progress, url: progress.fileURL, started: Date(), observation: observation)
        publish(force: true)
    }

    private func untrack(_ progress: Progress) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(progress)) else { return }
        entry.observation.invalidate()
        publish(force: true)

        let completed = progress.isFinished || progress.fractionCompleted >= 0.99
        guard completed, !progress.isCancelled, let url = entry.url else { return }
        let final = Self.finalURL(for: url)
        // Browsers rename the temp file right after finishing — give them a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if FileManager.default.fileExists(atPath: final.path) {
                self?.finished.send(final)
            }
        }
    }

    /// Throttled to ~4 updates a second so the island isn't redrawn on every byte.
    private func publish(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublish) > 0.25 else { return }
        lastPublish = now

        guard let entry = entries.values.max(by: { $0.started < $1.started }) else {
            if active != nil { active = nil }
            return
        }
        let name = entry.url.map { Self.finalURL(for: $0).lastPathComponent } ?? "Download"
        let fraction = entry.progress.isIndeterminate ? nil : min(max(entry.progress.fractionCompleted, 0), 1)
        let download = Download(name: name, fraction: fraction)
        if download != active { active = download }
    }

    static func finalURL(for url: URL) -> URL {
        var result = url
        while tempExtensions.contains(result.pathExtension.lowercased()) {
            result = result.deletingPathExtension()
        }
        return result
    }
}
