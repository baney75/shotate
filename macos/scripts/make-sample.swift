// Draws Tests/Fixtures/sample.png: a neutral fake app window for the self-test and README.
import AppKit

let w = 1200, h = 720
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func fill(_ r: CGRect, _ c: CGColor) { ctx.setFillColor(c); ctx.fill(r) }
fill(CGRect(x: 0, y: 0, width: w, height: h), CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1))
fill(CGRect(x: 0, y: h - 64, width: w, height: 64), CGColor(srgbRed: 0.89, green: 0.90, blue: 0.92, alpha: 1))
let lights: [CGColor] = [CGColor(srgbRed: 0.99, green: 0.37, blue: 0.34, alpha: 1),
                         CGColor(srgbRed: 0.99, green: 0.74, blue: 0.18, alpha: 1),
                         CGColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)]
for (i, c) in lights.enumerated() {
    ctx.setFillColor(c)
    ctx.fillEllipse(in: CGRect(x: 24 + i * 28, y: h - 42, width: 16, height: 16))
}
fill(CGRect(x: 60, y: 80, width: 520, height: 520), CGColor(gray: 1, alpha: 1))
fill(CGRect(x: 620, y: 80, width: 520, height: 520), CGColor(gray: 1, alpha: 1))
let line = CGColor(srgbRed: 0.80, green: 0.82, blue: 0.86, alpha: 1)
for r in 0..<9 {
    let y = CGFloat(540 - r * 50)
    let w1 = CGFloat(300 + (r * 37) % 150)
    let w2 = CGFloat(260 + (r * 53) % 190)
    fill(CGRect(x: 92, y: y, width: w1, height: 18), line)
    fill(CGRect(x: 652, y: y, width: w2, height: 18), line)
}
ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.56, blue: 0.98, alpha: 1))
ctx.addPath(CGPath(roundedRect: CGRect(x: 92, y: 110, width: 160, height: 44), cornerWidth: 10, cornerHeight: 10, transform: nil))
ctx.fillPath()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
