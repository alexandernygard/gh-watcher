// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GHWatcher",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "GHWatcher",
            path: "Sources/GHWatcher",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
