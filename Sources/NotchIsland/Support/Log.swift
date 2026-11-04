import os

/// Readable diagnostics. Watch them with:
///   log stream --predicate 'subsystem == "app.notchisland"' --style compact
enum Log {
    static let island = Logger(subsystem: "app.notchisland", category: "island")
    static let battery = Logger(subsystem: "app.notchisland", category: "battery")
    static let api = Logger(subsystem: "app.notchisland", category: "api")
    static let claude = Logger(subsystem: "app.notchisland", category: "claude-app")
    static let downloads = Logger(subsystem: "app.notchisland", category: "downloads")
}
