import XCTest
@testable import ShotateCore

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
        XCTAssertEqual(stop(active: true, any: true), .stop)
        XCTAssertEqual(stop(active: true, unclaimed: true, any: true), .stop, "asked to stop the user's: do that")
        XCTAssertEqual(stop(saving: true, any: true), .waitForSave)
        // The agent's recording.
        XCTAssertEqual(stop(active: true, agent: true), .stop)
        XCTAssertEqual(stop(saving: true, agent: true), .waitForSave)
        // Nothing running.
        XCTAssertEqual(stop(), .nothingRecording)
        XCTAssertEqual(stop(unclaimed: true), .returnUnclaimed)
    }
}
