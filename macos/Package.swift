// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Yapshot",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Yapshot", targets: ["Yapshot"]),
    ],
    targets: [
        // Drawing model, rendering and settings: no AppKit windows, fully unit-tested.
        .target(name: "YapshotCore"),
        // The menu bar app: capture, editor window, hotkeys.
        .executableTarget(name: "Yapshot", dependencies: ["YapshotCore"]),
        .testTarget(name: "YapshotCoreTests", dependencies: ["YapshotCore"]),
    ]
)
