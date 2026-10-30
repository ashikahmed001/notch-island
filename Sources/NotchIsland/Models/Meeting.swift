import AppKit
import EventKit

struct Meeting: Equatable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let location: String?
    let color: NSColor
    /// Zoom / Meet / Teams / Webex… link found in the event's URL, location or notes.
    let joinURL: URL?

    init(event: EKEvent) {
        id = event.eventIdentifier ?? UUID().uuidString
        title = (event.title?.isEmpty == false ? event.title : nil) ?? "Untitled event"
        start = event.startDate
        end = event.endDate
        location = event.location?.isEmpty == false ? event.location : nil
        color = event.calendar.map { NSColor(cgColor: $0.cgColor) ?? .systemBlue } ?? .systemBlue
        joinURL = Self.findJoinURL(in: [event.url?.absoluteString, event.location, event.notes])
    }

    static func == (lhs: Meeting, rhs: Meeting) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.start == rhs.start && lhs.end == rhs.end
            && lhs.location == rhs.location && lhs.joinURL == rhs.joinURL
    }

    func isInProgress(at date: Date) -> Bool { start <= date && date < end }

    /// "In 8 min", "Now · 20 min left", "In 2 h"
    func relativeLabel(at date: Date) -> String {
        if isInProgress(at: date) {
            let left = Int(end.timeIntervalSince(date) / 60)
            return left > 0 ? "Now · \(Self.duration(left)) left" : "Ending"
        }
        let minutes = Int(ceil(start.timeIntervalSince(date) / 60))
        if minutes <= 0 { return "Starting" }
        if minutes <= 180 { return "In \(Self.duration(minutes))" }
        return dayLabel
    }

    /// "Later today", "Tomorrow", or the weekday.
    var dayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(start) { return "Later today" }
        if calendar.isDateInTomorrow(start) { return "Tomorrow" }
        return start.formatted(.dateTime.weekday(.wide))
    }

    /// "9:00 AM" today, "Tue 9:00 AM" on other days.
    var shortStart: String {
        let time = start.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(start) ? time : "\(start.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    /// Compact form for the collapsed island: "8m", "Now", "2h".
    func shortLabel(at date: Date) -> String {
        if isInProgress(at: date) { return "Now" }
        let minutes = Int(ceil(start.timeIntervalSince(date) / 60))
        return minutes < 60 ? "\(max(minutes, 0))m" : "\(minutes / 60)h"
    }

    var timeRange: String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    private static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min")
    }

    /// Video-call providers used around the world.
    private static let meetingHosts = [
        "zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "gotomeeting.com", "meet.goto.com", "whereby.com", "chime.aws",
        "bluejeans.com", "meet.jit.si", "facetime.apple.com", "slack.com/huddle", "discord.gg",
    ]

    private static func findJoinURL(in texts: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                guard let url = match.url else { continue }
                let string = url.absoluteString.lowercased()
                if meetingHosts.contains(where: { string.contains($0) }) { return url }
            }
        }
        return nil
    }
}
