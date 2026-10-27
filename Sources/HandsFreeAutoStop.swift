import Foundation

/// Ends a recording on its own: a hands-free (toggle) session after the
/// configured silence, and any session at the 20-minute cap with a warning a
/// minute earlier. Pure: AppState feeds it the recorder's speech-activity
/// numbers on each audio-level tick. One instance per recording.
struct HandsFreeAutoStop: Equatable {
    static let silenceTimeoutStorageKey = "hands_free_silence_timeout_seconds"
    static let defaultSilenceTimeoutSeconds = 15
    static let silenceTimeoutRange: ClosedRange<Int> = 5...60
    /// Every session, any trigger mode.
    static let warningMilliseconds: Double = 19 * 60 * 1000
    static let maximumMilliseconds: Double = 20 * 60 * 1000
    static let warningStatusText = "Dictation stops at 20 minutes"

    enum Decision: Equatable {
        // Not `.none`: Optional<Decision>.none would shadow it in tests.
        case continueRecording
        case warn
        case stopForSilence
        case stopAtMaximumDuration
    }

    let silenceTimeoutMilliseconds: Double
    private(set) var hasWarned = false

    init(silenceTimeoutSeconds: Int) {
        silenceTimeoutMilliseconds = Double(Self.clamp(silenceTimeoutSeconds)) * 1000
    }

    static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, silenceTimeoutRange.lowerBound), silenceTimeoutRange.upperBound)
    }

    /// Returns the clamped saved value, or the default for a missing/invalid value, without persisting it.
    static func loadSilenceTimeoutSeconds(from defaults: UserDefaults) -> Int {
        guard let stored = defaults.object(forKey: silenceTimeoutStorageKey) as? Int else {
            return defaultSilenceTimeoutSeconds
        }
        return clamp(stored)
    }

    /// Cap first (deterministic reason), then the hands-free silence rule, then the one-time warning.
    mutating func evaluate(
        mode: RecordingTriggerMode,
        elapsedMilliseconds: Double,
        silenceMilliseconds: Double
    ) -> Decision {
        if elapsedMilliseconds >= Self.maximumMilliseconds {
            return .stopAtMaximumDuration
        }
        if mode == .toggle,
           elapsedMilliseconds >= silenceTimeoutMilliseconds,
           silenceMilliseconds >= silenceTimeoutMilliseconds {
            return .stopForSilence
        }
        if elapsedMilliseconds >= Self.warningMilliseconds, !hasWarned {
            hasWarned = true
            return .warn
        }
        return .continueRecording
    }
}
