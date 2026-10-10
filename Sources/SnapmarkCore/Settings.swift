import Foundation

/// User settings in the app's standard defaults (domain com.baney.snapmark), so `defaults write com.baney.snapmark` works.
public struct Settings: Equatable {
    public var saveFolder: URL
    public var copyOnCapture: Bool
    public var captureHotkeyEnabled: Bool
    public var showMenuBarIcon: Bool
    /// Extra global shortcuts that run a shell command, e.g. ["cmd+shift+a": "~/bin/open-terminal"].
    public var commandHotkeys: [String: String]

    // Always a directory URL, so it compares equal whether or not the folder exists yet.
    public static let defaultFolder = URL(fileURLWithPath: NSHomeDirectory() + "/Pictures/Screenshots",
                                          isDirectory: true)

    public init(saveFolder: URL = Settings.defaultFolder, copyOnCapture: Bool = true,
                captureHotkeyEnabled: Bool = true, showMenuBarIcon: Bool = true,
                commandHotkeys: [String: String] = [:]) {
        self.saveFolder = saveFolder
        self.copyOnCapture = copyOnCapture
        self.captureHotkeyEnabled = captureHotkeyEnabled
        self.showMenuBarIcon = showMenuBarIcon
        self.commandHotkeys = commandHotkeys
    }

    public static func load(from d: UserDefaults = .standard) -> Settings {
        var s = Settings()
        if let path = d.string(forKey: "saveFolder"), !path.isEmpty {
            s.saveFolder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        if d.object(forKey: "copyOnCapture") != nil { s.copyOnCapture = d.bool(forKey: "copyOnCapture") }
        if d.object(forKey: "captureHotkeyEnabled") != nil { s.captureHotkeyEnabled = d.bool(forKey: "captureHotkeyEnabled") }
        if d.object(forKey: "showMenuBarIcon") != nil { s.showMenuBarIcon = d.bool(forKey: "showMenuBarIcon") }
        s.commandHotkeys = d.dictionary(forKey: "commandHotkeys") as? [String: String] ?? [:]
        return s
    }

    public func save(to d: UserDefaults = .standard) {
        d.set(saveFolder.path, forKey: "saveFolder")
        d.set(copyOnCapture, forKey: "copyOnCapture")
        d.set(captureHotkeyEnabled, forKey: "captureHotkeyEnabled")
        d.set(showMenuBarIcon, forKey: "showMenuBarIcon")
        d.set(commandHotkeys, forKey: "commandHotkeys")
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

    /// Keys a global shortcut can use: letters, digits, and a few named keys.
    public static let supportedKeys: Set<String> = Set("abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
        .union(["space", "return", "escape", "tab", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10",
                "f11", "f12"])
}
