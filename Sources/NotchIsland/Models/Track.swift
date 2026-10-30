import AppKit

enum MediaSource: String, CaseIterable {
    case spotify, music

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        }
    }

    /// Distributed notification each player posts on play / pause / track change.
    var changeNotification: Notification.Name {
        switch self {
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        case .music: return Notification.Name("com.apple.Music.playerInfo")
        }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music: return "Music"
        }
    }

    var symbol: String {
        switch self {
        case .spotify: return "dot.radiowaves.left.and.right"
        case .music: return "music.note"
        }
    }

    /// The player's real app icon (cached).
    var appIcon: NSImage? {
        if let cached = Self.iconCache[self] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Self.iconCache[self] = icon
        return icon
    }

    private static var iconCache: [MediaSource: NSImage] = [:]

    func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}

struct TrackInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var isPlaying: Bool
    /// Radio / live stream: no duration, so no progress bar.
    var isLive: Bool
    /// False for a station between songs (presenter talking).
    var hasSongInfo: Bool = true
    var source: MediaSource
    var positionTimestamp: Date

    var id: String { "\(source.rawValue)|\(title)|\(artist)|\(album)" }

    /// Second line: artist → album → "Live radio" for a station between songs.
    var subtitle: String {
        if !artist.isEmpty { return artist }
        if !album.isEmpty { return album }
        return isLive ? "Live radio" : ""
    }

    func currentPosition(at date: Date) -> Double {
        let elapsed = isPlaying ? date.timeIntervalSince(positionTimestamp) : 0
        let value = position + elapsed
        return duration > 0 ? min(duration, value) : value
    }

    /// Same thing on screen? (Ignores the timestamp a fresh poll always changes.)
    func looksSame(as other: TrackInfo) -> Bool {
        let now = Date()
        return id == other.id && isPlaying == other.isPlaying && isLive == other.isLive
            && hasSongInfo == other.hasSongInfo && duration == other.duration
            && abs(currentPosition(at: now) - other.currentPosition(at: now)) < 1.5
    }
}
