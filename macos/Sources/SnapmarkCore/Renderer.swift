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

    /// The lines a label draws: its own line breaks, plus wrapping when it has a width.
    static func lines(_ m: Mark, size: CGFloat) -> [CTLine] {
        let text = m.text.isEmpty ? " " : m.text
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: ink(on: m.color).cgColor]
        let str = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let setter = CTFramesetterCreateWithAttributedString(str)
        let width = m.textWidth.map { max($0, size) } ?? 100_000
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        // A trailing line break starts an empty last line, which the caret is on while typing.
        return text.hasSuffix("\n") ? lines + [line(" ", size: size, color: m.color)] : lines
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

    /// The label wrapping at the width that puts the right edge of its box at `x`.
    public static func resizing(text m: Mark, toRightEdge x: CGFloat, imageWidth: Int) -> Mark {
        let size = fontSize(of: m, imageWidth: imageWidth)
        var out = m
        out.textWidth = max(size * 1.5, x - m.start.x - size * padX * 2)
        return out
    }

    /// A mark's grab points. A label has two: its bottom-right corner scales it, its right edge sets
    /// where it wraps. Shapes and arrows use `Mark.handles`.
    public static func handles(of m: Mark, imageWidth: Int) -> [CGPoint] {
        guard m.tool == .text else { return m.handles }
        let r = textOrStepRect(m, imageWidth: imageWidth)
        return [CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY)]
    }

    /// The mark with handle `i` (an index into `handles(of:)`) dragged to `p`.
    public static func moving(_ m: Mark, handle i: Int, to p: CGPoint, imageWidth: Int) -> Mark {
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
        let lines = lines(m, size: size)
        let widest = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth($0)) }.max() ?? 0
        let w = (m.textWidth.map { max($0, size) } ?? widest) + size * padX * 2
        let h = size * (lineHeight * CGFloat(max(lines.count, 1)) + padY)
        return CGRect(x: m.start.x, y: m.start.y - h, width: w, height: h)
    }

    /// The image, plus the area a canvas grows into: each side continues the screenshot's outermost
    /// row or column of pixels (so a title bar or a page background carries on), and the corners take
    /// the border color.
    public static func drawBackground(_ doc: Document, canvas: CGRect, in ctx: CGContext) {
        let img = doc.image, b = doc.bounds
        if canvas != b {
            ctx.setFillColor(doc.borderColor.cgColor)
            ctx.fill(canvas)
            ctx.saveGState()
            ctx.interpolationQuality = .none
            let w = img.width, h = img.height
            // Strips use CGImage's top-left origin; destinations use the context's bottom-left one.
            let sides: [(CGRect, CGRect)] = [
                (CGRect(x: 0, y: 0, width: 1, height: h), CGRect(x: canvas.minX, y: 0, width: -canvas.minX, height: b.height)),
                (CGRect(x: w - 1, y: 0, width: 1, height: h), CGRect(x: b.maxX, y: 0, width: canvas.maxX - b.maxX, height: b.height)),
                (CGRect(x: 0, y: h - 1, width: w, height: 1), CGRect(x: 0, y: canvas.minY, width: b.width, height: -canvas.minY)),
                (CGRect(x: 0, y: 0, width: w, height: 1), CGRect(x: 0, y: b.maxY, width: b.width, height: canvas.maxY - b.maxY)),
            ]
            for (strip, dest) in sides where dest.width > 0 && dest.height > 0 {
                if let s = img.cropping(to: strip) { ctx.draw(s, in: dest) }
            }
            ctx.restoreGState()
        }
        ctx.draw(img, in: b)
    }

    /// Everything a mark paints, including stroke width, arrowhead and shadow.
    public static func extent(of m: Mark, imageWidth: Int) -> CGRect {
        let w = m.size.width(forImageWidth: imageWidth)
        switch m.tool {
        case .text, .step: return textOrStepRect(m, imageWidth: imageWidth).insetBy(dx: -w, dy: -w)
        case .arrow: return m.rect.insetBy(dx: -max(w * 4.5, 10), dy: -max(w * 4.5, 10))
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
            drawArrow(from: m.start, to: m.end, color: m.color, width: w, in: ctx)
        case .text:
            let r = textOrStepRect(m, imageWidth: imageWidth)
            let size = fontSize(of: m, imageWidth: imageWidth)
            ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.06), blur: size * 0.3,
                          color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(m.color.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: size * 0.35, cornerHeight: size * 0.35, transform: nil))
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0)
            for (i, l) in lines(m, size: size).enumerated() {
                var descent: CGFloat = 0
                _ = CTLineGetTypographicBounds(l, nil, &descent, nil)
                ctx.textPosition = CGPoint(x: r.minX + size * padX, y: r.maxY - size * lineHeight * CGFloat(i + 1) + descent)
                CTLineDraw(l, ctx)
            }
        case .step:
            let r = textOrStepRect(m, imageWidth: imageWidth)
            let size = fontSize(imageWidth: imageWidth, size: m.size)
            ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.05), blur: size * 0.25,
                          color: CGColor(gray: 0, alpha: 0.35))
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

    static func drawArrow(from a: CGPoint, to b: CGPoint, color: RGBA, width w: CGFloat, in ctx: CGContext) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let head = max(w * 4.5, 10)
        let base = CGPoint(x: b.x - cos(angle) * head * 0.85, y: b.y - sin(angle) * head * 0.85)
        let wing = head * 0.55
        let left = CGPoint(x: b.x - cos(angle) * head + cos(angle + .pi / 2) * wing,
                           y: b.y - sin(angle) * head + sin(angle + .pi / 2) * wing)
        let right = CGPoint(x: b.x - cos(angle) * head - cos(angle + .pi / 2) * wing,
                            y: b.y - sin(angle) * head - sin(angle + .pi / 2) * wing)
        ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.3), blur: w * 1.2, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.move(to: a)
        ctx.addLine(to: base)
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
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return Document(image: image, dpi: CGFloat(dpi))
    }
}
