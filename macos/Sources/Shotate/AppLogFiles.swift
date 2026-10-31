import AppKit
import ShotateCore

/// The log files a recorded app writes while it is recorded, beyond the system log: Electron and
/// Node apps (T3 Code, Claude, Proton) never send their own output to the system log. Shotate notes
/// each candidate file's size when recording starts and, when it stops, copies what was added.
///
/// Candidates: files the app's processes hold open for writing (`lsof`), and log files in
/// ~/Library/Logs/<app>, ~/Library/Application Support/<app>/logs and any folder named for the app
/// in `appLogs` in the config. Crash reports the app leaves meanwhile are listed too.
final class AppLogFiles {
    private let folders: [URL]
    private let pids: [pid_t]
    private let names: [String]
    private let started = Date()
    private var sizes: [String: Int] = [:]

    static let extensions: Set<String> = ["log", "txt", "ndjson", "jsonl", "out", "err"]
    /// Per file: what's copied into the recording's folder, and how much of it is read for the note.
    static let copyLimit = 8 * 1_048_576
    static let readLimit = 256 * 1024
    static let fileLimit = 12

    init(pid: pid_t, extraFolders: [String: [String]]) {
        let app = NSRunningApplication(processIdentifier: pid)
        let name = app?.localizedName
        let bundleID = app?.bundleIdentifier
        let exe = app?.executableURL?.lastPathComponent
        names = [name, exe].compactMap { $0 }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var dirs: [URL] = []
        for n in Set([name, bundleID, exe].compactMap { $0 }) {
            dirs.append(home.appendingPathComponent("Library/Logs/\(n)"))
            dirs.append(home.appendingPathComponent("Library/Application Support/\(n)/logs"))
            dirs.append(home.appendingPathComponent("Library/Application Support/\(n)/Logs"))
        }
        for key in [bundleID, name].compactMap({ $0 }) {
            for p in extraFolders[key] ?? [] {
                dirs.append(URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
            }
        }
        folders = dirs
        pids = Self.processes(of: pid, bundle: app?.bundleURL)
        for f in candidates() { sizes[f] = Self.size(f) }
    }

    struct Collected {
        var files: [DebugReport.AppLogFile] = []
        var crashReports: [String] = []
    }

    /// Copies what each file gained into `folder` and returns the excerpts for the note. Slow work
    /// (file reads); call it off the main thread.
    func collect(into folder: URL) -> Collected {
        var out = Collected()
        let fm = FileManager.default
        var grown: [(path: String, from: Int, to: Int, modified: Date)] = []
        for f in candidates() {
            guard let a = try? fm.attributesOfItem(atPath: f), let size = (a[.size] as? NSNumber)?.intValue,
                  let modified = a[.modificationDate] as? Date, modified >= started.addingTimeInterval(-1) else { continue }
            var from = sizes[f] ?? 0
            if size < from { from = 0 }  // Rotated or truncated: all of it is new.
            if size > from { grown.append((f, from, size, modified)) }
        }
        grown.sort { $0.modified > $1.modified }
        let logs = folder.appendingPathComponent("app-logs")
        var used = Set<String>()
        for g in grown.prefix(Self.fileLimit) {
            guard let h = FileHandle(forReadingAtPath: g.path) else { continue }
            defer { try? h.close() }
            let start = max(g.from, g.to - Self.copyLimit)
            try? h.seek(toOffset: UInt64(start))
            let data = h.readData(ofLength: g.to - start)
            var name = URL(fileURLWithPath: g.path).lastPathComponent
            while used.contains(name) { name = "_" + name }
            used.insert(name)
            try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
            try? data.write(to: logs.appendingPathComponent(name))
            var text = String(decoding: data.suffix(Self.readLimit), as: UTF8.self)
            if data.count > Self.readLimit, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
            out.files.append(.init(path: g.path, added: g.to - g.from, excerpt: LogExcerpt.excerpt(text)))
        }
        let reports = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DiagnosticReports")
        for f in (try? fm.contentsOfDirectory(atPath: reports.path)) ?? [] where names.contains(where: { f.hasPrefix($0) }) {
            let path = reports.appendingPathComponent(f).path
            if let d = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, d >= started {
                out.crashReports.append(path)
            }
        }
        return out
    }

    /// Browser storage that happens to end in .log (LevelDB's write-ahead logs): data, not logs.
    static func isStorage(_ path: String) -> Bool {
        ["/leveldb/", "/IndexedDB/", "/Local Storage/", "/Session Storage/", "/Service Worker/", "/blob_storage/"]
            .contains { path.contains($0) }
    }

    private func candidates() -> Set<String> {
        var files = Set(openForWriting().filter { !Self.isStorage($0) })
        let fm = FileManager.default
        for dir in folders {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if e.level > 3 { e.skipDescendants(); continue }
                if Self.extensions.contains(url.pathExtension.lowercased()), !Self.isStorage(url.path) { files.insert(url.path) }
            }
        }
        return files
    }

    /// Log files the app's processes hold open for writing.
    private func openForWriting() -> [String] {
        guard !pids.isEmpty else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-n", "-P", "-F", "an", "-p", pids.map(String.init).joined(separator: ",")]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var files: [String] = []
        var writing = false
        for line in text.split(separator: "\n") {
            if line.hasPrefix("a") { writing = line.contains("w") || line.contains("u") }
            if line.hasPrefix("n/"), writing {
                let path = String(line.dropFirst())
                if Self.extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) { files.append(path) }
            }
        }
        return files
    }

    /// The app and every process run from inside its bundle (helpers, renderers, servers).
    private static func processes(of pid: pid_t, bundle: URL?) -> [pid_t] {
        guard let bundle else { return [pid] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "^" + NSRegularExpression.escapedPattern(for: bundle.path + "/")]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [pid] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return Array(Set([pid] + text.split(separator: "\n").compactMap { pid_t($0) }))
    }

    private static func size(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
