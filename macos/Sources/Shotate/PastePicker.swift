import AppKit
import Carbon.HIToolbox
import ImageIO
import ShotateCore

/// With "Choose which screenshot to paste" on, ⌘V asks which one when several were copied lately:
/// a menu at the pointer lists them newest first, numbered 1–9. Shotate claims ⌘V only while the
/// clipboard still holds its own screenshot, so anything copied since pastes as usual.
final class PastePicker {
    private let hotkeys: Hotkeys
    private let enabled: () -> Bool
    private var choices = PasteChoices()
    /// Pixel size and a small thumbnail per screenshot, made once when it's copied. The image
    /// itself is read from its file only when chosen.
    private var sizes: [URL: CGSize] = [:]
    private var thumbnails: [URL: NSImage] = [:]
    /// The pasteboard's change count right after Shotate last wrote it.
    private var ourChangeCount = -1
    /// ⌘V stays unclaimed until then: while the chosen screenshot is being pasted, or, without
    /// Accessibility, so the next ⌘V pastes it.
    private var holdOffUntil = Date.distantPast
    /// The copy the picker makes itself, which shouldn't reorder the list.
    private var choosing = false
    private var timer: Timer?

    init(hotkeys: Hotkeys, enabled: @escaping () -> Bool) {
        self.hotkeys = hotkeys
        self.enabled = enabled
        hotkeys.onPaste = { [weak self] in self?.ask() }
        Output.onCopied = { [weak self] file, png, count in self?.copied(file, png: png, changeCount: count) }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Switching apps changes who ⌘V belongs to; don't wait for the timer.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.update() }
        }
    }

    private func copied(_ file: URL, png: Data, changeCount: Int) {
        ourChangeCount = changeCount
        // With the option off, nothing is kept.
        guard !choosing, enabled() else { return update() }
        choices.copied(file)
        let source = CGImageSourceCreateWithData(png as CFData, nil)
        if let source, let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            sizes[file] = CGSize(width: w, height: h)
        }
        thumbnails[file] = source.flatMap(Self.thumbnail)
        update()
    }

    /// Claims ⌘V exactly while a paste should ask.
    func update() {
        choices.prune()
        let kept = Set(choices.entries.map(\.file))
        sizes = sizes.filter { kept.contains($0.key) }
        thumbnails = thumbnails.filter { kept.contains($0.key) }
        let ours = NSPasteboard.general.changeCount == ourChangeCount
        // In Shotate's own windows ⌘V is theirs.
        let ask = choices.shouldAsk(enabled: enabled(), clipboardIsOurs: ours) && Date() >= holdOffUntil && !NSApp.isActive
        if ask != hotkeys.pasteClaimed { hotkeys.claimPaste(ask) }
    }

    private func ask() {
        update()
        guard hotkeys.pasteClaimed else {
            // Something changed since ⌘V was claimed (text copied, another app in front): this ⌘V
            // was meant for the app in front, so pass it on.
            if AXIsProcessTrusted() { Self.pressCommandV() }
            return
        }
        let trusted = AXIsProcessTrusted()
        let menu = NSMenu(title: "Paste a Screenshot")
        menu.autoenablesItems = false
        let header = NSMenuItem(title: trusted ? "Paste which screenshot?" : "Choose one, then press ⌘V again", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let now = Date()
        for (i, e) in choices.entries.enumerated() {
            let item = NSMenuItem(title: label(e, now: now), action: #selector(chosen(_:)), keyEquivalent: "\(i + 1)")
            item.keyEquivalentModifierMask = []
            item.target = self
            item.representedObject = e.file
            item.image = thumbnails[e.file]
            item.state = e.pasted ? .on : .off
            menu.addItem(item)
        }
        // The newest is under the pointer, so Return pastes it.
        menu.popUp(positioning: menu.items.count > 1 ? menu.items[1] : nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func chosen(_ item: NSMenuItem) {
        guard let file = item.representedObject as? URL,
              let png = try? Data(contentsOf: file) else { return NSSound.beep() }
        choosing = true
        Output.copy(png: png, fileURL: file)
        choosing = false
        choices.markPasted(file)
        hotkeys.claimPaste(false)
        guard AXIsProcessTrusted() else {
            // Without permission to type ⌘V, the next ⌘V is the user's own and pastes this one.
            holdOffUntil = Date().addingTimeInterval(10)
            return
        }
        holdOffUntil = Date().addingTimeInterval(0.6)
        // The menu has closed and the app in front has its keys back; paste there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Self.pressCommandV() }
    }

    private static func pressCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(Hotkeys.keyCode(typing: "v")), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    /// "Just now · 1280 × 720", "4 min ago · 640 × 480".
    private func label(_ e: PasteChoices.Entry, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(e.copiedAt) / 60)
        let when = minutes < 1 ? "Just now" : "\(minutes) min ago"
        guard let size = sizes[e.file] else { return when }
        return "\(when) · \(Int(size.width)) × \(Int(size.height))"
    }

    /// The screenshot shrunk to fit 72 × 48 points, drawn once at Retina size.
    private static func thumbnail(_ source: CGImageSource) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 144,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Two pixels per point, shrunk further if it still doesn't fit.
        let points = CGSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
        let fit = min(72 / points.width, 48 / points.height, 1)
        return NSImage(cgImage: cg, size: NSSize(width: (points.width * fit).rounded(), height: (points.height * fit).rounded()))
    }
}
