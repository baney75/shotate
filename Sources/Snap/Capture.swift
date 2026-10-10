import AppKit
import CoreGraphics
import SnapCore

enum CaptureMode: String {
    case area, window, screen

    /// screencapture flags: -i interactive (drag, or Space to switch to window picking), -o no window
    /// shadow, -x no shutter sound.
    var arguments: [String] {
        switch self {
        case .area: ["-i", "-o", "-x"]
        case .window: ["-i", "-W", "-o", "-x"]
        case .screen: ["-m", "-x"]
        }
    }
}

enum Capture {
    /// macOS asks once for Screen Recording. Without it screencapture returns only the wallpaper,
    /// so check first and explain instead of failing quietly.
    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "Snap needs Screen Recording permission"
        alert.informativeText = "Turn on Snap in System Settings › Privacy & Security › Screen & System Audio "
            + "Recording, then quit and reopen Snap."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return false
    }

    /// Runs screencapture off the main thread; calls back on main with the image, or nil if cancelled.
    static func run(_ mode: CaptureMode, completion: @escaping (CGImage?) -> Void) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString).png")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = mode.arguments + [tmp.path]
            let err = Pipe()
            p.standardError = err
            do { try p.run() } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            p.waitUntilExit()
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !message.isEmpty { NSLog("Snap: screencapture: %@", message) }
            let image = Renderer.loadImageIfPresent(tmp)
            try? FileManager.default.removeItem(at: tmp)
            DispatchQueue.main.async { completion(image) }
        }
    }
}

extension Renderer {
    static func loadImageIfPresent(_ url: URL) -> CGImage? {
        FileManager.default.fileExists(atPath: url.path) ? loadImage(at: url) : nil
    }
}
