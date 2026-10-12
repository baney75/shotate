import Foundation

/// Everything a user can configure. It lives in a plain JSON file, ~/.config/shotate/config.json,
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
    public static let configURL = URL(fileURLWithPath: NSHomeDirectory() + "/.config/shotate/config.json")
    /// Where the app kept its config when it was called Snapmark.
    public static let legacyConfigURL = URL(fileURLWithPath: NSHomeDirectory() + "/.config/snapmark/config.json")

    /// Copies the Snapmark-era config into place the first time Shotate runs, so shortcuts and
    /// folders carry over. The old file is left where it was. Returns true when it copied.
    @discardableResult
    public static func adoptLegacyConfig(from old: URL = legacyConfigURL, to new: URL = configURL) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) else { return false }
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: old, to: new)
            return true
        } catch {
            return false
        }
    }

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
    public func key(for tool: Tool) -> String { resolvedToolKeys[tool] ?? tool.rawValue }

    public func tool(forKey k: String) -> Tool? { resolvedToolKeys.first { $0.value == k }?.key }

    static func isToolKey(_ k: String) -> Bool { k.count == 1 && k.first!.isLetter && k.first!.isASCII }

    /// Every tool's key, guaranteed unique so every tool stays reachable. A custom key is dropped
    /// (the tool keeps its default) when it isn't a letter, when an earlier tool already claimed it,
    /// or when it is the default of a tool that has no custom key. Dropping one custom key can
    /// expose another clash, so this repeats until nothing changes.
    public var resolvedToolKeys: [Tool: String] {
        var custom: [Tool: String] = [:]
        for t in Tool.allCases {
            if let k = toolKeys[t.title.lowercased()]?.lowercased(), Settings.isToolKey(k), k != t.rawValue { custom[t] = k }
        }
        var changed = true
        while changed {
            changed = false
            var claimed: Set<String> = []
            for t in Tool.allCases {
                guard let k = custom[t] else { continue }
                let stealsDefault = Tool.allCases.contains { $0 != t && custom[$0] == nil && $0.rawValue == k }
                if claimed.contains(k) || stealsDefault { custom[t] = nil; changed = true } else { claimed.insert(k) }
            }
        }
        return Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, custom[$0] ?? $0.rawValue) })
    }

    /// Spells out every tool key, the way the file stores them, so memory and disk compare equal.
    public mutating func normalize() {
        toolKeys = Dictionary(uniqueKeysWithValues: resolvedToolKeys.map { ($0.key.title.lowercased(), $0.value) })
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

    /// The file as Shotate writes it: every setting spelled out, with a pointer to the docs.
    public func json() -> Data {
        let home = NSHomeDirectory()
        let folder = saveFolder.path.hasPrefix(home + "/") ? "~" + saveFolder.path.dropFirst(home.count) : saveFolder.path
        var tools: [String: String] = [:]
        for (t, k) in resolvedToolKeys { tools[t.title.lowercased()] = k }
        let o: [String: Any] = [
            "_help": "Shotate settings. Edit and save; Shotate reloads right away. "
                + "Docs: https://github.com/baney75/shotate#configuration",
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

    /// "Shotate 2026-10-10 at 14.03.22.png" in the save folder; adds " 2", " 3" on a clash.
    public func newCaptureURL(date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Shotate \(f.string(from: date))"
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
