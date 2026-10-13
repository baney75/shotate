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

    func testOnlyScreenshotsWithinThreeSecondsOfEachOtherAreAChoice() {
        var p = PasteChoices()
        p.copied(a, at: t0)
        p.copied(b, at: t0 + 2.5)
        p.copied(c, at: t0 + 5)
        XCTAssertEqual(p.entries.map(\.file), [c, b, a], "each within 3 s of the one before")
        p.copied(b, at: t0 + 20)
        XCTAssertEqual(p.entries.map(\.file), [b, c, a], "copying one again from its editor keeps the batch")
        let d = URL(fileURLWithPath: "/tmp/d.png")
        p.copied(d, at: t0 + 24)
        XCTAssertEqual(p.entries.map(\.file), [d], "a new screenshot 4 s later starts over")
        XCTAssertFalse(p.shouldAsk(enabled: true, clipboardIsOurs: true))
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
        p.copied(b, at: t0 + 2)
        p.copied(c, at: t0 + 4)
        p.prune(now: t0 + 2 + PasteChoices.maxAge - 1) { $0 != c }
        XCTAssertEqual(p.entries.map(\.file), [b], "a too old, c deleted")
    }

    func testTheChoiceClearsAfterAMinute() {
        var p = PasteChoices()
        p.copied(a, at: t0)
        p.copied(b, at: t0 + 1)
        p.prune(now: t0 + 59) { _ in true }
        XCTAssertTrue(p.shouldAsk(enabled: true, clipboardIsOurs: true), "still a choice within the minute")
        p.prune(now: t0 + 62) { _ in true }
        XCTAssertFalse(p.shouldAsk(enabled: true, clipboardIsOurs: true), "after a minute ⌘V pastes as usual")
    }

    func testKeepsNineAtMost() {
        var p = PasteChoices()
        for i in 0..<12 { p.copied(URL(fileURLWithPath: "/tmp/\(i).png"), at: t0 + Double(i) * 2) }
        XCTAssertEqual(p.entries.count, PasteChoices.maxCount)
        XCTAssertEqual(p.entries.first?.file.lastPathComponent, "11.png")
    }

    func testACopyAgainKeepsItsPastedMark() {
        var p = PasteChoices()
        p.copied(a, at: t0)
        p.markPasted(a)
        p.copied(a, at: t0 + 1)
        XCTAssertTrue(p.entries[0].pasted)
    }

    func testANewScreenshotAfterACopyAgainIsJudgedByWhenTheOthersWereTaken() {
        var p = PasteChoices()
        p.copied(a, at: t0)
        p.copied(b, at: t0 + 2)
        p.copied(a, at: t0 + 30)  // Return in its editor, much later
        p.copied(c, at: t0 + 31)  // taken 29 s after b: a new batch
        XCTAssertEqual(p.entries.map(\.file), [c])
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
