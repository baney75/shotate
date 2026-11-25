import XCTest
@testable import ShotateCore

final class RecordingAlertTests: XCTestCase {
    private let incomplete = "The video didn't finish saving. It may be incomplete."

    func testIncompleteVideoIsAFailureThatNamesThePlace() {
        let m = RecordingAlert.message(place: "/r/a.mp4", partial: false, hasFolder: false, copied: .video,
                                       error: incomplete, logError: nil)
        XCTAssertEqual(m?.title, "Shotate couldn't save the recording")
        XCTAssertEqual(m?.detail, "What was written is at /r/a.mp4, and the video is copied. \(incomplete)")
    }

    func testIncompleteAppRecordingSaysTheNoteIsCopiedNotTheVideo() {
        let m = RecordingAlert.message(place: "/r/a", partial: false, hasFolder: true, copied: .note,
                                       error: incomplete, logError: nil)
        XCTAssertEqual(m?.title, "Shotate couldn't save the recording")
        XCTAssertEqual(m?.detail, "What was written is at /r/a, and the note is copied. \(incomplete)")
        XCTAssertFalse(m?.detail.contains("stills and note may still appear") ?? true)
    }

    func testPartialSaveSaysTheStillsMayStillAppear() {
        let m = RecordingAlert.message(place: "/r/a", partial: true, hasFolder: true, copied: .video,
                                       error: "Saving the recording took too long.", logError: nil)
        XCTAssertEqual(m?.title, "Shotate saved the video, but not everything else in time")
        XCTAssertEqual(m?.detail, "It's at /r/a, and the video is copied. The stills and note may still appear there. "
                           + "Saving the recording took too long.")
    }

    func testPartialSaveWithoutAFolderPromisesNoStills() {
        let m = RecordingAlert.message(place: "/r/a.mp4", partial: true, hasFolder: false, copied: .nothing,
                                       error: "Late.", logError: nil)
        XCTAssertEqual(m?.detail, "It's at /r/a.mp4. Late.")
    }

    func testNothingKeptGivesTheBareError() {
        let m = RecordingAlert.message(place: nil, partial: false, hasFolder: false, copied: .nothing,
                                       error: "Nothing was recorded.", logError: nil)
        XCTAssertEqual(m?.title, "Shotate couldn't save the recording")
        XCTAssertEqual(m?.detail, "Nothing was recorded.")
    }

    func testLogErrorAndCleanSave() {
        let m = RecordingAlert.message(place: "/r/a", partial: false, hasFolder: true, copied: .note,
                                       error: nil, logError: "denied")
        XCTAssertEqual(m?.title, "Shotate couldn't read the app's system log")
        XCTAssertEqual(m?.detail, "The video, stills and the app's own log files are saved, and the note is copied. macOS said: denied")
        XCTAssertNil(RecordingAlert.message(place: "/r/a", partial: false, hasFolder: true, copied: .note, error: nil, logError: nil))
    }
}
