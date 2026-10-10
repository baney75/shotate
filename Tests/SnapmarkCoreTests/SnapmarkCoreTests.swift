import CoreGraphics
import XCTest
@testable import SnapmarkCore

final class SnapmarkCoreTests: XCTestCase {
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

    func tempConfig() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("snapmark-\(UUID().uuidString)/config.json")
    }

    func testConfigFileRoundTrips() throws {
        let url = tempConfig()
        var s = Settings(saveFolder: URL(fileURLWithPath: "/tmp/snapmark-\(UUID().uuidString)-missing", isDirectory: true))
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

    func testMigratesOldDefaults() {
        let d = UserDefaults(suiteName: "snapmark-test-\(UUID().uuidString)")!
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapmark-test-\(UUID().uuidString).png")
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
}
