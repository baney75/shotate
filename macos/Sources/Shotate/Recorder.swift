import AppKit
import AVFoundation
import ScreenCaptureKit
import ShotateCore

/// Records one area of one screen to an MP4 with ScreenCaptureKit, from `start` until `stop()`. A red
/// outline marks the area and a small bar under it shows the time and a Stop button; neither is in
/// the video. No sound: Shotate never asks for the microphone.
@available(macOS 15.0, *)
final class Recorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private(set) static var current: Recorder?

    let file: URL
    private var stream: SCStream?
    private var indicator: RecordingIndicator?
    private var stopping = false
    private let done: (URL, Error?) -> Void

    /// Starts recording `rect` (AppKit global coordinates, within `screen`) into `file`. `done` runs on
    /// main once the file is finished, or with the error that stopped it.
    static func start(_ rect: CGRect, on screen: NSScreen, to file: URL, done: @escaping (URL, Error?) -> Void) {
        let r = Recorder(file: file, done: done)
        current = r
        r.indicator = RecordingIndicator(area: rect, screen: screen) { [weak r] in r?.stop() }
        Task { @MainActor in
            do { try await r.begin(rect, on: screen) } catch { r.finish(error) }
        }
    }

    private init(file: URL, done: @escaping (URL, Error?) -> Void) {
        self.file = file
        self.done = done
    }

    @MainActor
    private func begin(_ rect: CGRect, on screen: NSScreen) async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The indicator's windows are already up, so they can be named and kept out of the video.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = NativeCapture.display(for: screen, in: content) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "That screen isn't available to record."])
        }
        let ours = Set(indicator?.windowIDs ?? [])
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { ours.contains($0.windowID) })
        let config = SCStreamConfiguration()
        let size = CaptureGeometry.videoSize(of: rect.size, scale: screen.backingScaleFactor)
        config.sourceRect = CaptureGeometry.displayRect(of: rect, screenFrame: screen.frame)
        config.width = size.width
        config.height = size.height
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
        self.stream = stream
        try await stream.startCapture()
        // Stopped (or failed) while starting up.
        if stopping { try? await stream.stopCapture() }
    }

    /// Ends the recording; `done` runs once the file is written.
    func stop() {
        guard !stopping else { return }
        stopping = true
        indicator?.close()
        guard let stream else { return }
        Task { @MainActor in
            do { try await stream.stopCapture() } catch { finish(error) }
        }
        finishSoon()
    }

    /// The recording output reports when the file is complete. If it never does, don't leave
    /// Shotate stuck "recording".
    private func finishSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finish(nil) }
    }

    private func finish(_ error: Error?) {
        guard Recorder.current === self else { return }
        Recorder.current = nil
        stopping = true
        indicator?.close()
        indicator = nil
        let written = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 } ?? false
        if error != nil || !written { try? FileManager.default.removeItem(at: file) }
        let failure = error ?? (written ? nil : CocoaError(.fileWriteUnknown, userInfo: [
            NSLocalizedDescriptionKey: "Nothing was recorded. Try recording for a little longer."]))
        done(file, failure)
    }

    // MARK: SCRecordingOutputDelegate, SCStreamDelegate (called off main)

    func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        DispatchQueue.main.async { self.indicator?.startClock() }
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
            self.stopping = true
            self.indicator?.close()
            self.finishSoon()
        }
    }
}

/// The outline around the area being recorded and the bar with the time and Stop. Neither takes
/// focus from the app you are recording.
final class RecordingIndicator {
    private let outline: NSPanel
    private let bar: NSPanel
    private let clock = NSTextField(labelWithString: "0:00")
    private var timer: Timer?

    var windowIDs: [CGWindowID] { [outline, bar].map { CGWindowID($0.windowNumber) } }

    init(area: CGRect, screen: NSScreen, stop: @escaping () -> Void) {
        // Drawn just outside the area, so it would stay out of the video even if it were captured.
        let pad: CGFloat = 3
        outline = Self.panel(area.insetBy(dx: -pad, dy: -pad))
        outline.ignoresMouseEvents = true
        let border = NSView()
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.systemRed.cgColor
        border.layer?.borderWidth = 2
        border.layer?.cornerRadius = 2
        outline.contentView = border

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
        let row = NSStackView(views: [dot, clock, button])
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

        outline.orderFrontRegardless()
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
        outline.orderOut(nil)
        bar.orderOut(nil)
    }
}

/// Stop works on the first click, though Shotate isn't the active app.
private final class FirstClickButton: NSButton {
    var onClick: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc func clicked() { onClick() }
}
