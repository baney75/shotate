import AppKit
import CoreGraphics
import ShotateCore

enum CaptureMode: String {
    case area, window, screen

    /// screencapture flags: -i interactive (drag, or Space to switch to window picking), -o no window
    /// shadow, -x no shutter sound, -t png even when the user set another screenshot format, since
    /// Shotate keeps the file as it is.
    var arguments: [String] {
        switch self {
        case .area: ["-i", "-o", "-x", "-t", "png"]
        case .window: ["-i", "-W", "-o", "-x", "-t", "png"]
        case .screen: ["-m", "-x", "-t", "png"]
        }
    }
}

/// A finished capture: its PNG, in a temporary file and in memory, and the image.
struct Shot {
    let doc: Document
    let png: Data
    let file: URL
}

enum Capture {
    /// Captures with ScreenCaptureKit (screencapture before macOS 14, or if that fails before anything
    /// is picked); calls back on main with the shot, or nil if cancelled. The caller moves `file` into
    /// place, so the PNG is encoded once.
    static func run(_ mode: CaptureMode, completion: @escaping (Shot?) -> Void) {
        guard #available(macOS 14.0, *) else { return runScreencapture(mode, completion: completion) }
        NativeCapture.run(mode) { result in
            switch result {
            case .cancelled: completion(nil)
            case .failed: runScreencapture(mode, completion: completion)
            case let .image(image, dpi): save(image, dpi: dpi, completion: completion)
            }
        }
    }

    /// Encodes and writes the PNG off the main thread.
    private static func save(_ image: CGImage, dpi: CGFloat, completion: @escaping (Shot?) -> Void) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString).png")
        DispatchQueue.global(qos: .userInitiated).async {
            var shot: Shot?
            if let png = Renderer.pngData(image, dpi: dpi), (try? png.write(to: tmp)) != nil {
                shot = Shot(doc: Document(image: image, dpi: dpi), png: png, file: tmp)
            }
            DispatchQueue.main.async { completion(shot) }
        }
    }

    /// Runs screencapture off the main thread. It already writes a PNG with the right DPI.
    private static func runScreencapture(_ mode: CaptureMode, completion: @escaping (Shot?) -> Void) {
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
            if !message.isEmpty { NSLog("Shotate: screencapture: %@", message) }
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
