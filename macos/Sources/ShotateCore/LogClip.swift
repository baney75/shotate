import Foundation

/// What of a recorded app's log goes on the clipboard. A chatty app logs thousands of lines a
/// second, and a paste of tens of megabytes fails in most chat boxes and agent prompts, so a long
/// log is cut to its newest lines, with a note saying so and where the whole file is.
public enum LogClip {
    public static let limit = 256 * 1024

    /// `tail` is the end of the file (at most `limit` bytes, read by the caller), `size` the
    /// whole file's size.
    public static func text(tail: Data, size: Int, path: String, limit: Int = LogClip.limit) -> String {
        guard size > tail.count || tail.count > limit else { return String(decoding: tail, as: UTF8.self) }
        var data = tail.suffix(limit)
        // Start on a whole line.
        if let nl = data.firstIndex(of: 0x0A) { data = data[data.index(after: nl)...] }
        return "# The log is \(size / 1024) KB; these are its last \(data.count / 1024) KB. Whole log: \(path)\n"
            + String(decoding: data, as: UTF8.self)
    }
}
