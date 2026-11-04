import AppKit
import Combine
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
    /// Events that were just added to a calendar (an invite arrived, or one was created on another device).
    let newMeetings = PassthroughSubject<[Meeting], Never>()
    /// Option: announce new meetings.
    var announcesNewMeetings = false

    // MARK: Dashboard (expanded calendar tab)

    struct AgendaDay: Identifiable, Equatable {
        let day: Date
        let meetings: [Meeting]
        var id: Date { day }
    }

    /// Upcoming events grouped by day (or just the selected day's).
    @Published private(set) var agenda: [AgendaDay] = []
    /// Month shown in the grid (its first day).
    @Published private(set) var displayedMonth = CalendarService.startOfMonth(Date())
    /// Day numbers in `displayedMonth` that have at least one event (the dots).
    @Published private(set) var eventDays: Set<Int> = []
    /// A day picked in the grid; nil = "upcoming" from today.
    @Published private(set) var selectedDay: Date?
    /// Events this app created (the + button) — never announced as "new meeting".
    private var createdByUs = Set<String>()

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
            self?.scanForNewMeetings()
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

    /// Opens the event itself in Calendar; falls back to just opening the app.
    func open(_ meeting: Meeting) {
        if let id = meeting.externalID,
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"),
           NSWorkspace.shared.open(url) {
            return
        }
        openCalendarApp()
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
            knownEventIDs = nil
            if !agenda.isEmpty { agenda = [] }
            if !eventDays.isEmpty { eventDays = [] }
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
        if knownEventIDs == nil { scanForNewMeetings() }
        refreshDashboard()
    }

    // MARK: - Dashboard

    func showMonth(offset: Int) {
        let cal = Calendar.current
        displayedMonth = offset == 0
            ? Self.startOfMonth(Date())
            : Self.startOfMonth(cal.date(byAdding: .month, value: offset, to: displayedMonth) ?? displayedMonth)
        refreshDashboard()
    }

    /// Click a day: show its events. Click it again (or today) to go back to "upcoming".
    func select(_ day: Date) {
        let cal = Calendar.current
        let day = cal.startOfDay(for: day)
        if selectedDay == day || (selectedDay == nil && cal.isDateInToday(day)) {
            selectedDay = nil
        } else {
            selectedDay = cal.isDateInToday(day) ? nil : day
        }
        refreshDashboard()
    }

    /// Back to today / this month (when the island closes).
    func resetDashboard() {
        guard selectedDay != nil || displayedMonth != Self.startOfMonth(Date()) else { return }
        selectedDay = nil
        displayedMonth = Self.startOfMonth(Date())
        refreshDashboard()
    }

    /// The + button: a one-hour "New Event" (next full hour today, or 9 AM on the
    /// selected day), opened in Calendar so you can name it.
    func createEvent() {
        guard hasAccess, let target = store.defaultCalendarForNewEvents else {
            openCalendarApp()
            return
        }
        let cal = Calendar.current
        let now = Date()
        let start: Date
        if let day = selectedDay, !cal.isDateInToday(day) {
            start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        } else {
            start = cal.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
        }
        let event = EKEvent(eventStore: store)
        event.title = "New Event"
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.calendar = target
        do {
            try store.save(event, span: .thisEvent, commit: true)
            if let id = event.eventIdentifier { createdByUs.insert(id) }
            open(Meeting(event: event))
        } catch {
            openCalendarApp()
        }
    }

    private func refreshDashboard() {
        guard isEnabled, hasAccess else { return }
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)

        // Agenda: the selected day, or the next two weeks (up to 12 events).
        let rangeStart = selectedDay ?? today
        let rangeEnd = cal.date(byAdding: .day, value: selectedDay == nil ? 14 : 1, to: rangeStart) ?? rangeStart
        let events = store.events(matching: store.predicateForEvents(withStart: rangeStart, end: rangeEnd, calendars: nil))
            .filter { $0.status != .canceled && (selectedDay != nil || $0.endDate > now) }
            .sorted { lhs, rhs in
                let l = max(cal.startOfDay(for: lhs.startDate), rangeStart)
                let r = max(cal.startOfDay(for: rhs.startDate), rangeStart)
                if l != r { return l < r }
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }   // all-day first
                return lhs.startDate < rhs.startDate
            }
            .prefix(selectedDay == nil ? 12 : 30)
        var groups: [AgendaDay] = []
        for event in events {
            let key = max(cal.startOfDay(for: event.startDate), rangeStart)
            let meeting = Meeting(event: event)
            if let last = groups.last, last.day == key {
                groups[groups.count - 1] = AgendaDay(day: key, meetings: last.meetings + [meeting])
            } else {
                groups.append(AgendaDay(day: key, meetings: [meeting]))
            }
        }
        if groups != agenda { agenda = groups }

        // Dots in the month grid.
        var days = Set<Int>()
        if let month = cal.dateInterval(of: .month, for: displayedMonth) {
            let monthEvents = store.events(matching: store.predicateForEvents(withStart: month.start, end: month.end, calendars: nil))
            for event in monthEvents where event.status != .canceled {
                var day = max(cal.startOfDay(for: event.startDate), month.start)
                let last = min(event.endDate.addingTimeInterval(-1), month.end.addingTimeInterval(-1))
                var steps = 0
                while day <= last && steps < 32 {
                    days.insert(cal.component(.day, from: day))
                    guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                    steps += 1
                }
            }
        }
        if days != eventDays { eventDays = days }
    }

    static func startOfMonth(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: date)?.start ?? Calendar.current.startOfDay(for: date)
    }

    // MARK: - New meetings

    /// Every event in the next few weeks, as of the last scan. nil until the first scan.
    private var knownEventIDs: Set<String>?

    /// Diff the next 30 days against the last scan. Only events *created* in the last
    /// few minutes count — a calendar account syncing in for the first time stays quiet.
    private func scanForNewMeetings() {
        guard isEnabled, hasAccess else {
            knownEventIDs = nil
            return
        }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(30 * 24 * 3600), calendars: nil)
        let events = store.events(matching: predicate).filter { !$0.isAllDay && $0.status != .canceled }
        let ids = Set(events.compactMap(\.eventIdentifier))
        defer { knownEventIDs = ids }
        guard let known = knownEventIDs, announcesNewMeetings else { return }

        // You just made it yourself in Calendar — no need to tell you.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.iCal" { return }

        var seen = Set<String>()
        let fresh = events
            .filter { event in
                guard let id = event.eventIdentifier, !known.contains(id), !createdByUs.contains(id), seen.insert(id).inserted,
                      let created = event.creationDate else { return false }
                return now.timeIntervalSince(created) < 15 * 60
            }
            .sorted { $0.startDate < $1.startDate }
            .map(Meeting.init(event:))
        if !fresh.isEmpty { newMeetings.send(fresh) }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
