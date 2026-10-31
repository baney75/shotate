import CoreGraphics
import XCTest
@testable import ShotateCore

final class DebugReportTests: XCTestCase {
    /// A trimmed copy of a real ⇧⌘D log of T3 Code (2026-10-31): almost all of it macOS housekeeping.
    let log = """
    # Log of T3 Code (Nightly) (com.t3tools.t3code, pid 53933) while Shotate recorded it, from 2026-10-31T14:16:33-04:00.
    Filtering the log data using "processImagePath BEGINSWITH "/Applications/T3 Code (Nightly).app/""
    Timestamp               Ty Process[PID:TID]
    2026-10-31 14:16:33.813 I  T3 Code (Nightly)[53933:33fdcc6] [com.apple.AppKit:WindowSharing] Window ea7c selective sharing changed
    2026-10-31 14:16:33.827 F  T3 Code (Nightly)[53933:33fdcc6] [com.apple.runtime-issues:AppKit] Invalid view geometry: width is negative.
    2026-10-31 14:16:33.828 F  T3 Code (Nightly)[53933:33fdcc7] [com.apple.runtime-issues:AppKit] Invalid view geometry: width is negative.
    2026-10-31 14:16:33.829 Db T3 Code (Nightly)[53933:9253a88] [com.apple.xpc.transaction:all] transaction begin
    2026-10-31 14:16:33.830 Db T3 Code (Nightly)[53933:9253a88] [com.apple.xpc.transaction:all] transaction end
    2026-10-31 14:16:33.831 Df T3 Code (Nightly)[53933:9253a88] [com.apple.launchservices:cas] lookup
        contentsMask: 0x2; deferringRules: [[53933-18BA]];
    }
    2026-10-31 14:16:33.900 Df T3 Code (Nightly)[53933:9253a88] [com.t3tools.t3code:sync] Thread sync failed: 409
    2026-10-31 14:16:33.936 A  T3 Code (Nightly)[53933:924ff64] (CoreSpotlight) end-index-batch
    2026-10-31 14:16:34.001 Df T3 Code (Nightly)[53933:924ff64] (T3 Code (Nightly)) renderer ready
    2026-10-31 14:16:34.002 E  T3 Code Helper[53935:1] [com.apple.network:path] nw_path no route
    """

    func testDigestKeepsErrorsAndTheAppsOwnLinesAndFoldsRepeats() {
        let d = LogDigest.parse(log, ownImages: ["T3 Code (Nightly)"])
        XCTAssertEqual(d.total, 10)
        let texts = d.entries.map(\.text)
        XCTAssertEqual(d.entries.count, 4, texts.joined(separator: "\n"))
        XCTAssertEqual(d.entries.first?.count, 2, "the repeated fault folds into one line")
        XCTAssertTrue(texts.contains { $0.contains("Thread sync failed") })
        XCTAssertTrue(texts.contains { $0.contains("renderer ready") })
        XCTAssertTrue(texts.contains { $0.contains("nw_path no route") })
        XCTAssertFalse(texts.contains { $0.contains("xpc.transaction") || $0.contains("launchservices") || $0.contains("CoreSpotlight") })
        XCTAssertEqual(d.errors, 3)
        let md = d.markdown()
        XCTAssertTrue(md.hasPrefix("2026-10-31 14:16:33.827 F "), "errors come first")
        XCTAssertTrue(md.contains("(×2)"))
    }

    func testDigestMarkdownStaysWithinItsLimit() {
        let lines = (0..<500).map { "2026-10-31 14:16:33.\(String(format: "%03d", $0)) E  App[1:2] [com.x:y] failure number \($0)" }
        let d = LogDigest.parse(lines.joined(separator: "\n"))
        let md = d.markdown(limit: 2000)
        XCTAssertLessThanOrEqual(md.count, 2100)
        XCTAssertTrue(md.hasSuffix("more in the full log.\n"))
    }

    func testExcerptPutsTroubleBeforeTheTail() {
        let lines = (0..<100).map { $0 == 10 ? "{\"level\":\"error\",\"msg\":\"socket closed\"}" : "ok \($0)" }
        let e = LogExcerpt.excerpt(lines.joined(separator: "\n"), tailLines: 5)
        XCTAssertTrue(e.hasPrefix("Errors and warnings before the last 5 lines:\n{\"level\":\"error\""))
        XCTAssertTrue(e.hasSuffix("ok 95\nok 96\nok 97\nok 98\nok 99"))
        XCTAssertEqual(LogExcerpt.excerpt("a\nb"), "a\nb")
    }

    func testReportNamesEverythingAnAgentNeeds() {
        var r = DebugReport(appName: "T3 Code (Nightly)", bundleID: "com.t3tools.t3code", version: "0.9.1", pid: 53933,
                            started: Date(timeIntervalSince1970: 1_800_000_000), duration: 42.4,
                            folder: "/tmp/Rec", video: "/tmp/Rec/Rec.mp4", macOS: "27.2.0")
        r.videoSize = (2880, 1800)
        r.stills = [(0.3, "/tmp/Rec/stills/0-00.3.png"), (12.6, "/tmp/Rec/stills/0-12.6.png")]
        r.systemLog = "/tmp/Rec/system.log"
        r.digest = LogDigest.parse(log)
        r.appLogs = [.init(path: "/tmp/logs/server.log", added: 4096, excerpt: "boom")]
        r.crashReports = ["/Users/x/Library/Logs/DiagnosticReports/T3 Code-2026.ips"]
        let md = r.markdown()
        XCTAssertTrue(md.hasPrefix("# T3 Code (Nightly): screen recording with debug logs\n"))
        for s in ["for 0:42", "com.t3tools.t3code, version 0.9.1, pid 53933", "`/tmp/Rec/Rec.mp4` (2880×1800)",
                  "0:12.6 `/tmp/Rec/stills/0-12.6.png`", "Full system log: `/tmp/Rec/system.log`", "## Crash reports",
                  "## /tmp/logs/server.log (+4 KB)", "```\nboom\n```", "## System log, filtered", "routine macOS entries"] {
            XCTAssertTrue(md.contains(s), "missing \(s)\n\(md)")
        }
        XCTAssertFalse(md.contains("wrote no log files"))
        r.appLogs = []
        r.systemLogError = "Must be admin to run 'stream' command"
        let failed = r.markdown()
        XCTAssertTrue(failed.contains("macOS wouldn't give Shotate the log: Must be admin"))
        XCTAssertTrue(failed.contains("`appLogs` in ~/.config/shotate/config.json"))
        XCTAssertLessThanOrEqual(r.markdown(limit: 300).count, 360)
    }

    func testStillTimesNeverRoundIntoTheNextSecond() {
        XCTAssertEqual(DebugReport.preciseClock(2.8), "0:02.8")
        XCTAssertEqual(DebugReport.preciseClock(59.97), "0:59.9")
        XCTAssertEqual(DebugReport.preciseClock(61.25), "1:01.2")
    }

    func testMarkSpecReadsTopLeftPixels() throws {
        let json = """
        [{"tool": "box", "rect": [10, 20, 100, 50], "color": "blue"},
         {"tool": "arrow", "from": [0, 0], "to": [50, 60], "text": "Here"},
         {"tool": "step", "at": [5, 5]}, {"tool": "step", "at": [9, 9]},
         {"tool": "text", "at": [1, 2], "text": "Hi", "width": 80},
         {"tool": "pen", "points": [[0, 0], [10, 10]], "size": "thick"}]
        """
        let marks = try MarkSpec.marks(from: Data(json.utf8), imageHeight: 300)
        XCTAssertEqual(marks.map(\.tool), [.box, .arrow, .step, .step, .text, .pen])
        XCTAssertEqual(marks[0].start, CGPoint(x: 10, y: 280))
        XCTAssertEqual(marks[0].end, CGPoint(x: 110, y: 230))
        XCTAssertEqual(marks[0].color, RGBA.palette[2])
        XCTAssertEqual(marks[1].end, CGPoint(x: 50, y: 240))
        XCTAssertEqual(marks[1].text, "Here")
        XCTAssertEqual(marks[4].textWidth, 80)
        XCTAssertThrowsError(try MarkSpec.marks(from: Data("[{\"tool\": \"crop\"}]".utf8), imageHeight: 10))
        XCTAssertThrowsError(try MarkSpec.marks(from: Data("[{\"tool\": \"box\", \"rect\": [1, 2]}]".utf8), imageHeight: 10))
        XCTAssertThrowsError(try MarkSpec.marks(from: Data("[{\"tool\": \"box\", \"rect\": [1,2,3,4], \"color\": \"teal\"}]".utf8), imageHeight: 10))
        // Steps number themselves once added.
        let doc = Document(image: ShotateCoreTests().solidImage())
        for m in marks { doc.add(m) }
        XCTAssertEqual(doc.marks.filter { $0.tool == .step }.map(\.number), [1, 2])
    }

    func testAgentSettingsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotate-\(UUID().uuidString)/config.json")
        var s = Settings()
        XCTAssertFalse(s.agentControl, "off unless the user turns it on")
        s.agentControl = true
        s.appLogs = ["com.t3tools.t3code": ["~/.t3/userdata/logs"]]
        try s.save(to: url)
        let back = try Settings.load(from: url)
        XCTAssertTrue(back.agentControl)
        XCTAssertEqual(back.appLogs, s.appLogs)
        try Data(#"{"appLogs": {"x": "~/logs"}}"#.utf8).write(to: url)
        XCTAssertEqual(try Settings.load(from: url).appLogs, ["x": ["~/logs"]], "a single folder may be a string")
    }
}
