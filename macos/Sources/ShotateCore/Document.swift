import CoreGraphics
import Foundation

/// An annotation tool. The raw value is the single-key shortcut in the editor.
public enum Tool: String, CaseIterable, Sendable {
    case select = "v"
    case arrow = "a"
    case pen = "p"
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
        case .pen: "Pen"
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
        case .pen: "scribble.variable"
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
    /// How far an arrow's middle sits off the straight line between its ends, in image pixels, to the
    /// left of the direction it points. 0 is straight. Kept relative so a curve keeps its shape when
    /// an attached end moves.
    public var bend: CGFloat
    /// A pen stroke's points, in the order drawn. `start` and `end` are its first and last.
    public var points: [CGPoint]
    /// A pen's pressure at each point (0-1) when drawn with a tablet; empty draws an even line.
    public var pressures: [CGFloat]

    public init(tool: Tool, color: RGBA, size: StrokeSize = .medium, start: CGPoint, end: CGPoint,
                text: String = "", number: Int = 0, fontSize: CGFloat? = nil, textWidth: CGFloat? = nil,
                startBinding: Binding? = nil, endBinding: Binding? = nil, bend: CGFloat = 0,
                points: [CGPoint] = [], pressures: [CGFloat] = [], id: UUID = UUID()) {
        self.id = id; self.tool = tool; self.color = color; self.size = size
        self.start = start; self.end = end; self.text = text; self.number = number; self.fontSize = fontSize
        self.textWidth = textWidth; self.startBinding = startBinding; self.endBinding = endBinding; self.bend = bend
        self.points = points; self.pressures = pressures
    }

    /// A pen stroke through `points`.
    public static func stroke(_ points: [CGPoint], pressures: [CGFloat] = [], color: RGBA, size: StrokeSize) -> Mark {
        Mark(tool: .pen, color: color, size: size, start: points.first ?? .zero, end: points.last ?? .zero,
             points: points, pressures: pressures)
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
        if tool == .pen, let first = points.first {
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Grab points for resizing: the two ends and the middle of an arrow, the four corners of a shape.
    /// Text has its own handles (see `Renderer.handles`); steps use the size control.
    public var handles: [CGPoint] {
        switch tool {
        case .arrow: [start, end, midpoint]
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
            switch i {
            case 0: m.start = p
            case 1: m.end = p
            default: m.bend = bend(through: p)
            }
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
                 fontSize: m.fontSize, textWidth: m.textWidth, bend: m.bend, points: m.points, pressures: m.pressures)
        return m
    }

    /// The mark moved. A moved arrow lets go of what it was attached to.
    public func offset(by d: CGVector) -> Mark {
        var m = self
        m.startBinding = nil
        m.endBinding = nil
        m.start = CGPoint(x: start.x + d.dx, y: start.y + d.dy)
        m.end = CGPoint(x: end.x + d.dx, y: end.y + d.dy)
        m.points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        return m
    }
}

// MARK: Arrow geometry

/// An arrow is a quadratic curve from `start` to `end` whose middle sits `bend` pixels off the chord.
extension Mark {
    /// The unit vector to the left of the chord, or zero for an arrow with no length.
    var normal: CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y, len = hypot(dx, dy)
        return len > 0 ? CGPoint(x: -dy / len, y: dx / len) : .zero
    }

    var chordMidpoint: CGPoint { CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }

    /// The curve's control point. A quadratic passes halfway to its control point at its middle.
    public var control: CGPoint {
        let n = normal, c = chordMidpoint
        return CGPoint(x: c.x + n.x * bend * 2, y: c.y + n.y * bend * 2)
    }

    /// The point halfway along the arrow: where its label sits and where its curve handle is.
    public var midpoint: CGPoint {
        let n = normal, c = chordMidpoint
        return CGPoint(x: c.x + n.x * bend, y: c.y + n.y * bend)
    }

    /// The point at `t` (0 at `start`, 1 at `end`) along the curve.
    public func point(at t: CGFloat) -> CGPoint {
        let c = control, u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * c.x + t * t * end.x,
                       y: u * u * start.y + 2 * u * t * c.y + t * t * end.y)
    }

    /// The curve as a polyline, fine enough for hit testing and bounds.
    public var curvePoints: [CGPoint] {
        bend == 0 ? [start, end] : (0...32).map { point(at: CGFloat($0) / 32) }
    }

    /// The box around the arrow's line, curve included.
    public var curveBounds: CGRect {
        let pts = curvePoints
        return pts.dropFirst().reduce(CGRect(origin: pts[0], size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    /// The bend that puts the arrow's middle at the point on the curve's axis nearest `p`.
    public func bend(through p: CGPoint) -> CGFloat {
        let n = normal, c = chordMidpoint
        return (p.x - c.x) * n.x + (p.y - c.y) * n.y
    }

    /// The `t` at which the curve is `distance` from its start (or, with `fromEnd`, from its tip), in a
    /// straight line. Halving the interval is exact enough at any length; 0 when the arrow is shorter.
    public func parameter(atDistance distance: CGFloat, fromEnd: Bool) -> CGFloat {
        let anchor = fromEnd ? end : start
        func gap(_ t: CGFloat) -> CGFloat { let q = point(at: t); return hypot(q.x - anchor.x, q.y - anchor.y) }
        // `near` is the end at the anchor, `far` the other; the gap shrinks toward `near`.
        var near: CGFloat = fromEnd ? 1 : 0, far: CGFloat = fromEnd ? 0 : 1
        guard gap(far) > distance else { return far }
        for _ in 0..<30 {
            let t = (near + far) / 2
            if gap(t) < distance { near = t } else { far = t }
        }
        return (near + far) / 2
    }

    /// Which end (0 start, 1 end) is within `tolerance` of `p`, the nearer if both, or nil.
    public func end(near p: CGPoint, tolerance: CGFloat) -> Int? {
        let ds = hypot(p.x - start.x, p.y - start.y), de = hypot(p.x - end.x, p.y - end.y)
        guard min(ds, de) <= tolerance else { return nil }
        return de < ds ? 1 : 0
    }

    /// Where a label for end `i` (0 start, 1 end) attaches, as a fraction of its box: the side that
    /// faces back along the arrow, so the label sits beyond the end and the arrow meets its edge.
    public func calloutAnchor(end i: Int) -> CGPoint {
        let tip = i == 0 ? start : end, c = control
        let dx = tip.x - c.x, dy = tip.y - c.y
        return abs(dx) >= abs(dy) ? CGPoint(x: dx >= 0 ? 0 : 1, y: 0.5) : CGPoint(x: 0.5, y: dy >= 0 ? 0 : 1)
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
    /// The outermost column or row of pixels on each side, in the order left, right, bottom, top,
    /// with thin detail (a line, text, an icon) taken out. The canvas grows by stretching these, so a
    /// title bar, a page background or a gradient carries on, and nothing on the edge streaks.
    public let edgeStrips: [CGImage?]
    /// The color for each corner the canvas grows into, from the cleaned strips that meet there, in
    /// the order bottom-left, bottom-right, top-left, top-right.
    public let cornerColors: [RGBA]

    public init(image: CGImage, dpi: CGFloat = 72) {
        self.image = image
        self.dpi = dpi > 0 ? dpi : 72
        (borderColor, edgeStrips, cornerColors) = Document.edges(of: image, pixelsPerPoint: self.dpi / 72)
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

    /// The most common color along the outermost ring of pixels, each side's cleaned strip, and the
    /// corner colors.
    static func edges(of image: CGImage, pixelsPerPoint: CGFloat = 1) -> (border: RGBA, strips: [CGImage?], corners: [RGBA]) {
        let w = image.width, h = image.height
        let white = RGBA(1, 1, 1)
        guard w > 0, h > 0 else { return (white, [nil, nil, nil, nil], [white, white, white, white]) }
        // Left, right, bottom, top. CGImage cropping uses a top-left origin; strips are one pixel thick.
        let rects = [CGRect(x: 0, y: 0, width: 1, height: h), CGRect(x: w - 1, y: 0, width: 1, height: h),
                     CGRect(x: 0, y: h - 1, width: w, height: 1), CGRect(x: 0, y: 0, width: w, height: 1)]
        var all = ColorTally()
        var strips: [CGImage?] = []
        var cleaned: [[UInt8]] = []
        for rect in rects {
            guard var px = pixels(of: image, in: rect) else { strips.append(nil); cleaned.append([]); continue }
            for i in stride(from: 0, to: px.count, by: 4) { all.add((Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3]))) }
            removeThinRuns(&px, pixelsPerPoint: pixelsPerPoint)
            strips.append(makeImage(px, width: Int(rect.width), height: Int(rect.height)))
            cleaned.append(px)
        }
        let border = all.top ?? white
        // A corner continues both strips that meet there: the average of their end pixels. Left and
        // right strips run top to bottom; bottom and top strips run left to right.
        func end(_ side: Int, last: Bool) -> [Int]? {
            let px = cleaned[side]
            guard px.count >= 4 else { return nil }
            let i = last ? px.count - 4 : 0
            return (0..<4).map { Int(px[i + $0]) }
        }
        func corner(_ a: [Int]?, _ b: [Int]?) -> RGBA {
            let both = [a, b].compactMap { $0 }
            guard !both.isEmpty else { return border }
            let sum = (0..<4).map { c in both.reduce(0) { $0 + $1[c] } }
            guard sum[3] > 0 else { return RGBA(0, 0, 0, 0) }
            // Premultiplied bytes: dividing by alpha gives the straight color.
            return RGBA(CGFloat(sum[0]) / CGFloat(sum[3]), CGFloat(sum[1]) / CGFloat(sum[3]), CGFloat(sum[2]) / CGFloat(sum[3]),
                        CGFloat(sum[3]) / CGFloat(255 * both.count))
        }
        let corners = [corner(end(0, last: true), end(2, last: false)), corner(end(1, last: true), end(2, last: true)),
                       corner(end(0, last: false), end(3, last: false)), corner(end(1, last: false), end(3, last: true))]
        return (border, strips, corners)
    }

    /// Cleans a strip so stretching it looks like the screenshot carries on. Splits it into runs of
    /// similar neighboring pixels; a run is a band worth keeping when it covers 2% of the strip (at
    /// least 6 pixels), and a run in the middle of the strip must also be 32 points long: a title bar
    /// or footer sits at the strip's end, while a band in the middle as short as a line of text is
    /// content the edge cut through (a highlight, a bar, a word), and stretched it streaks.
    ///
    /// A band can still carry marks too faint to split it: dim text, or the anti-aliased edge of a
    /// glyph beside it. Inside a band, anything that changes faster than a gradient and is no longer
    /// than half a line of text takes the band's color.
    ///
    /// When bands cover most of the strip, each short run takes the color of the band beside it.
    /// Otherwise the edge is mostly detail, and the bands stay while the rest becomes the color most
    /// of it shares (the page behind a column of text), else the color most of the whole strip shares
    /// (a bold title on a page), or, when no color is clear (a photo, a busy pattern), the strip's own
    /// tones blurred, so the new space continues its light and color softly instead of in one
    /// arbitrary shade.
    static func removeThinRuns(_ px: inout [UInt8], pixelsPerPoint: CGFloat = 1) {
        let n = px.count / 4
        guard n > 1 else { return }
        func step(_ a: Int, _ b: Int) -> Int { (0..<4).map { abs(Int(px[a * 4 + $0]) - Int(px[b * 4 + $0])) }.max()! }
        var runs: [Range<Int>] = []
        var from = 0
        for i in 1...n where i == n || step(i - 1, i) > 12 {
            runs.append(from..<i)
            from = i
        }
        let minRun = min(n, max(6, n / 50))
        let minInner = max(minRun, Int((32 * pixelsPerPoint).rounded()))
        let long = runs.filter { $0.count >= ($0.lowerBound == 0 || $0.upperBound == n ? minRun : minInner) }
        // Inside a band, a stretch up to half a line of text long that leaves the band and comes back
        // (a faint glyph, a hairline) is a mark on it. It takes the band's color, blended from the
        // pixels on either side so a gradient carries on through it.
        let reach = max(1, Int((16 * pixelsPerPoint).rounded()))
        let banded = px
        for r in long {
            var steady: [Range<Int>] = []  // parts that change no faster than a gradient
            var s = r.lowerBound
            for i in (r.lowerBound + 1)...r.upperBound where i == r.upperBound || step(i - 1, i) > 2 {
                if i - s >= reach { steady.append(s..<i) }
                s = i
            }
            var at = r.lowerBound
            for (k, part) in (steady + [r.upperBound..<r.upperBound]).enumerated() {
                defer { at = part.upperBound }
                let gap = at..<part.lowerBound
                guard !gap.isEmpty, gap.count <= reach else { continue }
                let left = k > 0 ? gap.lowerBound - 1 : nil, right = part.isEmpty ? nil : part.lowerBound
                guard left != nil || right != nil else { continue }
                for i in gap {
                    let t = left == nil ? 1 : right == nil ? 0 : Double(i - gap.lowerBound + 1) / Double(gap.count + 1)
                    for c in 0..<4 {
                        let l = Double(banded[(left ?? right!) * 4 + c]), rt = Double(banded[(right ?? left!) * 4 + c])
                        px[i * 4 + c] = UInt8((l + (rt - l) * t).rounded())
                    }
                }
            }
        }
        let longSet = Set(long)
        let detail = runs.filter { !longSet.contains($0) }
        guard !detail.isEmpty else { return }
        let src = px
        let covered = long.reduce(0) { $0 + $1.count }
        if covered * 2 < n {
            // Mostly detail. The color most of the detail shares, in coarse buckets, else the color
            // most of the strip shares.
            func dominant(_ ranges: [Range<Int>]) -> [UInt8]? {
                var counts: [UInt32: (n: Int, sum: [Int])] = [:]
                var total = 0
                for r in ranges {
                    for i in r {
                        let k = (0..<4).reduce(UInt32(0)) { $0 << 5 | UInt32(src[i * 4 + $1] >> 3) }
                        var e = counts[k] ?? (0, [0, 0, 0, 0])
                        e.n += 1
                        for c in 0..<4 { e.sum[c] += Int(src[i * 4 + c]) }
                        counts[k] = e
                        total += 1
                    }
                }
                guard let top = counts.values.max(by: { $0.n < $1.n }), top.n * 2 >= total else { return nil }
                return top.sum.map { UInt8($0 / top.n) }
            }
            if let fill = dominant(detail) ?? dominant([0..<n]) {
                for r in detail { for i in r { for c in 0..<4 { px[i * 4 + c] = fill[c] } } }
            } else {
                // No clear color: a wide box blur of the whole strip, from running sums.
                let radius = max(Int((16 * pixelsPerPoint).rounded()), n / 8)
                var sums = [[Int]](repeating: [0, 0, 0, 0], count: n + 1)
                for i in 0..<n { for c in 0..<4 { sums[i + 1][c] = sums[i][c] + Int(src[i * 4 + c]) } }
                for r in detail {
                    for i in r {
                        let a = max(0, i - radius), b = min(n, i + radius + 1)
                        for c in 0..<4 { px[i * 4 + c] = UInt8((sums[b][c] - sums[a][c]) / (b - a)) }
                    }
                }
            }
            return
        }
        func copy(_ from: Int, to i: Int) { for c in 0..<4 { px[i * 4 + c] = src[from * 4 + c] } }
        for r in detail {
            // The last pixel of the long run before it, else the first of the one after.
            if let before = long.last(where: { $0.upperBound <= r.lowerBound }) {
                for i in r { copy(before.upperBound - 1, to: i) }
            } else if let after = long.first(where: { $0.lowerBound >= r.upperBound }) {
                for i in r { copy(after.lowerBound, to: i) }
            }
        }
    }

    private static func makeImage(_ px: [UInt8], width: Int, height: Int) -> CGImage? {
        var px = px
        return px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    /// Premultiplied RGBA bytes for part of an image (`rect` uses CGImage's top-left origin).
    private static func pixels(of image: CGImage, in rect: CGRect) -> [UInt8]? {
        guard let strip = image.cropping(to: rect) else { return nil }
        let sw = strip.width, sh = strip.height
        var px = [UInt8](repeating: 0, count: sw * sh * 4)
        guard let ctx = CGContext(data: &px, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        return px
    }

    /// Counts colors in coarse buckets, so near-identical shades count as one.
    private struct ColorTally {
        var buckets: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]

        /// Adds a premultiplied pixel. Transparent pixels get a bucket of their own.
        mutating func add(_ c: (Int, Int, Int, Int)) {
            let a = c.3
            guard a > 0 else {
                buckets[-1, default: (0, 0, 0, 0)].n += 1
                return
            }
            let (r, g, b) = (c.0 * 255 / a, c.1 * 255 / a, c.2 * 255 / a)
            let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            let e = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (e.n + 1, e.r + r, e.g + g, e.b + b)
        }

        /// The most common color; clear when most pixels are transparent.
        var top: RGBA? {
            guard let (key, top) = buckets.max(by: { $0.value.n < $1.value.n }) else { return nil }
            if key == -1 { return RGBA(0, 0, 0, 0) }
            let n = CGFloat(top.n) * 255
            return RGBA(CGFloat(top.r) / n, CGFloat(top.g) / n, CGFloat(top.b) / n)
        }
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

    /// Adds `label` and attaches end `i` (0 start, 1 end) of `arrow` to it at `anchor`, in one undo step.
    public func addCallout(_ label: Mark, arrow: UUID, end i: Int, anchor: CGPoint) {
        guard let a = marks.firstIndex(where: { $0.id == arrow }) else { return add(label) }
        checkpoint()
        marks.append(label)
        let b = Binding(id: label.id, anchor: anchor)
        if i == 0 { marks[a].startBinding = b } else { marks[a].endBinding = b }
        marks = resolvingBindings(marks)
    }

    // MARK: Arrow bindings

    /// The box an arrow end can attach to, or nil for marks that take no arrows.
    public func bindableRect(_ m: Mark) -> CGRect? {
        switch m.tool {
        case .box, .ellipse, .highlight, .redact: m.rect
        case .text, .step: Renderer.textOrStepRect(m, imageWidth: image.width)
        case .arrow, .pen, .crop, .select: nil
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
            if let label = Renderer.arrowLabel(of: m, imageWidth: imageWidth),
               Renderer.textOrStepRect(label, imageWidth: imageWidth).contains(p) { return 0 }
            let pts = m.curvePoints
            return zip(pts, pts.dropFirst()).map { segmentDistance(p, $0, $1) }.min() ?? .infinity
        case .pen:
            let pts = m.points
            let half = m.size.width(forImageWidth: imageWidth) / 2
            guard let first = pts.first else { return .infinity }
            let d = pts.count == 1 ? hypot(p.x - first.x, p.y - first.y)
                : zip(pts, pts.dropFirst()).map { segmentDistance(p, $0, $1) }.min()!
            return max(0, d - half)
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

/// Turns a hand-drawn stroke into the clean shape it was meant to be, as when a pen pauses at the
/// end of a stroke: a nearly straight stroke becomes a line, a closed one a box or an ellipse,
/// whichever it lies closer to. Anything else stays as drawn.
public enum Ink {
    public enum Shape: Equatable {
        case line(CGPoint, CGPoint)
        case box(CGRect)
        case ellipse(CGRect)
    }

    public static func shape(of pts: [CGPoint]) -> Shape? {
        guard pts.count >= 3, let first = pts.first, let last = pts.last else { return nil }
        let bounds = pts.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        let diag = hypot(bounds.width, bounds.height)
        guard diag >= 8 else { return nil }
        let length = zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        let chord = hypot(last.x - first.x, last.y - first.y)
        // Straight: it never strays far from the line between its ends. Measured by distance, not by
        // length, because a shaky hand adds length without leaving the line.
        let stray = pts.map { Geometry.segmentDistance($0, first, last) }.max() ?? 0
        if chord > diag * 0.9, stray < chord * 0.06 { return .line(first, last) }
        // Closed: it ends near where it began and went most of the way around its box.
        guard chord < diag * 0.3, length > diag * 1.8, bounds.width > 4, bounds.height > 4 else { return nil }
        let a = bounds.width / 2, b = bounds.height / 2
        var ellipse: CGFloat = 0, box: CGFloat = 0
        for p in pts {
            let x = (p.x - bounds.midX) / a, y = (p.y - bounds.midY) / b
            ellipse += abs(hypot(x, y) - 1)
            box += 1 - max(abs(x), abs(y))
        }
        return box < ellipse ? .box(bounds) : .ellipse(bounds)
    }
}
