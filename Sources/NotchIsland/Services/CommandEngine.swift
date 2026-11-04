import Foundation
import SwiftUI

/// One line in the command bar's results.
struct CommandResult: Identifiable, Equatable {
    enum Action: Equatable {
        /// Put this text on the clipboard.
        case copy(String)
        case timer(TimeInterval)
        case reminder(title: String, due: Date)
        /// Replace the typed text (example rows).
        case fill(String)
        case none
    }

    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String?
    let action: Action
    /// Short hint on the right: "Copy", "Start", "Add".
    var verb: String?
}

/// Understands what's typed into the command bar. Everything runs on the Mac:
/// no network, no AI — fast, private and predictable.
enum CommandEngine {
    static func results(for raw: String, now: Date = Date()) -> [CommandResult] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return examples }
        let lower = text.lowercased()

        var results: [CommandResult] = []
        if let timer = timerResult(lower) { results.append(timer) }
        if let reminder = reminderResult(text, now: now) { results.append(reminder) }
        if let conversion = conversionResult(lower) { results.append(conversion) }
        if let math = mathResult(lower) { results.append(math) }
        if let time = worldTimeResult(lower, now: now) { results.append(time) }

        if results.isEmpty {
            results.append(CommandResult(id: "none", symbol: "questionmark.circle", tint: .gray,
                                         title: String(localized: "No match"),
                                         subtitle: String(localized: "Try a sum, “5 km to mi”, “timer 10m”, “remind me at 5pm to…” or a city"),
                                         action: .none))
        }
        return results
    }

    static let examples: [CommandResult] = [
        CommandResult(id: "ex-math", symbol: "plus.forwardslash.minus", tint: .orange,
                      title: "1250 * 18% + 40", subtitle: String(localized: "Calculate"), action: .fill("1250 * 18% + 40")),
        CommandResult(id: "ex-unit", symbol: "arrow.left.arrow.right", tint: .cyan,
                      title: "5 km to mi", subtitle: String(localized: "Convert units"), action: .fill("5 km to mi")),
        CommandResult(id: "ex-timer", symbol: "timer", tint: .orange,
                      title: "timer 25m", subtitle: String(localized: "Start a timer"), action: .fill("timer 25m")),
        CommandResult(id: "ex-remind", symbol: "checklist", tint: .yellow,
                      title: "remind me at 5pm to call the bank", subtitle: String(localized: "Add a reminder"),
                      action: .fill("remind me at 5pm to call the bank")),
        CommandResult(id: "ex-time", symbol: "globe", tint: .teal,
                      title: "time in Tokyo", subtitle: String(localized: "Time anywhere"), action: .fill("time in Tokyo")),
    ]

    // MARK: - Numbers

    static func format(_ value: Double, maxDecimals: Int = 6) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = abs(value) >= 1000 ? min(2, maxDecimals) : maxDecimals
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Plain digits for the clipboard ("1234.5", no grouping).
    private static func plain(_ value: Double, maxDecimals: Int = 6) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = maxDecimals
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Calculator

    private static let mathCharacters = CharacterSet(charactersIn: "0123456789.,+-*/^%()x×÷ ")

    static func mathResult(_ lower: String) -> CommandResult? {
        var expression = lower.replacingOccurrences(of: " of ", with: " * ")
        guard expression.unicodeScalars.allSatisfy({ mathCharacters.contains($0) }),
              expression.rangeOfCharacter(from: .decimalDigits) != nil,
              expression.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^%x×÷")) != nil else { return nil }
        expression = expression.replacingOccurrences(of: ",", with: "")
        guard let value = MathParser.evaluate(expression) else { return nil }
        return CommandResult(id: "math", symbol: "equal", tint: .orange,
                             title: format(value), subtitle: String(localized: "Result · Enter copies it"),
                             action: .copy(plain(value)), verb: String(localized: "Copy"))
    }

    /// + − × ÷ ^, parentheses, unary minus and percent ("18%" = 0.18, "200 + 10%" = 220).
    struct MathParser {
        private let chars: [Character]
        private var index = 0

        private init(_ text: String) {
            chars = Array(text.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "×", with: "*")
                .replacingOccurrences(of: "x", with: "*")
                .replacingOccurrences(of: "÷", with: "/"))
        }

        static func evaluate(_ text: String) -> Double? {
            var parser = MathParser(text)
            guard let value = parser.expression(), parser.index == parser.chars.count, value.isFinite else { return nil }
            return value
        }

        private var peek: Character? { index < chars.count ? chars[index] : nil }

        private mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = peek, op == "+" || op == "-" {
                index += 1
                let start = index
                guard let rhs = term() else { return nil }
                // "200 + 10%" means 10% of 200, like a calculator.
                let isPercent = start < index && chars[index - 1] == "%" && !chars[start..<index].contains(where: { "*/^(".contains($0) })
                let amount = isPercent ? value * rhs : rhs
                value = op == "+" ? value + amount : value - amount
            }
            return value
        }

        private mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let op = peek, op == "*" || op == "/" {
                index += 1
                guard let rhs = power() else { return nil }
                if op == "/" && rhs == 0 { return nil }
                value = op == "*" ? value * rhs : value / rhs
            }
            return value
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek == "^" {
                index += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        private mutating func unary() -> Double? {
            if peek == "-" { index += 1; return unary().map { -$0 } }
            if peek == "+" { index += 1; return unary() }
            return postfix()
        }

        private mutating func postfix() -> Double? {
            guard var value = primary() else { return nil }
            while peek == "%" {
                index += 1
                value /= 100
            }
            return value
        }

        private mutating func primary() -> Double? {
            if peek == "(" {
                index += 1
                guard let value = expression(), peek == ")" else { return nil }
                index += 1
                return value
            }
            let start = index
            while let c = peek, c.isNumber || c == "." { index += 1 }
            guard start < index else { return nil }
            return Double(String(chars[start..<index]))
        }
    }

    // MARK: - Units

    private struct UnitInfo {
        let unit: Dimension
        let kind: String
        let symbol: String
    }

    private static let units: [String: UnitInfo] = {
        var map: [String: UnitInfo] = [:]
        func add(_ names: [String], _ unit: Dimension, _ kind: String, _ symbol: String) {
            for name in names { map[name] = UnitInfo(unit: unit, kind: kind, symbol: symbol) }
        }
        add(["mm", "millimeter", "millimeters", "millimetre", "millimetres"], UnitLength.millimeters, "length", "mm")
        add(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], UnitLength.centimeters, "length", "cm")
        add(["m", "meter", "meters", "metre", "metres"], UnitLength.meters, "length", "m")
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], UnitLength.kilometers, "length", "km")
        add(["in", "inch", "inches", "\""], UnitLength.inches, "length", "in")
        add(["ft", "foot", "feet", "'"], UnitLength.feet, "length", "ft")
        add(["yd", "yard", "yards"], UnitLength.yards, "length", "yd")
        add(["mi", "mile", "miles"], UnitLength.miles, "length", "mi")
        add(["mg", "milligram", "milligrams"], UnitMass.milligrams, "mass", "mg")
        add(["g", "gram", "grams"], UnitMass.grams, "mass", "g")
        add(["kg", "kilo", "kilos", "kilogram", "kilograms"], UnitMass.kilograms, "mass", "kg")
        add(["oz", "ounce", "ounces"], UnitMass.ounces, "mass", "oz")
        add(["lb", "lbs", "pound", "pounds"], UnitMass.pounds, "mass", "lb")
        add(["st", "stone", "stones"], UnitMass.stones, "mass", "st")
        add(["c", "°c", "celsius"], UnitTemperature.celsius, "temperature", "°C")
        add(["f", "°f", "fahrenheit"], UnitTemperature.fahrenheit, "temperature", "°F")
        add(["k", "kelvin"], UnitTemperature.kelvin, "temperature", "K")
        add(["ml", "milliliter", "milliliters", "millilitre", "millilitres"], UnitVolume.milliliters, "volume", "ml")
        add(["l", "liter", "liters", "litre", "litres"], UnitVolume.liters, "volume", "l")
        add(["cup", "cups"], UnitVolume.cups, "volume", "cups")
        add(["floz", "fl oz", "fluid ounce", "fluid ounces"], UnitVolume.fluidOunces, "volume", "fl oz")
        add(["gal", "gallon", "gallons"], UnitVolume.gallons, "volume", "gal")
        add(["tsp", "teaspoon", "teaspoons"], UnitVolume.teaspoons, "volume", "tsp")
        add(["tbsp", "tablespoon", "tablespoons"], UnitVolume.tablespoons, "volume", "tbsp")
        add(["kmh", "km/h", "kph"], UnitSpeed.kilometersPerHour, "speed", "km/h")
        add(["mph"], UnitSpeed.milesPerHour, "speed", "mph")
        add(["m/s", "mps"], UnitSpeed.metersPerSecond, "speed", "m/s")
        add(["kn", "knot", "knots"], UnitSpeed.knots, "speed", "kn")
        add(["s", "sec", "secs", "second", "seconds"], UnitDuration.seconds, "duration", "s")
        add(["min", "mins", "minute", "minutes"], UnitDuration.minutes, "duration", "min")
        add(["h", "hr", "hrs", "hour", "hours"], UnitDuration.hours, "duration", "h")
        add(["kb", "kilobyte", "kilobytes"], UnitInformationStorage.kilobytes, "data", "KB")
        add(["mb", "megabyte", "megabytes"], UnitInformationStorage.megabytes, "data", "MB")
        add(["gb", "gigabyte", "gigabytes"], UnitInformationStorage.gigabytes, "data", "GB")
        add(["tb", "terabyte", "terabytes"], UnitInformationStorage.terabytes, "data", "TB")
        add(["kib", "kibibyte", "kibibytes"], UnitInformationStorage.kibibytes, "data", "KiB")
        add(["mib", "mebibyte", "mebibytes"], UnitInformationStorage.mebibytes, "data", "MiB")
        add(["gib", "gibibyte", "gibibytes"], UnitInformationStorage.gibibytes, "data", "GiB")
        add(["sqm", "m2", "m²", "square meter", "square meters"], UnitArea.squareMeters, "area", "m²")
        add(["sqft", "ft2", "ft²", "square foot", "square feet"], UnitArea.squareFeet, "area", "ft²")
        add(["acre", "acres"], UnitArea.acres, "area", "acres")
        add(["ha", "hectare", "hectares"], UnitArea.hectares, "area", "ha")
        return map
    }()

    private static let conversionPattern = try? NSRegularExpression(
        pattern: #"^(-?[0-9][0-9.,]*)\s*([a-z°"'/²0-9 ]+?)\s+(?:to|in|as|into|=)\s+([a-z°"'/²0-9 ]+)$"#)

    static func conversionResult(_ lower: String) -> CommandResult? {
        guard let regex = conversionPattern,
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let valueRange = Range(match.range(at: 1), in: lower),
              let fromRange = Range(match.range(at: 2), in: lower),
              let toRange = Range(match.range(at: 3), in: lower),
              let value = Double(lower[valueRange].replacingOccurrences(of: ",", with: "")),
              let from = units[lower[fromRange].trimmingCharacters(in: .whitespaces)],
              let to = units[lower[toRange].trimmingCharacters(in: .whitespaces)],
              from.kind == to.kind else { return nil }
        let converted = Measurement(value: value, unit: from.unit).converted(to: to.unit).value
        let decimals = abs(converted) < 1 ? 6 : 3
        return CommandResult(id: "unit", symbol: "arrow.left.arrow.right", tint: .cyan,
                             title: "\(format(converted, maxDecimals: decimals)) \(to.symbol)",
                             subtitle: "\(format(value)) \(from.symbol)",
                             action: .copy(plain(converted, maxDecimals: decimals)), verb: String(localized: "Copy"))
    }

    // MARK: - Timer

    private static let timerPatterns: [NSRegularExpression] = [
        #"^(?:timer|t)\s+(.+)$"#,
        #"^(.+?)\s+timer$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func timerResult(_ lower: String) -> CommandResult? {
        var spec: String?
        if lower == "pomodoro" { spec = "25m" }
        for regex in timerPatterns where spec == nil {
            if let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
               let range = Range(match.range(at: 1), in: lower) {
                spec = String(lower[range])
            }
        }
        guard let spec, let seconds = duration(spec), seconds >= 1, seconds <= 24 * 3600 else { return nil }
        return CommandResult(id: "timer", symbol: "timer", tint: .orange,
                             title: String(localized: "Timer · \(TimerService.format(seconds))"),
                             subtitle: String(localized: "Ends at \(Date().addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened))"),
                             action: .timer(seconds), verb: String(localized: "Start"))
    }

    /// "10m", "1h30m", "90s", "1:30", "25" (minutes), "10 min", "2 hours".
    static func duration(_ text: String) -> TimeInterval? {
        let compact = text.replacingOccurrences(of: " ", with: "")
        if let minutes = Double(compact) { return minutes * 60 }
        let clock = compact.split(separator: ":")
        if clock.count == 2, let m = Double(clock[0]), let s = Double(clock[1]), s < 60 { return m * 60 + s }
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)(hours|hour|hrs|hr|h|minutes|minute|mins|min|m|seconds|second|secs|sec|s)"#) else { return nil }
        var total: TimeInterval = 0
        var covered = 0
        for match in regex.matches(in: compact, range: NSRange(compact.startIndex..., in: compact)) {
            guard let numberRange = Range(match.range(at: 1), in: compact),
                  let unitRange = Range(match.range(at: 2), in: compact),
                  let number = Double(compact[numberRange]) else { return nil }
            let unit = compact[unitRange]
            total += number * (unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1)
            covered += match.range.length
        }
        // Every character must belong to a "<number><unit>" piece.
        return covered == (compact as NSString).length && total > 0 ? total : nil
    }

    // MARK: - Reminders

    static func reminderResult(_ text: String, now: Date) -> CommandResult? {
        let lower = text.lowercased()
        guard lower.hasPrefix("remind") else { return nil }
        // Drop "remind me" / "reminder" / "remind".
        var body = text
        for prefix in ["remind me", "reminder", "remind"] where lower.hasPrefix(prefix) {
            body = String(text.dropFirst(prefix.count))
            break
        }
        body = body.trimmingCharacters(in: .whitespaces)

        // The date finder understands "in 20 minutes", "at 5pm", "tomorrow at 9"; teach it "20m".
        let normalized = expandShortUnits(body)
        var due: Date?
        var task = normalized
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let date = match.date, let range = Range(match.range, in: normalized) {
            due = date <= now ? date.addingTimeInterval(24 * 3600) : date
            task.removeSubrange(range)
        }
        task = cleanTask(task)
        let title = task.isEmpty ? String(localized: "Reminder") : task

        guard let due else {
            return CommandResult(id: "remind", symbol: "checklist", tint: .yellow,
                                 title: String(localized: "Remind: \(title)"),
                                 subtitle: String(localized: "Add a time, like “in 20 min” or “at 5pm”"),
                                 action: .none)
        }
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return CommandResult(id: "remind", symbol: "checklist", tint: .yellow,
                             title: String(localized: "Remind: \(title)"),
                             subtitle: formatter.string(from: due),
                             action: .reminder(title: title, due: due), verb: String(localized: "Add"))
    }

    private static func expandShortUnits(_ text: String) -> String {
        var result = text
        let rules: [(String, String)] = [
            (#"\b(\d+)\s*(?:m|min|mins)\b"#, "$1 minutes"),
            (#"\b(\d+)\s*(?:h|hr|hrs)\b"#, "$1 hours"),
        ]
        for (pattern, template) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    /// "to call the bank at" → "call the bank".
    private static func cleanTask(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        let glue: Set<String> = ["to", "at", "in", "on", "by", "about", "that", "for"]
        while let first = words.first, glue.contains(first.lowercased()) { words.removeFirst() }
        while let last = words.last, glue.contains(last.lowercased()) { words.removeLast() }
        let joined = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard let first = joined.first else { return "" }
        return first.uppercased() + joined.dropFirst()
    }

    // MARK: - World time

    private static let cityAliases: [String: String] = [
        "nyc": "America/New_York", "new york": "America/New_York", "sf": "America/Los_Angeles",
        "san francisco": "America/Los_Angeles", "la": "America/Los_Angeles", "seattle": "America/Los_Angeles",
        "boston": "America/New_York", "washington": "America/New_York", "miami": "America/New_York",
        "dallas": "America/Chicago", "austin": "America/Chicago", "houston": "America/Chicago",
        "london": "Europe/London", "uk": "Europe/London", "paris": "Europe/Paris", "berlin": "Europe/Berlin",
        "amsterdam": "Europe/Amsterdam", "madrid": "Europe/Madrid", "rome": "Europe/Rome",
        "zurich": "Europe/Zurich", "stockholm": "Europe/Stockholm", "dubai": "Asia/Dubai",
        "india": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata",
        "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata", "chennai": "Asia/Kolkata", "hyderabad": "Asia/Kolkata",
        "pune": "Asia/Kolkata", "kolkata": "Asia/Kolkata", "beijing": "Asia/Shanghai", "china": "Asia/Shanghai",
        "hong kong": "Asia/Hong_Kong", "tokyo": "Asia/Tokyo", "japan": "Asia/Tokyo", "seoul": "Asia/Seoul",
        "singapore": "Asia/Singapore", "sydney": "Australia/Sydney", "melbourne": "Australia/Melbourne",
        "toronto": "America/Toronto", "vancouver": "America/Vancouver", "mexico city": "America/Mexico_City",
        "sao paulo": "America/Sao_Paulo", "são paulo": "America/Sao_Paulo", "utc": "UTC", "gmt": "GMT",
    ]

    static func worldTimeResult(_ lower: String, now: Date) -> CommandResult? {
        var place = lower
        for prefix in ["what time is it in ", "time in ", "time at "] where place.hasPrefix(prefix) {
            place = String(place.dropFirst(prefix.count))
        }
        if place.hasSuffix(" time") { place = String(place.dropLast(5)) }
        place = place.trimmingCharacters(in: .whitespaces)
        guard place.count >= 2, place.rangeOfCharacter(from: .decimalDigits) == nil,
              let zone = zone(for: place) else { return nil }

        let time = DateFormatter()
        time.timeZone = zone
        time.timeStyle = .short
        time.dateStyle = .none
        let day = DateFormatter()
        day.timeZone = zone
        day.setLocalizedDateFormatFromTemplate("EEEE")

        let offset = zone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)
        let relative: String
        if offset == 0 {
            relative = String(localized: "Same time as you")
        } else {
            let hours = abs(offset) / 3600
            let minutes = (abs(offset) % 3600) / 60
            let amount = minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
            relative = offset > 0 ? String(localized: "\(amount) ahead of you") : String(localized: "\(amount) behind you")
        }
        let name = place.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        let clock = time.string(from: now)
        return CommandResult(id: "time", symbol: "globe", tint: .teal,
                             title: "\(name) · \(clock)",
                             subtitle: "\(day.string(from: now)) · \(relative)",
                             action: .copy(clock), verb: String(localized: "Copy"))
    }

    private static func zone(for place: String) -> TimeZone? {
        if let id = cityAliases[place] { return TimeZone(identifier: id) }
        let wanted = place.replacingOccurrences(of: " ", with: "_")
        if let id = TimeZone.knownTimeZoneIdentifiers.first(where: {
            ($0.split(separator: "/").last.map(String.init) ?? $0).lowercased() == wanted
        }) {
            return TimeZone(identifier: id)
        }
        if place.count <= 5, let zone = TimeZone(abbreviation: place.uppercased()) { return zone }
        return nil
    }
}
