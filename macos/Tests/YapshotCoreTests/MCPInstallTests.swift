import XCTest
@testable import YapshotCore

final class MCPInstallTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_764_000_000)

    private func tempFolder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("yapshot-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func read(_ u: URL) throws -> String { try String(contentsOf: u, encoding: .utf8) }

    // MARK: An entry for a moved or translocated app

    func testJSONEntryForAnotherPathIsUpdated() throws {
        let file = try tempFolder().appendingPathComponent("mcp.json")
        let original = #"{"mcpServers": {"yapshot": {"command": "/old/yapshot", "args": ["mcp"], "env": {"A": "1"}}}}"#
        try Data(original.utf8).write(to: file)
        let change = try MCPInstall.addJSON(at: file, command: "/new/yapshot", args: ["mcp"], now: now, isExecutable: { _ in true })
        XCTAssertEqual(change.outcome, .updated)
        XCTAssertEqual(try read(XCTUnwrap(change.backup)), original)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let entry = try XCTUnwrap((root["mcpServers"] as? [String: Any])?["yapshot"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, "/new/yapshot")
        XCTAssertEqual((entry["env"] as? [String: Any])?["A"] as? String, "1")
        XCTAssertEqual(try MCPInstall.addJSON(at: file, command: "/new/yapshot", args: ["mcp"], now: now,
                                              isExecutable: { _ in true }).outcome, .alreadyThere)
        // The same path, but nothing runs there any more.
        XCTAssertEqual(try MCPInstall.addJSON(at: file, command: "/new/yapshot", args: ["mcp"], now: now,
                                              isExecutable: { _ in false }).outcome, .updated)
    }

    func testTOMLEntryForAnotherPathIsUpdatedInPlace() throws {
        let file = try tempFolder().appendingPathComponent("config.toml")
        let original = """
        [mcp_servers.yapshot]
        command = "/old/yapshot"
        args = [
          "--cli",
          "mcp",
        ]
        startup_timeout_sec = 20

        [mcp_servers.yapshot.env]
        A = "1"

        [profiles.fast]
        model = "mini"

        """
        try Data(original.utf8).write(to: file)
        XCTAssertEqual(MCPInstall.tomlServerCommand(MCPInstall.tomlLines(original)).command, "/old/yapshot")
        XCTAssertEqual(MCPInstall.tomlServerCommand(MCPInstall.tomlLines(original)).args, ["--cli", "mcp"])
        let change = try MCPInstall.addTOML(at: file, command: "/new/yapshot", args: ["mcp"], now: now, isExecutable: { _ in true })
        XCTAssertEqual(change.outcome, .updated)
        XCTAssertEqual(try read(XCTUnwrap(change.backup)), original)
        XCTAssertEqual(try read(file), """
        [mcp_servers.yapshot]
        command = "/new/yapshot"
        args = ["mcp"]
        startup_timeout_sec = 20

        [mcp_servers.yapshot.env]
        A = "1"

        [profiles.fast]
        model = "mini"

        """)
        XCTAssertEqual(try MCPInstall.addTOML(at: file, command: "/new/yapshot", args: ["mcp"], now: now,
                                              isExecutable: { _ in true }).outcome, .alreadyThere)
    }

    func testTOMLThatIsNotUTF8IsLeftAlone() throws {
        let file = try tempFolder().appendingPathComponent("config.toml")
        let original = Data([0x6d, 0x6f, 0x64, 0x65, 0x6c, 0x3d, 0x22, 0xff, 0xfe, 0x22, 0x0a])
        try original.write(to: file)
        XCTAssertThrowsError(try MCPInstall.addTOML(at: file, command: "/new/yapshot", args: ["mcp"], now: now,
                                                    isExecutable: { _ in true }))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testInstallRefusesATranslocatedOrReadOnlyApp() {
        XCTAssertNotNil(MCPInstall.installRefusal(
            command: "/private/var/folders/x/T/AppTranslocation/ABC/d/Yapshot.app/Contents/Resources/bin/yapshot", readOnlyVolume: false))
        let message = MCPInstall.installRefusal(command: "/Volumes/Yapshot/Yapshot.app/Contents/Resources/bin/yapshot", readOnlyVolume: true)
        XCTAssertTrue(message?.contains("Applications") == true)
        XCTAssertNil(MCPInstall.installRefusal(command: "/Applications/Yapshot.app/Contents/Resources/bin/yapshot", readOnlyVolume: false))
    }

    // MARK: PATH for claude mcp add

    func testChildPATHAddsTheFoldersSearched() {
        let path = MCPInstall.childPATH(current: "/usr/bin:/bin", extra: ["/opt/homebrew/bin", "/usr/bin", "~/.local/bin"],
                                        found: "/opt/homebrew/bin/claude")
        XCTAssertEqual(path, "/usr/bin:/bin:/opt/homebrew/bin:" + ("~/.local/bin" as NSString).expandingTildeInPath)
        XCTAssertEqual(MCPInstall.childPATH(current: nil, extra: [], found: "/x/y/claude"), "/x/y")
    }

    // MARK: TOML uninstall leaves the rest of the file alone

    func testTOMLRemoveTouchesOnlyTheYapshotLines() throws {
        let before = """
        model = "gpt-5"

        [mcp_servers.github]
        command = "gh-mcp"

        """
        let yapshot = """
        [mcp_servers.yapshot]
        command = "/x"
        args = ["mcp"]

        [mcp_servers.yapshot.env]
        A = "1"


        """
        let after = """
        # profiles
        [profiles.writer]
        prompt = \"\"\"
        First paragraph.



        [not a table]
        Last paragraph.
        \"\"\"

        """
        XCTAssertEqual(MCPInstall.tomlRemoving(before + yapshot + after), before + "\n" + after)
        // At the end of the file, the blank line before it goes too.
        XCTAssertEqual(MCPInstall.tomlRemoving(after + "\n" + yapshot), after)
        XCTAssertEqual(MCPInstall.tomlRemoving(yapshot), "")
        XCTAssertFalse(MCPInstall.tomlHasServer(after))
    }

    // MARK: TOML keys are parsed, quotes and all

    func testQuotedDottedNameIsAnotherServer() throws {
        let file = try tempFolder().appendingPathComponent("config.toml")
        let dev = """
        [mcp_servers."yapshot.dev"]
        command = "/dev/yapshot"

        [mcp_servers."yapshot.dev".env]
        B = "2"

        """
        try Data(dev.utf8).write(to: file)
        XCTAssertFalse(MCPInstall.tomlHasServer(dev))
        XCTAssertEqual(try MCPInstall.removeTOML(at: file, now: now).outcome, .notThere)
        XCTAssertEqual(try read(file), dev)
        XCTAssertEqual(try MCPInstall.addTOML(at: file, command: "/x", args: ["mcp"], now: now).outcome, .added)
        XCTAssertTrue(try read(file).hasPrefix(dev))
        XCTAssertEqual(try MCPInstall.removeTOML(at: file, now: now).outcome, .removed)
        XCTAssertEqual(try read(file), dev)
        XCTAssertEqual(MCPInstall.parseKeyForTest(#"mcp_servers."yapshot.dev".'x y'"#), ["mcp_servers", "yapshot.dev", "x y"])
    }

    func testInlineOrDottedYapshotIsRefusedNotDuplicated() throws {
        let dir = try tempFolder()
        for text in ["[mcp_servers]\nyapshot = { command = \"/x\", args = [\"mcp\"] }\n",
                     "[mcp_servers]\nyapshot.command = \"/x\"\n",
                     "mcp_servers.yapshot.command = \"/x\"\n",
                     "mcp_servers = { github = { command = \"gh\" } }\n"] {
            let file = dir.appendingPathComponent("\(UUID().uuidString).toml")
            try Data(text.utf8).write(to: file)
            XCTAssertThrowsError(try MCPInstall.addTOML(at: file, command: "/x", args: ["mcp"], now: now), text)
            XCTAssertThrowsError(try MCPInstall.removeTOML(at: file, now: now), text)
            XCTAssertEqual(try read(file), text)
        }
        // Other servers written inline are fine.
        let file = dir.appendingPathComponent("ok.toml")
        try Data("[mcp_servers]\ngithub = { command = \"gh\" }\n".utf8).write(to: file)
        XCTAssertEqual(try MCPInstall.addTOML(at: file, command: "/x", args: ["mcp"], now: now).outcome, .added)
    }

    func testAHeaderInsideAMultilineStringIsNotATable() {
        let text = "prompt = '''\n[mcp_servers.yapshot]\n'''\nlist = [\n  [1, 2],\n]\n"
        XCTAssertFalse(MCPInstall.tomlHasServer(text))
        XCTAssertEqual(MCPInstall.tomlRemoving(text), text)
    }

    // MARK: Symlinked configs

    func testSymlinkedConfigIsEditedAtItsTarget() throws {
        let dir = try tempFolder()
        let dotfiles = dir.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        for (name, original) in [("mcp.json", #"{"mcpServers": {}}"#), ("config.toml", "model = \"gpt-5\"\n")] {
            let target = dotfiles.appendingPathComponent(name)
            try Data(original.utf8).write(to: target)
            let link = dir.appendingPathComponent("link-" + name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let json = name.hasSuffix(".json")
            let change = json ? try MCPInstall.addJSON(at: link, command: "/x", args: ["mcp"], now: now)
                              : try MCPInstall.addTOML(at: link, command: "/x", args: ["mcp"], now: now)
            XCTAssertEqual(change.outcome, .added)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path, name)
            XCTAssertTrue(try read(target).contains("/x"), name)
            XCTAssertEqual(try XCTUnwrap(change.backup).deletingLastPathComponent().resolvingSymlinksInPath().path,
                           dotfiles.resolvingSymlinksInPath().path)
            let removed = json ? try MCPInstall.removeJSON(at: link, now: now) : try MCPInstall.removeTOML(at: link, now: now)
            XCTAssertEqual(removed.outcome, .removed)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path, name)
            XCTAssertFalse(try read(target).contains("/x"), name)
        }
    }
}
