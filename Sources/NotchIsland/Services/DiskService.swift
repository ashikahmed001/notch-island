import AppKit
import Combine
import DiskArbitration

/// External drives: "Safe to unplug" after an eject, and — when an eject fails —
/// which apps are still using the drive.
///
/// Disk Arbitration tells us when anyone asks to unmount a drive (Finder, Disk Utility,
/// `diskutil`). If the drive is still there a few seconds later, the eject failed; `lsof`
/// then lists the processes with files open on it.
final class DiskService {
    static let shared = DiskService()

    struct Volume: Equatable {
        let url: URL
        let name: String
    }

    /// Something holding a drive open.
    struct Blocker: Equatable {
        let pid: pid_t
        let name: String
        /// A regular app the user can quit (not a background process).
        let isApp: Bool
    }

    /// Ejected: the drive's name.
    let unmounted = PassthroughSubject<String, Never>()
    /// An eject that didn't happen: the drive and who's using it (may be empty).
    let ejectFailed = PassthroughSubject<(volume: Volume, blockers: [Blocker]), Never>()

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    private var session: DASession?
    /// Keyed by path (URLs may or may not end in "/").
    private var known: [String: Volume] = [:]
    private var pendingChecks: [String: DispatchWorkItem] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Drives

    /// Mounted external drives (not the internal disk, disk images or network shares).
    static func externalVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeLocalizedNameKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> Volume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsInternal == false, values.volumeIsLocal != false,
                  values.volumeIsRootFileSystem != true,
                  !isDiskImage(url) else { return nil }
            return Volume(url: url.standardizedFileURL, name: values.volumeLocalizedName ?? url.lastPathComponent)
        }
    }

    private static func isDiskImage(_ url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let info = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        let model = info[kDADiskDescriptionDeviceModelKey as String] as? String
        let proto = info[kDADiskDescriptionDeviceProtocolKey as String] as? String
        return model == "Disk Image" || proto == "Disk Image"
    }

    // MARK: - Lifecycle

    private func start() {
        refreshKnown()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshKnown()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path,
                  let volume = self.known.removeValue(forKey: path) else { return }
            self.pendingChecks.removeValue(forKey: path)?.cancel()
            self.unmounted.send(volume.name)
        })

        // Hear about every unmount request (Finder, Disk Utility, diskutil…). We always
        // approve: this is only to notice an eject that then fails.
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskUnmountApprovalCallback(session, nil, { disk, context in
            guard let context else { return nil }
            let service = Unmanaged<DiskService>.fromOpaque(context).takeUnretainedValue()
            if let info = DADiskCopyDescription(disk) as? [String: Any],
               let url = info[kDADiskDescriptionVolumePathKey as String] as? URL {
                service.unmountRequested(url.path)
            }
            return nil
        }, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        pendingChecks.values.forEach { $0.cancel() }
        pendingChecks.removeAll()
        if let session { DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) }
        session = nil
    }

    private func refreshKnown() {
        var map: [String: Volume] = [:]
        for volume in Self.externalVolumes() { map[volume.url.path] = volume }
        known = map
    }

    // MARK: - Failed ejects

    private func unmountRequested(_ path: String) {
        guard let volume = known[path] else { return }
        pendingChecks[path]?.cancel()
        // Unmounting can take a moment (writing caches). Still there after 6 s → it failed.
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.known[path] != nil else { return }
            self.pendingChecks[path] = nil
            guard Self.externalVolumes().contains(where: { $0.url.path == path }) else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let blockers = Self.blockers(of: volume.url)
                DispatchQueue.main.async { self.ejectFailed.send((volume, blockers)) }
            }
        }
        pendingChecks[path] = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: check)
    }

    /// Processes with files open on the drive (`lsof` sees your own processes, not system ones).
    static func blockers(of url: URL) -> [Blocker] {
        guard let output = SystemProgressService.run("/usr/sbin/lsof", ["-F", "pc", "+f", "--", url.path], timeout: 8) else { return [] }
        var result: [Blocker] = []
        var seen = Set<pid_t>()
        var pid: pid_t?
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            if tag == "p" {
                pid = pid_t(value)
            } else if tag == "c", let current = pid, current != getpid(), seen.insert(current).inserted {
                if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                    result.append(Blocker(pid: current, name: app.localizedName ?? value, isApp: true))
                } else {
                    result.append(Blocker(pid: current, name: value, isApp: false))
                }
            }
        }
        // Apps first: those are the ones you can quit.
        return result.sorted { $0.isApp && !$1.isApp }
    }

    /// Quit the given apps, then try the eject again.
    func quitAndEject(_ pids: [pid_t], volume url: URL) {
        for pid in pids { NSRunningApplication(processIdentifier: pid)?.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (pids.isEmpty ? 0 : 1.5)) {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                Log.island.notice("eject retry failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
