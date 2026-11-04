import Foundation

/// AppleScript + JavaScript for media playing in a browser tab.
/// Each browser has to allow it once: "Allow JavaScript from Apple Events".
enum BrowserMedia {
    /// Sites whose tabs are checked for media (global music / video services).
    static let mediaHosts = [
        "youtube.com", "netflix.com", "soundcloud.com", "twitch.tv", "vimeo.com", "open.spotify.com",
        "music.apple.com", "tv.apple.com", "primevideo.com", "disneyplus.com", "hotstar.com", "max.com",
        "hulu.com", "peacocktv.com", "crunchyroll.com", "dailymotion.com", "bilibili.com", "nicovideo.jp",
        "deezer.com", "tidal.com", "bandcamp.com", "mixcloud.com", "pandora.com", "jiosaavn.com",
        "gaana.com", "wynk.in", "audible.com", "podcasts.apple.com", "zee5.com", "sonyliv.com",
    ]

    /// Picks the page's media element: the one playing, else the last one played.
    private static let pick = "var m=Array.prototype.slice.call(document.querySelectorAll('video,audio')).filter(function(e){return e.currentTime>0||!e.paused});var e=m.filter(function(x){return !x.paused})[0]||m[0];"

    /// state ~|~ title ~|~ artist ~|~ album ~|~ duration ~|~ position ~|~ artwork URL
    static let probe = "(function(){" + pick
        + "if(!e)return '';var s=navigator.mediaSession&&navigator.mediaSession.metadata;"
        + "var t=(s&&s.title)||document.title;var a=(s&&s.artist)||location.hostname.replace('www.','');"
        + "var al=(s&&s.album)||'';var art='';"
        + "if(s&&s.artwork&&s.artwork.length){art=s.artwork[s.artwork.length-1].src}"
        + "else{var og=document.querySelector('meta[property*=image]');if(og)art=og.content}"
        + "var d=isFinite(e.duration)?e.duration:0;"
        + "return [e.paused?'paused':'playing',t,a,al,d,e.currentTime,art].join('~|~')})()"

    static let playPause = "(function(){" + pick + "if(e){if(e.paused){e.play()}else{e.pause()}}return 'ok'})()"

    /// The site's own Next button (YouTube, YouTube Music, SoundCloud, Spotify web), else +10 s.
    static let next = "(function(){var b=document.querySelector('.ytp-next-button,.next-button,.skipControl__next,[data-testid=control-button-skip-forward]');"
        + "if(b){b.click();return 'ok'}" + pick + "if(e)e.currentTime=e.currentTime+10;return 'ok'})()"

    /// The site's own Previous button, else −10 s.
    static let previous = "(function(){var b=document.querySelector('.previous-button,.skipControl__previous,[data-testid=control-button-skip-back]');"
        + "if(b){b.click();return 'ok'}" + pick + "if(e)e.currentTime=Math.max(0,e.currentTime-10);return 'ok'})()"

    /// Finds the media tab: returns probe ~|~ window id ~|~ tab index (a playing tab wins),
    /// "JSOFF" when the browser blocks JavaScript from Apple Events, or "".
    static func query(_ source: MediaSource, separator sep: String) -> String {
        let hosts = mediaHosts.map { "u contains \"\($0)\"" }.joined(separator: " or ")
        let run = source == .safari ? "do JavaScript \"\(probe)\" in t" : "execute t javascript \"\(probe)\""
        return """
        tell application id "\(source.bundleID)"
            set out to ""
            set jsOff to false
            repeat with w in windows
                try
                    set wid to id of w
                    set ti to 0
                    repeat with t in tabs of w
                        set ti to ti + 1
                        set u to ""
                        try
                            set u to URL of t
                        end try
                        if u is missing value then set u to ""
                        if \(hosts) then
                            try
                                set r to \(run)
                                if r is not missing value and r is not "" then
                                    set out to (r as string) & "\(sep)" & wid & "\(sep)" & ti
                                    if out starts with "playing" then return out
                                end if
                            on error errMsg
                                if errMsg contains "JavaScript" then set jsOff to true
                            end try
                        end if
                    end repeat
                end try
            end repeat
            if out is "" and jsOff then return "JSOFF"
            return out
        end tell
        """
    }

    /// Runs one of the control snippets in the tab that's playing.
    static func control(_ source: MediaSource, tab: TrackInfo.BrowserTab, javaScript: String) -> String {
        if source == .safari {
            return "tell application id \"\(source.bundleID)\" to do JavaScript \"\(javaScript)\" in tab \(tab.tab) of window id \(tab.window)"
        }
        return "tell application id \"\(source.bundleID)\" to execute (tab \(tab.tab) of window id \(tab.window)) javascript \"\(javaScript)\""
    }
}
