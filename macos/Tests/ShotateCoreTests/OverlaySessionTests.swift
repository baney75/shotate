import XCTest
@testable import ShotateCore

final class OverlaySessionTests: XCTestCase {
    func testDismissViaEscapeCloseButtonHotkeyAndSystemEvents() {
        let reasons: [OverlaySession<String>.DismissReason] = [
            .escape, .closeButton, .hotkey, .rightClick, .focusLost, .systemEvent, .replaced,
        ]
        for reason in reasons {
            var escapeHistory: [Bool] = []
            var tearDownCount = 0
            var outcomes: [String?] = []

            let session = OverlaySession<String>(
                claimEscape: { escapeHistory.append($0) },
                tearDown: { tearDownCount += 1 },
                completion: { outcomes.append($0) }
            )
            session.begin()
            XCTAssertTrue(session.isActive)
            XCTAssertTrue(session.escapeClaimed)
            XCTAssertEqual(escapeHistory, [true])

            XCTAssertTrue(session.dismiss(reason))
            XCTAssertFalse(session.isActive)
            XCTAssertFalse(session.escapeClaimed)
            XCTAssertEqual(session.lastDismissReason, reason)
            XCTAssertEqual(escapeHistory, [true, false])
            XCTAssertEqual(tearDownCount, 1)
            XCTAssertEqual(outcomes.count, 1)
            XCTAssertNil(outcomes[0])

            // Repeated dismiss calls are idempotent and never double-fire teardown or completion.
            XCTAssertFalse(session.dismiss(.escape))
            XCTAssertEqual(tearDownCount, 1)
            XCTAssertEqual(outcomes.count, 1)
        }
    }

    func testCompleteRunsCleanupAndBlocksLaterDismiss() {
        var escapeHistory: [Bool] = []
        var tearDownCount = 0
        var result: Int? = -1

        let session = OverlaySession<Int>(
            claimEscape: { escapeHistory.append($0) },
            tearDown: { tearDownCount += 1 },
            completion: { result = $0 }
        )
        session.begin()
        XCTAssertTrue(session.complete(42))
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.escapeClaimed)
        XCTAssertEqual(session.lastDismissReason, .completed)
        XCTAssertEqual(escapeHistory, [true, false])
        XCTAssertEqual(tearDownCount, 1)
        XCTAssertEqual(result, 42)

        XCTAssertFalse(session.dismiss(.closeButton))
        XCTAssertEqual(tearDownCount, 1)
        XCTAssertEqual(result, 42)
    }

    func testDeinitNeverLeavesEscapeClaimedOrContinuationHung() {
        var escapeHistory: [Bool] = []
        var tearDownCount = 0
        var completed = false
        var received: String? = "unset"

        do {
            let session = OverlaySession<String>(
                claimEscape: { escapeHistory.append($0) },
                tearDown: { tearDownCount += 1 },
                completion: {
                    completed = true
                    received = $0
                }
            )
            session.begin()
            XCTAssertTrue(session.escapeClaimed)
        }

        XCTAssertEqual(escapeHistory, [true, false])
        XCTAssertEqual(tearDownCount, 1)
        XCTAssertTrue(completed)
        XCTAssertNil(received)
    }
}
