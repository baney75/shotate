import Foundation

/// What the user is told when a recording they started ends badly, kept apart so tests pin it.
public enum RecordingAlert {
    /// What went on the clipboard when the recording ended.
    public enum Copied: Equatable {
        case nothing
        /// A screen or area recording, or an app recording whose note wasn't written.
        case video
        /// An app recording's `debug.md`.
        case note
    }

    /// - Parameters:
    ///   - place: where the kept video (or its folder) is; nil when nothing was kept.
    ///   - partial: the 90 s watchdog handed over the video before the stills and note were done.
    ///   - hasFolder: an app recording, which has stills and a note to wait for.
    ///   - error: the recording's error, if any.
    ///   - logError: why the app's system log couldn't be read, if it couldn't.
    /// - Returns: the alert's title and text, or nil when there is nothing to say.
    public static func message(place: String?, partial: Bool, hasFolder: Bool, copied: Copied,
                               error: String?, logError: String?) -> (title: String, detail: String)? {
        let copiedText: String
        switch copied {
        case .nothing: copiedText = ""
        case .video: copiedText = ", and the video is copied"
        case .note: copiedText = ", and the note is copied"
        }
        if let error {
            guard let place else { return ("Yapshot couldn't save the recording", error) }
            if partial {
                return ("Yapshot saved the video, but not everything else in time",
                        "It's at \(place)\(copiedText). "
                            + (hasFolder ? "The stills and note may still appear there. " : "") + error)
            }
            return ("Yapshot couldn't save the recording", "What was written is at \(place)\(copiedText). \(error)")
        }
        if let logError {
            return ("Yapshot couldn't read the app's system log",
                    "The video, stills and the app's own log files are saved\(copiedText). macOS said: \(logError)")
        }
        return nil
    }
}
