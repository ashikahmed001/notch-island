import Combine
import Foundation

/// Screen lock / unlock, via the system's long-standing distributed notifications.
final class LockService: ObservableObject {
    struct Unlock {
        let lockedAt: Date
        let awayFor: TimeInterval
    }

    @Published private(set) var isLocked = false
    private(set) var lockedAt: Date?

    /// Fires once per unlock with how long the Mac was locked.
    let unlocked = PassthroughSubject<Unlock, Never>()

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.isLocked else { return }
            self.lockedAt = Date()
            self.isLocked = true
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isLocked else { return }
            let since = self.lockedAt ?? Date()
            self.isLocked = false
            self.unlocked.send(Unlock(lockedAt: since, awayFor: Date().timeIntervalSince(since)))
        })
    }

    deinit {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }
}
