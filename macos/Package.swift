// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shotate",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Shotate", targets: ["Shotate"]),
    ],
    targets: [
        // Drawing model, rendering and settings: no AppKit windows, fully unit-tested.
        .target(name: "ShotateCore"),
        // The menu bar app: capture, editor window, hotkeys.
        .executableTarget(name: "Shotate", dependencies: ["ShotateCore"]),
        .testTarget(name: "ShotateCoreTests", dependencies: ["ShotateCore"]),
    ]
)
