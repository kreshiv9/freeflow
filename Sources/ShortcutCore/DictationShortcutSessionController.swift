import Foundation

enum DictationShortcutAction: Equatable {
    case start(RecordingTriggerMode)
    case stop
    case switchedToToggle
    /// A hold released inside the double-tap window. Recording keeps running;
    /// the owner calls `resolvePendingTapStop(deadline:)` at `deadline`, and a
    /// second hold press before then turns the session hands-free.
    case stopUnlessRetapped(deadline: TimeInterval)
    /// A toggle session ended inside the cancel window: discard, do not transcribe.
    case cancel
}

final class DictationShortcutSessionController {
    /// A second hold press this soon after the first turns the session hands-free.
    static let doubleTapWindow: TimeInterval = 0.5
    /// A toggle session ended this soon after it started is cancelled, not transcribed.
    static let cancelWindow: TimeInterval = 0.5

    private(set) var activeMode: RecordingTriggerMode?
    private(set) var toggleStopArmed = false
    /// The hold shortcut has been released since the toggle session began, so its next press ends the session.
    private(set) var holdStopArmed = false
    /// Set while a quick hold tap waits for a second tap.
    private(set) var pendingTapStopDeadline: TimeInterval?
    /// Set by the press that ends a toggle session so the rest of that keypress
    /// cannot start a new one: the default ⌘+Fn press also emits .holdActivated,
    /// and adding a modifier mid-press emits another activation. Survives
    /// `reset()`, which the owner calls while the keys are still down; the next
    /// release clears it.
    private(set) var swallowsActivationsUntilRelease = false
    private var sessionStartedAt: TimeInterval?
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.now = now
    }

    func handle(event: ShortcutEvent, isTranscribing: Bool) -> DictationShortcutAction? {
        // Paste Again and transforms are handled before this controller runs; if
        // one ever reaches here, treat it as a no-op so dictation state is unaffected.
        if event == .copyAgainTriggered { return nil }
        if case .transformTriggered = event { return nil }

        // The matcher emits a batch's activations before its deactivations, so
        // the keypress that ended a session is over once any release arrives.
        if event == .holdDeactivated || event == .toggleDeactivated {
            swallowsActivationsUntilRelease = false
        }

        if activeMode == nil {
            guard !isTranscribing, !swallowsActivationsUntilRelease else { return nil }
            switch event {
            case .toggleActivated:
                activeMode = .toggle
                toggleStopArmed = false
                holdStopArmed = false
                sessionStartedAt = now()
                return .start(.toggle)
            case .holdActivated:
                activeMode = .hold
                toggleStopArmed = false
                holdStopArmed = false
                sessionStartedAt = now()
                return .start(.hold)
            case .holdDeactivated, .toggleDeactivated:
                return nil
            case .copyAgainTriggered:
                return nil
            case .transformTriggered:
                return nil
            }
        }

        guard let mode = activeMode else { return nil }

        switch mode {
        case .hold:
            switch event {
            case .toggleActivated:
                activeMode = .toggle
                toggleStopArmed = false
                holdStopArmed = false
                pendingTapStopDeadline = nil
                return .switchedToToggle
            case .holdDeactivated:
                guard pendingTapStopDeadline == nil else { return nil }
                let deadline = (sessionStartedAt ?? now()) + Self.doubleTapWindow
                guard now() < deadline else {
                    // A hold longer than the window stops immediately, as before.
                    reset()
                    return .stop
                }
                pendingTapStopDeadline = deadline
                return .stopUnlessRetapped(deadline: deadline)
            case .holdActivated:
                guard let deadline = pendingTapStopDeadline else { return nil }
                guard now() < deadline else {
                    // The deferred stop is overdue: it wins and this press is consumed.
                    reset()
                    return .stop
                }
                activeMode = .toggle
                pendingTapStopDeadline = nil
                toggleStopArmed = true
                holdStopArmed = false
                return .switchedToToggle
            case .toggleDeactivated:
                return nil
            case .copyAgainTriggered:
                return nil
            case .transformTriggered:
                return nil
            }

        case .toggle:
            switch event {
            case .toggleDeactivated:
                toggleStopArmed = true
                return nil
            case .toggleActivated:
                guard toggleStopArmed else { return nil }
                return endToggleSession()
            case .holdDeactivated:
                holdStopArmed = true
                return nil
            case .holdActivated:
                guard holdStopArmed else { return nil }
                return endToggleSession()
            case .copyAgainTriggered:
                return nil
            case .transformTriggered:
                return nil
            }
        }
    }

    /// Fires the stop deferred by `.stopUnlessRetapped`. Matching on the exact
    /// deadline makes a timer from an earlier session a no-op.
    func resolvePendingTapStop(deadline: TimeInterval) -> DictationShortcutAction? {
        guard activeMode == .hold, pendingTapStopDeadline == deadline else { return nil }
        reset()
        return .stop
    }

    /// Re-anchors the cancel and double-tap windows at the moment recording
    /// begins, so a Shortcut Start Delay does not eat into them.
    func markRecordingStarted() {
        guard activeMode != nil else { return }
        sessionStartedAt = now()
    }

    func beginManual(mode: RecordingTriggerMode) {
        activeMode = mode
        toggleStopArmed = false
        holdStopArmed = false
        pendingTapStopDeadline = nil
        sessionStartedAt = now()
    }

    func forceToggleMode() {
        activeMode = .toggle
        toggleStopArmed = false
        holdStopArmed = false
        pendingTapStopDeadline = nil
    }

    func reset() {
        activeMode = nil
        toggleStopArmed = false
        holdStopArmed = false
        pendingTapStopDeadline = nil
        sessionStartedAt = nil
    }

    /// Ends the session with the press that reached here; `reset()` deliberately
    /// leaves `swallowsActivationsUntilRelease` alone so the owner's own reset
    /// cannot re-enable the rest of that keypress.
    private func endToggleSession() -> DictationShortcutAction {
        let cancels = sessionStartedAt.map { now() - $0 < Self.cancelWindow } ?? false
        reset()
        swallowsActivationsUntilRelease = true
        return cancels ? .cancel : .stop
    }
}
