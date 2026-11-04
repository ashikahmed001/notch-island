import Foundation

/// Battery level of a Bluetooth audio device (AirPods, Beats, headphones), read from
/// `system_profiler` — public, needs no Bluetooth permission. AirPods report each bud
/// separately; the lower one is used.
enum BluetoothBattery {
    /// Calls back on the main thread with 0…100, or nil if the device doesn't report it.
    static func level(of deviceName: String, completion: @escaping (Int?) -> Void) {
        // Freshly connected devices report their battery a moment later.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            let level = read(deviceName)
            DispatchQueue.main.async { completion(level) }
        }
    }

    private static func read(_ deviceName: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Never hang: give up after 4 seconds.
        let deadline = DispatchTime.now() + 4
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry where name == deviceName {
                    guard let info = value as? [String: Any] else { continue }
                    let keys = ["device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevelMain", "device_batteryLevel"]
                    let levels = keys.compactMap { (info[$0] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) } }
                    return levels.min()
                }
            }
        }
        return nil
    }
}
