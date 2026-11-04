import AppKit
import Combine
import EventKit

/// Watches the Reminders app and announces reminders the moment they fall due.
final class ReminderService: ObservableObject {
    struct DueReminder: Equatable, Identifiable {
        let id: String
        let title: String
        let due: Date
        let list: String
        let color: NSColor

        /// One announcement per due time (a rescheduled reminder rings again).
        var key: String { "\(id)@\(due.timeIntervalSince1970)" }
    }

    @Published private(set) var hasAccess = false
    @Published private(set) var accessDenied = false
    /// Reminders that just fell due (earliest first).
    let becameDue = PassthroughSubject<[DueReminder], Never>()

    /// Feature flag. Access is only requested once the feature is enabled.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                updateAccessState()
                if !hasAccess && !accessDenied { requestAccess() }
                // Only what falls due from now on — no flood of old overdue items.
                lastCheck = Date()
                startTimers()
                check()
            } else {
                stopTimers()
            }
        }
    }

    private let store = EKEventStore()
    private var pollTimer: Timer?
    private var nextDueTimer: Timer?
    private var observer: NSObjectProtocol?
    private var lastCheck = Date()
    private var announced: Set<String> = []
    private var isFetching = false

    init() {
        updateAccessState()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.check()
        }
    }

    deinit {
        stopTimers()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func requestAccess() {
        if accessDenied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let completion: (Bool, Error?) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateAccessState()
                self?.check()
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders(completion: completion)
        } else {
            store.requestAccess(to: .reminder, completion: completion)
        }
    }

    /// Opens the reminder in the Reminders app (or just the app, if the link isn't understood).
    func open(_ reminder: DueReminder) {
        let encoded = reminder.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? reminder.id
        if let url = URL(string: "x-apple-reminderkit://REMCDReminder/\(encoded)"),
           NSWorkspace.shared.open(url) {
            return
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    enum CreateResult { case added, needsAccess, failed }

    /// A new reminder in the default list, with an alert at `due` (Command Bar).
    func create(title: String, due: Date) -> CreateResult {
        updateAccessState()
        guard hasAccess else {
            requestAccess()
            return .needsAccess
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        guard let list = store.defaultCalendarForNewReminders() else { return .failed }
        reminder.calendar = list
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        reminder.addAlarm(EKAlarm(absoluteDate: due))
        do {
            try store.save(reminder, commit: true)
            return .added
        } catch {
            Log.island.notice("couldn't save reminder: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    func complete(_ reminder: DueReminder) {
        guard let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
        item.isCompleted = true
        try? store.save(item, commit: true)
    }

    // MARK: - Internals

    private func updateAccessState() {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14.0, *) {
            hasAccess = status == .fullAccess
        } else {
            hasAccess = status == .authorized
        }
        accessDenied = status == .denied || status == .restricted
    }

    private func startTimers() {
        pollTimer?.invalidate()
        // Safety net (sleep / wake, sync from other devices); exact times use nextDueTimer.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopTimers() {
        pollTimer?.invalidate()
        pollTimer = nil
        nextDueTimer?.invalidate()
        nextDueTimer = nil
    }

    private func check() {
        guard isEnabled, hasAccess, !isFetching else { return }
        isFetching = true
        let now = Date()
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: now.addingTimeInterval(-24 * 3600),
            ending: now.addingTimeInterval(24 * 3600),
            calendars: nil
        )
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let items: [DueReminder] = (reminders ?? []).compactMap { reminder in
                // Date-only reminders ("sometime Tuesday") have no moment to announce.
                guard let components = reminder.dueDateComponents, components.hour != nil,
                      let due = Calendar.current.date(from: components) else { return nil }
                let title = reminder.title?.isEmpty == false ? reminder.title! : "Reminder"
                return DueReminder(
                    id: reminder.calendarItemIdentifier,
                    title: title,
                    due: due,
                    list: reminder.calendar?.title ?? "Reminders",
                    color: reminder.calendar.map { NSColor(cgColor: $0.cgColor) ?? .systemYellow } ?? .systemYellow
                )
            }
            DispatchQueue.main.async { self?.process(items, at: now) }
        }
    }

    private func process(_ items: [DueReminder], at now: Date) {
        isFetching = false
        guard isEnabled else { return }
        let since = lastCheck
        lastCheck = now

        let fresh = items
            .filter { $0.due <= now && $0.due > since.addingTimeInterval(-1) && !announced.contains($0.key) }
            .sorted { $0.due < $1.due }
        announced.formUnion(fresh.map(\.key))
        if !fresh.isEmpty { becameDue.send(fresh) }

        // Wake up right when the next one is due.
        nextDueTimer?.invalidate()
        nextDueTimer = nil
        if let next = items.map(\.due).filter({ $0 > now }).min() {
            let timer = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
                self?.check()
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            nextDueTimer = timer
        }
    }
}
