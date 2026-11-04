// swift-tools-version:5.9
import PackageDescription

// Automatic updates (Sparkle) are on hold. To turn them back on, see
// docs/RELEASING.md ▸ Automatic updates. The app code already supports Sparkle
// (`#if canImport(Sparkle)`) and builds without it.
let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NotchIsland",
            path: "Sources/NotchIsland"
        )
    ]
)
