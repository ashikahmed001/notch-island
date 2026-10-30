import SwiftUI

struct CalendarPanel: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        if !calendar.hasAccess {
            DoodleEmptyState(
                title: "See your next meeting",
                subtitle: "Works with iCloud, Google and Outlook calendars added to macOS."
            ) {
                CalendarDoodle(accent: Feature.calendar.tint)
            } actions: {
                Button {
                    calendar.requestAccess()
                } label: {
                    TintedCapsuleLabel(title: calendar.accessDenied ? "Open Settings" : "Allow access",
                                       symbol: "lock.open", tint: Feature.calendar.tint)
                }
                .buttonStyle(.plain)
            }
        } else if calendar.upcoming.isEmpty {
            DoodleEmptyState(
                title: "No more meetings",
                subtitle: "Nothing until the end of tomorrow."
            ) {
                CalendarDoodle(accent: Feature.calendar.tint)
            } actions: {
                Button {
                    calendar.openCalendarApp()
                } label: {
                    TintedCapsuleLabel(title: "Open Calendar", symbol: "calendar", tint: Feature.calendar.tint)
                }
                .buttonStyle(.plain)
            }
        } else {
            AgendaView(meetings: calendar.upcoming, calendar: calendar)
        }
    }
}

/// Next meeting as the hero; the following ones listed alongside.
struct AgendaView: View {
    let meetings: [Meeting]
    let calendar: CalendarService

    private static let listLimit = 3

    var body: some View {
        let hero = meetings[0]
        let rest = Array(meetings.dropFirst().prefix(Self.listLimit))
        let more = meetings.count - 1 - rest.count

        HStack(spacing: 14) {
            MeetingHero(meeting: hero, compact: !rest.isEmpty, calendar: calendar)

            if !rest.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
                    .padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 7) {
                    Text("UP NEXT")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    ForEach(rest) { meeting in
                        AgendaRow(meeting: meeting)
                    }
                    if more > 0 {
                        Button {
                            calendar.openCalendarApp()
                        } label: {
                            Text("+\(more) more")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Feature.calendar.tint)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 168, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// The next (or current) meeting: colour bar, when, title, time, Join.
struct MeetingHero: View {
    let meeting: Meeting
    /// Sharing the row with the agenda list → stack the Join button under the details.
    let compact: Bool
    let calendar: CalendarService

    var body: some View {
        let tint = Color(nsColor: meeting.color)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 4)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 3) {
                TimelineView(.everyMinute) { context in
                    Text(meeting.relativeLabel(at: context.date).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(tint)
                }
                Text(meeting.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(details)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if compact, meeting.joinURL != nil {
                    joinButton(height: 24)
                        .padding(.top, 4)
                }
            }

            if !compact {
                Spacer(minLength: 8)
                if meeting.joinURL != nil {
                    joinButton(height: 32)
                }
            }
        }
    }

    private var details: String {
        let time = Calendar.current.isDateInToday(meeting.start) || meeting.isInProgress(at: Date())
            ? meeting.timeRange
            : "\(meeting.start.formatted(.dateTime.weekday(.abbreviated))) \(meeting.timeRange)"
        return [time, meeting.location].compactMap { $0 }.joined(separator: "  ·  ")
    }

    private func joinButton(height: CGFloat) -> some View {
        Button {
            calendar.join(meeting)
        } label: {
            Label("Join", systemImage: "video.fill")
                .font(.system(size: height > 28 ? 12 : 11, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, height > 28 ? 14 : 10)
                .frame(height: height)
                .background(Capsule().fill(Color.green))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// One line in the agenda: colour dot, start time, title.
struct AgendaRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(nsColor: meeting.color))
                .frame(width: 6, height: 6)
            Text(meeting.shortStart)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(meeting.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help("\(meeting.title) · \(meeting.timeRange)")
    }
}
