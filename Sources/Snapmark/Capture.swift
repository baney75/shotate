import AppKit
import CoreGraphics
import SnapmarkCore

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
    /// Runs screencapture off the main thread; calls back on main with the image, or nil if cancelled.
    static func run(_ mode: CaptureMode, completion: @escaping (Document?) -> Void) {
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
            if !message.isEmpty { NSLog("Snapmark: screencapture: %@", message) }
            let doc = FileManager.default.fileExists(atPath: tmp.path) ? Renderer.loadDocument(at: tmp) : nil
            try? FileManager.default.removeItem(at: tmp)
            DispatchQueue.main.async { completion(doc) }
        }
    }
}
