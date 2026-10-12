import AppKit
import ShotateCore

/// Finds and installs updates on the stable or nightly channel (docs/updates.md). A check is one
/// HTTPS request for a release's manifest.json on GitHub, with no identifiers. Installing builds the
/// release from source in the background, the same way the installer does, so macOS keeps the Screen
/// Recording permission; `bundle.sh --install` then quits this copy and opens the new one.
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(Updates.Offer)
        case installing
        case failed(String)
    }

    let build = BuildInfo(bundle: .main)
    private(set) var state: State = .idle { didSet { onChange?() } }
    /// Called on main whenever `state` changes.
    var onChange: (() -> Void)?
    private let settings: () -> Settings
    private var timer: Timer?
    static let log = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Shotate/update.log")

    init(settings: @escaping () -> Settings) { self.settings = settings }

    /// The channel in use: the one chosen in Settings, or the one this build came from.
    var channel: String { settings().updateChannel ?? build.channel }

    var available: Updates.Offer? {
        if case let .available(o) = state { return o }
        return nil
    }

    /// Checks shortly after launch, then once a day, while automatic checks are on.
    func start() {
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check(manual: false)
        }
    }

    /// Looks for an update. Automatic checks stay quiet on failure and do nothing when turned off.
    func check(manual: Bool, completion: ((State) -> Void)? = nil) {
        guard manual || settings().checkForUpdates, state != .checking, state != .installing else { return }
        let channel = channel
        let previous = state
        state = .checking
        var request = URLRequest(url: UpdateManifest.url(channel: channel), timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession(configuration: .ephemeral).dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 404 {
                    // No build on this channel yet: nothing to offer.
                    self.state = .upToDate(Date())
                } else if let data, status == 200, let m = try? UpdateManifest.decode(data) {
                    self.state = Updates.offer(local: self.build, remote: m, channel: channel).map(State.available)
                        ?? .upToDate(Date())
                } else {
                    let why = error?.localizedDescription ?? "GitHub answered \(status)."
                    self.state = manual ? .failed("Couldn't check for updates. \(why)") : previous
                }
                completion?(self.state)
            }
        }.resume()
    }

    /// Builds and installs the offered release. Needs Apple's command line tools, which the
    /// installer already put in place.
    func install(_ offer: Updates.Offer) {
        guard FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
            || Self.run("/usr/bin/xcode-select", ["-p"]) else {
            state = .failed("Updating needs Apple's command line tools. Run the install command from "
                            + "github.com/baney75/shotate in Terminal instead.")
            return
        }
        let m = offer.manifest
        // These go into a shell script, so accept only the shapes CI writes.
        guard m.version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.]+)?$"#, options: .regularExpression) != nil,
              m.commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              Settings.channels.contains(m.channel) else {
            state = .failed("The update's details look wrong, so Shotate didn't install it.")
            return
        }
        // A stable release is its tag; a nightly is the exact commit it was built from.
        let ref = m.channel == "stable" ? "refs/tags/v\(m.version):refs/tags/v\(m.version)" : m.commit
        let script = """
        set -euo pipefail
        echo "== $(date) updating to Shotate \(m.version) (\(m.channel))"
        dir=$(mktemp -d)
        trap 'rm -rf "$dir"' EXIT
        cd "$dir"
        git init -q
        git fetch -q --depth 1 https://github.com/baney75/shotate.git '\(ref)'
        git checkout -q FETCH_HEAD
        SHOTATE_CHANNEL=\(m.channel) macos/scripts/bundle.sh --install || {
          open 'shotate://update-failed'
          exit 1
        }
        """
        try? FileManager.default.createDirectory(at: Self.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Detached, so it outlives this copy when bundle.sh quits it.
        p.arguments = ["-c", "nohup /bin/bash -c \"$0\" >> \"$1\" 2>&1 &", script, Self.log.path]
        do {
            try p.run()
            state = .installing
        } catch {
            state = .failed("Couldn't start the update: \(error.localizedDescription)")
        }
    }

    /// Called when the background build failed (it opens shotate://update-failed).
    func installFailed() {
        state = .failed("The update didn't build. Details are in ~/Library/Logs/Shotate/update.log.")
    }

    private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: Words

    /// "Shotate 0.12.1" or "Shotate Nightly (Oct 12)".
    static func name(of m: UpdateManifest) -> String {
        if m.channel == "nightly" {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return "Shotate Nightly (\(f.string(from: m.date)))"
        }
        return "Shotate \(m.version)"
    }

    /// The menu item for a known update.
    static func menuTitle(_ o: Updates.Offer) -> String {
        switch o {
        case let .update(m): "Update to \(name(of: m))…"
        case let .switchToStable(m): "Switch to \(name(of: m))…"
        }
    }

    /// One line for Settings.
    var statusText: String {
        switch state {
        case .idle: return "Shotate \(build.version) (\(build.channel), \(build.shortCommit))."
        case .checking: return "Checking…"
        case let .upToDate(d):
            let ago = RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
            return "Shotate \(build.version) is up to date. Checked \(ago)."
        case let .available(o): return "\(Self.name(of: o.manifest)) is available."
        case .installing: return "Building the update. Shotate restarts by itself in a minute or two."
        case let .failed(why): return why
        }
    }
}
