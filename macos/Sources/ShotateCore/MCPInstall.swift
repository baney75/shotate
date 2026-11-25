import Foundation

/// `shotate mcp install`: registers Shotate's MCP server with the agents on this Mac. Each edit adds
/// or removes only the `shotate` entry, leaves every other entry as it was, and copies the file
/// beside itself first. An entry named `shotate` that is already there is left alone.
public enum MCPInstall {
    public static let serverName = "shotate"

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

        /// The config file Shotate edits, under `home`. Claude Code has none: its own command does it.
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
        case added, alreadyThere, removed, notThere
    }

    public struct Change: Equatable {
        public var outcome: Outcome
        public var file: URL
        /// The copy made before editing; nil when nothing was edited or the file was new.
        public var backup: URL?
    }

    // MARK: JSON (Cursor, Claude Desktop)

    public static func addJSON(at url: URL, command: String, args: [String], now: Date = Date()) throws -> Change {
        var root = try readJSON(url)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if root["mcpServers"] != nil, !(root["mcpServers"] is [String: Any]) {
            throw AgentError("\(url.path): mcpServers isn't an object, so Shotate left the file alone.")
        }
        if servers[serverName] != nil { return Change(outcome: .alreadyThere, file: url) }
        servers[serverName] = ["command": command, "args": args]
        root["mcpServers"] = servers
        let backup = try backupIfPresent(url, now: now)
        try writeJSON(root, to: url)
        return Change(outcome: .added, file: url, backup: backup)
    }

    public static func removeJSON(at url: URL, now: Date = Date()) throws -> Change {
        guard FileManager.default.fileExists(atPath: url.path) else { return Change(outcome: .notThere, file: url) }
        var root = try readJSON(url)
        guard var servers = root["mcpServers"] as? [String: Any], servers[serverName] != nil else {
            return Change(outcome: .notThere, file: url)
        }
        servers[serverName] = nil
        root["mcpServers"] = servers
        let backup = try backupIfPresent(url, now: now)
        try writeJSON(root, to: url)
        return Change(outcome: .removed, file: url, backup: backup)
    }

    /// The file's top-level object; empty when the file is missing or blank. Anything else unreadable
    /// is an error, and the file is left as it was.
    static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: url.path),
              !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError("\(url.path) isn't a JSON object Shotate can read, so it left the file alone.")
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

    public static func addTOML(at url: URL, command: String, args: [String], now: Date = Date()) throws -> Change {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if tomlHasServer(text) { return Change(outcome: .alreadyThere, file: url) }
        let backup = try backupIfPresent(url, now: now)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(tomlAdding(text, command: command, args: args).utf8).write(to: url, options: .atomic)
        return Change(outcome: .added, file: url, backup: backup)
    }

    public static func removeTOML(at url: URL, now: Date = Date()) throws -> Change {
        guard let text = try? String(contentsOf: url, encoding: .utf8), tomlHasServer(text) else {
            return Change(outcome: .notThere, file: url)
        }
        let backup = try backupIfPresent(url, now: now)
        try Data(tomlRemoving(text).utf8).write(to: url, options: .atomic)
        return Change(outcome: .removed, file: url, backup: backup)
    }

    /// Whether a table header line is `[mcp_servers.shotate]` or one of its subtables
    /// (`[mcp_servers.shotate.env]`), with or without quotes around the name.
    static func isShotateHeader(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard t.hasPrefix("["), !t.hasPrefix("[["), let close = t.firstIndex(of: "]") else { return false }
        let key = t[t.index(after: t.startIndex)..<close].replacingOccurrences(of: "\"", with: "")
        return key == "mcp_servers.\(serverName)" || key.hasPrefix("mcp_servers.\(serverName).")
    }

    public static func tomlHasServer(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains(where: isShotateHeader)
    }

    public static func tomlAdding(_ text: String, command: String, args: [String]) -> String {
        var out = text
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty { out += "\n" }
        out += "[mcp_servers.\(serverName)]\n"
        out += "command = \(tomlString(command))\n"
        out += "args = [\(args.map(tomlString).joined(separator: ", "))]\n"
        return out
    }

    /// Drops the `shotate` table and its subtables, up to the next other table, and the blank line
    /// `tomlAdding` put before it.
    public static func tomlRemoving(_ text: String) -> String {
        var kept: [String] = []
        var inShotate = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inShotate = isShotateHeader(line) }
            if inShotate { continue }
            kept.append(line)
        }
        var out = kept.joined(separator: "\n")
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        while out.hasSuffix("\n\n") { out.removeLast() }
        return out
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

    /// Copies an existing file to `<file>.shotate-backup-<yyyyMMdd-HHmmss>` beside it.
    public static func backupIfPresent(_ url: URL, now: Date) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var backup = URL(fileURLWithPath: url.path + ".shotate-backup-" + f.string(from: now))
        var n = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = URL(fileURLWithPath: url.path + ".shotate-backup-" + f.string(from: now) + "-\(n)")
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
