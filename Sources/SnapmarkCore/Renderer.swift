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

    /// Black text on light colors, white on dark ones.
    static func ink(on c: RGBA) -> RGBA {
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
        let size = fontSize(imageWidth: imageWidth, size: m.size)
        if m.tool == .step {
            let r = size * 0.95
            return CGRect(x: m.start.x - r, y: m.start.y - r, width: r * 2, height: r * 2)
        }
        let l = line(m.text.isEmpty ? " " : m.text, size: size, color: m.color)
        let w = CTLineGetTypographicBounds(l, nil, nil, nil)
        let pad = size * 0.45
        return CGRect(x: m.start.x, y: m.start.y, width: CGFloat(w) + pad * 2, height: size * 1.25 + pad * 0.6)
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
            let size = fontSize(imageWidth: imageWidth, size: m.size)
            ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.06), blur: size * 0.3,
                          color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(m.color.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: size * 0.35, cornerHeight: size * 0.35, transform: nil))
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0)
            let l = line(m.text, size: size, color: ink(on: m.color))
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(l, nil, &descent, nil)
            ctx.textPosition = CGPoint(x: r.minX + size * 0.45, y: r.minY + size * 0.27 + descent)
            CTLineDraw(l, ctx)
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
    public static func flatten(_ doc: Document, selected: UUID? = nil) -> CGImage? {
        let img = doc.image
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: doc.bounds)
        // Stacking order: a redaction hides everything drawn before it.
        for m in doc.marks { draw(m, in: ctx, imageWidth: img.width, selected: m.id == selected) }
        guard let full = ctx.makeImage() else { return nil }
        guard let crop = doc.crop else { return full }
        // CGImage cropping uses a top-left origin.
        let flipped = CGRect(x: crop.minX, y: CGFloat(img.height) - crop.maxY, width: crop.width, height: crop.height)
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
    public static func loadDocument(at url: URL) -> Document? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return Document(image: image, dpi: CGFloat(dpi))
    }
}
