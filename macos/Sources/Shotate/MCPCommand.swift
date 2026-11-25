import AppKit
import AVFoundation
import ShotateCore

/// `shotate mcp`: Shotate's MCP server on stdin and stdout, for Claude Code, Codex, Cursor and
/// Claude Desktop. Local only: the agent starts it as a child process; no port is opened. Scripts and
/// voice notes are read from the voice notes folder directly; showing a script and capturing ask
/// the running app, like the other `shotate` commands.
enum MCPCommand {
    static func run(_ args: [String]) -> Never {
        switch args.first {
        case nil: serve()
        case "install", "uninstall":
            let p = AgentPolicy.parse(Array(args.dropFirst()))
            switch MCPInstall.clients(p.options["client"]) {
            case let .success(clients):
                let results = MCPSetup.run(install: args[0] == "install", clients: clients)
                AgentCLI.finish(["results": results.map(\.json)])
            case let .failure(e): AgentCLI.fail(e.message)
            }
        default: AgentCLI.fail("Usage: shotate mcp [install|uninstall] [--client claude|codex|cursor|claude-desktop|all]")
        }
    }

    static func serve() -> Never {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let server = MCPServer(handler: MCPTools(), version: version)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let out = server.handle(line: line) else { continue }
            FileHandle.standardOutput.write(Data((out + "\n").utf8))
        }
        exit(0)
    }
}

/// The tools, done here in the `shotate` process.
struct MCPTools: MCPToolHandler {
    var settings: Settings { (try? Settings.load()) ?? Settings() }

    func call(_ tool: String, _ a: [String: Any]) throws -> String {
        let voice = settings.voiceFolder
        switch tool {
        case "send_script":
            let url = try Scripts.save(title: MCPServer.string(a, "title"), text: MCPServer.string(a, "text"), in: voice)
            let name = url.deletingPathExtension().lastPathComponent
            guard AgentCLI.appIsRunning() else {
                return "Saved \u{201C}\(name)\u{201D} to \(url.path). Shotate isn't running, so it isn't on screen; "
                    + "the user can open it from Scripts in Shotate's menu bar menu."
            }
            let r = AgentCLI.send(["command": "script", "path": url.path], wait: 10, launch: false)
            if let e = r["error"] as? String { return "Saved \u{201C}\(name)\u{201D} to \(url.path), but Shotate couldn't show it: \(e)" }
            return "Saved \u{201C}\(name)\u{201D} to \(url.path) and opened it in Shotate's teleprompter. "
                + "The user presses Record there to read it aloud as a voice note."
        case "list_scripts":
            let f = ISO8601DateFormatter()
            return MCPServer.json(["folder": Scripts.folder(in: voice).path, "scripts": Scripts.list(in: voice).map {
                ["name": $0.name, "modified": f.string(from: $0.modified), "words": $0.words] as [String: Any]
            }])
        case "read_script":
            return try Scripts.read(MCPServer.string(a, "name"), in: voice)
        case "delete_script":
            let name = try MCPServer.string(a, "name")
            try Scripts.delete(name, in: voice)
            return "Deleted \u{201C}\(name)\u{201D}."
        case "list_voice_notes":
            let limit = max(1, (a["limit"] as? Int) ?? 20)
            let f = ISO8601DateFormatter()
            let notes = VoiceNotes.library(in: voice) { (try? AVAudioPlayer(contentsOf: $0))?.duration }.prefix(limit)
            return MCPServer.json(["folder": voice.path, "voiceNotes": notes.map { n -> [String: Any] in
                var o: [String: Any] = ["name": n.name, "file": n.url.lastPathComponent, "date": f.string(from: n.date),
                                        "hasTranscript": n.meta.transcript != nil]
                if let d = n.duration { o["duration"] = (d * 10).rounded() / 10 }
                if let s = n.meta.script { o["script"] = s }
                return o
            }])
        case "get_transcript":
            let n = try VoiceNotes.entry(MCPServer.string(a, "name"), in: voice)
            guard let t = n.meta.transcript else {
                throw AgentError("\u{201C}\(n.name)\u{201D} has no transcript yet. The user can transcribe it in Shotate's Voice Notes window.")
            }
            var o: [String: Any] = ["name": n.name, "transcript": t,
                                    "markers": n.meta.markers.map { ["time": $0.time, "label": $0.label] as [String: Any] }]
            if let s = n.meta.script { o["script"] = s }
            return MCPServer.json(o)
        case "status":
            let s = settings
            var o: [String: Any] = ["running": AgentCLI.appIsRunning(), "agentControl": s.agentControl,
                                    "voiceFolder": s.voiceFolder.path, "scriptsFolder": Scripts.folder(in: s.voiceFolder).path]
            if o["running"] as? Bool == true {
                let r = AgentCLI.send(["command": "status"], wait: 5, launch: false)
                for key in ["agentControl", "version", "screenRecording", "recording"] { if let v = r[key] { o[key] = v } }
            }
            return MCPServer.json(o)
        case "capture":
            guard settings.agentControl else {
                throw AgentError("Agent control is off. Ask the user to turn on \"Let Agents Control Shotate\" in Shotate's menu bar icon's menu.")
            }
            let target = try MCPServer.string(a, "target")
            guard ["screen", "window", "area", "app"].contains(target) else { throw AgentError("target is screen, window, area or app.") }
            var r: [String: Any] = ["command": "capture", "mode": target == "app" ? "window" : target]
            for key in ["app", "title", "rect"] { if let v = a[key] as? String { r[key] = v } }
            if let w = a["window"] as? Int { r["window"] = String(w) }
            if let out = a["out"] as? String { r["out"] = AgentCLI.absolute(out) }
            let reply = AgentCLI.send(r, wait: 30)
            if let e = reply["error"] as? String { throw AgentError(e) }
            return MCPServer.json(reply)
        default:
            throw AgentError("Unknown tool \(tool).")
        }
    }
}

/// Registers the server with each client, for `shotate mcp install` and the Settings button.
enum MCPSetup {
    struct Result {
        var client: MCPInstall.Client
        var outcome: String
        var detail: String
        var json: [String: Any] { ["client": client.rawValue, "outcome": outcome, "detail": detail] }
    }

    /// The command agents run: the `shotate` script inside the app, or this binary with --cli.
    static var serverCommand: (String, [String]) {
        let script = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/shotate").path
        if FileManager.default.isExecutableFile(atPath: script) { return (script, ["mcp"]) }
        return (CommandLine.arguments[0].hasPrefix("/") ? CommandLine.arguments[0] : AgentCLI.absolute(CommandLine.arguments[0]),
                ["--cli", "mcp"])
    }

    static func run(install: Bool, clients: [MCPInstall.Client]) -> [Result] {
        let (command, args) = serverCommand
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return clients.map { c in
            guard let file = c.configURL(home: home) else { return claude(install: install, command: command, args: args) }
            do {
                let change: MCPInstall.Change
                switch (c, install) {
                case (.codex, true): change = try MCPInstall.addTOML(at: file, command: command, args: args)
                case (.codex, false): change = try MCPInstall.removeTOML(at: file)
                case (_, true): change = try MCPInstall.addJSON(at: file, command: command, args: args)
                case (_, false): change = try MCPInstall.removeJSON(at: file)
                }
                let path = (file.path as NSString).abbreviatingWithTildeInPath
                let backup = change.backup.map { " (backup: \(($0.path as NSString).abbreviatingWithTildeInPath))" } ?? ""
                let detail: String
                switch change.outcome {
                case .added: detail = "Added shotate to \(path)\(backup)."
                case .alreadyThere: detail = "\(path) already has a shotate entry; left it as it is."
                case .removed: detail = "Removed shotate from \(path)\(backup)."
                case .notThere: detail = "\(path) has no shotate entry."
                }
                return Result(client: c, outcome: change.outcome.rawValue, detail: detail)
            } catch {
                return Result(client: c, outcome: "error", detail: error.localizedDescription)
            }
        }
    }

    /// Claude Code keeps its own config: its `claude mcp` command edits it.
    static func claude(install: Bool, command: String, args: [String]) -> Result {
        let argv = install ? MCPInstall.claudeAddArguments(command: command, args: args) : MCPInstall.claudeRemoveArguments
        guard let claude = MCPInstall.findExecutable("claude", path: ProcessInfo.processInfo.environment["PATH"],
                                                     extra: ["~/.local/bin", "~/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]) else {
            return Result(client: .claude, outcome: "skipped",
                          detail: "claude isn't on PATH. To add it later: claude " + argv.joined(separator: " "))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = argv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(client: .claude, outcome: "error", detail: error.localizedDescription) }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        if p.terminationStatus == 0 {
            return Result(client: .claude, outcome: install ? "added" : "removed",
                          detail: install ? "Ran claude mcp add: shotate is in Claude Code's user config." : "Ran claude mcp remove.")
        }
        let lower = output.lowercased()
        if install, lower.contains("already exists") {
            return Result(client: .claude, outcome: "alreadyThere", detail: "Claude Code already has a shotate server; left it as it is.")
        }
        if !install, lower.contains("no ") || lower.contains("not found") {
            return Result(client: .claude, outcome: "notThere", detail: "Claude Code has no shotate server.")
        }
        return Result(client: .claude, outcome: "error", detail: "claude \(argv.joined(separator: " ")) failed: \(output)")
    }
}
