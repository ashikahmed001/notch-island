// swift-tools-version:5.9
import Foundation
import PackageDescription

// Sparkle (automatic updates) is kept in Vendor/Sparkle — the official release
// (https://github.com/sparkle-project/Sparkle/releases), so builds never download it.
// To update Sparkle: replace Vendor/Sparkle/Sparkle.framework and Vendor/Sparkle/bin.
let sparkle = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Vendor/Sparkle").path

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NotchIsland",
            path: "Sources/NotchIsland",
            swiftSettings: [.unsafeFlags(["-F", sparkle])],
            linkerSettings: [.unsafeFlags([
                "-F", sparkle, "-framework", "Sparkle",
                // Inside the app: Contents/Frameworks. For `swift run`: the Vendor folder.
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", sparkle,
            ])]
        )
    ]
)
