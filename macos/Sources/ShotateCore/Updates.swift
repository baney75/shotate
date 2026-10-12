import Foundation

/// What the update check reads: `manifest.json` on a GitHub release (docs/updates.md).
public struct UpdateManifest: Codable, Equatable {
    public struct Asset: Codable, Equatable {
        public var name: String
        public var url: URL
        public var sha256: String
    }
    public var channel: String
    public var version: String
    public var commit: String
    public var date: Date
    public var notes: URL
    public var assets: [String: Asset]

    public static func decode(_ data: Data) throws -> UpdateManifest {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(UpdateManifest.self, from: data)
    }

    /// Where each channel's newest manifest lives. GitHub redirects these, so there is no API rate limit.
    public static func url(channel: String) -> URL {
        URL(string: channel == "nightly"
            ? "https://github.com/baney75/shotate/releases/download/nightly/manifest.json"
            : "https://github.com/baney75/shotate/releases/latest/download/manifest.json")!
    }
}

/// This build: its version, the commit and channel it was built from, and when.
public struct BuildInfo: Equatable {
    public var version: String
    public var commit: String
    public var channel: String
    public var date: Date

    public init(version: String, commit: String, channel: String, date: Date) {
        self.version = version
        self.commit = commit
        self.channel = channel
        self.date = date
    }

    /// From the app's Info.plist, as `bundle.sh` writes it.
    public init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        version = info["CFBundleShortVersionString"] as? String ?? "0"
        commit = info["ShotateCommit"] as? String ?? "unknown"
        channel = info["ShotateChannel"] as? String ?? "stable"
        date = (info["ShotateBuildDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
    }

    public var shortCommit: String { String(commit.prefix(7)) }
}

public enum Updates {
    public enum Offer: Equatable {
        /// A newer build on the chosen channel.
        case update(UpdateManifest)
        /// A nightly build moving to the stable channel, which may be an older version.
        case switchToStable(UpdateManifest)

        public var manifest: UpdateManifest {
            switch self { case let .update(m), let .switchToStable(m): m }
        }
    }

    /// Whether `remote` should be offered to a build like `local` on `channel`.
    public static func offer(local: BuildInfo, remote: UpdateManifest, channel: String) -> Offer? {
        let known = !local.commit.isEmpty && local.commit != "unknown"
        guard remote.channel == channel, !(known && remote.commit.lowercased() == local.commit.lowercased()) else {
            return nil
        }
        if channel == "nightly" { return remote.date > local.date ? .update(remote) : nil }
        if local.channel == "nightly" { return .switchToStable(remote) }
        return compare(remote.version, local.version) == .orderedDescending ? .update(remote) : nil
    }

    /// Semantic version order: X.Y.Z numerically, a prerelease below its release, build metadata ignored.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ v: String) -> ([Int], String?) {
            let core = v.split(separator: "+", maxSplits: 1).first.map(String.init) ?? v
            let halves = core.split(separator: "-", maxSplits: 1).map(String.init)
            let nums = halves[0].split(separator: ".").map { Int($0) ?? 0 }
            return (nums + Array(repeating: 0, count: max(0, 3 - nums.count)), halves.count > 1 ? halves[1] : nil)
        }
        let (na, pa) = parts(a), (nb, pb) = parts(b)
        for (x, y) in zip(na, nb) where x != y { return x < y ? .orderedAscending : .orderedDescending }
        switch (pa, pb) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (x?, y?): return x == y ? .orderedSame : x.compare(y, options: .numeric)
        }
    }
}
