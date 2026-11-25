import Foundation

/// The rules the `yapshot` command and the app follow when an agent drives a recording, kept apart
/// so tests pin them: how long `--for` may be, what a yes/no flag means, and what `stop` does.
public enum AgentPolicy {
    /// The longest `record --for`.
    public static let maxSeconds: Double = 4 * 3600

    /// `--for`: nil when absent; a finite number of seconds from just above 0 to 4 hours; otherwise
    /// an error ("20s", "true", "inf", "nan", "-5", "99999").
    public static func recordSeconds(_ value: String?) -> Result<Double?, AgentError> {
        guard let value else { return .success(nil) }
        guard let s = Double(value), s.isFinite, s > 0, s <= maxSeconds else {
            return .failure(AgentError("--for needs seconds, up to 4 hours, e.g. --for 20"))
        }
        return .success(s)
    }

    /// A flag such as `--any`: bare or true/1/yes is on; absent or false/0/no is off; anything else
    /// is an error, so `--any=false` never means yes.
    public static func flag(_ name: String, _ value: String?) -> Result<Bool, AgentError> {
        guard let value else { return .success(false) }
        switch value.lowercased() {
        case "true", "1", "yes": return .success(true)
        case "false", "0", "no": return .success(false)
        default: return .failure(AgentError("--\(name) is a switch: --\(name), or --\(name)=true or --\(name)=false"))
        }
    }

    /// `yapshot stop`'s arguments: nothing, `--any`, or `--any=<yes/no>`. Anything else is an error,
    /// so `--any false` (with a space) can't read as a bare `--any`.
    public static func stopArguments(_ args: [String]) -> Result<Bool, AgentError> {
        if args.isEmpty { return .success(false) }
        guard args.count == 1, args[0] == "--any" || args[0].hasPrefix("--any=") else {
            return .failure(AgentError("stop takes only --any, or --any=true or --any=false"))
        }
        return flag("any", args[0] == "--any" ? nil : String(args[0].dropFirst("--any=".count))).map { args[0] == "--any" ? true : $0 }
    }

    /// The command line's `--key value` pairs and positional words. A `--flag` with no value (or
    /// followed by another option) is "true"; `--key=value` keeps the value as written. Switches
    /// never take the next word, so `--copy out.png` can't swallow a file name.
    public static func parse(_ args: [String]) -> (positional: [String], options: [String: String]) {
        var positional: [String] = []
        var options: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--"), a.count > 2 {
                let key = String(a.dropFirst(2))
                if let eq = key.firstIndex(of: "=") {
                    options[String(key[..<eq])] = String(key[key.index(after: eq)...])
                } else if i + 1 < args.count, !args[i + 1].hasPrefix("--") || args[i + 1] == "-",
                          !switchNames.contains(key) {
                    options[key] = args[i + 1]
                    i += 1
                } else {
                    options[key] = "true"
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
        return (positional, options)
    }

    /// The options that are yes/no switches.
    public static let switchNames: Set<String> = ["copy", "edit", "gif", "mp4", "any"]

    /// The switches among `names` that are on, each read by `flag`, so `--copy=false`, `--edit=0` or
    /// `--gif=no` is off and `--gif=maybe` is an error.
    public static func switches(_ names: [String], in options: [String: String]) -> Result<Set<String>, AgentError> {
        var on: Set<String> = []
        for name in names {
            switch flag(name, options[name]) {
            case let .success(yes): if yes { on.insert(name) }
            case let .failure(e): return .failure(e)
            }
        }
        return .success(on)
    }

    public enum StopAction: Equatable {
        /// Stop the running recording and answer once it's saved.
        case stop(dropUnclaimed: Bool)
        /// Already stopped and saving: answer once it's saved.
        case waitForSave(dropUnclaimed: Bool)
        /// The agent's own recording already ended: answer with how.
        case returnUnclaimed
        /// The user's recording: only with `--any`.
        case refuseUsers
        case nothingRecording
    }

    /// `byAgent` says who started the recording that is running or saving. With `--any` on the
    /// user's recording, running or saving, the agent gets the user's recording, so an agent result
    /// nobody collected is dropped (`dropUnclaimed`): a later `stop` would pass it off as fresh.
    public static func stop(active: Bool, saving: Bool, byAgent: Bool, unclaimed: Bool, any: Bool) -> StopAction {
        if !byAgent, !any, active || saving {
            if unclaimed { return .returnUnclaimed }
            return active ? .refuseUsers : .nothingRecording
        }
        let drop = !byAgent && any
        if active { return .stop(dropUnclaimed: drop) }
        if saving { return .waitForSave(dropUnclaimed: drop) }
        return unclaimed ? .returnUnclaimed : .nothingRecording
    }

    /// The reply key for a recording's error: "warning" only for a partial save (the 90 s watchdog
    /// handed over the video as it was, while the stills and note ran late), so the command exits 0.
    /// Any other error is "error" (exit 1), even when the video was kept: it may be incomplete.
    public static func recordingProblemKey(kept: Bool, partial: Bool) -> String {
        kept && partial ? "warning" : "error"
    }
}

public struct AgentError: Error, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
