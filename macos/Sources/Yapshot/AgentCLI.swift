import AppKit
import YapshotCore

/// `yapshot <command>`: the command line for people and coding agents. Captures and recordings go
/// through the running app (it holds the Screen Recording permission); `annotate` and `export` run
/// here. Every command prints one JSON object and exits 0, or prints {"error": ...} and exits 1.
enum AgentCLI {
    static let usage = """
    yapshot: screenshots, recordings, annotated docs images, GIFs and MP4s from the command line.

      yapshot status                      Is Yapshot running, recording, allowed to be driven?
      yapshot windows                     Windows on screen: id, app, title, frame (points, top-left origin)
      yapshot capture [screen|window|area] [--app NAME|--pid N|--window ID] [--title T]
                      [--rect x,y,w,h] [--out file.png] [--copy] [--edit]
      yapshot record  [app|screen|area] [--app NAME|--pid N] [--rect x,y,w,h] [--out file.mp4]
                      [--for SECONDS]     Without --for it returns at once; end it with `yapshot stop`.
      yapshot stop [--any]                Stops an agent's recording and waits until it's saved.
                                          --any also stops one the user started.
      yapshot open file.png               Opens an image in Yapshot's editor.
      yapshot annotate in.png out.png --marks marks.json   (or --marks - to read stdin)
      yapshot export in.mp4 [--gif|--mp4] [--out file] [--from S] [--to S] [--width PX] [--fps N]
      yapshot mcp                         MCP server on stdin/stdout for AI agents (local only)
      yapshot mcp install|uninstall [--client claude|codex|cursor|claude-desktop|all]
                                          Registers it with those agents (backs up each file first)

    Everything but status and mcp needs "Let Agents Control Yapshot" on (menu bar icon), or
    "agentControl": true in ~/.config/yapshot/config.json. Docs: https://github.com/baney75/yapshot/blob/main/docs/agents.md
    """

    static func run(_ args: [String]) -> Never {
        guard let command = args.first, !["help", "-h", "--help"].contains(command) else {
            print(usage)
            exit(args.isEmpty ? 1 : 0)
        }
        let (positional, options) = parse(Array(args.dropFirst()))
        switch command {
        case "mcp": MCPCommand.run(Array(args.dropFirst()))
        case "annotate": annotate(positional, options)
        case "export": export(positional, options)
        case "status", "windows":
            finish(send(["command": command], wait: 15, launch: command != "status"))
        case "stop":
            switch AgentPolicy.stopArguments(Array(args.dropFirst())) {
            case let .success(any): finish(send(["command": "stop", "any": any], wait: 300))
            case let .failure(e): fail(e.message)
            }
        case "open":
            guard let path = positional.first else { fail("open needs a file.") }
            finish(send(["command": "open", "path": absolute(path)], wait: 15))
        case "capture", "record":
            var seconds: Double?
            if command == "record" {
                switch AgentPolicy.recordSeconds(options["for"]) {
                case let .success(s): seconds = s
                case let .failure(e): fail(e.message)
                }
            }
            var r: [String: Any] = ["command": command]
            if let mode = positional.first { r["mode"] = mode }
            for key in ["app", "pid", "window", "title", "rect"] { if let v = options[key] { r[key] = v } }
            if let out = options["out"] { r["out"] = absolute(out) }
            switch AgentPolicy.switches(["copy", "edit"], in: options) {
            case let .success(on): for key in on { r[key] = true }
            case let .failure(e): fail(e.message)
            }
            let started = send(r, wait: 30)
            guard command == "record", started["error"] == nil, let seconds else {
                finish(started)
            }
            Thread.sleep(forTimeInterval: seconds)
            finish(send(["command": "stop"], wait: 300))
        default:
            fail("Unknown command \(command). Run `yapshot help`.")
        }
    }

    // MARK: Talking to the app

    /// Posts the request and waits for the app's answer file.
    static func send(_ request: [String: Any], wait: TimeInterval, launch: Bool = true) -> [String: Any] {
        if !appIsRunning() {
            guard launch else { return ["running": false] }
            startApp()
        }
        return post(request, wait: wait)
    }

    /// Posts one request to the app and waits up to `wait` seconds for its reply.
    static func post(_ request: [String: Any], wait: TimeInterval) -> [String: Any] {
        let id = UUID().uuidString
        let reply = AgentProtocol.replyURL(id)
        guard let data = try? JSONSerialization.data(withJSONObject: request), let json = String(data: data, encoding: .utf8) else {
            fail("Couldn't encode the request.")
        }
        DistributedNotificationCenter.default().postNotificationName(AgentProtocol.request, object: id,
                                                                     userInfo: ["request": json], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if let d = try? Data(contentsOf: reply), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                try? FileManager.default.removeItem(at: reply)
                if request["command"] as? String == "status" { o["running"] = true }
                return o
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return ["error": "Yapshot didn't answer within \(Int(wait)) s. Is it running? (`open -a Yapshot`)"]
    }

    /// The app's status reply, or nil when the app isn't up. Other processes of this bundle (the
    /// `yapshot mcp` servers agents keep running) count only if they answer, and only the app does.
    static func ping(wait: TimeInterval = 1) -> [String: Any]? {
        let me = getpid()
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.baney.snapmark")
            .contains { $0.processIdentifier != me && !$0.isTerminated }
        guard others else { return nil }
        let r = post(["command": "status"], wait: wait)
        return r["error"] == nil ? r : nil
    }

    /// Whether the Yapshot app itself is running and answering.
    static func appIsRunning() -> Bool { ping() != nil }

    /// Opens the app this command lives in, in the background, and waits until it answers.
    static func startApp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", Bundle.main.bundleURL.path]
        try? p.run()
        p.waitUntilExit()
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, !appIsRunning() { Thread.sleep(forTimeInterval: 0.2) }
    }

    // MARK: Local commands

    static func annotate(_ positional: [String], _ options: [String: String]) -> Never {
        guard positional.count == 2, let marksPath = options["marks"] else {
            fail("Usage: yapshot annotate in.png out.png --marks marks.json")
        }
        let input = URL(fileURLWithPath: absolute(positional[0]))
        guard let doc = Renderer.loadDocument(at: input) else { fail("\(input.path) isn't an image Yapshot can read.") }
        let data = marksPath == "-" ? FileHandle.standardInput.readDataToEndOfFile()
            : (try? Data(contentsOf: URL(fileURLWithPath: absolute(marksPath)))) ?? Data()
        do {
            for m in try MarkSpec.marks(from: data, imageHeight: doc.image.height) { doc.add(m) }
        } catch { fail(error.localizedDescription) }
        let out = URL(fileURLWithPath: absolute(positional[1]))
        guard let image = Renderer.flatten(doc), let png = Renderer.pngData(image, dpi: doc.dpi),
              (try? png.write(to: out)) != nil else { fail("Couldn't write \(out.path).") }
        finish(["file": out.path, "width": image.width, "height": image.height, "marks": doc.marks.count])
    }

    /// GIF: two-pass palette, so screen text stays crisp. MP4: H.264, yuv420p, even size, fast start,
    /// so it plays everywhere (GitHub, X, Slack, QuickTime).
    static func export(_ positional: [String], _ options: [String: String]) -> Never {
        guard let input = positional.first else { fail("Usage: yapshot export in.mp4 [--gif|--mp4] [--out file]") }
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile) else {
            fail("export needs ffmpeg: brew install ffmpeg")
        }
        let on: Set<String>
        switch AgentPolicy.switches(["gif", "mp4"], in: options) {
        case let .success(s): on = s
        case let .failure(e): fail(e.message)
        }
        let gif = on.contains("gif") || options["out"]?.lowercased().hasSuffix(".gif") == true
        let src = URL(fileURLWithPath: absolute(input))
        let out = options["out"].map { URL(fileURLWithPath: absolute($0)) }
            ?? src.deletingPathExtension().appendingPathExtension(gif ? "gif" : "web.mp4")
        let width = options["width"].flatMap(Int.init) ?? (gif ? 960 : 1920)
        let fps = options["fps"].flatMap(Int.init) ?? (gif ? 15 : 30)
        var a = ["-hide_banner", "-loglevel", "error", "-y"]
        if let from = options["from"] { a += ["-ss", from] }
        if let to = options["to"] { a += ["-to", to] }
        a += ["-i", src.path]
        let scale = "fps=\(fps),scale='min(\(width),iw)':-2:flags=lanczos"
        if gif {
            a += ["-filter_complex", "[0:v]\(scale),split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
                  "-loop", "0", out.path]
        } else {
            a += ["-vf", scale + ",pad=ceil(iw/2)*2:ceil(ih/2)*2", "-c:v", "libx264", "-preset", "slow", "-crf", "20",
                  "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-an", out.path]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = a
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { fail(error.localizedDescription) }
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { fail("ffmpeg: " + message.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? NSNumber)?.intValue ?? 0
        finish(["file": out.path, "bytes": size])
    }

    // MARK: Helpers

    /// `--key value` pairs; see `AgentPolicy.parse`.
    static func parse(_ args: [String]) -> ([String], [String: String]) {
        let p = AgentPolicy.parse(args)
        return (p.positional, p.options)
    }

    static func absolute(_ path: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        return p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
    }

    static func finish(_ o: [String: Any]) -> Never {
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
        exit(o["error"] == nil ? 0 : 1)
    }

    static func fail(_ message: String) -> Never { finish(["error": message]) }
}
