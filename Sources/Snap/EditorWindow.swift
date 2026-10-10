import AppKit
import SnapCore

/// One screenshot's editor. The capture is already on disk and on the clipboard before this opens,
/// so closing it never loses the screenshot; edits are written back when it closes.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let doc: Document
    let fileURL: URL
    let canvas: CanvasView
    var onClose: ((EditorWindowController) -> Void)?
    private var toolControl = NSSegmentedControl()
    private var sizeControl = NSSegmentedControl()
    private var colorButtons: [NSButton] = []
    private var undoButton = NSButton()
    private var redoButton = NSButton()
    private var finished = false

    init(document: Document, fileURL: URL) {
        doc = document
        self.fileURL = fileURL
        canvas = CanvasView(document: document)

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var size = CGSize(width: CGFloat(document.image.width) / scale, height: CGFloat(document.image.height) / scale)
        let fit = min(1, screen.width * 0.85 / size.width, (screen.height * 0.85 - 60) / size.height)
        size = CGSize(width: max(size.width * fit, 640), height: max(size.height * fit, 240) + 52)

        let window = EditorWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
        window.title = fileURL.deletingPathExtension().lastPathComponent
        window.representedURL = fileURL
        window.minSize = CGSize(width: 640, height: 300)
        window.isReleasedWhenClosed = false
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
            toolControl.setToolTip("\(t.title) (\(t.rawValue.uppercased()))", forSegment: i)
        }
        bar.addArrangedSubview(toolControl)

        for (i, c) in RGBA.palette.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(colorClicked(_:)))
            b.tag = i
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = c.cgColor
            b.layer?.cornerRadius = 9
            b.layer?.borderColor = NSColor.controlAccentColor.cgColor
            b.toolTip = "Color \(i + 1)"
            b.setAccessibilityLabel("Color \(i + 1)")
            b.widthAnchor.constraint(equalToConstant: 18).isActive = true
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            colorButtons.append(b)
            bar.addArrangedSubview(b)
        }

        sizeControl = NSSegmentedControl(labels: ["S", "M", "L"], trackingMode: .selectOne, target: self,
                                         action: #selector(sizeChanged))
        sizeControl.selectedSegment = 1
        sizeControl.toolTip = "Stroke and text size ([ and ])"
        bar.addArrangedSubview(sizeControl)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(spacer)

        undoButton = iconButton("arrow.uturn.backward", "Undo (⌘Z)", #selector(undoClicked))
        redoButton = iconButton("arrow.uturn.forward", "Redo (⇧⌘Z)", #selector(redoClicked))
        bar.addArrangedSubview(undoButton)
        bar.addArrangedSubview(redoButton)
        bar.addArrangedSubview(DragOutButton(controller: self))
        bar.addArrangedSubview(iconButton("doc.on.clipboard", "Copy file path (⇧⌘C), for terminals", #selector(copyPathClicked)))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyClicked))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "\r"
        copy.toolTip = "Copy the image and close (Return or ⌘C)"
        bar.addArrangedSubview(copy)

        let barBackground = NSVisualEffectView()
        barBackground.material = .titlebar
        barBackground.blendingMode = .withinWindow
        bar.translatesAutoresizingMaskIntoConstraints = false
        barBackground.addSubview(bar)

        let root = NSView()
        let canvasHolder = NSView()
        canvasHolder.wantsLayer = true
        canvasHolder.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        for v in [barBackground, canvasHolder] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
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
            canvasHolder.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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
        for (j, b) in colorButtons.enumerated() { b.layer?.borderWidth = j == i ? 2.5 : 0 }
    }

    func select(size: StrokeSize) {
        canvas.applySizeToSelection(size)
        sizeControl.selectedSegment = size.rawValue - 1
    }

    private func refresh() {
        undoButton.isEnabled = doc.canUndo
        redoButton.isEnabled = doc.canRedo
        window?.isDocumentEdited = doc.isEdited
    }

    @objc private func toolChanged() { select(tool: Tool.allCases[toolControl.selectedSegment]) }
    @objc private func colorClicked(_ b: NSButton) { select(colorIndex: b.tag) }
    @objc private func sizeChanged() { select(size: StrokeSize(rawValue: sizeControl.selectedSegment + 1) ?? .medium) }
    @objc private func undoClicked() { canvas.undo() }
    @objc private func redoClicked() { canvas.redo() }
    @objc private func copyClicked() { finish(copyImage: true) }
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
        default: break
        }
        guard mods.isEmpty || mods == [.shift] else { return false }
        switch e.keyCode {
        case 36, 76: finish(copyImage: true); return true                       // Return
        case 53: finish(copyImage: false); return true                          // Esc
        case 51, 117: canvas.deleteSelection(); return true                     // Delete
        default: break
        }
        if let t = Tool(rawValue: chars) { select(tool: t); return true }
        if let n = Int(chars), (1...RGBA.palette.count).contains(n) { select(colorIndex: n - 1); return true }
        if chars == "[" { select(size: StrokeSize(rawValue: max(1, canvas.size.rawValue - 1))!); return true }
        if chars == "]" { select(size: StrokeSize(rawValue: min(3, canvas.size.rawValue + 1))!); return true }
        return false
    }

    // MARK: Output

    func flattened() -> CGImage? { Renderer.flatten(doc) }

    /// Writes edits back to the capture file. Copies the image (or its path) when asked.
    func finish(copyImage: Bool, copyPath: Bool = false) {
        guard !finished else { return }
        canvas.commitText()
        finished = true
        if let image = flattened() {
            if doc.isEdited { Output.write(image, to: fileURL) }
            if copyImage { Output.copy(image, fileURL: fileURL) }
        }
        if copyPath { Output.copyPath(fileURL) }
        window?.close()
    }

    func saveCopy() {
        guard let window, let image = flattened() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.beginSheetModal(for: window) { r in
            if r == .OK, let url = panel.url { Output.write(image, to: url) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if !finished {
            finished = true
            canvas.commitText()
            if doc.isEdited, let image = flattened() { Output.write(image, to: fileURL) }
        }
        onClose?(self)
    }
}

final class EditorWindow: NSWindow {
    weak var controller: EditorWindowController?
    override func keyDown(with e: NSEvent) {
        if controller?.handleKey(e) != true { super.keyDown(with: e) }
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
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
        guard let c = controller else { return }
        c.canvas.commitText()
        if c.doc.isEdited, let image = c.flattened() { Output.write(image, to: c.fileURL) }
        let item = NSDraggingItem(pasteboardWriter: c.fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: c.fileURL.path))
        beginDraggingSession(with: [item], event: e, source: self)
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
}

enum Output {
    static func write(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = Renderer.pngData(image) { try? data.write(to: url, options: .atomic) }
    }

    /// PNG data plus the file: terminals such as Claude Code paste the image with Ctrl+V,
    /// Finder and chat apps get the file.
    static func copy(_ image: CGImage, fileURL: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if let png = Renderer.pngData(image) { item.setData(png, forType: .png) }
        item.setString(fileURL.absoluteString, forType: .fileURL)
        pb.writeObjects([item])
    }

    /// The path as text, for pasting into a terminal prompt.
    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}
