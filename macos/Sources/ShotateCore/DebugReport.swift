import Foundation

/// The part of a recorded app's system log worth reading. `log stream --level debug` on a busy app
/// is almost all macOS housekeeping (XPC transactions, Launch Services, user defaults): a 40 s
/// recording of T3 Code was 2,900 lines with nothing from the app itself. The digest keeps errors,
/// faults and anything the app logged under its own subsystem, and folds repeats into one line.
public struct LogDigest: Equatable {
    public struct Entry: Equatable {
        /// The first line as `log` wrote it, plus any lines that continue it.
        public var text: String
        public var count: Int
        public var isError: Bool
    }

    public var entries: [Entry]
    /// Entries in the whole log, kept or not.
    public var total: Int
    public var errors: Int { entries.filter(\.isError).reduce(0) { $0 + $1.count } }
    public var kept: Int { entries.reduce(0) { $0 + $1.count } }

    /// `text` is `log stream --style compact` output. `ownImages` are the app's own executable names,
    /// so lines the app logged without a subsystem (`(MyApp) message`) are kept too.
    public static func parse(_ text: String, ownImages: Set<String> = []) -> LogDigest {
        var entries: [Entry] = []
        var index: [String: Int] = [:]
        var total = 0
        var current: (text: String, key: String, keep: Bool, error: Bool)?

        func flush() {
            guard let c = current, c.keep else { return }
            if let i = index[c.key] {
                entries[i].count += 1
            } else {
                index[c.key] = entries.count
                entries.append(Entry(text: c.text, count: 1, isError: c.error))
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            guard let head = Header(s) else {
                // A line that continues the entry above it (multi-line messages).
                if current != nil, !s.isEmpty, !s.hasPrefix("#"), !s.hasPrefix("Filtering the log"),
                   !s.hasPrefix("Timestamp ") {
                    current!.text += "\n" + s
                    current!.key += "\n" + s
                }
                continue
            }
            flush()
            total += 1
            let error = head.type == "E" || head.type == "F" || head.type == "Er" || head.type == "Ft"
            let own: Bool
            if let sub = head.subsystem {
                own = !sub.hasPrefix("com.apple.")
            } else if let image = head.image {
                own = ownImages.contains(image)
            } else {
                own = false
            }
            current = (s, head.key, error || own, error)
        }
        flush()
        return LogDigest(entries: entries, total: total)
    }

    /// Markdown lines, errors first, each at most `lineLimit` characters, `limit` characters in all.
    public func markdown(limit: Int = 12_000, lineLimit: Int = 400) -> String {
        let ordered = entries.filter(\.isError) + entries.filter { !$0.isError }
        var out = ""
        var shown = 0
        for e in ordered {
            var t = e.text.count > lineLimit ? String(e.text.prefix(lineLimit)) + " …" : e.text
            if e.count > 1 { t += "  (×\(e.count))" }
            guard out.count + t.count + 1 <= limit else { break }
            out += t + "\n"
            shown += 1
        }
        if shown < ordered.count { out += "… \(ordered.count - shown) more in the full log.\n" }
        return out
    }

    /// One line of compact `log stream` output:
    /// `2026-10-31 14:16:33.827 F  App[53933:33fdcc6] [com.apple.runtime-issues:AppKit] message` or
    /// `2026-10-31 14:16:33.936 A  App[53933:924ff64] (CoreSpotlight) message`.
    struct Header {
        let type: String
        let subsystem: String?
        let image: String?
        /// The line without its time and thread, so repeats compare equal.
        let key: String

        init?(_ s: String) {
            let parts = s.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].count == 10, parts[0].dropFirst(4).first == "-",
                  parts[1].count >= 8, parts[1].dropFirst(2).first == ":" else { return nil }
            let rest = parts[2].drop { $0 == " " }
            let fields = rest.split(separator: " ", maxSplits: 1)
            guard let type = fields.first else { return nil }
            self.type = String(type)
            let after = fields.count > 1 ? fields[1].drop { $0 == " " } : ""
            // Skip the process: "Name With Spaces[pid:tid] ".
            guard let close = after.range(of: "] ") else { return nil }
            let process = after[..<close.lowerBound]
            let processName = process.split(separator: "[").first.map(String.init) ?? ""
            let body = after[close.upperBound...]
            if body.hasPrefix("["), let end = body.firstIndex(of: "]") {
                let tag = body[body.index(after: body.startIndex)..<end]
                subsystem = String(tag.split(separator: ":", maxSplits: 1).first ?? tag)
                image = nil
            } else if body.hasPrefix("("), let end = Self.closingParen(body) {
                subsystem = nil
                image = String(body[body.index(after: body.startIndex)..<end])
            } else {
                subsystem = nil
                image = nil
            }
            key = processName + " " + type + " " + body
        }

        /// Image names can hold parentheses: "(T3 Code (Nightly)) message".
        private static func closingParen(_ s: Substring) -> Substring.Index? {
            var depth = 0
            for i in s.indices {
                if s[i] == "(" { depth += 1 }
                if s[i] == ")" { depth -= 1; if depth == 0 { return i } }
            }
            return nil
        }
    }
}

/// What a log file the app wrote during the recording adds: the lines that look like trouble, then
/// its newest lines.
public enum LogExcerpt {
    static let trouble = ["error", "exception", "fatal", "panic", "traceback", "uncaught", "failed", "warn",
                          "crash", "\"level\":\"e", "\"level\":50", "\"level\":60"]

    public static func excerpt(_ text: String, troubleLines: Int = 30, tailLines: Int = 25, lineLimit: Int = 300) -> String {
        let lines = text.split(separator: "\n").map(String.init)
        func cut(_ l: String) -> String { l.count > lineLimit ? String(l.prefix(lineLimit)) + " …" : l }
        let tailStart = max(0, lines.count - tailLines)
        let flagged = lines[..<tailStart].filter { l in
            let lower = l.lowercased()
            return trouble.contains { lower.contains($0) }
        }
        var out = ""
        if !flagged.isEmpty {
            out += "Errors and warnings before the last \(tailLines) lines"
                + (flagged.count > troubleLines ? " (newest \(troubleLines) of \(flagged.count))" : "") + ":\n"
            out += flagged.suffix(troubleLines).map(cut).joined(separator: "\n") + "\n\n"
            out += "Last lines:\n"
        }
        out += lines[tailStart...].map(cut).joined(separator: "\n")
        return out
    }
}

/// The note an app recording (⇧⌘D) puts on the clipboard and saves as `debug.md` beside the video:
/// enough for a coding agent to start debugging, with paths to everything else.
public struct DebugReport {
    public struct AppLogFile {
        public var path: String
        /// Bytes the app added while it was recorded.
        public var added: Int
        public var excerpt: String
        public init(path: String, added: Int, excerpt: String) {
            self.path = path; self.added = added; self.excerpt = excerpt
        }
    }

    public var appName: String
    public var bundleID: String?
    public var version: String?
    public var pid: Int32
    public var started: Date
    public var duration: TimeInterval
    public var folder: String
    public var video: String
    public var videoSize: (width: Int, height: Int)?
    public var stills: [(time: TimeInterval, path: String)] = []
    public var systemLog: String?
    public var systemLogError: String?
    public var digest: LogDigest?
    public var appLogs: [AppLogFile] = []
    public var crashReports: [String] = []
    public var macOS: String

    public init(appName: String, bundleID: String?, version: String?, pid: Int32, started: Date, duration: TimeInterval,
                folder: String, video: String, macOS: String) {
        self.appName = appName; self.bundleID = bundleID; self.version = version; self.pid = pid
        self.started = started; self.duration = duration; self.folder = folder; self.video = video; self.macOS = macOS
    }

    /// "0:42", "1:02:09".
    /// "0:02.8": a still's time, to the tenth, never rounded up into the next second.
    public static func preciseClock(_ t: TimeInterval) -> String {
        let tenths = Int((max(0, t) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }

    public static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    public func markdown(limit: Int = 48_000) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        var head = "# \(appName): screen recording with debug logs\n\n"
        head += "Recorded \(f.string(from: started)) for \(Self.clock(duration)) with Shotate. "
            + "Watch the video (or look at the stills) for what happened on screen; the logs below are what the app wrote meanwhile.\n\n"
        let id = [bundleID, version.map { "version \($0)" }, "pid \(pid)"].compactMap { $0 }.joined(separator: ", ")
        head += "- App: \(appName) (\(id)), macOS \(macOS)\n"
        let size = videoSize.map { " (\($0.width)×\($0.height))" } ?? ""
        head += "- Video: `\(video)`\(size)\n"
        if !stills.isEmpty {
            head += "- Stills (PNG, one per moment, readable by agents that can't play video):\n"
            for s in stills { head += "  - \(Self.preciseClock(s.time)) `\(s.path)`\n" }
        }
        if let systemLog { head += "- Full system log: `\(systemLog)`\n" }
        head += "- Everything: `\(folder)`\n"

        var body = ""
        if !crashReports.isEmpty {
            body += "\n## Crash reports written during the recording\n\n"
            body += crashReports.map { "- `\($0)`" }.joined(separator: "\n") + "\n"
        }
        for log in appLogs {
            body += "\n## \(Self.home(log.path)) (+\(Self.bytes(log.added)))\n\n```\n\(log.excerpt)\n```\n"
        }
        if let systemLogError {
            body += "\n## System log\n\nmacOS wouldn't give Shotate the log: \(systemLogError)\n"
        } else if let digest {
            body += "\n## System log, filtered\n\n"
            let dropped = digest.total - digest.kept
            body += "\(digest.total) entries; \(digest.errors) errors or faults. "
                + (dropped > 0 ? "\(dropped) routine macOS entries (XPC, Launch Services, defaults) are left out here but kept in the full log.\n\n"
                    : "\n\n")
            body += digest.entries.isEmpty ? "Nothing from the app itself, and no errors.\n"
                : "```\n" + digest.markdown(limit: max(2000, limit - head.count - body.count - 200)) + "```\n"
        }
        if appLogs.isEmpty {
            body += "\nThe app wrote no log files Shotate could find. If it logs somewhere else, name the folder in "
                + "`appLogs` in ~/.config/shotate/config.json.\n"
        }
        let text = head + body
        return text.count <= limit ? text : String(text.prefix(limit)) + "\n… (cut; the full logs are in the folder above)\n"
    }

    static func home(_ path: String) -> String {
        let h = NSHomeDirectory()
        return path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
    }

    static func bytes(_ n: Int) -> String {
        n >= 1_048_576 ? String(format: "%.1f MB", Double(n) / 1_048_576) : n >= 1024 ? "\(n / 1024) KB" : "\(n) bytes"
    }
}
