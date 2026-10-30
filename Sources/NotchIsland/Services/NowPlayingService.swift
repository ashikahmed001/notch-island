import AppKit

/// Now Playing for Spotify and Apple Music via AppleScript.
///
/// Why not MediaRemote? Apple locked the private MediaRemote framework down in
/// macOS 15.4, so third-party apps can't read system-wide Now Playing anymore.
///
/// All AppleScript runs on a background serial queue: a single Apple Event can
/// take 50–100 ms, which would otherwise stutter the island's animations.
final class NowPlayingService: ObservableObject {
    enum Command: String {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    @Published private(set) var track: TrackInfo?
    @Published private(set) var artwork: NSImage?
    /// Two vivid colours from the artwork (for the audio-bar gradient). Empty → white.
    @Published private(set) var artworkColors: [NSColor] = []

    var isActivelyPlaying: Bool { track?.isPlaying == true }

    /// Feature flag. Starts off; the app enables it after the launch greeting.
    /// When off, no AppleScript runs at all.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { refresh() } else { apply([]) }
        }
    }

    /// Paused while the Mac is locked: keeps the current state, just stops asking.
    var isPaused = false {
        didSet {
            if oldValue && !isPaused { refresh() }
        }
    }

    /// Feature flag: allow the iTunes Search API fallback for covers.
    var allowsOnlineLookup = true

    private static let separator = "~|~"

    // Background (scriptQueue) state
    private let scriptQueue = DispatchQueue(label: "NotchIsland.AppleScript", qos: .userInitiated)
    private var scripts: [String: NSAppleScript] = [:]
    private var loggedErrors = Set<String>()

    // Main-thread state
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var refreshInFlight = false
    private var refreshPending = false
    private var artworkTrackID: String?
    private var artworkAttempts = 0
    private var artworkData: Data?
    /// Radio: when the current on-air song was first seen, and known song lengths (from the catalog).
    private var streamSong: (title: String, start: Date)?
    private var streamSongLengths: [String: Double] = [:]

    private struct RawTrack {
        let source: MediaSource
        let parts: [String]
    }

    init() {
        let distributed = DistributedNotificationCenter.default()
        for source in MediaSource.allCases {
            let token = distributed.addObserver(forName: source.changeNotification, object: nil, queue: .main) { [weak self] _ in
                // Players post the notification slightly before their state settles.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.refresh() }
            }
            observers.append((distributed, token))
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
            observers.append((workspace, token))
        }

        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 1
        refresh()
    }

    deinit {
        timer?.invalidate()
        observers.forEach { center, token in center.removeObserver(token) }
    }

    // MARK: - Public

    func send(_ command: Command) {
        guard isEnabled, let source = track?.source else { return }
        runScript("tell application id \"\(source.bundleID)\" to \(command.rawValue)") { _ in }
        if command == .playPause, var current = track {
            current.position = current.currentPosition(at: Date())
            current.positionTimestamp = Date()
            current.isPlaying.toggle()      // optimistic UI
            track = current
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh() }
    }

    func refresh() {
        guard isEnabled, !isPaused else { return }
        guard !refreshInFlight else {
            refreshPending = true
            return
        }
        // Only talk to players that are already running — `tell application`
        // would otherwise launch them.
        let sources = MediaSource.allCases.filter { $0.isInstalled && $0.isRunning }
        guard !sources.isEmpty else {
            apply([])
            return
        }
        refreshInFlight = true
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let raws = sources.compactMap { self.queryRaw($0) }
            DispatchQueue.main.async {
                self.refreshInFlight = false
                self.apply(raws)
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }

    // MARK: - State (main thread)

    private func apply(_ raws: [RawTrack]) {
        let candidates = raws.compactMap(makeTrack)
        let newTrack = candidates.first(where: { $0.isPlaying }) ?? candidates.first

        switch (track, newTrack) {
        case (nil, nil):
            break
        case let (old?, new?) where old.looksSame(as: new):
            break   // nothing visible changed — don't re-render
        default:
            track = newTrack
        }

        if newTrack?.id != artworkTrackID {
            artworkTrackID = newTrack?.id
            artworkAttempts = 0
            artworkData = nil
            artwork = nil
            if let newTrack {
                loadArtwork(for: newTrack)
                // Keep the previous colours (no flash); only drop them if this track never gets art.
                let id = newTrack.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.artworkTrackID == id, self.artworkData == nil else { return }
                    self.artworkColors = []
                }
            } else {
                artworkColors = []
            }
        }
    }

    private func makeTrack(_ raw: RawTrack) -> TrackInfo? {
        let parts = raw.parts
        var title = parts[1]
        var artist = parts[2]
        let album = parts[3]
        var duration = Self.number(parts[4])
        if duration <= 0 { duration = Self.clockSeconds(parts[7]) }   // "3:16" → 196

        let rawStreamTitle = parts[6].trimmingCharacters(in: .whitespacesAndNewlines)
        let isRadio = !rawStreamTitle.isEmpty || parts[8] == "true"
        var streamTitle = rawStreamTitle

        if !streamTitle.isEmpty {
            if streamTitle != streamSong?.title { streamSong = (streamTitle, Date()) }
            // Stations keep the last song's title while the presenter talks.
            // Once the song's real length (+ grace) has passed, treat it as "On air".
            if let length = streamSongLengths[streamTitle],
               let start = streamSong?.start,
               Date().timeIntervalSince(start) > length + 10 {
                streamTitle = ""
            }
        }

        if isRadio && streamTitle.isEmpty {
            artist = "On air"
        }
        if !streamTitle.isEmpty {
            // Radio: the song on air is the title, the station is the subtitle.
            artist = title
            title = streamTitle
        }

        return TrackInfo(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: Self.number(parts[5]),
            isPlaying: parts[0] == "playing",
            isLive: isRadio,
            hasSongInfo: !isRadio || !streamTitle.isEmpty,
            source: raw.source,
            positionTimestamp: Date()
        )
    }

    // MARK: - Artwork (main thread)

    private func loadArtwork(for track: TrackInfo) {
        let expectedID = track.id
        switch track.source {
        case .music:
            runScript("tell application id \"\(track.source.bundleID)\" to get raw data of artwork 1 of current track") { [weak self] result in
                guard let self, self.artworkTrackID == expectedID else { return }
                if let data = result?.data { self.setArtwork(data, for: expectedID) }

                if track.isLive {
                    // Radio only exposes the station logo — look up the song's real cover.
                    if track.hasSongInfo {
                        self.fetchCatalogArtwork(term: track.title, expectedID: expectedID, lengthKey: track.title)
                    }
                    return
                }
                // Right after a track change Music often returns no cover or the previous
                // one, so re-read a few times; changed bytes replace the image.
                self.artworkAttempts += 1
                if self.artworkAttempts < 4 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard let self, self.artworkTrackID == expectedID, let current = self.track else { return }
                        self.loadArtwork(for: current)
                    }
                } else if self.artworkData == nil {
                    self.fetchCatalogArtwork(term: "\(track.title) \(track.artist)", expectedID: expectedID)
                }
            }

        case .spotify:
            runScript("tell application id \"\(track.source.bundleID)\" to get artwork url of current track") { result in
                guard let urlString = result?.stringValue, let url = URL(string: urlString) else { return }
                URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { self?.setArtwork(data, for: expectedID) }
                }.resume()
            }
        }
    }

    /// Only touches the UI when the image actually changed and still belongs to the current track.
    private func setArtwork(_ data: Data, for trackID: String) {
        guard artworkTrackID == trackID, data != artworkData, let image = NSImage(data: data) else { return }
        artworkData = data
        artwork = image
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let colors = image.vibrantColors()
            DispatchQueue.main.async {
                guard let self, self.artworkTrackID == trackID, colors != self.artworkColors else { return }
                self.artworkColors = colors
            }
        }
    }

    /// Public iTunes Search API (no key needed) → 600×600 cover (+ song length for radio).
    private func fetchCatalogArtwork(term: String, expectedID: String, lengthKey: String? = nil) {
        guard allowsOnlineLookup else { return }
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier.lowercased() ?? "us"),
        ]
        guard let url = components?.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["results"] as? [[String: Any]])?.first
            else { return }
            if let lengthKey, let millis = (first["trackTimeMillis"] as? NSNumber)?.doubleValue, millis > 0 {
                DispatchQueue.main.async { self?.streamSongLengths[lengthKey] = millis / 1000 }
            }
            guard let small = first["artworkUrl100"] as? String,
                  let large = URL(string: small.replacingOccurrences(of: "100x100", with: "600x600"))
            else { return }
            URLSession.shared.dataTask(with: large) { imageData, _, _ in
                guard let imageData else { return }
                DispatchQueue.main.async { self?.setArtwork(imageData, for: expectedID) }
            }.resume()
        }.resume()
    }

    // MARK: - AppleScript (scriptQueue)

    private func queryRaw(_ source: MediaSource) -> RawTrack? {
        let sep = Self.separator
        let durationExpr = source == .spotify ? "((duration of theTrack) / 1000)" : "(duration of theTrack)"
        // Only Music has radio stations; their "current stream title" is the song on air.
        let streamExpr = source == .music ? "current stream title" : "\"\""
        // Fallbacks when `duration` is missing (common for streamed Apple Music tracks).
        let finishExpr = source == .music ? "finish of theTrack" : "0"
        let timeExpr = source == .music ? "time of theTrack" : "\"\""
        // Radio stations are URL tracks / have a stream URL, even between songs.
        let radioBlock = source == .music ? """
            try
                if class of theTrack is URL track then set isRadio to true
            end try
            try
                if current stream URL is not missing value and current stream URL is not "" then set isRadio to true
            end try
        """ : ""
        // Every property is read defensively: radio/live tracks return `missing value`
        // for duration, artist, etc., which would otherwise break the whole script.
        let script = """
        tell application id "\(source.bundleID)"
            if player state is stopped then return ""
            set theTrack to current track
            set trackName to ""
            set trackArtist to ""
            set trackAlbum to ""
            set trackDuration to 0
            set playerPos to 0
            set streamName to ""
            try
                set trackName to name of theTrack
            end try
            try
                set trackArtist to artist of theTrack
            end try
            try
                set trackAlbum to album of theTrack
            end try
            try
                set trackDuration to \(durationExpr)
            end try
            try
                set playerPos to player position
            end try
            try
                set streamName to \(streamExpr)
            end try
            if trackName is missing value then set trackName to ""
            if trackArtist is missing value then set trackArtist to ""
            if trackAlbum is missing value then set trackAlbum to ""
            if trackDuration is missing value then set trackDuration to 0
            if playerPos is missing value then set playerPos to 0
            if streamName is missing value then set streamName to ""
            if trackDuration is 0 then
                try
                    set trackDuration to \(finishExpr)
                end try
                if trackDuration is missing value then set trackDuration to 0
            end if
            set trackTime to ""
            try
                set trackTime to \(timeExpr)
            end try
            if trackTime is missing value then set trackTime to ""
            set isRadio to false
        \(radioBlock)
            return (player state as string) & "\(sep)" & trackName & "\(sep)" & trackArtist & "\(sep)" & trackAlbum & "\(sep)" & trackDuration & "\(sep)" & playerPos & "\(sep)" & streamName & "\(sep)" & trackTime & "\(sep)" & (isRadio as string)
        end tell
        """
        guard let output = execute(script)?.stringValue, !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: sep)
        guard parts.count >= 9 else { return nil }
        return RawTrack(source: source, parts: parts)
    }

    /// Runs a script off the main thread, then calls back on main.
    private func runScript(_ source: String, completion: @escaping (NSAppleEventDescriptor?) -> Void) {
        scriptQueue.async { [weak self] in
            let result = self?.execute(source)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Compiles once, then caches. scriptQueue only.
    private func execute(_ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = scripts[source] {
            script = cached
        } else {
            guard let compiled = NSAppleScript(source: source) else { return nil }
            scripts[source] = compiled
            script = compiled
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            if loggedErrors.insert("\(number) \(message)").inserted {
                if number == -1743 {
                    NSLog("NotchIsland: Automation permission denied. Enable it in System Settings → Privacy & Security → Automation.")
                } else {
                    NSLog("NotchIsland: AppleScript error %d: %@", number, message)
                }
            }
            return nil
        }
        return result
    }

    // MARK: - Parsing

    /// Parses "m:ss" or "h:mm:ss".
    private static func clockSeconds(_ string: String) -> Double {
        let fields = string.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Double($0) }
        guard !fields.isEmpty else { return 0 }
        return fields.reduce(0) { $0 * 60 + $1 }
    }

    /// AppleScript formats reals with the user's locale (e.g. "245,5").
    private static func number(_ string: String) -> Double {
        Double(string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}
