import Foundation

/// Everything a user can configure. It lives in a plain JSON file, ~/.config/snapmark/config.json,
/// so people and agents can edit it directly; the app reloads it as soon as it changes, and the
/// Settings window writes the same file.
public struct Settings: Equatable {
    public var saveFolder: URL
    public var copyOnCapture: Bool
    public var showMenuBarIcon: Bool
    /// Global shortcuts by action ("captureArea", "captureWindow", "captureScreen"). Empty means off.
    public var shortcuts: [String: String]
    /// Extra global shortcuts that run a shell command, e.g. ["cmd+shift+a": "~/bin/open-terminal"].
    public var commandHotkeys: [String: String]
    /// Editor tool keys, by tool name ("arrow": "a"). Missing tools keep their default letter.
    public var toolKeys: [String: String]

    // Always a directory URL, so it compares equal whether or not the folder exists yet.
    public static let defaultFolder = URL(fileURLWithPath: NSHomeDirectory() + "/Pictures/Screenshots",
                                          isDirectory: true)
    public static let defaultShortcut = "cmd+shift+s"
    public static let actions = ["captureArea", "captureWindow", "captureScreen"]
    public static let defaultShortcuts = ["captureArea": defaultShortcut, "captureWindow": "", "captureScreen": ""]
    public static let configURL = URL(fileURLWithPath: NSHomeDirectory() + "/.config/snapmark/config.json")

    public init(saveFolder: URL = Settings.defaultFolder, copyOnCapture: Bool = true, showMenuBarIcon: Bool = true,
                shortcuts: [String: String] = Settings.defaultShortcuts, commandHotkeys: [String: String] = [:],
                toolKeys: [String: String] = [:]) {
        self.saveFolder = saveFolder
        self.copyOnCapture = copyOnCapture
        self.showMenuBarIcon = showMenuBarIcon
        self.shortcuts = shortcuts
        self.commandHotkeys = commandHotkeys
        self.toolKeys = toolKeys
    }

    /// The area-capture shortcut, or nil when it is turned off.
    public var captureShortcut: Shortcut? { shortcuts["captureArea"].flatMap(Shortcut.init) }

    // MARK: Tool keys

    /// The single key that picks a tool in the editor.
    public func key(for tool: Tool) -> String {
        let k = toolKeys[tool.title.lowercased()]?.lowercased() ?? ""
        return Settings.isToolKey(k) && !toolKeyClashes(k, except: tool) ? k : tool.rawValue
    }

    public func tool(forKey k: String) -> Tool? { Tool.allCases.first { key(for: $0) == k } }

    static func isToolKey(_ k: String) -> Bool { k.count == 1 && k.first!.isLetter && k.first!.isASCII }

    /// A custom key that is already another tool's key is ignored, so every tool stays reachable.
    private func toolKeyClashes(_ k: String, except tool: Tool) -> Bool {
        Tool.allCases.contains { other in
            guard other != tool else { return false }
            let custom = toolKeys[other.title.lowercased()]?.lowercased()
            return custom == k || (custom == nil && other.rawValue == k)
        }
    }

    // MARK: File

    /// Reads a config file. Missing keys keep their defaults and unknown keys are ignored, so a
    /// hand-edited file with only one setting in it works. Throws when the JSON itself is broken.
    public static func load(from url: URL = Settings.configURL) throws -> Settings {
        let data = try Data(contentsOf: url)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt,
                             userInfo: [NSLocalizedDescriptionKey: "The config file must be a JSON object."])
        }
        var s = Settings()
        if let path = o["saveFolder"] as? String, !path.isEmpty {
            s.saveFolder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let b = o["copyOnCapture"] as? Bool { s.copyOnCapture = b }
        if let b = o["showMenuBarIcon"] as? Bool { s.showMenuBarIcon = b }
        if let m = o["shortcuts"] as? [String: String] {
            for a in actions { if let v = m[a] { s.shortcuts[a] = Shortcut(v) != nil ? v.lowercased() : "" } }
        }
        if let m = o["commands"] as? [String: String] { s.commandHotkeys = m.filter { Shortcut($0.key) != nil } }
        if let m = o["toolKeys"] as? [String: String] { s.toolKeys = m.mapValues { $0.lowercased() } }
        return s
    }

    /// The file as Snapmark writes it: every setting spelled out, with a pointer to the docs.
    public func json() -> Data {
        let home = NSHomeDirectory()
        let folder = saveFolder.path.hasPrefix(home + "/") ? "~" + saveFolder.path.dropFirst(home.count) : saveFolder.path
        var tools: [String: String] = [:]
        for t in Tool.allCases { tools[t.title.lowercased()] = key(for: t) }
        let o: [String: Any] = [
            "_help": "Snapmark settings. Edit and save; Snapmark reloads right away. "
                + "Docs: https://github.com/baney75/snapmark#configuration",
            "saveFolder": folder,
            "copyOnCapture": copyOnCapture,
            "showMenuBarIcon": showMenuBarIcon,
            "shortcuts": shortcuts,
            "commands": commandHotkeys,
            "toolKeys": tools,
        ]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
    }

    public func save(to url: URL = Settings.configURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json().write(to: url, options: .atomic)
    }

    /// Settings from before the config file existed (domain com.baney.snapmark).
    public static func migrated(from d: UserDefaults) -> Settings {
        var s = Settings()
        if let path = d.string(forKey: "saveFolder"), !path.isEmpty {
            s.saveFolder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        if d.object(forKey: "copyOnCapture") != nil { s.copyOnCapture = d.bool(forKey: "copyOnCapture") }
        if d.object(forKey: "showMenuBarIcon") != nil { s.showMenuBarIcon = d.bool(forKey: "showMenuBarIcon") }
        if let k = d.string(forKey: "captureShortcut"), Shortcut(k) != nil { s.shortcuts["captureArea"] = k }
        if d.object(forKey: "captureHotkeyEnabled") != nil, !d.bool(forKey: "captureHotkeyEnabled") {
            s.shortcuts["captureArea"] = ""
        }
        s.commandHotkeys = d.dictionary(forKey: "commandHotkeys") as? [String: String] ?? [:]
        return s
    }

    /// "Snapmark 2026-10-10 at 14.03.22.png" in the save folder; adds " 2", " 3" on a clash.
    public func newCaptureURL(date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Snapmark \(f.string(from: date))"
        var url = saveFolder.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = saveFolder.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        return url
    }
}

/// Parses "cmd+shift+a" style shortcuts into a key and modifier set.
public struct Shortcut: Equatable, Hashable {
    public enum Modifier: String, CaseIterable { case cmd, shift, option, control }
    public let key: String
    public let modifiers: Set<Modifier>

    public init?(_ text: String) {
        var mods = Set<Modifier>()
        var key: String?
        for raw in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch raw {
            case "cmd", "command", "⌘": mods.insert(.cmd)
            case "shift", "⇧": mods.insert(.shift)
            case "opt", "option", "alt", "⌥": mods.insert(.option)
            case "ctrl", "control", "⌃": mods.insert(.control)
            default:
                guard key == nil, Shortcut.supportedKeys.contains(raw) else { return nil }
                key = raw
            }
        }
        guard let k = key, !mods.isEmpty else { return nil }
        self.key = k
        self.modifiers = mods
    }

    /// How macOS menus show it: "⌃⌥⇧⌘S".
    public var displayString: String {
        let glyphs: [(Modifier, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.cmd, "⌘")]
        let named = ["space": "Space", "return": "↩", "escape": "⎋", "tab": "⇥"]
        return glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined() + (named[key] ?? key.uppercased())
    }

    /// Keys a global shortcut can use: letters, digits, and a few named keys.
    public static let supportedKeys: Set<String> = Set("abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
        .union(["space", "return", "escape", "tab", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10",
                "f11", "f12"])
}
