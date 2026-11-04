import Foundation

/// The two ways a dictation skips waiting for the cleanup model: the fast path, which never
/// calls it for a short transcript that is already clean or a short clean query in the
/// google.com search box, and the deadline fallback, which pastes the transcript with local formatting
/// when the model is late. Pure text rules, no logging. The text rules are deliberately
/// over-inclusive: a miss only means the model runs.
enum CleanupFastPath {
    enum Reason: Equatable, Sendable {
        case alreadyClean
        case searchBox
    }

    static let maximumWords = 12

    /// Processing statuses stored on the Run Log row; pinned by tests.
    static let alreadyCleanProcessingStatus = "Fast path: already clean, skipped cleanup"
    static let searchBoxProcessingStatus = "Fast path: search box, skipped cleanup"
    static let timedOutProcessingStatus = "Cleanup timed out, using raw transcript"
    static let timedOutRetryProcessingStatus = "Cleanup timed out on retry, using raw transcript"

    static func processingStatus(for reason: Reason) -> String {
        switch reason {
        case .alreadyClean: alreadyCleanProcessingStatus
        case .searchBox: searchBoxProcessingStatus
        }
    }

    /// Why this dictation can skip the model, or nil when cleanup must run. None and an
    /// Output Language always go their own way, and both rules are English only (the filler
    /// and marker lists are English). Both rules need text with no filler, self-correction,
    /// repeated word or phrase, or spoken list or punctuation command, and a dictation with
    /// a snippet or file-tag trigger or a custom system prompt always goes to the model. The
    /// already-clean rule also needs grammatical rather than pause punctuation. The
    /// search box relaxes the shape (a lowercase start, no end mark, up to
    /// `searchBoxMaximumWords`) at any level and style; anything else falls through to the
    /// other rule. The already-clean rule is Light only (Medium asked for rewording), leaves
    /// Very casual and Excited to the model, which rewrite casing and punctuation, and never
    /// skips email formatting.
    static func reason(
        transcript: String,
        websiteDomain: String?,
        category: DictationAppCategory?,
        cleanupLevel: CleanupLevel,
        style: DictationStyle?,
        outputLanguage: String,
        dictationLanguage: String,
        hasSnippetMatches: Bool,
        hasCustomSystemPrompt: Bool
    ) -> Reason? {
        // A custom prompt carries the user's own instructions, so it always runs.
        guard !cleanupLevel.skipsCleanup,
              outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !hasSnippetMatches,
              !hasCustomSystemPrompt,
              appliesEnglishRules(transcript, dictationLanguage: dictationLanguage) else { return nil }
        if isSearchBox(websiteDomain: websiteDomain), isSearchQuery(transcript) {
            return .searchBox
        }
        guard cleanupLevel == .light,
              category != .email,
              style == nil || style == .formal || style == .casual,
              isAlreadyClean(transcript) else { return nil }
        return .alreadyClean
    }

    /// The Google page's own search box. Text context sets the domain only for focus inside
    /// the page, never the address bar, and other Google products never match.
    static func isSearchBox(websiteDomain: String?) -> Bool {
        guard var domain = websiteDomain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        if domain.hasPrefix("www.") {
            domain.removeFirst(4)
        }
        return domain == "google.com"
    }

    static let searchBoxMaximumWords = 20

    /// The domain is all text context knows, so any field on google.com (a Maps review, a
    /// Flights form) matches it. Only one short line with a letter or digit counts as a query,
    /// and wording cleanup would change ("um", "no wait", "in, in", "first ... second") still goes to
    /// the model, which pastes nothing for filler alone ("Um."). Snippet triggers are checked
    /// by `reason`, which knows the snippet plan.
    static func isSearchQuery(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline),
              (1...searchBoxMaximumWords).contains(trimmed.split(whereSeparator: \.isWhitespace).count),
              trimmed.contains(where: { $0.isLetter || $0.isNumber }) else {
            return false
        }
        return !hasWordingCleanupChanges(trimmed)
    }

    /// The local text rules are English. An explicit English dictation qualifies; under
    /// Auto-detect, text whose letters are all ASCII stands in for language detection, which
    /// keeps accented and non-Latin dictations with the model.
    static func appliesEnglishRules(_ text: String, dictationLanguage: String) -> Bool {
        let language = dictationLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if language == "English" { return true }
        guard language.isEmpty else { return false }
        return text.allSatisfy { !$0.isLetter || $0.isASCII }
    }

    /// A saved prompt that is not the default carries the user's own instructions.
    static func isCustomSystemPrompt(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed != PostProcessingService.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hesitations and the discourse fillers the prompt removes, over-inclusive: any "like", "so"
    /// or "okay so" opening a sentence, and a "right?" tag. "just" is left out because in a short
    /// dictation it nearly always carries meaning ("Just ship it."); "actually" and "I mean" come
    /// from the backtrack marker list. The search-box rule shares this list, so these fillers are
    /// never pasted there either.
    private static let fillerPattern =
        #"(?i)\b(?:u+m+|u+h+m*|e+r+m*|a+h+|e+h+|h+m+|m+h*m+|you know|so yeah|basically|literally|like)\b|(?i)(?:^|[.!?…]\s+)so\b|(?i)\b(?:okay|ok),?\s+so\b|(?i)\bright\s*\?"#
    /// "no" anywhere but the start ("Monday. No, Tuesday.", "tokyo no osaka"), with the common
    /// non-English negations an unaccented Auto-detect dictation can still carry, plus
    /// "I meant" and "oops", which the sanitizer's shared list lacks.
    private static let extraBacktrackPattern =
        #"(?i)(?:[,.;:!?]|\S\s)\s*(?:no|nu|non|nein|não)\b|\bno,?\s+no\b|\bi meant\b|\b(?:wh)?oops\b"#
    private static let spokenCommandPattern =
        #"(?i)\b(?:first|second|third|firstly|secondly|thirdly|1st|2nd|3rd|number (?:one|two|1|2)|bullet|numbered|new line|next line|line break|new paragraph|skip a line|comma|period|full stop|question mark|exclamation (?:point|mark)|colon|semicolon|em dash|dash dash|underscore|dot|slash|open (?:paren|quote|bracket)|close (?:paren|quote|bracket)|quote|unquote|camel case|snake case|all caps)\b"#
    private static let trailingClosers: Set<Character> = ["\"", "\u{201D}", "\u{2019}", "'", ")", "]"]
    private static let sentenceEndMarks: Set<Character> = [".", "?", "!", "\u{2026}"]
    /// Punctuation placed at a pause rather than by grammar: a sentence after an inner sentence
    /// mark that opens with a connective ("I fixed it. Into the settings.") or has one or two
    /// words ("I fixed it. Last night."), a comma or period right after a function word ("Open
    /// the, settings."), or a comma right before one ("Check, the logs."). Used by the
    /// already-clean rule only; the search box ignores it.
    private static let pauseSplitPattern =
        #"(?i)[.!?…]["'”’)\]]*\s+(?:and|but|or|so|because|which|that|than|then|into|onto|to|for|with|without|from|in|on|at|of|by|about|like|until|unless|instead)\b|[.!?…]["'”’)\]]*\s+[\w'’-]+(?:\s+[\w'’-]+)?[.!?…]|\b(?:a|an|the|to|of|and|or|but|for|with|from|into|my|your|our|their|its)[,.;:](?:\s|$)|,\s+(?:the|a|an|to|of|into|for|with|from|in|on|at|my|your|our|their|this|these|those)\b"#

    /// One line of at most `maximumWords` words with a letter or digit that starts capitalized,
    /// ends with a sentence mark, and has no lowercase "i", lowercase sentence start after an
    /// inner sentence mark, doubled space, wording cleanup would change, or pause punctuation (a
    /// split-off fragment, a comma beside a function word). Punctuation alone
    /// ("...") goes to cleanup, which returns EMPTY for it. An abbreviation ("5 p.m. today")
    /// reads as a lowercase sentence start and goes to the model.
    static func isAlreadyClean(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline),
              trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        guard (1...maximumWords).contains(wordCount) else { return false }
        if let firstLetter = trimmed.first(where: \.isLetter), firstLetter.isLowercase {
            return false
        }
        guard let lastMark = trimmed.reversed().first(where: { !trailingClosers.contains($0) }),
              sentenceEndMarks.contains(lastMark),
              trimmed.range(of: #"\bi\b"#, options: .regularExpression) == nil,
              trimmed.range(of: #"[.!?…]["'”’)\]]*\s+[a-z]"#, options: .regularExpression) == nil,
              trimmed.range(of: #"\S\s{2,}\S"#, options: .regularExpression) == nil,
              trimmed.range(of: pauseSplitPattern, options: .regularExpression) == nil else { return false }
        return !hasWordingCleanupChanges(trimmed)
    }

    /// A repeated word or phrase, filler, self-correction, or spoken list, format or
    /// punctuation command.
    private static func hasWordingCleanupChanges(_ text: String) -> Bool {
        // ICU backreferences stay case-sensitive under (?i), so "The the" is checked lowercased.
        // A repeat of one to three words, across a space, comma or dash, is a stutter or a
        // false start ("Can you, can you", "I- I", "the — the"); "Okay, okay." also matches.
        let repeatedPhrase = #"\b(\w+(?:\s+\w+){0,2})[\s,;:.\-–—]+\1\b"#
        if text.lowercased().range(of: repeatedPhrase, options: .regularExpression) != nil {
            return true
        }
        return [
            fillerPattern,
            TranscriptOutputSanitizer.backtrackMarkerPattern,
            extraBacktrackPattern,
            spokenCommandPattern
        ].contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Casual asks for no trailing period on a short single-sentence message; the fast path
    /// applies that locally, for English only, as the prompt's Style rule does. Abbreviations
    /// ("p.m.", "U.S.") and ellipses keep their dots.
    static func pastedText(_ text: String, style: DictationStyle?, dictationLanguage: String) -> String {
        guard style == .casual, appliesEnglishRules(text, dictationLanguage: dictationLanguage) else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix(".."),
              trimmed.split(whereSeparator: \.isWhitespace).count <= maximumWords else { return text }
        let withoutPeriod = String(trimmed.dropLast())
        guard withoutPeriod.range(of: #"[.!?]\s"#, options: .regularExpression) == nil,
              let lastWord = withoutPeriod.split(whereSeparator: \.isWhitespace).last,
              !lastWord.contains(".") else { return text }
        return withoutPeriod
    }

    /// What the stop path pastes for a fast-path dictation. The style rule runs on the
    /// placeholder text, so a snippet payload's own punctuation is never touched.
    static func pastedText(for plan: SnippetExpansionPlan, style: DictationStyle?, dictationLanguage: String) -> String {
        plan.resolve(pastedText(plan.placeholderText, style: style, dictationLanguage: dictationLanguage))
            ?? plan.expandedText
    }

    /// The deadline fallback pastes the snippet-expanded transcript with the local list
    /// formatting cleanup would have added.
    static func timedOutText(for plan: SnippetExpansionPlan) -> String {
        timedOutText(plan.expandedText)
    }

    static func timedOutText(_ text: String) -> String {
        SpokenListFormatter.numberedList(from: text) ?? text
    }
}
