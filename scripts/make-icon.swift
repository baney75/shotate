// Draws Snap's app icon (a viewfinder over a gradient) into an .iconset, then iconutil makes the .icns.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.addPath(squircle)
    ctx.clip()
    let colors = [CGColor(srgbRed: 0.18, green: 0.20, blue: 0.27, alpha: 1), CGColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1)]
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    // Viewfinder corners.
    let w = rect.width, lw = max(1.5, w * 0.06), arm = w * 0.2
    let box = rect.insetBy(dx: w * 0.2, dy: w * 0.2)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    for (x, y, dx, dy) in [(box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1.0, 1.0),
                           (box.minX, box.maxY, 1.0, -1.0), (box.maxX, box.maxY, -1.0, -1.0)] {
        ctx.move(to: CGPoint(x: x + dx * arm, y: y)); ctx.addLine(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x, y: y + dy * arm))
    }
    ctx.strokePath()
    // An arrow in the accent red, the editor's default color.
    ctx.setStrokeColor(CGColor(srgbRed: 0.91, green: 0.26, blue: 0.29, alpha: 1))
    ctx.setFillColor(CGColor(srgbRed: 0.91, green: 0.26, blue: 0.29, alpha: 1))
    ctx.setLineWidth(lw * 1.1)
    let a = CGPoint(x: box.minX + box.width * 0.22, y: box.minY + box.height * 0.22)
    let b = CGPoint(x: box.maxX - box.width * 0.24, y: box.maxY - box.height * 0.24)
    ctx.move(to: a); ctx.addLine(to: CGPoint(x: b.x - w * 0.06, y: b.y - w * 0.06)); ctx.strokePath()
    let h = w * 0.16
    ctx.move(to: b); ctx.addLine(to: CGPoint(x: b.x - h, y: b.y - h * 0.25)); ctx.addLine(to: CGPoint(x: b.x - h * 0.25, y: b.y - h)); ctx.closePath(); ctx.fillPath()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
