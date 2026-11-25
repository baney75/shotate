import XCTest
@testable import YapshotCore

final class VoiceNotesTests: XCTestCase {
    private func load(_ json: String) throws -> Settings {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yapshot-\(UUID().uuidString)/config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        return try Settings.load(from: url)
    }

    /// A file from before voice notes, with recordArea on ⇧⌘R: recording moves to ⌥⇧⌘R and ⇧⌘R
    /// starts a voice note.
    func testOldRecordAreaShortcutMovesForVoiceNotes() throws {
        let s = try load(#"{"shortcuts": {"captureArea": "cmd+shift+s", "recordArea": "cmd+shift+r"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+option+shift+r"))
        XCTAssertEqual(s.shortcut("voiceNote"), Shortcut("cmd+shift+r"))
    }

    func testOldRecordAreaShortcutMatchesInAnyOrder() throws {
        let s = try load(#"{"shortcuts": {"recordArea": "Shift+Cmd+R"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+option+shift+r"))
        XCTAssertEqual(s.shortcut("voiceNote"), Shortcut("cmd+shift+r"))
    }

    /// Someone who chose their own record shortcut keeps it; voiceNote only gets its free default.
    func testReboundRecordAreaIsLeftAlone() throws {
        let s = try load(#"{"shortcuts": {"recordArea": "cmd+ctrl+r"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+ctrl+r"))
        XCTAssertEqual(s.shortcut("voiceNote"), Shortcut("cmd+shift+r"))
    }

    /// The migration runs once: a file that already has voiceNote is never touched again, even
    /// when the person put recordArea back on ⇧⌘R.
    func testFileWithVoiceNoteKeyIsNotMigrated() throws {
        let s = try load(#"{"shortcuts": {"recordArea": "cmd+shift+r", "voiceNote": ""}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertNil(s.shortcut("voiceNote"))
    }

    /// A file that never wrote recordArea had it on the old ⇧⌘R default. If ⌥⇧⌘R is taken, area
    /// recording keeps ⇧⌘R instead of losing its shortcut, and voiceNote starts off.
    func testUnwrittenRecordAreaCountsAsTheOldDefault() throws {
        var s = try load(#"{"shortcuts": {"captureArea": "cmd+option+shift+r"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertNil(s.shortcut("voiceNote"))
        s = try load(#"{"commands": {"cmd+option+shift+r": "/usr/bin/true"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertNil(s.shortcut("voiceNote"))
        s = try load(#"{"copyOnCapture": true}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+option+shift+r"))
        XCTAssertEqual(s.shortcut("voiceNote"), Shortcut("cmd+shift+r"))
    }

    /// The move is decided once and written as just two keys: everything else in the file, even
    /// entries this build can't read, stays. Later loads don't migrate, so editing the clash away
    /// doesn't move area recording after all.
    func testMigrationWritesOnlyItsKeysAndIsNotDecidedAgain() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yapshot-\(UUID().uuidString)/config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"shortcuts": {"recordArea": "cmd+shift+r", "captureScreen": "cmd+option+shift+r", "recordScreen": "hyper+r"}, "commands": {"cmd+shift+f13": "~/bin/x"}, "future": 1}"#.utf8).write(to: url)
        let (first, migrated) = try Settings.loadReporting(from: url)
        XCTAssertTrue(migrated)
        try first.writeVoiceNoteShortcuts(to: url)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let keys = raw["shortcuts"] as! [String: String]
        XCTAssertEqual(keys["recordScreen"], "hyper+r")
        XCTAssertEqual(keys["recordArea"], "cmd+shift+r")
        XCTAssertEqual(keys["voiceNote"], "")
        XCTAssertEqual(raw["commands"] as? [String: String], ["cmd+shift+f13": "~/bin/x"])
        XCTAssertEqual(raw["future"] as? Int, 1)
        // A hand edit that drops voiceNote again isn't re-migrated once the caller stops passing migrate.
        try Data(#"{"shortcuts": {"recordArea": "cmd+shift+r"}}"#.utf8).write(to: url)
        let (later, again) = try Settings.loadReporting(from: url, migrate: false)
        XCTAssertFalse(again)
        XCTAssertEqual(later.shortcut("recordArea"), Shortcut("cmd+shift+r"))
    }

    /// voiceNote's default never takes keys the file uses for something else.
    func testVoiceNoteDefaultYieldsOnClash() throws {
        var s = try load(#"{"shortcuts": {"recordArea": "cmd+ctrl+r", "captureWindow": "shift+cmd+r"}}"#)
        XCTAssertEqual(s.shortcut("captureWindow"), Shortcut("cmd+shift+r"))
        XCTAssertNil(s.shortcut("voiceNote"))
        s = try load(#"{"shortcuts": {"recordArea": "cmd+ctrl+r"}, "commands": {"cmd+shift+r": "/usr/bin/true"}}"#)
        XCTAssertNil(s.shortcut("voiceNote"))
        // recordArea's new keys are taken: nothing moves, and voiceNote starts off.
        s = try load(#"{"shortcuts": {"recordArea": "cmd+shift+r", "captureScreen": "cmd+option+shift+r"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertNil(s.shortcut("voiceNote"))
        // recordArea moves, but another action also had ⇧⌘R: voiceNote still starts off.
        s = try load(#"{"shortcuts": {"recordArea": "cmd+shift+r", "captureWindow": "cmd+shift+r"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+option+shift+r"))
        XCTAssertNil(s.shortcut("voiceNote"))
    }

    func testVoiceSettingsDefaultsAndParsing() throws {
        let d = Settings()
        XCTAssertEqual(d.voiceFolder.path, NSHomeDirectory() + "/Music/Voice Notes")
        XCTAssertEqual(d.voiceQuality, .aac)
        XCTAssertFalse(d.voiceStereo)
        let s = try load(#"{"voiceFolder": "~/Notes/Audio", "voiceQuality": "ALAC", "voiceStereo": true}"#)
        XCTAssertEqual(s.voiceFolder.path, NSHomeDirectory() + "/Notes/Audio")
        XCTAssertEqual(s.voiceQuality, .alac)
        XCTAssertTrue(s.voiceStereo)
        XCTAssertEqual(try load(#"{"voiceQuality": "mp3"}"#).voiceQuality, .aac, "an unknown quality keeps the default")
    }

    func testVoiceSettingsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yapshot-\(UUID().uuidString)/config.json")
        var s = Settings()
        s.voiceFolder = URL(fileURLWithPath: NSHomeDirectory() + "/Music/Elsewhere", isDirectory: true)
        s.voiceQuality = .wav
        s.voiceStereo = true
        s.normalize()
        try s.save(to: url)
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(o?["voiceFolder"] as? String, "~/Music/Elsewhere")
        XCTAssertEqual(o?["voiceQuality"] as? String, "wav")
        XCTAssertEqual(try Settings.load(from: url), s)
    }

    func testVoiceNoteFileNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = Settings()
        s.voiceFolder = dir
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 10, 10, 14, 3, 22)
        let date = Calendar.current.date(from: c)!
        let first = s.newVoiceNoteURL(date: date)
        XCTAssertEqual(first.lastPathComponent, "Voice Note 2026-10-10 at 14.03.22.m4a")
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
        FileManager.default.createFile(atPath: first.path, contents: Data())
        XCTAssertEqual(s.newVoiceNoteURL(date: date).lastPathComponent, "Voice Note 2026-10-10 at 14.03.22 2.m4a")
        s.voiceQuality = .wav
        XCTAssertEqual(s.newVoiceNoteURL(date: date).pathExtension, "wav")
    }

    func testSidecarSitsInMetaFolderBesideTheAudio() {
        let audio = URL(fileURLWithPath: "/Users/x/Music/Voice Notes/Voice Note 1.m4a")
        XCTAssertEqual(VoiceNotes.sidecarURL(for: audio).path, "/Users/x/Music/Voice Notes/.meta/Voice Note 1.m4a.json")
    }

    func testMetaRoundTripsAndOldSidecarsDecode() throws {
        let m = VoiceMeta(markers: [VoiceMarker(time: 1.5, label: "Marker 1")], transcript: "Hello", duration: 3)
        XCTAssertEqual(try JSONDecoder().decode(VoiceMeta.self, from: JSONEncoder().encode(m)), m)
        // Cantor's sidecars have the same shape, so a library moved over keeps its transcripts.
        let old = try JSONDecoder().decode(VoiceMeta.self, from: Data(#"{"markers": [], "transcript": "Hi"}"#.utf8))
        XCTAssertEqual(old.transcript, "Hi")
        XCTAssertNil(old.duration)
    }

    func testSearchNamesAndTranscripts() {
        XCTAssertTrue(VoiceNotes.matches("", name: "a", transcript: nil))
        XCTAssertTrue(VoiceNotes.matches("groc", name: "Voice Note", transcript: "Buy GROCERIES"))
        XCTAssertTrue(VoiceNotes.matches("voice", name: "Voice Note", transcript: nil))
        XCTAssertFalse(VoiceNotes.matches("milk", name: "Voice Note", transcript: nil))
    }

    func testSafeNameAndClock() {
        XCTAssertEqual(VoiceNotes.safeName("  a/b:c \n"), "a-b-c")
        XCTAssertEqual(VoiceNotes.clock(65), "1:05")
        XCTAssertEqual(VoiceNotes.clock(3723), "1:02:03")
        XCTAssertEqual(VoiceNotes.clock(65.34, tenths: true), "01:05.3")
        XCTAssertEqual(VoiceNotes.clock(.nan), "0:00")
    }
}
