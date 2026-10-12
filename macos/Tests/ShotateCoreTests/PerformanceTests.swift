import CoreGraphics
import ImageIO
import XCTest
@testable import ShotateCore

/// The caches that keep capture and editing fast. Each test fails if its cache stops being used or
/// changes what gets drawn.
final class PerformanceTests: XCTestCase {
    func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // A gradient, so a misplaced layer shows up as wrong pixels.
        for x in stride(from: 0, to: w, by: 8) {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(x) / CGFloat(w), green: 0.5, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 8, height: h))
        }
        return ctx.makeImage()!
    }

    func bytes(_ draw: (CGContext) -> Void, _ w: Int, _ h: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return px
    }

    func testLabelLayoutIsBuiltOncePerText() {
        let m = Mark(tool: .text, color: RGBA.palette[0], start: CGPoint(x: 10, y: 200), end: .zero, text: "Once \(UUID())")
        let before = Renderer.layoutsBuilt
        let first = Renderer.textOrStepRect(m, imageWidth: 800)
        for _ in 0..<20 { XCTAssertEqual(Renderer.textOrStepRect(m, imageWidth: 800), first) }
        let doc = Document(image: image(800, 300))
        doc.add(m)
        XCTAssertNil(doc.hitTest(.zero, tolerance: 4))
        XCTAssertEqual(doc.hitTest(CGPoint(x: first.midX, y: first.midY), tolerance: 4)?.id, m.id)
        XCTAssertEqual(Renderer.layoutsBuilt - before, 1)
        // New text, a wrap width or an ink change each lay the label out again.
        var longer = m; longer.text += " more"
        XCTAssertGreaterThan(Renderer.textOrStepRect(longer, imageWidth: 800).width, first.width)
        var wrapped = m; wrapped.textWidth = 40
        XCTAssertGreaterThan(Renderer.textOrStepRect(wrapped, imageWidth: 800).height, first.height)
        var light = m; light.color = RGBA(1, 1, 1)
        _ = Renderer.textOrStepRect(light, imageWidth: 800)
        XCTAssertEqual(Renderer.layoutsBuilt - before, 4)
    }

    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    func marked() -> Document {
        let doc = Document(image: image(600, 400))
        doc.add(Mark(tool: .arrow, color: RGBA.palette[0], start: CGPoint(x: 40, y: 40), end: CGPoint(x: 400, y: 300)))
        doc.add(Mark(tool: .text, color: RGBA.palette[2], start: CGPoint(x: 60, y: 360), end: .zero, text: "Label"))
        doc.add(Mark(tool: .redact, color: RGBA.palette[0], start: CGPoint(x: 300, y: 50), end: CGPoint(x: 500, y: 150)))
        doc.add(Mark(tool: .step, color: RGBA.palette[1], size: .thick, start: CGPoint(x: 520, y: 330), end: .zero))
        doc.add(Mark(tool: .text, color: RGBA.palette[4], start: CGPoint(x: 150, y: 250), end: .zero, text: "Big",
                     fontSize: 90))
        doc.add(Mark(tool: .box, color: RGBA.palette[3], start: CGPoint(x: 100, y: 100), end: CGPoint(x: 250, y: 220)))
        return doc
    }
    /// The editor's transform: image pixels into the view's backing pixels, scaled and offset by a margin.
    let t = CGAffineTransform(translationX: 20, y: 10).scaledBy(x: 0.9, y: 0.9)
    let (w, h) = (580, 380)

    func render(_ doc: Document, _ drawMarks: (CGContext) -> Void) -> [UInt8] {
        bytes({ ctx in
            ctx.concatenate(t)
            Renderer.drawBackground(doc, canvas: doc.bounds, in: ctx)
            drawMarks(ctx)
        }, w, h)
    }

    func worst(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0 }

    func testMarkLayerDrawsTheSameAsDrawingEachMark() {
        let doc = marked()
        let direct = render(doc) { ctx in for m in doc.marks { Renderer.draw(m, in: ctx, imageWidth: 600) } }
        // During a drag: the first marks from the cached layer, the rest through their own bitmap.
        for split in [0, 2, 4, doc.marks.count] {
            let layered = render(doc) { ctx in
                MarkLayer().draw(Array(doc.marks.prefix(split)), imageWidth: 600, transform: t, width: w, height: h,
                                 space: space, in: ctx)
                MarkLayer.drawUncached(Array(doc.marks.dropFirst(split)), imageWidth: 600, transform: t, width: w,
                                       height: h, space: space, in: ctx)
            }
            XCTAssertLessThanOrEqual(worst(direct, layered), 2, "split at \(split) differs from drawing each mark")
        }
    }

    func testMovingMarksAreNotClippedByTheirBitmap() {
        // Each mark alone through its cropped bitmap matches the full-size layer: no shadow is cut off.
        let doc = marked()
        // Stacked combining marks draw far above the label's box.
        doc.add(Mark(tool: .text, color: RGBA.palette[5], start: CGPoint(x: 300, y: 220), end: .zero,
                     text: "Z" + String(repeating: "\u{346}", count: 20) + "a", fontSize: 60))
        for m in doc.marks {
            let full = render(doc) { MarkLayer().draw([m], imageWidth: 600, transform: t, width: w, height: h, space: space, in: $0) }
            let cropped = render(doc) { MarkLayer.drawUncached([m], imageWidth: 600, transform: t, width: w, height: h, space: space, in: $0) }
            XCTAssertLessThanOrEqual(worst(full, cropped), 1, "\(m.tool) is clipped")
        }
    }

    func testMarkLayerIsReusedUntilAMarkChanges() {
        let layer = MarkLayer()
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var marks = [Mark(tool: .arrow, color: RGBA.palette[0], start: .zero, end: CGPoint(x: 90, y: 90))]
        func draw(_ tf: CGAffineTransform = .identity) {
            layer.draw(marks, imageWidth: 100, transform: tf, width: 100, height: 100, space: space, in: ctx)
        }
        draw(); draw(); draw()
        XCTAssertEqual(layer.renders, 1)
        marks[0].color = RGBA.palette[1]
        draw()
        draw(CGAffineTransform(scaleX: 0.5, y: 0.5))
        XCTAssertEqual(layer.renders, 3)
    }

    func testLoadDocumentFromDataKeepsSizeAndDPI() throws {
        let png = try XCTUnwrap(Renderer.pngData(image(64, 32), dpi: 144))
        let doc = try XCTUnwrap(Renderer.loadDocument(data: png))
        XCTAssertEqual(doc.image.width, 64)
        XCTAssertEqual(doc.image.height, 32)
        XCTAssertEqual(doc.dpi, 144)
        XCTAssertNil(Renderer.loadDocument(data: Data("not an image".utf8)))
    }
}

final class CaptureGeometryTests: XCTestCase {
    /// An area chosen on screen maps to the pixels showing it: AppKit counts up from the bottom,
    /// image pixels down from the top, and a second screen sits at its own origin.
    func testAreaMapsToImagePixels() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(CaptureGeometry.pixelRect(of: CGRect(x: 200, y: 150, width: 300, height: 200), screenFrame: main, scale: 2),
                       CGRect(x: 400, y: 1264, width: 600, height: 400))
        let side = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        XCTAssertEqual(CaptureGeometry.pixelRect(of: CGRect(x: -1900, y: 1080, width: 100, height: 100), screenFrame: side, scale: 1),
                       CGRect(x: 20, y: 0, width: 100, height: 100))
    }
}
