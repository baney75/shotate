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

/// One annotation, in image pixel coordinates with the origin at the bottom left.
public struct Mark: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var tool: Tool
    public var color: RGBA
    public var size: StrokeSize
    public var start: CGPoint
    public var end: CGPoint
    public var text: String
    public var number: Int

    public init(tool: Tool, color: RGBA, size: StrokeSize = .medium, start: CGPoint, end: CGPoint,
                text: String = "", number: Int = 0, id: UUID = UUID()) {
        self.id = id; self.tool = tool; self.color = color; self.size = size
        self.start = start; self.end = end; self.text = text; self.number = number
    }

    public var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    public func offset(by d: CGVector) -> Mark {
        var m = self
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
    public private(set) var crop: CGRect?
    /// Bumps on every change, undo and redo, so callers can tell whether a saved copy is stale.
    public private(set) var revision = 0
    private var undoStack: [([Mark], CGRect?)] = []
    private var redoStack: [([Mark], CGRect?)] = []

    public init(image: CGImage, dpi: CGFloat = 72) {
        self.image = image
        self.dpi = dpi > 0 ? dpi : 72
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
    }

    public func update(_ mark: Mark) {
        guard let i = marks.firstIndex(where: { $0.id == mark.id }), marks[i] != mark else { return }
        checkpoint()
        marks[i] = mark
    }

    public func remove(id: UUID) {
        guard marks.contains(where: { $0.id == id }) else { return }
        checkpoint()
        marks.removeAll { $0.id == id }
    }

    public func setCrop(_ rect: CGRect?) {
        let clipped = rect.map { $0.integral.intersection(bounds) }
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

    /// Snapmark a drag end to 45-degree steps (Shift while drawing an arrow).
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
