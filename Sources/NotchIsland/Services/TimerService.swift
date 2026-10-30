import AppKit
import Combine

/// Countdown timer. Remaining time is derived from an end date, so it stays
/// accurate without a per-second tick (views use TimelineView to redraw).
final class TimerService: ObservableObject {
    enum State: Equatable { case idle, running, paused, ringing }

    @Published private(set) var state: State = .idle
    @Published private(set) var duration: TimeInterval = 0

    /// Fires when a countdown reaches zero.
    let finished = PassthroughSubject<Void, Never>()
    /// Fires on every chime while ringing (drives the island's shake).
    let chimed = PassthroughSubject<Void, Never>()

    /// Length of the most recent timer, for "Repeat".
    private(set) var lastDuration: TimeInterval = 0
    /// Feature flag: play the chime when done.
    var playsSound = true
    private var chimeTimer: Timer?
    private var chimeCount = 0

    private var endDate: Date?
    private var pausedRemaining: TimeInterval = 0
    private var finishTimer: Timer?

    func remaining(at date: Date = Date()) -> TimeInterval {
        switch state {
        case .idle, .ringing: return 0
        case .paused: return pausedRemaining
        case .running: return max(0, (endDate ?? date).timeIntervalSince(date))
        }
    }

    /// 1 → just started, 0 → done.
    func fractionRemaining(at date: Date = Date()) -> Double {
        duration > 0 ? min(1, max(0, remaining(at: date) / duration)) : 0
    }

    func start(minutes: Double) {
        start(seconds: minutes * 60)
    }

    func start(seconds: TimeInterval) {
        stopChiming()
        lastDuration = seconds
        duration = seconds
        endDate = Date().addingTimeInterval(seconds)
        state = .running
        scheduleFinish()
    }

    func pause() {
        guard state == .running else { return }
        pausedRemaining = remaining()
        finishTimer?.invalidate()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        endDate = Date().addingTimeInterval(pausedRemaining)
        state = .running
        scheduleFinish()
    }

    func addMinute() {
        switch state {
        case .idle, .ringing:
            start(seconds: 60)   // also works as "snooze" while ringing
        case .running:
            endDate = endDate?.addingTimeInterval(60)
            duration += 60
            scheduleFinish()
        case .paused:
            pausedRemaining += 60
            duration += 60
        }
    }

    /// Run the same timer again.
    func restart() {
        start(seconds: lastDuration > 0 ? lastDuration : 60)
    }

    func stop() {
        stopChiming()
        finishTimer?.invalidate()
        finishTimer = nil
        endDate = nil
        state = .idle
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func scheduleFinish() {
        finishTimer?.invalidate()
        guard let endDate else { return }
        let timer = Timer(fire: endDate, interval: 0, repeats: false) { [weak self] _ in
            self?.complete()
        }
        RunLoop.main.add(timer, forMode: .common)
        finishTimer = timer
    }

    private func complete() {
        finishTimer?.invalidate()
        finishTimer = nil
        endDate = nil
        state = .ringing
        finished.send()

        chimeCount = 0
        chime()
        // Keep ringing (chime + shake) every 2.5 s, give up after ~30 s.
        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.chimeCount += 1
            if self.chimeCount >= 12 {
                self.stop()
            } else {
                self.chime()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        chimeTimer = timer
    }

    private func chime() {
        if playsSound {
            let sound = NSSound(named: "Glass")
            sound?.stop()
            sound?.play()
        }
        chimed.send()
    }

    private func stopChiming() {
        chimeTimer?.invalidate()
        chimeTimer = nil
    }
}
