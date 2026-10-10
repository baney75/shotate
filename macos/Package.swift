// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Snapmark",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Snapmark", targets: ["Snapmark"]),
    ],
    targets: [
        // Drawing model, rendering and settings: no AppKit windows, fully unit-tested.
        .target(name: "SnapmarkCore"),
        // The menu bar app: capture, editor window, hotkeys.
        .executableTarget(name: "Snapmark", dependencies: ["SnapmarkCore"]),
        .testTarget(name: "SnapmarkCoreTests", dependencies: ["SnapmarkCore"]),
    ]
)
