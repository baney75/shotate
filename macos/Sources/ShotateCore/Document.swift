import CoreGraphics
import Foundation

/// An annotation tool. The raw value is the single-key shortcut in the editor.
public enum Tool: String, CaseIterable, Sendable {
    case select = "v"
    case arrow = "a"
    case box = "r"
    case ellipse = "o"
    case highlight = "h"
    case text = "t"
    case redact = "b"
    case step = "n"
    case crop = "c"

    public var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .box: "Box"
        case .ellipse: "Ellipse"
        case .highlight: "Highlight"
        case .text: "Text"
        case .redact: "Redact"
        case .step: "Step"
        case .crop: "Crop"
        }
    }

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .ellipse: "circle"
        case .highlight: "highlighter"
        case .text: "textformat"
        case .redact: "eye.slash"
        case .step: "1.circle"
        case .crop: "crop"
        }
    }

    /// Tools that make a mark by dragging out a shape.
    public var isShape: Bool { [.arrow, .box, .ellipse, .highlight, .redact].contains(self) }
}

/// An RGBA color stored as plain numbers so documents stay Sendable and testable.
public struct RGBA: Equatable, Hashable, Sendable {
    public var r, g, b, a: CGFloat
    public init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public func with(alpha: CGFloat) -> RGBA { RGBA(r, g, b, alpha) }

    /// Readable on light and dark screenshots; the order matches keys 1-6.
    public static let palette: [RGBA] = [
        RGBA(0.91, 0.26, 0.29), // red
        RGBA(0.98, 0.75, 0.18), // amber
        RGBA(0.30, 0.56, 0.98), // blue
        RGBA(0.27, 0.78, 0.47), // green
        RGBA(0.71, 0.45, 0.96), // purple
        RGBA(1, 1, 1),          // white
    ]
}

public enum StrokeSize: Int, CaseIterable, Sendable {
    case thin = 1, medium = 2, thick = 3
    /// Scales with the image so marks look the same on small crops and full Retina screens.
    public func width(forImageWidth w: Int) -> CGFloat {
        // Retina captures are about 2 px per point: 4 px is a 2 pt line on a small capture.
        let base = min(14, max(4, CGFloat(w) / 220))
        return base * [0.6, 1.0, 1.7][rawValue - 1]
    }
}

/// An arrow end attached to another mark: it follows that mark, at the same spot in its box.
public struct Binding: Equatable, Sendable {
    public var id: UUID
    /// Where in the target's box the end sits, as fractions of its width and height.
    public var anchor: CGPoint
    public init(id: UUID, anchor: CGPoint) { self.id = id; self.anchor = anchor }
}

/// One annotation, in image pixel coordinates with the origin at the bottom left.
/// A text label's `start` is the top-left corner of its box, so new lines grow downward.
public struct Mark: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var tool: Tool
    public var color: RGBA
    public var size: StrokeSize
    public var start: CGPoint
    public var end: CGPoint
    public var text: String
    public var number: Int
    /// A label's font size in image pixels when it was sized by hand; nil follows `size`.
    public var fontSize: CGFloat?
    /// A label's wrapping width in image pixels (inside its padding); nil grows with the text.
    public var textWidth: CGFloat?
    /// The marks an arrow's ends are attached to.
    public var startBinding: Binding?
    public var endBinding: Binding?

    public init(tool: Tool, color: RGBA, size: StrokeSize = .medium, start: CGPoint, end: CGPoint,
                text: String = "", number: Int = 0, fontSize: CGFloat? = nil, textWidth: CGFloat? = nil,
                startBinding: Binding? = nil, endBinding: Binding? = nil, id: UUID = UUID()) {
        self.id = id; self.tool = tool; self.color = color; self.size = size
        self.start = start; self.end = end; self.text = text; self.number = number; self.fontSize = fontSize
        self.textWidth = textWidth; self.startBinding = startBinding; self.endBinding = endBinding
    }

    /// The same mark with another's color and size, and a label takes a label's text size. Use
    /// `Renderer.rewrapped` afterwards so a wrapping label's width scales with its new font.
    public func styled(like o: Mark) -> Mark {
        var m = self
        m.color = o.color
        m.size = o.size
        if tool == .text { m.fontSize = o.tool == .text ? o.fontSize : nil }
        return m
    }

    public var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Grab points for resizing: the two ends of an arrow, the four corners of a shape.
    /// Text has its own handles (see `Renderer.handles`); steps use the size control.
    public var handles: [CGPoint] {
        switch tool {
        case .arrow: [start, end]
        case .box, .ellipse, .highlight, .redact:
            [start, end, CGPoint(x: start.x, y: end.y), CGPoint(x: end.x, y: start.y)]
        default: []
        }
    }

    /// The mark with handle `i` (an index into `handles`) moved to `p`. A shape keeps the opposite corner fixed.
    public func moving(handle i: Int, to p: CGPoint) -> Mark {
        var m = self
        let h = handles
        guard h.indices.contains(i) else { return m }
        if tool == .arrow {
            if i == 0 { m.start = p } else { m.end = p }
            return m
        }
        let opposite = CGPoint(x: h[i].x == start.x ? end.x : start.x, y: h[i].y == start.y ? end.y : start.y)
        m.start = opposite
        m.end = p
        return m
    }

    /// A copy with a new identity, nudged so it doesn't hide the original.
    public func duplicate(offset d: CGFloat) -> Mark {
        var m = offset(by: CGVector(dx: d, dy: -d))
        m = Mark(tool: m.tool, color: m.color, size: m.size, start: m.start, end: m.end, text: m.text, number: m.number,
                 fontSize: m.fontSize, textWidth: m.textWidth)
        return m
    }

    /// The mark moved. A moved arrow lets go of what it was attached to.
    public func offset(by d: CGVector) -> Mark {
        var m = self
        m.startBinding = nil
        m.endBinding = nil
        m.start = CGPoint(x: start.x + d.dx, y: start.y + d.dy)
        m.end = CGPoint(x: end.x + d.dx, y: end.y + d.dy)
        return m
    }
}

/// The editable state of one screenshot: base image, marks, crop, and undo history.
public final class Document {
    public let image: CGImage
    /// 144 for Retina captures. Kept on export so the image shows at its real size in other apps.
    public let dpi: CGFloat
    public private(set) var marks: [Mark] = []
    /// The crop as the user drew it. Use `effectiveCrop`, which follows the canvas as marks change.
    public private(set) var crop: CGRect?

    /// The crop trimmed to the current canvas, or nil when none is left. Deleting or moving a mark
    /// can shrink the canvas under an existing crop; this keeps export and the editor in agreement.
    public var effectiveCrop: CGRect? {
        guard let c = crop?.intersection(canvas), c.width >= 4, c.height >= 4 else { return nil }
        return c
    }
    /// Bumps on every change, undo and redo, so callers can tell whether a saved copy is stale.
    public private(set) var revision = 0
    private var undoStack: [([Mark], CGRect?)] = []
    private var redoStack: [([Mark], CGRect?)] = []

    /// The color along the screenshot's edge. Marks drawn past the edge grow the canvas, and the new
    /// area is filled with this color so it looks like the screenshot simply continues.
    public let borderColor: RGBA

    public init(image: CGImage, dpi: CGFloat = 72) {
        self.image = image
        self.dpi = dpi > 0 ? dpi : 72
        borderColor = Document.edgeColor(of: image)
    }

    /// The image plus every mark that reaches past it, with a margin so nothing touches the edge.
    /// Equal to `bounds` while every mark stays inside the image.
    public var canvas: CGRect { canvas(including: marks) }

    public func canvas(including marks: [Mark]) -> CGRect {
        var r = bounds
        for m in marks {
            let e = Renderer.extent(of: m, imageWidth: image.width)
            if !bounds.contains(e) {
                let pad = max(12, m.size.width(forImageWidth: image.width) * 2.5)
                r = r.union(e.insetBy(dx: -pad, dy: -pad))
            }
        }
        return r.integral
    }

    /// The most common color in the outermost row and column of pixels on each side.
    static func edgeColor(of image: CGImage) -> RGBA {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return RGBA(1, 1, 1) }
        // CGImage cropping uses a top-left origin; strips are one pixel thick.
        let strips = [CGRect(x: 0, y: 0, width: w, height: 1), CGRect(x: 0, y: h - 1, width: w, height: 1),
                      CGRect(x: 0, y: 0, width: 1, height: h), CGRect(x: w - 1, y: 0, width: 1, height: h)]
        var buckets: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        for rect in strips {
            guard let strip = image.cropping(to: rect) else { continue }
            let sw = strip.width, sh = strip.height
            var px = [UInt8](repeating: 0, count: sw * sh * 4)
            guard let ctx = CGContext(data: &px, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.draw(strip, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            for i in stride(from: 0, to: px.count, by: 4) {
                let a = Int(px[i + 3])
                // Transparent pixels get a bucket of their own; the rest are un-premultiplied.
                guard a > 0 else {
                    let e = buckets[-1] ?? (0, 0, 0, 0)
                    buckets[-1] = (e.n + 1, 0, 0, 0)
                    continue
                }
                let (r, g, b) = (Int(px[i]) * 255 / a, Int(px[i + 1]) * 255 / a, Int(px[i + 2]) * 255 / a)
                let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                let e = buckets[key] ?? (0, 0, 0, 0)
                buckets[key] = (e.n + 1, e.r + r, e.g + g, e.b + b)
            }
        }
        guard let (key, top) = buckets.max(by: { $0.value.n < $1.value.n }) else { return RGBA(1, 1, 1) }
        if key == -1 { return RGBA(0, 0, 0, 0) }  // mostly transparent edge: grow with transparency
        let n = CGFloat(top.n) * 255
        return RGBA(CGFloat(top.r) / n, CGFloat(top.g) / n, CGFloat(top.b) / n)
    }

    public var bounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }
    public var isEdited: Bool { !marks.isEmpty || crop != nil }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private func checkpoint() {
        revision += 1
        undoStack.append((marks, crop))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public func add(_ mark: Mark) {
        checkpoint()
        var m = mark
        if m.tool == .step { m.number = nextStepNumber }
        marks.append(m)
        marks = resolvingBindings(marks)
    }

    /// Replaces a mark. Arrows attached to it follow, in the same undo step.
    public func update(_ mark: Mark) {
        guard let i = marks.firstIndex(where: { $0.id == mark.id }), marks[i] != mark else { return }
        checkpoint()
        marks[i] = mark
        marks = resolvingBindings(marks)
    }

    /// Removes a mark. Arrows attached to it stay where they are and let go.
    public func remove(id: UUID) {
        guard marks.contains(where: { $0.id == id }) else { return }
        checkpoint()
        marks.removeAll { $0.id == id }
        for i in marks.indices {
            if marks[i].startBinding?.id == id { marks[i].startBinding = nil }
            if marks[i].endBinding?.id == id { marks[i].endBinding = nil }
        }
    }

    // MARK: Arrow bindings

    /// The box an arrow end can attach to, or nil for marks that take no arrows.
    public func bindableRect(_ m: Mark) -> CGRect? {
        switch m.tool {
        case .box, .ellipse, .highlight, .redact: m.rect
        case .text, .step: Renderer.textOrStepRect(m, imageWidth: image.width)
        case .arrow, .crop, .select: nil
        }
    }

    /// The attachment for an arrow end dropped at `p`: the topmost mark under it, other than `excluding`.
    public func binding(at p: CGPoint, tolerance: CGFloat, excluding: UUID?, in marks: [Mark]? = nil) -> Binding? {
        for m in (marks ?? self.marks).reversed() where m.id != excluding {
            // Edges count as inside: an arrow dropped right on a box's outline attaches to it.
            guard let r = bindableRect(m), r.width > 0, r.height > 0 else { continue }
            let t = r.insetBy(dx: -tolerance, dy: -tolerance)
            guard p.x >= t.minX, p.x <= t.maxX, p.y >= t.minY, p.y <= t.maxY else { continue }
            let a = CGPoint(x: min(max((p.x - r.minX) / r.width, 0), 1), y: min(max((p.y - r.minY) / r.height, 0), 1))
            return Binding(id: m.id, anchor: a)
        }
        return nil
    }

    /// The marks with every attached arrow end moved onto its target. Used for the document and for
    /// live previews, so an arrow follows a box while the box is still being dragged.
    public func resolvingBindings(_ marks: [Mark]) -> [Mark] {
        guard marks.contains(where: { $0.startBinding != nil || $0.endBinding != nil }) else { return marks }
        var rects: [UUID: CGRect] = [:]
        for m in marks { rects[m.id] = bindableRect(m) }
        func point(_ b: Binding?) -> CGPoint? {
            guard let b, let r = rects[b.id] else { return nil }
            return CGPoint(x: r.minX + b.anchor.x * r.width, y: r.minY + b.anchor.y * r.height)
        }
        return marks.map { m in
            var m = m
            if let p = point(m.startBinding) { m.start = p }
            if let p = point(m.endBinding) { m.end = p }
            return m
        }
    }

    // MARK: Snapping

    /// The boxes a dragged mark lines up with: the image and every other mark that has a box.
    public func snapTargets(excluding ids: Set<UUID>, in marks: [Mark]? = nil) -> [CGRect] {
        [bounds] + (marks ?? self.marks).filter { !ids.contains($0.id) }.compactMap(bindableRect)
    }

    /// Moves a mark to the top (drawn last) or the bottom of the stack.
    public func reorder(id: UUID, toFront: Bool) {
        guard let i = marks.firstIndex(where: { $0.id == id }), marks.count > 1,
              toFront ? i != marks.count - 1 : i != 0 else { return }
        checkpoint()
        let m = marks.remove(at: i)
        if toFront { marks.append(m) } else { marks.insert(m, at: 0) }
    }

    public func setCrop(_ rect: CGRect?) {
        let clipped = rect.map { $0.integral.intersection(canvas) }
        let value = (clipped?.width ?? 0) >= 4 && (clipped?.height ?? 0) >= 4 ? clipped : nil
        guard value != crop else { return }
        checkpoint()
        crop = value
    }

    public func undo() {
        guard let last = undoStack.popLast() else { return }
        revision += 1
        redoStack.append((marks, crop))
        (marks, crop) = last
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        revision += 1
        undoStack.append((marks, crop))
        (marks, crop) = next
    }

    public var nextStepNumber: Int { (marks.filter { $0.tool == .step }.map(\.number).max() ?? 0) + 1 }

    /// The topmost mark under a point, using a tolerance in image pixels.
    public func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Mark? {
        marks.reversed().first { Geometry.distance(from: p, to: $0, imageWidth: image.width) <= tolerance }
    }
}

public enum Geometry {
    /// Distance from a point to a mark's visible shape (0 when inside filled shapes).
    public static func distance(from p: CGPoint, to m: Mark, imageWidth: Int) -> CGFloat {
        switch m.tool {
        case .arrow:
            return segmentDistance(p, m.start, m.end)
        case .highlight, .redact:
            return m.rect.contains(p) ? 0 : rectDistance(p, m.rect)
        case .ellipse:
            let r = m.rect
            // First-order distance to the outline: |F| / |∇F| for F = (x/a)² + (y/b)² - 1.
            let a = max(r.width / 2, 1), b = max(r.height / 2, 1)
            let x = p.x - r.midX, y = p.y - r.midY
            let f = (x * x) / (a * a) + (y * y) / (b * b) - 1
            let gx = 2 * x / (a * a), gy = 2 * y / (b * b)
            let g = hypot(gx, gy)
            return g > 0 ? abs(f) / g : min(a, b)
        case .box, .crop, .select:
            let r = m.rect
            if r.insetBy(dx: -1, dy: -1).contains(p) {
                let inner = min(abs(p.x - r.minX), abs(p.x - r.maxX), abs(p.y - r.minY), abs(p.y - r.maxY))
                return inner
            }
            return rectDistance(p, r)
        case .text, .step:
            let r = Renderer.textOrStepRect(m, imageWidth: imageWidth)
            return r.contains(p) ? 0 : rectDistance(p, r)
        }
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func rectDistance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// Snap a drag end to 45-degree steps (Shift while drawing an arrow).
    public static func snap45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let angle = (atan2(b.y - a.y, b.x - a.x) / (.pi / 4)).rounded() * (.pi / 4)
        let len = hypot(b.x - a.x, b.y - a.y)
        return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
    }

    /// Make a drag square (Shift while drawing a box or ellipse).
    public static func square(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let side = max(abs(b.x - a.x), abs(b.y - a.y))
        return CGPoint(x: a.x + (b.x >= a.x ? side : -side), y: a.y + (b.y >= a.y ? side : -side))
    }
}

/// Lining marks up with the image and with each other, as in canvas editors: an edge or center that
/// comes within a few points of another edge or center jumps to it, and a guide line shows the match.
public enum Snap {
    public struct Guide: Equatable, Sendable {
        /// A vertical guide at x = `at` (else horizontal at y = `at`), from `from` to `to` along it.
        public var vertical: Bool
        public var at: CGFloat
        public var from: CGFloat
        public var to: CGFloat
    }

    static func stops(_ r: CGRect, vertical: Bool) -> [CGFloat] {
        vertical ? [r.minX, r.midX, r.maxX] : [r.minY, r.midY, r.maxY]
    }

    /// The closest stop in `targets` to any of `own`, as the shift to reach it, within `threshold`.
    static func best(_ own: [CGFloat], _ targets: [CGRect], vertical: Bool, threshold: CGFloat) -> CGFloat? {
        var best: CGFloat?
        for t in targets {
            for a in stops(t, vertical: vertical) {
                for b in own where abs(a - b) <= threshold && abs(a - b) < abs(best ?? .infinity) { best = a - b }
            }
        }
        return best
    }

    /// Guides along every target stop that `r` now meets.
    static func guides(for r: CGRect, _ targets: [CGRect]) -> [Guide] {
        var out: [Guide] = []
        for vertical in [true, false] {
            for t in targets {
                for a in stops(t, vertical: vertical) where stops(r, vertical: vertical).contains(where: { abs($0 - a) < 0.5 }) {
                    let lo = vertical ? min(r.minY, t.minY) : min(r.minX, t.minX)
                    let hi = vertical ? max(r.maxY, t.maxY) : max(r.maxX, t.maxX)
                    let g = Guide(vertical: vertical, at: a, from: lo, to: hi)
                    if !out.contains(g) { out.append(g) }
                }
            }
        }
        return out
    }

    /// How far to shift a box being moved so it lines up, and the guides to show.
    public static func move(_ r: CGRect, to targets: [CGRect], threshold: CGFloat) -> (CGVector, [Guide]) {
        let dx = best(stops(r, vertical: true), targets, vertical: true, threshold: threshold) ?? 0
        let dy = best(stops(r, vertical: false), targets, vertical: false, threshold: threshold) ?? 0
        return (CGVector(dx: dx, dy: dy), guides(for: r.offsetBy(dx: dx, dy: dy), targets))
    }

    /// A point being drawn or dragged (a corner or an arrow end), lined up, and the guides to show.
    public static func point(_ p: CGPoint, to targets: [CGRect], threshold: CGFloat) -> (CGPoint, [Guide]) {
        let dx = best([p.x], targets, vertical: true, threshold: threshold) ?? 0
        let dy = best([p.y], targets, vertical: false, threshold: threshold) ?? 0
        let q = CGPoint(x: p.x + dx, y: p.y + dy)
        return (q, guides(for: CGRect(origin: q, size: .zero), targets))
    }
}
