// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Snap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Snap", targets: ["Snap"]),
    ],
    targets: [
        // Drawing model, rendering and settings: no AppKit windows, fully unit-tested.
        .target(name: "SnapCore"),
        // The menu bar app: capture, editor window, hotkeys.
        .executableTarget(name: "Snap", dependencies: ["SnapCore"]),
        .testTarget(name: "SnapCoreTests", dependencies: ["SnapCore"]),
    ]
)
