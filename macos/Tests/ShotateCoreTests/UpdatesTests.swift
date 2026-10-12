import XCTest
@testable import ShotateCore

final class UpdatesTests: XCTestCase {
    let day: TimeInterval = 86_400
    func manifest(_ channel: String, _ version: String, commit: String, date: Date) -> UpdateManifest {
        UpdateManifest(channel: channel, version: version, commit: commit, date: date,
                       notes: URL(string: "https://example.com")!, assets: [:])
    }
    func build(_ channel: String, _ version: String, commit: String = "aaa", date: Date) -> BuildInfo {
        BuildInfo(version: version, commit: commit, channel: channel, date: date)
    }

    func testStableOffersOnlyNewerVersions() {
        let now = Date()
        let local = build("stable", "0.12.0", date: now)
        XCTAssertEqual(Updates.offer(local: local, remote: manifest("stable", "0.12.1", commit: "b", date: now), channel: "stable"),
                       .update(manifest("stable", "0.12.1", commit: "b", date: now)))
        XCTAssertNil(Updates.offer(local: local, remote: manifest("stable", "0.12.0", commit: "b", date: now), channel: "stable"))
        XCTAssertNil(Updates.offer(local: local, remote: manifest("stable", "0.11.9", commit: "b", date: now), channel: "stable"))
        XCTAssertNil(Updates.offer(local: local, remote: manifest("stable", "0.13.0", commit: "aaa", date: now), channel: "stable"),
                     "same commit is the same build")
        XCTAssertNil(Updates.offer(local: local, remote: manifest("nightly", "0.13.0", commit: "b", date: now), channel: "stable"),
                     "a manifest from the other channel is ignored")
    }

    func testNightlyGoesByDateSoANewerStableIsNotDowngraded() {
        let now = Date()
        let local = build("nightly", "0.12.1+nightly.1", date: now)
        XCTAssertNotNil(Updates.offer(local: local, remote: manifest("nightly", "0.12.1+nightly.2", commit: "b", date: now + day),
                                      channel: "nightly"))
        XCTAssertNil(Updates.offer(local: local, remote: manifest("nightly", "0.12.1+nightly.0", commit: "b", date: now - day),
                                   channel: "nightly"))
        let stable = build("stable", "0.13.0", date: now)
        XCTAssertNil(Updates.offer(local: stable, remote: manifest("nightly", "0.12.1+nightly.0", commit: "b", date: now - day),
                                   channel: "nightly"), "a stable built after the last nightly stays")
    }

    func testNightlyBuildCanSwitchBackToStable() {
        let now = Date()
        let local = build("nightly", "0.12.0", date: now)
        let remote = manifest("stable", "0.12.0", commit: "b", date: now - day)
        XCTAssertEqual(Updates.offer(local: local, remote: remote, channel: "stable"), .switchToStable(remote))
    }

    func testNightlyBuildIsOfferedANewerStableAsASwitch() {
        let now = Date()
        let remote = manifest("stable", "0.13.0", commit: "b", date: now)
        XCTAssertEqual(Updates.offer(local: build("nightly", "0.12.1", date: now), remote: remote, channel: "stable"),
                       .switchToStable(remote), "same answer as the Windows and Linux app")
        XCTAssertNil(Updates.offer(local: build("stable", "0.13.0", commit: "ABC", date: now),
                                   remote: manifest("stable", "0.13.0", commit: "abc", date: now), channel: "stable"),
                     "commits compare without case")
        XCTAssertNotNil(Updates.offer(local: build("stable", "0.12.0", commit: "unknown", date: now),
                                      remote: manifest("stable", "0.13.0", commit: "unknown", date: now), channel: "stable"),
                        "an unknown commit never matches")
    }

    func testSemverOrder() {
        XCTAssertEqual(Updates.compare("0.12.10", "0.12.9"), .orderedDescending)
        XCTAssertEqual(Updates.compare("1.0.0-beta.2", "1.0.0"), .orderedAscending)
        XCTAssertEqual(Updates.compare("1.0.0-beta.10", "1.0.0-beta.2"), .orderedDescending)
        XCTAssertEqual(Updates.compare("0.12.1+nightly.202610120617", "0.12.1"), .orderedSame)
        XCTAssertEqual(Updates.compare("1.2", "1.2.0"), .orderedSame)
    }

    func testDecodesTheManifestCIWrites() throws {
        let json = #"{"channel":"stable","version":"0.12.0","commit":"abc","date":"2026-10-11T18:00:00Z","notes":"https://github.com/baney75/shotate/releases/tag/v0.12.0","assets":{"windows-x64":{"name":"Shotate_0.12.0_x64-setup.exe","url":"https://github.com/x","sha256":"00"}}}"#
        let m = try UpdateManifest.decode(Data(json.utf8))
        XCTAssertEqual(m.version, "0.12.0")
        XCTAssertEqual(m.assets["windows-x64"]?.name, "Shotate_0.12.0_x64-setup.exe")
    }

    func testUpdateSettingsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotate-upd-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var s = Settings()
        XCTAssertNil(s.updateChannel)
        XCTAssertTrue(s.checkForUpdates)
        s.updateChannel = "nightly"
        s.checkForUpdates = false
        try s.save(to: url)
        let back = try Settings.load(from: url)
        XCTAssertEqual(back.updateChannel, "nightly")
        XCTAssertFalse(back.checkForUpdates)
        try Data(#"{"updateChannel": "beta"}"#.utf8).write(to: url)
        XCTAssertNil(try Settings.load(from: url).updateChannel, "unknown channels are ignored")
    }
}
