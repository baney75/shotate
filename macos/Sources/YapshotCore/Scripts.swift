import Foundation

/// Scripts to read aloud: Markdown files in `<voice folder>/Scripts`, one per title. The MCP tools
/// and the teleprompter read and write them; a name never reaches outside that folder.
public enum Scripts {
    public struct Info: Equatable {
        public var name: String
        public var url: URL
        public var modified: Date
        public var words: Int
    }

    public static func folder(in voiceFolder: URL) -> URL {
        voiceFolder.appendingPathComponent("Scripts", isDirectory: true)
    }

    /// A title made into a file name: no separators, no leading dots (so never "..", never hidden),
    /// no `.md` or `.txt` on the end (save adds `.md`), at most 120 characters. Empty becomes "Script".
    public static func safeTitle(_ raw: String) -> String {
        var s = VoiceNotes.safeName(raw.replacingOccurrences(of: "\\", with: "-"))
        s = String(s.drop { $0 == "." || $0 == " " })
        for ext in [".md", ".txt"] where s.lowercased().hasSuffix(ext) { s = String(s.dropLast(ext.count)) }
        s = String(s.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Script" : s
    }

    /// Saves `text` as `<safe title>.md`, replacing a script with the same title.
    @discardableResult
    public static func save(title: String, text: String, in voiceFolder: URL) throws -> URL {
        let dir = folder(in: voiceFolder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safeTitle(title) + ".md")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Newest first. A name is the file name without its extension, unless two files share that
    /// base name (`Plan.md`, `Plan.txt`): then each is listed by its file name. Every name listed
    /// reads back with `resolve`.
    public static func list(in voiceFolder: URL) -> [Info] {
        let dir = folder(in: voiceFolder)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        let scripts = urls.filter { ["md", "txt"].contains($0.pathExtension.lowercased()) }
        let bases = scripts.map { $0.deletingPathExtension().lastPathComponent.lowercased() }
        return scripts.map { u in
            let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let text = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            let base = u.deletingPathExtension().lastPathComponent
            let shared = bases.filter { $0 == base.lowercased() }.count > 1
            return Info(name: shared ? u.lastPathComponent : base, url: u, modified: date, words: wordCount(text))
        }.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.name < $1.name }
    }

    /// The file a name means: the file name itself when it ends in `.md` or `.txt`, then
    /// `<name>.md`, then `<name>.txt`. Throws for anything that isn't a plain name of a script in the
    /// folder: "../x", "a/b", "~", ".hidden" or a missing file.
    public static func resolve(_ name: String, in voiceFolder: URL) throws -> URL {
        let dir = folder(in: voiceFolder)
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [n + ".md", n + ".txt"]
        if ["md", "txt"].contains((n as NSString).pathExtension.lowercased()) { candidates.insert(n, at: 0) }
        for c in candidates {
            let url = try contained(c, in: dir, extensions: ["md", "txt"], defaultExtension: "md")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw AgentError("No script named \u{201C}\(name)\u{201D}.")
    }

    public static func read(_ name: String, in voiceFolder: URL) throws -> String {
        try String(contentsOf: resolve(name, in: voiceFolder), encoding: .utf8)
    }

    public static func delete(_ name: String, in voiceFolder: URL) throws {
        try FileManager.default.removeItem(at: resolve(name, in: voiceFolder))
    }

    public static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// `name` as a file directly inside `dir`, or an error. A name with a path separator, a leading
    /// dot or a `~` is refused before touching the disk, and the result must sit right in `dir`
    /// after resolving symlinks.
    static func contained(_ name: String, in dir: URL, extensions: Set<String>, defaultExtension: String) throws -> URL {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !n.contains("/"), !n.contains("\\"), !n.hasPrefix("."), !n.hasPrefix("~"), !n.contains("\0") else {
            throw AgentError("\u{201C}\(name)\u{201D} isn't a name in the folder.")
        }
        var url = dir.appendingPathComponent(n)
        if !extensions.contains(url.pathExtension.lowercased()) { url = dir.appendingPathComponent(n + "." + defaultExtension) }
        guard url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path
                == dir.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw AgentError("\u{201C}\(name)\u{201D} isn't a name in the folder.")
        }
        return url
    }
}

extension VoiceNotes {
    public struct Entry: Equatable {
        public var name: String
        public var url: URL
        public var date: Date
        public var duration: Double?
        public var meta: VoiceMeta
    }

    /// The voice notes in `folder`, newest first, read straight from the files and sidecars. A
    /// duration missing from the sidecar comes from `duration` (the app measures the audio), and
    /// only for the `limit` newest notes returned.
    public static func library(in folder: URL, limit: Int? = nil, duration: (URL) -> Double? = { _ in nil }) -> [Entry] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        let all: [Entry] = urls.filter { audioExtensions.contains($0.pathExtension.lowercased()) }.map { u in
            let meta = (try? JSONDecoder().decode(VoiceMeta.self, from: Data(contentsOf: sidecarURL(for: u)))) ?? VoiceMeta()
            let date = (try? u.resourceValues(forKeys: Set(keys)))?.creationDate ?? .distantPast
            return Entry(name: u.deletingPathExtension().lastPathComponent, url: u, date: date,
                         duration: meta.duration, meta: meta)
        }
        let sorted = all.sorted { $0.date != $1.date ? $0.date > $1.date : $0.name < $1.name }
        var kept = Array(sorted.prefix(limit ?? Int.max))
        for i in kept.indices where kept[i].duration == nil { kept[i].duration = duration(kept[i].url) }
        return kept
    }

    /// The note a name means: its name as listed, or its file name. Never outside `folder`.
    public static func entry(_ name: String, in folder: URL) throws -> Entry {
        _ = try Scripts.contained(name, in: folder, extensions: audioExtensions, defaultExtension: "m4a")
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let e = library(in: folder).first(where: { $0.name == n || $0.url.lastPathComponent == n }) else {
            throw AgentError("No voice note named \u{201C}\(name)\u{201D}.")
        }
        return e
    }
}
