import SwiftUI

struct TimerPanel: View {
    @ObservedObject var timer: TimerService
    /// The open island is showing (no ticking while it's closed).
    var live = true
    private let presets: [Double] = [1, 5, 10, 15, 25, 45]

    var body: some View {
        if timer.state == .idle {
            VStack(spacing: 10) {
                Text("Start a timer")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { minutes in
                        Button {
                            timer.start(minutes: minutes)
                        } label: {
                            Text("\(Int(minutes))m")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .frame(width: 46, height: 30)
                                .glassBackground(RoundedRectangle(cornerRadius: 8, style: .continuous), fallback: Color.white.opacity(0.1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if timer.state == .ringing {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.red.opacity(0.18))
                    Image(systemName: "bell.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.red)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Time's up")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.red)
                    Text("\(max(1, Int((timer.lastDuration / 60).rounded()))) min timer")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button { timer.addMinute() } label: {
                        Text("+1 min")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()   // never truncate to "+1…"
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .glassBackground(Capsule(), fallback: Color.white.opacity(0.1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    roundButton("arrow.clockwise", tint: .orange) { timer.restart() }
                    roundButton("xmark", tint: .white) { timer.stop() }
                }
                .fixedSize()
            }
            .frame(maxHeight: .infinity)
        } else {
            let paused = timer.state == .paused
            HStack(spacing: 16) {
                ZStack {
                    TimerRing(timer: timer, lineWidth: 5, live: live)
                    Image(systemName: paused ? "pause.fill" : "timer")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.orange.opacity(paused ? 0.45 : 0.9))
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 2) {
                    TimerText(timer: timer, size: 32, live: live)
                    Text(paused ? "Paused" : "Ends at \(Date().addingTimeInterval(timer.remaining()).formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button { timer.addMinute() } label: {
                        Text("+1 min")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()   // never truncate to "+1…"
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .glassBackground(Capsule(), fallback: Color.white.opacity(0.1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    roundButton(paused ? "play.fill" : "pause.fill", tint: .orange) {
                        if paused { timer.resume() } else { timer.pause() }
                    }
                    roundButton("xmark", tint: .white) { timer.stop() }
                }
                .fixedSize()
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// iPhone Clock–style circular control.
    private func roundButton(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .glassBackground(Circle(), fallback: tint.opacity(tint == .white ? 0.12 : 0.22),
                                 tint: tint == .white ? nil : tint.opacity(0.4))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
