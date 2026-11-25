import Foundation

/// `yapshot mcp install`: registers Yapshot's MCP server with the agents on this Mac. Each edit adds,
/// updates or removes only the `yapshot` entry, leaves every other entry as it was, and copies the
/// file beside itself first. A symlinked config is edited at its target, so the link stays. An
/// existing `yapshot` entry is left alone when it already runs this app. An entry under the old name
/// `shotate` that runs our command is replaced, so there is one server, not two.
public enum MCPInstall {
    public static let serverName = "yapshot"
    /// The name before the rename to Yapshot.
    public static let legacyServerName = "shotate"

    /// Whether a server's command is this app's: the `yapshot` or `shotate` script, or the app binary.
    public static func isOurCommand(_ command: String) -> Bool {
        ["yapshot", "shotate"].contains((command as NSString).lastPathComponent.lowercased())
    }

    public enum Client: String, CaseIterable {
        case claude, codex, cursor
        case claudeDesktop = "claude-desktop"

        public var title: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .cursor: return "Cursor"
            case .claudeDesktop: return "Claude Desktop"
            }
        }

        /// The config file Yapshot edits, under `home`. Claude Code has none: its own command does it.
        public func configURL(home: URL) -> URL? {
            switch self {
            case .claude: return nil
            case .codex: return home.appendingPathComponent(".codex/config.toml")
            case .cursor: return home.appendingPathComponent(".cursor/mcp.json")
            case .claudeDesktop: return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
            }
        }
    }

    /// `--client`: absent or `all` is every client.
    public static func clients(_ value: String?) -> Result<[Client], AgentError> {
        guard let value, value != "all", value != "true" else { return .success(Client.allCases) }
        guard let c = Client(rawValue: value.lowercased()) else {
            return .failure(AgentError("--client is claude, codex, cursor, claude-desktop or all"))
        }
        return .success([c])
    }

    public enum Outcome: String, Equatable {
        /// Added or updated `yapshot` (or kept the one there) and removed an old `shotate` entry that ran our command.
        case replaced
        case added, updated, alreadyThere, removed, notThere
    }

    public struct Change: Equatable {
        public var outcome: Outcome
        public var file: URL
        /// The copy made before editing; nil when nothing was edited or the file was new.
        public var backup: URL?
    }

    /// Why Yapshot won't register itself from where it is running, or nil when it can. A copy macOS
    /// translocated (opened from Downloads or a disk image) or one on a read-only volume moves or goes
    /// away, and every agent would be left pointing at a path that no longer exists.
    public static func installRefusal(command: String, readOnlyVolume: Bool) -> String? {
        guard command.contains("/AppTranslocation/") || readOnlyVolume else { return nil }
        return "Yapshot is running from a temporary or read-only place (\(command)), so agents couldn't start it later. "
            + "Move Yapshot to the Applications folder, open it from there, and connect again."
    }

    /// The PATH for a child process: `current`, then the `extra` folders, then the folder `found`
    /// is in, each once. A GUI app's PATH is short, and a `#!/usr/bin/env node` script needs the rest.
    public static func childPATH(current: String?, extra: [String], found: String) -> String {
        var dirs: [String] = []
        let all = (current ?? "").split(separator: ":").map(String.init) + extra.map { ($0 as NSString).expandingTildeInPath }
            + [(found as NSString).deletingLastPathComponent]
        for d in all where !d.isEmpty && !dirs.contains(d) { dirs.append(d) }
        return dirs.joined(separator: ":")
    }

    // MARK: JSON (Cursor, Claude Desktop)

    /// Adds the entry, or rewrites an existing one whose command or args differ from these or whose
    /// command isn't executable any more (the app moved). A matching, working entry is left alone.
    public static func addJSON(at url: URL, command: String, args: [String], now: Date = Date(),
                               isExecutable: (String) -> Bool = FileManager.default.isExecutableFile) throws -> Change {
        let file = url.resolvingSymlinksInPath()
        var root = try readJSON(file)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if root["mcpServers"] != nil, !(root["mcpServers"] is [String: Any]) {
            throw AgentError("\(url.path): mcpServers isn't an object, so Yapshot left the file alone.")
        }
        let legacy = (servers[legacyServerName] as? [String: Any])?["command"] as? String
        let replacing = legacy.map(isOurCommand) ?? false
        var outcome = Outcome.added
        var entry: [String: Any] = [:]
        var current = false
        if let existing = servers[serverName] {
            entry = existing as? [String: Any] ?? [:]
            current = entry["command"] as? String == command && (entry["args"] as? [String] ?? []) == args && isExecutable(command)
            if current, !replacing { return Change(outcome: .alreadyThere, file: url) }
            outcome = .updated
        }
        if replacing {
            servers[legacyServerName] = nil
            outcome = .replaced
        }
        if !current {
            entry["command"] = command
            entry["args"] = args
            servers[serverName] = entry
        }
        root["mcpServers"] = servers
        let backup = try backupIfPresent(file, now: now)
        try writeJSON(root, to: file)
        return Change(outcome: outcome, file: url, backup: backup)
    }

    public static func removeJSON(at url: URL, now: Date = Date()) throws -> Change {
        let file = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: file.path) else { return Change(outcome: .notThere, file: url) }
        var root = try readJSON(file)
        guard var servers = root["mcpServers"] as? [String: Any], servers[serverName] != nil else {
            return Change(outcome: .notThere, file: url)
        }
        servers[serverName] = nil
        root["mcpServers"] = servers
        let backup = try backupIfPresent(file, now: now)
        try writeJSON(root, to: file)
        return Change(outcome: .removed, file: url, backup: backup)
    }

    /// The file's top-level object; empty when the file is missing or blank. Anything else unreadable
    /// is an error, and the file is left as it was.
    static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: url.path),
              !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError("\(url.path) isn't a JSON object Yapshot can read, so it left the file alone.")
        }
        return o
    }

    static func writeJSON(_ o: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    // MARK: TOML (Codex)

    /// Adds a `[mcp_servers.yapshot]` table, or rewrites the command and args of the one there when
    /// they differ or the command isn't executable. A `yapshot` server written another way (an inline
    /// table or dotted keys) is refused: appending a table would define it twice. A
    /// `[mcp_servers.shotate]` table that runs our command is removed with its subtables; an old
    /// `shotate` server written another way is refused too, since it can't be removed cleanly.
    public static func addTOML(at url: URL, command: String, args: [String], now: Date = Date(),
                               isExecutable: (String) -> Bool = FileManager.default.isExecutableFile) throws -> Change {
        let file = url.resolvingSymlinksInPath()
        var text = ""
        if FileManager.default.fileExists(atPath: file.path) {
            guard let read = try? String(contentsOf: file, encoding: .utf8) else {
                throw AgentError("\(url.path) isn't readable UTF-8 text, so Yapshot left the file alone.")
            }
            text = read
        }
        let lines = tomlLines(text)
        for name in [serverName, legacyServerName] {
            if let other = tomlFind(lines, name: name).other {
                throw AgentError("\(url.path) \(other), so Yapshot left the file alone. "
                    + "Remove it, or write it as a [mcp_servers.\(name)] table, and connect again.")
            }
        }
        let found = tomlFind(lines)
        let replacing = tomlServerCommand(lines, name: legacyServerName).command.map(isOurCommand) ?? false
        var out = replacing ? tomlRemoving(text, name: legacyServerName) : text
        var outcome: Outcome
        if found.table {
            let current = tomlServerCommand(lines)
            let upToDate = current.command == command && current.args == args && isExecutable(command)
            if upToDate, !replacing { return Change(outcome: .alreadyThere, file: url) }
            if !upToDate { out = tomlUpdating(out, command: command, args: args) }
            outcome = .updated
        } else {
            out = tomlAdding(out, command: command, args: args)
            outcome = .added
        }
        if replacing { outcome = .replaced }
        let backup = try backupIfPresent(file, now: now)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(out.utf8).write(to: file, options: .atomic)
        return Change(outcome: outcome, file: url, backup: backup)
    }

    public static func removeTOML(at url: URL, now: Date = Date()) throws -> Change {
        let file = url.resolvingSymlinksInPath()
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return Change(outcome: .notThere, file: url) }
        let found = tomlFind(tomlLines(text))
        if let other = found.other {
            throw AgentError("\(url.path) \(other), so Yapshot left the file alone. Remove it there by hand.")
        }
        guard found.table || found.subtables else { return Change(outcome: .notThere, file: url) }
        let backup = try backupIfPresent(file, now: now)
        try Data(tomlRemoving(text).utf8).write(to: file, options: .atomic)
        return Change(outcome: .removed, file: url, backup: backup)
    }

    /// One line of a TOML file, as far as finding tables and keys needs: quotes in keys are honored,
    /// and lines inside a multi-line string or a multi-line array are continuations, never headers.
    struct TOMLLine {
        enum Kind: Equatable {
            case blank, comment, other, continuation
            case header([String]), arrayHeader([String])
            /// A `key = value` line, its dotted key in segments.
            case key([String])
        }
        var text: String
        var kind: Kind
        /// The table this line is in: for a header, the table it opens.
        var table: [String]
        /// Where the value starts, in unicode scalars, for a key line.
        var valueStart: Int = 0

        var headerKeys: [String]? {
            switch kind {
            case let .header(k), let .arrayHeader(k): return k
            default: return nil
            }
        }
    }

    static func tomlLines(_ text: String) -> [TOMLLine] {
        var out: [TOMLLine] = []
        var multi: String?
        var depth = 0
        var table: [String] = []
        for text in text.components(separatedBy: "\n") {
            let s = Array(text.unicodeScalars)
            if multi != nil || depth > 0 {
                scanValue(s, from: 0, multi: &multi, depth: &depth)
                out.append(TOMLLine(text: text, kind: .continuation, table: table))
                continue
            }
            var i = 0
            while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
            let rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.isEmpty { out.append(TOMLLine(text: text, kind: .blank, table: table)); continue }
            if rest.hasPrefix("#") { out.append(TOMLLine(text: text, kind: .comment, table: table)); continue }
            if rest.hasPrefix("[") {
                let array = rest.hasPrefix("[[")
                var j = i + (array ? 2 : 1)
                if let keys = parseKey(s, &j), closes(s, j, array ? "]]" : "]") {
                    table = keys
                    out.append(TOMLLine(text: text, kind: array ? .arrayHeader(keys) : .header(keys), table: table))
                } else {
                    out.append(TOMLLine(text: text, kind: .other, table: table))
                }
                continue
            }
            var j = i
            if let keys = parseKey(s, &j), j < s.count, s[j] == "=" {
                scanValue(s, from: j + 1, multi: &multi, depth: &depth)
                out.append(TOMLLine(text: text, kind: .key(keys), table: table, valueStart: j + 1))
            } else {
                out.append(TOMLLine(text: text, kind: .other, table: table))
            }
        }
        return out
    }

    /// A dotted key from `i`, stopping after it and any spaces: `a."b.c".'d'` is ["a", "b.c", "d"].
    static func parseKey(_ s: [Unicode.Scalar], _ i: inout Int) -> [String]? {
        var segments: [String] = []
        func skipSpaces() { while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 } }
        while true {
            skipSpaces()
            guard i < s.count else { return nil }
            var seg = ""
            if s[i] == "\"" {
                i += 1
                while i < s.count, s[i] != "\"" {
                    if s[i] == "\\", i + 1 < s.count {
                        i += 1
                        switch s[i] {
                        case "n": seg += "\n"
                        case "t": seg += "\t"
                        default: seg.unicodeScalars.append(s[i])
                        }
                    } else {
                        seg.unicodeScalars.append(s[i])
                    }
                    i += 1
                }
                guard i < s.count else { return nil }
                i += 1
            } else if s[i] == "'" {
                i += 1
                while i < s.count, s[i] != "'" { seg.unicodeScalars.append(s[i]); i += 1 }
                guard i < s.count else { return nil }
                i += 1
            } else {
                while i < s.count, s[i].isASCII,
                      s[i].properties.isAlphabetic || ("0"..."9").contains(s[i]) || s[i] == "_" || s[i] == "-" {
                    seg.unicodeScalars.append(s[i])
                    i += 1
                }
                if seg.isEmpty { return nil }
            }
            segments.append(seg)
            skipSpaces()
            if i < s.count, s[i] == "." { i += 1; continue }
            return segments
        }
    }

    private static func closes(_ s: [Unicode.Scalar], _ i: Int, _ close: String) -> Bool {
        let c = Array(close.unicodeScalars)
        return i + c.count <= s.count && Array(s[i..<(i + c.count)]) == c
    }

    /// Walks a value from `i`, keeping track of an open multi-line string and of open brackets, so
    /// the next lines are known to be part of it.
    static func scanValue(_ s: [Unicode.Scalar], from start: Int, multi: inout String?, depth: inout Int) {
        var i = start
        while i < s.count {
            if let d = multi {
                if d == "\"\"\"", s[i] == "\\" { i += 2; continue }
                if closes(s, i, d) { multi = nil; i += 3; continue }
                i += 1
                continue
            }
            switch s[i] {
            case "#": return
            case "\"", "'":
                let q = s[i]
                if closes(s, i, String(repeating: String(Character(q)), count: 3)) {
                    multi = String(repeating: String(Character(q)), count: 3)
                    i += 3
                    continue
                }
                i += 1
                while i < s.count, s[i] != q {
                    if q == "\"", s[i] == "\\" { i += 1 }
                    i += 1
                }
            case "[", "{": depth += 1
            case "]", "}": depth = max(0, depth - 1)
            default: break
            }
            i += 1
        }
    }

    private static func isServer(_ keys: [String], _ name: String) -> Bool {
        keys.count >= 2 && keys[0] == "mcp_servers" && keys[1] == name
    }

    /// How the file defines the `name` server (`yapshot` unless told otherwise): as a
    /// `[mcp_servers.<name>]` table, by subtables of it, or some other way that Yapshot won't edit
    /// (`other` says which).
    static func tomlFind(_ lines: [TOMLLine], name: String = serverName) -> (table: Bool, subtables: Bool, other: String?) {
        var table = false, subtables = false
        var other: String?
        for l in lines {
            switch l.kind {
            case let .header(k) where isServer(k, name): if k.count == 2 { table = true } else { subtables = true }
            case let .arrayHeader(k) where isServer(k, name): subtables = true
            case let .key(k):
                if l.table == ["mcp_servers"], k.first == name {
                    other = other ?? "defines \(name) inside [mcp_servers] (\(l.text.trimmingCharacters(in: .whitespaces)))"
                } else if l.table.isEmpty, isServer(k, name) {
                    other = other ?? "defines \(name) with dotted keys (\(l.text.trimmingCharacters(in: .whitespaces)))"
                } else if l.table.isEmpty, k == ["mcp_servers"] {
                    other = other ?? "has mcp_servers as an inline table"
                }
            default: break
            }
        }
        return (table, subtables, other)
    }

    /// Whether the file defines a `name` server in any form.
    public static func tomlHasServer(_ text: String, name: String = serverName) -> Bool {
        let f = tomlFind(tomlLines(text), name: name)
        return f.table || f.subtables || f.other != nil
    }

    /// The line range of the `[mcp_servers.<name>]` table itself (header included), not its subtables.
    private static func mainTable(_ lines: [TOMLLine], name: String = serverName) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { $0.kind == .header(["mcp_servers", name]) }) else { return nil }
        let end = lines[(start + 1)...].firstIndex { $0.headerKeys != nil } ?? lines.count
        return start..<end
    }

    /// The command and args the `[mcp_servers.<name>]` table has now.
    static func tomlServerCommand(_ lines: [TOMLLine], name: String = serverName) -> (command: String?, args: [String]?) {
        guard let range = mainTable(lines, name: name) else { return (nil, nil) }
        var command: String?, args: [String]?
        var i = range.lowerBound
        while i < range.upperBound {
            if case let .key(k) = lines[i].kind, k == ["command"] || k == ["args"] {
                var value = String(lines[i].text.unicodeScalars.dropFirst(lines[i].valueStart))
                var j = i + 1
                while j < range.upperBound, lines[j].kind == .continuation { value += "\n" + lines[j].text; j += 1 }
                let strings = tomlStrings(value)
                if k == ["command"] { command = strings.first } else { args = strings }
            }
            i += 1
        }
        return (command, args)
    }

    /// The `command` string of the `[mcp_servers.<name>]` table, if it has one.
    public static func tomlCommand(_ text: String, name: String) -> String? {
        tomlServerCommand(tomlLines(text), name: name).command
    }

    /// The single-line strings in a value, unescaped: enough for `command` and `args`.
    static func tomlStrings(_ value: String) -> [String] {
        let s = Array(value.unicodeScalars)
        var out: [String] = []
        var i = 0
        while i < s.count {
            if s[i] == "#" { break }
            if s[i] == "\"" || s[i] == "'" {
                let q = s[i]
                var str = ""
                i += 1
                while i < s.count, s[i] != q {
                    if q == "\"", s[i] == "\\", i + 1 < s.count {
                        i += 1
                        switch s[i] {
                        case "n": str += "\n"
                        case "t": str += "\t"
                        default: str.unicodeScalars.append(s[i])
                        }
                    } else {
                        str.unicodeScalars.append(s[i])
                    }
                    i += 1
                }
                out.append(str)
            }
            i += 1
        }
        return out
    }

    public static func tomlAdding(_ text: String, command: String, args: [String]) -> String {
        var out = text
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty { out += "\n" }
        out += "[mcp_servers.\(serverName)]\n"
        out += tomlEntryLines(command: command, args: args).joined(separator: "\n") + "\n"
        return out
    }

    private static func tomlEntryLines(command: String, args: [String]) -> [String] {
        ["command = \(tomlString(command))", "args = [\(args.map(tomlString).joined(separator: ", "))]"]
    }

    /// Replaces the `command` and `args` lines of the `[mcp_servers.yapshot]` table, keeping the
    /// table's other keys and every other line of the file.
    public static func tomlUpdating(_ text: String, command: String, args: [String]) -> String {
        let lines = tomlLines(text)
        guard let range = mainTable(lines) else { return tomlAdding(text, command: command, args: args) }
        var body: [String] = []
        var i = range.lowerBound + 1
        while i < range.upperBound {
            if case let .key(k) = lines[i].kind, k == ["command"] || k == ["args"] {
                i += 1
                while i < range.upperBound, lines[i].kind == .continuation { i += 1 }
                continue
            }
            body.append(lines[i].text)
            i += 1
        }
        let texts = lines.map(\.text)
        let new = [texts[range.lowerBound]] + tomlEntryLines(command: command, args: args) + body
        return (Array(texts[..<range.lowerBound]) + new + Array(texts[range.upperBound...])).joined(separator: "\n")
    }

    /// Drops only the lines of the `name` table (`yapshot` unless told otherwise) and its subtables.
    /// Comment lines right above the next table belong to that table and stay. Blank lines are evened
    /// out only where the table was cut out; the rest of the file is left byte for byte.
    public static func tomlRemoving(_ text: String, name: String = serverName) -> String {
        var lines = tomlLines(text)
        let endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { lines.removeLast() }
        var out: [String] = []
        var seam = false
        var i = 0
        while i < lines.count {
            guard let k = lines[i].headerKeys, isServer(k, name) else {
                if seam {
                    if lines[i].kind == .blank { i += 1; continue }
                    if !out.isEmpty { out.append("") }
                    seam = false
                }
                out.append(lines[i].text)
                i += 1
                continue
            }
            var end = i + 1
            while end < lines.count {
                if let next = lines[end].headerKeys, !isServer(next, name) { break }
                end += 1
            }
            if end < lines.count {
                while end - 1 > i, lines[end - 1].kind == .comment { end -= 1 }
            }
            while let last = out.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.removeLast() }
            seam = true
            i = end
        }
        if out.isEmpty { return "" }
        return out.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    }

    /// A TOML basic string.
    static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Claude Code and helpers

    public static func claudeAddArguments(command: String, args: [String]) -> [String] {
        ["mcp", "add", "--scope", "user", serverName, "--", command] + args
    }

    public static let claudeRemoveArguments = ["mcp", "remove", "--scope", "user", serverName]
    public static let claudeRemoveLegacyArguments = ["mcp", "remove", "--scope", "user", legacyServerName]
    public static let claudeGetLegacyArguments = ["mcp", "get", legacyServerName]

    /// The `Command:` line of `claude mcp get <name>` output.
    public static func claudeCommand(fromGetOutput output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Command:") { return t.dropFirst("Command:".count).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// Copies an existing file to `<file>.yapshot-backup-<yyyyMMdd-HHmmss>` beside it.
    public static func backupIfPresent(_ url: URL, now: Date) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var backup = URL(fileURLWithPath: url.path + ".yapshot-backup-" + f.string(from: now))
        var n = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = URL(fileURLWithPath: url.path + ".yapshot-backup-" + f.string(from: now) + "-\(n)")
            n += 1
        }
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }

    /// The first executable `name` on `path` (a PATH value), then in `extra` folders. A GUI app's PATH
    /// is short, so callers pass the usual install folders too.
    public static func findExecutable(_ name: String, path: String?, extra: [String] = []) -> String? {
        let dirs = (path ?? "").split(separator: ":").map(String.init) + extra
        return dirs.map { ($0 as NSString).expandingTildeInPath + "/" + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

extension MCPInstall {
    /// `parseKey` on a whole string, for tests.
    static func parseKeyForTest(_ s: String) -> [String]? {
        var i = 0
        return parseKey(Array(s.unicodeScalars), &i)
    }
}
