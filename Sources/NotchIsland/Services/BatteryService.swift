import Combine
import Foundation
import IOKit.ps

/// Battery state via IOKit power-source notifications (no polling).
final class BatteryService: ObservableObject {
    @Published private(set) var level: Int = 100
    @Published private(set) var isCharging = false
    @Published private(set) var isPluggedIn = false
    @Published private(set) var isFull = false
    @Published private(set) var hasBattery = false
    @Published private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Minutes, nil while macOS is still calculating.
    @Published private(set) var minutesToEmpty: Int?
    @Published private(set) var minutesToFull: Int?

    /// The charger was just connected (not fired for the state at launch).
    let chargerConnected = PassthroughSubject<Void, Never>()

    private var runLoopSource: CFRunLoopSource?
    private var lowPowerObserver: NSObjectProtocol?

    init() {
        update()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            Unmanaged<BatteryService>.fromOpaque(context).takeUnretainedValue().update()
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            // Common modes: keep hearing about the charger while menus are open or the UI is busy.
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let lowPowerObserver {
            NotificationCenter.default.removeObserver(lowPowerObserver)
        }
    }

    /// Short human status: "Full in 45m", "3h 10m left", "Charged", "Not charging".
    var statusText: String? {
        if isPluggedIn {
            if isFull { return "Charged" }
            if isCharging {
                if let m = minutesToFull { return "Full in \(Self.format(m))" }
                return "Charging"
            }
            return "Not charging"   // e.g. Optimized Battery Charging holding at 80%
        }
        if let m = minutesToEmpty { return "\(Self.format(m)) left" }
        return nil
    }

    static func format(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    func update() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }

            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let newLevel = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : 0
            let newCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let newPlugged = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let newFull = (desc[kIOPSIsChargedKey] as? Bool ?? false) || (newPlugged && newLevel >= 100)
            let toEmpty = (desc[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            let toFull = (desc[kIOPSTimeToFullChargeKey] as? Int).flatMap { $0 > 0 ? $0 : nil }

            let wasKnown = hasBattery
            if wasKnown && newPlugged != isPluggedIn {
                Log.battery.notice("power changed — plugged in: \(newPlugged, privacy: .public), charging: \(newCharging, privacy: .public), level: \(newLevel, privacy: .public)%")
            }
            if wasKnown && newPlugged && !isPluggedIn {
                // Publish after the new values are in place, so the alert shows the right level.
                DispatchQueue.main.async { [weak self] in self?.chargerConnected.send() }
            }
            if !hasBattery { hasBattery = true }
            if newLevel != level { level = newLevel }
            if newCharging != isCharging { isCharging = newCharging }
            if newPlugged != isPluggedIn { isPluggedIn = newPlugged }
            if newFull != isFull { isFull = newFull }
            if toEmpty != minutesToEmpty { minutesToEmpty = toEmpty }
            if toFull != minutesToFull { minutesToFull = toFull }
            return
        }
    }
}
