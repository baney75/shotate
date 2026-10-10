// Draws the README banner and the GitHub social card from the app icon:
//   swift scripts/make-brand.swift build/Snapmark.iconset/icon_512x512@2x.png docs
import AppKit

let icon = NSImage(contentsOfFile: CommandLine.arguments[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let out = CommandLine.arguments[2]

func render(_ w: Int, _ h: Int, iconSize: CGFloat, title: CGFloat, to name: String) {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let W = CGFloat(w), H = CGFloat(h)
    let bg = [CGColor(srgbRed: 0.13, green: 0.14, blue: 0.24, alpha: 1), CGColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)]
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: bg as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
    let glow = [CGColor(srgbRed: 0.91, green: 0.26, blue: 0.29, alpha: 0.16), CGColor(srgbRed: 0.91, green: 0.26, blue: 0.29, alpha: 0)]
    ctx.drawRadialGradient(CGGradient(colorsSpace: nil, colors: glow as CFArray, locations: [0, 1])!,
                           startCenter: CGPoint(x: W * 0.25, y: H * 0.5), startRadius: 0,
                           endCenter: CGPoint(x: W * 0.25, y: H * 0.5), endRadius: W * 0.35, options: [])
    let left = W * 0.08
    ctx.draw(icon, in: CGRect(x: left, y: (H - iconSize) / 2, width: iconSize, height: iconSize))
    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: CGPoint) {
        let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                               .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }
    let x = left + iconSize + W * 0.04
    text("Snapmark", size: title, weight: .bold, color: .white, at: CGPoint(x: x, y: H / 2 + title * 0.1))
    text("Screenshot. Mark it up. Paste.", size: title * 0.36, weight: .medium,
         color: NSColor(white: 1, alpha: 0.78), at: CGPoint(x: x, y: H / 2 - title * 0.42))
    text("Free and open source for macOS", size: title * 0.26, weight: .regular,
         color: NSColor(srgbRed: 0.98, green: 0.55, blue: 0.56, alpha: 1), at: CGPoint(x: x, y: H / 2 - title * 0.85))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
render(1600, 560, iconSize: 340, title: 112, to: "banner.png")
render(1280, 640, iconSize: 360, title: 104, to: "social-card.png")
