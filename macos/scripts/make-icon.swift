// Draws Yapshot's app icon into an .iconset, then iconutil makes the .icns: a red marker loop drawn as a
// speech bubble, the way you circle what matters and say why, inside crop corners on a deep ink tile.
//   swift scripts/make-icon.swift build/Shotate.iconset
import AppKit

/// Shotate's colors. Mark red is also the editor's default ink.
enum Brand {
    static let ink = CGColor(srgbRed: 0.075, green: 0.082, blue: 0.137, alpha: 1)      // #131523
    static let inkTop = CGColor(srgbRed: 0.161, green: 0.176, blue: 0.290, alpha: 1)   // #292D4A
    static let red = CGColor(srgbRed: 0.91, green: 0.26, blue: 0.29, alpha: 1)        // #E8434A
}

/// A hand-drawn speech bubble: a marker loop of a little more than one turn whose ends overlap,
/// with a tail pulled out toward the lower left. It circles what matters and says it out loud.
func bubble(center c: CGPoint, rx: CGFloat, ry: CGFloat, tilt: CGFloat, tail: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let start = CGFloat.pi * 0.62, sweep = CGFloat.pi * 2.16, steps = 220
    let tailAt = CGFloat.pi * 1.22   // lower left, measured like `a` below
    let half = CGFloat.pi * 0.11     // how wide the tail's base is
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let a = start - sweep * t
        let grow = 0.90 + 0.18 * t
        // Distance from the tail's angle, wrapped to -pi...pi.
        var d = (a - tailAt).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        // A sharp spike that eases back into the loop, only on the first turn.
        let spike = (abs(d) < half && t < 0.9) ? tail * pow(1 - abs(d) / half, 2.2) : 0
        let x = cos(a) * (rx * grow + spike), y = sin(a) * (ry * grow + spike)
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
    // The bubble: the annotation and the voice.
    let center = CGPoint(x: rect.midX + w * 0.01, y: rect.midY + w * 0.03)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.012), blur: w * 0.035, color: CGColor(gray: 0, alpha: 0.45))
    ctx.setStrokeColor(Brand.red)
    ctx.setLineWidth(max(2, w * 0.07))
    ctx.addPath(bubble(center: center, rx: w * 0.265, ry: w * 0.19, tilt: 0.12, tail: w * 0.15))
    ctx.strokePath()
    ctx.restoreGState()
    // A few voice bars inside, only where there are pixels to show them.
    if s >= 60 {
        let bars: [CGFloat] = [0.30, 0.62, 1.0, 0.52, 0.78, 0.36]
        let bw = w * 0.032, gap = w * 0.030, tall = w * 0.16
        var x = center.x - (CGFloat(bars.count) * bw + CGFloat(bars.count - 1) * gap) / 2
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
        for h in bars {
            let bh = max(bw, tall * h)
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: center.y - bh / 2, width: bw, height: bh),
                               cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil))
            x += bw + gap
        }
        ctx.fillPath()
    }
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
