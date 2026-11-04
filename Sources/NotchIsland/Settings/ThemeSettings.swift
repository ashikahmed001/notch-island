import Combine
import SwiftUI

/// Settings ▸ Appearance: accent colours, seasonal touches, and your own greeting.
final class ThemeSettings: ObservableObject {
    static let shared = ThemeSettings()

    enum Theme: String, CaseIterable, Identifiable {
        case classic, mono, ocean, sunset, forest, candy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .classic: return String(localized: "Classic")
            case .mono: return String(localized: "Silver")
            case .ocean: return String(localized: "Ocean")
            case .sunset: return String(localized: "Sunset")
            case .forest: return String(localized: "Forest")
            case .candy: return String(localized: "Candy")
            }
        }

        /// Colours handed out to the features in order (nil = each feature's own colour).
        var palette: [Color]? {
            switch self {
            case .classic: return nil
            case .mono: return [Color(white: 0.9), Color(white: 0.78), Color(white: 0.66)]
            case .ocean: return [.cyan, .teal, .blue, .mint, .indigo]
            case .sunset: return [.orange, .pink, .red, .yellow, .purple]
            case .forest: return [.green, .mint, Color(red: 0.62, green: 0.78, blue: 0.3), .teal, .yellow]
            case .candy: return [.pink, .purple, .mint, .yellow, .cyan]
            }
        }

        /// A few colours to preview the theme.
        var swatch: [Color] {
            palette ?? [.pink, .red, .cyan, .orange, .green]
        }
    }

    @Published var theme: Theme { didSet { save() } }
    @Published var seasonal: Bool { didSet { save() } }
    /// Replaces "Good morning" etc. in the welcome greeting (empty = time of day).
    @Published var greeting: String { didSet { save() } }
    /// Replaces your macOS first name in the greeting (empty = account name).
    @Published var name: String { didSet { save() } }

    /// The app's language ("" = follow macOS). Takes effect after a restart.
    @Published var language: String {
        didSet {
            if language.isEmpty {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([language], forKey: "AppleLanguages")
            }
            languageChanged = language != launchLanguage
        }
    }
    @Published private(set) var languageChanged = false
    private let launchLanguage: String

    /// Languages the app is translated into (names in their own language).
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"),
        ("hi", "हिन्दी"), ("ja", "日本語"), ("zh-Hans", "简体中文"),
    ]

    /// Quit and open again (to switch languages).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    private let defaults = UserDefaults.standard

    private init() {
        let saved = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first ?? ""
        // Only a language we ship counts as "chosen"; anything else means "follow macOS".
        let chosen = Self.languages.contains { $0.code == saved } && UserDefaults.standard.persistentDomain(
            forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil ? saved : ""
        language = chosen
        launchLanguage = chosen
        theme = Theme(rawValue: defaults.string(forKey: "appearance.theme") ?? "") ?? .classic
        seasonal = defaults.object(forKey: "appearance.seasonal") as? Bool ?? true
        greeting = defaults.string(forKey: "appearance.greeting") ?? ""
        name = defaults.string(forKey: "appearance.name") ?? ""
    }

    private func save() {
        defaults.set(theme.rawValue, forKey: "appearance.theme")
        defaults.set(seasonal, forKey: "appearance.seasonal")
        defaults.set(greeting, forKey: "appearance.greeting")
        defaults.set(name, forKey: "appearance.name")
    }
}

/// Seasonal touches: a little weather or celebration inside the open island, around the
/// festivals people celebrate across the world.
enum Season: Equatable {
    case winter, newYear, lunarNewYear, holi, eid, diwali, halloween

    var greeting: String? {
        switch self {
        case .winter: return nil
        case .newYear: return String(localized: "Happy New Year")
        case .lunarNewYear: return String(localized: "Happy Lunar New Year")
        case .holi: return String(localized: "Happy Holi")
        case .eid: return String(localized: "Eid Mubarak")
        case .diwali: return String(localized: "Happy Diwali")
        case .halloween: return String(localized: "Happy Halloween")
        }
    }

    var name: String {
        switch self {
        case .winter: return String(localized: "Winter snow (December)")
        case .newYear: return String(localized: "New Year")
        case .lunarNewYear: return String(localized: "Lunar New Year")
        case .holi: return String(localized: "Holi")
        case .eid: return String(localized: "Eid al-Fitr")
        case .diwali: return String(localized: "Diwali")
        case .halloween: return String(localized: "Halloween")
        }
    }

    /// Festival dates that move every year (yyyy-MM-dd), shown for a couple of days around.
    private static let movable: [(Season, [String])] = [
        (.diwali, ["2026-11-08", "2027-10-29", "2028-10-17", "2029-11-05", "2030-10-26"]),
        (.lunarNewYear, ["2027-02-06", "2028-01-26", "2029-02-13", "2030-02-03"]),
        (.holi, ["2027-03-22", "2028-03-11", "2029-03-01", "2030-03-20"]),
        (.eid, ["2027-03-10", "2028-02-27", "2029-02-15", "2030-02-05"]),
    ]

    static func current(_ date: Date = Date()) -> Season? {
        let cal = Calendar.current
        let month = cal.component(.month, from: date), day = cal.component(.day, from: date)
        if (month == 12 && day == 31) || (month == 1 && day <= 2) { return .newYear }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        for (season, dates) in movable {
            for string in dates {
                guard let festival = formatter.date(from: string) else { continue }
                let days = cal.dateComponents([.day], from: cal.startOfDay(for: festival), to: cal.startOfDay(for: date)).day ?? 99
                if (-1...1).contains(days) { return season }
            }
        }
        if month == 10 && day == 31 { return .halloween }
        if month == 12 { return .winter }
        return nil
    }

    /// The next one coming up (for Settings).
    static func upcoming(from date: Date = Date()) -> (Season, Date)? {
        let cal = Calendar.current
        for offset in 0..<400 {
            guard let day = cal.date(byAdding: .day, value: offset, to: date), let season = current(day) else { continue }
            return (season, day)
        }
        return nil
    }
}

/// Falling snow, drifting sparkles or confetti — drawn behind the open island's content.
/// Still in Low Power Mode / Reduce motion, and only while the island is open.
struct SeasonalOverlay: View {
    let season: Season

    private struct Particle {
        let x: Double, speed: Double, size: Double, phase: Double, hue: Int
    }

    private static let particles: [Particle] = (0..<26).map { index in
        // Deterministic "random" so the scene doesn't jump between redraws.
        func r(_ salt: Int) -> Double {
            let value = sin(Double(index * 12_989 + salt * 78_233)) * 43_758.5453
            return value - floor(value)
        }
        return Particle(x: r(1), speed: 0.4 + r(2) * 0.6, size: 1.2 + r(3) * 2.3, phase: r(4), hue: index % 5)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: Motion.reduced)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                for particle in Self.particles {
                    draw(particle, time: time, in: &canvas, size: size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var colors: [Color] {
        switch season {
        case .winter: return [.white]
        case .newYear: return [Color(red: 1, green: 0.84, blue: 0.4), .white, Color(red: 1, green: 0.7, blue: 0.3)]
        case .lunarNewYear: return [.red, Color(red: 1, green: 0.8, blue: 0.3)]
        case .holi: return [.pink, .yellow, .green, .cyan, .purple]
        case .eid: return [Color(red: 1, green: 0.88, blue: 0.55), .white]
        case .diwali: return [Color(red: 1, green: 0.75, blue: 0.3), .orange, Color(red: 1, green: 0.9, blue: 0.6)]
        case .halloween: return [.orange, .purple]
        }
    }

    private func draw(_ p: Particle, time: Double, in canvas: inout GraphicsContext, size: CGSize) {
        let color = colors[p.hue % colors.count]
        switch season {
        case .winter, .newYear:
            // Falling: snow drifts, New Year confetti tumbles.
            let travel = (time * 14 * p.speed + p.phase * size.height).truncatingRemainder(dividingBy: size.height + 10)
            let y = travel - 5
            let x = p.x * size.width + sin(time * 0.8 + p.phase * 6) * 8
            if season == .winter {
                let rect = CGRect(x: x, y: y, width: p.size, height: p.size)
                canvas.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.55)))
            } else {
                var piece = canvas
                piece.translateBy(x: x, y: y)
                piece.rotate(by: .radians(time * 2 * p.speed + p.phase * 6))
                piece.fill(Path(roundedRect: CGRect(x: -p.size, y: -p.size / 2, width: p.size * 2, height: p.size), cornerRadius: 0.6),
                           with: .color(color.opacity(0.8)))
            }
        case .holi:
            // Soft colour puffs rising.
            let travel = (time * 10 * p.speed + p.phase * size.height).truncatingRemainder(dividingBy: size.height + 12)
            let rect = CGRect(x: p.x * size.width, y: size.height - travel, width: p.size * 2.2, height: p.size * 2.2)
            canvas.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.35)))
        case .diwali, .eid, .lunarNewYear, .halloween:
            // Twinkling sparkles in place.
            let twinkle = (sin(time * 2.4 * p.speed + p.phase * 12) + 1) / 2
            let center = CGPoint(x: p.x * size.width, y: (p.phase * 0.85 + 0.05) * size.height)
            let r = p.size * (0.6 + twinkle * 0.8)
            var star = Path()
            star.move(to: CGPoint(x: center.x, y: center.y - r * 1.8))
            star.addLine(to: CGPoint(x: center.x + r * 0.35, y: center.y))
            star.addLine(to: CGPoint(x: center.x, y: center.y + r * 1.8))
            star.addLine(to: CGPoint(x: center.x - r * 0.35, y: center.y))
            star.closeSubpath()
            star.move(to: CGPoint(x: center.x - r * 1.8, y: center.y))
            star.addLine(to: CGPoint(x: center.x, y: center.y + r * 0.35))
            star.addLine(to: CGPoint(x: center.x + r * 1.8, y: center.y))
            star.addLine(to: CGPoint(x: center.x, y: center.y - r * 0.35))
            star.closeSubpath()
            canvas.fill(star, with: .color(color.opacity(0.25 + twinkle * 0.6)))
        }
    }
}
