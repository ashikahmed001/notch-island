import AppKit
import SwiftUI

/// Settings ▸ General ▸ Battery saver (one switch for all the energy savings below).
enum Energy {
    /// Set once at launch.
    static weak var flags: FeatureFlags?

    /// On unless switched off in Settings.
    static var saver: Bool { flags?.isOn(.batterySaver) ?? true }
}

/// Battery-friendly motion.
enum Motion {
    /// Decorative animation (music bars, bolt pulse, download arrow) stands still when
    /// "Reduce motion" is on, or in Low Power Mode with Battery saver on.
    /// Progress, timers and alerts still update.
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || (Energy.saver && ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

/// Ticks every `interval` while `live`; otherwise draws once and then stays still.
/// Used for views that stay loaded (but unseen) while the island is closed.
struct LiveSchedule: TimelineSchedule {
    var start: Date = .now
    var interval: TimeInterval = 1
    var live = true

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        // Battery saver off → always tick, like before.
        guard live || !Energy.saver else { return AnyIterator(CollectionOfOne(startDate).makeIterator()) }
        var iterator = PeriodicTimelineSchedule(from: start, by: interval).entries(from: startDate, mode: mode).makeIterator()
        return AnyIterator { iterator.next() }
    }
}
