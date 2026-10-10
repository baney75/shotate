import AppKit
import SnapmarkCore

/// Shows the screenshot scaled to fit and turns mouse input into marks. All geometry is kept in
/// image pixels (origin bottom-left); the view converts at the edges.
///
/// Interaction follows the conventions of canvas editors such as tldraw and Figma: a new mark is
/// selected as soon as it is drawn, so Delete removes it and color and size apply to it; a selected
/// mark shows handles to resize it; Esc deselects before it closes; right-click offers the actions.
/// Text is placed by clicking (or dragging a box to set its size), moved by dragging it with the
/// Text or Select tool, and scaled from its corner handle.
final class CanvasView: NSView, NSTextFieldDelegate {
    let doc: Document
    var tool: Tool = .arrow {
        didSet { commitText(); selectedID = nil; window?.invalidateCursorRects(for: self) }
    }
    var color: RGBA = RGBA.palette[0]
    var size: StrokeSize = .medium
    var onChange: (() -> Void)?

    private(set) var selectedID: UUID? { didSet { if oldValue != selectedID { needsDisplay = true; onChange?() } } }
    private var hoverID: UUID? { didSet { if oldValue != hoverID { needsDisplay = true } } }
    private var draft: Mark? { didSet { needsDisplay = true } }
    /// The selected mark while it is being moved or resized, before the change is committed.
    private var live: Mark? { didSet { needsDisplay = true } }
    private var dragOrigin: CGPoint?
    private var dragHandle: Int?
    private var cropDraft: CGRect? { didSet { needsDisplay = true } }
    private var textField: NSTextField?
    private var editingID: UUID?
    private var textOrigin = CGPoint.zero
    private var textFontSize: CGFloat?
    /// A box being dragged with the Text tool to place and size a new label.
    private var textBox: CGRect? { didSet { needsDisplay = true } }
    /// A label pressed with the Text tool: released in place it opens for editing, dragged it moves.
    private var pressedLabel: Mark?
    private var tracking: NSTrackingArea?

    init(document: Document) {
        doc = document
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Screenshot")
        setAccessibilityHelp("Draw with the selected tool. Tools: V select, A arrow, R box, O ellipse, H highlight, "
                             + "T text, B redact, N step, C crop. Delete removes the selected mark.")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: Geometry

    /// The area shown, in image pixels: the canvas (the image, grown by any mark drawn past its edge)
    /// plus a margin to draw into. It holds still during a drag so the view doesn't zoom under the
    /// pointer, and catches up when the drag ends.
    private var frozenLayout: CGRect?
    private var layoutRect: CGRect {
        if let frozenLayout { return frozenLayout }
        let c = doc.canvas
        let margin = 0.07 * CGFloat(max(doc.image.width, doc.image.height))
        return c.insetBy(dx: -margin, dy: -margin)
    }
    private var scale: CGFloat {
        let l = layoutRect
        return min(bounds.width / max(l.width, 1), bounds.height / max(l.height, 1))
    }
    /// Where image pixel (0, 0) lands in the view.
    private var origin: CGPoint {
        let l = layoutRect, s = scale
        return CGPoint(x: (bounds.width - l.width * s) / 2 - l.minX * s, y: (bounds.height - l.height * s) / 2 - l.minY * s)
    }
    private var pixelsPerPoint: CGFloat { 1 / max(scale, 0.0001) }

    func imagePoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil), o = origin
        return CGPoint(x: (p.x - o.x) * pixelsPerPoint, y: (p.y - o.y) * pixelsPerPoint)
    }
    func viewPoint(_ p: CGPoint) -> CGPoint {
        let o = origin
        return CGPoint(x: o.x + p.x / pixelsPerPoint, y: o.y + p.y / pixelsPerPoint)
    }

    var selectedMark: Mark? { selectedID.flatMap { id in doc.marks.first { $0.id == id } } }

    /// The outline drawn around a selected or hovered mark, in image pixels.
    private func outline(_ m: Mark) -> CGRect {
        let r = (m.tool == .text || m.tool == .step) ? Renderer.textOrStepRect(m, imageWidth: doc.image.width) : m.rect
        let pad = 4 * pixelsPerPoint + m.size.width(forImageWidth: doc.image.width) / 2
        return r.insetBy(dx: -pad, dy: -pad)
    }

    /// A mark's grab points. A label has one, at the bottom-right corner of its box, to scale it.
    private func handles(of m: Mark) -> [CGPoint] {
        guard m.tool == .text else { return m.handles }
        let r = Renderer.textOrStepRect(m, imageWidth: doc.image.width)
        return [CGPoint(x: r.maxX, y: r.minY)]
    }

    private func moving(_ m: Mark, handle i: Int, to p: CGPoint) -> Mark {
        m.tool == .text ? Renderer.resizing(text: m, toCorner: p, imageWidth: doc.image.width) : m.moving(handle: i, to: p)
    }

    private func handleIndex(at p: CGPoint) -> Int? {
        guard let m = live ?? selectedMark else { return nil }
        let reach = 7 * pixelsPerPoint
        return handles(of: m).firstIndex { hypot($0.x - p.x, $0.y - p.y) <= reach }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let o = origin
        ctx.saveGState()
        ctx.translateBy(x: o.x, y: o.y)
        ctx.scaleBy(x: 1 / pixelsPerPoint, y: 1 / pixelsPerPoint)
        ctx.interpolationQuality = .high
        var marks = doc.marks
        if let l = live, let i = marks.firstIndex(where: { $0.id == l.id }) { marks[i] = l }
        if let d = draft { marks.append(d) }
        // The canvas as it will export: grown past the edge where marks reach, in the border color.
        let canvas = doc.canvas(including: marks)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2 * pixelsPerPoint), blur: 10 * pixelsPerPoint,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(doc.borderColor.cgColor)
        ctx.fill(canvas)
        ctx.restoreGState()
        Renderer.drawBackground(doc, canvas: canvas, in: ctx)
        for m in marks where m.id != editingID {
            Renderer.draw(m, in: ctx, imageWidth: doc.image.width)
        }
        // Dim everything outside the crop.
        if let crop = cropDraft ?? doc.effectiveCrop {
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            let path = CGMutablePath()
            path.addRect(canvas)
            path.addRect(crop)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(pixelsPerPoint)
            ctx.setLineDash(phase: 0, lengths: [6 * pixelsPerPoint, 4 * pixelsPerPoint])
            ctx.stroke(crop)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if let box = textBox {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.5 * pixelsPerPoint)
            ctx.setLineDash(phase: 0, lengths: [5 * pixelsPerPoint, 3 * pixelsPerPoint])
            ctx.stroke(box)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor ?? CGColor(srgbRed: 0.3, green: 0.56, blue: 0.98, alpha: 1)
        if let id = hoverID, id != selectedID, let m = marks.first(where: { $0.id == id }) {
            ctx.setStrokeColor(accent.copy(alpha: 0.5) ?? accent)
            ctx.setLineWidth(1.5 * pixelsPerPoint)
            ctx.stroke(outline(m))
        }
        if let id = selectedID, id != editingID, let m = marks.first(where: { $0.id == id }) {
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.5 * pixelsPerPoint)
            if m.tool != .arrow { ctx.stroke(outline(m)) }
            let side = 8 * pixelsPerPoint
            for h in handles(of: m) {
                let box = CGRect(x: h.x - side / 2, y: h.y - side / 2, width: side, height: side)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fillEllipse(in: box)
                ctx.strokeEllipse(in: box)
            }
        }
        ctx.restoreGState()
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Mouse

    override func mouseMoved(with e: NSEvent) {
        let p = imagePoint(e)
        if handleIndex(at: p) != nil { NSCursor.crosshair.set(); hoverID = nil; return }
        var hit = tool == .select || tool == .text ? doc.hitTest(p, tolerance: 6 * pixelsPerPoint) : nil
        if tool == .text, hit?.tool != .text { hit = nil }
        hoverID = hit?.id
        if tool == .select { (hit != nil ? NSCursor.openHand : NSCursor.arrow).set() }
        if tool == .text { (hit != nil ? NSCursor.openHand : NSCursor.iBeam).set() }
    }

    override func mouseExited(with e: NSEvent) { hoverID = nil }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        // Commit a label first: it may grow the canvas, and the new layout must be in place before
        // this click is mapped to the image or a new text field is positioned.
        if textField != nil { commitText() }
        frozenLayout = layoutRect
        let p = imagePoint(e)
        let tolerance = 8 * pixelsPerPoint
        // A selected mark's handles win over every tool, so a fresh arrow can be adjusted right away.
        if let i = handleIndex(at: p), let m = selectedMark {
            dragHandle = i
            live = m
            return
        }
        switch tool {
        case .select:
            if let hit = doc.hitTest(p, tolerance: tolerance) {
                selectedID = hit.id
                dragOrigin = p
                if e.clickCount == 2, hit.tool == .text { beginText(at: hit.start, editing: hit) }
                else { NSCursor.closedHand.set() }
            } else {
                selectedID = nil
            }
        case .text:
            if let hit = doc.hitTest(p, tolerance: tolerance), hit.tool == .text {
                selectedID = hit.id
                pressedLabel = hit
                dragOrigin = p
            } else {
                selectedID = nil
                dragOrigin = p
                textBox = CGRect(origin: p, size: .zero)
            }
        case .step:
            doc.add(Mark(tool: .step, color: color, size: size, start: p, end: p))
            selectedID = doc.marks.last?.id
            changed()
        case .crop:
            selectedID = nil
            dragOrigin = p
            cropDraft = CGRect(origin: p, size: .zero)
        default:
            selectedID = nil
            draft = Mark(tool: tool, color: color, size: size, start: p, end: p)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        var p = imagePoint(e)
        if let i = dragHandle, let m = live {
            let base = selectedMark ?? m
            if e.modifierFlags.contains(.shift) {
                // Same as drawing: 45° steps for an arrow, a square for a shape, from the fixed end.
                if base.tool != .text {
                    let fixed = base.tool == .arrow ? (i == 0 ? base.end : base.start) : base.moving(handle: i, to: p).start
                    p = base.tool == .arrow ? Geometry.snap45(from: fixed, to: p) : Geometry.square(from: fixed, to: p)
                }
            }
            live = moving(base, handle: i, to: p)
            return
        }
        if textBox != nil, let o = dragOrigin {
            textBox = CGRect(x: min(o.x, p.x), y: min(o.y, p.y), width: abs(p.x - o.x), height: abs(p.y - o.y))
            return
        }
        // A pressed label only starts to move past a few points, so a slightly shaky click still edits it.
        if pressedLabel != nil, let o = dragOrigin, live == nil, hypot(p.x - o.x, p.y - o.y) < 3 * pixelsPerPoint { return }
        if tool == .select || tool == .text, let o = dragOrigin, let m = selectedMark {
            live = m.offset(by: CGVector(dx: p.x - o.x, dy: p.y - o.y))
            return
        }
        if tool == .crop, let o = dragOrigin {
            cropDraft = CGRect(x: min(o.x, p.x), y: min(o.y, p.y), width: abs(p.x - o.x), height: abs(p.y - o.y))
            return
        }
        guard var d = draft else { return }
        if e.modifierFlags.contains(.shift) {
            p = d.tool == .arrow ? Geometry.snap45(from: d.start, to: p) : Geometry.square(from: d.start, to: p)
        }
        d.end = p
        draft = d
    }

    override func mouseUp(with e: NSEvent) {
        defer {
            dragOrigin = nil
            dragHandle = nil
            pressedLabel = nil
            textBox = nil
            frozenLayout = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        if let m = live {
            live = nil
            doc.update(m)
            changed()
            if tool == .select { NSCursor.openHand.set() }
            return
        }
        if let label = pressedLabel {
            beginText(at: label.start, editing: label)
            return
        }
        if let box = textBox {
            // A dragged box sets the text height; a click uses the preset size, centered on the click.
            let sized = box.height > 6 * pixelsPerPoint ? box.height / Renderer.textBoxHeight : nil
            let probe = Mark(tool: .text, color: color, size: size, start: box.origin, end: box.origin, fontSize: sized)
            let h = Renderer.textOrStepRect(probe, imageWidth: doc.image.width).height
            let top = sized == nil ? box.midY + h / 2 : box.maxY
            beginText(at: CGPoint(x: box.minX, y: top - h), editing: nil, fontSize: sized)
            return
        }
        if tool == .crop {
            // A click without a drag leaves the current crop alone.
            if let draft = cropDraft, draft.width >= 4 * pixelsPerPoint, draft.height >= 4 * pixelsPerPoint {
                doc.setCrop(draft)
            }
            cropDraft = nil
            changed()
            return
        }
        guard let d = draft else { return }
        draft = nil
        if hypot(d.end.x - d.start.x, d.end.y - d.start.y) > 3 * pixelsPerPoint {
            doc.add(d)
            selectedID = d.id
            changed()
        }
    }

    // MARK: Context menu

    override func menu(for e: NSEvent) -> NSMenu? {
        commitText()
        if let hit = doc.hitTest(imagePoint(e), tolerance: 8 * pixelsPerPoint) { selectedID = hit.id }
        guard selectedID != nil else { return nil }
        let menu = NSMenu()
        for (title, action, key) in [("Delete", #selector(deleteSelectionAction), "\u{8}"),
                                     ("Duplicate", #selector(duplicateSelectionAction), "d"),
                                     ("Bring to Front", #selector(bringToFrontAction), "]"),
                                     ("Send to Back", #selector(sendToBackAction), "[")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = key == "\u{8}" ? [] : [.command]
            item.target = self
            menu.addItem(item)
            if title == "Duplicate" { menu.addItem(.separator()) }
        }
        return menu
    }

    @objc func deleteSelectionAction() { deleteSelection() }
    @objc func duplicateSelectionAction() { duplicateSelection() }
    @objc func bringToFrontAction() { reorderSelection(toFront: true) }
    @objc func sendToBackAction() { reorderSelection(toFront: false) }

    // MARK: Text

    private func beginText(at p: CGPoint, editing: Mark?, fontSize sized: CGFloat? = nil) {
        let markColor = editing?.color ?? color
        let probe = editing ?? Mark(tool: .text, color: color, size: size, start: p, end: p, fontSize: sized)
        let fontSize = Renderer.fontSize(of: probe, imageWidth: doc.image.width) / pixelsPerPoint
        let field = NSTextField(frame: .zero)
        field.cell = LabelFieldCell(textCell: "")
        field.isEditable = true
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.stringValue = editing?.text ?? ""
        let ink = NSColor(cgColor: Renderer.ink(on: markColor).cgColor) ?? .white
        field.placeholderAttributedString = NSAttributedString(string: "Type, then Return", attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: ink.withAlphaComponent(0.65)])
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = ink
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.backgroundColor = markColor.cgColor.copy(alpha: 0.92)
        field.layer?.cornerRadius = fontSize * 0.35
        field.delegate = self
        addSubview(field)
        textField = field
        textOrigin = p
        textFontSize = editing?.fontSize ?? sized
        editingID = editing?.id
        fitTextField()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    /// Sizes the field to the pill the label will draw as, so typing looks like the result.
    private func fitTextField() {
        guard let field = textField else { return }
        let text = field.stringValue.isEmpty ? field.placeholderAttributedString?.string ?? "" : field.stringValue
        let m = Mark(tool: .text, color: color, size: editingID.flatMap { id in doc.marks.first { $0.id == id }?.size } ?? size,
                     start: textOrigin, end: textOrigin, text: text, fontSize: textFontSize)
        let r = Renderer.textOrStepRect(m, imageWidth: doc.image.width)
        let o = viewPoint(r.origin)
        // A few points of slack keep the caret and the last glyph from scrolling out of view.
        field.frame = CGRect(x: o.x, y: o.y, width: r.width / pixelsPerPoint + 4, height: r.height / pixelsPerPoint)
    }

    func controlTextDidChange(_ obj: Notification) { fitTextField() }

    func commitText() {
        guard let field = textField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        textField = nil
        if let id = editingID, var m = doc.marks.first(where: { $0.id == id }) {
            if text.isEmpty { doc.remove(id: id) } else { m.text = text; doc.update(m); selectedID = id }
        } else if !text.isEmpty {
            let m = Mark(tool: .text, color: color, size: size, start: textOrigin, end: textOrigin, text: text, fontSize: textFontSize)
            doc.add(m)
            selectedID = m.id
        }
        editingID = nil
        changed()
        window?.makeFirstResponder(self)
    }

    private func cancelText() {
        textField?.removeFromSuperview()
        textField = nil
        editingID = nil
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    var isEditingText: Bool { textField != nil }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commitText(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancelText(); return true }
        return false
    }

    // MARK: Editing commands

    var hasSelection: Bool { selectedMark != nil }

    func deselect() { selectedID = nil }

    func deleteSelection() {
        guard let id = selectedID else { return }
        doc.remove(id: id)
        selectedID = nil
        changed()
    }

    func duplicateSelection() {
        guard let m = selectedMark else { return }
        let copy = m.duplicate(offset: 12 * pixelsPerPoint)
        doc.add(copy)
        selectedID = copy.id
        changed()
    }

    func reorderSelection(toFront: Bool) {
        guard let id = selectedID else { return }
        doc.reorder(id: id, toFront: toFront)
        changed()
    }

    /// Arrow keys: 1 point, or 10 with Shift.
    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let m = selectedMark else { return }
        doc.update(m.offset(by: CGVector(dx: dx * pixelsPerPoint, dy: dy * pixelsPerPoint)))
        changed()
    }

    func applyColorToSelection(_ c: RGBA) {
        color = c
        if var m = selectedMark { m.color = c; doc.update(m); changed() }
    }

    func applySizeToSelection(_ s: StrokeSize) {
        size = s
        guard var m = selectedMark else { return }
        m.size = s
        if m.tool == .text {
            // A preset replaces a hand-set size; the label keeps its top-left corner.
            let top = Renderer.textOrStepRect(m, imageWidth: doc.image.width).maxY
            m.fontSize = nil
            m = Renderer.anchored(m, top: top, imageWidth: doc.image.width)
        }
        doc.update(m)
        changed()
    }

    func undo() { commitText(); doc.undo(); selectedID = nil; changed() }
    func redo() { commitText(); doc.redo(); selectedID = nil; changed() }

    private func changed() {
        needsDisplay = true
        let n = doc.marks.count
        setAccessibilityLabel(n == 0 ? "Screenshot" : "Screenshot with \(n) annotation\(n == 1 ? "" : "s")")
        onChange?()
    }
}

/// The label editor's cell: the text sits where the drawn label puts it, inset and vertically centered.
private final class LabelFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let size = font?.pointSize ?? 13
        // The cell adds its own 2-point text inset; take it back so the text lands where the label draws it.
        let inset = rect.insetBy(dx: max(0, size * 0.45 - 2), dy: 0)
        let h = cellSize(forBounds: inset).height
        return NSRect(x: inset.minX, y: inset.midY - h / 2, width: inset.width, height: h)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }
}
