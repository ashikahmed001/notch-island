import AppKit
import Combine
import CoreAudio

/// Sound output devices (speakers, AirPods, displays, USB…) via CoreAudio:
/// lists them, switches the Mac's output, and notices headphones connecting.
final class AudioOutputService: ObservableObject {
    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: UInt32

        var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }

        /// SF Symbol that looks like the device.
        var symbol: String {
            let lower = name.lowercased()
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn:
                if lower.contains("macbook") { return "laptopcomputer" }
                if lower.contains("imac") || lower.contains("studio display") { return "desktopcomputer" }
                return "speaker.wave.2.fill"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                if lower.contains("airpods max") { return "airpodsmax" }
                if lower.contains("airpods pro") { return "airpodspro" }
                if lower.contains("airpods") { return "airpods" }
                if lower.contains("beats") { return "beats.headphones" }
                if lower.contains("homepod") { return "homepod.fill" }
                return "headphones"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
                return "tv"
            case kAudioDeviceTransportTypeAirPlay:
                return "airplayaudio"
            case kAudioDeviceTransportTypeUSB:
                return "hifispeaker.fill"
            default:
                return "speaker.wave.2.fill"
            }
        }
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var currentID: AudioDeviceID = 0
    /// A Bluetooth audio device (AirPods, headphones…) just connected.
    let connected = PassthroughSubject<Device, Never>()

    private var knownIDs = Set<AudioDeviceID>()
    private var started = false

    init() {
        refresh()
        knownIDs = Set(devices.map(\.id))
        listen(kAudioHardwarePropertyDevices)
        listen(kAudioHardwarePropertyDefaultOutputDevice)
        started = true
    }

    var current: Device? { devices.first { $0.id == currentID } }

    func select(_ device: Device) {
        var id = device.id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        currentID = device.id   // optimistic; the listener confirms
    }

    // MARK: - Internals

    private func listen(_ selector: AudioObjectPropertySelector) {
        var address = Self.address(selector)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let all = Self.allDeviceIDs().compactMap(Self.device(for:))
        let current = Self.defaultOutputID()
        // Hide virtual / aggregate devices (Teams, Zoom, BlackHole…) unless in use.
        let visible = all.filter { device in
            device.id == current ||
                (device.transport != kAudioDeviceTransportTypeVirtual && device.transport != kAudioDeviceTransportTypeAggregate)
        }
        if visible != devices { devices = visible }
        if current != currentID { currentID = current }

        if started {
            let ids = Set(visible.map(\.id))
            for device in visible where !knownIDs.contains(device.id) && device.isBluetooth {
                connected.send(device)
            }
            knownIDs = ids
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultOutputID() -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    /// Output-capable devices only.
    private static func device(for id: AudioDeviceID) -> Device? {
        var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0 else { return nil }

        var canBeDefault = address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput)
        var flag: UInt32 = 0
        var flagSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &canBeDefault, 0, nil, &flagSize, &flag) == noErr, flag == 0 { return nil }

        guard let name = string(id, kAudioObjectPropertyName) else { return nil }
        let uid = string(id, kAudioDevicePropertyDeviceUID) ?? name

        var transportAddress = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)

        return Device(id: id, uid: uid, name: name, transport: transport)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
