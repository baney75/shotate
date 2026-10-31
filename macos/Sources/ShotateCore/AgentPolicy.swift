import Foundation

/// The rules the `shotate` command and the app follow when an agent drives a recording, kept apart
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

    /// `shotate stop`'s arguments: nothing, `--any`, or `--any=<yes/no>`. Anything else is an error,
    /// so `--any false` (with a space) can't read as a bare `--any`.
    public static func stopArguments(_ args: [String]) -> Result<Bool, AgentError> {
        if args.isEmpty { return .success(false) }
        guard args.count == 1, args[0] == "--any" || args[0].hasPrefix("--any=") else {
            return .failure(AgentError("stop takes only --any, or --any=true or --any=false"))
        }
        return flag("any", args[0] == "--any" ? nil : String(args[0].dropFirst("--any=".count))).map { args[0] == "--any" ? true : $0 }
    }

    public enum StopAction: Equatable {
        /// Stop the running recording and answer once it's saved. (With `--any` on the user's
        /// recording, an agent result nobody collected is dropped: it would be stale later.)
        case stop
        /// Already stopped and saving: answer once it's saved.
        case waitForSave
        /// The agent's own recording already ended: answer with how.
        case returnUnclaimed
        /// The user's recording: only with `--any`.
        case refuseUsers
        case nothingRecording
    }

    /// `byAgent` says who started the recording that is running or saving.
    public static func stop(active: Bool, saving: Bool, byAgent: Bool, unclaimed: Bool, any: Bool) -> StopAction {
        if !byAgent, !any, active || saving {
            if unclaimed { return .returnUnclaimed }
            return active ? .refuseUsers : .nothingRecording
        }
        if active { return .stop }
        if saving { return .waitForSave }
        return unclaimed ? .returnUnclaimed : .nothingRecording
    }
}

public struct AgentError: Error, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
