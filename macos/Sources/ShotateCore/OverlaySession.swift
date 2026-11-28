import Foundation

/// Dismiss lifecycle for a fullscreen or floating overlay (capture picker, record picker, paste
/// chooser). Guarantees that:
/// - Every dismiss trigger (Esc, close button, hotkey re-press, right-click, Space/screen/sleep)
///   runs cleanup exactly once and leaves `isActive == false` and `escapeClaimed == false`.
/// - The completion callback runs at most once, even if multiple triggers fire or the session
///   deallocates unexpectedly.
public final class OverlaySession<Outcome> {
    public enum DismissReason: Equatable {
        case escape
        case closeButton
        case hotkey
        case rightClick
        case focusLost
        case systemEvent
        case replaced
        case completed
    }

    public private(set) var isActive = false
    public private(set) var escapeClaimed = false
    public private(set) var lastDismissReason: DismissReason?

    private let claimEscape: (Bool) -> Void
    private let tearDown: () -> Void
    private var completion: ((Outcome?) -> Void)?

    public init(
        claimEscape: @escaping (Bool) -> Void = { _ in },
        tearDown: @escaping () -> Void = {},
        completion: @escaping (Outcome?) -> Void
    ) {
        self.claimEscape = claimEscape
        self.tearDown = tearDown
        self.completion = completion
    }

    /// Marks the overlay visible and claims Escape so Esc works even if key focus is lost.
    public func begin() {
        guard !isActive, completion != nil else { return }
        isActive = true
        escapeClaimed = true
        claimEscape(true)
    }

    /// Finishes with a chosen outcome and tears down the overlay.
    @discardableResult
    public func complete(_ outcome: Outcome) -> Bool {
        finish(outcome: outcome, reason: .completed)
    }

    /// Dismisses without an outcome (Esc, close button, hotkey re-press, system event, etc.).
    @discardableResult
    public func dismiss(_ reason: DismissReason) -> Bool {
        finish(outcome: nil, reason: reason)
    }

    private func finish(outcome: Outcome?, reason: DismissReason) -> Bool {
        guard let done = completion else { return false }
        completion = nil
        lastDismissReason = reason
        isActive = false
        if escapeClaimed {
            escapeClaimed = false
            claimEscape(false)
        }
        tearDown()
        done(outcome)
        return true
    }

    deinit {
        if completion != nil {
            _ = finish(outcome: nil, reason: .systemEvent)
        } else if escapeClaimed {
            escapeClaimed = false
            claimEscape(false)
        }
    }
}
