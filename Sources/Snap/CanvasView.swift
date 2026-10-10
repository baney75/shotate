import AppKit
import SnapCore

/// Shows the screenshot scaled to fit and turns mouse input into marks. All geometry is kept in
/// image pixels (origin bottom-left); the view converts at the edges.
final class CanvasView: NSView, NSTextFieldDelegate {
    let doc: Document
    var tool: Tool = .arrow { didSet { commitText(); if tool != .select { selectedID = nil }; window?.invalidateCursorRects(for: self) } }
    var color: RGBA = RGBA.palette[0]
    var size: StrokeSize = .medium
    var onChange: (() -> Void)?

    private(set) var selectedID: UUID? { didSet { needsDisplay = true } }
    private var draft: Mark? { didSet { needsDisplay = true } }
    private var dragOrigin: CGPoint?
    private var dragOffset = CGVector.zero
    private var cropDraft: CGRect? { didSet { needsDisplay = true } }
    private var textField: NSTextField?
    private var editingID: UUID?
    private var textOrigin = CGPoint.zero

    init(document: Document) {
        doc = document
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

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
        if let id = selectedID, dragOffset != .zero, let i = marks.firstIndex(where: { $0.id == id }) {
            marks[i] = marks[i].offset(by: dragOffset)
        }
        if let d = draft { marks.append(d) }
        for m in marks where m.tool == .redact { Renderer.draw(m, in: ctx, imageWidth: doc.image.width) }
        for m in marks where m.tool != .redact && m.id != editingID {
            Renderer.draw(m, in: ctx, imageWidth: doc.image.width, selected: m.id == selectedID)
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

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = imagePoint(e)
        let tolerance = 8 * pixelsPerPoint
        if textField != nil { commitText() }
        switch tool {
        case .select:
            if let hit = doc.hitTest(p, tolerance: tolerance) {
                selectedID = hit.id
                dragOrigin = p
                if e.clickCount == 2, hit.tool == .text { beginText(at: hit.start, editing: hit) }
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
            changed()
        case .crop:
            dragOrigin = p
            cropDraft = CGRect(origin: p, size: .zero)
        default:
            draft = Mark(tool: tool, color: color, size: size, start: p, end: p)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        var p = imagePoint(e)
        if tool == .select, let o = dragOrigin, selectedID != nil {
            dragOffset = CGVector(dx: p.x - o.x, dy: p.y - o.y)
            needsDisplay = true
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
        defer { dragOrigin = nil }
        if tool == .select, let id = selectedID, dragOffset != .zero,
           let m = doc.marks.first(where: { $0.id == id }) {
            doc.update(m.offset(by: dragOffset))
            dragOffset = .zero
            changed()
            return
        }
        if tool == .crop {
            doc.setCrop(cropDraft)
            cropDraft = nil
            changed()
            return
        }
        guard let d = draft else { return }
        draft = nil
        let minSize = 3 * pixelsPerPoint
        if hypot(d.end.x - d.start.x, d.end.y - d.start.y) > minSize {
            doc.add(d)
            changed()
        }
    }

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
            if text.isEmpty { doc.remove(id: id) } else { m.text = text; doc.update(m) }
        } else if !text.isEmpty {
            doc.add(Mark(tool: .text, color: color, size: size, start: textOrigin, end: textOrigin, text: text))
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

    func deleteSelection() {
        guard let id = selectedID else { return }
        doc.remove(id: id)
        selectedID = nil
        changed()
    }

    func applyColorToSelection(_ c: RGBA) {
        color = c
        if let id = selectedID, var m = doc.marks.first(where: { $0.id == id }) { m.color = c; doc.update(m); changed() }
    }

    func applySizeToSelection(_ s: StrokeSize) {
        size = s
        if let id = selectedID, var m = doc.marks.first(where: { $0.id == id }) { m.size = s; doc.update(m); changed() }
    }

    func undo() { commitText(); doc.undo(); selectedID = nil; changed() }
    func redo() { doc.redo(); selectedID = nil; changed() }

    private func changed() {
        needsDisplay = true
        onChange?()
    }
}
