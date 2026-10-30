import SwiftUI

struct BatteryBadge: View {
    @ObservedObject var battery: BatteryService
    /// Percentage + glyph only; the status ("Full in 45m") moves to the tooltip.
    var compact = false

    var body: some View {
        if battery.hasBattery {
            HStack(spacing: 6) {
                if !compact, let status = battery.statusText {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
                Text("\(battery.level)%")
                    .monospacedDigit()
                    .foregroundStyle(battery.tint == .white ? Color.primary : battery.tint)
                BatteryGlyph(
                    level: battery.level,
                    showBolt: battery.isPluggedIn && !battery.isFull,
                    fill: battery.tint,
                    width: compact ? 22 : 24
                )
            }
            .help(battery.statusText ?? "\(battery.level)%")
        }
    }
}

/// Battery icon whose fill tracks the exact percentage (SF Symbols only has 4 steps).
struct BatteryGlyph: View {
    let level: Int
    let showBolt: Bool
    let fill: Color
    var width: CGFloat = 24

    var body: some View {
        let height = width * 0.5
        let inner = width - 4
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.32, style: .continuous)
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: height * 0.2, style: .continuous)
                    .fill(fill)
                    .frame(width: max(2, inner * CGFloat(min(max(level, 0), 100)) / 100))
                    .padding(2)
                if showBolt {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: height * 0.72, weight: .black))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.45))
                .frame(width: 1.5, height: height * 0.38)
        }
        .animation(.easeInOut(duration: 0.4), value: level)
    }
}

extension BatteryService {
    /// Same colour language as iOS: green on power, yellow in Low Power Mode, red when low.
    var tint: Color {
        if isPluggedIn { return .green }
        if isLowPowerMode { return .yellow }
        if level <= 20 { return .red }
        return .white
    }
}
