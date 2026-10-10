import AppKit
import SnapmarkCore

// `Snapmark --selftest in.png out.png` draws one of every mark and writes the result (used by CI).
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--selftest"), i + 2 < args.count {
    guard let image = Renderer.loadImage(at: URL(fileURLWithPath: args[i + 1])) else { exit(2) }
    let doc = Document(image: image)
    let w = CGFloat(image.width), h = CGFloat(image.height)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }
    doc.add(Mark(tool: .redact, color: RGBA.palette[0], start: p(0.05, 0.75), end: p(0.35, 0.9)))
    doc.add(Mark(tool: .box, color: RGBA.palette[1], start: p(0.5, 0.5), end: p(0.9, 0.85)))
    doc.add(Mark(tool: .ellipse, color: RGBA.palette[4], start: p(0.55, 0.1), end: p(0.75, 0.35)))
    doc.add(Mark(tool: .highlight, color: RGBA.palette[1], start: p(0.05, 0.05), end: p(0.45, 0.15)))
    doc.add(Mark(tool: .arrow, color: RGBA.palette[0], start: p(0.30, 0.52), end: p(0.18, 0.235)))
    doc.add(Mark(tool: .text, color: RGBA.palette[2], start: p(0.08, 0.55), end: .zero, text: "Click Deploy"))
    doc.add(Mark(tool: .step, color: RGBA.palette[3], start: p(0.85, 0.2), end: .zero))
    doc.add(Mark(tool: .step, color: RGBA.palette[3], start: p(0.85, 0.45), end: .zero))
    // A callout past the right edge shows the canvas growing in the screenshot's border color.
    doc.add(Mark(tool: .text, color: RGBA.palette[4], start: p(0.93, 0.62), end: .zero, text: "Room to explain"))
    guard let out = Renderer.flatten(doc), let data = Renderer.pngData(out) else { exit(3) }
    try? data.write(to: URL(fileURLWithPath: args[i + 2]))
    exit(0)
}

// A relaunch starts this copy while the old one is still quitting: wait for it (up to 10 s), so the
// global shortcuts and the menu bar icon are free.
if let i = args.firstIndex(of: "--wait-for"), i + 1 < args.count, let pid = pid_t(args[i + 1]) {
    for _ in 0..<100 where kill(pid, 0) == 0 { usleep(100_000) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
