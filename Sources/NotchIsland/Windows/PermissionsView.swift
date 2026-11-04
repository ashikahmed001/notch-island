import AppKit
import ApplicationServices
import EventKit
import SwiftUI

/// Live status of every permission the app can use, with a way to grant each.
final class PermissionsModel: ObservableObject {
    enum Status: Equatable {
        case granted, denied, notAsked, unknown

        var label: String {
            switch self {
            case .granted: return "Allowed"
            case .denied: return "Denied"
            case .notAsked, .unknown: return "Not yet"
            }
        }
    }

    @Published private(set) var accessibility: Status = .unknown
    @Published private(set) var calendar: Status = .unknown
    @Published private(set) var reminders: Status = .unknown
    @Published private(set) var automation: [MediaSource: Status] = [:]
    @Published private(set) var desktop: Status = .unknown
    @Published private(set) var downloads: Status = .unknown

    let installedPlayers = MediaSource.allCases.filter(\.isInstalled)
    private let calendarService: CalendarService
    private let reminderService: ReminderService
    private var timer: Timer?
    private let queue = DispatchQueue(label: "NotchIsland.Permissions", qos: .userInitiated)
    private static let folderKeyPrefix = "permissions.folder."

    init(calendarService: CalendarService, reminderService: ReminderService) {
        self.calendarService = calendarService
        self.reminderService = reminderService
        refresh()
    }

    /// Re-check every second while the window is open (the user may flip switches in System Settings).
    func startWatching() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let ax: Status = AXIsProcessTrusted() ? .granted : .notAsked
        if ax != accessibility { accessibility = ax }

        let cal = Self.eventKitStatus(.event)
        if cal != calendar { calendar = cal }
        let rem = Self.eventKitStatus(.reminder)
        if rem != reminders { reminders = rem }

        desktop = folderStatus(ScreenshotService.screenshotFolder)
        downloads = folderStatus(DownloadsService.downloadsFolder)

        // Apple Events checks can block briefly — do them off the main thread.
        let players = installedPlayers
        queue.async { [weak self] in
            var result: [MediaSource: Status] = [:]
            for player in players {
                result[player] = Self.automationStatus(player, ask: false)
            }
            DispatchQueue.main.async {
                if self?.automation != result { self?.automation = result }
            }
        }
    }

    // MARK: - Requests

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) {
            openSettings("Privacy_Accessibility")
        }
    }

    func requestCalendar() {
        calendarService.requestAccess()
    }

    func requestReminders() {
        reminderService.requestAccess()
    }

    /// macOS only asks while the player is running, so launch it quietly first.
    func requestAutomation(_ player: MediaSource) {
        if automation[player] == .denied {
            openSettings("Privacy_Automation")
            return
        }
        if !player.isRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        }
        queue.asyncAfter(deadline: .now() + (player.isRunning ? 0 : 2)) { [weak self] in
            _ = Self.automationStatus(player, ask: true)
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    /// Reading the folder makes macOS show its "access files in…" prompt.
    func requestFolder(_ folder: URL) {
        queue.async { [weak self] in
            let ok = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
            UserDefaults.standard.set(ok, forKey: Self.folderKeyPrefix + folder.path)
            DispatchQueue.main.async {
                if !ok { self?.openSettings("Privacy_FilesAndFolders") }
                self?.refresh()
            }
        }
    }

    // MARK: - Status checks

    private static func eventKitStatus(_ type: EKEntityType) -> Status {
        let status = EKEventStore.authorizationStatus(for: type)
        switch status {
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .denied
        default:
            if #available(macOS 14.0, *) {
                return status == .fullAccess ? .granted : .denied
            }
            return .granted
        }
    }

    private static func automationStatus(_ player: MediaSource, ask: Bool) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: player.bundleID)
        guard let descriptor = target.aeDesc else { return .unknown }
        let result = AEDeterminePermissionToAutomateTarget(descriptor, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch result {
        case 0: return .granted                 // noErr
        case -1743: return .denied              // errAEEventNotPermitted
        case -1744: return .notAsked            // errAEEventWouldRequireUserConsent
        default: return .unknown                // e.g. -600: app not running
        }
    }

    /// Folder access can't be checked without prompting, so remember the last answer.
    private func folderStatus(_ folder: URL) -> Status {
        guard let value = UserDefaults.standard.object(forKey: Self.folderKeyPrefix + folder.path) as? Bool else { return .notAsked }
        return value ? .granted : .denied
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("A few permissions")
                        .font(.title2.weight(.semibold))
                    Text("Each one powers a feature. Skip any you don't need — you can change them later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                ForEach(model.installedPlayers, id: \.self) { player in
                    PermissionRow(
                        symbol: "music.note", tint: Feature.nowPlaying.tint,
                        title: "Control \(player.displayName)",
                        detail: "Show what's playing and use the play / skip buttons.",
                        status: model.automation[player] ?? .unknown
                    ) { model.requestAutomation(player) }
                    Divider()
                }
                PermissionRow(
                    symbol: "calendar", tint: Feature.calendar.tint,
                    title: "Calendar",
                    detail: "Show your next meeting and a Join button.",
                    status: model.calendar
                ) { model.requestCalendar() }
                Divider()
                PermissionRow(
                    symbol: "checklist", tint: Feature.reminders.tint,
                    title: "Reminders",
                    detail: "Show a reminder in the notch when it's due, and mark it done.",
                    status: model.reminders
                ) { model.requestReminders() }
                Divider()
                PermissionRow(
                    symbol: "hand.point.up.left", tint: Feature.clipboard.tint,
                    title: "Accessibility",
                    detail: "Paste a clipboard item into the app you're using with one click.",
                    status: model.accessibility
                ) { model.requestAccessibility() }
                Divider()
                PermissionRow(
                    symbol: "camera.viewfinder", tint: Feature.clipboard.tint,
                    title: "Screenshots folder",
                    detail: "Drop new screenshots from the notch.",
                    status: model.desktop
                ) { model.requestFolder(ScreenshotService.screenshotFolder) }
                Divider()
                PermissionRow(
                    symbol: "arrow.down.circle", tint: Feature.downloads.tint,
                    title: "Downloads folder",
                    detail: "Show download progress and finished files.",
                    status: model.downloads
                ) { model.requestFolder(DownloadsService.downloadsFolder) }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))

            HStack {
                Text("Change these anytime in System Settings › Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { model.startWatching() }
        .onDisappear { model.stopWatching() }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let status: PermissionsModel.Status
    let request: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if status == .granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.green)
            } else {
                Button(status == .denied ? "Open Settings" : "Allow", action: request)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 10)
    }
}
