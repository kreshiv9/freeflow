import Foundation

/// A missing preference keeps the silence gate on, so a recording without
/// speech ends locally instead of being sent to the transcription provider.
enum SilenceGatePreference {
    static let storageKey = "silence_gate_enabled"
    static let defaultEnabled = true

    /// Returns the default-on choice for missing/invalid values without persisting a default.
    static func load(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: storageKey) as? Bool) ?? defaultEnabled
    }

    /// The stop-time decision: skip the provider round trip only when the gate
    /// is on and the recorder counted no speech.
    static func shouldSkipTranscription(enabled: Bool, speechActivity: SpeechActivityTracker) -> Bool {
        enabled && !speechActivity.hasSpeech
    }

    /// Status shown while a gated dictation winds down.
    static let skippedStatusText = "No speech detected"
    /// Processing status stored on the gated Run Log row. The Run Log compares
    /// it exactly, so a future "Skipped: ..." status cannot inherit its wording.
    static let skippedProcessingStatus = "Skipped: no speech detected"
}
