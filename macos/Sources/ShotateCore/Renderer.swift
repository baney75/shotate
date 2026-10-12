import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws marks with CoreGraphics. Used both for the live editor and the exported PNG,
/// so what you see is exactly what gets copied.
public enum Renderer {
    public static func fontSize(imageWidth w: Int, size: StrokeSize) -> CGFloat {
        min(72, max(22, CGFloat(w) / 38)) * [0.8, 1.0, 1.35][size.rawValue - 1]
    }

    /// The font size a text or step mark draws with: its own when sized by hand, else its preset.
    public static func fontSize(of m: Mark, imageWidth w: Int) -> CGFloat {
        m.fontSize ?? fontSize(imageWidth: w, size: m.size)
    }

    /// A label's line height and the padding around its text, as multiples of the font size.
    public static let lineHeight: CGFloat = 1.25
    static let padX: CGFloat = 0.45, padY: CGFloat = 0.27

    /// A label laid out: its lines and the width of the widest one.
    final class TextLayout {
        let lines: [CTLine]
        let widest: CGFloat
        init(lines: [CTLine], widest: CGFloat) { self.lines = lines; self.widest = widest }
    }

    /// Layouts by text, font size, wrap width and ink. Hit testing, the canvas size and every redraw
    /// measure each label, and Core Text layout is the slow part, so each layout is made once.
    private static let layouts: NSCache<NSString, TextLayout> = {
        let c = NSCache<NSString, TextLayout>()
        c.countLimit = 500
        return c
    }()
    /// How many layouts were built rather than reused; tests use it to keep the cache working.
    static var layoutsBuilt: Int { layoutLock.withLock { built } }
    private static var built = 0
    private static let layoutLock = NSLock()

    /// The lines a label draws: its own line breaks, plus wrapping when it has a width.
    static func layout(_ m: Mark, size: CGFloat) -> TextLayout {
        let ink = ink(on: m.color)
        let width = m.textWidth.map { max($0, size) } ?? 100_000
        let key = "\(size) \(width) \(ink.r) \(ink.g) \(ink.b)\n\(m.text)" as NSString
        if let hit = layouts.object(forKey: key) { return hit }
        let text = m.text.isEmpty ? " " : m.text
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: ink.cgColor]
        let str = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let setter = CTFramesetterCreateWithAttributedString(str)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil), nil)
        var lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        // A trailing line break starts an empty last line, which the caret is on while typing.
        if text.hasSuffix("\n") { lines.append(line(" ", size: size, color: m.color)) }
        let widest = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth($0)) }.max() ?? 0
        let out = TextLayout(lines: lines, widest: widest)
        layouts.setObject(out, forKey: key)
        layoutLock.withLock { built += 1 }
        return out
    }

    /// The label scaled so the bottom-right corner of its box follows `p`; the top-left corner stays put.
    public static func resizing(text m: Mark, toCorner p: CGPoint, imageWidth: Int) -> Mark {
        let r = textOrStepRect(m, imageWidth: imageWidth)
        let scale = max((p.x - r.minX) / max(r.width, 1), (r.maxY - p.y) / max(r.height, 1))
        let old = fontSize(of: m, imageWidth: imageWidth)
        var out = m
        out.fontSize = min(max(old * scale, 8), 600)
        out.textWidth = m.textWidth.map { $0 * out.fontSize! / old }
        return out
    }

    /// `new` with its wrap width scaled by how much its font grew from `old`, so it keeps its lines.
    public static func rewrapped(_ new: Mark, from old: Mark, imageWidth: Int) -> Mark {
        var out = new
        out.textWidth = new.textWidth.map { $0 * fontSize(of: new, imageWidth: imageWidth) / fontSize(of: old, imageWidth: imageWidth) }
        return out
    }

    /// The label wrapping at the width that puts the right edge of its box at `x`.
    public static func resizing(text m: Mark, toRightEdge x: CGFloat, imageWidth: Int) -> Mark {
        let size = fontSize(of: m, imageWidth: imageWidth)
        var out = m
        out.textWidth = max(size * 1.5, x - m.start.x - size * padX * 2)
        return out
    }

    /// `label` moved so the point at `anchor` (fractions of its box) sits on `p`. A label grows right
    /// and down from its top-left corner as it gets text; pinning keeps it on its spot instead.
    public static func pinned(_ label: Mark, at p: CGPoint, anchor a: CGPoint, imageWidth: Int) -> Mark {
        let r = textOrStepRect(label, imageWidth: imageWidth)
        var out = label
        out.start = CGPoint(x: p.x - a.x * r.width, y: p.y + r.height - a.y * r.height)
        out.end = out.start
        return out
    }

    /// The label an arrow carries in its middle, as a text mark, or nil when it has none.
    public static func arrowLabel(of m: Mark, imageWidth: Int) -> Mark? {
        guard m.tool == .arrow, !m.text.isEmpty else { return nil }
        let label = Mark(tool: .text, color: m.color, size: m.size, start: .zero, end: .zero, text: m.text, id: m.id)
        return pinned(label, at: m.midpoint, anchor: CGPoint(x: 0.5, y: 0.5), imageWidth: imageWidth)
    }

    /// How far a labeled arrow's middle handle sits from its middle, along its normal: just outside the
    /// label, on the side the arrow bends to, so the handle doesn't cover the text. 0 without a label.
    static func labelClearance(of m: Mark, imageWidth: Int) -> CGFloat {
        guard let label = arrowLabel(of: m, imageWidth: imageWidth) else { return 0 }
        let r = textOrStepRect(label, imageWidth: imageWidth), n = m.normal
        let side: CGFloat = m.bend < 0 ? -1 : 1
        return side * (abs(n.x) * r.width / 2 + abs(n.y) * r.height / 2 + fontSize(of: label, imageWidth: imageWidth) * 0.3)
    }

    /// The bend that puts a labeled arrow's middle handle (which sits `k` past the middle, on the side
    /// the arrow bends to) under a pointer `proj` off the chord. Inside the label's reach it is straight.
    static func bend(forHandleAt proj: CGFloat, clearance k: CGFloat) -> CGFloat {
        proj >= k ? proj - k : proj <= -k ? proj + k : 0
    }

    /// A mark's grab points. A label has two: its bottom-right corner scales it, its right edge sets
    /// where it wraps. An arrow's middle handle clears its label. Shapes use `Mark.handles`.
    public static func handles(of m: Mark, imageWidth: Int) -> [CGPoint] {
        if m.tool == .arrow {
            let k = labelClearance(of: m, imageWidth: imageWidth), mid = m.midpoint, n = m.normal
            return [m.start, m.end, CGPoint(x: mid.x + n.x * k, y: mid.y + n.y * k)]
        }
        guard m.tool == .text else { return m.handles }
        let r = textOrStepRect(m, imageWidth: imageWidth)
        return [CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY)]
    }

    /// The mark with handle `i` (an index into `handles(of:)`) dragged to `p`.
    public static func moving(_ m: Mark, handle i: Int, to p: CGPoint, imageWidth: Int) -> Mark {
        if m.tool == .arrow, i == 2 {
            var out = m
            out.bend = bend(forHandleAt: m.bend(through: p), clearance: abs(labelClearance(of: m, imageWidth: imageWidth)))
            return out
        }
        guard m.tool == .text else { return m.moving(handle: i, to: p) }
        return i == 0 ? resizing(text: m, toCorner: p, imageWidth: imageWidth)
            : resizing(text: m, toRightEdge: p.x, imageWidth: imageWidth)
    }

    /// Black text on light colors, white on dark ones.
    public static func ink(on c: RGBA) -> RGBA {
        (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.62 ? RGBA(0.08, 0.08, 0.09) : RGBA(1, 1, 1)
    }

    static func line(_ text: String, size: CGFloat, color: RGBA) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color.cgColor]
        let str = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        return CTLineCreateWithAttributedString(str)
    }

    /// The label box for a text mark, or the disc for a step, in image coordinates.
    public static func textOrStepRect(_ m: Mark, imageWidth: Int) -> CGRect {
        let size = fontSize(of: m, imageWidth: imageWidth)
        if m.tool == .step {
            let r = size * 0.95
            return CGRect(x: m.start.x - r, y: m.start.y - r, width: r * 2, height: r * 2)
        }
        let layout = layout(m, size: size)
        let w = (m.textWidth.map { max($0, size) } ?? layout.widest) + size * padX * 2
        let h = size * (lineHeight * CGFloat(max(layout.lines.count, 1)) + padY)
        return CGRect(x: m.start.x, y: m.start.y - h, width: w, height: h)
    }

    /// The image, plus the area a canvas grows into: each side continues the screenshot's outermost
    /// row or column of pixels with thin detail taken out (see `Document.edgeStrips`), so a title bar
    /// or a page background carries on without streaks, and the corners take the border color.
    public static func drawBackground(_ doc: Document, canvas: CGRect, in ctx: CGContext) {
        let img = doc.image, b = doc.bounds
        if canvas != b {
            ctx.setFillColor(doc.borderColor.cgColor)
            ctx.fill(canvas)
            ctx.saveGState()
            ctx.interpolationQuality = .none
            // Left, right, bottom, top, as `Document.edgeStrips` orders them.
            let sides = [CGRect(x: canvas.minX, y: 0, width: -canvas.minX, height: b.height),
                         CGRect(x: b.maxX, y: 0, width: canvas.maxX - b.maxX, height: b.height),
                         CGRect(x: 0, y: canvas.minY, width: b.width, height: -canvas.minY),
                         CGRect(x: 0, y: b.maxY, width: b.width, height: canvas.maxY - b.maxY)]
            for (strip, dest) in zip(doc.edgeStrips, sides) where dest.width > 0 && dest.height > 0 {
                if let strip { ctx.draw(strip, in: dest) }
            }
            ctx.restoreGState()
        }
        ctx.draw(img, in: b)
    }

    /// The glyphs a label paints, which combining marks or tall scripts can push past its box.
    public static func inkRect(of m: Mark, imageWidth: Int) -> CGRect {
        let r = textOrStepRect(m, imageWidth: imageWidth)
        guard m.tool == .text else { return r }
        let size = fontSize(of: m, imageWidth: imageWidth)
        var ink = r
        for (i, l) in layout(m, size: size).lines.enumerated() {
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(l, nil, &descent, nil)
            let b = CTLineGetImageBounds(l, nil)
            guard !b.isNull, b.width.isFinite, b.height.isFinite else { continue }
            ink = ink.union(b.offsetBy(dx: r.minX + size * padX, dy: r.maxY - size * lineHeight * CGFloat(i + 1) + descent))
        }
        return ink
    }

    /// Everything a mark paints, including stroke width, arrowhead and shadow.
    public static func extent(of m: Mark, imageWidth: Int) -> CGRect {
        let w = m.size.width(forImageWidth: imageWidth)
        switch m.tool {
        case .text, .step: return textOrStepRect(m, imageWidth: imageWidth).insetBy(dx: -w, dy: -w)
        case .arrow:
            let r = m.curveBounds.insetBy(dx: -max(w * 4.5, 10), dy: -max(w * 4.5, 10))
            return arrowLabel(of: m, imageWidth: imageWidth).map { r.union(extent(of: $0, imageWidth: imageWidth)) } ?? r
        default: return m.rect.insetBy(dx: -w, dy: -w)
        }
    }

    public static func draw(_ m: Mark, in ctx: CGContext, imageWidth: Int, selected: Bool = false) {
        let w = m.size.width(forImageWidth: imageWidth)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch m.tool {
        case .box:
            ctx.setStrokeColor(m.color.cgColor)
            ctx.setLineWidth(w)
            ctx.setLineJoin(.round)
            ctx.addPath(CGPath(roundedRect: m.rect, cornerWidth: w * 1.2, cornerHeight: w * 1.2, transform: nil))
            ctx.strokePath()
        case .ellipse:
            ctx.setStrokeColor(m.color.cgColor)
            ctx.setLineWidth(w)
            ctx.strokeEllipse(in: m.rect)
        case .highlight:
            ctx.setFillColor(m.color.with(alpha: 0.38).cgColor)
            ctx.fill(m.rect)
        case .redact:
            // A solid bar: pixelation and blur can sometimes be reversed; this cannot.
            ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
            ctx.addPath(CGPath(roundedRect: m.rect, cornerWidth: w, cornerHeight: w, transform: nil))
            ctx.fillPath()
        case .arrow:
            drawArrow(m, width: w, in: ctx)
            if let label = arrowLabel(of: m, imageWidth: imageWidth) {
                ctx.restoreGState()
                ctx.saveGState()
                draw(label, in: ctx, imageWidth: imageWidth)
            }
        case .text:
            let r = textOrStepRect(m, imageWidth: imageWidth)
            let size = fontSize(of: m, imageWidth: imageWidth)
            shadow(in: ctx, drop: size * 0.06, blur: size * 0.3)
            ctx.setFillColor(m.color.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: size * 0.35, cornerHeight: size * 0.35, transform: nil))
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0)
            for (i, l) in layout(m, size: size).lines.enumerated() {
                var descent: CGFloat = 0
                _ = CTLineGetTypographicBounds(l, nil, &descent, nil)
                ctx.textPosition = CGPoint(x: r.minX + size * padX, y: r.maxY - size * lineHeight * CGFloat(i + 1) + descent)
                CTLineDraw(l, ctx)
            }
        case .step:
            let r = textOrStepRect(m, imageWidth: imageWidth)
            let size = fontSize(imageWidth: imageWidth, size: m.size)
            shadow(in: ctx, drop: size * 0.05, blur: size * 0.25)
            ctx.setFillColor(m.color.cgColor)
            ctx.fillEllipse(in: r)
            ctx.setShadow(offset: .zero, blur: 0)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(max(1.5, w * 0.45))
            ctx.strokeEllipse(in: r.insetBy(dx: w * 0.25, dy: w * 0.25))
            let l = line("\(m.number)", size: size * 1.05, color: ink(on: m.color))
            let b = CTLineGetBoundsWithOptions(l, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: r.midX - b.width / 2 - b.minX, y: r.midY - b.height / 2 - b.minY)
            CTLineDraw(l, ctx)
        case .crop, .select:
            break
        }
        if selected {
            let r = (m.tool == .text || m.tool == .step) ? textOrStepRect(m, imageWidth: imageWidth) : m.rect
            ctx.setStrokeColor(CGColor(srgbRed: 0.30, green: 0.56, blue: 0.98, alpha: 1))
            ctx.setLineWidth(max(1, w * 0.4))
            ctx.setLineDash(phase: 0, lengths: [w * 1.5, w])
            ctx.stroke(r.insetBy(dx: -w * 1.5, dy: -w * 1.5))
        }
    }

    /// A drop shadow measured in image pixels. Core Graphics sizes shadows in the context's base space
    /// and ignores the CTM, so the CTM's scale is applied here. That holds for bitmap contexts, whose
    /// base space is pixels: marks are only drawn into those (the export, and the editor's `MarkLayer`),
    /// never straight into a view, whose base space is points.
    static func shadow(in ctx: CGContext, drop: CGFloat, blur: CGFloat) {
        let s = hypot(ctx.ctm.a, ctx.ctm.b)
        ctx.setShadow(offset: CGSize(width: 0, height: -drop * s), blur: blur * s, color: CGColor(gray: 0, alpha: 0.35))
    }

    static func drawArrow(_ m: Mark, width w: CGFloat, in ctx: CGContext) {
        let a = m.start, b = m.end, color = m.color
        let head = max(w * 4.5, 10)
        // A curve stops where the head begins: split it at the point about the head's length from the
        // tip, and aim the head from there so line and head meet on its axis.
        var split = (t: CGFloat(1), control: m.control)
        if m.bend != 0 {
            let t = m.parameter(atDistance: head * 0.85, fromEnd: true)
            let c = m.control
            split = (t, CGPoint(x: a.x + (c.x - a.x) * t, y: a.y + (c.y - a.y) * t))
        }
        let cut = m.bend != 0 ? m.point(at: split.t) : a
        let angle = atan2(b.y - cut.y, b.x - cut.x)
        let base = CGPoint(x: b.x - cos(angle) * head * 0.85, y: b.y - sin(angle) * head * 0.85)
        let wing = head * 0.55
        let left = CGPoint(x: b.x - cos(angle) * head + cos(angle + .pi / 2) * wing,
                           y: b.y - sin(angle) * head + sin(angle + .pi / 2) * wing)
        let right = CGPoint(x: b.x - cos(angle) * head - cos(angle + .pi / 2) * wing,
                            y: b.y - sin(angle) * head - sin(angle + .pi / 2) * wing)
        shadow(in: ctx, drop: w * 0.3, blur: w * 1.2)
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.move(to: a)
        if m.bend != 0 { ctx.addQuadCurve(to: cut, control: split.control) } else { ctx.addLine(to: base) }
        ctx.strokePath()
        ctx.move(to: b)
        ctx.addLine(to: left)
        ctx.addLine(to: right)
        ctx.closePath()
        ctx.fillPath()
    }

    /// The finished image: base then marks in the order they were added, cropped if a crop is set.
    /// Marks past the edge grow the canvas, filled with the screenshot's border color.
    public static func flatten(_ doc: Document, selected: UUID? = nil) -> CGImage? {
        let img = doc.image
        let canvas = doc.canvas
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: -canvas.minX, y: -canvas.minY)
        ctx.interpolationQuality = .high
        drawBackground(doc, canvas: canvas, in: ctx)
        // Stacking order: a redaction hides everything drawn before it.
        for m in doc.marks { draw(m, in: ctx, imageWidth: img.width, selected: m.id == selected) }
        guard let full = ctx.makeImage() else { return nil }
        guard let crop = doc.effectiveCrop else { return full }
        // CGImage cropping uses a top-left origin, relative to the canvas.
        let flipped = CGRect(x: crop.minX - canvas.minX, y: canvas.maxY - crop.maxY, width: crop.width, height: crop.height)
        return full.cropping(to: flipped)
    }

    public static func pngData(_ image: CGImage, dpi: CGFloat = 72) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    public static func loadImage(at url: URL) -> CGImage? { loadDocument(at: url)?.image }

    /// The image and its DPI (screencapture tags Retina captures 144).
    /// Reads the bytes into memory and decodes now: a URL-backed CGImage decodes lazily from the
    /// file, so deleting the capture's temp file (or editing the original) broke every later save.
    public static func loadDocument(at url: URL) -> Document? {
        (try? Data(contentsOf: url)).flatMap(loadDocument(data:))
    }

    /// The image in `data` (any format ImageIO reads) and its DPI, decoded now.
    public static func loadDocument(data: Data) -> Document? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return Document(image: image, dpi: CGFloat(dpi))
    }
}
