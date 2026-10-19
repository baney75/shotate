import CoreGraphics
import XCTest
@testable import ShotateCore

final class ShotateCoreTests: XCTestCase {
    func solidImage(_ w: Int = 400, _ h: Int = 300, gray: CGFloat = 0.5) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// RGBA at an image-coordinate point (origin bottom-left).
    func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                            bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let row = img.height - 1 - y
        let i = (row * img.width + x) * 4
        return (p[i], p[i + 1], p[i + 2])
    }

    func testUndoRedoRestoresMarksAndCrop() {
        let doc = Document(image: solidImage())
        doc.add(Mark(tool: .box, color: RGBA.palette[0], start: .zero, end: CGPoint(x: 50, y: 50)))
        doc.setCrop(CGRect(x: 10, y: 10, width: 100, height: 80))
        XCTAssertEqual(doc.marks.count, 1)
        XCTAssertNotNil(doc.crop)
        doc.undo()
        XCTAssertNil(doc.crop)
        doc.undo()
        XCTAssertTrue(doc.marks.isEmpty)
        XCTAssertFalse(doc.isEdited)
        doc.redo(); doc.redo()
        XCTAssertEqual(doc.marks.count, 1)
        XCTAssertNotNil(doc.crop)
        doc.undo()
        doc.add(Mark(tool: .arrow, color: RGBA.palette[1], start: .zero, end: CGPoint(x: 9, y: 9)))
        XCTAssertFalse(doc.canRedo, "a new edit clears redo")
    }

    func testRevisionTracksEveryChange() {
        let doc = Document(image: solidImage())
        XCTAssertEqual(doc.revision, 0)
        doc.add(Mark(tool: .box, color: RGBA.palette[0], start: .zero, end: CGPoint(x: 9, y: 9)))
        let afterAdd = doc.revision
        doc.undo()
        XCTAssertGreaterThan(doc.revision, afterAdd, "undo back to clean is still a change since the last save")
        doc.redo()
        XCTAssertGreaterThan(doc.revision, afterAdd + 1)
    }

    func testStepsNumberThemselves() {
        let doc = Document(image: solidImage())
        for _ in 0..<3 { doc.add(Mark(tool: .step, color: RGBA.palette[2], start: CGPoint(x: 20, y: 20), end: .zero)) }
        XCTAssertEqual(doc.marks.map(\.number), [1, 2, 3])
        doc.remove(id: doc.marks[1].id)
        XCTAssertEqual(doc.nextStepNumber, 4)
    }

    func testHitTestPicksTopmostAndMoves() {
        let doc = Document(image: solidImage())
        doc.add(Mark(tool: .highlight, color: RGBA.palette[1], start: CGPoint(x: 10, y: 10), end: CGPoint(x: 200, y: 100)))
        doc.add(Mark(tool: .arrow, color: RGBA.palette[0], start: CGPoint(x: 0, y: 0), end: CGPoint(x: 300, y: 300)))
        let hit = doc.hitTest(CGPoint(x: 50, y: 51), tolerance: 6)
        XCTAssertEqual(hit?.tool, .arrow, "the arrow is on top and passes near (50,50)")
        XCTAssertNil(doc.hitTest(CGPoint(x: 390, y: 10), tolerance: 6))
        doc.update(hit!.offset(by: CGVector(dx: 5, dy: 0)))
        XCTAssertEqual(doc.marks.last?.start.x, 5)
        doc.undo()
        XCTAssertEqual(doc.marks.last?.start.x, 0)
    }

    func testCropIsClippedAndTinyCropsAreIgnored() {
        let doc = Document(image: solidImage())
        doc.setCrop(CGRect(x: 350, y: 250, width: 200, height: 200))
        XCTAssertEqual(doc.crop, CGRect(x: 350, y: 250, width: 50, height: 50))
        doc.setCrop(CGRect(x: 1, y: 1, width: 2, height: 2))
        XCTAssertNil(doc.crop)
    }

    func testFlattenDrawsMarksAndAppliesCrop() {
        let doc = Document(image: solidImage(gray: 0.5))
        doc.add(Mark(tool: .redact, color: RGBA.palette[0], start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100)))
        doc.add(Mark(tool: .highlight, color: RGBA(1, 1, 0), start: CGPoint(x: 200, y: 200), end: CGPoint(x: 300, y: 280)))
        let out = Renderer.flatten(doc)!
        let redacted = pixel(out, 50, 50)
        XCTAssertLessThan(Int(redacted.0), 40, "redaction is a dark solid bar")
        let lit = pixel(out, 250, 240)
        XCTAssertGreaterThan(Int(lit.0), Int(lit.2) + 30, "highlight tints yellow")
        let untouched = pixel(out, 350, 50)
        XCTAssertEqual(Int(untouched.0), Int(untouched.2))
        doc.setCrop(CGRect(x: 0, y: 0, width: 120, height: 90))
        let cropped = Renderer.flatten(doc)!
        XCTAssertEqual(cropped.width, 120)
        XCTAssertEqual(cropped.height, 90)
        XCTAssertLessThan(Int(pixel(cropped, 50, 50).0), 40, "crop keeps bottom-left origin")
        XCTAssertNotNil(Renderer.pngData(cropped))
    }

    func testTextAndStepRender() {
        let doc = Document(image: solidImage(800, 400, gray: 0.9))
        doc.add(Mark(tool: .text, color: RGBA.palette[2], start: CGPoint(x: 100, y: 100), end: .zero, text: "Click here"))
        doc.add(Mark(tool: .step, color: RGBA.palette[0], start: CGPoint(x: 600, y: 200), end: .zero))
        let out = Renderer.flatten(doc)!
        let label = Renderer.textOrStepRect(doc.marks[0], imageWidth: 800)
        XCTAssertGreaterThan(label.width, 60)
        let inLabel = pixel(out, Int(label.minX) + 3, Int(label.midY))
        XCTAssertGreaterThan(Int(inLabel.2), Int(inLabel.0) + 60, "label fill is blue")
        let disc = pixel(out, 600, 200 + Int(Renderer.fontSize(imageWidth: 800, size: .medium) * 0.7))
        XCTAssertGreaterThan(Int(disc.0), Int(disc.2) + 60, "step disc is red")
    }

    func testMarksStayReadableOnSmallAndLargeCaptures() {
        XCTAssertGreaterThanOrEqual(StrokeSize.medium.width(forImageWidth: 600), 4)
        XCTAssertLessThanOrEqual(StrokeSize.medium.width(forImageWidth: 6000), 14)
        XCTAssertGreaterThanOrEqual(Renderer.fontSize(imageWidth: 600, size: .medium), 22)
        XCTAssertLessThanOrEqual(Renderer.fontSize(imageWidth: 6000, size: .medium), 72)
    }

    func testEllipseIsHitOnItsOutlineNotItsCorner() {
        let doc = Document(image: solidImage(1200, 1200))
        doc.add(Mark(tool: .ellipse, color: RGBA.palette[0], start: CGPoint(x: 100, y: 100), end: CGPoint(x: 1100, y: 1100)))
        let r45 = CGFloat(500) * CGFloat(2).squareRoot() / 2
        let onOutline = CGPoint(x: 600 + r45, y: 600 + r45)
        XCTAssertNotNil(doc.hitTest(onOutline, tolerance: 8))
        XCTAssertNil(doc.hitTest(CGPoint(x: 1090, y: 1090), tolerance: 8), "bounding-box corner is empty space")
        let thin = Document(image: solidImage(3000, 100))
        thin.add(Mark(tool: .ellipse, color: RGBA.palette[0], start: CGPoint(x: 0, y: 0), end: CGPoint(x: 2000, y: 20)))
        XCTAssertNil(thin.hitTest(CGPoint(x: 2400, y: 10), tolerance: 8), "400 px past the tip of a long ellipse")
        XCTAssertNotNil(thin.hitTest(CGPoint(x: 2001, y: 10), tolerance: 8), "at the tip")
    }

    func testRedactionCoversEarlierMarks() {
        let doc = Document(image: solidImage(800, 400, gray: 0.9))
        doc.add(Mark(tool: .text, color: RGBA.palette[2], start: CGPoint(x: 100, y: 100), end: .zero, text: "secret"))
        let label = Renderer.textOrStepRect(doc.marks[0], imageWidth: 800)
        doc.add(Mark(tool: .redact, color: RGBA.palette[0], start: CGPoint(x: label.minX - 5, y: label.minY - 5),
                     end: CGPoint(x: label.maxX + 5, y: label.maxY + 5)))
        let p = pixel(Renderer.flatten(doc)!, Int(label.midX), Int(label.midY))
        XCTAssertLessThan(Int(p.2), 60, "the blue label is hidden under the bar")
    }

    func testDPIIsKeptThroughSaveAndLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try Renderer.pngData(solidImage(), dpi: 144)!.write(to: url)
        XCTAssertEqual(Renderer.loadDocument(at: url)?.dpi, 144)
    }

    func testShortcutParsing() {
        XCTAssertNil(Shortcut("cmd+/"), "keys that cannot be registered are rejected up front")
        XCTAssertEqual(Shortcut("cmd+shift+a")?.modifiers, [.cmd, .shift])
        XCTAssertEqual(Shortcut("⌘⇧+s".replacingOccurrences(of: "⌘⇧", with: "cmd+shift"))?.key, "s")
        XCTAssertNil(Shortcut("a"), "a bare key would swallow typing")
        XCTAssertNil(Shortcut("cmd+shift+ab"))
        XCTAssertEqual(Shortcut("ctrl+option+space")?.key, "space")
    }

    func testCaptureFileNamesNeverCollide() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = Settings(saveFolder: dir)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = s.newCaptureURL(date: date)
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = s.newCaptureURL(date: date)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" 2.png"))
    }

    func testRecordingFileNamesNeverCollide() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = Settings(saveFolder: dir)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = s.newRecordingURL(date: date)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("Shotate Recording "))
        XCTAssertEqual(first.pathExtension, "mp4")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        XCTAssertTrue(s.newRecordingURL(date: date).lastPathComponent.hasSuffix(" 2.mp4"))
    }

    /// The record shortcuts work out of the box, including for config files written before they
    /// existed, and an empty string turns one off.
    func testRecordShortcutsDefaultOnForOldConfigs() throws {
        let url = tempConfig()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"shortcuts": {"captureArea": "shift+cmd+s", "captureScreen": "", "captureWindow": ""}}"#.utf8).write(to: url)
        let s = try Settings.load(from: url)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertEqual(s.shortcut("recordScreen"), Shortcut("cmd+ctrl+shift+r"))
        XCTAssertEqual(s.shortcut("recordApp"), Shortcut("cmd+shift+d"))
        XCTAssertNil(s.shortcut("captureScreen"), "a shortcut the file turned off stays off")
        try Data(#"{"shortcuts": {"recordArea": ""}}"#.utf8).write(to: url)
        XCTAssertNil(try Settings.load(from: url).shortcut("recordArea"))
        XCTAssertEqual(Settings().shortcut("captureScreen"), Shortcut("cmd+ctrl+shift+s"))
    }

    /// An upgrade never takes keys the file already uses: a new action whose default clashes with
    /// one of the person's shortcuts or commands starts off instead.
    func testNewDefaultsYieldToShortcutsInUse() throws {
        let url = tempConfig()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"shortcuts": {"captureWindow": "shift+cmd+r"}, "commands": {"cmd+shift+d": "/usr/bin/true"}}"#.utf8)
            .write(to: url)
        let s = try Settings.load(from: url)
        XCTAssertEqual(s.shortcut("captureWindow"), Shortcut("cmd+shift+r"))
        XCTAssertNil(s.shortcut("recordArea"))
        XCTAssertNil(s.shortcut("recordApp"))
        XCTAssertEqual(s.shortcut("recordScreen"), Shortcut("cmd+ctrl+shift+r"))
        XCTAssertEqual(s.commandHotkeys["cmd+shift+d"], "/usr/bin/true")
    }

    /// Settings carried over from before the config file get the same protection.
    func testMigratedSettingsYieldNewDefaults() {
        let d = UserDefaults(suiteName: "shotate-test-\(UUID().uuidString)")!
        d.set("cmd+shift+r", forKey: "captureShortcut")
        d.set(["cmd+shift+d": "/usr/bin/true"], forKey: "commandHotkeys")
        let s = Settings.migrated(from: d)
        XCTAssertEqual(s.shortcut("captureArea"), Shortcut("cmd+shift+r"))
        XCTAssertNil(s.shortcut("recordArea"))
        XCTAssertNil(s.shortcut("recordApp"))
        XCTAssertEqual(s.shortcut("recordScreen"), Shortcut("cmd+ctrl+shift+r"))
    }

    /// A short log is copied whole; a long one is cut to its newest whole lines, and says so.
    func testLongLogsAreClippedForTheClipboard() {
        let short = Data("a\nb\n".utf8)
        XCTAssertEqual(LogClip.text(tail: short, size: short.count, path: "/x.log"), "a\nb\n")
        let lines = (0..<1000).map { "line \($0)\n" }.joined()
        let tail = Data(lines.utf8).suffix(100)
        let clipped = LogClip.text(tail: tail, size: 50_000, path: "/x.log", limit: 100)
        XCTAssertTrue(clipped.hasPrefix("# The log is 48 KB"))
        XCTAssertTrue(clipped.contains("Whole log: /x.log\n"))
        XCTAssertTrue(clipped.hasSuffix("line 999\n"))
        let body = clipped.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        XCTAssertTrue(body.first?.hasPrefix("line ") == true, "starts on a whole line")
    }

    func tempConfig() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shotate-\(UUID().uuidString)/config.json")
    }

    func testConfigFileRoundTrips() throws {
        let url = tempConfig()
        var s = Settings(saveFolder: URL(fileURLWithPath: "/tmp/shotate-\(UUID().uuidString)-missing", isDirectory: true))
        s.copyOnCapture = false
        s.commandHotkeys = ["cmd+shift+a": "/usr/bin/true"]
        s.shortcuts["captureWindow"] = "ctrl+shift+2"
        s.toolKeys = ["arrow": "w"]
        try s.save(to: url)
        var expected = s
        expected.toolKeys = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0.title.lowercased(), s.key(for: $0)) })
        XCTAssertEqual(try Settings.load(from: url), expected, "round-trips even when the folder does not exist")
    }

    /// People and agents write partial files by hand: what's missing keeps its default, and bad
    /// shortcuts turn that action off instead of breaking the whole file.
    func testHandWrittenPartialConfigKeepsDefaults() throws {
        let url = tempConfig()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"shortcuts": {"captureScreen": "CMD+SHIFT+9", "captureWindow": "nonsense"}, "extra": 1}"#.utf8).write(to: url)
        let s = try Settings.load(from: url)
        XCTAssertEqual(s.shortcuts["captureArea"], Settings.defaultShortcut)
        XCTAssertEqual(s.shortcuts["captureScreen"], "cmd+shift+9")
        XCTAssertEqual(s.shortcuts["captureWindow"], "")
        XCTAssertTrue(s.copyOnCapture)
        try Data("{ not json".utf8).write(to: url)
        XCTAssertThrowsError(try Settings.load(from: url))
    }

    func testToolKeysRemapWithoutLosingAnyTool() {
        var s = Settings()
        XCTAssertEqual(s.key(for: .arrow), "a")
        s.toolKeys = ["arrow": "w", "box": "a", "ellipse": "r"]  // a chain of swaps
        XCTAssertEqual(s.tool(forKey: "w"), .arrow)
        XCTAssertEqual(s.tool(forKey: "a"), .box)
        XCTAssertEqual(s.tool(forKey: "r"), .ellipse)
        s.toolKeys = ["arrow": "v"]  // clashes with Select's default: ignored
        XCTAssertEqual(s.key(for: .arrow), "a")
        XCTAssertEqual(s.tool(forKey: "v"), .select)
        s.toolKeys = ["arrow": "1"]  // digits pick colors
        XCTAssertEqual(s.key(for: .arrow), "a")
        XCTAssertEqual(Set(Tool.allCases.map(s.key(for:))).count, Tool.allCases.count)
    }

    /// A file written before the pen existed keeps its own keys; the pen moves to a free letter.
    func testNewToolsDontTakeKeysPeopleChose() {
        var s = Settings()
        s.toolKeys = ["select": "v", "arrow": "a", "box": "p", "ellipse": "o", "highlight": "h", "text": "t",
                      "redact": "b", "step": "n", "crop": "c"]
        XCTAssertEqual(s.key(for: .box), "p")
        XCTAssertNotEqual(s.key(for: .pen), "p")
        XCTAssertEqual(s.tool(forKey: s.key(for: .pen)), .pen)
        s.normalize()
        XCTAssertEqual(s.key(for: .box), "p", "and it stays that way once written back")
        // Once the file names the pen, its default counts like any other.
        s.toolKeys = ["box": "p", "pen": "p"]
        XCTAssertEqual(s.key(for: .pen), "p")
        XCTAssertEqual(s.key(for: .box), "r")
    }

    /// Whatever the file says, every tool must keep a key of its own.
    func testEveryToolStaysReachableUnderAnyRemap() {
        let letters = ["a", "b", "c", "v", "r", "x", "1", "", "bb"]
        let names = Tool.allCases.map { $0.title.lowercased() }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            var s = Settings()
            for n in names where Bool.random(using: &rng) { s.toolKeys[n] = letters.randomElement(using: &rng)! }
            for t in Tool.allCases {
                XCTAssertEqual(s.tool(forKey: s.key(for: t)), t, "\(s.toolKeys)")
            }
        }
        var s = Settings()
        s.toolKeys = ["arrow": "b", "redact": "1"]  // "1" is not a tool key, so Redact keeps its default "b" and Arrow cannot take it
        XCTAssertEqual(s.key(for: .redact), "b")
        XCTAssertEqual(s.key(for: .arrow), "a")
        s.toolKeys = ["arrow": "b", "redact": "x"]  // Redact moves away, so Arrow may take "b"
        XCTAssertEqual(s.key(for: .arrow), "b")
        XCTAssertEqual(s.key(for: .redact), "x")
    }

    func testNormalizedSettingsEqualWhatTheFileLoads() throws {
        let url = tempConfig()
        var s = Settings()
        s.toolKeys = ["arrow": "w"]
        try s.save(to: url)
        s.normalize()
        XCTAssertEqual(try Settings.load(from: url), s)
    }

    func testMigratesOldDefaults() {
        let d = UserDefaults(suiteName: "shotate-test-\(UUID().uuidString)")!
        d.set(false, forKey: "captureHotkeyEnabled")
        d.set(["cmd+shift+a": "x"], forKey: "commandHotkeys")
        let s = Settings.migrated(from: d)
        XCTAssertEqual(s.shortcuts["captureArea"], "")
        XCTAssertNil(s.captureShortcut)
        XCTAssertEqual(s.commandHotkeys, ["cmd+shift+a": "x"])
    }

    /// Captures are read from a temp file that is deleted right away. The image must not depend on
    /// that file afterwards, or saving and copying fail with "No IDATs written".
    func testLoadedDocumentSurvivesSourceFileDeletion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotate-test-\(UUID().uuidString).png")
        try XCTUnwrap(Renderer.pngData(solidImage(gray: 0.2), dpi: 144)).write(to: url)
        let doc = try XCTUnwrap(Renderer.loadDocument(at: url))
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(doc.dpi, 144)
        doc.add(Mark(tool: .box, color: RGBA.palette[0], start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 90)))
        let flat = try XCTUnwrap(Renderer.flatten(doc))
        XCTAssertNotNil(Renderer.pngData(flat, dpi: doc.dpi))
        XCTAssertNotNil(Renderer.pngData(doc.image, dpi: doc.dpi))
        XCTAssertEqual(pixel(flat, 200, 150).0, pixel(doc.image, 200, 150).0)
    }

    func testShortcutDisplayStringUsesMenuOrder() {
        XCTAssertEqual(Shortcut("cmd+shift+s")?.displayString, "⇧⌘S")
        XCTAssertEqual(Shortcut("shift+ctrl+option+cmd+2")?.displayString, "⌃⌥⇧⌘2")
        XCTAssertEqual(Shortcut("ctrl+f5")?.displayString, "⌃F5")
    }

    func testDraggingACornerKeepsTheOppositeCornerFixed() {
        let m = Mark(tool: .box, color: RGBA.palette[0], start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 60))
        XCTAssertEqual(m.handles.count, 4)
        // Handle 2 is (start.x, end.y) = top-left; its opposite is (end.x, start.y).
        let r = m.moving(handle: 2, to: CGPoint(x: 0, y: 80)).rect
        XCTAssertEqual(r, CGRect(x: 0, y: 10, width: 100, height: 70))
        let arrow = Mark(tool: .arrow, color: RGBA.palette[0], start: .zero, end: CGPoint(x: 50, y: 50))
        XCTAssertEqual(arrow.moving(handle: 1, to: CGPoint(x: 70, y: 20)).end, CGPoint(x: 70, y: 20))
        XCTAssertEqual(arrow.moving(handle: 1, to: CGPoint(x: 70, y: 20)).start, .zero)
        XCTAssertTrue(Mark(tool: .text, color: RGBA.palette[0], start: .zero, end: .zero, text: "x").handles.isEmpty)
    }

    func testReorderAndDuplicateAreUndoable() {
        let doc = Document(image: solidImage())
        let a = Mark(tool: .box, color: RGBA.palette[0], start: .zero, end: CGPoint(x: 10, y: 10))
        let b = Mark(tool: .ellipse, color: RGBA.palette[1], start: .zero, end: CGPoint(x: 20, y: 20))
        doc.add(a); doc.add(b)
        doc.reorder(id: a.id, toFront: true)
        XCTAssertEqual(doc.marks.map(\.id), [b.id, a.id])
        doc.undo()
        XCTAssertEqual(doc.marks.map(\.id), [a.id, b.id])
        let copy = a.duplicate(offset: 8)
        XCTAssertNotEqual(copy.id, a.id)
        XCTAssertEqual(copy.start, CGPoint(x: 8, y: -8))
        let before = doc.revision
        doc.reorder(id: b.id, toFront: true)  // already on top: no change, no undo step
        XCTAssertEqual(doc.revision, before)
    }

    /// Like Shottr: drawing past the edge grows the image, and the new area matches the border.
    func testMarksPastTheEdgeExtendTheCanvasWithTheBorderColor() throws {
        let doc = Document(image: solidImage(400, 300, gray: 0.8))
        XCTAssertEqual(doc.canvas, doc.bounds)
        doc.add(Mark(tool: .box, color: RGBA.palette[0], start: CGPoint(x: 100, y: 100), end: CGPoint(x: 200, y: 200)))
        XCTAssertEqual(doc.canvas, doc.bounds, "marks inside the image don't change its size")
        doc.add(Mark(tool: .arrow, color: RGBA.palette[0], start: CGPoint(x: 300, y: 150), end: CGPoint(x: 520, y: 150)))
        let flat = try XCTUnwrap(Renderer.flatten(doc))
        XCTAssertGreaterThan(flat.width, 520)
        XCTAssertEqual(flat.height, 300, "only the side that was drawn past grows")
        let corner = pixel(flat, flat.width - 2, 2), inside = pixel(flat, 10, 10)
        XCTAssertEqual(Int(corner.0), Int(inside.0), accuracy: 2, "the fill matches the image's edge")
        XCTAssertEqual(Int(corner.2), Int(inside.2), accuracy: 2)
        doc.undo()
        XCTAssertEqual(try XCTUnwrap(Renderer.flatten(doc)).width, 400, "undo shrinks it back")
    }

    func testBorderColorIsTheEdgeNotTheMiddle() {
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 10, width: 180, height: 80))
        let c = Document(image: ctx.makeImage()!).borderColor
        XCTAssertEqual(c.b, 0.9, accuracy: 0.02)
        XCTAssertEqual(c.r, 0.1, accuracy: 0.02)
    }

    /// A crop drawn into grown space must not break export once that space goes away.
    func testCropSurvivesTheCanvasShrinking() throws {
        let doc = Document(image: solidImage(100, 100))
        let box = Mark(tool: .box, color: RGBA.palette[0], start: CGPoint(x: 150, y: 10), end: CGPoint(x: 190, y: 50))
        doc.add(box)
        doc.setCrop(CGRect(x: 120, y: 10, width: 60, height: 40))
        XCTAssertNotNil(doc.effectiveCrop)
        doc.remove(id: box.id)
        XCTAssertNil(doc.effectiveCrop, "the crop lay entirely in space that no longer exists")
        let flat = try XCTUnwrap(Renderer.flatten(doc))
        XCTAssertEqual(flat.width, 100)
        doc.setCrop(CGRect(x: 50, y: 0, width: 150, height: 100))
        XCTAssertEqual(try XCTUnwrap(Renderer.flatten(doc)).width, 50, "a crop partly outside is trimmed, not dropped")
    }

    func testTransparentEdgesGrowTransparent() {
        let ctx = CGContext(data: nil, width: 50, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 10, width: 30, height: 30))  // opaque middle, clear border
        XCTAssertEqual(Document(image: ctx.makeImage()!).borderColor.a, 0)
    }

    func testDraggingALabelCornerScalesItAboutItsTopLeft() {
        let label = Mark(tool: .text, color: RGBA.palette[0], start: CGPoint(x: 100, y: 200), end: CGPoint(x: 100, y: 200), text: "Hello")
        let r = Renderer.textOrStepRect(label, imageWidth: 1000)
        // Drag the bottom-right corner out to twice the width.
        let big = Renderer.resizing(text: label, toCorner: CGPoint(x: r.minX + r.width * 2, y: r.minY), imageWidth: 1000)
        let br = Renderer.textOrStepRect(big, imageWidth: 1000)
        XCTAssertEqual(big.fontSize!, Renderer.fontSize(of: label, imageWidth: 1000) * 2, accuracy: 0.01)
        XCTAssertEqual(br.minX, r.minX, accuracy: 0.01)
        XCTAssertEqual(br.maxY, r.maxY, accuracy: 0.01)
        XCTAssertEqual(br.width, r.width * 2, accuracy: r.width * 0.03)  // SF Pro changes shape with size
        // Dragging past the top-left corner can't flip or erase it.
        let tiny = Renderer.resizing(text: label, toCorner: CGPoint(x: 0, y: 1000), imageWidth: 1000)
        XCTAssertEqual(tiny.fontSize, 8)
        // A hand size survives duplication and moves the hit area with it.
        XCTAssertEqual(big.duplicate(offset: 5).fontSize, big.fontSize)
        let doc = Document(image: solidImage(1000, 600))
        doc.add(big)
        XCTAssertEqual(doc.hitTest(CGPoint(x: br.maxX - 2, y: br.midY), tolerance: 0)?.id, big.id)
    }

    func testLabelsWrapAtTheirWidthAndGrowDownward() {
        let red = RGBA.palette[0]
        let one = Mark(tool: .text, color: red, start: CGPoint(x: 100, y: 500), end: .zero, text: "Deploy the build now")
        let r1 = Renderer.textOrStepRect(one, imageWidth: 1000)
        var wrapped = one
        wrapped.textWidth = r1.width / 2
        let r2 = Renderer.textOrStepRect(wrapped, imageWidth: 1000)
        XCTAssertGreaterThan(r2.height, r1.height * 1.5)   // two or more lines
        XCTAssertLessThan(r2.width, r1.width)
        XCTAssertEqual(r2.maxY, 500, accuracy: 0.01)      // the top-left corner is the anchor
        XCTAssertEqual(r1.maxY, 500, accuracy: 0.01)
        // Line breaks typed with Option-Return add lines too.
        var broken = one
        broken.text = "Deploy\nnow"
        XCTAssertEqual(Renderer.textOrStepRect(broken, imageWidth: 1000).height, r1.height + Renderer.fontSize(of: one, imageWidth: 1000) * Renderer.lineHeight, accuracy: 0.5)
        // The side handle sets the width; the corner scales width and font together.
        let side = Renderer.moving(wrapped, handle: 1, to: CGPoint(x: r2.maxX + 50, y: r2.midY), imageWidth: 1000)
        XCTAssertEqual(side.textWidth!, wrapped.textWidth! + 50, accuracy: 0.01)
        let corner = Renderer.moving(wrapped, handle: 0, to: CGPoint(x: r2.minX + r2.width * 2, y: r2.minY), imageWidth: 1000)
        XCTAssertEqual(corner.textWidth! / wrapped.textWidth!, corner.fontSize! / Renderer.fontSize(of: wrapped, imageWidth: 1000), accuracy: 0.001)
    }

    func testArrowsFollowTheMarksTheyAreAttachedTo() {
        let doc = Document(image: solidImage(1000, 600))
        let box = Mark(tool: .box, color: RGBA.palette[1], start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 200))
        doc.add(box)
        let b = doc.binding(at: CGPoint(x: 300, y: 150), tolerance: 0, excluding: nil)!
        XCTAssertEqual(b.id, box.id)
        XCTAssertEqual(b.anchor.x, 1, accuracy: 0.001)
        XCTAssertEqual(b.anchor.y, 0.5, accuracy: 0.001)
        XCTAssertNil(doc.binding(at: CGPoint(x: 600, y: 400), tolerance: 0, excluding: nil))
        let arrow = Mark(tool: .arrow, color: RGBA.palette[0], start: CGPoint(x: 600, y: 400), end: CGPoint(x: 300, y: 150), endBinding: b)
        doc.add(arrow)
        // Moving the box drags the arrow's end with it, in one undo step.
        doc.update(box.offset(by: CGVector(dx: 50, dy: -20)))
        XCTAssertEqual(doc.marks.last!.end, CGPoint(x: 350, y: 130))
        XCTAssertEqual(doc.marks.last!.start, CGPoint(x: 600, y: 400))
        // Live previews resolve the same way without touching the document.
        var marks = doc.marks
        marks[0] = marks[0].offset(by: CGVector(dx: 10, dy: 0))
        XCTAssertEqual(doc.resolvingBindings(marks).last!.end, CGPoint(x: 360, y: 130))
        doc.undo()
        XCTAssertEqual(doc.marks.last!.end, CGPoint(x: 300, y: 150))
        // Moving the arrow itself lets go; deleting the box leaves the arrow where it is, detached.
        XCTAssertNil(arrow.offset(by: CGVector(dx: 5, dy: 5)).endBinding)
        doc.remove(id: box.id)
        XCTAssertNil(doc.marks.last!.endBinding)
        XCTAssertEqual(doc.marks.last!.end, CGPoint(x: 300, y: 150))
    }

    func testDraggedMarksSnapToEdgesAndCenters() {
        let targets = [CGRect(x: 0, y: 0, width: 1000, height: 600), CGRect(x: 100, y: 100, width: 200, height: 100)]
        // A box 4 px right of the target's left edge snaps onto it, with a guide.
        let (d, guides) = Snap.move(CGRect(x: 104, y: 400, width: 50, height: 50), to: targets, threshold: 6)
        XCTAssertEqual(d.dx, -4)
        XCTAssertEqual(d.dy, 0)
        XCTAssertTrue(guides.contains { $0.vertical && $0.at == 100 })
        // Centers line up too: the image's center is at x 500.
        XCTAssertEqual(Snap.move(CGRect(x: 473, y: 400, width: 50, height: 20), to: targets, threshold: 6).0.dx, 2)
        // Too far away: no snap and no guides.
        let far = Snap.move(CGRect(x: 120, y: 400, width: 50, height: 50), to: targets, threshold: 6)
        XCTAssertEqual(far.0, .zero)
        XCTAssertTrue(far.1.isEmpty)
        XCTAssertEqual(Snap.point(CGPoint(x: 297, y: 203), to: targets, threshold: 6).0, CGPoint(x: 300, y: 200))
    }

    func testPastingAStyleKeepsShapeAndText() {
        let source = Mark(tool: .text, color: RGBA.palette[3], size: .thick, start: .zero, end: .zero, text: "A", fontSize: 40)
        let target = Mark(tool: .text, color: RGBA.palette[0], start: CGPoint(x: 9, y: 9), end: .zero, text: "B")
        let styled = target.styled(like: source)
        XCTAssertEqual(styled.color, source.color)
        XCTAssertEqual(styled.size, .thick)
        XCTAssertEqual(styled.fontSize, 40)
        XCTAssertEqual(styled.text, "B")
        XCTAssertEqual(styled.start, target.start)
    }

    func testRestyledWrappingLabelsKeepTheirLines() {
        var label = Mark(tool: .text, color: RGBA.palette[0], start: .zero, end: .zero, text: "Release notes go here", textWidth: 200)
        let big = Mark(tool: .text, color: RGBA.palette[1], start: .zero, end: .zero, text: "x", fontSize: 90)
        let lines = Renderer.textOrStepRect(label, imageWidth: 1000).height
        let pasted = Renderer.rewrapped(label.styled(like: big), from: label, imageWidth: 1000)
        XCTAssertEqual(pasted.textWidth! / 200, 90 / Renderer.fontSize(of: label, imageWidth: 1000), accuracy: 0.001)
        XCTAssertEqual(Renderer.textOrStepRect(pasted, imageWidth: 1000).height / lines, 90 / Renderer.fontSize(of: label, imageWidth: 1000), accuracy: 0.01)
        // A shape's style drops a label's hand-set size back to its preset.
        label.fontSize = 50
        XCTAssertNil(label.styled(like: Mark(tool: .box, color: RGBA.palette[2], start: .zero, end: .zero)).fontSize)
    }

    /// Settings from the Snapmark days carry over once and are never overwritten after that.
    func testAdoptsSnapmarkConfigOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shotate-adopt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("snapmark/config.json"), new = dir.appendingPathComponent("shotate/config.json")
        XCTAssertFalse(Settings.adoptLegacyConfig(from: old, to: new), "nothing to adopt")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"saveFolder": "~/Desktop"}"#.utf8).write(to: old)
        XCTAssertTrue(Settings.adoptLegacyConfig(from: old, to: new))
        XCTAssertEqual(try Settings.load(from: new).saveFolder.path, NSHomeDirectory() + "/Desktop")
        try Data(#"{"saveFolder": "~/Documents"}"#.utf8).write(to: new)
        XCTAssertFalse(Settings.adoptLegacyConfig(from: old, to: new), "an existing Shotate config wins")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "the old file stays")
    }

    func testArrowsBendFromTheirMiddleHandle() throws {
        let doc = Document(image: solidImage(600, 300, gray: 0.8))
        let arrow = Mark(tool: .arrow, color: RGBA.palette[2], start: CGPoint(x: 100, y: 100), end: CGPoint(x: 500, y: 100))
        XCTAssertEqual(arrow.handles.count, 3)
        XCTAssertEqual(arrow.handles[2], CGPoint(x: 300, y: 100), "a straight arrow's middle handle is on its line")
        let bent = arrow.moving(handle: 2, to: CGPoint(x: 260, y: 180))
        XCTAssertEqual(bent.bend, 80, accuracy: 0.001, "only the distance off the line counts")
        XCTAssertEqual(bent.midpoint.y, 180, accuracy: 0.001)
        XCTAssertEqual(bent.handles[2].x, 300, accuracy: 0.001)
        doc.add(bent)
        // The curve, not the straight line between the ends, is what hits and what draws.
        XCTAssertEqual(doc.hitTest(CGPoint(x: 300, y: 178), tolerance: 6)?.id, bent.id)
        XCTAssertNil(doc.hitTest(CGPoint(x: 300, y: 100), tolerance: 6))
        XCTAssertGreaterThan(Renderer.extent(of: bent, imageWidth: 600).maxY, 180)
        let flat = try XCTUnwrap(Renderer.flatten(doc))
        let on = pixel(flat, 300, 180), off = pixel(flat, 300, 100)
        XCTAssertGreaterThan(Int(on.2), Int(on.0) + 60, "the curve's middle is painted in the arrow's blue")
        XCTAssertEqual(Int(off.0), Int(off.2), accuracy: 2, "the chord is left bare")
        // The bend is relative, so moving an end keeps the shape bowing the same way.
        XCTAssertEqual(bent.moving(handle: 1, to: CGPoint(x: 500, y: 140)).bend, 80)
        XCTAssertEqual(bent.duplicate(offset: 5).bend, 80)
    }

    func testDoubleClickedArrowEndsGetALabelTheArrowPointsAt() {
        let doc = Document(image: solidImage(1000, 600))
        let arrow = Mark(tool: .arrow, color: RGBA.palette[0], start: CGPoint(x: 100, y: 300), end: CGPoint(x: 400, y: 300))
        doc.add(arrow)
        XCTAssertEqual(arrow.end(near: CGPoint(x: 405, y: 302), tolerance: 10), 1)
        XCTAssertEqual(arrow.end(near: CGPoint(x: 98, y: 300), tolerance: 10), 0)
        XCTAssertNil(arrow.end(near: CGPoint(x: 250, y: 300), tolerance: 10), "the middle is not an end")
        // Pointing right, the label goes right of the tip with its left edge on it.
        let anchor = arrow.calloutAnchor(end: 1)
        XCTAssertEqual(anchor, CGPoint(x: 0, y: 0.5))
        let blank = Mark(tool: .text, color: arrow.color, start: .zero, end: .zero, text: "Here")
        let label = Renderer.pinned(blank, at: arrow.end, anchor: anchor, imageWidth: 1000)
        let r = Renderer.textOrStepRect(label, imageWidth: 1000)
        XCTAssertEqual(r.minX, 400, accuracy: 0.001)
        XCTAssertEqual(r.midY, 300, accuracy: 0.001)
        let before = doc.revision
        doc.addCallout(label, arrow: arrow.id, end: 1, anchor: anchor)
        XCTAssertEqual(doc.revision, before + 1, "label and attachment are one undo step")
        XCTAssertEqual(doc.marks.first!.endBinding?.id, label.id)
        // Moving the label drags the arrow's tip with it.
        doc.update(label.offset(by: CGVector(dx: 30, dy: 40)))
        XCTAssertEqual(doc.marks.first!.end.x, 430, accuracy: 0.001)
        XCTAssertEqual(doc.marks.first!.end.y, 340, accuracy: 0.001)
        doc.undo(); doc.undo()
        XCTAssertEqual(doc.marks.map(\.id), [arrow.id])
        XCTAssertNil(doc.marks.first!.endBinding)
        // Pointing down, the label hangs below the tip; the tail of an upward arrow is the same.
        let down = Mark(tool: .arrow, color: RGBA.palette[0], start: CGPoint(x: 100, y: 500), end: CGPoint(x: 110, y: 200))
        XCTAssertEqual(down.calloutAnchor(end: 1), CGPoint(x: 0.5, y: 1))
        XCTAssertEqual(down.calloutAnchor(end: 0), CGPoint(x: 0.5, y: 0))
    }

    func testArrowLabelsSitOnTheMiddleOfTheCurve() throws {
        let doc = Document(image: solidImage(1000, 600, gray: 0.8))
        var arrow = Mark(tool: .arrow, color: RGBA.palette[2], start: CGPoint(x: 100, y: 300), end: CGPoint(x: 700, y: 300))
        arrow.bend = -120
        XCTAssertNil(Renderer.arrowLabel(of: arrow, imageWidth: 1000))
        arrow.text = "Step two"
        doc.add(arrow)
        let label = try XCTUnwrap(Renderer.arrowLabel(of: arrow, imageWidth: 1000))
        let r = Renderer.textOrStepRect(label, imageWidth: 1000)
        XCTAssertEqual(r.midX, 400, accuracy: 0.5)
        XCTAssertEqual(r.midY, 180, accuracy: 0.5)
        XCTAssertEqual(doc.hitTest(CGPoint(x: r.minX + 3, y: r.maxY - 3), tolerance: 0)?.id, arrow.id, "the label is part of the arrow")
        XCTAssertTrue(Renderer.extent(of: arrow, imageWidth: 1000).contains(r))
        // The middle handle sits just outside the label, and dragging it moves the curve by as much.
        let h = Renderer.handles(of: arrow, imageWidth: 1000)[2]
        XCTAssertEqual(h.x, 400, accuracy: 0.5)
        XCTAssertLessThan(h.y, r.minY)
        let dragged = Renderer.moving(arrow, handle: 2, to: CGPoint(x: h.x, y: h.y - 30), imageWidth: 1000)
        XCTAssertEqual(dragged.bend, arrow.bend - 30, accuracy: 0.001)
        // Dragged across to the other side, the handle stays under the pointer there.
        let other = CGPoint(x: 400, y: 600)
        let flipped = Renderer.moving(arrow, handle: 2, to: other, imageWidth: 1000)
        XCTAssertGreaterThan(flipped.bend, 0)
        XCTAssertEqual(Renderer.handles(of: flipped, imageWidth: 1000)[2].y, other.y, accuracy: 0.5)
        let flat = try XCTUnwrap(Renderer.flatten(doc))
        let fill = pixel(flat, Int(r.minX + 4), Int(r.midY))
        XCTAssertGreaterThan(Int(fill.2), Int(fill.0) + 60, "the label is a pill in the arrow's color")
    }

    /// Stretching an edge with detail on it streaks every line that touches it across the new space.
    func testDetailedEdgesFillWithTheirColorInsteadOfStreaking() throws {
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // A vertical gradient (smooth on the left and right edges) with a red line touching the left edge.
        for y in 0..<100 {
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.2 + CGFloat(y) / 400, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: 200, height: 1))
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 40, width: 120, height: 2))
        // A wide band on the top of the right edge, like a title bar, which should carry on.
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 150, y: 80, width: 50, height: 20))
        let doc = Document(image: ctx.makeImage()!)
        doc.add(Mark(tool: .box, color: RGBA.palette[3], start: CGPoint(x: -80, y: 70), end: CGPoint(x: -40, y: 90)))
        doc.add(Mark(tool: .box, color: RGBA.palette[3], start: CGPoint(x: 240, y: 70), end: CGPoint(x: 280, y: 90)))
        let flat = try XCTUnwrap(Renderer.flatten(doc))
        let grownLeft = pixel(flat, 5, 40)
        XCTAssertLessThan(Int(grownLeft.0), 100, "no red streak runs into the new space")
        XCTAssertEqual(Int(grownLeft.1), Int(pixel(flat, 5, 39).1), accuracy: 3, "the gradient carries on through it")
        // On the right the gradient carries on: the grown pixels match the edge's at the same height.
        let x = flat.width - 3, edgeX = Int(199 - doc.canvas.minX)
        XCTAssertEqual(Int(pixel(flat, x, 10).1), Int(pixel(flat, edgeX, 10).1), accuracy: 2)
        XCTAssertNotEqual(Int(pixel(flat, x, 10).1), Int(pixel(flat, x, 60).1), "still a gradient, not one color")
        XCTAssertEqual(Int(pixel(flat, x, 90).0), 230, accuracy: 2, "the wide band carries on too")
    }

    /// The line must reach the arrowhead's notch on any length of curve, not stop a sample short.
    func testLongCurvesMeetTheirHead() {
        let arrow = Mark(tool: .arrow, color: RGBA.palette[0], start: CGPoint(x: 0, y: 0), end: CGPoint(x: 2000, y: 0), bend: 200)
        let t = arrow.parameter(atDistance: 49.7, fromEnd: true)
        let q = arrow.point(at: t)
        XCTAssertEqual(hypot(q.x - 2000, q.y), 49.7, accuracy: 0.01)
        XCTAssertEqual(arrow.parameter(atDistance: 5000, fromEnd: true), 0, "shorter than the head")
    }

    /// 2026-10-14: a pen stroke past the left edge of a terminal capture smeared a 14-pixel gray bar
    /// (a cut-off line of text) across the whole grown area. A band in the middle of an edge that is
    /// shorter than a line of text is content, so the grown area keeps the background there.
    func testCutContentInTheMiddleOfAnEdgeDoesNotStreak() throws {
        let ctx = CGContext(data: nil, width: 400, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.1, blue: 0.11, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 320))
        ctx.setFillColor(CGColor(srgbRed: 0.73, green: 0.71, blue: 0.73, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 150, width: 60, height: 14))
        let doc = Document(image: ctx.makeImage()!, dpi: 144)
        doc.add(Mark.stroke([CGPoint(x: 100, y: 100), CGPoint(x: -150, y: 160)], color: RGBA.palette[0], size: .medium))
        let flat = try XCTUnwrap(Renderer.flatten(doc))
        // The bar's middle row, in the grown area well clear of the stroke.
        let row = Int(157 - doc.canvas.minY)
        XCTAssertLessThan(Int(pixel(flat, 3, row).0), 60, "the bar doesn't streak into the new space")
        XCTAssertGreaterThan(Int(pixel(flat, Int(-doc.canvas.minX) + 5, row).0), 150, "the bar is still in the image")
    }

    /// The edges of a 144 dpi dark T3 Code capture, from the screenshot Donovan sent on 2026-10-16:
    /// row 0 is the top edge (1288 pixels), row 1 starts with the right edge (387 pixels). His red
    /// stroke crossed them; those pixels are set to the page color (33, 25, 29): top 253..<279 (page
    /// either side) and 566..<571 (in the title), right 339..<344 (page either side). Counting the 5
    /// title pixels as ink, the page is still 48% of the top edge's detail and 72% of the strip.
    func edgeFixture() throws -> (top: [UInt8], right: [UInt8]) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/edge-strips.png")
        let img = try XCTUnwrap(Renderer.loadImage(at: url))
        var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8,
                                          bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return (Array(px[0..<(1288 * 4)]), Array(px[(1288 * 4)..<((1288 + 387) * 4)]))
    }

    /// 2026-10-16: a pen stroke past the top and right of that capture. The top edge cut through a
    /// bold title, and the grown area above it became a smeared gray band; the right edge cut through
    /// dim text, and its anti-aliased tails streaked faint lines across the grown area. Both edges are
    /// text on one page color, so both must grow as that color.
    func testEdgesCutThroughTextGrowAsThePageColor() throws {
        let (top, right) = try edgeFixture()
        let page: [Int] = [33, 25, 29]
        for (name, strip) in [("top", top), ("right", right)] {
            var px = strip
            Document.removeThinRuns(&px, pixelsPerPoint: 2)
            let off = stride(from: 0, to: px.count, by: 4).filter { i in (0..<3).contains { abs(Int(px[i + $0]) - page[$0]) > 3 } }
            XCTAssertEqual(off.count, 0, "\(name) edge: \(off.count) pixels aren't the page color, first at \(off.first.map { $0 / 4 } ?? -1)")
        }
        // The whole path: a capture with those edges, and a stroke past its top and right.
        let w = 1288, h = 387
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4] = 33; px[i * 4 + 1] = 25; px[i * 4 + 2] = 29; px[i * 4 + 3] = 255 }
        for x in 0..<w { for c in 0..<4 { px[x * 4 + c] = top[x * 4 + c] } }
        for y in 0..<h { for c in 0..<4 { px[(y * w + w - 1) * 4 + c] = right[y * 4 + c] } }
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let doc = Document(image: try XCTUnwrap(ctx.makeImage()), dpi: 144)
        doc.add(Mark.stroke([CGPoint(x: 100, y: 200), CGPoint(x: 100, y: 900), CGPoint(x: 1900, y: 900),
                             CGPoint(x: 1900, y: 100)], color: RGBA.palette[0], size: .medium))
        let flat = try XCTUnwrap(Renderer.flatten(doc))
        let dx = Int(-doc.canvas.minX), dy = Int(-doc.canvas.minY)
        func isPage(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(flat, x + dx, y + dy)
            return abs(Int(p.0) - 33) <= 3 && abs(Int(p.1) - 25) <= 3 && abs(Int(p.2) - 29) <= 3
        }
        for x in stride(from: 300, to: 1200, by: 7) { XCTAssertTrue(isPage(x, h + 200), "above the title, x \(x)") }
        // Image rows 44 to 59 from the top hold the dim text's tails.
        for y in (h - 60)...(h - 44) { XCTAssertTrue(isPage(w + 200, y), "right of the dim text, row \(h - 1 - y)") }
    }

    /// A faint mark inside a band takes the band's color, and a gradient carries on through it.
    func testFaintMarksInsideABandBlendIntoIt() {
        var px: [UInt8] = []
        for i in 0..<300 {
            let v = UInt8(100 + i / 6 + ((150..<153).contains(i) ? 9 : 0))
            px += [v, v, v, 255]
        }
        Document.removeThinRuns(&px, pixelsPerPoint: 2)
        for i in 140..<165 { XCTAssertEqual(Int(px[i * 4]), 100 + i / 6, accuracy: 1, "pixel \(i)") }
        XCTAssertEqual(px[0], 100, "the gradient's ends are untouched")
        XCTAssertEqual(px[299 * 4], 149)
    }

    /// A dark toolbar at the end of an edge, too close to the page's color to split from it and
    /// shorter than half a line of text, still carries on.
    func testShortFaintEndBandsCarryOn() {
        var px: [UInt8] = []
        for i in 0..<524 { let v: UInt8 = i < 24 ? 40 : 33; px += [v, v, v, 255] }
        Document.removeThinRuns(&px, pixelsPerPoint: 2)
        XCTAssertEqual(px[10 * 4], 40, "the toolbar")
        XCTAssertEqual(px[300 * 4], 33, "the page")
    }

    /// The same toolbar behind a 1-pixel window border still carries on, and the border takes its color.
    func testShortFaintEndBandsCarryOnPastABorder() {
        var px: [UInt8] = []
        for i in 0..<524 { let v: UInt8 = i == 0 ? 255 : i < 24 ? 40 : 33; px += [v, v, v, 255] }
        Document.removeThinRuns(&px, pixelsPerPoint: 2)
        XCTAssertEqual(px[0], 40, "the border")
        XCTAssertEqual(px[10 * 4], 40, "the toolbar")
        XCTAssertEqual(px[300 * 4], 33, "the page")
    }

    /// A toolbar under a title bar, each close to the next in color, carries on between them.
    func testAFaintToolbarBetweenTwoBandsCarriesOn() {
        var px: [UInt8] = []
        for i in 0..<524 { let v: UInt8 = i < 56 ? 40 : i < 80 ? 44 : 33; px += [v, v, v, 255] }
        Document.removeThinRuns(&px, pixelsPerPoint: 2)
        XCTAssertEqual(px[20 * 4], 40, "the title bar")
        XCTAssertTrue((56..<80).allSatisfy { px[$0 * 4] == 44 }, "the toolbar")
    }

    /// A glyph cut at the very start of an edge doesn't leave its faint edge streaking there.
    func testAGlyphAtTheStartOfAnEdgeLeavesNoFaintTail() {
        var px: [UInt8] = []
        for i in 0..<500 { let v: UInt8 = i < 4 ? 200 : i < 8 ? 40 : 33; px += [v, v, v, 255] }
        Document.removeThinRuns(&px, pixelsPerPoint: 2)
        XCTAssertTrue((0..<500).allSatisfy { px[$0 * 4] == 33 })
    }

    /// Dim text cut less than half a line from either end of the edge goes too.
    func testDimTextNearTheEndsOfAnEdgeGoes() {
        var px: [UInt8] = []
        for i in 0..<500 {
            let tail = [3, 6, 10, 4, 0, 8]
            let v = 33 + ((24..<40).contains(i) ? tail[(i - 24) % 6] : (460..<476).contains(i) ? tail[(i - 460) % 6] : 0)
            px += [UInt8(v), UInt8(v), UInt8(v), 255]
        }
        Document.removeThinRuns(&px, pixelsPerPoint: 2)
        XCTAssertEqual((0..<500).filter { abs(Int(px[$0 * 4]) - 33) > 2 }, [])
    }

    /// An edge down a paragraph of dim text cuts every line; none of them streaks.
    func testSeveralLinesOfDimTextInsideABandAllGo() {
        var px: [UInt8] = []
        for i in 0..<500 {
            var v = 33
            // Three lines 24 pixels tall, 12 apart, from 200: glyph tails 3 to 10 levels off the page.
            if i >= 200, i < 308, (i - 200) % 36 < 24 { v += [3, 6, 10, 4, 0, 8][(i - 200) % 6] }
            px += [UInt8(v), UInt8(v), UInt8(v), 255]
        }
        Document.removeThinRuns(&px, pixelsPerPoint: 2)
        let off = (0..<500).filter { abs(Int(px[$0 * 4]) - 33) > 2 }
        XCTAssertEqual(off, [], "pixels still off the page color")
    }

    /// A header and footer of one color covering just under half an edge, around a photo: the photo
    /// softens into its own tones instead of turning the header's color.
    func testBandColorDoesNotPaintOverAPhotoBetweenThem() {
        var px: [UInt8] = []
        for i in 0..<1000 {
            // The photo: wide swings, and 5% of it in the header's color.
            let v = i < 245 || i >= 755 ? 40 : (i % 20 == 0 ? 41 : 90 + (i * 53 % 11) * 14)
            px += [UInt8(v), UInt8(v), UInt8(v), 255]
        }
        Document.removeThinRuns(&px)
        XCTAssertEqual(px[100 * 4], 40, "the header stays")
        XCTAssertGreaterThan(Int(px[500 * 4]), 80, "the photo isn't painted the header's color")
        // The same, with the header's color the photo's most common one, at 12% of it.
        px = []
        for i in 0..<1000 {
            let v = i < 245 || i >= 755 ? 40 : (i % 8 == 0 ? 41 : 90 + (i * 53 % 11) * 14)
            px += [UInt8(v), UInt8(v), UInt8(v), 255]
        }
        Document.removeThinRuns(&px)
        XCTAssertGreaterThan(Int(px[501 * 4]), 80, "still blurred, not the header's color")
    }

    /// When two colors tie for the most common in the detail, the result doesn't depend on which one
    /// a dictionary happens to list first, so the same screenshot grows the same way every time.
    func testTiedDetailColorsGrowTheSameEveryTime() {
        var px: [UInt8] = []
        for i in 0..<200 { let v: UInt8 = i < 90 ? 33 : i >= 196 ? 120 : (i % 2 == 0 ? 200 : 33); px += [v, v, v, 255] }
        Document.removeThinRuns(&px)
        XCTAssertTrue((90..<200).allSatisfy { px[$0 * 4] == 33 }, "the page color, which most of the strip shares")
    }

    /// An edge with no clear color (a photo, noise) continues its own tones, softened, instead of
    /// whichever shade happened to be most common.
    func testBusyEdgesWithNoClearColorBlur() {
        var px: [UInt8] = []
        // Light noise over the first half, dark noise over the second: no color covers half of it.
        for i in 0..<400 {
            let base = i < 200 ? 200 : 60
            let v = UInt8(base + (i * 37 % 7) * 9 - 27)
            px += [v, v, v, 255]
        }
        Document.removeThinRuns(&px)
        XCTAssertEqual(Int(px[20 * 4]), 200, accuracy: 15, "the light part stays light")
        XCTAssertEqual(Int(px[380 * 4]), 60, accuracy: 15, "the dark part stays dark")
        XCTAssertLessThan(abs(Int(px[100 * 4]) - Int(px[101 * 4])), 6, "and smooth, not noisy")
    }

    /// Text down the middle of an edge with a title bar at its end: the title bar carries on and
    /// the rest takes the page color, not the title bar's.
    func testDetailedEdgesKeepEndBandsAndTakeThePageColor() {
        var px: [UInt8] = []
        for i in 0..<600 {
            let v: UInt8 = i < 56 ? 120 : (i % 24 < 6 ? 10 : 250)
            px += [v, v, v, 255]
        }
        Document.removeThinRuns(&px, pixelsPerPoint: 2)
        XCTAssertEqual(px[20 * 4], 120, "title bar")
        XCTAssertTrue((56..<600).allSatisfy { px[$0 * 4] == 250 }, "page color below it")
    }

    /// Corners continue the strips that meet there: a title bar's color, not the page's.
    func testCornersTakeTheColorWhereTheirStripsMeet() throws {
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 80, width: 200, height: 20))
        let doc = Document(image: ctx.makeImage()!)
        XCTAssertEqual(doc.cornerColors[2].r, 0.5, accuracy: 0.02, "top-left")
        XCTAssertEqual(doc.cornerColors[0].r, 1, accuracy: 0.02, "bottom-left")
        doc.add(Mark(tool: .box, color: RGBA.palette[0], start: CGPoint(x: -60, y: 120), end: CGPoint(x: -40, y: 140)))
        let flat = try XCTUnwrap(Renderer.flatten(doc))
        XCTAssertEqual(Int(pixel(flat, 2, flat.height - 3).0), 128, accuracy: 3, "the grown top-left corner")
    }

    /// An edge with no wide band (say, through a column of text) becomes one plain color.
    func testAllDetailEdgesBecomeOneColor() {
        var px: [UInt8] = []
        for i in 0..<200 { px += i % 8 < 5 ? [240, 240, 240, 255] : [20, 20, 20, 255] }
        Document.removeThinRuns(&px)
        XCTAssertTrue(stride(from: 0, to: px.count, by: 4).allSatisfy { px[$0] == 240 })
    }

    func testPenStrokesDrawHitMoveAndGrowTheCanvas() throws {
        let doc = Document(image: solidImage(400, 300, gray: 0.8))
        let pts = (0...40).map { CGPoint(x: 50 + CGFloat($0) * 5, y: 150 + 40 * sin(CGFloat($0) / 6)) }
        let stroke = Mark.stroke(pts, color: RGBA.palette[2], size: .medium)
        doc.add(stroke)
        XCTAssertEqual(stroke.start, pts.first)
        XCTAssertEqual(stroke.end, pts.last)
        XCTAssertEqual(doc.hitTest(pts[20], tolerance: 0)?.id, stroke.id, "the line itself is hit")
        XCTAssertNil(doc.hitTest(CGPoint(x: 150, y: 260), tolerance: 6))
        let moved = stroke.offset(by: CGVector(dx: 10, dy: -5))
        XCTAssertEqual(moved.points[7], CGPoint(x: pts[7].x + 10, y: pts[7].y - 5), "moving moves every point")
        XCTAssertEqual(stroke.duplicate(offset: 4).points.count, pts.count)
        let flat = try XCTUnwrap(Renderer.flatten(doc))
        let on = pixel(flat, Int(pts[20].x), Int(pts[20].y))
        XCTAssertGreaterThan(Int(on.2), Int(on.0) + 60, "drawn in the pen's blue")
        // A stroke past the edge grows the canvas like any mark.
        doc.add(Mark.stroke([CGPoint(x: 380, y: 100), CGPoint(x: 460, y: 120)], color: RGBA.palette[0], size: .medium))
        XCTAssertGreaterThan(doc.canvas.maxX, 460)
        // A tap is a dot.
        XCTAssertEqual(doc.hitTest(CGPoint(x: 20, y: 20), tolerance: 0)?.id, nil)
        doc.add(Mark.stroke([CGPoint(x: 20, y: 20)], color: RGBA.palette[0], size: .medium))
        XCTAssertEqual(doc.hitTest(CGPoint(x: 21, y: 20), tolerance: 0)?.tool, .pen)
    }

    func testPenPressureSetsTheWidth() {
        let w: CGFloat = 10
        XCTAssertLessThan(Renderer.penWidth(w, pressure: 0.1), w * 0.5, "a light touch draws thin")
        XCTAssertEqual(Renderer.penWidth(w, pressure: 0.6), w, accuracy: 0.01)
        XCTAssertGreaterThan(Renderer.penWidth(w, pressure: 1), w * 1.4)
        XCTAssertEqual(Renderer.penWidth(w, pressure: 3), Renderer.penWidth(w, pressure: 1), "clamped")
    }

    /// Holding the pen still turns a rough stroke into the shape it was meant to be.
    func testHeldStrokesBecomeShapes() {
        // A wobbly line.
        // A shaky line: the jitter adds a tenth to its length, but it never leaves the line.
        let line = (0...30).map { CGPoint(x: CGFloat($0) * 8, y: 100 + ($0 % 2 == 0 ? 2 : -2)) }
        XCTAssertEqual(Ink.shape(of: line), .line(line.first!, line.last!))
        // A rough circle that doesn't quite close.
        let circle = (0..<34).map { i -> CGPoint in
            let a: CGFloat = CGFloat(i) / 36 * 2 * .pi
            let r: CGFloat = i % 3 == 0 ? 104 : 97
            return CGPoint(x: 200 + cos(a) * r, y: 200 + sin(a) * r)
        }
        guard case .ellipse(let r)? = Ink.shape(of: circle) else { return XCTFail("a circle is an ellipse") }
        XCTAssertEqual(r.midX, 200, accuracy: 8)
        XCTAssertEqual(r.width, 205, accuracy: 15)
        // A rough rectangle, corner to corner and back.
        var rect: [CGPoint] = []
        for x in stride(from: 0, through: 300, by: 10) { rect.append(CGPoint(x: CGFloat(x), y: 2)) }
        for y in stride(from: 0, through: 150, by: 10) { rect.append(CGPoint(x: 298, y: CGFloat(y))) }
        for x in stride(from: 300, through: 0, by: -10) { rect.append(CGPoint(x: CGFloat(x), y: 151)) }
        for y in stride(from: 150, through: 20, by: -10) { rect.append(CGPoint(x: 1, y: CGFloat(y))) }
        guard case .box? = Ink.shape(of: rect) else { return XCTFail("a rectangle is a box") }
        // A scribble or an open curve stays as drawn.
        let squiggle = (0...40).map { CGPoint(x: CGFloat($0) * 6, y: 100 + 60 * sin(CGFloat($0) / 3)) }
        XCTAssertNil(Ink.shape(of: squiggle))
        XCTAssertNil(Ink.shape(of: [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 1), CGPoint(x: 3, y: 3)]), "too small to guess")
    }
}
