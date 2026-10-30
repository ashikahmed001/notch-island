# Notch Island

A Dynamic Island for the MacBook notch, built with SwiftUI and AppKit.

## Features
- **The island.** A black island over the notch (a virtual one on Macs without a notch). Works across Spaces and over full-screen apps; clicks pass through while collapsed.
- **Hover to expand** with a Dynamic Island–style spring, blur-in content and tabs for Music, Calendar, Clipboard and Timer.
- **Now Playing** (Apple Music and Spotify): artwork, progress, controls; radio shows LIVE and "On air" while the presenter talks.
- **Compact live activities:** artwork + audio bars while music plays, a countdown ring while a timer runs.
- **Battery:** exact-level glyph, time to full/empty, plug-in, full and low-battery alerts.
- **Clipboard:** last 8 copies with previews; click to paste, ⌥-click to copy, drag out; a "Copied" preview drops down when you copy.
- **Timer:** presets, pause, +1 min; when it ends the island opens, shakes and chimes until you dismiss it.
- **Calendar:** next meeting countdown and a Join button for Zoom / Meet / Teams / Webex links.
- **Screenshot shelf:** new screenshots drop from the notch with a thumbnail and join the clipboard shelf, ready to drag.
- **Downloads:** progress ring while a browser downloads, then "Downloaded" and the file on the shelf (right-click › Show in Finder).
- **Settings window** (⌘,) and a **permissions screen** on first launch.
- **Lock & Unlock:** padlock animation on unlock, "while you were away" summary, background checks paused while locked.
- **Feature flags:** every feature and option can be switched on/off from the menu bar icon; off means fully stopped.
- Menu bar icon with Quit; no Dock icon.

## Requirements
- macOS 13 Ventura or later
- Xcode 15+ or the Command Line Tools (`xcode-select --install`)

## Run it
```bash
cd NotchIsland
swift run --build-system native   # quick dev run from Terminal
# or
./scripts/bundle.sh && open build/NotchIsland.app   # proper .app bundle
# or
open Package.swift           # opens in Xcode → ⌘R
```

On first launch while music is playing, macOS asks for **Automation** permission to control Music or Spotify. Allow it. When you use `swift run`, the prompt is attributed to Terminal. If you denied it, re-enable it in System Settings → Privacy & Security → Automation.

## Project structure
```
Sources/NotchIsland/
├── App/
│   └── NotchIslandApp.swift        Entry point, menu-bar item, one island per notched screen
├── Window/
│   ├── NotchPanel.swift            Borderless, non-activating panel above the menu bar
│   ├── NotchWindowController.swift Hover tracking, expand/collapse, drag & alert handling
│   └── NotchGeometry.swift         Notch size from safe-area insets (virtual notch fallback)
├── Models/
│   ├── Track.swift                 MediaSource + TrackInfo
│   └── ClipItem.swift              Clipboard item (text / image / files) + previews
├── Services/                       Data sources — no UI code
│   ├── NowPlayingService.swift     Music & Spotify via AppleScript (background queue) + iTunes artwork
│   ├── BatteryService.swift        IOKit power-source notifications
│   ├── ClipboardService.swift      Pasteboard history, copy/paste (⌘V via Accessibility)
│   ├── TimerService.swift          Countdown, pause/resume, ringing + chimes
│   ├── CalendarService.swift       Next meeting via EventKit
│   ├── ScreenshotService.swift     Watches the screenshot folder
│   ├── DownloadsService.swift      Browser download progress (NSProgress file subscriptions)
│   └── LockService.swift           Screen lock / unlock events
├── Settings/
│   └── FeatureFlags.swift          Every feature + option as a persisted on/off switch
├── Windows/
│   ├── SettingsView.swift          Settings window (Features / General / About)
│   ├── PermissionsView.swift       First-run permissions screen with live status
│   └── AppWindows.swift            Window helper
├── ViewModel/
│   └── IslandViewModel.swift       Mode, tabs, peeks, sizes, springs — glue between services and views
└── Views/
    ├── IslandView.swift            Root: animated notch shape hosting both layouts
    ├── Compact/CompactView.swift   Collapsed live activities (music, timer, peeks, copied preview)
    ├── Expanded/                   ExpandedView (tabs) + NowPlaying / Clipboard / Timer panels
    ├── Components/                 ArtworkView, AudioBars, Battery, TimerViews, Placeholder
    └── Effects/                    NotchShape, BlurMorph transition, ShakeEffect
```

**Data flow:** Services publish state → `IslandViewModel` combines it and decides what the island shows and how big it is → Views render. `NotchWindowController` drives open/close from the mouse and timer alerts.

## Known limitations
- **Now Playing only covers Spotify and Apple Music.** Since macOS 15.4, Apple blocks third-party access to the system-wide MediaRemote Now Playing info, so browser audio (YouTube etc.) isn't shown. Workaround to explore: the `mediaremote-adapter` approach.
- Ad-hoc signing means macOS may ask for Automation permission again after each rebuild. A Developer ID signature fixes this.
- One island on one screen: the notched display, or else the main display.

## Roadmap ideas
1. Volume and brightness HUD replacement (`CGEventTap` + CoreAudio; needs Accessibility permission)
2. Next calendar event (EventKit)
3. File shelf: drag files onto the island, then AirDrop or share them
4. Custom timer durations, Pomodoro cycles
5. Settings window, launch at login (`SMAppService`), Sparkle updates, Developer ID notarization
