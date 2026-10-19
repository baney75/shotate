import AppKit
import ScreenCaptureKit
import ShotateCore

/// Shotate's own capture. On recent macOS the screencapture tool takes 0.4–3 s to write even a small
/// region, while ScreenCaptureKit returns a screen in milliseconds. Area and window capture freeze
/// every screen when the shortcut is pressed, so letting go of the mouse only crops.
@available(macOS 14.0, *)
enum NativeCapture {
    enum Result {
        case image(CGImage, dpi: CGFloat)
        case cancelled
        /// ScreenCaptureKit failed before the user picked anything; the caller can fall back.
        case failed
    }

    /// Calls back on main.
    static func run(_ mode: CaptureMode, completion: @escaping (Result) -> Void) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if mode == .screen {
                    // screencapture -m: the main display.
                    guard let screen = NSScreen.screens.first, let display = display(for: screen, in: content) else {
                        return completion(.failed)
                    }
                    let image = try await capture(display, in: content)
                    return completion(.image(image, dpi: 72 * screen.backingScaleFactor))
                }
                guard let (choice, shots, windows) = try await pick(content, windowMode: mode == .window) else {
                    return completion(.failed)
                }
                switch choice {
                case nil:
                    completion(.cancelled)
                case let .area(screen, rect)?:
                    guard let (s, image) = shots.first(where: { $0.0 === screen }) else { return completion(.cancelled) }
                    let scale = s.backingScaleFactor
                    let pixels = CaptureGeometry.pixelRect(of: rect, screenFrame: s.frame, scale: scale)
                    guard let crop = image.cropping(to: pixels) else { return completion(.cancelled) }
                    completion(.image(crop, dpi: 72 * scale))
                case let .window(id)?:
                    guard let w = windows.first(where: { $0.id == id }) else { return completion(.cancelled) }
                    Task { @MainActor in
                        do {
                            let (image, scale) = try await capture(w.window)
                            completion(.image(image, dpi: 72 * scale))
                        } catch {
                            NSLog("Shotate: window capture: %@", error.localizedDescription)
                            completion(.cancelled)
                        }
                    }
                }
            } catch {
                NSLog("Shotate: ScreenCaptureKit: %@", error.localizedDescription)
                completion(.failed)
            }
        }
    }

    enum Pick {
        case chosen(RecordTarget)
        case cancelled
        case failed
    }

    /// For recording: the same picker, but it answers with what to record instead of an image. A
    /// picked window gives the part of its frame on the screen that shows most of it, or with `app`
    /// (click a window; Space doesn't switch to dragging) that window's app. Calls back on main.
    static func pickToRecord(app: Bool, completion: @escaping (Pick) -> Void) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let (choice, shots, windows) = try await pick(content, windowMode: app, toggles: !app) else {
                    return completion(.failed)
                }
                switch choice {
                case nil:
                    completion(.cancelled)
                case let .area(screen, rect)?:
                    completion(.chosen(.area(rect, screen)))
                case let .window(id)?:
                    guard let w = windows.first(where: { $0.id == id }),
                          let screen = shots.map(\.0).max(by: { area(w.frame.intersection($0.frame)) < area(w.frame.intersection($1.frame)) })
                    else { return completion(.cancelled) }
                    if app {
                        guard let pid = w.window.owningApplication?.processID else { return completion(.cancelled) }
                        return completion(.chosen(.app(pid, screen)))
                    }
                    let rect = w.frame.intersection(screen.frame)
                    completion(rect.width >= 2 && rect.height >= 2 ? .chosen(.area(rect, screen)) : .cancelled)
                }
            } catch {
                NSLog("Shotate: ScreenCaptureKit: %@", error.localizedDescription)
                completion(.failed)
            }
        }
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// Freezes every screen and shows the picker over them until something is chosen or it is
    /// cancelled. Nil when ScreenCaptureKit returned no screens.
    @MainActor
    private static func pick(_ content: SCShareableContent, windowMode: Bool, toggles: Bool = true) async throws
        -> (choice: Picker.Choice?, shots: [(NSScreen, CGImage)], windows: [PickableWindow])? {
        let frozen = try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (i, screen) in NSScreen.screens.enumerated() {
                guard let display = display(for: screen, in: content) else { continue }
                group.addTask { (i, try await capture(display, in: content)) }
            }
            var images: [Int: CGImage] = [:]
            for try await (i, image) in group { images[i] = image }
            return images
        }
        let shots = NSScreen.screens.enumerated().compactMap { i, s in frozen[i].map { (s, $0) } }
        guard !shots.isEmpty else { return nil }
        let windows = pickableWindows(content)
        let choice = await withCheckedContinuation { (done: CheckedContinuation<Picker.Choice?, Never>) in
            Picker.show(shots: shots, windows: windows.map { ($0.id, $0.frame) }, windowMode: windowMode, toggles: toggles) {
                done.resume(returning: $0)
            }
        }
        return (choice, shots, windows)
    }

    static func display(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return content.displays.first { $0.displayID == id }
    }

    /// The whole display at full resolution, without the cursor, and without the bar and outline of
    /// a recording in progress.
    private static func capture(_ display: SCDisplay, in content: SCShareableContent) async throws -> CGImage {
        let overlay = Recording.overlayWindowIDs
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { overlay.contains($0.windowID) })
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration(for: filter))
    }

    /// One window on its own, without its shadow (screencapture -W -o), and its pixels per point.
    private static func capture(_ window: SCWindow) async throws -> (CGImage, CGFloat) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = configuration(for: filter)
        config.ignoreShadowsSingleWindow = true
        return (try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
                CGFloat(filter.pointPixelScale))
    }

    private static func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return config
    }

    struct PickableWindow {
        let id: CGWindowID
        /// In AppKit global coordinates (bottom-left origin).
        let frame: CGRect
        let window: SCWindow
    }

    /// Windows screencapture -W could pick (app windows, panels, the Dock, the menu bar), frontmost
    /// first: ScreenCaptureKit doesn't promise an order; the window server list does. Full-screen
    /// windows above the normal level are skipped, since they are overlays that would hide every
    /// window under them.
    private static func pickableWindows(_ content: SCShareableContent) -> [PickableWindow] {
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]] ?? []
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        // Screens in window-server coordinates (top-left origin), to spot full-screen overlays.
        let screens = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: top - $0.frame.maxY,
                                                     width: $0.frame.width, height: $0.frame.height) }
        return info.compactMap { w in
            guard let layer = w[kCGWindowLayer] as? Int, layer >= 0, layer < Int(CGWindowLevelForKey(.screenSaverWindow)),
                  (w[kCGWindowAlpha] as? Double ?? 1) > 0,
                  let id = w[kCGWindowNumber] as? CGWindowID, let sc = byID[id],
                  let dict = w[kCGWindowBounds], let r = CGRect(dictionaryRepresentation: dict as! CFDictionary),
                  r.width >= 8, r.height >= 8 else { return nil }
            if layer != 0, screens.contains(where: { r.contains($0) }) { return nil }
            return PickableWindow(id: id, frame: CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height),
                                  window: sc)
        }
    }
}

/// The window server's switch that lets a background app set the cursor. Private, but unchanged
/// since Mac OS X 10.5; without it the crosshair waits for the first mouse move. Looked up at run
/// time, so a macOS without it only loses the early crosshair.
enum BackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    /// On while the picker is up, so the crosshair shows at once; off again after, so Shotate
    /// never sets the cursor over the app you're using.
    static func set(_ on: Bool) {
        guard let conn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CGSDefaultConnection"),
              let prop = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetConnectionProperty") else { return }
        let cid = unsafeBitCast(conn, to: DefaultConnection.self)()
        let err = unsafeBitCast(prop, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString,
                                                           on ? kCFBooleanTrue : kCFBooleanFalse)
        if err != 0 { NSLog("Shotate: SetsCursorInBackground %d failed: %d", on ? 1 : 0, err) }
    }
}

/// The full-screen chooser over the frozen screens: drag out an area, or (in window mode, or after
/// Space) click a window. Esc or a right-click cancels.
final class Picker {
    enum Choice {
        /// In AppKit global coordinates, within `screen`.
        case area(screen: NSScreen, rect: CGRect)
        case window(CGWindowID)
    }

    static var current: Picker?

    private var overlays: [PickerWindow] = []
    /// The frozen screens; a chosen area names one of these.
    private var screens: [NSScreen] = []
    let windows: [(id: CGWindowID, frame: CGRect)]
    var windowMode: Bool
    /// Space switches between dragging an area and clicking a window.
    var toggles = true
    private let done: (Choice?) -> Void
    /// Drag start and current point, in global coordinates, and the screen it started on.
    var dragStart: CGPoint?
    var dragPoint: CGPoint?
    var dragScreen: NSScreen?
    var hovered: CGWindowID?

    static func show(shots: [(NSScreen, CGImage)], windows: [(CGWindowID, CGRect)], windowMode: Bool, toggles: Bool = true,
                     done: @escaping (Choice?) -> Void) {
        let p = Picker(windows: windows.map { (id: $0.0, frame: $0.1) }, windowMode: windowMode, done: done)
        p.toggles = toggles
        current = p
        p.screens = shots.map(\.0)
        p.overlays = shots.map { PickerWindow(screen: $0.0, image: $0.1, picker: p) }
        // The overlays take keys without activating Shotate, so the app being captured keeps its
        // active look and its focus comes back on Esc.
        let mouse = NSEvent.mouseLocation
        for w in p.overlays { w.orderFrontRegardless() }
        (p.overlays.first { $0.frame.contains(mouse) } ?? p.overlays[0]).makeKey()
        p.hover(at: mouse)
        p.refresh()
        // Shotate stays in the background while you pick, and macOS ignores a background app's
        // cursor until the mouse moves, so the pointer stayed an arrow and nothing said to drag.
        // The window server lets an app opt in to setting it from the background.
        BackgroundCursor.set(true)
        NSCursor.crosshair.set()
        // The window server puts back its own cursor when the overlay arrives under the pointer;
        // set it again once the overlay is there.
        for delay in [0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if Picker.current === p { NSCursor.crosshair.set() }
            }
        }
    }

    private init(windows: [(id: CGWindowID, frame: CGRect)], windowMode: Bool, done: @escaping (Choice?) -> Void) {
        self.windows = windows
        self.windowMode = windowMode
        self.done = done
    }

    /// The dragged rectangle, kept on the screen where the drag started and snapped to its pixels.
    var selection: CGRect? {
        guard let a = dragStart, let b = dragPoint, let s = dragScreen else { return nil }
        let scale = s.backingScaleFactor
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let r = CGRect(x: snap(min(a.x, b.x)), y: snap(min(a.y, b.y)),
                       width: snap(abs(a.x - b.x)), height: snap(abs(a.y - b.y))).intersection(s.frame)
        return r.isNull ? nil : r
    }

    var hoveredFrame: CGRect? { windows.first { $0.id == hovered }?.frame }

    func hover(at p: CGPoint) {
        let id = windows.first { $0.frame.contains(p) }?.id
        if id != hovered { hovered = id; refresh() }
    }

    func mouseDown(at p: CGPoint) {
        guard !windowMode else { return }
        dragScreen = screens.first { NSMouseInRect(p, $0.frame, false) } ?? screens.first
        dragStart = p
        dragPoint = p
        refresh()
    }

    func mouseDragged(to p: CGPoint) {
        guard dragStart != nil else { return }
        dragPoint = p
        refresh()
    }

    func mouseUp(at p: CGPoint) {
        if windowMode {
            hover(at: p)
            if let id = hovered { finish(.window(id)) }
            return
        }
        guard dragStart != nil else { return }
        dragPoint = p
        // A click without a drag picks nothing, like screencapture; start over.
        if let r = selection, let s = dragScreen, r.width >= 2, r.height >= 2 {
            finish(.area(screen: s, rect: r))
        } else {
            dragStart = nil
            dragPoint = nil
            refresh()
        }
    }

    func toggleMode() {
        guard toggles, dragStart == nil else { return }
        windowMode.toggle()
        hover(at: NSEvent.mouseLocation)
        refresh()
    }

    func cancel() { finish(nil) }

    func refresh() { for w in overlays { w.overlay.update() } }

    private func finish(_ choice: Choice?) {
        guard Picker.current === self else { return }
        Picker.current = nil
        for w in overlays { w.orderOut(nil) }
        overlays = []
        BackgroundCursor.set(false)
        done(choice)
    }
}

private final class PickerWindow: NSPanel {
    let overlay: PickerView

    init(screen: NSScreen, image: CGImage, picker: Picker) {
        overlay = PickerView(screen: screen, image: image, picker: picker)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: false)
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        setFrame(screen.frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        contentView = overlay
        initialFirstResponder = overlay
        makeFirstResponder(overlay)
    }

    override var canBecomeKey: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        makeFirstResponder(overlay)
    }
}

/// One screen's frozen image with the selection drawn over it. Layers do the drawing, so moving the
/// mouse only changes a few paths.
private final class PickerView: NSView {
    private unowned let picker: Picker
    private let screen: NSScreen
    private let dim = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let label = CATextLayer()

    init(screen: NSScreen, image: CGImage, picker: Picker) {
        self.picker = picker
        self.screen = screen
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        let root = CALayer()
        root.contents = image
        root.contentsGravity = .resize
        root.magnificationFilter = .nearest
        root.minificationFilter = .nearest
        layer = root
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor(white: 0, alpha: 0.3).cgColor
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.cgColor
        outline.lineWidth = 1
        outline.shadowOpacity = 0.6
        outline.shadowRadius = 1
        outline.shadowOffset = .zero
        label.fontSize = 11
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.foregroundColor = NSColor.white.cgColor
        label.backgroundColor = NSColor(white: 0, alpha: 0.65).cgColor
        label.cornerRadius = 4
        label.alignmentMode = .center
        label.contentsScale = screen.backingScaleFactor
        for l in [dim, outline, label] as [CALayer] { root.addSublayer(l) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    /// The event's location in global coordinates.
    private func global(_ e: NSEvent) -> CGPoint {
        window.map { $0.convertPoint(toScreen: e.locationInWindow) } ?? NSEvent.mouseLocation
    }

    override func mouseMoved(with e: NSEvent) {
        NSCursor.crosshair.set()
        if picker.windowMode { picker.hover(at: global(e)) }
    }
    override func mouseDown(with e: NSEvent) { picker.mouseDown(at: global(e)) }
    override func mouseDragged(with e: NSEvent) { picker.mouseDragged(to: global(e)) }
    override func mouseUp(with e: NSEvent) { picker.mouseUp(at: global(e)) }
    override func rightMouseDown(with e: NSEvent) { picker.cancel() }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: picker.cancel()        // Esc
        case 49: picker.toggleMode()    // Space
        default: break
        }
    }

    /// `r` (global) in this view's coordinates.
    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }

    func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let hole: CGRect? = picker.windowMode ? picker.hoveredFrame : picker.selection
        let mine = hole.map(local)?.intersection(bounds)
        let shown = mine.map { !$0.isNull && !$0.isEmpty } ?? false
        // Dim everything but the hole while there is one; in window mode dim the other windows.
        if picker.windowMode || picker.selection != nil {
            let path = CGMutablePath()
            path.addRect(bounds)
            if let mine, shown { path.addRect(mine) }
            dim.path = path
        } else {
            dim.path = nil
        }
        outline.path = shown ? CGPath(rect: mine!.insetBy(dx: -0.5, dy: -0.5), transform: nil) : nil
        if !picker.windowMode, shown, let sel = picker.selection {
            let s = screen.backingScaleFactor
            label.string = "\(Int((sel.width * s).rounded())) × \(Int((sel.height * s).rounded()))"
            let size = CGSize(width: 90, height: 18)
            var origin = CGPoint(x: mine!.maxX - size.width, y: mine!.minY - size.height - 6)
            if origin.y < 4 { origin.y = mine!.minY + 6 }
            origin.x = max(4, origin.x)
            label.frame = CGRect(origin: origin, size: size)
            label.isHidden = false
        } else {
            label.isHidden = true
        }
    }
}
