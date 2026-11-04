import AppKit
import SwiftUI

/// Home tab: the widgets picked in Settings ▸ Home (or customized right here), side by side.
struct HomePanel: View {
    @ObservedObject var vm: IslandViewModel

    var body: some View {
        let widgets = vm.home.widgets
        let scale = vm.homeScale
        let editing = vm.isEditingHome
        let hidden = HomeSettings.Widget.allCases.filter { !vm.home.isShown($0) }

        HStack(alignment: .center, spacing: 12 * scale) {
            ForEach(Array(widgets.enumerated()), id: \.element) { index, widget in
                if index > 0 { divider }
                content(widget)
                    .frame(width: widget.width * scale)
                    .frame(maxHeight: .infinity)
                    .opacity(editing ? 0.5 : 1)
                    .allowsHitTesting(!editing)
                    .overlay {
                        if editing {
                            WidgetEditOverlay(vm: vm, widget: widget, index: index, count: widgets.count)
                        }
                    }
                    .contextMenu {
                        Button("Customize Home…") { withAnimation(IslandViewModel.spring) { vm.isEditingHome = true } }
                        Divider()
                        Button("Move Left") { withAnimation(IslandViewModel.spring) { vm.home.move(widget, by: -1) } }
                            .disabled(index == 0)
                        Button("Move Right") { withAnimation(IslandViewModel.spring) { vm.home.move(widget, by: 1) } }
                            .disabled(index == widgets.count - 1)
                        Button("Remove \(widget.title)") { withAnimation(IslandViewModel.spring) { vm.home.setShown(widget, false) } }
                    }
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            if editing && !hidden.isEmpty {
                if !widgets.isEmpty { divider }
                AddWidgetColumn(vm: vm, hidden: hidden)
                    .frame(width: IslandViewModel.homeAddColumnWidth * scale)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(IslandViewModel.spring, value: widgets)
        .animation(IslandViewModel.spring, value: editing)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
            .padding(.vertical, 14)
    }

    @ViewBuilder
    private func content(_ widget: HomeSettings.Widget) -> some View {
        switch widget {
        case .music: MusicWidget(vm: vm, player: vm.nowPlaying)
        case .nextMeeting: NextMeetingWidget(calendar: vm.calendar)
        case .cpu:
            CPUHistoryCard(stats: vm.stats)
        case .battery:
            BatteryHistoryCard(stats: vm.stats, battery: vm.battery)
        case .focus: FocusWidget(vm: vm, timer: vm.timer)
        case .todos: TodoWidget(vm: vm, todos: vm.todos)
        }
    }
}

// MARK: - Customizing

/// Customize / Done, shown beside the date while the Home tab is open.
struct HomeEditButton: View {
    @ObservedObject var vm: IslandViewModel

    var body: some View {
        let editing = vm.isEditingHome
        Button {
            withAnimation(IslandViewModel.spring) { vm.isEditingHome.toggle() }
        } label: {
            Label(editing ? "Done" : "Customize", systemImage: editing ? "checkmark" : "slider.horizontal.3")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(editing ? Color.black : Color.white.opacity(0.7))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(editing ? Color.white : Color.white.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(editing ? "Finish customizing" : "Add, remove and reorder Home widgets")
    }
}

/// While customizing: dashed outline, remove badge, move arrows.
struct WidgetEditOverlay: View {
    @ObservedObject var vm: IslandViewModel
    let widget: HomeSettings.Widget
    let index: Int
    let count: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            VStack(spacing: 6) {
                Image(systemName: widget.symbol)
                    .font(.system(size: 16, weight: .semibold))
                Text(widget.title)
                    .font(.system(size: 11, weight: .semibold))
                HStack(spacing: 6) {
                    arrow("chevron.left", disabled: index == 0) { vm.home.move(widget, by: -1) }
                    arrow("chevron.right", disabled: index == count - 1) { vm.home.move(widget, by: 1) }
                }
            }
            .foregroundStyle(Color.white)
        }
        .overlay(alignment: .topLeading) {
            Button {
                withAnimation(IslandViewModel.spring) { vm.home.setShown(widget, false) }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.red))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: -6, y: -6)
            .help("Remove")
        }
        .padding(.vertical, 6)
    }

    private func arrow(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(IslandViewModel.spring) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 26, height: 22)
                .background(Capsule().fill(Color.white.opacity(disabled ? 0.04 : 0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }
}

/// While customizing: the widgets you can add.
struct AddWidgetColumn: View {
    @ObservedObject var vm: IslandViewModel
    let hidden: [HomeSettings.Widget]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Add widget")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(hidden) { widget in
                Button {
                    withAnimation(IslandViewModel.spring) { vm.home.setShown(widget, true) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.green)
                        Text(widget.title).lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Music

struct MusicWidget: View {
    @ObservedObject var vm: IslandViewModel
    @ObservedObject var player: NowPlayingService

    var body: some View {
        if let track = player.track {
            HStack(spacing: 12) {
                ArtworkView(image: player.artwork, cornerRadius: 12)
                    .frame(width: 84, height: 84)
                    .overlay(alignment: .bottomTrailing) {
                        SourceBadge(source: track.source).offset(x: 5, y: 5)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(track.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .lineLimit(1)
                    if !track.album.isEmpty {
                        Text(track.album)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 14) {
                        control("backward.fill") { player.send(.previous) }
                        control(track.isPlaying ? "pause.fill" : "play.fill", size: 17) { player.send(.playPause) }
                        control("forward.fill") { player.send(.next) }
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Feature.nowPlaying.tint)
                Text("Nothing playing")
                    .font(.system(size: 12, weight: .semibold))
                Text("Play something in Music or Spotify.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func control(_ symbol: String, size: CGFloat = 13, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Next meeting

struct NextMeetingWidget: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        if let meeting = calendar.next {
            let tint = Color(nsColor: meeting.color)
            VStack(alignment: .leading, spacing: 4) {
                TimelineView(.everyMinute) { context in
                    Text(meeting.relativeLabel(at: context.date).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(tint)
                }
                Text(meeting.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(meeting.timeRange)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if meeting.joinURL != nil {
                    JoinButton(height: 24, showsIcon: true) { calendar.join(meeting) }
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { calendar.open(meeting) }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Feature.calendar.tint)
                Text(calendar.hasAccess ? "No more meetings" : "Calendar is off")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
    }
}

// MARK: - CPU / battery (colour-coded history)

/// Card frame shared by the CPU and battery widgets.
struct StatCardFrame<Content: View>: View {
    let title: String
    let value: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint)
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.vertical, 4)
    }
}

/// CPU over the last 2 minutes as bars: green when calm, amber when busy, red when maxed.
struct CPUHistoryCard: View {
    @ObservedObject var stats: SystemStatsService
    private static let bars = 20

    var body: some View {
        let load = stats.cpu
        StatCardFrame(title: "CPU · 2 min", value: "\(Int((load * 100).rounded()))%", tint: Self.color(for: load)) {
            GeometryReader { geo in
                let values = Self.buckets(stats.cpuHistory)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(value == nil ? Color.white.opacity(0.06) : Self.color(for: value ?? 0))
                            .frame(height: max(3, geo.size.height * CGFloat(value ?? 0.04)))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                .animation(.easeOut(duration: 0.4), value: stats.cpuHistory.count)
            }
            Text(Self.summary(load))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help("CPU use over the last 2 minutes")
    }

    static func color(for load: Double) -> Color {
        load >= 0.8 ? .red : (load >= 0.5 ? .orange : .green)
    }

    static func summary(_ load: Double) -> String {
        load >= 0.8 ? String(localized: "Working hard") : (load >= 0.5 ? String(localized: "Busy")
            : (load >= 0.15 ? String(localized: "Light load") : String(localized: "Mostly idle")))
    }

    /// 60 samples (2 s each) → 20 bars, each the busiest moment in its 6 seconds.
    /// Bars with no data yet (just opened) show as empty slots on the left.
    static func buckets(_ history: [Double]) -> [Double?] {
        let perBar = 3
        var result: [Double?] = []
        var index = history.count
        while index > 0 && result.count < bars {
            let slice = history[max(0, index - perBar)..<index]
            result.insert(slice.max(), at: 0)
            index -= perBar
        }
        while result.count < bars { result.insert(nil, at: 0) }
        return result
    }
}

/// Battery over the last hour: a timeline of charging (green) vs. on battery,
/// plus what changed in plain words.
struct BatteryHistoryCard: View {
    @ObservedObject var stats: SystemStatsService
    @ObservedObject var battery: BatteryService

    var body: some View {
        let level = battery.level
        let tint: Color = level <= 20 ? .red : .yellow
        let history = stats.batteryHistory
        StatCardFrame(title: "Battery · 1 h", value: "\(level)%", tint: tint) {
            GeometryReader { geo in
                let runs = Self.runs(history)
                let total = max(runs.reduce(0) { $0 + $1.count }, 1)
                HStack(spacing: 0) {
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        Rectangle()
                            .fill(run.charging ? Color.green : tint)
                            .frame(width: geo.size.width * CGFloat(run.count) / CGFloat(total))
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
            }
            .frame(height: 10)

            HStack {
                if history.contains(where: \.charging) {
                    legend("Charging", .green)
                }
                Spacer(minLength: 2)
                if history.contains(where: { !$0.charging }) {
                    legend("On battery", tint)
                }
            }

            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.change(history))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .lineLimit(2)
                if let timeLeft = timeLeft {
                    Text(timeLeft)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .help("Battery over the last hour")
    }

    private var timeLeft: String? {
        if battery.isCharging, let minutes = battery.minutesToFull { return "Full in \(Self.duration(minutes))" }
        if !battery.isPluggedIn, let minutes = battery.minutesToEmpty { return "\(Self.duration(minutes)) left" }
        return nil
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// Consecutive samples with the same charging state.
    static func runs(_ history: [SystemStatsService.BatterySample]) -> [(charging: Bool, count: Int)] {
        var runs: [(charging: Bool, count: Int)] = []
        for sample in history {
            if let last = runs.last, last.charging == sample.charging {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((sample.charging, 1))
            }
        }
        return runs
    }

    /// "Lost 18% in the last hour", "Gained 6% in 25 min", "Steady for 40 min".
    static func change(_ history: [SystemStatsService.BatterySample]) -> String {
        guard let first = history.first, let last = history.last, history.count >= 3 else {
            return "Tracking since you opened the island"
        }
        let minutes = history.count - 1
        let span = minutes >= 59 ? "the last hour" : "\(minutes) min"
        let delta = Int(((last.level - first.level) * 100).rounded())
        if delta <= -1 { return "Lost \(-delta)% in \(span)" }
        if delta >= 1 { return "Gained \(delta)% in \(span)" }
        return "Steady for \(minutes >= 59 ? "the last hour" : "\(minutes) min")"
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min")
    }
}

// MARK: - Focus timer

struct FocusWidget: View {
    @ObservedObject var vm: IslandViewModel
    @ObservedObject var timer: TimerService

    var body: some View {
        let tint = Feature.timer.tint
        VStack(spacing: 8) {
            if timer.state == .idle {
                HStack(spacing: 6) {
                    mode("Focus", .focus, minutes: 25)
                    mode("Break", .rest, minutes: 5)
                }
                MinuteRuler(vm: vm, tint: tint)
                HStack(spacing: 8) {
                    Button { timer.start(minutes: vm.focusMinutes) } label: {
                        Text("Start")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 16)
                            .frame(height: 30)
                            .glassBackground(Capsule(), fallback: tint.opacity(0.2), tint: tint.opacity(0.35))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { vm.flags.toggle(.timerSound) } label: {
                        Image(systemName: vm.flags.isOn(.timerSound) ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 30, height: 30)
                            .glassBackground(Circle(), fallback: tint.opacity(0.15))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Chime when done")
                    Spacer(minLength: 4)
                    Text(String(format: "%d:00", Int(vm.focusMinutes)))
                        .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint)
                }
            } else {
                Text(timer.state == .ringing ? "Time's up" : (vm.focusMode == .focus ? "Focusing" : "On a break"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TimerText(timer: timer, size: 34, live: vm.mode == .expanded)
                HStack(spacing: 10) {
                    if timer.state != .ringing {
                        roundButton(timer.state == .paused ? "play.fill" : "pause.fill", tint: tint) {
                            if timer.state == .paused { timer.resume() } else { timer.pause() }
                        }
                    }
                    roundButton("xmark", tint: .white) { timer.stop() }
                }
            }
        }
    }

    private func mode(_ title: String, _ mode: IslandViewModel.FocusMode, minutes: Double) -> some View {
        let selected = vm.focusMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                vm.focusMode = mode
                vm.focusMinutes = minutes
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Feature.timer.tint : Color.white.opacity(0.5))
                .padding(.horizontal, 14)
                .frame(height: 26)
                .background(Capsule().fill(selected ? Feature.timer.tint.opacity(0.2) : Color.white.opacity(0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func roundButton(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .glassBackground(Circle(), fallback: tint.opacity(tint == .white ? 0.12 : 0.22))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Drag along the ruler to pick 1–60 minutes.
struct MinuteRuler: View {
    @ObservedObject var vm: IslandViewModel
    let tint: Color
    private static let maxMinutes = 60

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let selected = Int(vm.focusMinutes)
            let markerX = CGFloat(vm.focusMinutes) / CGFloat(Self.maxMinutes) * width
            ZStack(alignment: .topLeading) {
                ForEach(0...Self.maxMinutes, id: \.self) { minute in
                    let x = CGFloat(minute) / CGFloat(Self.maxMinutes) * width
                    Rectangle()
                        .fill(minute <= selected ? tint : Color.white.opacity(0.22))
                        .frame(width: 1.2, height: minute % 5 == 0 ? 13 : 8)
                        .position(x: x, y: 22)
                    if minute % 10 == 0 {
                        Text("\(minute)")
                            .font(.system(size: 8.5, weight: minute == selected ? .bold : .medium).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.45))
                            .position(x: x, y: 6)
                    }
                }
                Capsule()
                    .fill(Color.white)
                    .frame(width: 2.5, height: 20)
                    .position(x: markerX, y: 22)
                Image(systemName: "triangle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(tint)
                    .position(x: markerX, y: 36)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let minutes = (value.location.x / max(width, 1) * CGFloat(Self.maxMinutes)).rounded()
                vm.focusMinutes = Double(min(max(minutes, 1), CGFloat(Self.maxMinutes)))
            })
        }
        .frame(height: 40)
    }
}

// MARK: - To-dos

struct TodoWidget: View {
    @ObservedObject var vm: IslandViewModel
    @ObservedObject var todos: TodoService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("To-dos")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if todos.openCount > 0 {
                    Text("\(todos.openCount)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(todos.items) { todo in
                        row(todo)
                    }
                    if todos.items.isEmpty && !vm.isAddingTodo {
                        Text("Nothing to do 🎉")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if vm.isAddingTodo {
                InlineTextField(text: $vm.newTodoText, placeholder: "New task — Return to add") {
                    todos.add(vm.newTodoText)
                    vm.newTodoText = ""
                } onCancel: {
                    vm.newTodoText = ""
                    vm.isAddingTodo = false
                }
                .frame(height: 24)
                .padding(.horizontal, 10)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            } else {
                Button { vm.isAddingTodo = true } label: {
                    Label("Add a task", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Feature.timer.tint)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(Feature.timer.tint.opacity(0.18)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ todo: TodoService.Todo) -> some View {
        let tint = Feature.timer.tint
        return HStack(spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { todos.toggle(todo) } } label: {
                ZStack {
                    Circle().stroke(tint, lineWidth: 1.5)
                    if todo.isDone {
                        Circle().fill(tint)
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.black)
                    }
                }
                .frame(width: 15, height: 15)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Text(todo.title)
                .font(.system(size: 12))
                .strikethrough(todo.isDone)
                .foregroundStyle(todo.isDone ? Color.white.opacity(0.4) : Color.white)
                .lineLimit(1)
        }
        .contextMenu {
            Button("Delete") { todos.remove(todo) }
            Button("Clear completed") { todos.clearDone() }
        }
    }
}

/// A plain text field that takes focus as soon as it appears (Return = submit, Esc = cancel).
struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextField
        init(parent: InlineTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
