import AppKit
import Combine

/// Long system jobs macOS only shows if you go looking:
/// - Time Machine backups (`tmutil status`, checked slowly while idle, often while running);
/// - Finder copies onto external drives (the progress Finder publishes for files it writes
///   to a drive's top folder — the same mechanism the Downloads feature uses).
final class SystemProgressService: ObservableObject {
    static let shared = SystemProgressService()

    struct Activity: Equatable {
        enum Kind: Equatable { case backup, copy }
        let kind: Kind
        /// "Backing up" / "Copying to Backup".
        var title: String
        /// "Looking for changes" / "3 items · 1.2 GB of 4 GB".
        var detail: String?
        /// nil while the amount isn't known yet.
        var fraction: Double?
    }

    @Published private(set) var backup: Activity?
    @Published private(set) var copy: Activity?
    /// What the island shows: a copy you started beats a background backup.
    var current: Activity? { copy ?? backup }

    /// A copy onto a drive finished ("Copied to Backup").
    let copyFinished = PassthroughSubject<(volume: String, items: Int), Never>()

    var watchesBackups = false { didSet { if watchesBackups != oldValue { updateBackupWatching() } } }
    var watchesCopies = false { didSet { if watchesCopies != oldValue { updateCopyWatching() } } }

    private init() {}

    // MARK: - Time Machine

    private var backupTimer: Timer?
    private var checkingBackup = false

    private func updateBackupWatching() {
        backupTimer?.invalidate()
        backupTimer = nil
        guard watchesBackups else {
            backup = nil
            return
        }
        scheduleBackupCheck(after: 2)
    }

    /// Idle: once a minute (two in Battery saver). Running: every 4 seconds.
    private func scheduleBackupCheck(after seconds: TimeInterval) {
        backupTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.checkBackup() }
        timer.tolerance = seconds * 0.25
        RunLoop.main.add(timer, forMode: .common)
        backupTimer = timer
    }

    private func checkBackup() {
        guard watchesBackups, !checkingBackup else { return }
        checkingBackup = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = Self.readBackupStatus()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingBackup = false
                guard self.watchesBackups else { return }
                if self.backup != status { self.backup = status }
                let idle: TimeInterval = Energy.saver ? 120 : 60
                self.scheduleBackupCheck(after: status == nil ? idle : 4)
            }
        }
    }

    /// Parses `tmutil status`, e.g. `Running = 1; BackupPhase = Copying; Percent = "0.42";`.
    private static func readBackupStatus() -> Activity? {
        guard let text = run("/usr/bin/tmutil", ["status"]), text.contains("Running = 1") else { return nil }
        let phase = firstMatch(#"BackupPhase = "?([A-Za-z]+)"?;"#, in: text)
        var fraction = firstMatch(#"\bPercent = "?(-?[0-9.]+)"?;"#, in: text).flatMap(Double.init)
        if let value = fraction, value < 0 || value > 1 { fraction = nil }

        let detail: String?
        switch phase {
        case "Starting", "MountingBackupVol", "MountingDiskImage", "PreparingSourceVolumes":
            detail = String(localized: "Preparing")
        case "FindingChanges", "FindingBackupVol", "SizingChanges":
            detail = String(localized: "Looking for changes")
        case "Copying":
            if let remaining = firstMatch(#"TimeRemaining = "?([0-9.]+)"?;"#, in: text).flatMap(Double.init), remaining > 0 {
                detail = String(localized: "About \(Self.minutes(remaining)) left")
            } else {
                detail = nil
            }
        case "ThinningPreBackup", "ThinningPostBackup", "DeletingOldBackups":
            detail = String(localized: "Cleaning up old backups")
        case "Finishing", "Stopping":
            detail = String(localized: "Finishing")
        default:
            detail = nil
        }
        return Activity(kind: .backup, title: String(localized: "Backing up"), detail: detail,
                        fraction: phase == "Copying" ? fraction : nil)
    }

    private static func minutes(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Runs a small tool and returns its output (gives up after 5 seconds).
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Stuck tool: stop it, which also ends the read below.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // returns when the tool exits
        process.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Copies to external drives

    private struct CopyEntry {
        let progress: Progress
        let volume: String
        let observation: NSKeyValueObservation
    }
    private var copySubscribers: [URL: Any] = [:]
    private var copies: [ObjectIdentifier: CopyEntry] = [:]
    private var mountObservers: [NSObjectProtocol] = []
    private var copiedItems: [String: Int] = [:]

    private func updateCopyWatching() {
        if watchesCopies {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
                mountObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.resubscribeVolumes()
                })
            }
            resubscribeVolumes()
        } else {
            mountObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
            mountObservers.removeAll()
            copySubscribers.values.forEach { Progress.removeSubscriber($0) }
            copySubscribers.removeAll()
            copies.values.forEach { $0.observation.invalidate() }
            copies.removeAll()
            copy = nil
        }
    }

    /// One subscription per external drive (top folder).
    private func resubscribeVolumes() {
        let volumes = Set(DiskService.externalVolumes().map(\.url))
        for (url, subscriber) in copySubscribers where !volumes.contains(url) {
            Progress.removeSubscriber(subscriber)
            copySubscribers[url] = nil
        }
        for url in volumes where copySubscribers[url] == nil {
            let name = url.lastPathComponent
            copySubscribers[url] = Progress.addSubscriber(forFileURL: url) { [weak self] progress in
                DispatchQueue.main.async { self?.track(progress, volume: name) }
                return { DispatchQueue.main.async { self?.untrack(progress) } }
            }
        }
    }

    private func track(_ progress: Progress, volume: String) {
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.publishCopies() }
        }
        copies[ObjectIdentifier(progress)] = CopyEntry(progress: progress, volume: volume, observation: observation)
        publishCopies()
    }

    private func untrack(_ progress: Progress) {
        guard let entry = copies.removeValue(forKey: ObjectIdentifier(progress)) else { return }
        entry.observation.invalidate()
        if !progress.isCancelled { copiedItems[entry.volume, default: 0] += 1 }
        // Last one onto this drive finished → "Copied to Backup".
        if !copies.values.contains(where: { $0.volume == entry.volume }) {
            let count = copiedItems.removeValue(forKey: entry.volume) ?? 0
            if count > 0 { copyFinished.send((entry.volume, count)) }
        }
        publishCopies()
    }

    private var lastCopyPublish = Date.distantPast

    private func publishCopies() {
        guard let first = copies.values.first else {
            copy = nil
            return
        }
        // Fraction updates arrive many times a second; the ring only needs a few.
        let now = Date()
        if copy != nil, now.timeIntervalSince(lastCopyPublish) < 0.25 { return }
        lastCopyPublish = now

        let entries = Array(copies.values)
        let total = entries.reduce(Int64(0)) { $0 + max(0, $1.progress.totalUnitCount) }
        let done = entries.reduce(Int64(0)) { $0 + max(0, $1.progress.completedUnitCount) }
        let fraction: Double? = total > 0 ? min(1, Double(done) / Double(total))
            : entries.map(\.progress.fractionCompleted).reduce(0, +) / Double(entries.count)
        var parts: [String] = []
        if entries.count > 1 { parts.append(String(localized: "\(entries.count) items")) }
        if total > 1_000_000 {
            let formatter = ByteCountFormatter()
            parts.append("\(formatter.string(fromByteCount: done)) / \(formatter.string(fromByteCount: total))")
        }
        let activity = Activity(kind: .copy, title: String(localized: "Copying to \(first.volume)"),
                                detail: parts.isEmpty ? nil : parts.joined(separator: " · "),
                                fraction: fraction)
        if copy != activity { copy = activity }
    }
}
