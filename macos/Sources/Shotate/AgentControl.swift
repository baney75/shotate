import AppKit
import ScreenCaptureKit
import ShotateCore

/// How programs on this Mac drive Shotate without clicks: the `shotate` command (see `AgentCLI`)
/// posts a distributed notification with a JSON request, and Shotate writes the JSON answer to
/// ~/Library/Application Support/Shotate/agent/<id>.json. Web pages can't post these (unlike
/// shotate:// links), and everything except `status` needs `agentControl` on in the config.
enum AgentProtocol {
    static let request = Notification.Name("com.baney.shotate.agent.request")
    static var replies: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Shotate/agent", isDirectory: true)
    }

    static func replyURL(_ id: String) -> URL { replies.appendingPathComponent(id + ".json") }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}

final class AgentControl: NSObject {
    private weak var app: AppDelegate?
    /// Requests waiting for the recording to be saved.
    private var waitingForSave: [String] = []
    /// How the last agent recording ended, when no `stop` was waiting for it (it failed, or the
    /// user stopped it): the next `stop` gets it, and `status` shows it.
    private var unclaimed: [String: Any]?

    init(app: AppDelegate) {
        self.app = app
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(received(_:)),
                                                            name: AgentProtocol.request, object: nil,
                                                            suspensionBehavior: .deliverImmediately)
    }

    @objc private func received(_ n: Notification) {
        guard let id = n.object as? String, AgentProtocol.validID(id),
              let json = n.userInfo?["request"] as? String,
              let r = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let command = r["command"] as? String else { return }
        DispatchQueue.main.async { self.handle(id, command, r) }
    }

    private func handle(_ id: String, _ command: String, _ r: [String: Any]) {
        guard let app else { return }
        if command == "status" { return reply(id, status()) }
        guard app.settings.agentControl else {
            return fail(id, "Agent control is off. Turn on \"Let Agents Control Shotate\" in the menu bar icon's menu, "
                + "or set \"agentControl\": true in ~/.config/shotate/config.json.")
        }
        // The picker is up for the user: an agent capture would catch it, and a recording would
        // collide with the one the user is about to start.
        guard !app.capturing || command == "open" || command == "stop" else {
            return fail(id, "The user is picking something to capture right now. Try again in a moment.")
        }
        guard ScreenRecording.isGranted || command == "open" else {
            return fail(id, "Shotate doesn't have Screen Recording permission. Open Shotate's setup (shotate://welcome).")
        }
        switch command {
        case "windows": windows(id)
        case "capture": capture(id, r)
        case "record": record(id, r)
        case "stop": stop(id, any: r["any"] as? Bool == true)
        case "open":
            guard let path = r["path"] as? String else { return fail(id, "open needs a path.") }
            app.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            reply(id, ["opened": path])
        default: fail(id, "Unknown command \(command).")
        }
    }

    private func status() -> [String: Any] {
        var s: [String: Any] = [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "agentControl": app?.settings.agentControl ?? false,
            "screenRecording": ScreenRecording.isGranted,
            "canRecord": app?.canRecord ?? false,
            "recording": Recording.isActive,
            "saving": Recording.isSaving,
            "saveFolder": app?.settings.saveFolder.path ?? "",
        ]
        #if compiler(>=6.0)
        if #available(macOS 15.0, *), let f = Recorder.current?.file { s["recordingFile"] = f.path }
        #endif
        if let unclaimed { s["lastRecording"] = unclaimed }
        return s
    }

    // MARK: Windows and captures

    private func windows(_ id: String) {
        guard #available(macOS 14.0, *) else { return fail(id, "Needs macOS 14 or later.") }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let list = Self.appWindows(content).map(Self.describe)
                reply(id, ["windows": list])
            } catch { fail(id, error.localizedDescription) }
        }
    }

    @available(macOS 14.0, *)
    private static func appWindows(_ content: SCShareableContent) -> [SCWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        let order = Self.frontToBack()
        return content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40 && $0.owningApplication != nil
                && $0.owningApplication?.processID != me }
            .sorted { (order[$0.windowID] ?? .max) < (order[$1.windowID] ?? .max) }
    }

    /// Window IDs, frontmost first, from the window server.
    private static func frontToBack() -> [CGWindowID: Int] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (i, w) in info.enumerated() { if let n = w[kCGWindowNumber as String] as? Int { order[CGWindowID(n)] = i } }
        return order
    }

    @available(macOS 14.0, *)
    private static func describe(_ w: SCWindow) -> [String: Any] {
        [
            "id": Int(w.windowID),
            "pid": Int(w.owningApplication?.processID ?? 0),
            "app": w.owningApplication?.applicationName ?? "",
            "bundleID": w.owningApplication?.bundleIdentifier ?? "",
            "title": w.title ?? "",
            // Global points, top-left origin (the same space as Cua and CGWindowList).
            "frame": [Int(w.frame.minX), Int(w.frame.minY), Int(w.frame.width), Int(w.frame.height)],
        ]
    }

    /// The window a request names: `window` (an ID), or the frontmost window of `app` (name or
    /// bundle ID) or `pid`, optionally whose title contains `title`.
    @available(macOS 14.0, *)
    private static func window(_ r: [String: Any], in content: SCShareableContent) -> SCWindow? {
        let all = appWindows(content)
        if let wid = Self.int(r["window"]) { return all.first { Int($0.windowID) == wid } }
        let title = (r["title"] as? String)?.lowercased()
        return all.first { w in
            guard let owner = w.owningApplication else { return false }
            if let pid = Self.int(r["pid"]), Int(owner.processID) != pid { return false }
            if let name = (r["app"] as? String)?.lowercased(),
               owner.applicationName.lowercased() != name, owner.bundleIdentifier.lowercased() != name { return false }
            if let title, !(w.title ?? "").lowercased().contains(title) { return false }
            return true
        }
    }

    private func capture(_ id: String, _ r: [String: Any]) {
        guard #available(macOS 14.0, *), let app else { return fail(id, "Needs macOS 14 or later.") }
        let mode = r["mode"] as? String ?? (r["rect"] != nil ? "area" : r["app"] != nil || r["pid"] != nil || r["window"] != nil ? "window" : "screen")
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                var image: CGImage
                var scale: CGFloat
                switch mode {
                case "window":
                    guard let w = Self.window(r, in: content) else { return fail(id, "No such window on screen. Try `shotate windows`.") }
                    (image, scale) = try await NativeCapture.capture(w)
                case "screen", "area":
                    let rect = mode == "area" ? Self.rect(r["rect"]) : nil
                    if mode == "area", rect == nil { return fail(id, "area needs --rect x,y,w,h in points, top-left origin.") }
                    guard let screen = rect.flatMap({ Self.screen(containing: $0) }) ?? NSScreen.screens.first else {
                        return fail(id, "No screen is available.")
                    }
                    guard let display = NativeCapture.display(for: screen, in: content) else { return fail(id, "That screen isn't available.") }
                    image = try await NativeCapture.capture(display, in: content)
                    scale = screen.backingScaleFactor
                    if let rect {
                        let appKit = Self.appKitRect(rect)
                        let pixels = CaptureGeometry.pixelRect(of: appKit.intersection(screen.frame), screenFrame: screen.frame, scale: scale)
                        guard let crop = image.cropping(to: pixels) else { return fail(id, "That area is off screen.") }
                        image = crop
                    }
                default: return fail(id, "capture mode is screen, window or area.")
                }
                let url = Self.outURL(r["out"]) ?? app.settings.newCaptureURL()
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Output.write(image, to: url, dpi: 72 * scale)
                if r["copy"] as? Bool == true { _ = Output.copy(image, fileURL: url, dpi: 72 * scale) }
                if r["edit"] as? Bool == true { app.open(url) }
                reply(id, ["file": url.path, "width": image.width, "height": image.height, "scale": scale])
            } catch { fail(id, error.localizedDescription) }
        }
    }

    // MARK: Recording

    private func record(_ id: String, _ r: [String: Any]) {
        guard let app else { return }
        guard app.canRecord else { return fail(id, "Recording needs macOS 15 and a build made with Xcode 16 or later.") }
        guard !Recording.isActive else { return fail(id, "Already recording. Stop it first with `shotate stop`.") }
        guard !Recording.isSaving else { return fail(id, "Still saving the last recording. Try again in a moment.") }
        let mode = r["mode"] as? String ?? (r["rect"] != nil ? "area" : r["app"] != nil || r["pid"] != nil ? "app" : "screen")
        guard #available(macOS 14.0, *) else { return }
        Task { @MainActor in
            let target: RecordTarget
            switch mode {
            case "screen":
                guard let main = NSScreen.screens.first else { return fail(id, "No screen is available.") }
                target = .screen(main)
            case "area":
                guard let rect = Self.rect(r["rect"]) else { return fail(id, "area needs --rect x,y,w,h in points, top-left origin.") }
                guard let screen = Self.screen(containing: rect) ?? NSScreen.screens.first else {
                    return fail(id, "No screen is available.")
                }
                let area = Self.appKitRect(rect).intersection(screen.frame).integral
                guard !area.isNull, area.width >= 8, area.height >= 8 else { return fail(id, "That area is off screen.") }
                target = .area(area, screen)
            case "app":
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                      let w = Self.window(r, in: content), let owner = w.owningApplication else {
                    return fail(id, "No window of that app on screen. Try `shotate windows`.")
                }
                guard let screen = Self.screen(containing: w.frame) ?? NSScreen.screens.first else {
                    return fail(id, "No screen is available.")
                }
                target = .app(owner.processID, screen)
            default:
                return fail(id, "record mode is app, screen or area.")
            }
            let file = Self.outURL(r["out"]) ?? app.settings.newRecordingURL()
            // An app recording is the folder named like the file; neither may be there already.
            var made = file
            if case .app = target { made = file.deletingPathExtension() }
            if FileManager.default.fileExists(atPath: made.path) {
                return fail(id, "\(made.path) already exists. Choose another --out.")
            }
            unclaimed = nil
            guard app.startRecording(target, to: file, byAgent: true), Recording.isActive else {
                let why = unclaimed?["error"] as? String
                    ?? (Recording.isSaving ? "Still saving the last recording. Try again in a moment." : "Shotate is already recording.")
                unclaimed = nil
                return fail(id, why)
            }
            var answer: [String: Any] = ["recording": true]
            #if compiler(>=6.0)
            if #available(macOS 15.0, *), let f = Recorder.current?.file {
                answer["video"] = f.path
                if case .app = target { answer["folder"] = f.deletingLastPathComponent().path }
            }
            #endif
            reply(id, answer)
        }
    }

    private func stop(_ id: String, any: Bool) {
        switch AgentPolicy.stop(active: Recording.isActive, saving: Recording.isSaving,
                                byAgent: app?.recordingByAgent ?? false, unclaimed: unclaimed != nil, any: any) {
        case .stop:
            waitingForSave.append(id)
            Recording.stop()
        case .waitForSave:
            waitingForSave.append(id)
        case .returnUnclaimed:
            // The agent's own recording already ended (it failed, or the user stopped it): say how.
            let last = unclaimed ?? [:]
            unclaimed = nil
            reply(id, last)
        case .refuseUsers:
            fail(id, "The user started this recording. Only stop it if they asked: `shotate stop --any`.")
        case .nothingRecording:
            fail(id, "Nothing is recording.")
        }
    }

    /// Called by the app delegate once any recording is saved or fails.
    func recordingFinished(_ saved: SavedRecording?, error: Error?, byAgent: Bool) {
        let ids = waitingForSave
        waitingForSave = []
        var answer: [String: Any] = [:]
        if let saved {
            answer["video"] = saved.video.path
            if let c = saved.clicks { answer["clicks"] = c.path }
            if let f = saved.folder { answer["folder"] = f.path }
            if let d = saved.debug { answer["debug"] = d.path }
            if let l = saved.log { answer["systemLog"] = l.path }
            if !saved.stills.isEmpty { answer["stills"] = saved.stills.map(\.path) }
            if let e = saved.logError { answer["logError"] = e }
        }
        if let error { answer["error"] = error.localizedDescription }
        if ids.isEmpty, byAgent { unclaimed = answer }
        for id in ids { reply(id, answer) }
    }

    // MARK: Helpers

    private func fail(_ id: String, _ message: String) { reply(id, ["error": message]) }

    private func reply(_ id: String, _ o: [String: Any]) {
        let dir = AgentProtocol.replies
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? data.write(to: AgentProtocol.replyURL(id), options: .atomic)
    }

    static func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? String).flatMap { Int($0) } ?? (v as? Double).map { Int($0) } }

    /// "x,y,w,h" or [x, y, w, h], in global points with the origin at the main screen's top left.
    static func rect(_ v: Any?) -> CGRect? {
        let n: [Double]
        if let s = v as? String { n = s.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) } }
        else if let a = v as? [Any] { n = a.compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) } }
        else { return nil }
        guard n.count == 4, n[2] > 0, n[3] > 0 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    /// Top-left-origin global points to AppKit's bottom-left origin.
    static func appKitRect(_ r: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }

    static func screen(containing r: CGRect) -> NSScreen? {
        let a = appKitRect(r)
        return NSScreen.screens.max { $0.frame.intersection(a).area < $1.frame.intersection(a).area }
    }

    static func outURL(_ v: Any?) -> URL? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
