import Foundation

/// A missing preference keeps raw pasting in AI apps on, matching Wispr Flow:
/// a dictation into an AI chat skips cleanup so the prompt stays as spoken.
enum AIAppRawTranscriptPreference {
    static let storageKey = "ai_apps_raw_transcript_enabled"
    static let defaultEnabled = true

    /// Returns the default-on choice for missing/invalid values without persisting a default.
    static func load(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: storageKey) as? Bool) ?? defaultEnabled
    }

    /// The app a dictation targets. Text context carries the category and is the
    /// only source that recognizes AI web chats by domain; without it the
    /// recording-start bundle identifier still classifies desktop AI apps.
    static func resolvedCategory(
        textContext: TextContextSnapshot?,
        bundleIdentifier: String?
    ) -> DictationAppCategory {
        textContext?.category
            ?? TextContextCore.category(bundleIdentifier: bundleIdentifier, websiteDomain: nil)
    }

    /// The stop-time decision: skip cleanup only when the setting is on, the
    /// target is an AI chat, and the session is plain dictation. Edit Mode
    /// transforms selected text and is never affected.
    static func shouldPasteRawTranscript(
        enabled: Bool,
        category: DictationAppCategory?,
        isCommandMode: Bool
    ) -> Bool {
        enabled && category == .aiChat && !isCommandMode
    }

    /// Processing statuses stored on the Run Log row; pinned by tests so the
    /// wording cannot drift from the spec.
    static let rawTranscriptProcessingStatus = "Raw transcript (AI app)"
    static let translatedProcessingStatus = "Raw transcript (AI app), translated to output language"
}
