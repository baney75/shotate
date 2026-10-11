import CoreGraphics

/// Draws the editor's marks through bitmaps. Shadows make marks slow to draw (an arrow's blur costs
/// milliseconds), so the marks that aren't changing are drawn once into a cached layer, and during a
/// drag only the marks that move are drawn again. Those go through a bitmap of their own, so every
/// mark is drawn the same way and nothing shifts when a drag starts or ends. Drawing marks over the
/// image in order equals painting the layers over it, because each mark is composited source-over.
public final class MarkLayer {
    private struct Key: Equatable {
        var marks: [Mark]
        var imageWidth: Int
        var transform: CGAffineTransform
        var width: Int, height: Int
        var space: CGColorSpace
    }
    private var key: Key?
    private var cached: CGImage?
    /// How many times the layer was drawn rather than reused; tests use it to keep the reuse working.
    public private(set) var renders = 0

    public init() {}

    /// Draws `marks` into `ctx` (in image pixels) from the cached layer, redrawing the layer only when
    /// a mark, the view or its color space changed. `transform` maps image pixels to the view's
    /// `width` × `height` backing pixels; `space` is the window's color space.
    public func draw(_ marks: [Mark], imageWidth: Int, transform: CGAffineTransform, width: Int, height: Int,
                     space: CGColorSpace, in ctx: CGContext) {
        guard !marks.isEmpty, width > 0, height > 0 else { return }
        let k = Key(marks: marks, imageWidth: imageWidth, transform: transform, width: width, height: height, space: space)
        if k != key || cached == nil {
            cached = Self.render(marks, imageWidth: imageWidth, transform: transform,
                                 area: CGRect(x: 0, y: 0, width: width, height: height), space: space)
            key = k
            renders += 1
        }
        if let cached { Self.paint(cached, area: CGRect(x: 0, y: 0, width: width, height: height), transform: transform, in: ctx) }
    }

    /// Draws `marks` into `ctx` through a fresh bitmap covering only the area they paint: for marks
    /// that change every frame.
    public static func drawUncached(_ marks: [Mark], imageWidth: Int, transform: CGAffineTransform, width: Int,
                                    height: Int, space: CGColorSpace, in ctx: CGContext) {
        guard !marks.isEmpty else { return }
        let reach = marks.map { reachRect($0, imageWidth: imageWidth) }.reduce(CGRect.null) { $0.union($1) }
        let area = reach.applying(transform).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !area.isEmpty, let img = render(marks, imageWidth: imageWidth, transform: transform, area: area, space: space) else { return }
        paint(img, area: area, transform: transform, in: ctx)
    }

    /// Everything a mark paints, shadow included, with room to spare.
    static func reachRect(_ m: Mark, imageWidth: Int) -> CGRect {
        let e = Renderer.extent(of: m, imageWidth: imageWidth)
        let w = m.size.width(forImageWidth: imageWidth)
        let pad: CGFloat = switch m.tool {
        case .text, .step: Renderer.fontSize(of: m, imageWidth: imageWidth) * 0.8
        case .arrow: w * 3
        default: w
        }
        return e.insetBy(dx: -pad - 2, dy: -pad - 2)
    }

    /// The part `area` (in bitmap pixels) of the full bitmap the marks would be drawn into.
    static func render(_ marks: [Mark], imageWidth: Int, transform: CGAffineTransform, area: CGRect,
                       space: CGColorSpace) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(area.width), height: Int(area.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: -area.minX, y: -area.minY)
        ctx.concatenate(transform)
        for m in marks { Renderer.draw(m, in: ctx, imageWidth: imageWidth) }
        return ctx.makeImage()
    }

    /// Puts a rendered area back where it belongs, one bitmap pixel per backing pixel.
    static func paint(_ img: CGImage, area: CGRect, transform: CGAffineTransform, in ctx: CGContext) {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.draw(img, in: area.applying(transform.inverted()))
        ctx.restoreGState()
    }
}
