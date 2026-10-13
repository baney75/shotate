import XCTest
@testable import ShotateCore

final class PasteChoicesTests: XCTestCase {
    let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b.png"), c = URL(fileURLWithPath: "/tmp/c.png")
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testNewestFirstAndACopyAgainMovesToTheFront() {
        var p = PasteChoices()
        p.copied(a, at: t0)
        p.copied(b, at: t0 + 1)
        p.copied(a, at: t0 + 2)
        XCTAssertEqual(p.entries.map(\.file), [a, b])
    }

    func testAsksOnlyWithTwoChoicesTheSettingOnAndOurClipboard() {
        var p = PasteChoices()
        p.copied(a, at: t0)
        XCTAssertFalse(p.shouldAsk(enabled: true, clipboardIsOurs: true))
        p.copied(b, at: t0 + 1)
        XCTAssertTrue(p.shouldAsk(enabled: true, clipboardIsOurs: true))
        XCTAssertFalse(p.shouldAsk(enabled: false, clipboardIsOurs: true))
        XCTAssertFalse(p.shouldAsk(enabled: true, clipboardIsOurs: false))
    }

    func testOldScreenshotsAndDeletedFilesDropOff() {
        var p = PasteChoices()
        p.copied(a, at: t0)
        p.copied(b, at: t0 + PasteChoices.maxAge - 10)
        p.copied(c, at: t0 + PasteChoices.maxAge - 5)
        p.prune(now: t0 + PasteChoices.maxAge + 1) { $0 != c }
        XCTAssertEqual(p.entries.map(\.file), [b])
    }

    func testKeepsNineAtMost() {
        var p = PasteChoices()
        for i in 0..<12 { p.copied(URL(fileURLWithPath: "/tmp/\(i).png"), at: t0 + Double(i)) }
        XCTAssertEqual(p.entries.count, PasteChoices.maxCount)
        XCTAssertEqual(p.entries.first?.file.lastPathComponent, "11.png")
    }

    func testPastedIsMarkedAndACopyAgainClearsIt() {
        var p = PasteChoices()
        p.copied(a, at: t0)
        p.markPasted(a)
        XCTAssertTrue(p.entries[0].pasted)
        p.copied(a, at: t0 + 1)
        XCTAssertFalse(p.entries[0].pasted)
    }
}

final class ChoosePasteSettingTests: XCTestCase {
    func testOffByDefaultAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotate-paste-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var s = Settings()
        XCTAssertFalse(s.choosePaste)
        s.choosePaste = true
        try s.save(to: url)
        XCTAssertTrue(try Settings.load(from: url).choosePaste)
        try Data(#"{"copyOnCapture": true}"#.utf8).write(to: url)
        XCTAssertFalse(try Settings.load(from: url).choosePaste, "a file without it keeps it off")
    }
}
