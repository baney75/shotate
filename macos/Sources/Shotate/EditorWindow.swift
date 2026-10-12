import AppKit
import ShotateCore

/// One screenshot's editor. A capture is already on disk and on the clipboard before this opens.
/// Edits are written back into Shotate's own captures; an image opened from elsewhere is never
/// overwritten, its edits go to a "… (edited).png" copy next to it.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let doc: Document
    let fileURL: URL
    /// True for Shotate's own captures, false for images opened from Finder or the Open panel.
    let ownsFile: Bool
    let canvas: CanvasView
    var onClose: ((EditorWindowController) -> Void)?
    private var toolControl = NSSegmentedControl()
    private var sizeControl = NSSegmentedControl()
    private var colorButtons: [NSButton] = []
    private var undoButton = NSButton()
    private var redoButton = NSButton()
    private var deleteButton = NSButton()
    private var finished = false
    private let status = NSTextField(labelWithString: "")

    /// For the editor's tool keys and the fallback save folder.
    let settings: Settings

    /// The capture's PNG as screencapture wrote it, for copying before any edit is saved.
    private let capturePNG: Data?

    init(document: Document, fileURL: URL, ownsFile: Bool, capturePNG: Data? = nil, settings: Settings) {
        doc = document
        self.capturePNG = capturePNG
        self.settings = settings
        self.fileURL = fileURL
        self.ownsFile = ownsFile
        canvas = CanvasView(document: document)

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var size = CGSize(width: CGFloat(document.image.width) / scale, height: CGFloat(document.image.height) / scale)
        let fit = min(1, screen.width * 0.85 / size.width, (screen.height * 0.85 - 60) / size.height)
        size = CGSize(width: max(size.width * fit, 720), height: max(size.height * fit, 240) + 76)

        let window = EditorWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
        window.title = fileURL.deletingPathExtension().lastPathComponent
        window.representedURL = fileURL
        window.minSize = CGSize(width: 720, height: 320)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)  // open on the Space the user is looking at
        window.center()
        super.init(window: window)
        window.delegate = self
        window.controller = self
        buildContent()
        canvas.onChange = { [weak self] in self?.refresh() }
        select(tool: .arrow)
        select(colorIndex: 0)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeFirstResponder(canvas)
    }

    // MARK: Layout

    private func buildContent() {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        toolControl = NSSegmentedControl(images: Tool.allCases.map {
            NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)!
        }, trackingMode: .selectOne, target: self, action: #selector(toolChanged))
        for (i, t) in Tool.allCases.enumerated() {
            toolControl.setToolTip("\(t.title) (\(settings.key(for: t).uppercased()))", forSegment: i)
        }
        bar.addArrangedSubview(toolControl)

        for (i, c) in RGBA.palette.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(colorClicked(_:)))
            b.tag = i
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = c.cgColor
            b.layer?.cornerRadius = 10
            b.layer?.borderColor = NSColor.separatorColor.cgColor
            b.layer?.borderWidth = 1
            let name = ["Red", "Amber", "Blue", "Green", "Purple", "White"][i]
            b.toolTip = "\(name) (\(i + 1))"
            b.setAccessibilityLabel(name)
            b.widthAnchor.constraint(equalToConstant: 20).isActive = true
            b.heightAnchor.constraint(equalToConstant: 20).isActive = true
            colorButtons.append(b)
            bar.addArrangedSubview(b)
        }

        // Three dots of growing size read as stroke weight at a glance.
        sizeControl = NSSegmentedControl(images: [5.0, 8.0, 11.0].enumerated().map { i, pt in
            NSImage(systemSymbolName: "circle.fill", accessibilityDescription: ["Small", "Medium", "Large"][i])!
                .withSymbolConfiguration(.init(pointSize: pt, weight: .regular))!
        }, trackingMode: .selectOne, target: self, action: #selector(sizeChanged))
        sizeControl.selectedSegment = 1
        for (i, name) in ["Small", "Medium", "Large"].enumerated() {
            sizeControl.setToolTip("\(name) ([ and ] change size)", forSegment: i)
        }
        sizeControl.setAccessibilityLabel("Size")
        bar.addArrangedSubview(sizeControl)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(spacer)

        undoButton = iconButton("arrow.uturn.backward", "Undo (⌘Z)", #selector(undoClicked))
        redoButton = iconButton("arrow.uturn.forward", "Redo (⇧⌘Z)", #selector(redoClicked))
        deleteButton = iconButton("trash", "Delete the selected mark (Delete). ⌘⌫ moves the whole capture to the Trash.",
                                  #selector(deleteClicked))
        bar.addArrangedSubview(deleteButton)
        bar.addArrangedSubview(undoButton)
        bar.addArrangedSubview(redoButton)
        bar.addArrangedSubview(DragOutButton(controller: self))
        bar.addArrangedSubview(iconButton("doc.on.clipboard", "Copy file path (⇧⌘C), for terminals", #selector(copyPathClicked)))
        bar.addArrangedSubview(iconButton("square.and.arrow.down", "Save a copy as… (⌘S)", #selector(saveCopyClicked)))
        let copy = NSButton(title: "Copy & Close", target: self, action: #selector(copyClicked))
        copy.bezelStyle = .rounded
        copy.bezelColor = .controlAccentColor
        // Return is handled in handleKey so it can go to a text label being typed instead.
        copy.toolTip = "Copy the image and close (Return or ⌘C)"
        bar.addArrangedSubview(copy)

        let barBackground = NSVisualEffectView()
        barBackground.material = .titlebar
        barBackground.blendingMode = .withinWindow
        bar.translatesAutoresizingMaskIntoConstraints = false
        barBackground.addSubview(bar)

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingMiddle
        status.translatesAutoresizingMaskIntoConstraints = false
        let hint = NSTextField(labelWithString: "Return or Esc copies and closes · ⌘Z undo")
        hint.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)

        let root = NSView()
        let canvasHolder = NSView()
        canvasHolder.wantsLayer = true
        canvasHolder.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        for v in [barBackground, canvasHolder] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        root.addSubview(status)
        root.addSubview(hint)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvasHolder.addSubview(canvas)
        NSLayoutConstraint.activate([
            barBackground.topAnchor.constraint(equalTo: root.topAnchor),
            barBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            barBackground.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: barBackground.topAnchor),
            bar.bottomAnchor.constraint(equalTo: barBackground.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: barBackground.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: barBackground.trailingAnchor),
            canvasHolder.topAnchor.constraint(equalTo: barBackground.bottomAnchor),
            canvasHolder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvasHolder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvasHolder.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            status.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            status.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -12),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            hint.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            canvas.topAnchor.constraint(equalTo: canvasHolder.topAnchor, constant: 12),
            canvas.bottomAnchor.constraint(equalTo: canvasHolder.bottomAnchor, constant: -12),
            canvas.leadingAnchor.constraint(equalTo: canvasHolder.leadingAnchor, constant: 12),
            canvas.trailingAnchor.constraint(equalTo: canvasHolder.trailingAnchor, constant: -12),
        ])
        window?.contentView = root
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self,
                         action: action)
        b.bezelStyle = .texturedRounded
        b.toolTip = tip
        return b
    }

    // MARK: State

    func select(tool: Tool) {
        canvas.tool = tool
        toolControl.selectedSegment = Tool.allCases.firstIndex(of: tool) ?? 0
    }

    func select(colorIndex i: Int) {
        canvas.applyColorToSelection(RGBA.palette[i])
        showColor(i)
    }

    private func showColor(_ i: Int) {
        for (j, b) in colorButtons.enumerated() {
            b.layer?.borderWidth = j == i ? 3 : 1
            b.layer?.borderColor = (j == i ? NSColor.labelColor : NSColor.separatorColor).cgColor
        }
    }

    func select(size: StrokeSize) {
        canvas.applySizeToSelection(size)
        sizeControl.selectedSegment = size.rawValue - 1
    }

    private func refresh() {
        deleteButton.isEnabled = canvas.hasSelection
        undoButton.isEnabled = doc.canUndo
        redoButton.isEnabled = doc.canRedo
        window?.isDocumentEdited = doc.revision != savedRevision
        let where_ = ((savedCopy ?? fileURL).path as NSString).abbreviatingWithTildeInPath
        status.stringValue = !ownsFile && savedCopy == nil ? "Edits will be saved next to the original"
            : doc.revision != savedRevision ? "Unsaved edits · \(where_)" : "Saved to \(where_)"
    }

    @objc private func toolChanged() { select(tool: Tool.allCases[toolControl.selectedSegment]) }
    @objc private func colorClicked(_ b: NSButton) { select(colorIndex: b.tag) }
    @objc private func sizeChanged() { select(size: StrokeSize(rawValue: sizeControl.selectedSegment + 1) ?? .medium) }
    @objc private func undoClicked() { canvas.undo() }
    @objc private func deleteClicked() { canvas.deleteSelection() }
    @objc private func redoClicked() { canvas.redo() }
    @objc private func copyClicked() { finish(copyImage: true) }
    @objc private func saveCopyClicked() { saveCopy() }
    @objc private func copyPathClicked() { finish(copyImage: false, copyPath: true) }

    // MARK: Keys

    /// Single-key shortcuts while the canvas has focus. Returns true when handled.
    func handleKey(_ e: NSEvent) -> Bool {
        if canvas.isEditingText { return false }
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (mods, chars) {
        case ([.command], "z"): canvas.undo(); return true
        case ([.command, .shift], "z"): canvas.redo(); return true
        case ([.command], "c"): finish(copyImage: true); return true
        case ([.command, .shift], "c"): finish(copyImage: false, copyPath: true); return true
        case ([.command], "s"): saveCopy(); return true
        case ([.command], "d"): canvas.duplicateSelection(); return true
        case ([.command, .option], "c"): canvas.copyStyle(); return true
        case ([.command, .option], "v"):
            if let s = canvas.pasteStyle() {
                if let i = RGBA.palette.firstIndex(of: s.color) { showColor(i) }
                sizeControl.selectedSegment = s.size.rawValue - 1
            }
            return true
        case ([.command], "]"): canvas.reorderSelection(toFront: true); return true
        case ([.command], "["): canvas.reorderSelection(toFront: false); return true
        default: break
        }
        if mods == [.command], e.keyCode == 51 { trashCapture(); return true }   // ⌘⌫
        guard mods.isEmpty || mods == [.shift] else { return false }
        let step: CGFloat = mods == [.shift] ? 10 : 1
        switch e.keyCode {
        case 36, 76: finish(copyImage: true); return true                       // Return
        case 53:
            // Esc steps back one level at a time: drawing tool → Select tool → no selection → copy and close.
            if canvas.tool != .select { select(tool: .select) }
            else if canvas.hasSelection { canvas.deselect() }
            else { finish(copyImage: true) }
            return true
        case 51, 117: canvas.deleteSelection(); return true                     // Delete, Forward Delete
        case 123: canvas.nudgeSelection(dx: -step, dy: 0); return true
        case 124: canvas.nudgeSelection(dx: step, dy: 0); return true
        case 125: canvas.nudgeSelection(dx: 0, dy: -step); return true
        case 126: canvas.nudgeSelection(dx: 0, dy: step); return true
        default: break
        }
        if let t = settings.tool(forKey: chars) { select(tool: t); return true }
        if let n = Int(chars), (1...RGBA.palette.count).contains(n) { select(colorIndex: n - 1); return true }
        if chars == "[" { select(size: StrokeSize(rawValue: max(1, canvas.size.rawValue - 1))!); return true }
        if chars == "]" { select(size: StrokeSize(rawValue: min(3, canvas.size.rawValue + 1))!); return true }
        return false
    }

    // MARK: Output

    func flattened() -> CGImage? { Renderer.flatten(doc) }

    /// Where edits are saved: the capture itself, or a sibling copy for an opened file.
    var outputURL: URL {
        guard !ownsFile else { return fileURL }
        let base = fileURL.deletingPathExtension().lastPathComponent
        let dir = fileURL.deletingLastPathComponent()
        var url = dir.appendingPathComponent("\(base) (edited).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path), url != savedCopy {
            url = dir.appendingPathComponent("\(base) (edited \(n)).png")
            n += 1
        }
        return url
    }
    private var savedCopy: URL?
    private var savedRevision = 0

    /// Saves changes made since the last save and returns the file that now holds the image.
    /// Returns nil when the save failed; the user has been told and the window stays open.
    @discardableResult
    func saveEdits() -> URL? {
        canvas.commitText()
        guard doc.revision != savedRevision else { return savedCopy ?? fileURL }
        guard let image = flattened() else {
            Alerts.show("Shotate couldn't render this image", "Your edits are still open. Try Save a Copy (⌘S).",
                        in: window)
            return nil
        }
        var url = outputURL
        do {
            try Output.write(image, to: url, dpi: doc.dpi)
        } catch {
            // A read-only folder (a mounted disk image, a locked folder): fall back to the screenshots folder.
            let fallback = settings.newCaptureURL()
            do {
                try Output.write(image, to: fallback, dpi: doc.dpi)
                url = fallback
            } catch {
                Alerts.show("Shotate couldn't save this image", error: error, in: window)
                return nil
            }
        }
        savedRevision = doc.revision
        if !ownsFile || url != fileURL { savedCopy = url }
        refresh()
        return url
    }

    /// Return, ⌘C, ⇧⌘C: save edits, copy the image or its path, close.
    func finish(copyImage: Bool, copyPath: Bool = false) {
        guard !finished, let url = saveEdits() else { return }
        finished = true
        if copyImage, !copy(savedAt: url) {
            finished = false
            Alerts.show("Shotate couldn't copy the image", "It is saved at \(url.path).", in: window)
            return
        }
        if copyPath { Output.copyPath(url) }
        window?.close()
    }

    /// Copies the image `saveEdits` just saved at `url` without rendering and encoding it again: an
    /// unedited capture copies the bytes it was captured with, and a PNG Shotate saved copies that
    /// file. An opened original may be another format, so it is rendered.
    private func copy(savedAt url: URL) -> Bool {
        if savedRevision == 0, let png = capturePNG { return Output.copy(png: png, fileURL: url) }
        if ownsFile || url == savedCopy, let png = try? Data(contentsOf: url) { return Output.copy(png: png, fileURL: url) }
        return flattened().map { Output.copy($0, fileURL: url, dpi: doc.dpi) } ?? false
    }

    /// Esc and the close button: discard unsaved edits only after asking.
    func closeAsking() {
        canvas.commitText()
        guard doc.revision != savedRevision, doc.isEdited || savedRevision != 0, let window else {
            finished = true
            self.window?.close()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Keep your annotations?"
        alert.informativeText = ownsFile ? "The capture is already saved; this only affects your edits."
            : "Edits are saved as a copy next to the original."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard let self else { return }
            switch r {
            case .alertFirstButtonReturn: if self.saveEdits() == nil { return }
            case .alertSecondButtonReturn:
                // Discard: put an owned capture back to the clean original if a drag-out saved marks.
                if self.ownsFile, self.savedRevision != 0 {
                    try? Output.write(self.doc.image, to: self.fileURL, dpi: self.doc.dpi)
                }
            default: return
            }
            self.finished = true
            self.window?.close()
        }
    }

    /// ⌘⌫: a capture you didn't want goes to the Trash (recoverable). An opened image is never trashed;
    /// only Shotate's edited copy of it is.
    func trashCapture() {
        canvas.commitText()
        guard let window else { return }
        let target = ownsFile ? fileURL : savedCopy
        let alert = NSAlert()
        alert.messageText = target == nil ? "Discard your annotations?" : "Move \(target!.lastPathComponent) to the Trash?"
        alert.informativeText = ownsFile ? "The capture is removed from your screenshots folder. You can restore it from the Trash."
            : "The original image is not touched."
        alert.addButton(withTitle: target == nil ? "Discard" : "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            if let target {
                do { try FileManager.default.trashItem(at: target, resultingItemURL: nil) } catch {
                    Alerts.show("Shotate couldn't move \(target.lastPathComponent) to the Trash", error: error, in: window)
                    return
                }
            }
            self.finished = true
            self.window?.close()
        }
    }

    func saveCopy() {
        guard let window, let image = flattened() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.beginSheetModal(for: window) { [doc] r in
            guard r == .OK, let url = panel.url else { return }
            do { try Output.write(image, to: url, dpi: doc.dpi) } catch {
                Alerts.show("Shotate couldn't save \(url.lastPathComponent)", error: error, in: window)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if finished || doc.revision == savedRevision { return true }
        closeAsking()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        finished = true
        onClose?(self)
    }
}

final class EditorWindow: NSWindow {
    weak var controller: EditorWindowController?
    override func keyDown(with e: NSEvent) {
        if controller?.handleKey(e) != true { super.keyDown(with: e) }
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        // While a label is being typed, plain keys (Return included) belong to the text field.
        if controller?.canvas.isEditingText == true, !e.modifierFlags.contains(.command) { return false }
        if e.modifierFlags.contains(.command), controller?.handleKey(e) == true { return true }
        return super.performKeyEquivalent(with: e)
    }
}

/// Drag the finished PNG into another app: a chat, a terminal running Claude Code, Finder.
final class DragOutButton: NSButton, NSDraggingSource {
    weak var controller: EditorWindowController?
    init(controller: EditorWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Drag the image out")
        bezelStyle = .texturedRounded
        toolTip = "Drag the image into another app"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with e: NSEvent) {
        guard let c = controller, let url = c.saveEdits() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: e, source: self)
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
}

enum Output {
    static func write(_ image: CGImage, to url: URL, dpi: CGFloat) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = Renderer.pngData(image, dpi: dpi) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The image couldn't be encoded as PNG."])
        }
        try data.write(to: url, options: .atomic)
    }

    /// Moves a finished PNG (a fresh capture) to `url`, making its folder if needed.
    static func place(_ file: URL, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: url)
    }

    /// One clipboard item with PNG data, a TIFF made only if an app asks for it, and the file.
    /// Terminals such as Claude Code paste the image with Ctrl+V; Finder and chat apps get the file.
    /// Returns false when nothing was copied.
    @discardableResult
    static func copy(_ image: CGImage, fileURL: URL, dpi: CGFloat) -> Bool {
        guard let png = Renderer.pngData(image, dpi: dpi) else { return false }
        return copy(png: png, fileURL: fileURL)
    }

    /// The same, from PNG data already in hand.
    @discardableResult
    static func copy(png: Data, fileURL: URL) -> Bool {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setDataProvider(TIFFProvider(png: png), forTypes: [.tiff])
        item.setString(fileURL.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([item])
    }

    /// The path as text, for pasting into a terminal prompt.
    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}

/// Builds TIFF on demand for older apps that don't read PNG from the clipboard.
private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    let png: Data
    init(png: Data) { self.png = png }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation(using: .lzw, factor: 0) {
            item.setData(tiff, forType: .tiff)
        }
    }
}
