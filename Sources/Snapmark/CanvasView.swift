import AppKit
import SnapmarkCore

/// Shows the screenshot scaled to fit and turns mouse input into marks. All geometry is kept in
/// image pixels (origin bottom-left); the view converts at the edges.
///
/// Interaction follows the conventions of canvas editors such as tldraw and Figma: a new mark is
/// selected as soon as it is drawn, so Delete removes it and color and size apply to it; a selected
/// mark shows handles to resize it; Esc deselects before it closes; right-click offers the actions.
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

    /// Where the image sits inside the view, aspect-fit and centered.
    var imageRect: CGRect {
        let iw = CGFloat(doc.image.width), ih = CGFloat(doc.image.height)
        let s = min(bounds.width / iw, bounds.height / ih)
        let w = iw * s, h = ih * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
    private var pixelsPerPoint: CGFloat { CGFloat(doc.image.width) / max(imageRect.width, 1) }

    func imagePoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        let r = imageRect
        return CGPoint(x: (p.x - r.minX) * pixelsPerPoint, y: (p.y - r.minY) * pixelsPerPoint)
    }
    func viewPoint(_ p: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: r.minX + p.x / pixelsPerPoint, y: r.minY + p.y / pixelsPerPoint)
    }

    var selectedMark: Mark? { selectedID.flatMap { id in doc.marks.first { $0.id == id } } }

    /// The outline drawn around a selected or hovered mark, in image pixels.
    private func outline(_ m: Mark) -> CGRect {
        let r = (m.tool == .text || m.tool == .step) ? Renderer.textOrStepRect(m, imageWidth: doc.image.width) : m.rect
        let pad = 4 * pixelsPerPoint + m.size.width(forImageWidth: doc.image.width) / 2
        return r.insetBy(dx: -pad, dy: -pad)
    }

    private func handleIndex(at p: CGPoint) -> Int? {
        guard let m = live ?? selectedMark else { return nil }
        let reach = 7 * pixelsPerPoint
        return m.handles.firstIndex { hypot($0.x - p.x, $0.y - p.y) <= reach }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = imageRect
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: 1 / pixelsPerPoint, y: 1 / pixelsPerPoint)
        ctx.interpolationQuality = .high
        ctx.draw(doc.image, in: doc.bounds)
        var marks = doc.marks
        if let l = live, let i = marks.firstIndex(where: { $0.id == l.id }) { marks[i] = l }
        if let d = draft { marks.append(d) }
        for m in marks where m.id != editingID {
            Renderer.draw(m, in: ctx, imageWidth: doc.image.width)
        }
        // Dim everything outside the crop.
        if let crop = cropDraft ?? doc.crop {
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            let path = CGMutablePath()
            path.addRect(doc.bounds)
            path.addRect(crop)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(pixelsPerPoint)
            ctx.setLineDash(phase: 0, lengths: [6 * pixelsPerPoint, 4 * pixelsPerPoint])
            ctx.stroke(crop)
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
            for h in m.handles {
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
        addCursorRect(imageRect, cursor: cursor)
    }

    // MARK: Mouse

    override func mouseMoved(with e: NSEvent) {
        let p = imagePoint(e)
        if handleIndex(at: p) != nil { NSCursor.crosshair.set(); hoverID = nil; return }
        let hit = tool == .select ? doc.hitTest(p, tolerance: 6 * pixelsPerPoint) : nil
        hoverID = hit?.id
        if tool == .select { (hit != nil ? NSCursor.openHand : NSCursor.arrow).set() }
    }

    override func mouseExited(with e: NSEvent) { hoverID = nil }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = imagePoint(e)
        let tolerance = 8 * pixelsPerPoint
        if textField != nil { commitText() }
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
                beginText(at: hit.start, editing: hit)
            } else {
                beginText(at: p, editing: nil)
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
                let fixed = base.tool == .arrow ? (i == 0 ? base.end : base.start) : base.moving(handle: i, to: p).start
                p = base.tool == .arrow ? Geometry.snap45(from: fixed, to: p) : Geometry.square(from: fixed, to: p)
            }
            live = base.moving(handle: i, to: p)
            return
        }
        if tool == .select, let o = dragOrigin, let m = selectedMark {
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
        defer { dragOrigin = nil; dragHandle = nil }
        if let m = live {
            live = nil
            doc.update(m)
            changed()
            if tool == .select { NSCursor.openHand.set() }
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

    private func beginText(at p: CGPoint, editing: Mark?) {
        let vp = viewPoint(p)
        let fontSize = Renderer.fontSize(imageWidth: doc.image.width, size: editing?.size ?? size) / pixelsPerPoint
        let field = NSTextField(frame: CGRect(x: vp.x, y: vp.y, width: max(220, bounds.width - vp.x - 12),
                                              height: fontSize * 1.6))
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.stringValue = editing?.text ?? ""
        field.placeholderString = "Type, then Return"
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(cgColor: (editing?.color ?? color).cgColor)?.withAlphaComponent(0.9)
        field.textColor = .white
        field.focusRingType = .none
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = p
        editingID = editing?.id
        needsDisplay = true
    }

    func commitText() {
        guard let field = textField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        textField = nil
        if let id = editingID, var m = doc.marks.first(where: { $0.id == id }) {
            if text.isEmpty { doc.remove(id: id) } else { m.text = text; doc.update(m); selectedID = id }
        } else if !text.isEmpty {
            let m = Mark(tool: .text, color: color, size: size, start: textOrigin, end: textOrigin, text: text)
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
        if var m = selectedMark { m.size = s; doc.update(m); changed() }
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
