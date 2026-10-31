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

/// A saved recording. Every recording has a click timeline beside the video (`.clicks.json`).
/// Recording an app saves a folder instead: the video, stills, the logs the app wrote meanwhile and
/// `debug.md`, the note that goes on the clipboard for a coding agent.
struct SavedRecording {
    let video: URL
    let clicks: URL?
    /// App recordings: the folder holding everything.
    var folder: URL?
    var log: URL?
    var debug: URL?
    var debugText: String?
    var stills: [URL] = []
    /// Why the app's system log couldn't be read, in `log`'s words.
    var logError: String?
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

    /// Stopped, but its folder (stills, logs, the note) is still being written.
    static var isSaving: Bool {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) { return Recorder.saving > 0 }
        #endif
        return false
    }

    /// See `Recorder.start`. Returns false when this build or macOS can't record.
    @discardableResult
    static func start(_ target: RecordTarget, to file: URL, appLogs: [String: [String]] = [:],
                      done: @escaping (SavedRecording?, Error?) -> Void) -> Bool {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            Recorder.start(target, to: file, appLogs: appLogs, done: done)
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

    /// The bar and outline of the recording in progress, which a screenshot leaves out.
    static var overlayWindowIDs: Set<CGWindowID> {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) { return Set(Recorder.current?.overlayWindowIDs ?? []) }
        #endif
        return []
    }
}

#if compiler(>=6.0)
/// Records an area, a screen or an app to an MP4 with ScreenCaptureKit, from `start` until `stop()`.
/// A small bar shows the time and a Stop button, and a red outline marks a recorded area; neither is
/// in the video. No sound: Shotate never asks for the microphone.
@available(macOS 15.0, *)
final class Recorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private(set) static var current: Recorder?
    /// Recordings stopped but not yet handed to `done`.
    private(set) static var saving = 0

    let file: URL
    private let target: RecordTarget
    private var stream: SCStream?
    private var log: AppLog?
    private var logFiles: AppLogFiles?
    private var appLogFolders: [String: [String]] = [:]
    /// The recorded app, noted at the start: it may have quit (or crashed) by the end.
    private var identity: AppIdentity?
    private var clicks: ClickTrail?
    private var startedAt = Date()
    private var indicator: RecordingIndicator?
    private var stopping = false
    /// The first frame is in the file.
    private var started = false
    /// Why macOS stopped the stream, when it wasn't us.
    private var stopError: Error?
    private let done: (SavedRecording?, Error?) -> Void

    /// Starts recording `target` into `file`. `done` runs on main once the file is finished, or with
    /// the error that stopped it.
    static func start(_ target: RecordTarget, to file: URL, appLogs: [String: [String]] = [:],
                      done: @escaping (SavedRecording?, Error?) -> Void) {
        // One recording at a time: a second would orphan the first, still capturing.
        guard current == nil else { return done(nil, error("Shotate is already recording.")) }
        var file = file
        var made = file
        if case .app = target {
            // An app recording is a folder named like the video would be, with the video inside.
            let folder = file.deletingPathExtension()
            file = folder.appendingPathComponent(folder.lastPathComponent).appendingPathExtension("mp4")
            made = folder
        }
        // Never record over something that's there: a failed recording deletes what it made, and
        // an old file would pass for a new one.
        guard !FileManager.default.fileExists(atPath: made.path) else {
            return done(nil, error("\(made.path) already exists. Choose another name."))
        }
        let r = Recorder(target: target, file: file, done: done)
        r.appLogFolders = appLogs
        if case let .app(pid, _) = target { r.identity = AppIdentity(pid: pid) }
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
        // Stopped while macOS was answering: start nothing (`finish` has run or will).
        guard Recorder.current === self, !stopping else { throw Self.nothingRecorded }
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
            // `exceptingWindows` flips a window's inclusion: for another app, naming the bar would
            // put it in the video; only when the app is Shotate itself does naming it keep it out.
            let isShotate = pid == ProcessInfo.processInfo.processIdentifier
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: isShotate ? notOurs : [])
            log = try AppLog(pid: pid, file: file.deletingLastPathComponent().appendingPathComponent("system.log"))
            // lsof and pgrep over an Electron app's helpers can take a second: off the main thread.
            let folders = appLogFolders
            logFiles = await withCheckedContinuation { c in
                DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: AppLogFiles(pid: pid, extraFolders: folders)) }
            }
        }
        clicks = ClickTrail(screen: screen, area: {
            if case let .area(rect, _) = target { return rect }
            return screen.frame
        }(), scale: screen.backingScaleFactor)
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
        // Already given up on (the fallback ran out while this started): nobody will report the file.
        if Recorder.current !== self { try? FileManager.default.removeItem(at: file) }
    }

    var overlayWindowIDs: [CGWindowID] { indicator?.windowIDs ?? [] }

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
        Recorder.saving += 1
        let done: (SavedRecording?, Error?) -> Void = { [done] saved, error in
            Recorder.saving -= 1
            done(saved, error)
        }
        stopping = true
        indicator?.close()
        indicator = nil
        // Ending on a failure or a timeout: make sure nothing keeps capturing.
        if let stream { Task { try? await stream.stopCapture() } }
        let written = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 } ?? false
        let failure = error ?? (written ? nil : stopError ?? Self.nothingRecorded)
        let keep = written && (failure == nil || keepFile)
        let duration = Date().timeIntervalSince(startedAt)
        let clicksFile = keep ? clicks?.save(beside: file) : nil
        clicks?.stop()
        if !keep { try? FileManager.default.removeItem(at: file) }
        var saved = SavedRecording(video: file, clicks: clicksFile)
        let folder = file.deletingLastPathComponent()
        guard let log else {
            // An app recording that failed before its log started: its folder is new and empty.
            if case .app = target, !keep { try? FileManager.default.removeItem(at: folder) }
            return done(keep ? saved : nil, failure)
        }
        guard keep else {
            log.stop { [done] _, _ in
                try? FileManager.default.removeItem(at: folder)
                done(nil, failure)
            }
            return
        }
        let identity = identity ?? AppIdentity(pid: 0)
        let logFiles = logFiles
        let started = startedAt
        let clickTimes = clicks?.times ?? []
        log.stop { [file, done] text, logError in
            // Stills, log files and the note take a moment: off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let report = DebugBundle.write(folder: folder, video: file, app: identity, started: started,
                                               duration: duration, systemLog: log.file, systemLogText: text,
                                               logError: logError, logFiles: logFiles, clickTimes: clickTimes)
                saved.folder = folder
                saved.log = log.file
                saved.debug = report.file
                saved.debugText = report.text
                saved.stills = report.stills
                saved.logError = logError
                DispatchQueue.main.async { done(saved, failure) }
            }
        }
    }

    private static let nothingRecorded = error("Nothing was recorded. Try recording for a little longer.")

    private static func error(_ message: String) -> Error {
        CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: SCRecordingOutputDelegate, SCStreamDelegate (called off main)

    func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        DispatchQueue.main.async {
            self.started = true
            self.startedAt = Date()
            // Already given up on (stopped while starting): note no clicks outside a recording.
            guard Recorder.current === self, !self.stopping else { return }
            self.clicks?.start()
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
            self.stopError = error
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
    private let errors = Pipe()
    private var exited = false
    private var interrupted = false
    private var onExit: (() -> Void)?

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
        // Through a pipe Shotate copies into the file, not straight into the file: if Shotate is
        // force-quit or crashes, the pipe closes and `log` exits instead of writing forever.
        let lines = Pipe()
        process.standardOutput = lines
        process.standardError = errors
        try process.run()
        // Only the child writes to these; closing this side lets the reads see their end.
        try? lines.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let process = process
        Thread.detachNewThread { [weak self] in
            let input = lines.fileHandleForReading
            while case let data = input.availableData, !data.isEmpty { out.write(data) }
            try? out.close()
            // The pipe ends when `log` does; everything it wrote is in the file now.
            process.waitUntilExit()
            DispatchQueue.main.async {
                self?.exited = true
                let f = self?.onExit
                self?.onExit = nil
                f?()
            }
        }
    }

    /// Ends the stream (as Ctrl-C would, so its last lines are written) and calls back on main,
    /// once, with the log's text, or with the error `log` gave if it quit by itself.
    func stop(_ completion: @escaping (String?, String?) -> Void) {
        var called = false
        let deliver = { [weak self] in
            guard !called, let self else { return }
            called = true
            completion(self.newestText(), self.failure())
        }
        guard !exited else { return deliver() }
        interrupted = true
        onExit = deliver
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { deliver() }
    }

    /// `log`'s own message when it quit on its own with an error, as when the account may not read the log.
    private func failure() -> String? {
        guard !interrupted, !process.isRunning, process.terminationStatus != 0 else { return nil }
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "log stream exited with status \(process.terminationStatus)." : text
    }

    /// The newest part of the log (up to 16 MB) for the digest, read from the end so a huge log
    /// isn't loaded whole.
    private func newestText() -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let size = Int((try? h.seekToEnd()) ?? 0)
        try? h.seek(toOffset: UInt64(max(0, size - 16 * 1_048_576)))
        return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    }
}

/// The bar with the time and Stop, and around a recorded area a red outline. Neither takes focus
/// from the app you are recording.
final class RecordingIndicator {
    private let outline: NSPanel?
    private let bar: NSPanel
    private let clock = NSTextField(labelWithString: "0:00")
    private var timer: Timer?
    private let row: NSStackView
    private let area: CGRect
    private let screenFrame: CGRect

    var windowIDs: [CGWindowID] { ([outline, bar].compactMap { $0 }).map { CGWindowID($0.windowNumber) } }

    init(area: CGRect, outlined: Bool, screen: NSScreen, title: String?, stop: @escaping () -> Void) {
        self.area = area
        screenFrame = screen.visibleFrame
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
        row = NSStackView(views: views + [clock, button])
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
            self?.show(elapsed: Int(Date().timeIntervalSince(start)))
        }
    }

    /// "0:42", "12:05", "1:02:09".
    func show(elapsed s: Int) {
        let old = clock.stringValue.count
        clock.stringValue = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
        // At 10:00 and 1:00:00 the time grows a digit: grow the bar too, or Stop is cut off.
        if clock.stringValue.count != old { fit() }
    }

    private func fit() {
        let size = row.fittingSize
        row.frame = CGRect(origin: .zero, size: size)
        bar.setFrame(Self.barFrame(size: size, area: area, screen: screenFrame), display: true)
    }

    /// For `--render-ui`.
    var barWindow: NSWindow { bar }

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
