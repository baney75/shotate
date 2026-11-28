import XCTest
@testable import ShotateCore

final class VoiceNotesTests: XCTestCase {
    private func load(_ json: String) throws -> Settings {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yapshot-\(UUID().uuidString)/config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        return try Settings.load(from: url)
    }

    /// Default shortcuts: Cmd+Shift+R is the screen recorder (area), Cmd+Shift+M is the mic/voice note.
    func testDefaultRecorderAndVoiceNoteShortcuts() {
        let d = Settings()
        XCTAssertEqual(d.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertEqual(d.shortcut("recordScreen"), Shortcut("cmd+ctrl+shift+r"))
        XCTAssertEqual(d.shortcut("recordApp"), Shortcut("cmd+shift+d"))
        XCTAssertEqual(d.shortcut("voiceNote"), Shortcut("cmd+shift+m"))
    }

    /// A 0.14.0 config file with the old default pair (recordArea on ⌥⇧⌘R, voiceNote on ⇧⌘R)
    /// migrates back to ⇧⌘R for recording and ⇧⌘M for voice notes.
    func testV14ShortcutPairMigratesToRecorderRAndMicM() throws {
        let s = try load(#"{"shortcuts": {"captureArea": "cmd+shift+s", "recordArea": "cmd+option+shift+r", "voiceNote": "cmd+shift+r"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertEqual(s.shortcut("voiceNote"), Shortcut("cmd+shift+m"))
    }

    func testV14ShortcutPairMatchesInAnyModifierOrder() throws {
        let s = try load(#"{"shortcuts": {"recordArea": "Shift+Opt+Cmd+R", "voiceNote": "Shift+Cmd+R"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertEqual(s.shortcut("voiceNote"), Shortcut("cmd+shift+m"))
    }

    /// Custom shortcuts are never stolen: if the user changed either recordArea or voiceNote away
    /// from the 0.14.0 default pair, both stay exactly as the user set them.
    func testCustomizedShortcutsAreLeftAlone() throws {
        var s = try load(#"{"shortcuts": {"recordArea": "cmd+ctrl+r", "voiceNote": "cmd+shift+r"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+ctrl+r"))
        XCTAssertEqual(s.shortcut("voiceNote"), Shortcut("cmd+shift+r"))

        s = try load(#"{"shortcuts": {"recordArea": "cmd+option+shift+r", "voiceNote": "cmd+option+m"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+option+shift+r"))
        XCTAssertEqual(s.shortcut("voiceNote"), Shortcut("cmd+option+m"))

        s = try load(#"{"shortcuts": {"recordArea": "cmd+option+shift+r", "voiceNote": ""}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+option+shift+r"))
        XCTAssertNil(s.shortcut("voiceNote"))

        s = try load(#"{"shortcuts": {"recordArea": "cmd+shift+r", "voiceNote": ""}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertNil(s.shortcut("voiceNote"))
    }

    /// Migration never steals Cmd+Shift+M (or Cmd+Shift+R) when another shortcut or command uses it.
    func testMigrationYieldsWhenTargetShortcutIsAlreadyTaken() throws {
        // Another action already uses Cmd+Shift+M: recordArea restores to ⇧⌘R, voiceNote turns off.
        var s = try load(#"{"shortcuts": {"recordArea": "cmd+option+shift+r", "voiceNote": "cmd+shift+r", "captureWindow": "shift+cmd+m"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertEqual(s.shortcut("captureWindow"), Shortcut("cmd+shift+m"))
        XCTAssertNil(s.shortcut("voiceNote"))

        // A command hotkey uses Cmd+Shift+M: voiceNote turns off rather than stealing it.
        s = try load(#"{"shortcuts": {"recordArea": "cmd+option+shift+r", "voiceNote": "cmd+shift+r"}, "commands": {"cmd+shift+m": "/usr/bin/true"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertNil(s.shortcut("voiceNote"))

        // Another action also uses Cmd+Shift+R: recordArea stays on ⌥⇧⌘R, voiceNote moves to ⇧⌘M.
        s = try load(#"{"shortcuts": {"recordArea": "cmd+option+shift+r", "voiceNote": "cmd+shift+r", "captureWindow": "cmd+shift+r"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+option+shift+r"))
        XCTAssertEqual(s.shortcut("captureWindow"), Shortcut("cmd+shift+r"))
        XCTAssertEqual(s.shortcut("voiceNote"), Shortcut("cmd+shift+m"))
    }

    /// A pre-0.14.0 config without voiceNote keeps recordArea on ⇧⌘R and gets ⇧⌘M unless taken.
    func testPreV14ConfigKeepsRecorderRAndGetsFreeMicM() throws {
        var s = try load(#"{"shortcuts": {"captureArea": "cmd+shift+s", "recordArea": "cmd+shift+r"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertEqual(s.shortcut("voiceNote"), Shortcut("cmd+shift+m"))

        s = try load(#"{"shortcuts": {"recordArea": "cmd+shift+r", "captureWindow": "cmd+shift+m"}}"#)
        XCTAssertEqual(s.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertNil(s.shortcut("voiceNote"))
    }

    /// Migration writes only recordArea and voiceNote, preserves unknown keys, and does not repeat
    /// when migrate is false.
    func testMigrationWritesOnlyItsKeysAndRunsOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yapshot-\(UUID().uuidString)/config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"shortcuts": {"recordArea": "cmd+option+shift+r", "voiceNote": "cmd+shift+r", "recordScreen": "hyper+r"}, "commands": {"cmd+shift+f13": "~/bin/x"}, "future": 1}"#.utf8).write(to: url)
        let (first, migrated) = try Settings.loadReporting(from: url, migrate: true)
        XCTAssertTrue(migrated)
        XCTAssertEqual(first.shortcut("recordArea"), Shortcut("cmd+shift+r"))
        XCTAssertEqual(first.shortcut("voiceNote"), Shortcut("cmd+shift+m"))
        try first.writeVoiceNoteShortcuts(to: url)

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let keys = raw["shortcuts"] as! [String: String]
        XCTAssertEqual(keys["recordScreen"], "hyper+r")
        XCTAssertEqual(keys["recordArea"], "cmd+shift+r")
        XCTAssertEqual(keys["voiceNote"], "cmd+shift+m")
        XCTAssertEqual(raw["commands"] as? [String: String], ["cmd+shift+f13": "~/bin/x"])
        XCTAssertEqual(raw["future"] as? Int, 1)

        // If the user later hand-edits back to the old pair, migrate: false respects their choice.
        try Data(#"{"shortcuts": {"recordArea": "cmd+option+shift+r", "voiceNote": "cmd+shift+r"}}"#.utf8).write(to: url)
        let (later, again) = try Settings.loadReporting(from: url, migrate: false)
        XCTAssertFalse(again)
        XCTAssertEqual(later.shortcut("recordArea"), Shortcut("cmd+option+shift+r"))
        XCTAssertEqual(later.shortcut("voiceNote"), Shortcut("cmd+shift+r"))
    }

    // MARK: QuickVoiceController (no transcription; copies audio file; reliable dismiss)

    func testQuickVoiceStopCopiesAudioFileAndAutoHides() {
        let audioURL = URL(fileURLWithPath: "/tmp/Voice Note 2026-11-28 at 08.00.00.m4a")
        var recording = false
        var copiedFiles: [URL] = []
        var scheduledHide: (() -> Void)?
        var phases: [QuickVoiceController.Phase] = []

        let controller = QuickVoiceController(
            isRecording: { recording },
            startRecording: { done in
                recording = true
                done(true, nil)
            },
            stopRecording: {
                guard recording else { return nil }
                recording = false
                return audioURL
            },
            copyAudioFile: { url in
                copiedFiles.append(url)
                return true
            },
            onPhaseChange: { phases.append($0) },
            scheduleHide: { _, work in scheduledHide = work },
            cancelScheduledHide: { scheduledHide = nil }
        )

        // First Cmd+Shift+M press starts recording.
        controller.toggle()
        XCTAssertTrue(recording)
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertTrue(controller.phase.isVisible)
        XCTAssertTrue(copiedFiles.isEmpty)

        // Second Cmd+Shift+M press stops recording and copies the audio file (never text/transcript).
        controller.toggle()
        XCTAssertFalse(recording)
        XCTAssertEqual(copiedFiles, [audioURL])
        XCTAssertEqual(controller.phase, .copied("Voice Note 2026-11-28 at 08.00.00.m4a"))
        XCTAssertNotNil(scheduledHide)

        // Auto-hide timer dismisses the badge cleanly.
        scheduledHide?()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.phase.isVisible)
        XCTAssertEqual(phases, [.starting, .recording, .copied("Voice Note 2026-11-28 at 08.00.00.m4a"), .idle])
    }

    func testQuickVoiceDismissStopsRecordingCopiesAudioAndHidesImmediately() {
        let audioURL = URL(fileURLWithPath: "/tmp/note.m4a")
        var recording = false
        var copiedFiles: [URL] = []
        var cancelCount = 0

        let controller = QuickVoiceController(
            isRecording: { recording },
            startRecording: { done in recording = true; done(true, nil) },
            stopRecording: {
                guard recording else { return nil }
                recording = false
                return audioURL
            },
            copyAudioFile: { copiedFiles.append($0); return true },
            cancelScheduledHide: { cancelCount += 1 }
        )

        controller.toggle()
        XCTAssertEqual(controller.phase, .recording)

        // Esc or Close button stops recording, copies audio, and immediately dismisses.
        controller.dismiss()
        XCTAssertFalse(recording)
        XCTAssertEqual(copiedFiles, [audioURL])
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.phase.isVisible)
        XCTAssertGreaterThanOrEqual(cancelCount, 1)
    }

    func testQuickVoiceDismissWhileWaitingOnMicPermissionAbortsLateStart() {
        var recording = false
        var stopCalls = 0
        var pendingStart: ((Bool, String?) -> Void)?

        let controller = QuickVoiceController(
            isRecording: { recording },
            startRecording: { done in pendingStart = done },
            stopRecording: {
                stopCalls += 1
                recording = false
                return nil
            },
            copyAudioFile: { _ in true }
        )

        controller.toggle()
        XCTAssertEqual(controller.phase, .starting)

        // User presses Esc / close / shortcut again before mic permission returns.
        controller.dismiss()
        XCTAssertEqual(controller.phase, .idle)

        // Late permission callback must not open a zombie overlay and must stop any started recorder.
        recording = true
        pendingStart?(true, nil)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.phase.isVisible)
        XCTAssertEqual(stopCalls, 1)
        XCTAssertFalse(recording)
    }

    func testQuickVoiceExternalStopDismissesBadge() {
        var recording = false
        let controller = QuickVoiceController(
            isRecording: { recording },
            startRecording: { done in recording = true; done(true, nil) },
            stopRecording: { recording = false; return nil },
            copyAudioFile: { _ in true }
        )

        controller.toggle()
        XCTAssertEqual(controller.phase, .recording)

        // Recorder stopped from Voice Notes window or system audio interruption.
        recording = false
        controller.externalRecordingStopped()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.phase.isVisible)
    }

    func testQuickVoiceInternalStopDoesNotFlickerOnSynchronousIsRecordingChange() {
        let audioURL = URL(fileURLWithPath: "/tmp/sync-stop.m4a")
        var recording = false
        var phases: [QuickVoiceController.Phase] = []
        var controller: QuickVoiceController!

        controller = QuickVoiceController(
            isRecording: { recording },
            startRecording: { done in recording = true; done(true, nil) },
            stopRecording: {
                recording = false
                // Simulate Combine firing $isRecording = false synchronously during stop().
                controller.externalRecordingStopped()
                return audioURL
            },
            copyAudioFile: { _ in true },
            onPhaseChange: { phases.append($0) }
        )

        controller.toggle()
        controller.finish()
        XCTAssertEqual(phases, [.starting, .recording, .copied("sync-stop.m4a")])
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

    func testMetaRoundTripsAndLegacyTranscriptSidecarsDecodeCleanly() throws {
        let m = VoiceMeta(markers: [VoiceMarker(time: 1.5, label: "Marker 1")], duration: 3, script: "Intro")
        let encoded = try JSONEncoder().encode(m)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("transcript"))
        XCTAssertEqual(try JSONDecoder().decode(VoiceMeta.self, from: encoded), m)
        // Legacy sidecars that stored a transcript still decode cleanly with unknown fields ignored.
        let old = try JSONDecoder().decode(VoiceMeta.self, from: Data(#"{"markers": [], "transcript": "Hi"}"#.utf8))
        XCTAssertTrue(old.markers.isEmpty)
        XCTAssertNil(old.duration)
    }

    func testSearchMatchesNamesOnly() {
        XCTAssertTrue(VoiceNotes.matches("", name: "a"))
        XCTAssertTrue(VoiceNotes.matches("voice", name: "Voice Note"))
        XCTAssertFalse(VoiceNotes.matches("milk", name: "Voice Note"))
    }

    func testSafeNameAndClock() {
        XCTAssertEqual(VoiceNotes.safeName("  a/b:c \n"), "a-b-c")
        XCTAssertEqual(VoiceNotes.clock(65), "1:05")
        XCTAssertEqual(VoiceNotes.clock(3723), "1:02:03")
        XCTAssertEqual(VoiceNotes.clock(65.34, tenths: true), "01:05.3")
        XCTAssertEqual(VoiceNotes.clock(.nan), "0:00")
    }
}
