import SwiftUI

/// Launch greeting, revealed in stages over a soft, time-of-day aurora:
/// "Good evening," → shimmering name → date & day summary → features lighting up → "All set".
struct WelcomeView: View {
    @ObservedObject var vm: IslandViewModel
    let welcome: IslandViewModel.Welcome

    private var phase: Int { vm.welcomePhase }
    private var palette: WelcomePalette { WelcomePalette(hour: welcome.hour) }
    private var allReady: Bool { !welcome.features.isEmpty && vm.welcomeLit >= welcome.features.count }

    var body: some View {
        VStack(spacing: 9) {
            // Hero line
            HStack(spacing: 8) {
                Text("👋")
                    .font(.system(size: 24))
                    .modifier(WaveEffect(animatableData: vm.waveTrigger))
                    .modifier(BlurMorph(active: phase < 1))
                Text("\(welcome.greeting),")
                    .foregroundStyle(Color.white)
                    .modifier(BlurMorph(active: phase < 1))
                ShimmerText(text: welcome.name, colors: palette.name)
                    .modifier(BlurMorph(active: phase < 2))
            }
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .lineLimit(1)

            // Date, then a look at the day once services have started
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: palette.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 12, weight: .semibold))
                    Text(welcome.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                if let context = vm.welcomeContext {
                    Text(context)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.name.last ?? .white)
                        .transition(.blurMorph)
                }
            }
            .lineLimit(1)
            .modifier(BlurMorph(active: phase < 3))

            // Features starting up
            HStack(spacing: 8) {
                ForEach(Array(welcome.features.enumerated()), id: \.offset) { index, feature in
                    FeatureDot(feature: feature, lit: index < vm.welcomeLit)
                }
                if allReady {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("All set")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .padding(.leading, 4)
                    .transition(.blurMorph)
                }
            }
            .padding(.top, 2)
            .modifier(BlurMorph(active: phase < 3))
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: allReady)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Aurora(colors: palette.aurora)
                .padding(-40)            // bleed to the island's edges; the island clips it
                .opacity(phase >= 1 ? 1 : 0)
                .animation(.easeOut(duration: 1.2), value: phase >= 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { vm.dismissWelcome?() }
        .help("Click to dismiss")
    }
}

/// Colours that follow the time of day.
struct WelcomePalette {
    let name: [Color]
    let aurora: [Color]
    /// SF Symbol for the time of day, shown before the date.
    let symbol: String

    init(hour: Int) {
        switch hour {
        case 5..<12:   // morning: sunrise amber
            name = [Color(red: 1.0, green: 0.88, blue: 0.45), Color(red: 1.0, green: 0.62, blue: 0.3)]
            aurora = [.orange, .yellow, .pink]
            symbol = "sun.horizon.fill"
        case 12..<17:  // afternoon: clear sky
            name = [Color(red: 0.55, green: 0.85, blue: 1.0), Color(red: 0.4, green: 0.6, blue: 1.0)]
            aurora = [.cyan, .blue, .teal]
            symbol = "sun.max.fill"
        case 17..<22:  // evening: sunset peach → pink
            name = [Color(red: 1.0, green: 0.82, blue: 0.6), Color(red: 1.0, green: 0.5, blue: 0.72)]
            aurora = [.pink, .orange, .purple]
            symbol = "sunset.fill"
        default:       // night: indigo
            name = [Color(red: 0.75, green: 0.72, blue: 1.0), Color(red: 0.55, green: 0.45, blue: 1.0)]
            aurora = [.indigo, .purple, .blue]
            symbol = "moon.stars.fill"
        }
    }
}

/// Gradient text with a light sweep passing across it.
struct ShimmerText: View {
    let text: String
    let colors: [Color]

    var body: some View {
        Text(text)
            .foregroundStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
            .overlay(
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    // One sweep every 2.4 s, sliding from left (-1) to right (+1).
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                    let x = CGFloat(t) * 3 - 1.5
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.75), .clear],
                        startPoint: UnitPoint(x: x - 0.25, y: 0.5),
                        endPoint: UnitPoint(x: x + 0.25, y: 0.5)
                    )
                }
                .mask(Text(text))
            )
    }
}

/// Soft drifting colour blobs (only alive while the greeting shows).
struct Aurora: View {
    let colors: [Color]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    ForEach(colors.indices, id: \.self) { i in
                        let phase = t * (0.35 + Double(i) * 0.12) + Double(i) * 2.1
                        Circle()
                            .fill(colors[i].opacity(0.32))
                            .frame(width: w * 0.55, height: w * 0.55)
                            .position(
                                x: w * (0.5 + 0.32 * CGFloat(cos(phase))),
                                y: h * (0.55 + 0.22 * CGFloat(sin(phase * 1.3)))
                            )
                    }
                }
                .blur(radius: 38)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Feature icon in a circle: dim until its service starts, then pops into colour.
private struct FeatureDot: View {
    let feature: Feature
    let lit: Bool

    var body: some View {
        FeatureGlyph(feature: feature, size: 11, color: Color.white.opacity(lit ? 1 : 0.35))
            .frame(width: 26, height: 26)
            .background(Circle().fill(lit ? feature.tint.opacity(0.85) : Color.white.opacity(0.08)))
            .scaleEffect(lit ? 1 : 0.82)
            .shadow(color: lit ? feature.tint.opacity(0.5) : .clear, radius: 6)
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: lit)
            .help(feature.title)
    }
}

/// Hand wave: a few decaying rotations pivoting near the wrist.
struct WaveEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = animatableData - floor(animatableData)          // 0→1 per wave
        let angle = sin(t * .pi * 5) * (.pi / 9) * (1 - t * 0.6)  // up to ±20°
        let pivot = CGPoint(x: size.width * 0.75, y: size.height * 0.9)
        let transform = CGAffineTransform(translationX: pivot.x, y: pivot.y)
            .rotated(by: angle)
            .translatedBy(x: -pivot.x, y: -pivot.y)
        return ProjectionTransform(transform)
    }
}
