import AppKit
import AVFoundation
import ShotateCore

/// Where the clicks were while recording: time from the first frame and position in video pixels
/// (top-left origin), saved beside the video as `<name>.clicks.json`. A demo editor can zoom to
/// each click; the debug note takes a still just after each one. Mouse buttons only: no keys, and
/// nothing outside a recording.
final class ClickTrail {
    struct Click { let t: TimeInterval; let x: Int; let y: Int; let button: String; let count: Int }

    private let area: CGRect
    private let scale: CGFloat
    private var monitor: Any?
    private var began = Date()
    private(set) var clicks: [Click] = []

    init(screen: NSScreen, area: CGRect, scale: CGFloat) {
        self.area = area
        self.scale = scale
    }

    func start() {
        guard monitor == nil else { return }
        began = Date()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            self?.note(e)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func note(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        guard area.contains(p) else { return }
        let button = e.type == .leftMouseDown ? "left" : e.type == .rightMouseDown ? "right" : "other"
        clicks.append(Click(t: Date().timeIntervalSince(began), x: Int(((p.x - area.minX) * scale).rounded()),
                            y: Int(((area.maxY - p.y) * scale).rounded()), button: button, count: e.clickCount))
    }

    /// Writes `<video>.clicks.json` and returns it.
    func save(beside video: URL) -> URL? {
        let url = video.deletingPathExtension().appendingPathExtension("clicks.json")
        let o: [String: Any] = [
            "version": 1,
            "video": video.lastPathComponent,
            "size": [Int((area.width * scale).rounded()), Int((area.height * scale).rounded())],
            "scale": scale,
            "about": "Mouse clicks while recording: t is seconds from the video's first frame, x and y are video pixels from the top left.",
            "clicks": clicks.map { ["t": ($0.t * 1000).rounded() / 1000, "x": $0.x, "y": $0.y, "button": $0.button, "count": $0.count] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    var times: [TimeInterval] { clicks.map(\.t) }
}

/// Who was recorded, noted when recording starts: an app that crashes mid-recording can't be asked
/// at the end.
struct AppIdentity {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let version: String?
    let executable: String?

    init(pid: pid_t) {
        self.pid = pid
        let app = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
        let info = app?.bundleURL.flatMap { Bundle(url: $0) }?.infoDictionary
        name = app?.localizedName ?? "process \(pid)"
        bundleID = app?.bundleIdentifier
        executable = app?.executableURL?.lastPathComponent
        version = (info?["CFBundleShortVersionString"] as? String).map { v in
            (info?["CFBundleVersion"] as? String).map { $0 == v ? v : "\(v) (\($0))" } ?? v
        }
    }
}

/// The folder an app recording (⇧⌘D) leaves: the video, stills, the logs and `debug.md`.
enum DebugBundle {
    struct Written {
        let file: URL
        let text: String
        let stills: [URL]
    }

    static func write(folder: URL, video: URL, app: AppIdentity, started: Date, duration: TimeInterval,
                      systemLog: URL, systemLogText: String?, logError: String?, logFiles: AppLogFiles?,
                      clickTimes: [TimeInterval] = []) -> Written {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let asset = AVURLAsset(url: video)
        let (length, size) = Self.measure(asset)
        var report = DebugReport(appName: app.name, bundleID: app.bundleID, version: app.version, pid: app.pid,
                                 started: started, duration: length ?? duration, folder: folder.path,
                                 video: video.path, macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        let stills = Self.stills(of: asset, duration: length ?? duration, clicks: clickTimes, into: folder.appendingPathComponent("stills"))
        report.videoSize = size
        report.stills = stills.map { ($0.time, $0.url.path) }
        report.systemLog = systemLog.path
        report.systemLogError = logError
        if logError == nil, let systemLogText {
            report.digest = LogDigest.parse(systemLogText, ownImages: Set([app.name, app.executable].compactMap { $0 }))
        }
        if let collected = logFiles?.collect(into: folder) {
            report.appLogs = collected.files
            report.crashReports = collected.crashReports
        }
        let text = report.markdown()
        let file = folder.appendingPathComponent("debug.md")
        try? Data(text.utf8).write(to: file)
        return Written(file: file, text: text, stills: stills.map(\.url))
    }

    /// The video's real length and size: the wall clock at the end runs past the last frame while
    /// the file is finished.
    static func measure(_ asset: AVURLAsset) -> (TimeInterval?, (width: Int, height: Int)?) {
        var length: TimeInterval?
        var size: (Int, Int)?
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 { length = d.seconds }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let s = try? await track.load(.naturalSize) { size = (Int(s.width), Int(s.height)) }
            semaphore.signal()
        }
        semaphore.wait()
        return (length, size)
    }

    /// The first and last frames and one just after each click (at most 8 in all), as PNGs at most
    /// 1600 pixels wide.
    static func stills(of asset: AVURLAsset, duration: TimeInterval, clicks: [TimeInterval], into dir: URL)
        -> [(time: TimeInterval, url: URL)] {
        let length = max(duration, 0.2)
        var times = [min(0.3, length / 2)]
        let afterClicks = clicks.map { min($0 + 0.6, length - 0.1) }
        let even = stride(from: length / 4, to: length - 0.5, by: max(length / 4, 1)).map { $0 }
        for t in (afterClicks.isEmpty ? even : afterClicks) where times.allSatisfy({ abs($0 - t) > 0.8 }) && times.count < 7 {
            times.append(t)
        }
        if length > 1, times.allSatisfy({ abs($0 - (length - 0.15)) > 0.8 }) { times.append(max(0, length - 0.15)) }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [(TimeInterval, URL)] = []
        for t in times.sorted() {
            let done = DispatchSemaphore(value: 0)
            var image: CGImage?
            gen.generateCGImageAsynchronously(for: CMTime(seconds: t, preferredTimescale: 600)) { img, _, _ in
                image = img
                done.signal()
            }
            done.wait()
            guard let image, let png = Renderer.pngData(image) else { continue }
            let url = dir.appendingPathComponent(DebugReport.preciseClock(t).replacingOccurrences(of: ":", with: "-") + ".png")
            if (try? png.write(to: url)) != nil { out.append((t, url)) }
        }
        return out
    }
}
