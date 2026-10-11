import AppKit
import CoreGraphics
import SnapmarkCore

enum CaptureMode: String {
    case area, window, screen

    /// screencapture flags: -i interactive (drag, or Space to switch to window picking), -o no window
    /// shadow, -x no shutter sound, -t png even when the user set another screenshot format, since
    /// Snapmark keeps the file as it is.
    var arguments: [String] {
        switch self {
        case .area: ["-i", "-o", "-x", "-t", "png"]
        case .window: ["-i", "-W", "-o", "-x", "-t", "png"]
        case .screen: ["-m", "-x", "-t", "png"]
        }
    }
}

/// A finished capture: screencapture's PNG, still in a temporary file, and the image decoded from it.
struct Shot {
    let doc: Document
    let png: Data
    let file: URL
}

enum Capture {
    /// Runs screencapture off the main thread; calls back on main with the shot, or nil if cancelled.
    /// The caller moves `file` into place: screencapture already wrote a PNG with the right DPI, so
    /// encoding it again would only delay the editor.
    static func run(_ mode: CaptureMode, completion: @escaping (Shot?) -> Void) {
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
            var shot: Shot?
            if let png = try? Data(contentsOf: tmp), let doc = Renderer.loadDocument(data: png) {
                shot = Shot(doc: doc, png: png, file: tmp)
            } else {
                try? FileManager.default.removeItem(at: tmp)
            }
            DispatchQueue.main.async { completion(shot) }
        }
    }
}
