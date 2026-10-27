// Draws the README banner and the GitHub social card from the app icon:
//   swift scripts/make-brand.swift build/Shotate.iconset/icon_512x512@2x.png docs
import AppKit

let icon = NSImage(contentsOfFile: CommandLine.arguments[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let out = CommandLine.arguments[2]
// Shotate's colors: deep ink, and mark red (the editor's default ink).
let ink = CGColor(srgbRed: 0.075, green: 0.082, blue: 0.137, alpha: 1)
let inkTop = CGColor(srgbRed: 0.161, green: 0.176, blue: 0.290, alpha: 1)
let red = NSColor(srgbRed: 0.91, green: 0.26, blue: 0.29, alpha: 1)

func render(_ w: Int, _ h: Int, iconSize: CGFloat, title: CGFloat, to name: String) {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let W = CGFloat(w), H = CGFloat(h)
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [inkTop, ink] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: H), end: CGPoint(x: W * 0.6, y: 0), options: [.drawsAfterEndLocation])
    let glow = [red.withAlphaComponent(0.18).cgColor, red.withAlphaComponent(0).cgColor]
    ctx.drawRadialGradient(CGGradient(colorsSpace: nil, colors: glow as CFArray, locations: [0, 1])!,
                           startCenter: CGPoint(x: W * 0.2, y: H * 0.5), startRadius: 0,
                           endCenter: CGPoint(x: W * 0.2, y: H * 0.5), endRadius: W * 0.32, options: [])
    let left = W * 0.08
    ctx.draw(icon, in: CGRect(x: left, y: (H - iconSize) / 2, width: iconSize, height: iconSize))
    let x = left + iconSize + W * 0.045
    // The four lines run from the title's cap height down to the last line's descender, which puts
    // their middle 0.175 title heights below the baseline math's middle: lift them so the block is
    // centered on the icon.
    let lift = title * 0.175
    // Each line shrinks if it would run past the right margin (the social card is narrower than the banner).
    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, rounded: Bool = false, color: NSColor, at p: CGPoint) {
        func font(_ size: CGFloat) -> NSFont {
            let f = NSFont.systemFont(ofSize: size, weight: weight)
            guard rounded, let d = f.fontDescriptor.withDesign(.rounded) else { return f }
            return NSFont(descriptor: d, size: size) ?? f
        }
        func line(_ size: CGFloat) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font(size), .foregroundColor: color]))
        }
        let room = W * 0.95 - p.x, width = CTLineGetTypographicBounds(line(size), nil, nil, nil)
        ctx.textPosition = p
        CTLineDraw(line(width > room ? size * room / width : size), ctx)
    }
    text("Shotate", size: title, weight: .heavy, rounded: true, color: .white, at: CGPoint(x: x, y: lift + H / 2 + title * 0.12))
    text("Point at what matters.", size: title * 0.38, weight: .semibold, color: NSColor(white: 1, alpha: 0.86),
         at: CGPoint(x: x, y: lift + H / 2 - title * 0.42))
    text("Free screenshot and annotation tool for macOS, Windows and Linux", size: title * 0.235, weight: .regular,
         color: NSColor(white: 1, alpha: 0.6), at: CGPoint(x: x, y: lift + H / 2 - title * 0.82))
    text("by Donovan Baney  ·  dbaney.com", size: title * 0.235, weight: .medium,
         color: NSColor(srgbRed: 0.98, green: 0.55, blue: 0.56, alpha: 1), at: CGPoint(x: x, y: lift + H / 2 - title * 1.14))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
render(1600, 560, iconSize: 340, title: 120, to: "banner.png")
// A smaller icon on the narrower card leaves the tagline a right margin like the icon's left one.
render(1280, 640, iconSize: 300, title: 108, to: "social-card.png")
