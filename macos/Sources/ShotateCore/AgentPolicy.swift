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
        default: return .failure(AgentError("--\(name) takes no value"))
        }
    }

    public enum StopAction: Equatable {
        /// Stop the running recording and answer once it's saved.
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
