import AppKit

enum NotchGeometry {
    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: hasNotch) ?? NSScreen.main
    }

    /// Size of the physical notch, or a virtual one sized to the menu bar.
    static func notchSize(for screen: NSScreen) -> CGSize {
        if hasNotch(screen),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // The notch is centred: whatever the two usable "ears" don't cover.
            let width = screen.frame.width - left.width - right.width
            return CGSize(width: ceil(width), height: screen.safeAreaInsets.top)
        }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return CGSize(width: 190, height: max(menuBarHeight, 24))
    }
}
