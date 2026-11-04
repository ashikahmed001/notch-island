import SwiftUI

/// Calendar tab: agenda on the left, month at a glance on the right.
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
        } else {
            HStack(alignment: .top, spacing: 18) {
                AgendaColumn(calendar: calendar)
                    .frame(width: 236)
                MonthGrid(calendar: calendar)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Agenda

/// "SAT 31 W44", then the events grouped by day.
struct AgendaColumn: View {
    @ObservedObject var calendar: CalendarService

    private var headerDay: Date { calendar.selectedDay ?? Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if calendar.agenda.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(calendar.selectedDay == nil ? "Nothing coming up" : "Nothing on this day")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Click + to add an event.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(calendar.agenda) { day in
                            if !Calendar.current.isDate(day.day, inSameDayAs: headerDay) {
                                Text(day.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased())
                                    .font(.system(size: 9.5, weight: .bold))
                                    .tracking(0.4)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            }
                            ForEach(day.meetings) { meeting in
                                EventCard(meeting: meeting, calendar: calendar)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        let cal = Calendar.current
        let day = headerDay
        let tint = Feature.calendar.tint
        return HStack(spacing: 5) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .foregroundStyle(tint)
            Text("\(cal.component(.day, from: day))")
                .foregroundStyle(Color.white)
            Text("W\(cal.component(.weekOfYear, from: day))")
                .foregroundStyle(tint.opacity(0.6))
            Spacer(minLength: 4)
            if calendar.selectedDay != nil {
                Button { calendar.select(Date()) } label: {
                    Text("Today")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .frame(height: 22)
    }
}

/// One event: colour bar, title and time in the calendar's colour, Join if there's a link.
/// Click → open it in Calendar.
struct EventCard: View {
    let meeting: Meeting
    let calendar: CalendarService

    var body: some View {
        let base = meeting.color
        let tint = Color(nsColor: base)
        // A lighter version of the calendar colour, readable on black.
        let text = Color(nsColor: base.blended(withFraction: 0.35, of: .white) ?? base)
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(text)
                    .lineLimit(1)
                Text(meeting.timeRange)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(text.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if meeting.joinURL != nil, meeting.end > Date() {
                JoinButton(height: 22) { calendar.join(meeting) }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.16)))
        .contentShape(Rectangle())
        .onTapGesture { calendar.open(meeting) }
        .help("\(meeting.title) · \(meeting.timeRange) — click to open in Calendar")
    }
}

/// Green "Join" capsule (video-call link in the event).
struct JoinButton: View {
    var height: CGFloat = 24
    var showsIcon = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if showsIcon {
                    Label("Join", systemImage: "video.fill")
                } else {
                    Text("Join")
                }
            }
            .font(.system(size: height > 26 ? 12 : 11, weight: .bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, height > 26 ? 14 : 10)
            .frame(height: height)
            .glassBackground(Capsule(), fallback: Color.green, tint: Color.green)
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Month

/// The month at a glance: today in red, dots on days with events. Click a day to see it.
struct MonthGrid: View {
    @ObservedObject var calendar: CalendarService

    private static let cellHeight: CGFloat = 22

    var body: some View {
        let cal = Calendar.current
        let month = calendar.displayedMonth
        let weeks = Self.weeks(of: month)

        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                roundButton("plus", help: "New event") { calendar.createEvent() }
                roundButton("arrow.up.left.and.arrow.down.right", help: "Open Calendar") { calendar.openCalendarApp() }
                monthSwitcher(month)
            }
            .frame(height: 22)
            .padding(.bottom, 4)

            HStack(spacing: 0) {
                ForEach(Array(Self.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 16)

            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, date in
                        if let date {
                            dayCell(date, cal: cal)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: Self.cellHeight)
                        }
                    }
                }
                .frame(height: Self.cellHeight)
            }
        }
    }

    private func dayCell(_ date: Date, cal: Calendar) -> some View {
        let day = cal.component(.day, from: date)
        let isToday = cal.isDateInToday(date)
        let isSelected = calendar.selectedDay.map { cal.isDate($0, inSameDayAs: date) } ?? false
        let isWeekend = cal.isDateInWeekend(date)
        let hasEvents = calendar.eventDays.contains(day)
        return Button { calendar.select(date) } label: {
            ZStack {
                if isToday {
                    Circle().fill(Feature.calendar.tint).frame(width: 21, height: 21)
                } else if isSelected {
                    Circle().stroke(Color.white.opacity(0.55), lineWidth: 1).frame(width: 21, height: 21)
                }
                Text("\(day)")
                    .font(.system(size: 11, weight: isToday ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? Color.white : Color.white.opacity(isWeekend ? 0.45 : 0.9))
                if hasEvents && !isToday {
                    Circle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 3, height: 3)
                        .offset(y: 9)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: Self.cellHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func monthSwitcher(_ month: Date) -> some View {
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: month) == cal.component(.year, from: Date())
        let label = sameYear
            ? month.formatted(.dateTime.month(.abbreviated))
            : month.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        return HStack(spacing: 2) {
            chevron("chevron.left") { calendar.showMonth(offset: -1) }
            Button { calendar.showMonth(offset: 0) } label: {
                Text(label.uppercased())
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Feature.calendar.tint)
                    .frame(minWidth: 34)
            }
            .buttonStyle(.plain)
            .help("Back to this month")
            chevron("chevron.right") { calendar.showMonth(offset: 1) }
        }
    }

    private func chevron(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .glassBackground(Circle(), fallback: Color.white.opacity(0.12))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Weekday initials starting on the user's first weekday (Monday or Sunday by region).
    static var weekdaySymbols: [String] {
        let cal = Calendar.current
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Rows of 7 dates (nil = padding before the 1st / after the last day).
    static func weeks(of month: Date) -> [[Date?]] {
        let cal = Calendar.current
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let leading = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            cells.append(cal.date(byAdding: .day, value: day - 1, to: month))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }
}
