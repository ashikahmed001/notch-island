import Combine
import Foundation
import Network

/// Internet connection, from macOS's own network monitor (event-driven, no polling).
final class NetworkService: ObservableObject {
    @Published private(set) var isOnline = true
    /// "Wi-Fi", "Ethernet", "iPhone hotspot"… for the "Back online" banner.
    @Published private(set) var connectionName = "Connected"

    /// Offline for a few seconds (brief drops — switching Wi-Fi, waking up — don't count).
    let wentOffline = PassthroughSubject<Void, Never>()
    /// Back online after an announced outage.
    let cameOnline = PassthroughSubject<Void, Never>()

    private let monitor = NWPathMonitor()
    private var hasInitialState = false
    private var pendingOffline: DispatchWorkItem?
    private var announcedOffline = false
    private static let graceSeconds: TimeInterval = 4

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let name: String
            if path.isExpensive && path.usesInterfaceType(.wifi) { name = "Personal Hotspot" }
            else if path.usesInterfaceType(.wifi) { name = "Wi-Fi" }
            else if path.usesInterfaceType(.wiredEthernet) { name = "Ethernet" }
            else if path.usesInterfaceType(.cellular) { name = "Cellular" }
            else { name = "Connected" }
            DispatchQueue.main.async { self?.update(online: online, name: name) }
        }
        monitor.start(queue: DispatchQueue(label: "NotchIsland.Network", qos: .utility))
    }

    deinit { monitor.cancel() }

    private func update(online: Bool, name: String) {
        if connectionName != name { connectionName = name }
        // The first report is just how things are at launch.
        guard hasInitialState else {
            hasInitialState = true
            isOnline = online
            return
        }
        guard online != isOnline else { return }
        isOnline = online
        pendingOffline?.cancel()
        if !online {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isOnline else { return }
                self.announcedOffline = true
                Log.island.notice("internet connection lost")
                self.wentOffline.send()
            }
            pendingOffline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.graceSeconds, execute: work)
        } else if announcedOffline {
            announcedOffline = false
            Log.island.notice("internet connection back (\(name, privacy: .public))")
            cameOnline.send()
        }
    }
}
