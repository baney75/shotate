import AppKit
import ShotateCore

/// Shows the screenshot scaled to fit and turns mouse input into marks. All geometry is kept in
/// image pixels (origin bottom-left); the view converts at the edges.
///
/// Interaction follows the conventions of canvas editors such as tldraw and Figma: a new mark is
/// selected as soon as it is drawn, so Delete removes it and color and size apply to it; a selected
/// mark shows handles to resize it; Esc deselects before it closes; right-click offers the actions.
/// Text is placed by clicking (or dragging to set the width it wraps at), moved by dragging it with
/// the Text or Select tool, scaled from its corner handle and rewrapped from its side handle.
/// Dragged marks snap to the image and to each other (hold ⌘ to place freely), and an arrow end
/// dropped on a mark stays attached to it. An arrow's middle handle bends it; double-clicking an
/// arrow's end adds a label it points at, and double-clicking along it labels its middle. The pen
/// draws freehand (with a tablet's pressure); holding still at the end of a stroke turns it into the
/// line, box or ellipse it was meant to be.
final class CanvasView: NSView, NSTextViewDelegate {
    let doc: Document
    var tool: Tool = .arrow {
        // A mark mid-drag belongs to the tool that started it; switching drops it.
        didSet { commitText(); resetTextPress(); endPenHold(); draft = nil; selectedID = nil; window?.invalidateCursorRects(for: self) }
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
    private var textField: LabelEditor?
    private var editingID: UUID?
    private var textOrigin = CGPoint.zero
    private var textFontSize: CGFloat?
    /// A box being dragged with the Text tool to place and size a new label.
    private var textBox: CGRect? { didSet { needsDisplay = true } }
    /// A label pressed with the Text tool: released in place it opens for editing, dragged it moves.
    private var pressedLabel: Mark?
    private var textWidth: CGFloat?
    /// Keeps the label being typed on a spot: the point, and where on the label's box it sits.
    private var textPin: (point: CGPoint, anchor: CGPoint)?
    /// The arrow end a new label is for, attached to it when the label is committed.
    private var callout: (arrow: UUID, end: Int)?
    /// Snap guides to draw while dragging.
    private var guides: [Snap.Guide] = [] { didSet { needsDisplay = true } }
    /// The mark an arrow end being dragged would attach to, outlined as a drop target.
    private var bindTarget: UUID? { didSet { if oldValue != bindTarget { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    /// Fires when the pen holds still mid-stroke, to turn the stroke into a shape.
    private var penHold: Timer?
    /// Where the pen last moved enough to restart the hold.
    private var penHoldAnchor = CGPoint.zero
    /// What a held stroke became: a line whose end still follows the pen, or a shape that stays put.
    private enum PenSnap { case none, line, shape }
    private var penSnap = PenSnap.none
    private let markLayer = MarkLayer()

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
    /// How far a drag may widen the frozen view.
    private var dragLimit: CGRect?
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
        let r = (m.tool == .text || m.tool == .step) ? Renderer.textOrStepRect(m, imageWidth: doc.image.width)
            : m.tool == .arrow ? m.curveBounds : m.rect
        let pad = 4 * pixelsPerPoint + m.size.width(forImageWidth: doc.image.width) / 2
        return r.insetBy(dx: -pad, dy: -pad)
    }

    private func handles(of m: Mark) -> [CGPoint] { Renderer.handles(of: m, imageWidth: doc.image.width) }

    private func moving(_ m: Mark, handle i: Int, to p: CGPoint) -> Mark {
        Renderer.moving(m, handle: i, to: p, imageWidth: doc.image.width)
    }

    /// The box a mark lines up by when snapping.
    private func snapRect(_ m: Mark) -> CGRect { doc.bindableRect(m) ?? m.rect }

    /// `p` lined up with the image and the other marks, unless ⌘ is held. Updates the guides.
    private func snapped(_ p: CGPoint, _ e: NSEvent, excluding ids: Set<UUID>) -> CGPoint {
        guard !e.modifierFlags.contains(.command) else { guides = []; return p }
        let (q, g) = Snap.point(p, to: doc.snapTargets(excluding: ids), threshold: 6 * pixelsPerPoint)
        guides = g
        return q
    }

    /// Where an arrow end at `p` attaches: the mark under it, outlined while dragging.
    private func bind(_ p: CGPoint, arrow: UUID) -> Binding? {
        let b = doc.binding(at: p, tolerance: 2 * pixelsPerPoint, excluding: arrow)
        bindTarget = b?.id
        return b
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
        // Arrows attached to a mark being dragged follow it live.
        if live != nil { marks = doc.resolvingBindings(marks) }
        // An arrow whose label is open shows the editor in place of its label.
        if let id = editingID, let i = marks.firstIndex(where: { $0.id == id }), marks[i].tool == .arrow { marks[i].text = "" }
        // The canvas as it will export: grown past the edge where marks reach, in the border color.
        let canvas = doc.canvas(including: marks)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2 * pixelsPerPoint), blur: 10 * pixelsPerPoint,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(doc.borderColor.cgColor)
        ctx.fill(canvas)
        ctx.restoreGState()
        Renderer.drawBackground(doc, canvas: canvas, in: ctx)
        // Marks up to the first one a drag or draft changes come from the cached layer; the rest are
        // drawn fresh. Without a drag that is every mark, so hovering and selecting redraw nothing.
        // A live resize changes the size every frame, so the layer would never be reused.
        let committed = doc.marks
        let stable = inLiveResize ? 0 : marks.indices.first { $0 >= committed.count || marks[$0] != committed[$0] } ?? marks.count
        let backing = convertToBacking(bounds).size
        let (bw, bh) = (Int(backing.width.rounded()), Int(backing.height.rounded()))
        let toBacking = CGAffineTransform(scaleX: backing.width / max(bounds.width, 1), y: backing.height / max(bounds.height, 1))
            .translatedBy(x: o.x, y: o.y).scaledBy(x: 1 / pixelsPerPoint, y: 1 / pixelsPerPoint)
        let space = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let hidden = marks.first { $0.id == editingID }?.tool == .arrow ? nil : editingID
        markLayer.draw(marks[..<stable].filter { $0.id != hidden }, imageWidth: doc.image.width, transform: toBacking,
                       width: bw, height: bh, space: space, in: ctx)
        MarkLayer.drawUncached(marks[stable...].filter { $0.id != hidden }, imageWidth: doc.image.width,
                               transform: toBacking, width: bw, height: bh, space: space, in: ctx)
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
        let guideColor = CGColor(srgbRed: 0.98, green: 0.3, blue: 0.55, alpha: 1)
        ctx.setStrokeColor(guideColor)
        ctx.setLineWidth(pixelsPerPoint)
        for g in guides {
            ctx.move(to: g.vertical ? CGPoint(x: g.at, y: g.from) : CGPoint(x: g.from, y: g.at))
            ctx.addLine(to: g.vertical ? CGPoint(x: g.at, y: g.to) : CGPoint(x: g.to, y: g.at))
        }
        ctx.strokePath()
        if let id = bindTarget, let m = marks.first(where: { $0.id == id }) {
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(2.5 * pixelsPerPoint)
            ctx.stroke(outline(m))
        }
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
        dragLimit = layoutRect.insetBy(dx: -0.5 * CGFloat(max(doc.image.width, doc.image.height)),
                                       dy: -0.5 * CGFloat(max(doc.image.width, doc.image.height)))
        let p = imagePoint(e)
        let tolerance = 8 * pixelsPerPoint
        if e.clickCount == 2, tool != .step, tool != .crop, tool != .pen, labelArrow(at: p) { return }
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
        case .pen:
            selectedID = nil
            draft = Mark.stroke([p], pressures: e.subtype == .tabletPoint ? [CGFloat(e.pressure)] : [], color: color, size: size)
            penSnap = .none
            restartPenHold(at: p)
        default:
            selectedID = nil
            var d = Mark(tool: tool, color: color, size: size, start: p, end: p)
            if tool == .arrow { d.startBinding = doc.binding(at: p, tolerance: 2 * pixelsPerPoint, excluding: nil) }
            else { d.start = snapped(p, e, excluding: []); d.end = d.start; guides = [] }
            draft = d
        }
    }

    override func mouseDragged(with e: NSEvent) {
        defer { followDrag(e) }
        var p = imagePoint(e)
        if let i = dragHandle, let m = live {
            let base = selectedMark ?? m
            if base.tool == .arrow, i == 2 {
                // The middle handle bends the arrow. Close to straight snaps straight, so a curve can be undone.
                var bent = moving(base, handle: i, to: p)
                if abs(bent.bend) < 6 * pixelsPerPoint { bent.bend = 0 }
                guides = []
                live = bent
                return
            }
            if e.modifierFlags.contains(.shift) {
                // Same as drawing: 45° steps for an arrow, a square for a shape, from the fixed end.
                if base.tool != .text {
                    let fixed = base.tool == .arrow ? (i == 0 ? base.end : base.start) : base.moving(handle: i, to: p).start
                    p = base.tool == .arrow ? Geometry.snap45(from: fixed, to: p) : Geometry.square(from: fixed, to: p)
                }
            }
            let shift = e.modifierFlags.contains(.shift)
            if shift { guides = []; bindTarget = nil }
            if base.tool == .arrow {
                // An arrow end attaches to the mark it's dropped on; elsewhere it snaps. Shift does neither.
                var m = moving(base, handle: i, to: p)
                let b = shift ? nil : bind(p, arrow: base.id)
                if b == nil, !shift { m = moving(base, handle: i, to: snapped(p, e, excluding: [base.id])) }
                else { guides = [] }
                if i == 0 { m.startBinding = b } else { m.endBinding = b }
                live = m
            } else if base.tool == .text {
                live = moving(base, handle: i, to: p)
            } else {
                live = moving(base, handle: i, to: shift ? p : snapped(p, e, excluding: [base.id]))
            }
            return
        }
        if textBox != nil, let o = dragOrigin {
            p = snapped(p, e, excluding: [])
            textBox = CGRect(x: min(o.x, p.x), y: min(o.y, p.y), width: abs(p.x - o.x), height: abs(p.y - o.y))
            return
        }
        // A mark only starts to move past a few points, so a slightly shaky click doesn't nudge it,
        // snap it or let go of an arrow's attachments (and a pressed label still opens for editing).
        if tool == .select || tool == .text, let o = dragOrigin, live == nil, hypot(p.x - o.x, p.y - o.y) < 3 * pixelsPerPoint { return }
        if tool == .select || tool == .text, let o = dragOrigin, let m = selectedMark {
            var moved = m.offset(by: CGVector(dx: p.x - o.x, dy: p.y - o.y))
            if e.modifierFlags.contains(.command) { guides = [] } else {
                let (d, g) = Snap.move(snapRect(moved), to: doc.snapTargets(excluding: [m.id]), threshold: 6 * pixelsPerPoint)
                moved = moved.offset(by: d)
                guides = g
            }
            live = moved
            return
        }
        if tool == .crop, let o = dragOrigin {
            cropDraft = CGRect(x: min(o.x, p.x), y: min(o.y, p.y), width: abs(p.x - o.x), height: abs(p.y - o.y))
            return
        }
        guard var d = draft else { return }
        if tool == .pen {
            drawPen(to: p, e)
            return
        }
        if d.tool == .arrow {
            d.endBinding = e.modifierFlags.contains(.shift) ? nil : bind(p, arrow: d.id)
            if d.endBinding == nil { bindTarget = nil }
            if d.endBinding != nil { guides = [] }
        }
        if e.modifierFlags.contains(.shift) {
            p = d.tool == .arrow ? Geometry.snap45(from: d.start, to: p) : Geometry.square(from: d.start, to: p)
            guides = []
        } else if d.endBinding == nil {
            p = snapped(p, e, excluding: [])
        }
        d.end = p
        draft = d
    }

    /// Widens the frozen view when a drag reaches past it, so a mark drawn off the edge stays in sight.
    /// Only while the pointer is inside the view: outside, every widening would map it further out and
    /// widen again. It also stops at half the image's size past where the drag began.
    private func followDrag(_ e: NSEvent) {
        guard let f = frozenLayout, let limit = dragLimit, bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        var marks = doc.marks
        if let l = live, let i = marks.firstIndex(where: { $0.id == l.id }) { marks[i] = l }
        if let d = draft { marks.append(d) }
        let c = doc.canvas(including: doc.resolvingBindings(marks))
        guard !f.contains(c) else { return }
        let margin = 0.07 * CGFloat(max(doc.image.width, doc.image.height))
        frozenLayout = f.union(c.insetBy(dx: -margin, dy: -margin)).intersection(limit)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer {
            dragOrigin = nil
            dragHandle = nil
            pressedLabel = nil
            textBox = nil
            guides = []
            bindTarget = nil
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
        if let label = pressedLabel, let current = doc.marks.first(where: { $0.id == label.id }) {
            beginText(at: current.start, editing: current)
            return
        }
        if let box = textBox {
            // A drag sets the width the label wraps at, from its top-left corner; a click starts a
            // label that grows with its text, centered on the click.
            let probe = Mark(tool: .text, color: color, size: size, start: .zero, end: .zero)
            let font = Renderer.fontSize(of: probe, imageWidth: doc.image.width)
            if box.width > 12 * pixelsPerPoint {
                beginText(at: CGPoint(x: box.minX, y: box.maxY), editing: nil,
                          textWidth: max(font * 1.5, box.width - font * 0.9))
            } else {
                let h = Renderer.textOrStepRect(probe, imageWidth: doc.image.width).height
                beginText(at: CGPoint(x: box.minX, y: box.midY + h / 2), editing: nil)
            }
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
        if tool == .pen {
            // A stroke stays unselected, so writing doesn't flash an outline after every line.
            endPenHold()
            doc.add(d)
            changed()
        } else if hypot(d.end.x - d.start.x, d.end.y - d.start.y) > 3 * pixelsPerPoint {
            doc.add(d)
            selectedID = d.id
            changed()
        }
    }

    // MARK: Pen

    /// Adds `p` to the stroke being drawn, or moves the end of a stroke that became a line.
    private func drawPen(to p: CGPoint, _ e: NSEvent) {
        guard var d = draft else { return }
        switch penSnap {
        case .shape: return
        case .line:
            d.points = [d.points[0], p]
            d.end = p
        case .none:
            guard let last = d.points.last, hypot(p.x - last.x, p.y - last.y) >= pixelsPerPoint else { return }
            d.points.append(p)
            d.end = p
            if d.pressures.count == d.points.count - 1 { d.pressures.append(CGFloat(e.pressure)) }
            // Small shakes don't count as moving, so a hand holding still on a tablet still holds.
            if hypot(p.x - penHoldAnchor.x, p.y - penHoldAnchor.y) > 3 * pixelsPerPoint { restartPenHold(at: p) }
        }
        draft = d
    }

    private func restartPenHold(at p: CGPoint) {
        penHoldAnchor = p
        penHold?.invalidate()
        penHold = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.penHeld() }
    }

    private func endPenHold() {
        penHold?.invalidate()
        penHold = nil
        penSnap = .none
    }

    /// The pen held still: the stroke becomes the shape it looks like, if any.
    private func penHeld() {
        guard let d = draft, d.tool == .pen, penSnap == .none, let shape = Ink.shape(of: d.points) else { return }
        switch shape {
        case let .line(a, b):
            draft = Mark.stroke([a, b], color: d.color, size: d.size)
            penSnap = .line
        case let .box(r), let .ellipse(r):
            let kind: Tool = if case .box = shape { .box } else { .ellipse }
            draft = Mark(tool: kind, color: d.color, size: d.size, start: r.origin, end: CGPoint(x: r.maxX, y: r.maxY))
            penSnap = .shape
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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

    /// Double-clicking an arrow labels it. Near a free end it opens a new label for that end, which the
    /// arrow then points at; near an end that already points at a label, that label. Anywhere else
    /// along it (or near an end attached to a shape), the label in its middle. Returns false when the
    /// topmost mark under `p` is not an arrow, so a label or shape there keeps its own double-click.
    private func labelArrow(at p: CGPoint) -> Bool {
        guard let arrow = doc.hitTest(p, tolerance: 8 * pixelsPerPoint), arrow.tool == .arrow else { return false }
        if let end = arrow.end(near: p, tolerance: 10 * pixelsPerPoint) {
            let bound = (end == 0 ? arrow.startBinding : arrow.endBinding).flatMap { b in doc.marks.first { $0.id == b.id } }
            if let label = bound, label.tool == .text {
                selectedID = label.id
                beginText(at: label.start, editing: label)
                return true
            }
            if bound == nil {
                selectedID = nil
                callout = (arrow.id, end)
                textPin = (end == 0 ? arrow.start : arrow.end, arrow.calloutAnchor(end: end))
                beginText(at: .zero, editing: nil, color: arrow.color)
                return true
            }
        }
        selectedID = arrow.id
        beginText(at: .zero, editing: arrow)
        return true
    }

    /// Opens the label editor with its top-left corner at `p`.
    private func beginText(at p: CGPoint, editing: Mark?, textWidth wrap: CGFloat? = nil, color labelColor: RGBA? = nil) {
        let markColor = editing?.color ?? labelColor ?? color
        labelColor.map { textColor = $0 }
        textOrigin = p
        textFontSize = editing?.fontSize
        textWidth = editing?.textWidth ?? wrap
        editingID = editing?.id
        let fontSize = Renderer.fontSize(of: editingMark(text: ""), imageWidth: doc.image.width) / pixelsPerPoint
        let ink = NSColor(cgColor: Renderer.ink(on: markColor).cgColor) ?? .white
        // The editor lays text out like the drawn label: the same font, padding, line height and wrap width.
        let editor = LabelEditor(frame: .zero)
        labelUndo = UndoManager()
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = fontSize * Renderer.lineHeight
        style.maximumLineHeight = fontSize * Renderer.lineHeight
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: ink,
                                                    .paragraphStyle: style]
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.insertionPointColor = ink
        editor.textContainerInset = NSSize(width: fontSize * 0.45, height: 0)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.defaultParagraphStyle = style
        editor.typingAttributes = attrs
        editor.textStorage?.setAttributedString(NSAttributedString(string: editing?.text ?? "", attributes: attrs))
        editor.placeholder = NSAttributedString(string: "Type, then Return", attributes: attrs.merging(
            [.foregroundColor: ink.withAlphaComponent(0.65)]) { $1 })
        editor.wantsLayer = true
        editor.layer?.backgroundColor = markColor.cgColor.copy(alpha: 0.92)
        editor.layer?.cornerRadius = fontSize * 0.35
        editor.delegate = self
        addSubview(editor)
        textField = editor
        fitTextField()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        needsDisplay = true
    }

    /// The color a new label takes when it is not the current color: a callout's arrow's color.
    private var textColor: RGBA?

    /// The label being edited, as it would be with `text`. An arrow's label sits on its middle.
    private func editingMark(text: String) -> Mark {
        let base = editingID.flatMap { id in doc.marks.first { $0.id == id } }
        let m = Mark(tool: .text, color: base?.color ?? textColor ?? color, size: base?.size ?? size, start: textOrigin,
                     end: textOrigin, text: text, fontSize: textFontSize, textWidth: textWidth)
        if let base, base.tool == .arrow {
            return Renderer.pinned(m, at: base.midpoint, anchor: CGPoint(x: 0.5, y: 0.5), imageWidth: doc.image.width)
        }
        guard let pin = textPin else { return m }
        return Renderer.pinned(m, at: pin.point, anchor: pin.anchor, imageWidth: doc.image.width)
    }

    /// Sizes the editor to the box the label will draw as, so typing looks like the result.
    private func fitTextField() {
        guard let editor = textField else { return }
        let text = editor.string.isEmpty ? editor.placeholder.string : editor.string
        let r = Renderer.textOrStepRect(editingMark(text: text), imageWidth: doc.image.width)
        let o = viewPoint(r.origin)
        let inset = editor.textContainerInset.width
        // A wrapping label wraps at its width; one that grows gets room for the caret past the last glyph.
        let frame = CGRect(x: o.x, y: o.y, width: r.width / pixelsPerPoint + (textWidth == nil ? 2 : 0),
                           height: r.height / pixelsPerPoint)
        editor.textContainer?.containerSize = NSSize(width: textWidth == nil ? 100_000 : frame.width - inset * 2,
                                                     height: 100_000)
        editor.frame = frame
    }

    func textDidChange(_ notification: Notification) { fitTextField() }

    /// Each label editor has its own undo history, so ⌘Z never steps into an earlier label's typing.
    private var labelUndo = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { labelUndo }

    func commitText() {
        guard let editor = textField else { return }
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.removeFromSuperview()
        textField = nil
        if let id = editingID {
            // The label may have been undone while it was open; then there is nothing to update.
            if var m = doc.marks.first(where: { $0.id == id }) {
                // Clearing an arrow's label removes the label, not the arrow.
                if m.tool == .arrow { m.text = text; doc.update(m); selectedID = id }
                else if text.isEmpty { doc.remove(id: id) } else { m.text = text; doc.update(m); selectedID = id }
            }
        } else if !text.isEmpty {
            let m = editingMark(text: text)
            if let c = callout, let pin = textPin { doc.addCallout(m, arrow: c.arrow, end: c.end, anchor: pin.anchor) }
            else { doc.add(m) }
            selectedID = m.id
        }
        editingID = nil
        resetLabelPlacement()
        changed()
        window?.makeFirstResponder(self)
    }

    private func resetLabelPlacement() {
        textPin = nil
        callout = nil
        textColor = nil
    }

    private func cancelText() {
        textField?.removeFromSuperview()
        textField = nil
        editingID = nil
        resetLabelPlacement()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    var isEditingText: Bool { textField != nil }

    /// Return commits and Esc cancels; Option-Return starts a new line.
    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commitText(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancelText(); return true }
        if sel == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        }
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

    /// The style ⌥⌘C copied, which ⌥⌘V puts on the selection and on new marks.
    private var copiedStyle: Mark?

    func copyStyle() { if let m = selectedMark { copiedStyle = m } }

    /// Pastes the copied style. Returns it so the toolbar can show it.
    @discardableResult
    func pasteStyle() -> Mark? {
        guard let s = copiedStyle else { return nil }
        color = s.color
        size = s.size
        if let m = selectedMark {
            doc.update(Renderer.rewrapped(m.styled(like: s), from: m, imageWidth: doc.image.width))
            changed()
        }
        return s
    }

    func applyColorToSelection(_ c: RGBA) {
        color = c
        if var m = selectedMark { m.color = c; doc.update(m); changed() }
    }

    func applySizeToSelection(_ s: StrokeSize) {
        size = s
        guard let old = selectedMark else { return }
        var m = old
        m.size = s
        if m.tool == .text {
            // A preset replaces a hand-set size, and the wrap width scales with it.
            m.fontSize = nil
            m = Renderer.rewrapped(m, from: old, imageWidth: doc.image.width)
        }
        doc.update(m)
        changed()
    }

    func undo() { commitText(); resetTextPress(); doc.undo(); selectedID = nil; changed() }
    func redo() { commitText(); resetTextPress(); doc.redo(); selectedID = nil; changed() }

    /// Forgets a Text-tool press in progress, so releasing it later does nothing.
    private func resetTextPress() {
        pressedLabel = nil
        textBox = nil
        live = nil
        dragOrigin = nil
    }

    private func changed() {
        needsDisplay = true
        let n = doc.marks.count
        setAccessibilityLabel(n == 0 ? "Screenshot" : "Screenshot with \(n) annotation\(n == 1 ? "" : "s")")
        onChange?()
    }
}

/// The label editor: a text view that shows a hint while empty.
private final class LabelEditor: NSTextView {
    var placeholder = NSAttributedString()
    override func draw(_ rect: NSRect) {
        super.draw(rect)
        if string.isEmpty { placeholder.draw(at: textContainerOrigin) }
    }
}
