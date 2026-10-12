import AppKit
import ShotateCore

// `Shotate --selftest in.png out.png` draws one of every mark and writes the result (used by CI).
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--selftest"), i + 2 < args.count {
    guard let image = Renderer.loadImage(at: URL(fileURLWithPath: args[i + 1])) else { exit(2) }
    let doc = Document(image: image)
    let w = CGFloat(image.width), h = CGFloat(image.height)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }
    doc.add(Mark(tool: .redact, color: RGBA.palette[0], start: p(0.05, 0.75), end: p(0.35, 0.9)))
    let box = Mark(tool: .box, color: RGBA.palette[1], start: p(0.5, 0.5), end: p(0.9, 0.85))
    doc.add(box)
    doc.add(Mark(tool: .ellipse, color: RGBA.palette[4], start: p(0.55, 0.1), end: p(0.75, 0.35)))
    doc.add(Mark(tool: .highlight, color: RGBA.palette[1], start: p(0.05, 0.05), end: p(0.45, 0.15)))
    let pointer = Mark(tool: .arrow, color: RGBA.palette[0], start: p(0.30, 0.52), end: p(0.18, 0.235), bend: w * 0.04)
    doc.add(pointer)
    doc.add(Mark(tool: .text, color: RGBA.palette[2], start: p(0.08, 0.64), end: .zero, text: "Click Deploy"))
    // A label the curved arrow starts from, as double-clicking its tail makes.
    let anchor = pointer.calloutAnchor(end: 0)
    let callout = Renderer.pinned(Mark(tool: .text, color: RGBA.palette[0], size: .thin, start: .zero, end: .zero, text: "Start"),
                                  at: pointer.start, anchor: anchor, imageWidth: image.width)
    doc.addCallout(callout, arrow: pointer.id, end: 0, anchor: anchor)
    // An arrow attached to the box, from a label that wraps at its width.
    doc.add(Mark(tool: .arrow, color: RGBA.palette[4], start: p(0.44, 0.3), end: p(0.5, 0.6),
                 endBinding: Binding(id: box.id, anchor: CGPoint(x: 0, y: 0.3))))
    doc.add(Mark(tool: .text, color: RGBA.palette[4], size: .thin, start: p(0.3, 0.3), end: .zero,
                 text: "Release notes go here", textWidth: w * 0.14))
    doc.add(Mark(tool: .step, color: RGBA.palette[3], start: p(0.85, 0.2), end: .zero))
    doc.add(Mark(tool: .step, color: RGBA.palette[3], start: p(0.85, 0.45), end: .zero))
    // A curved arrow between the steps, labeled in its middle.
    doc.add(Mark(tool: .arrow, color: RGBA.palette[3], size: .thin, start: p(0.88, 0.41), end: p(0.88, 0.25), text: "then",
                 bend: w * 0.05))
    // A pen underline drawn with a tablet under the callout: light at the ends, pressed in the middle.
    let ink = (0...60).map { p(0.80 + CGFloat($0) * 0.003, 0.6 - 0.008 * sin(CGFloat($0) / 9)) }
    doc.add(Mark.stroke(ink, pressures: (0...60).map { sin(CGFloat($0) / 60 * .pi) }, color: RGBA.palette[0], size: .medium))
    // A callout past the right edge shows the canvas growing in the screenshot's border color.
    doc.add(Mark(tool: .text, color: RGBA.palette[4], start: p(0.93, 0.68), end: .zero, text: "Room to explain"))
    guard let out = Renderer.flatten(doc), let data = Renderer.pngData(out) else { exit(3) }
    try? data.write(to: URL(fileURLWithPath: args[i + 2]))
    exit(0)
}

// A relaunch starts this copy while the old one is still quitting: wait for it (up to 10 s), so the
// global shortcuts and the menu bar icon are free.
let waitPid = args.firstIndex(of: "--wait-for").flatMap { $0 + 1 < args.count ? pid_t(args[$0 + 1]) : nil }
if let pid = waitPid {
    for _ in 0..<100 where kill(pid, 0) == 0 { usleep(100_000) }
}

// One copy at a time. Shotate keeps Snapmark's bundle ID, so an old Snapmark still running (say, a
// copy installed somewhere else) would fight it for the shortcuts: quit that one. If another Shotate
// is already running, hand over to it.
for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
where other.processIdentifier != getpid() && other.processIdentifier != waitPid && !other.isTerminated {
    if other.bundleURL?.lastPathComponent == "Snapmark.app" {
        other.terminate()
        // Let it let go of the shortcuts and the menu bar icon (up to 5 s).
        for _ in 0..<50 where !other.isTerminated { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    } else {
        other.activate()
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
