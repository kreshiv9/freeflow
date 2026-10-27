import Foundation

/// Wispr-style tone for English dictations; one "Style:" line appended to the cleanup prompt.
enum DictationStyle: String, CaseIterable, Codable, Identifiable {
    case formal
    case casual
    case veryCasual
    case excited

    var id: String { rawValue }

    /// Wispr Flow's own labels, punctuation and casing included.
    var displayName: String {
        switch self {
        case .formal: "Formal."
        case .casual: "Casual"
        case .veryCasual: "very casual"
        case .excited: "Excited!"
        }
    }

    /// Single line, no newline, no em dash (the prompt forbids inserting them).
    var directive: String {
        switch self {
        case .formal:
            "Formal. Use standard capitalization and full punctuation, with a period ending every sentence."
        case .casual:
            "Casual. Use standard capitalization with lighter punctuation: fewer commas, and no trailing period on a short single-sentence message."
        case .veryCasual:
            "Very casual. Write in all lowercase except proper nouns and the pronoun I, with lighter punctuation: fewer commas, and no trailing period on a short single-sentence message."
        case .excited:
            "Excited. Use standard capitalization with lighter punctuation, and exclamation points where the tone is upbeat."
        }
    }
}

/// The kinds of app a style is chosen for. `allCases` order is the Settings order.
enum StyleCategory: String, CaseIterable, Codable, Identifiable {
    case personal
    case work
    case email
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .personal: "Personal messages"
        case .work: "Work"
        case .email: "Email"
        case .other: "Other"
        }
    }

    /// Wispr offers "very casual" for personal messages only.
    var allowedStyles: [DictationStyle] {
        switch self {
        case .personal: [.formal, .casual, .veryCasual, .excited]
        case .work, .email, .other: [.formal, .casual, .excited]
        }
    }

    var defaultStyle: DictationStyle {
        switch self {
        case .email: .formal
        case .personal, .work, .other: .casual
        }
    }

    var storageKey: String { "dictation_style_\(rawValue)" }

    static var defaultStyles: [StyleCategory: DictationStyle] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultStyle) })
    }

    /// The stored choice when it is allowed for this category, otherwise the default.
    func style(in styles: [StyleCategory: DictationStyle]) -> DictationStyle {
        guard let style = styles[self], allowedStyles.contains(style) else {
            return defaultStyle
        }
        return style
    }

    /// An AI chat has no style of its own: it is pasted raw (feature 03) or styled as `.other`.
    static func styleCategory(for category: DictationAppCategory) -> StyleCategory? {
        switch category {
        case .email: .email
        case .workMessaging: .work
        case .personalMessaging: .personal
        case .coding, .other: .other
        case .aiChat: nil
        }
    }

    /// Resolution from the same category as the AI-app decision, keyed on that decision
    /// rather than the setting: a transcript pasted raw has no style, and an AI chat that
    /// is cleaned anyway (the AI-apps setting is off, or a Run Log retry, which always
    /// cleans) takes `.other`.
    static func resolvedStyle(
        for category: DictationAppCategory,
        styles: [StyleCategory: DictationStyle],
        rawTranscriptForAIApp: Bool
    ) -> DictationStyle? {
        guard !rawTranscriptForAIApp else { return nil }
        return (styleCategory(for: category) ?? .other).style(in: styles)
    }

    /// One key per category. A missing, non-string, unknown or disallowed value loads as the
    /// category default; never persists.
    static func loadStyles(from defaults: UserDefaults) -> [StyleCategory: DictationStyle] {
        var styles: [StyleCategory: DictationStyle] = [:]
        for category in allCases {
            let stored = (defaults.object(forKey: category.storageKey) as? String)
                .flatMap(DictationStyle.init(rawValue:))
            styles[category] = category.style(in: stored.map { [category: $0] } ?? [:])
        }
        return styles
    }

    /// Writes every category's sanitized choice, so a disallowed value is never persisted.
    static func saveStyles(_ styles: [StyleCategory: DictationStyle], to defaults: UserDefaults) {
        for category in allCases {
            defaults.set(category.style(in: styles).rawValue, forKey: category.storageKey)
        }
    }
}
