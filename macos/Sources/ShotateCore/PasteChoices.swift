import Foundation

/// The screenshots Shotate put on the clipboard lately, newest first, for choosing which one ⌘V
/// pastes. A capture that's copied again (edited, say) moves back to the front as one entry.
public struct PasteChoices: Equatable {
    public struct Entry: Equatable {
        /// The file the image is saved as; it names the entry.
        public let file: URL
        /// When it was last put on the clipboard; it drops off `maxAge` after that.
        public var copiedAt: Date
        /// When it first joined: the 3-second rule compares screenshots by when they were taken.
        public let takenAt: Date
        public var pasted = false
    }

    /// Older screenshots drop off after a minute: the choice is for the ones just taken, and after
    /// that ⌘V pastes the latest as usual.
    public static let maxAge: TimeInterval = 60
    /// Screenshots count as one batch to choose from only when each comes within this long of
    /// the one before; one taken later starts a new batch.
    public static let burstGap: TimeInterval = 3
    /// One per number key.
    public static let maxCount = 9

    public private(set) var entries: [Entry] = []

    public init() {}

    /// Shotate just put this screenshot on the clipboard.
    public mutating func copied(_ file: URL, at date: Date = Date()) {
        // Copying one already here again (Return in its editor) only moves it to the front; a new
        // screenshot more than `burstGap` after the last one starts a new batch.
        if let i = entries.firstIndex(where: { $0.file == file }) {
            var e = entries.remove(at: i)
            e.copiedAt = date
            entries.insert(e, at: 0)
            return
        }
        if let newest = entries.map(\.takenAt).max(), date.timeIntervalSince(newest) > Self.burstGap { entries.removeAll() }
        entries.insert(Entry(file: file, copiedAt: date, takenAt: date), at: 0)
        if entries.count > Self.maxCount { entries.removeLast(entries.count - Self.maxCount) }
    }

    public mutating func markPasted(_ file: URL) {
        if let i = entries.firstIndex(where: { $0.file == file }) { entries[i].pasted = true }
    }

    /// Forgets screenshots older than `maxAge`, and any whose file is gone.
    public mutating func prune(now: Date = Date(), exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        entries.removeAll { now.timeIntervalSince($0.copiedAt) > Self.maxAge || !exists($0.file) }
    }

    /// Whether ⌘V should ask which screenshot to paste: the setting is on, the clipboard still holds
    /// the screenshot Shotate put there (so text copied since pastes as usual), and there's a choice.
    public func shouldAsk(enabled: Bool, clipboardIsOurs: Bool) -> Bool {
        enabled && clipboardIsOurs && entries.count >= 2
    }
}
