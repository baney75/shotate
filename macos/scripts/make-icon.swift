// Draws Shotate's app icon into an .iconset, then iconutil makes the .icns: a red marker loop, the way you
// circle the thing that matters on a screenshot, inside crop corners on a deep ink tile.
//   swift scripts/make-icon.swift build/Shotate.iconset
import AppKit

/// Shotate's colors. Mark red is also the editor's default ink.
enum Brand {
    static let ink = CGColor(srgbRed: 0.075, green: 0.082, blue: 0.137, alpha: 1)      // #131523
    static let inkTop = CGColor(srgbRed: 0.161, green: 0.176, blue: 0.290, alpha: 1)   // #292D4A
    static let red = CGColor(srgbRed: 0.91, green: 0.26, blue: 0.29, alpha: 1)        // #E8434A
}

/// A hand-drawn loop: a little more than one turn, growing slightly, so the ends overlap like a marker.
func loop(center c: CGPoint, rx: CGFloat, ry: CGFloat, tilt: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let start = CGFloat.pi * 0.70, sweep = CGFloat.pi * 2.18, steps = 160
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let a = start - sweep * t
        let grow = 0.86 + 0.24 * t
        let x = cos(a) * rx * grow, y = sin(a) * ry * grow
        let pt = CGPoint(x: c.x + x * cos(tilt) - y * sin(tilt), y: c.y + x * sin(tilt) + y * cos(tilt))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    return p
}

func drawIcon(_ ctx: CGContext, size s: CGFloat) {
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let tile = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [Brand.inkTop, Brand.ink] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    let w = rect.width
    // Crop corners: the screenshot.
    let lw = max(1.5, w * 0.055), arm = w * 0.17
    let box = rect.insetBy(dx: w * 0.17, dy: w * 0.17)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.92))
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for (x, y, dx, dy) in [(box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1.0, 1.0),
                           (box.minX, box.maxY, 1.0, -1.0), (box.maxX, box.maxY, -1.0, -1.0)] {
        ctx.move(to: CGPoint(x: x + dx * arm, y: y)); ctx.addLine(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x, y: y + dy * arm))
    }
    ctx.strokePath()
    // The loop: the annotation.
    ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.012), blur: w * 0.035, color: CGColor(gray: 0, alpha: 0.45))
    ctx.setStrokeColor(Brand.red)
    ctx.setLineWidth(max(2, w * 0.085))
    ctx.addPath(loop(center: CGPoint(x: rect.midX, y: rect.midY), rx: w * 0.25, ry: w * 0.17, tilt: 0.28))
    ctx.strokePath()
    ctx.restoreGState()
    // A thin edge so the tile reads on dark Docks.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    ctx.setLineWidth(max(1, s / 256))
    ctx.addPath(tile)
    ctx.strokePath()
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawIcon(ctx, size: CGFloat(px))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
