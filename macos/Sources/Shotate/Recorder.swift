import AppKit
import AVFoundation
import ScreenCaptureKit
import ShotateCore

/// What a recording shows.
enum RecordTarget {
    /// In AppKit global coordinates, within the screen.
    case area(CGRect, NSScreen)
    case screen(NSScreen)
    /// Every window of one app on the screen that showed the window you clicked, and that app's log.
    case app(pid_t, NSScreen)
}

/// A saved recording. Recording an app also saves what the app logged meanwhile, beside the video.
struct SavedRecording {
    let video: URL
    let log: URL?
    let logText: String?
}

/// The app's way into recording. Recording needs macOS 15 and the macOS 15 SDK (Swift 6 / Xcode 16);
/// Shotate updates by building on your Mac, so an older toolchain still builds, just without it.
enum Recording {
    static var isSupported: Bool {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    static var isActive: Bool {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) { return Recorder.current != nil }
        #endif
        return false
    }

    /// See `Recorder.start`. Returns false when this build or macOS can't record.
    @discardableResult
    static func start(_ target: RecordTarget, to file: URL, done: @escaping (SavedRecording?, Error?) -> Void) -> Bool {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            Recorder.start(target, to: file, done: done)
            return true
        }
        #endif
        return false
    }

    static func stop() {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) { Recorder.current?.stop() }
        #endif
    }
}

#if compiler(>=6.0)
/// Records an area, a screen or an app to an MP4 with ScreenCaptureKit, from `start` until `stop()`.
/// A small bar shows the time and a Stop button, and a red outline marks a recorded area; neither is
/// in the video. No sound: Shotate never asks for the microphone.
@available(macOS 15.0, *)
final class Recorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private(set) static var current: Recorder?

    let file: URL
    private let target: RecordTarget
    private var stream: SCStream?
    private var log: AppLog?
    private var indicator: RecordingIndicator?
    private var stopping = false
    /// The first frame is in the file.
    private var started = false
    private let done: (SavedRecording?, Error?) -> Void

    /// Starts recording `target` into `file`. `done` runs on main once the file is finished, or with
    /// the error that stopped it.
    static func start(_ target: RecordTarget, to file: URL, done: @escaping (SavedRecording?, Error?) -> Void) {
        let r = Recorder(target: target, file: file, done: done)
        current = r
        let stop: () -> Void = { [weak r] in r?.stop() }
        switch target {
        case let .area(rect, screen):
            r.indicator = RecordingIndicator(area: rect, outlined: true, screen: screen, title: nil, stop: stop)
        case let .screen(screen):
            r.indicator = RecordingIndicator(area: screen.frame, outlined: false, screen: screen, title: nil, stop: stop)
        case let .app(pid, screen):
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
            r.indicator = RecordingIndicator(area: screen.frame, outlined: false, screen: screen, title: name, stop: stop)
        }
        Task { @MainActor in
            do { try await r.begin() } catch { r.finish(error) }
        }
    }

    private init(target: RecordTarget, file: URL, done: @escaping (SavedRecording?, Error?) -> Void) {
        self.target = target
        self.file = file
        self.done = done
    }

    @MainActor
    private func begin() async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The indicator's windows are already up, so they can be named and kept out of the video.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let screen: NSScreen
        switch target {
        case let .area(_, s), let .screen(s), let .app(_, s): screen = s
        }
        guard let display = NativeCapture.display(for: screen, in: content) else {
            throw Self.error("That screen isn't available to record.")
        }
        let ours = Set(indicator?.windowIDs ?? [])
        let notOurs = content.windows.filter { ours.contains($0.windowID) }
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        var size = screen.frame.size
        switch target {
        case let .area(rect, _):
            filter = SCContentFilter(display: display, excludingWindows: notOurs)
            config.sourceRect = CaptureGeometry.displayRect(of: rect, screenFrame: screen.frame)
            size = rect.size
        case .screen:
            filter = SCContentFilter(display: display, excludingWindows: notOurs)
        case let .app(pid, _):
            guard let app = content.applications.first(where: { $0.processID == pid }) else {
                throw Self.error("That app quit before recording started.")
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            log = try AppLog(pid: pid, file: file.deletingPathExtension().appendingPathExtension("log"))
        }
        let pixels = CaptureGeometry.videoSize(of: size, scale: screen.backingScaleFactor)
        config.width = pixels.width
        config.height = pixels.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.showMouseClicks = true
        config.captureResolution = .best
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = file
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: self))
        try await stream.startCapture()
        // Only a running stream can be stopped; a stop that came while starting is handled here.
        self.stream = stream
        if stopping { try? await stream.stopCapture() }
    }

    /// Ends the recording; `done` runs once the file is written.
    func stop() {
        guard !stopping else { return }
        stopping = true
        indicator?.close()
        finishSoon()
        // Still starting: `begin` stops the stream as soon as it is running.
        guard let stream else { return }
        Task { @MainActor in
            do { try await stream.stopCapture() } catch { finish(error) }
        }
    }

    /// The recording output reports when the file is complete. If it never does, don't leave
    /// Shotate stuck recording. A file that started can take a while to finish; one that never got
    /// a frame has nothing to wait for.
    private func finishSoon() {
        let wait: Double = started ? 60 : 5
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            if self.started {
                self.finish(Self.error("The video didn't finish saving. It may be incomplete."), keepFile: true)
            } else {
                self.finish(nil)
            }
        }
    }

    /// `keepFile` keeps what was written despite the error, so nothing is thrown away unasked.
    private func finish(_ error: Error?, keepFile: Bool = false) {
        guard Recorder.current === self else { return }
        Recorder.current = nil
        stopping = true
        indicator?.close()
        indicator = nil
        let written = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 } ?? false
        let failure = error ?? (written ? nil : Self.error("Nothing was recorded. Try recording for a little longer."))
        let keep = written && (failure == nil || keepFile)
        if !keep { try? FileManager.default.removeItem(at: file) }
        guard let log else {
            return done(keep ? SavedRecording(video: file, log: nil, logText: nil) : nil, failure)
        }
        log.stop { [file, done] text in
            if !keep { try? FileManager.default.removeItem(at: log.file) }
            done(keep ? SavedRecording(video: file, log: log.file, logText: text) : nil, failure)
        }
    }

    private static func error(_ message: String) -> Error {
        CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: SCRecordingOutputDelegate, SCStreamDelegate (called off main)

    func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        DispatchQueue.main.async {
            self.started = true
            self.indicator?.startClock()
        }
    }

    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        DispatchQueue.main.async { self.finish(nil) }
    }

    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async { self.finish(error) }
    }

    /// macOS stopped the stream, for example from the screen-recording item in the menu bar. The
    /// recording output still finishes the file.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Shotate: recording stream stopped: %@", error.localizedDescription)
        DispatchQueue.main.async {
            guard !self.stopping else { return }
            self.stopping = true
            self.indicator?.close()
            self.finishSoon()
        }
    }
}
#endif

/// What one app writes to the system log while it is recorded, debug messages included, through
/// `log stream`. Its helper processes count too: anything run from inside its app bundle.
final class AppLog {
    let file: URL
    private let process = Process()

    init(pid: pid_t, file: URL) throws {
        self.file = file
        let app = NSRunningApplication(processIdentifier: pid)
        let predicate: String
        if let bundle = app?.bundleURL?.path {
            let quoted = bundle.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            predicate = "processImagePath BEGINSWITH \"\(quoted)/\""
        } else {
            predicate = "processIdentifier == \(pid)"
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        let header = "# Log of \(app?.localizedName ?? "process \(pid)") (\(app?.bundleIdentifier ?? "no bundle ID"), "
            + "pid \(pid)) while Shotate recorded it, from \(f.string(from: Date())).\n"
            + "# log stream --level debug --predicate '\(predicate)'\n"
        try Data(header.utf8).write(to: file)
        let out = try FileHandle(forWritingTo: file)
        out.seekToEndOfFile()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--level", "debug", "--style", "compact", "--predicate", predicate]
        process.standardOutput = out
        process.standardError = out
        try process.run()
    }

    /// Ends the stream (as Ctrl-C would, so its last lines are written) and calls back on main with
    /// the whole log.
    func stop(_ completion: @escaping (String) -> Void) {
        let deliver = { [file] in
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            DispatchQueue.main.async { completion(text) }
        }
        guard process.isRunning else { return deliver() }
        process.terminationHandler = { _ in deliver() }
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { process.terminate() }
        }
    }
}

/// The bar with the time and Stop, and around a recorded area a red outline. Neither takes focus
/// from the app you are recording.
final class RecordingIndicator {
    private let outline: NSPanel?
    private let bar: NSPanel
    private let clock = NSTextField(labelWithString: "0:00")
    private var timer: Timer?

    var windowIDs: [CGWindowID] { ([outline, bar].compactMap { $0 }).map { CGWindowID($0.windowNumber) } }

    init(area: CGRect, outlined: Bool, screen: NSScreen, title: String?, stop: @escaping () -> Void) {
        if outlined {
            // Drawn just outside the area, so it would stay out of the video even if it were captured.
            let pad: CGFloat = 3
            let outline = Self.panel(area.insetBy(dx: -pad, dy: -pad))
            outline.ignoresMouseEvents = true
            let border = NSView()
            border.wantsLayer = true
            border.layer?.borderColor = NSColor.systemRed.cgColor
            border.layer?.borderWidth = 2
            border.layer?.cornerRadius = 2
            outline.contentView = border
            self.outline = outline
        } else {
            outline = nil
        }

        let dot = NSImageView(image: NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")!)
        dot.contentTintColor = .systemRed
        clock.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let button = FirstClickButton(title: "Stop", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.target = button
        button.action = #selector(FirstClickButton.clicked)
        button.onClick = stop
        button.toolTip = "Stop recording and save the video"
        var views: [NSView] = [dot]
        if let title {
            let name = NSTextField(labelWithString: title)
            name.font = .systemFont(ofSize: 12, weight: .semibold)
            name.lineBreakMode = .byTruncatingTail
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
            views.append(name)
        }
        let row = NSStackView(views: views + [clock, button])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 6)
        let size = row.fittingSize
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true
        background.addSubview(row)
        row.frame = CGRect(origin: .zero, size: size)
        bar = Self.panel(Self.barFrame(size: size, area: area, screen: screen.visibleFrame))
        bar.contentView = background
        bar.hasShadow = true

        outline?.orderFrontRegardless()
        bar.orderFrontRegardless()
    }

    /// Under the area; above it when there is no room below; inside its bottom edge when it fills the screen.
    static func barFrame(size: CGSize, area: CGRect, screen: CGRect) -> CGRect {
        let gap: CGFloat = 10
        var y = area.minY - gap - size.height
        if y < screen.minY { y = area.maxY + gap }
        if y + size.height > screen.maxY { y = max(area.minY, screen.minY) + gap }
        let x = min(max(area.midX - size.width / 2, screen.minX + gap), screen.maxX - size.width - gap)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private static func panel(_ frame: CGRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }

    func startClock() {
        guard timer == nil else { return }
        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            let s = Int(Date().timeIntervalSince(start))
            self?.clock.stringValue = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                : String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        outline?.orderOut(nil)
        bar.orderOut(nil)
    }
}

/// Stop works on the first click, though Shotate isn't the active app.
private final class FirstClickButton: NSButton {
    var onClick: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc func clicked() { onClick() }
}
