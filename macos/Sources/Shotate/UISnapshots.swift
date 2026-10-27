import AppKit
import ShotateCore

/// `Shotate --render-ui <folder> [--appearance light|dark] [--sample image.png] [--icon icon.png]` draws each window
/// Shotate shows and saves a PNG of it, for checking how the app looks without using it. Each window
/// goes behind every other window (it never takes focus or the keyboard) and is captured with
/// `screencapture -l`, so the process that runs this needs Screen Recording. The capture overlay is
/// drawn straight to an image. Nothing is saved, copied or registered; no shortcuts are claimed.
final class UISnapshots {
    static func run(_ args: [String], at i: Int) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let j = args.firstIndex(of: "--appearance"), j + 1 < args.count {
            app.appearance = NSAppearance(named: args[j + 1] == "light" ? .aqua : .darkAqua)
        }
        // A bare `swift build` binary has no bundle icon; the welcome window shows it.
        if let j = args.firstIndex(of: "--icon"), j + 1 < args.count, let icon = NSImage(contentsOfFile: args[j + 1]) {
            app.applicationIconImage = icon
        }
        let samplePath = args.firstIndex(of: "--sample").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            ?? "Tests/Fixtures/sample.png"
        guard let image = Renderer.loadImage(at: URL(fileURLWithPath: samplePath)) else {
            FileHandle.standardError.write(Data("can't read \(samplePath)\n".utf8))
            exit(2)
        }
        let snapshots = UISnapshots(out: URL(fileURLWithPath: args[i + 1], isDirectory: true), image: image)
        DispatchQueue.main.async {
            snapshots.all()
            exit(snapshots.failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    private let out: URL
    /// Surfaces that weren't written; any makes the run exit 1.
    private(set) var failures = 0
    private let image: CGImage
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("shotate-render-ui", isDirectory: true)

    private init(out: URL, image: CGImage) {
        self.out = out
        self.image = image
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    private func all() {
        editor()
        settings()
        welcome()
        pasteChooser()
        recordingBar()
        overlay()
        menuBarMenu()
    }

    // MARK: Surfaces

    private func editor() {
        let doc = Document(image: image)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }
        // The README's picture (docs/editor.png): a label pointing at a button, a highlight, a box,
        // numbered steps and a redaction.
        doc.add(Mark(tool: .text, color: RGBA.palette[0], start: p(0.08, 0.64), end: .zero, text: "Click Deploy"))
        doc.add(Mark(tool: .arrow, color: RGBA.palette[0], start: p(0.2, 0.55), end: p(0.16, 0.2), bend: w * 0.03))
        doc.add(Mark(tool: .box, color: RGBA.palette[1], start: p(0.5, 0.5), end: p(0.9, 0.85)))
        doc.add(Mark(tool: .step, color: RGBA.palette[3], start: p(0.94, 0.86), end: .zero))
        doc.add(Mark(tool: .step, color: RGBA.palette[3], start: p(0.94, 0.3), end: .zero))
        doc.add(Mark(tool: .redact, color: RGBA.palette[0], start: p(0.55, 0.12), end: p(0.82, 0.22)))
        doc.add(Mark(tool: .highlight, color: RGBA.palette[1], start: p(0.05, 0.42), end: p(0.4, 0.5)))
        let url = scratch.appendingPathComponent("Release checklist.png")
        let c = EditorWindowController(document: doc, fileURL: url, ownsFile: false, settings: Settings())
        c.select(tool: .arrow)
        c.window?.setContentSize(CGSize(width: 1000, height: 612))
        capture(c.window, "editor")
        c.window?.orderOut(nil)
    }

    private func settings() {
        let app = AppDelegate()
        let c = SettingsWindowController(app: app)
        guard let tabs = c.window?.contentViewController as? NSTabViewController else { return }
        for (i, name) in ["general", "shortcuts", "commands", "advanced"].enumerated() {
            c.reload()
            tabs.selectedTabViewItemIndex = i
            capture(c.window, "settings-\(name)", settle: 0.8)
        }
        c.window?.orderOut(nil)
    }

    private func welcome() {
        let c = WelcomeWindowController(app: AppDelegate())
        capture(c.window, "welcome")
        c.window?.orderOut(nil)
    }

    private func pasteChooser() {
        let thumb = NSImage(cgImage: image, size: NSSize(width: image.width / 4, height: image.height / 4))
        let size = "\(image.width) × \(image.height)"
        let items = ["Just now", "Just now", "2 min ago"].enumerated().map { i, age in
            PasteChooser.Item(id: scratch.appendingPathComponent("\(i).png"), number: i + 1, image: thumb, age: age,
                              size: size, pasted: i == 2)
        }
        for (typesPaste, name) in [(true, "paste-chooser"), (false, "paste-chooser-no-access")] {
            let c = PasteChooser(items: items, typesPaste: typesPaste)
            capture(c.window, name)
            c.window.orderOut(nil)
        }
    }

    private func recordingBar() {
        guard let screen = NSScreen.main else { return }
        let area = CGRect(x: screen.frame.midX - 200, y: screen.frame.midY - 100, width: 400, height: 200)
        for (title, seconds, name) in [(nil, 42, "recording-bar"), ("Safari", 754, "recording-bar-app"),
                                       (nil, 3723, "recording-bar-hour")] as [(String?, Int, String)] {
            let r = RecordingIndicator(area: area, outlined: false, screen: screen, title: title, stop: {})
            r.show(elapsed: seconds)
            capture(r.barWindow, name)
            r.close()
        }
    }

    private func overlay() {
        guard let screen = NSScreen.main else { return }
        let o = screen.frame.origin
        let drag = (CGPoint(x: o.x + 240, y: o.y + 260), CGPoint(x: o.x + 760, y: o.y + 560))
        if let shot = Picker.snapshot(screen: screen, image: image, from: drag.0, to: drag.1) {
            write(shot, "overlay-area")
        }
        let window = CGRect(x: o.x + 200, y: o.y + 180, width: 640, height: 420)
        if let shot = Picker.snapshot(screen: screen, image: image, from: .zero, to: .zero, window: window) {
            write(shot, "overlay-window")
        }
    }

    /// The menu bar menu as text: a menu can't be shown without taking the keyboard, so it is
    /// listed instead (titles, shortcuts, check marks, separators).
    private func menuBarMenu() {
        let menu = NSMenu()
        AppDelegate().menuNeedsUpdate(menu)
        let lines = menu.items.map { i -> String in
            if i.isSeparatorItem { return "────────────" }
            var keys = ""
            if !i.keyEquivalent.isEmpty {
                let m = i.keyEquivalentModifierMask
                keys = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "")
                    + (m.contains(.command) ? "⌘" : "") + i.keyEquivalent.uppercased()
            }
            return (i.state == .on ? "✓ " : "  ") + i.title + (keys.isEmpty ? "" : "    " + keys)
        }
        let file = out.appendingPathComponent("menu-bar-menu.txt")
        report((try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)) != nil, file)
    }

    // MARK: Capturing

    /// Puts `window` behind everything (at the normal level, without focus), lets it draw, then
    /// captures just that window, without its shadow.
    private func capture(_ window: NSWindow?, _ name: String, settle: TimeInterval = 0.5) {
        guard let window, let screen = NSScreen.main else { return }
        window.level = .normal
        window.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 40,
                                      y: screen.visibleFrame.maxY - window.frame.height - 40))
        window.orderBack(nil)
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        let file = out.appendingPathComponent("\(name).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        guard (try? p.run()) != nil else { return report(false, file) }
        p.waitUntilExit()
        report(p.terminationStatus == 0, file)
    }

    private func write(_ image: CGImage, _ name: String) {
        let file = out.appendingPathComponent("\(name).png")
        report(Renderer.pngData(image).map { (try? $0.write(to: file)) != nil } ?? false, file)
    }

    private func report(_ ok: Bool, _ file: URL) {
        if ok { return print("wrote \(file.path)") }
        failures += 1
        FileHandle.standardError.write(Data("couldn't write \(file.path)\n".utf8))
    }
}
