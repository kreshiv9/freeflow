import Foundation

/// Wispr-style Auto Cleanup level. `.none` is the former "Preserve exact wording"
/// toggle; `save` keeps writing that legacy key so an older build behaves the same.
enum CleanupLevel: String, CaseIterable, Codable, Identifiable {
    case none
    case light
    case medium

    var id: String { rawValue }

    static let defaultLevel: CleanupLevel = .light
    static let storageKey = "cleanup_level"
    /// The pre-feature toggle: read only when no level is stored, always written by `save`.
    static let legacyPreserveExactWordingStorageKey = "preserve_exact_wording"

    var displayName: String {
        switch self {
        case .none: "None"
        case .light: "Light"
        case .medium: "Medium"
        }
    }

    /// The Wispr Flow sentence shown under the Settings picker.
    var caption: String {
        switch self {
        case .none:
            "Pastes the raw transcript, including filler words, false starts, and spoken errors."
        case .light:
            "Removes filler words and fixes grammar."
        case .medium:
            "May reword phrases for clarity and conciseness while preserving meaning."
        }
    }

    /// The stop path skips the cleanup model for `.none`, exactly like the old toggle.
    var skipsCleanup: Bool { self == CleanupLevel.none }

    /// Appended after the base system prompt. nil for `.none`, which never reaches the model.
    /// Medium restates Light's duties because only one level line is ever sent.
    var promptDirective: String? {
        switch self {
        case .none:
            nil
        case .light:
            "Cleanup level: Light — remove filler words, false starts and hesitations, fix grammar, punctuation and obvious recognition errors; do not reword."
        case .medium:
            "Cleanup level: Medium — remove filler words, false starts and hesitations, fix grammar, punctuation and obvious recognition errors; in addition, you may reword phrases for clarity and conciseness while preserving meaning."
        }
    }

    /// A stored level wins. Otherwise the legacy toggle migrates: true -> `.none`,
    /// anything else -> `.light`. An invalid or non-string level counts as unset.
    /// Never persists.
    static func load(from defaults: UserDefaults) -> CleanupLevel {
        if let raw = defaults.object(forKey: storageKey) as? String,
           let level = CleanupLevel(rawValue: raw) {
            return level
        }
        let legacyPreserveExactWording = defaults.object(forKey: legacyPreserveExactWordingStorageKey) as? Bool
        return legacyPreserveExactWording == true ? CleanupLevel.none : defaultLevel
    }

    /// Writes the level and mirrors it into the legacy toggle for older builds.
    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
        defaults.set(skipsCleanup, forKey: Self.legacyPreserveExactWordingStorageKey)
    }

    /// Status shown after the Run Log's "Undo AI edit" copies the raw transcript; pinned by tests.
    static let rawTranscriptCopiedStatusText = "Raw transcript copied"
}
