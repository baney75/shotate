import XCTest
@testable import ShotateCore

private final class FakeHandler: MCPToolHandler {
    var calls: [(String, [String: Any])] = []
    func call(_ tool: String, _ arguments: [String: Any]) throws -> String {
        calls.append((tool, arguments))
        if tool == "delete_script" { throw AgentError("No script named x.") }
        return "ok \(tool)"
    }
}

final class MCPTests: XCTestCase {
    private func reply(_ server: MCPServer, _ line: String) throws -> [String: Any] {
        let out = try XCTUnwrap(server.handle(line: line))
        XCTAssertFalse(out.contains("\n"), "one message per line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    func testInitializeAnswersWithVersionAndTools() throws {
        let s = MCPServer(handler: FakeHandler(), version: "1.2.3")
        let r = try reply(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#)
        XCTAssertEqual(r["id"] as? Int, 1)
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["version"] as? String, "1.2.3")
    }

    func testNotificationsGetNoReply() {
        let s = MCPServer(handler: FakeHandler(), version: "1")
        XCTAssertNil(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#))
    }

    func testToolsListHasEveryToolWithASchema() throws {
        let s = MCPServer(handler: FakeHandler(), version: "1")
        let r = try reply(s, #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
        XCTAssertEqual(r["id"] as? String, "a")
        let tools = try XCTUnwrap((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String },
                       ["send_script", "list_scripts", "read_script", "delete_script", "list_voice_notes",
                        "get_transcript", "status", "capture"])
        for t in tools {
            XCTAssertEqual((t["inputSchema"] as? [String: Any])?["type"] as? String, "object")
            XCTAssertFalse((t["description"] as? String ?? "").isEmpty)
        }
    }

    func testToolsCallGoesToTheHandler() throws {
        let h = FakeHandler()
        let s = MCPServer(handler: h, version: "1")
        let r = try reply(s, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"send_script","arguments":{"title":"Intro","text":"Hi"}}}"#)
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, "ok send_script")
        XCTAssertEqual(h.calls.first?.0, "send_script")
        XCTAssertEqual(h.calls.first?.1["title"] as? String, "Intro")
    }

    func testAHandlerErrorIsAToolResultNotAProtocolError() throws {
        let s = MCPServer(handler: FakeHandler(), version: "1")
        let r = try reply(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"delete_script","arguments":{"name":"x"}}}"#)
        XCTAssertNil(r["error"])
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, "No script named x.")
    }

    func testErrors() throws {
        let s = MCPServer(handler: FakeHandler(), version: "1")
        XCTAssertEqual((try reply(s, #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual((try reply(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope"}}"#)["error"] as? [String: Any])?["code"] as? Int, -32602)
        let parse = try reply(s, "{not json")
        XCTAssertEqual((parse["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertTrue(parse["id"] is NSNull)
        XCTAssertEqual((try reply(s, #"{"id":5,"method":"ping"}"#)["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertNotNil(try reply(s, #"{"jsonrpc":"2.0","id":6,"method":"ping"}"#)["result"])
    }

    // MARK: Scripts

    private func tempFolder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("shotate-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testSafeTitle() {
        XCTAssertEqual(Scripts.safeTitle("../../etc/passwd"), "-..-etc-passwd")
        XCTAssertEqual(Scripts.safeTitle(".hidden"), "hidden")
        XCTAssertEqual(Scripts.safeTitle("  "), "Script")
        XCTAssertEqual(Scripts.safeTitle("a\\b:c"), "a-b-c")
        XCTAssertEqual(Scripts.safeTitle(String(repeating: "x", count: 300)).count, 120)
    }

    func testSaveListReadDelete() throws {
        let voice = try tempFolder()
        let url = try Scripts.save(title: "Launch video", text: "Hello there, friends.", in: voice)
        XCTAssertEqual(url.path, voice.appendingPathComponent("Scripts/Launch video.md").path)
        try Scripts.save(title: "Launch video", text: "Hello again.", in: voice)
        let list = Scripts.list(in: voice)
        XCTAssertEqual(list.map(\.name), ["Launch video"])
        XCTAssertEqual(list.first?.words, 2)
        XCTAssertEqual(try Scripts.read("Launch video", in: voice), "Hello again.")
        XCTAssertEqual(try Scripts.read("Launch video.md", in: voice), "Hello again.")
        try Scripts.delete("Launch video", in: voice)
        XCTAssertTrue(Scripts.list(in: voice).isEmpty)
        XCTAssertThrowsError(try Scripts.read("Launch video", in: voice))
    }

    /// delete_script and read_script never reach outside the Scripts folder.
    func testPathTraversalIsRejected() throws {
        let voice = try tempFolder()
        try Scripts.save(title: "Keep", text: "x", in: voice)
        let outside = voice.appendingPathComponent("secret.md")
        try Data("secret".utf8).write(to: outside)
        for name in ["../secret", "../secret.md", "..", ".", "a/../../secret", "/etc/passwd", "~/secret", ".Keep", "", "Keep/.."] {
            XCTAssertThrowsError(try Scripts.delete(name, in: voice), name)
            XCTAssertThrowsError(try Scripts.read(name, in: voice), name)
        }
        // A symlink in the folder that points out of it is refused too.
        try FileManager.default.createSymbolicLink(at: Scripts.folder(in: voice).appendingPathComponent("link.md"),
                                                   withDestinationURL: outside)
        XCTAssertThrowsError(try Scripts.delete("link", in: voice))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(Scripts.list(in: voice).filter { $0.name == "Keep" }.count, 1)
    }

    func testVoiceLibraryReadsSidecars() throws {
        let voice = try tempFolder()
        let a = voice.appendingPathComponent("Standup.m4a"), b = voice.appendingPathComponent("Later.wav")
        try Data().write(to: a)
        try Data().write(to: b)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: a.path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: b.path)
        try Data("not audio".utf8).write(to: voice.appendingPathComponent("notes.txt"))
        let meta = VoiceMeta(transcript: "Ship it.", duration: 12.5, script: "Launch video")
        try FileManager.default.createDirectory(at: VoiceNotes.sidecarURL(for: a).deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(meta).write(to: VoiceNotes.sidecarURL(for: a))
        let lib = VoiceNotes.library(in: voice) { _ in 3 }
        XCTAssertEqual(lib.map(\.name), ["Later", "Standup"])
        XCTAssertEqual(lib[0].duration, 3)
        XCTAssertNil(lib[0].meta.transcript)
        XCTAssertEqual(lib[1].duration, 12.5)
        XCTAssertEqual(lib[1].meta.script, "Launch video")
        XCTAssertEqual(try VoiceNotes.entry("Standup", in: voice).meta.transcript, "Ship it.")
        XCTAssertEqual(try VoiceNotes.entry("Standup.m4a", in: voice).name, "Standup")
        XCTAssertThrowsError(try VoiceNotes.entry("../Standup", in: voice))
        XCTAssertThrowsError(try VoiceNotes.entry("Nope", in: voice))
    }

    /// Sidecars written before `script` existed still read.
    func testOldSidecarDecodes() throws {
        let m = try JSONDecoder().decode(VoiceMeta.self, from: Data(#"{"markers":[],"transcript":"hi"}"#.utf8))
        XCTAssertEqual(m.transcript, "hi")
        XCTAssertNil(m.script)
    }

    // MARK: Install

    private let now = Date(timeIntervalSince1970: 1_764_000_000)

    func testJSONMergeKeepsOtherServersAndBacksUp() throws {
        let dir = try tempFolder()
        let file = dir.appendingPathComponent("mcp.json")
        let original = #"{"mcpServers": {"github": {"command": "gh-mcp", "args": []}}, "theme": "dark"}"#
        try Data(original.utf8).write(to: file)
        let change = try MCPInstall.addJSON(at: file, command: "/Apps/shotate", args: ["mcp"], now: now)
        XCTAssertEqual(change.outcome, .added)
        let backup = try XCTUnwrap(change.backup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(root["theme"] as? String, "dark")
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["github"] as? [String: Any])?["command"] as? String, "gh-mcp")
        XCTAssertEqual((servers["shotate"] as? [String: Any])?["command"] as? String, "/Apps/shotate")
        XCTAssertEqual((servers["shotate"] as? [String: Any])?["args"] as? [String], ["mcp"])

        XCTAssertEqual(try MCPInstall.addJSON(at: file, command: "/Apps/shotate", args: ["mcp"], now: now,
                                              isExecutable: { _ in true }).outcome, .alreadyThere)
        let removed = try MCPInstall.removeJSON(at: file, now: now)
        XCTAssertEqual(removed.outcome, .removed)
        XCTAssertNotEqual(removed.backup, backup)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((after["mcpServers"] as? [String: Any])?.keys.sorted(), ["github"])
        XCTAssertEqual(try MCPInstall.removeJSON(at: file, now: now).outcome, .notThere)
    }

    func testJSONNewFileAndBadFile() throws {
        let dir = try tempFolder()
        let file = dir.appendingPathComponent("Claude/claude_desktop_config.json")
        let change = try MCPInstall.addJSON(at: file, command: "/x", args: ["mcp"], now: now)
        XCTAssertEqual(change.outcome, .added)
        XCTAssertNil(change.backup)
        let bad = dir.appendingPathComponent("bad.json")
        try Data("{ oops".utf8).write(to: bad)
        XCTAssertThrowsError(try MCPInstall.addJSON(at: bad, command: "/x", args: [], now: now))
        XCTAssertEqual(try String(contentsOf: bad, encoding: .utf8), "{ oops")
        XCTAssertEqual(try MCPInstall.removeJSON(at: dir.appendingPathComponent("missing.json"), now: now).outcome, .notThere)
    }

    func testTOMLAddAndRemove() throws {
        let dir = try tempFolder()
        let file = dir.appendingPathComponent("config.toml")
        let original = """
        model = "gpt-5"

        [mcp_servers.github]
        command = "gh-mcp"

        [profiles.fast]
        model = "mini"
        """
        try Data(original.utf8).write(to: file)
        let change = try MCPInstall.addTOML(at: file, command: "/Apps/Sho \"tate\"/shotate", args: ["mcp"], now: now)
        XCTAssertEqual(change.outcome, .added)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(change.backup), encoding: .utf8), original)
        let added = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(added.hasPrefix(original))
        XCTAssertTrue(added.contains("[mcp_servers.shotate]\ncommand = \"/Apps/Sho \\\"tate\\\"/shotate\"\nargs = [\"mcp\"]\n"))
        XCTAssertEqual(try MCPInstall.addTOML(at: file, command: "/Apps/Sho \"tate\"/shotate", args: ["mcp"], now: now,
                                              isExecutable: { _ in true }).outcome, .alreadyThere)

        // A subtable the user added under it goes too; the tables after it stay.
        try Data((added + "\n[mcp_servers.shotate.env]\nA = \"1\"\n\n[tools]\nweb = true\n").utf8).write(to: file)
        XCTAssertEqual(try MCPInstall.removeTOML(at: file, now: now).outcome, .removed)
        let removed = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(removed.contains("shotate"))
        XCTAssertTrue(removed.hasPrefix(original))
        XCTAssertTrue(removed.contains("[tools]\nweb = true"))
        XCTAssertTrue(removed.contains("[mcp_servers.github]\ncommand = \"gh-mcp\""))
        XCTAssertEqual(try MCPInstall.removeTOML(at: file, now: now).outcome, .notThere)
    }

    func testTOMLHeaderForms() {
        XCTAssertTrue(MCPInstall.tomlHasServer("[mcp_servers.\"shotate\"]\ncommand = \"x\""))
        XCTAssertTrue(MCPInstall.tomlHasServer("  [ mcp_servers.shotate ]  "))
        XCTAssertFalse(MCPInstall.tomlHasServer("[mcp_servers.shotate2]"))
        XCTAssertFalse(MCPInstall.tomlHasServer("# [mcp_servers.shotate]"))
        XCTAssertEqual(MCPInstall.tomlAdding("", command: "/x", args: ["mcp"]), "[mcp_servers.shotate]\ncommand = \"/x\"\nargs = [\"mcp\"]\n")
    }

    func testClientsAndClaudeArguments() {
        XCTAssertEqual(try MCPInstall.clients(nil).get(), MCPInstall.Client.allCases)
        XCTAssertEqual(try MCPInstall.clients("claude-desktop").get(), [.claudeDesktop])
        XCTAssertThrowsError(try MCPInstall.clients("vscode").get())
        XCTAssertEqual(MCPInstall.claudeAddArguments(command: "/b/shotate", args: ["mcp"]),
                       ["mcp", "add", "--scope", "user", "shotate", "--", "/b/shotate", "mcp"])
        let home = URL(fileURLWithPath: "/Users/t")
        XCTAssertEqual(MCPInstall.Client.cursor.configURL(home: home)?.path, "/Users/t/.cursor/mcp.json")
        XCTAssertEqual(MCPInstall.Client.codex.configURL(home: home)?.path, "/Users/t/.codex/config.toml")
        XCTAssertNil(MCPInstall.Client.claude.configURL(home: home))
    }

    func testBackupNamesDontCollide() throws {
        let dir = try tempFolder()
        let file = dir.appendingPathComponent("c.json")
        try Data("{}".utf8).write(to: file)
        let a = try XCTUnwrap(MCPInstall.backupIfPresent(file, now: now))
        let b = try XCTUnwrap(MCPInstall.backupIfPresent(file, now: now))
        XCTAssertNotEqual(a, b)
    }

    func testInitializeEchoesASupportedOlderVersion() throws {
        let s = MCPServer(handler: FakeHandler(), version: "1")
        for (asked, answer) in [("2024-11-05", "2024-11-05"), ("2025-03-26", "2025-03-26"), ("2025-06-18", "2025-06-18"),
                                ("1999-01-01", "2025-06-18")] {
            let r = try reply(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(asked)"}}"#)
            XCTAssertEqual((r["result"] as? [String: Any])?["protocolVersion"] as? String, answer, asked)
        }
        let none = try reply(s, #"{"jsonrpc":"2.0","id":2,"method":"initialize"}"#)
        XCTAssertEqual((none["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
    }

    /// Every name list_scripts shows reads back: .txt files, a title that ended in .md, and two files
    /// with the same base name.
    func testEveryListedScriptNameReadsBack() throws {
        let voice = try tempFolder()
        let dir = Scripts.folder(in: voice)
        let intro = try Scripts.save(title: "Intro.md", text: "intro", in: voice)
        XCTAssertEqual(intro.lastPathComponent, "Intro.md")
        XCTAssertEqual(Scripts.safeTitle("Notes.TXT"), "Notes")
        try Data("plan".utf8).write(to: dir.appendingPathComponent("Plan.txt"))
        try Data("dup md".utf8).write(to: dir.appendingPathComponent("Dup.md"))
        try Data("dup txt".utf8).write(to: dir.appendingPathComponent("Dup.txt"))
        try Data("old".utf8).write(to: dir.appendingPathComponent("Old.md.md"))
        let names = Scripts.list(in: voice).map(\.name)
        XCTAssertEqual(Set(names), ["Intro", "Plan", "Dup.md", "Dup.txt", "Old.md"])
        for info in Scripts.list(in: voice) {
            XCTAssertEqual(try Scripts.resolve(info.name, in: voice).lastPathComponent, info.url.lastPathComponent, info.name)
        }
        XCTAssertEqual(try Scripts.read("Plan", in: voice), "plan")
        XCTAssertEqual(try Scripts.read("Plan.txt", in: voice), "plan")
        XCTAssertEqual(try Scripts.read("Intro.md", in: voice), "intro")
        XCTAssertEqual(try Scripts.read("Dup", in: voice), "dup md")
        try Scripts.delete("Plan", in: voice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Plan.txt").path))
    }

    /// Durations are measured only for the notes returned.
    func testVoiceLibraryLimitMeasuresOnlyWhatItReturns() throws {
        let voice = try tempFolder()
        for i in 0..<10 {
            let u = voice.appendingPathComponent("Note \(i).m4a")
            try Data().write(to: u)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: Double(1000 + i))], ofItemAtPath: u.path)
        }
        var measured: [String] = []
        let lib = VoiceNotes.library(in: voice, limit: 2) { measured.append($0.lastPathComponent); return 1 }
        XCTAssertEqual(lib.map(\.name), ["Note 9", "Note 8"])
        XCTAssertEqual(lib.map(\.duration), [1, 1])
        XCTAssertEqual(measured.sorted(), ["Note 8.m4a", "Note 9.m4a"])
    }
}
