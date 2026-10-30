import AppKit
import EventKit

/// Next meeting from every calendar added to macOS (iCloud, Google, Exchange/Outlook…).
final class CalendarService: ObservableObject {
    @Published private(set) var hasAccess = false
    @Published private(set) var accessDenied = false
    /// Meetings in progress or coming up, until the end of tomorrow (earliest first).
    @Published private(set) var upcoming: [Meeting] = []

    /// The meeting in progress, or the next one.
    var next: Meeting? { upcoming.first }
    /// Starts within 10 minutes (or started under 5 minutes ago) → compact live activity.
    @Published private(set) var isSoon = false

    /// Feature flag. Starts off; access is only requested once the feature is enabled.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                updateAccessState()
                if !hasAccess && !accessDenied { requestAccess() }
            }
            refresh()
        }
    }

    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init() {
        updateAccessState()

        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        // Calendar changes arrive via the notification; this keeps "soon"/labels current.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func requestAccess() {
        if accessDenied {
            openPrivacySettings()
            return
        }
        let completion: (Bool, Error?) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateAccessState()
                self?.refresh()
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: completion)
        } else {
            store.requestAccess(to: .event, completion: completion)
        }
    }

    func join(_ meeting: Meeting) {
        guard let url = meeting.joinURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    // MARK: - Internals

    private func updateAccessState() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            hasAccess = status == .fullAccess
        } else {
            hasAccess = status == .authorized
        }
        accessDenied = status == .denied || status == .restricted
    }

    private func refresh() {
        guard isEnabled, hasAccess else {
            if !upcoming.isEmpty { upcoming = [] }
            if isSoon { isSoon = false }
            return
        }
        let now = Date()
        let endOfTomorrow = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now)) ?? now.addingTimeInterval(48 * 3600)
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-6 * 3600),
            end: endOfTomorrow,
            calendars: nil
        )
        let meetings = Array(
            store.events(matching: predicate)
                .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
                .sorted { $0.startDate < $1.startDate }
                .prefix(12)
                .map(Meeting.init(event:))
        )
        if meetings != upcoming { upcoming = meetings }

        let newNext = meetings.first

        let soon = newNext.map {
            $0.start.timeIntervalSince(now) <= 600 && now.timeIntervalSince($0.start) <= 300
        } ?? false
        if soon != isSoon { isSoon = soon }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
