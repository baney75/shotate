import Foundation

/// What the MCP server's tools do. The server parses and answers messages; a handler does the work,
/// so tests can drive the protocol with a fake one. A thrown `AgentError` becomes a tool result with
/// `isError`, which the agent reads; it isn't a protocol error.
public protocol MCPToolHandler {
    func call(_ tool: String, _ arguments: [String: Any]) throws -> String
}

/// The Model Context Protocol over stdio: JSON-RPC 2.0, one message per line. It runs on this Mac
/// only, as a child process of the agent that started it; it opens no port.
public final class MCPServer {
    public static let protocolVersion = "2025-06-18"
    /// Versions this server can speak. Nothing it uses is newer than the oldest.
    public static let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    private let handler: MCPToolHandler
    private let version: String

    public init(handler: MCPToolHandler, version: String) {
        self.handler = handler
        self.version = version
    }

    /// The tools agents see, with their input schemas.
    public static let tools: [[String: Any]] = [
        tool("send_script", "Give the user a script to read aloud. Saves it in the Scripts folder beside their voice notes "
             + "and opens it in Yapshot's teleprompter, which scrolls while they record a voice note. Sending the same "
             + "title again replaces that script.",
             ["title": string("A short name; it becomes the file name."), "text": string("The script, as plain text.")],
             required: ["title", "text"]),
        tool("list_scripts", "List the saved scripts: name, modified date, word count."),
        tool("read_script", "Read a saved script.", ["name": string("The script's name, as list_scripts shows it.")],
             required: ["name"]),
        tool("delete_script", "Delete a saved script.", ["name": string("The script's name, as list_scripts shows it.")],
             required: ["name"]),
        tool("list_voice_notes", "List the user's voice notes, newest first: name, date, duration in seconds, whether "
             + "it has a transcript, and the script it was read from.",
             ["limit": ["type": "integer", "minimum": 1, "description": "At most this many (default 20)."]]),
        tool("get_transcript", "The transcript of a voice note, with its markers.",
             ["name": string("The voice note's name, as list_voice_notes shows it.")], required: ["name"]),
        tool("status", "Whether Yapshot is running, whether agent control is on, and where voice notes are kept."),
        tool("capture", "Take a screenshot through the running app and return the file path. Needs \"Let Agents Control "
             + "Yapshot\" on in the menu bar icon's menu.",
             ["target": ["type": "string", "enum": ["screen", "window", "area", "app"],
                         "description": "screen, a window (app or window id), an area (rect), or app (its front window)."],
              "app": string("App name or bundle ID, for window or app."),
              "window": ["type": "integer", "description": "A window id from `yapshot windows`."],
              "title": string("Only a window whose title contains this."),
              "rect": string("x,y,w,h in points from the main screen's top left, for area."),
              "out": string("Absolute path for the PNG. Default: the user's screenshots folder.")],
             required: ["target"]),
    ]

    public static var toolNames: [String] { tools.compactMap { $0["name"] as? String } }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:],
                             required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    /// Answers one line. Nil for a notification, which gets no reply.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data) else {
            return encode(error: -32700, "Parse error", id: NSNull())
        }
        guard let message = any as? [String: Any] else {
            return encode(error: -32600, "Invalid Request", id: NSNull())
        }
        let id = message["id"]
        guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return id == nil ? nil : encode(error: -32600, "Invalid Request", id: id!)
        }
        guard let id else { return nil } // notifications/initialized and any other notification
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            // The client's version when this server supports it, as MCP asks; otherwise the latest.
            let asked = params["protocolVersion"] as? String ?? ""
            return encode(result: [
                "protocolVersion": Self.supportedVersions.contains(asked) ? asked : Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "yapshot", "title": "Yapshot", "version": version],
                "instructions": "Yapshot is the user's screenshot and voice notes app on this Mac. send_script puts a script "
                    + "in its teleprompter for the user to read aloud; list_voice_notes and get_transcript read what they recorded.",
            ], id: id)
        case "ping":
            return encode(result: [:], id: id)
        case "tools/list":
            return encode(result: ["tools": Self.tools], id: id)
        case "tools/call":
            guard let name = params["name"] as? String else { return encode(error: -32602, "tools/call needs a name", id: id) }
            guard Self.toolNames.contains(name) else { return encode(error: -32602, "Unknown tool: \(name)", id: id) }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try handler.call(name, arguments)
                return encode(result: ["content": [["type": "text", "text": text]], "isError": false], id: id)
            } catch {
                return encode(result: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true], id: id)
            }
        default:
            return encode(error: -32601, "Method not found: \(method)", id: id)
        }
    }

    private func encode(result: [String: Any], id: Any) -> String {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(error code: Int, _ message: String, id: Any) -> String {
        line(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func line(_ o: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A tool's argument as a string, or an error the agent can read.
    public static func string(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let s = arguments[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError("\(key) is required.")
        }
        return s
    }

    /// Pretty JSON text for a tool result.
    public static func json(_ o: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
