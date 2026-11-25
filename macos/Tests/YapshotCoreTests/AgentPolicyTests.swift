import XCTest
@testable import YapshotCore

final class AgentPolicyTests: XCTestCase {
    func testForNeedsAFiniteNumberOfSecondsUpToFourHours() {
        XCTAssertEqual(try AgentPolicy.recordSeconds(nil).get(), nil)
        XCTAssertEqual(try AgentPolicy.recordSeconds("20").get(), 20)
        XCTAssertEqual(try AgentPolicy.recordSeconds("0.5").get(), 0.5)
        XCTAssertEqual(try AgentPolicy.recordSeconds("14400").get(), 14400)
        // Each of these once started a recording that never stopped, or stopped at once.
        for bad in ["20s", "true", "inf", "infinity", "nan", "-5", "0", "14401", "1e300", ""] {
            XCTAssertThrowsError(try AgentPolicy.recordSeconds(bad).get(), bad)
        }
    }

    func testAnyIsOnlyOnWhenItSaysSo() {
        XCTAssertEqual(try AgentPolicy.flag("any", nil).get(), false)
        XCTAssertEqual(try AgentPolicy.flag("any", "true").get(), true, "bare --any parses as true")
        XCTAssertEqual(try AgentPolicy.flag("any", "YES").get(), true)
        XCTAssertEqual(try AgentPolicy.flag("any", "false").get(), false, "--any=false must not stop the user's recording")
        XCTAssertEqual(try AgentPolicy.flag("any", "0").get(), false)
        XCTAssertThrowsError(try AgentPolicy.flag("any", "maybe").get()) { e in
            XCTAssertEqual((e as? AgentError)?.message, "--any is a switch: --any, or --any=true or --any=false")
        }
    }

    func testStopArgumentsCantBeMisreadAsAny() {
        XCTAssertEqual(try AgentPolicy.stopArguments([]).get(), false)
        XCTAssertEqual(try AgentPolicy.stopArguments(["--any"]).get(), true)
        XCTAssertEqual(try AgentPolicy.stopArguments(["--any=false"]).get(), false)
        XCTAssertEqual(try AgentPolicy.stopArguments(["--any=yes"]).get(), true)
        // With a space, "false" used to be dropped and --any read as bare: the user's recording ended.
        for bad in [["--any", "false"], ["--any", "0"], ["--any", "no"], ["now"], ["--all"], ["--any=maybe"]] {
            XCTAssertThrowsError(try AgentPolicy.stopArguments(bad).get(), bad.joined(separator: " "))
        }
    }

    func testStopLeavesTheUsersRecordingAloneUnlessAsked() {
        func stop(active: Bool = false, saving: Bool = false, agent: Bool = false, unclaimed: Bool = false, any: Bool = false)
            -> AgentPolicy.StopAction {
            AgentPolicy.stop(active: active, saving: saving, byAgent: agent, unclaimed: unclaimed, any: any)
        }
        // The user's recording, running or saving.
        XCTAssertEqual(stop(active: true), .refuseUsers)
        XCTAssertEqual(stop(saving: true), .nothingRecording, "never queue for the user's save")
        XCTAssertEqual(stop(active: true, unclaimed: true), .returnUnclaimed, "the agent's own result first")
        XCTAssertEqual(stop(active: true, any: true), .stop(dropUnclaimed: true))
        XCTAssertEqual(stop(saving: true, any: true), .waitForSave(dropUnclaimed: true))
        // The agent's recording.
        XCTAssertEqual(stop(active: true, agent: true), .stop(dropUnclaimed: false))
        XCTAssertEqual(stop(saving: true, agent: true), .waitForSave(dropUnclaimed: false))
        XCTAssertEqual(stop(active: true, agent: true, any: true), .stop(dropUnclaimed: false))
        // Nothing running.
        XCTAssertEqual(stop(), .nothingRecording)
        XCTAssertEqual(stop(unclaimed: true), .returnUnclaimed)
    }

    // Asked to stop the user's recording while an agent result waits: the agent gets the user's
    // recording, so the old result must go, or the next plain `stop` hands it over as fresh.
    func testStopAnyOnTheUsersRunningRecordingDropsTheUnclaimedResult() {
        XCTAssertEqual(AgentPolicy.stop(active: true, saving: false, byAgent: false, unclaimed: true, any: true),
                       .stop(dropUnclaimed: true))
    }

    func testStopAnyOnTheUsersSavingRecordingDropsTheUnclaimedResult() {
        XCTAssertEqual(AgentPolicy.stop(active: false, saving: true, byAgent: false, unclaimed: true, any: true),
                       .waitForSave(dropUnclaimed: true))
    }

    // Each switch: bare is on, =false/=0/=no is off, anything else fails with flag's message.
    private func assertSwitch(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        func on(_ args: [String]) throws -> Bool {
            try AgentPolicy.switches([name], in: AgentPolicy.parse(args).options).get().contains(name)
        }
        XCTAssertEqual(try on([]), false, file: file, line: line)
        XCTAssertEqual(try on(["--\(name)"]), true, file: file, line: line)
        XCTAssertEqual(try on(["--\(name)", "out.png"]), true, "a switch never takes the next word", file: file, line: line)
        XCTAssertEqual(try on(["--\(name)=true"]), true, file: file, line: line)
        for off in ["false", "0", "no", "FALSE"] {
            XCTAssertEqual(try on(["--\(name)=\(off)"]), false, "--\(name)=\(off) must be off", file: file, line: line)
        }
        XCTAssertThrowsError(try on(["--\(name)=maybe"]), file: file, line: line) { e in
            XCTAssertEqual((e as? AgentError)?.message, "--\(name) is a switch: --\(name), or --\(name)=true or --\(name)=false",
                           file: file, line: line)
        }
    }

    func testCopyIsOffWhenItSaysFalse() { assertSwitch("copy") }
    func testEditIsOffWhenItSaysFalse() { assertSwitch("edit") }
    func testGifIsOffWhenItSaysFalse() { assertSwitch("gif") }
    func testMp4IsOffWhenItSaysFalse() { assertSwitch("mp4") }

    func testParseKeepsValuesAndPositionals() {
        let p = AgentPolicy.parse(["area", "--rect", "0,0,10,10", "--out=a.png", "--marks", "-"])
        XCTAssertEqual(p.positional, ["area"])
        XCTAssertEqual(p.options, ["rect": "0,0,10,10", "out": "a.png", "marks": "-"])
    }

    // Only the watchdog's partial save is a warning (exit 0); a kept video that may be incomplete
    // is an error (exit 1).
    func testOnlyAPartialSaveIsAWarning() {
        XCTAssertEqual(AgentPolicy.recordingProblemKey(kept: true, partial: true), "warning")
        XCTAssertEqual(AgentPolicy.recordingProblemKey(kept: true, partial: false), "error")
        XCTAssertEqual(AgentPolicy.recordingProblemKey(kept: false, partial: false), "error")
    }
}
