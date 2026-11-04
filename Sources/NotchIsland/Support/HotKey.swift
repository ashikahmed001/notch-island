import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (works whichever app is in front; no permission needed).
final class HotKey {
    /// Shortcuts offered in Settings ▸ Command Bar.
    enum Preset: String, CaseIterable, Identifiable {
        case optionSpace, controlOptionSpace, commandShiftSpace, controlSpace

        var id: String { rawValue }
        var label: String {
            switch self {
            case .optionSpace: return "⌥ Space"
            case .controlOptionSpace: return "⌃⌥ Space"
            case .commandShiftSpace: return "⇧⌘ Space"
            case .controlSpace: return "⌃ Space"
            }
        }
        var modifiers: UInt32 {
            switch self {
            case .optionSpace: return UInt32(optionKey)
            case .controlOptionSpace: return UInt32(controlKey | optionKey)
            case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
            case .controlSpace: return UInt32(controlKey)
            }
        }

        static let defaultsKey = "commandBar.shortcut"
        static var saved: Preset {
            get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Preset.init) ?? .optionSpace }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
        }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    /// False when another app already owns this shortcut.
    private(set) var isRegistered = false

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4E49_534C), id: 1)   // "NISL"
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        isRegistered = status == noErr
        if !isRegistered {
            Log.island.notice("couldn't register the Command Bar shortcut (status \(status, privacy: .public)) — another app may use it")
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
