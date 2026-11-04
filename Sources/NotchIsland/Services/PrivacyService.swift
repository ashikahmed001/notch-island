import AppKit
import Combine
import CoreAudio
import CoreMediaIO
import Darwin

/// An app using the microphone (helpers like "Google Chrome Helper" are folded into their app).
struct PrivacyApp: Equatable, Identifiable {
    /// The app bundle path (or the executable name for command-line tools).
    let id: String
    let name: String
    let appURL: URL?
    let icon: NSImage?
    let pid: pid_t

    static func == (lhs: PrivacyApp, rhs: PrivacyApp) -> Bool { lhs.id == rhs.id }
}

/// Which apps are using the microphone and whether the camera is on — the same moments
/// macOS shows its orange / green dot for.
///
/// - Microphone, per app: Core Audio's process objects (macOS 14+). On macOS 13 only
///   "something is recording" is known.
/// - Camera: CoreMediaIO's "running somewhere" flag. macOS doesn't say which app.
///
/// Event-driven: Core Audio / CoreMediaIO call back when something starts or stops.
/// While something is in use, a slow safety re-check runs every few seconds.
/// No permission prompts: nothing here records or opens a device.
final class PrivacyService: ObservableObject {
    static let shared = PrivacyService()

    @Published private(set) var micApps: [PrivacyApp] = []
    @Published private(set) var micInUse = false
    @Published private(set) var cameraInUse = false

    enum Event { case mic(PrivacyApp?), camera }
    /// Something started using the mic or camera (not fired for what was already on at launch).
    let started = PassthroughSubject<Event, Never>()

    var isActive: Bool { micInUse || cameraInUse }

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            queue.async { [weak self] in self?.isEnabled == true ? self?.start() : self?.stop() }
        }
    }

    private let queue = DispatchQueue(label: "NotchIsland.Privacy", qos: .utility)
    private let ownPID = getpid()
    private var running = false
    private var hasBaseline = false
    private var refreshWork: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?
    private var appCache: [pid_t: PrivacyApp?] = [:]

    // Last published state (read on the queue).
    private var lastMicIDs: Set<String> = []
    private var lastMicInUse = false
    private var lastCamera = false

    private struct AudioListener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private struct CameraListener {
        let object: CMIOObjectID
        var address: CMIOObjectPropertyAddress
        let block: CMIOObjectPropertyListenerBlock
    }
    private var audioListeners: [AudioListener] = []
    private var cameraListeners: [CameraListener] = []

    private init() {}

    // MARK: - Lifecycle (on the queue)

    private func start() {
        guard !running else { return }
        running = true
        hasBaseline = false
        registerAudio()
        registerCamera()
        refresh()
    }

    private func stop() {
        guard running else { return }
        running = false
        unregisterAudio()
        unregisterCamera()
        refreshWork?.cancel()
        watchdog?.cancel()
        watchdog = nil
        appCache.removeAll()
        lastMicIDs = []; lastMicInUse = false; lastCamera = false
        DispatchQueue.main.async { [weak self] in
            self?.micApps = []
            self?.micInUse = false
            self?.cameraInUse = false
        }
    }

    /// Coalesce bursts of callbacks; also skips sub-second blips (an app probing the mic).
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        queue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - State

    private func refresh() {
        guard running else { return }
        let apps = currentMicApps()
        let micOn: Bool
        if #available(macOS 14.0, *) { micOn = !apps.isEmpty } else { micOn = anyInputDeviceRunning() }
        let cameraOn = anyCameraRunning()

        let ids = Set(apps.map(\.id))
        var events: [Event] = []
        if hasBaseline {
            for app in apps where !lastMicIDs.contains(app.id) { events.append(.mic(app)) }
            // macOS 13: no per-app info, just "the mic came on".
            if apps.isEmpty, micOn, !lastMicInUse { events.append(.mic(nil)) }
            if cameraOn, !lastCamera { events.append(.camera) }
        }
        hasBaseline = true
        lastMicIDs = ids; lastMicInUse = micOn; lastCamera = cameraOn
        updateWatchdog(active: micOn || cameraOn)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled else { return }
            if self.micApps != apps { self.micApps = apps }
            if self.micInUse != micOn { self.micInUse = micOn }
            if self.cameraInUse != cameraOn { self.cameraInUse = cameraOn }
            for event in events { self.started.send(event) }
        }
    }

    /// Callbacks can be missed (a device unplugged mid-call); re-check slowly while in use.
    private func updateWatchdog(active: Bool) {
        if active, watchdog == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in self?.refresh() }
            timer.resume()
            watchdog = timer
        } else if !active, let timer = watchdog {
            timer.cancel()
            watchdog = nil
        }
    }

    // MARK: - Microphone

    private var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    private func currentMicApps() -> [PrivacyApp] {
        guard #available(macOS 14.0, *) else { return [] }
        var seen = Set<String>()
        var apps: [PrivacyApp] = []
        for process in audioIDs(systemObject, AudioObjectPropertySelector(kAudioHardwarePropertyProcessObjectList)) {
            guard audioUInt32(process, AudioObjectPropertySelector(kAudioProcessPropertyIsRunningInput)) == 1,
                  let pid = audioPID(process), pid != ownPID,
                  let app = resolveApp(pid), !seen.contains(app.id) else { continue }
            seen.insert(app.id)
            apps.append(app)
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func inputDevices() -> [AudioObjectID] {
        audioIDs(systemObject, AudioObjectPropertySelector(kAudioHardwarePropertyDevices)).filter { device in
            var address = AudioObjectPropertyAddress(mSelector: AudioObjectPropertySelector(kAudioDevicePropertyStreams),
                                                     mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeInput),
                                                     mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
        }
    }

    private func anyInputDeviceRunning() -> Bool {
        inputDevices().contains {
            audioUInt32($0, AudioObjectPropertySelector(kAudioDevicePropertyDeviceIsRunningSomewhere)) == 1
        }
    }

    private func registerAudio() {
        let reRegister: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            self.unregisterAudio()
            self.registerAudio()
            self.scheduleRefresh()
        }
        let changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh() }

        addAudio(systemObject, AudioObjectPropertySelector(kAudioHardwarePropertyDevices), reRegister)
        for device in inputDevices() {
            addAudio(device, AudioObjectPropertySelector(kAudioDevicePropertyDeviceIsRunningSomewhere), changed)
        }
        if #available(macOS 14.0, *) {
            addAudio(systemObject, AudioObjectPropertySelector(kAudioHardwarePropertyProcessObjectList), reRegister)
            // A second app can start recording while the device is already running.
            for process in audioIDs(systemObject, AudioObjectPropertySelector(kAudioHardwarePropertyProcessObjectList)) {
                addAudio(process, AudioObjectPropertySelector(kAudioProcessPropertyIsRunningInput), changed)
            }
        }
    }

    private func addAudio(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                                                 mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            audioListeners.append(AudioListener(object: object, address: address, block: block))
        }
    }

    private func unregisterAudio() {
        for var listener in audioListeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, queue, listener.block)
        }
        audioListeners.removeAll()
    }

    private func audioIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                                                 mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func audioUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                                                 mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @available(macOS 14.0, *)
    private func audioPID(_ process: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(mSelector: AudioObjectPropertySelector(kAudioProcessPropertyPID),
                                                 mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                                                 mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr, pid > 0 else { return nil }
        return pid
    }

    // MARK: - Camera

    private var cameraSystemObject: CMIOObjectID { CMIOObjectID(kCMIOObjectSystemObject) }

    private func cmioAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private func cameraDevices() -> [CMIOObjectID] {
        var address = cmioAddress(Int(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(cameraSystemObject, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(cameraSystemObject, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private func anyCameraRunning() -> Bool {
        cameraDevices().contains { device in
            var address = cmioAddress(Int(kCMIODevicePropertyDeviceIsRunningSomewhere))
            var value: UInt32 = 0
            var used: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
            return status == noErr && value != 0
        }
    }

    private func registerCamera() {
        let reRegister: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            self.unregisterCamera()
            self.registerCamera()
            self.scheduleRefresh()
        }
        let changed: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh() }
        addCamera(cameraSystemObject, Int(kCMIOHardwarePropertyDevices), reRegister)
        for device in cameraDevices() {
            addCamera(device, Int(kCMIODevicePropertyDeviceIsRunningSomewhere), changed)
        }
    }

    private func addCamera(_ object: CMIOObjectID, _ selector: Int, _ block: @escaping CMIOObjectPropertyListenerBlock) {
        var address = cmioAddress(selector)
        if CMIOObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            cameraListeners.append(CameraListener(object: object, address: address, block: block))
        }
    }

    private func unregisterCamera() {
        for var listener in cameraListeners {
            CMIOObjectRemovePropertyListenerBlock(listener.object, &listener.address, queue, listener.block)
        }
        cameraListeners.removeAll()
    }

    // MARK: - Process → app

    /// System daemons (e.g. "Hey Siri" listening) aren't apps the user started; skip them.
    private static let systemPrefixes = ["/System/Library/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"]

    private func resolveApp(_ pid: pid_t) -> PrivacyApp? {
        if let cached = appCache[pid] { return cached }
        let app = lookUpApp(pid)
        appCache[pid] = .some(app)
        return app
    }

    private func lookUpApp(_ pid: pid_t) -> PrivacyApp? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)

        // The outermost .app, so helpers count as their app.
        var bundlePath: String?
        var partial = ""
        for component in path.split(separator: "/") {
            partial += "/" + component
            if component.hasSuffix(".app") { bundlePath = partial; break }
        }

        if let bundlePath {
            let url = URL(fileURLWithPath: bundlePath)
            let bundle = Bundle(url: url)
            if bundle?.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
            let running = bundle?.bundleIdentifier.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
            }
            let name = running?.localizedName
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            let icon = NSWorkspace.shared.icon(forFile: bundlePath)
            return PrivacyApp(id: bundlePath, name: name, appURL: url, icon: icon, pid: running?.processIdentifier ?? pid)
        }

        // A command-line tool (sox, ffmpeg, whisper…) — but not a system daemon.
        if Self.systemPrefixes.contains(where: path.hasPrefix) { return nil }
        let name = (path as NSString).lastPathComponent
        return PrivacyApp(id: path, name: name, appURL: nil, icon: nil, pid: pid)
    }
}
