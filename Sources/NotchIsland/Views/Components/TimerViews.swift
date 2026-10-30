import SwiftUI

struct TimerRing: View {
    @ObservedObject var timer: TimerService
    var lineWidth: CGFloat = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let fraction = timer.fractionRemaining(at: context.date)
            let tint = timer.tint(at: context.date)
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.22), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: fraction)
            }
        }
    }
}

struct TimerText: View {
    @ObservedObject var timer: TimerService
    var size: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(TimerService.format(timer.remaining(at: context.date)))
                .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(timer.tint(at: context.date))
                .animation(.easeInOut(duration: 0.3), value: timer.state)
        }
    }
}

extension TimerService {
    /// Orange while running, dimmed when paused, red for the final 10 seconds.
    func tint(at date: Date) -> Color {
        if state == .paused { return Color.orange.opacity(0.45) }
        if state == .ringing { return .red }
        return remaining(at: date) <= 10 ? .red : .orange
    }
}
