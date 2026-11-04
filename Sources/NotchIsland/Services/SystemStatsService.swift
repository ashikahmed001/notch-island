import Foundation
import Combine
import Darwin

/// CPU load and battery level over time, for the Home graphs.
/// CPU is only sampled while the Home tab is on screen.
final class SystemStatsService: ObservableObject {
    /// 0…1, oldest first (last ~2 minutes).
    @Published private(set) var cpuHistory: [Double] = []
    /// One sample a minute for the last hour, oldest first.
    struct BatterySample: Equatable {
        let level: Double      // 0…1
        let charging: Bool
    }
    @Published private(set) var batteryHistory: [BatterySample] = []

    var cpu: Double { cpuHistory.last ?? 0 }

    /// Set while the Home tab is visible.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            cpuTimer?.invalidate()
            cpuTimer = nil
            guard isActive else { return }
            previous = nil
            _ = sampleCPU()
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tickCPU() }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            cpuTimer = timer
        }
    }

    private let battery: BatteryService
    private var cpuTimer: Timer?
    private var batteryTimer: Timer?
    private var previous: host_cpu_load_info?

    init(battery: BatteryService) {
        self.battery = battery
        // Start with the current state so the timeline isn't empty.
        batteryHistory = [currentBatterySample]
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tickBattery() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
    }

    deinit {
        cpuTimer?.invalidate()
        batteryTimer?.invalidate()
    }

    private func tickCPU() {
        guard let load = sampleCPU() else { return }
        var history = cpuHistory
        history.append(load)
        if history.count > 60 { history.removeFirst(history.count - 60) }
        cpuHistory = history
    }

    private func tickBattery() {
        var history = batteryHistory
        history.append(currentBatterySample)
        if history.count > 60 { history.removeFirst(history.count - 60) }
        batteryHistory = history
    }

    private var currentBatterySample: BatterySample {
        BatterySample(level: Double(battery.level) / 100, charging: battery.isCharging || battery.isPluggedIn)
    }

    /// Share of CPU time spent busy since the previous sample.
    private func sampleCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { self.previous = info }
        guard let previous else { return nil }
        let user = Double(info.cpu_ticks.0 &- previous.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- previous.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- previous.cpu_ticks.3)
        let total = user + system + idle + nice
        return total > 0 ? (user + system + nice) / total : nil
    }
}
