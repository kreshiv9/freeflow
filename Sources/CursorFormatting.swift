import Foundation

/// Wispr-style local fit of a finished dictation into the text around the cursor: the first
/// character's case, one space on either side, and the trailing sentence mark. Pure text rules;
/// nothing inside the transcript is ever changed and no text is logged.
enum CursorFormatting {
    static let storageKey = "cursor_formatting_enabled"
    static let defaultEnabled = true
    /// Appended to the Run Log processing status when the fit changed anything; pinned by tests.
    static let statusSuffix = ", fitted to cursor"

    struct Adjustment: Equatable {
        var text: String
        var changedCasing = false
        var addedLeadingSpace = false
        var addedTrailingSpace = false
        var droppedTrailingPunctuation = false
        /// True when the fit inspected text after the cursor on the same line and so decided
        /// the trailing edge itself; the paste path then adds no space after a sentence mark.
        var handledTrailingEdge = false

        var changedAnything: Bool {
            changedCasing || addedLeadingSpace || addedTrailingSpace || droppedTrailingPunctuation
        }
    }

    /// Returns the default-on choice for missing/invalid values without persisting a default.
    static func load(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: storageKey) as? Bool) ?? defaultEnabled
    }

    /// The stop-time decision: fit only plain dictation. Edit Mode rewrites a selection and a
    /// voice macro pastes literal user-defined text, so neither is fitted.
    static func applies(enabled: Bool, isCommandMode: Bool, isVoiceMacro: Bool) -> Bool {
        enabled && !isCommandMode && !isVoiceMacro
    }

    /// The Run Log processing status: the outcome, then the snippet, file-tag and cursor-fit
    /// suffixes, then the press-enter note last so the row keeps its "status; command" shape.
    /// Composed here, outside AppState, so the order is pinned by tests.
    static func processingStatus(
        outcome: String,
        expandedSnippetCount: Int,
        taggedFileCount: Int = 0,
        fittedToCursor: Bool,
        pressEnterDetected: Bool
    ) -> String {
        let status = outcome
            + SnippetExpansion.statusSuffix(expandedCount: expandedSnippetCount)
            + FileTagMatcher.statusSuffix(taggedCount: taggedFileCount)
            + (fittedToCursor ? statusSuffix : "")
        guard pressEnterDetected else { return status }
        return "\(status); detected press enter command"
    }

    /// Custom Vocabulary text (correction targets already merged in) split the way cleanup
    /// splits it: on newlines, commas and semicolons, trimmed, empties dropped.
    static func keepCapitalizedTerms(from vocabularyText: String) -> Set<String> {
        Set(
            vocabularyText
                .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    /// Fits to the snapshot read at recording start. An empty side is stored as nil, so the
    /// field counts as read when `fieldTextRead` is set or any text field is non-nil, and a nil
    /// side is then an empty edge; an unread field returns the transcript unchanged. The paste
    /// replaces a selection, so the edges are the text before and after the selection.
    static func adjust(
        _ transcript: String,
        in context: TextContextSnapshot,
        keepCapitalized: Set<String> = [],
        keepLowercase: Set<String> = []
    ) -> Adjustment {
        guard context.fieldTextRead || context.textBeforeCursor != nil || context.selectedText != nil
                || context.textAfterCursor != nil else {
            return Adjustment(text: transcript)
        }
        return adjust(
            transcript,
            before: context.textBeforeCursor ?? "",
            after: context.textAfterCursor ?? "",
            keepCapitalized: keepCapitalized,
            keepLowercase: keepLowercase
        )
    }

    /// Core rules. A nil side leaves that edge untouched; both nil, or an empty transcript,
    /// returns the transcript unchanged with every flag false. `keepLowercase` holds exact
    /// words (code identifiers such as "user_name") that keep a lowercase sentence start but,
    /// unlike vocabulary, never keep a capital mid-sentence.
    static func adjust(
        _ transcript: String,
        before: String?,
        after: String?,
        keepCapitalized: Set<String> = [],
        keepLowercase: Set<String> = []
    ) -> Adjustment {
        guard !transcript.isEmpty, before != nil || after != nil else { return Adjustment(text: transcript) }
        var result = Adjustment(text: transcript)
        var text = transcript
        var leading = ""
        var trailing = ""

        if let before, let first = text.first {
            // Spaces and tabs before the cursor do not end a sentence; a newline does.
            var b = Substring(before)
            while let last = b.last, last.isWhitespace, !last.isNewline { b.removeLast() }
            let beforeEndsWithWhitespace = before.last?.isWhitespace == true

            if let last = b.last, !last.isNewline, !sentenceEnders.contains(last), !isOpener(endOf: b) {
                // Mid-sentence: a letter, digit, comma, colon, closing quote, emoji or symbol.
                if first.isUppercase, !isProtected(firstWordOf: text, keepCapitalized: keepCapitalized) {
                    text = first.lowercased() + String(text.dropFirst())
                    result.changedCasing = true
                }
                if !beforeEndsWithWhitespace, !(isCJK(last) && isCJK(first)) {
                    leading = " "
                    result.addedLeadingSpace = true
                }
            } else {
                // Sentence start: an empty field, a newline, sentence punctuation or an opener.
                if first.isLowercase,
                   !keepsLowercaseStart(firstWordOf: text, keepCapitalized: keepCapitalized, keepLowercase: keepLowercase) {
                    text = first.uppercased() + String(text.dropFirst())
                    result.changedCasing = true
                }
                if let last = b.last, sentenceEnders.contains(last), !beforeEndsWithWhitespace,
                   !(isCJK(last) && isCJK(first)) {
                    leading = " "
                    result.addedLeadingSpace = true
                }
            }
        }

        // A list or other multi-line payload keeps its own ending.
        if let after, !text.contains(where: \.isNewline) {
            var a = Substring(after)
            while let next = a.first, next.isWhitespace, !next.isNewline { a.removeFirst() }
            if let next = a.first, !next.isNewline, let last = text.last {
                result.handledTrailingEdge = true
                let afterStartsWithWhitespace = after.first?.isWhitespace == true
                if isCloser(startOf: a) {
                    // Punctuation follows: never a space, and a duplicated mark goes.
                    dropOneTrailingSentenceMark(from: &text, into: &result)
                } else if !(isCJK(next) && isCJK(last)) {
                    if next.isLowercase || next.isNumber {
                        // The sentence continues after the cursor.
                        dropOneTrailingSentenceMark(from: &text, into: &result)
                    }
                    if !afterStartsWithWhitespace {
                        trailing = " "
                        result.addedTrailingSpace = true
                    }
                }
            }
        }

        result.text = leading + text + trailing
        return result
    }

    // MARK: - Rules

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？"]
    private static let openers: Set<Character> = [
        "(", "[", "{", "\"", "'", "“", "‘", "（", "「", "『", "【"
    ]
    private static let closers: Set<Character> = [
        ".", ",", "!", "?", ";", ":", ")", "]", "}", "”", "’",
        "。", "，", "、", "！", "？", "；", "：", "）", "」", "』", "】"
    ]
    /// Straight quotes open or close depending on their neighbor; apps without smart quotes
    /// (Slack, browsers, editors, terminals) use them for both.
    private static let straightQuotes: Set<Character> = ["\"", "'"]
    private static let pronounForms: Set<String> = ["I", "I'm", "I'll", "I've", "I'd"]

    /// A bracket or quote that opens what follows. A straight quote opens only at the start of
    /// the text or after whitespace or another opener; `He said "hi"` and `the kids'` continue.
    private static func isOpener(endOf b: Substring) -> Bool {
        guard let last = b.last else { return false }
        if straightQuotes.contains(last) {
            guard let previous = b.dropLast().last else { return true }
            return previous.isWhitespace || openers.contains(previous)
        }
        return openers.contains(last)
    }

    /// Punctuation that closes what came before. A straight quote closes only when nothing,
    /// whitespace or punctuation follows it; `"quoted" text` opens and keeps the sentence mark.
    private static func isCloser(startOf a: Substring) -> Bool {
        guard let next = a.first else { return false }
        if straightQuotes.contains(next) {
            guard let following = a.dropFirst().first else { return true }
            return following.isWhitespace || following.isPunctuation
        }
        return closers.contains(next)
    }

    /// The transcript's first word without trailing punctuation, plus its stem when it is a
    /// possessive ("Avery's" → "Avery"), so a vocabulary name matches in either form.
    private static func firstWordForms(of text: String) -> [String] {
        var word = text.prefix { !$0.isWhitespace }
        while let last = word.last, !last.isLetter, !last.isNumber { word.removeLast() }
        var forms = [String(word)]
        for suffix in ["'s", "’s"] where word.hasSuffix(suffix) {
            forms.append(String(word.dropLast(2)))
        }
        return forms
    }

    private static func vocabularyFirstWords(_ keepCapitalized: Set<String>) -> [String] {
        keepCapitalized.compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
    }

    /// A capitalized first word that keeps its case mid-sentence: the pronoun I and its
    /// contractions, acronyms and CamelCase names (a second capital), and the first word of
    /// a vocabulary term, compared case-insensitively.
    private static func isProtected(firstWordOf text: String, keepCapitalized: Set<String>) -> Bool {
        let forms = firstWordForms(of: text)
        guard let word = forms.first, !word.isEmpty else { return false }
        if pronounForms.contains(word.replacingOccurrences(of: "’", with: "'")) { return true }
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        let lowered = forms.map { $0.lowercased() }
        return vocabularyFirstWords(keepCapitalized).contains { lowered.contains($0.lowercased()) }
    }

    /// A lowercase-led first word that keeps its case at a sentence start: a CamelCase name
    /// ("iPhone", "macOS"), or a vocabulary term or `keepLowercase` word spelled that way,
    /// compared exactly so a term entered capitalized still capitalizes the dictation.
    private static func keepsLowercaseStart(
        firstWordOf text: String,
        keepCapitalized: Set<String>,
        keepLowercase: Set<String>
    ) -> Bool {
        let forms = firstWordForms(of: text)
        guard let word = forms.first, !word.isEmpty else { return false }
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        if forms.contains(where: keepLowercase.contains) { return true }
        return vocabularyFirstWords(keepCapitalized).contains { forms.contains($0) }
    }

    /// Removes one sentence-ending mark from the end of `text`, never from a run like "..."
    /// or "?!" and never the whole text.
    private static func dropOneTrailingSentenceMark(from text: inout String, into result: inout Adjustment) {
        guard let last = text.last, sentenceEnders.contains(last),
              let previous = text.dropLast().last, !sentenceEnders.contains(previous) else { return }
        var stripped = text.dropLast()
        while let tail = stripped.last, tail.isWhitespace { stripped.removeLast() }
        guard !stripped.isEmpty else { return }
        text = String(stripped)
        result.droppedTrailingPunctuation = true
    }

    /// Chinese and Japanese scripts and their fullwidth punctuation, which join without
    /// spaces. Hangul is left out because Korean uses spaces.
    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
