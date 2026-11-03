import Foundation

/// Wispr-style File Tagging for Cursor and Windsurf: "tag", "tagged", "at" or "@" followed by
/// a spoken file name becomes an @-mention of the exact collected file name. Capitalization,
/// separators, run-together words, quotes, backticks and surrounding markup do not prevent a
/// match, and a leading spoken "dot" names a dotfile. A trigger with no matching file stays
/// untouched, so "meet at noon" never changes. The plan reuses the snippet placeholders, so
/// cleanup keeps the tags and they resolve locally afterwards. Pure text rules, no logging.
enum FileTagMatcher {
    static let storageKey = "vibe_coding_file_tagging_enabled"
    static let defaultEnabled = true
    static let maxNameWords = 8

    private static let triggerWords: Set<String> = ["tag", "tagged", "at", "@"]
    private static let taggingBundleIdentifiers: Set<String> = [
        IdentifierExtractor.cursorBundleIdentifier, IdentifierExtractor.windsurfBundleIdentifier
    ]
    private static let markup: Set<Character> = [
        "`", "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "*", "<", ">"
    ]
    private static let openingBrackets: Set<Character> = ["(", "[", "{"]
    private static let closingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]
    private static let spokenSeparators: [String: String] = ["dot": ".", "underscore": "_", "dash": "-"]

    /// Returns the default-on choice for missing/invalid values without persisting a default.
    static func load(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: storageKey) as? Bool) ?? defaultEnabled
    }

    static func supportsTagging(bundleIdentifier: String?) -> Bool {
        guard let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return taggingBundleIdentifiers.contains(bundle)
    }

    /// One whitespace-separated word, in Character offsets. From the left: opening brackets,
    /// then markup, then the core. From the right: outer punctuation, then markup, then inner
    /// punctuation, then the core ("\"swift.\"," has inner ".", markup "\"" and outer ",").
    private struct Word {
        let start: Int
        let end: Int
        let bracketEnd: Int
        let coreStart: Int
        let coreEnd: Int
        let innerPunctuationEnd: Int
        let markupEnd: Int
        var core: [Character]
        let trailing: [Character]

        var hasLeadingMarkup: Bool { coreStart > bracketEnd }
        var hasLeadingBrackets: Bool { bracketEnd > start }
        var hasTrailingMarkup: Bool { markupEnd > innerPunctuationEnd }
        var hasInnerPunctuation: Bool { innerPunctuationEnd > coreEnd }
    }

    private struct Hit {
        let range: Range<Int>
        /// An opening quote on the name that is not consumed, put back before the tag.
        let prefix: String
        /// Punctuation from inside consumed closing quotes, put back after the tag.
        let suffix: String
        let name: String
    }

    /// Placeholder text, expanded text and "@<name>" expansions like a snippet plan; every tag
    /// span is replaced in order and matches never overlap. The longest name (up to
    /// `maxNameWords` words) wins; ties go to the first collected file name.
    static func plan(for text: String, fileNames: [String]) -> SnippetExpansionPlan {
        var strict: [String: String] = [:]
        var loose: [String: String] = [:]
        for name in fileNames where !name.isEmpty && !name.contains(where: \.isWhitespace) {
            let key = strictKey(name)
            guard !key.isEmpty else { continue }
            if strict[key] == nil { strict[key] = name }
            if loose[looseKey(key)] == nil { loose[looseKey(key)] = name }
        }
        guard !strict.isEmpty else {
            return SnippetExpansionPlan(placeholderText: text, expandedText: text, expansions: [])
        }

        let source = WordBoundedText(text)
        let characters = source.characters
        let all = words(in: characters)
        var hits: [Hit] = []
        var index = 0
        while index < all.count {
            let trigger = all[index]
            let isAttached: Bool
            let available: [Word]
            if isTrigger(trigger, characters: characters) {
                isAttached = false
                available = Array(all[(index + 1)...].prefix(maxNameWords))
            } else if trigger.core.count > 1, trigger.core.first == "@" {
                // "@AppState.swift" or "@app state dot swift": the rest of the word is name word 1.
                var remainder = trigger
                remainder.core.removeFirst()
                isAttached = true
                available = [remainder] + Array(all[(index + 1)...].prefix(maxNameWords - 1))
            } else {
                index += 1
                continue
            }

            var matched: (count: Int, name: String)?
            for count in stride(from: available.count, through: 1, by: -1) {
                guard let key = key(for: Array(available.prefix(count)), firstIsRemainder: isAttached),
                      let name = strict[key] ?? loose[looseKey(key)] else { continue }
                matched = (count, name)
                break
            }
            guard let matched else {
                index += 1
                continue
            }

            let first = available[0]
            let last = available[matched.count - 1]
            // Quotes and backticks are consumed only when they wrap the name on both sides, so
            // a quote that opens on the name and closes later stays; brackets and outer
            // punctuation always stay.
            let consumesMarkup = (trigger.hasLeadingMarkup || first.hasLeadingMarkup) && last.hasTrailingMarkup
            let start = consumesMarkup ? trigger.bracketEnd : trigger.coreStart
            let end = consumesMarkup ? last.markupEnd : last.coreEnd
            let prefix = consumesMarkup || isAttached ? "" : String(characters[first.bracketEnd..<first.coreStart])
            let suffix = consumesMarkup ? String(characters[last.coreEnd..<last.innerPunctuationEnd]) : ""
            hits.append(Hit(range: start..<end, prefix: prefix, suffix: suffix, name: matched.name))
            index += isAttached ? matched.count : matched.count + 1
        }

        return SnippetExpansionPlan(
            placeholderText: source.replacing(hits.enumerated().map { offset, hit in
                (range: hit.range, text: hit.prefix + SnippetExpansion.placeholder(offset + 1) + hit.suffix)
            }),
            expandedText: source.replacing(hits.map { (range: $0.range, text: $0.prefix + "@" + $0.name + $0.suffix) }),
            expansions: hits.map { "@" + $0.name }
        )
    }

    /// The tag plan for one dictation, or nil when it does not apply: the setting is off, the
    /// app is not Cursor or Windsurf, no file names were collected, a dictionary correction
    /// changed the text or a snippet expanded (Wispr's limitation), or nothing matched.
    /// Unlike Wispr, which tags only in the AI chat panel, the gate is the app alone: the code
    /// editor and the integrated terminal are not told apart from chat yet, because their
    /// Accessibility labels are unverified. Dictating there into a match also tags.
    static func dictationPlan(
        correctedTranscript: String,
        rawTranscript: String,
        snippetPlan: SnippetExpansionPlan,
        enabled: Bool,
        bundleIdentifier: String?,
        fileNames: [String]
    ) -> SnippetExpansionPlan? {
        guard enabled,
              supportsTagging(bundleIdentifier: bundleIdentifier),
              !fileNames.isEmpty,
              correctedTranscript == rawTranscript,
              !snippetPlan.hasMatches else { return nil }
        let plan = plan(for: correctedTranscript, fileNames: fileNames)
        return plan.hasMatches ? plan : nil
    }

    /// Run Log suffix appended to the existing processing status.
    static func statusSuffix(taggedCount: Int) -> String {
        switch taggedCount {
        case 0:
            return ""
        case 1:
            return ", 1 file tagged"
        default:
            return ", \(taggedCount) files tagged"
        }
    }

    // MARK: - Matching

    private static func words(in characters: [Character]) -> [Word] {
        var result: [Word] = []
        var index = 0
        while index < characters.count {
            guard !characters[index].isWhitespace else {
                index += 1
                continue
            }
            let start = index
            while index < characters.count, !characters[index].isWhitespace { index += 1 }
            let end = index

            var bracketEnd = start
            while bracketEnd < end, openingBrackets.contains(characters[bracketEnd]) { bracketEnd += 1 }
            var coreStart = bracketEnd
            while coreStart < end, markup.contains(characters[coreStart]) { coreStart += 1 }
            var markupEnd = end
            while markupEnd > coreStart, closingPunctuation.contains(characters[markupEnd - 1]) { markupEnd -= 1 }
            var innerPunctuationEnd = markupEnd
            while innerPunctuationEnd > coreStart, markup.contains(characters[innerPunctuationEnd - 1]) {
                innerPunctuationEnd -= 1
            }
            var coreEnd = innerPunctuationEnd
            while coreEnd > coreStart, closingPunctuation.contains(characters[coreEnd - 1]) { coreEnd -= 1 }

            result.append(Word(
                start: start,
                end: end,
                bracketEnd: bracketEnd,
                coreStart: coreStart,
                coreEnd: coreEnd,
                innerPunctuationEnd: innerPunctuationEnd,
                markupEnd: markupEnd,
                core: Array(characters[coreStart..<coreEnd]),
                trailing: Array(characters[coreEnd..<end])
            ))
        }
        return result
    }

    /// A trigger word, case-insensitive, with no markup or punctuation after it except one
    /// "," or ":" (speech-to-text often adds a comma after a pause).
    private static func isTrigger(_ word: Word, characters: [Character]) -> Bool {
        guard triggerWords.contains(String(word.core).lowercased()),
              !word.hasTrailingMarkup,
              !word.hasInnerPunctuation else { return false }
        switch word.end - word.markupEnd {
        case 0:
            return true
        case 1:
            return characters[word.end - 1] == "," || characters[word.end - 1] == ":"
        default:
            return false
        }
    }

    /// The lookup key for a run of name words, or nil when the run cannot be one name: a word
    /// before the last ends in anything but one ".", a "." is followed by a word that does not
    /// start lowercase (speech-to-text capitalizes a new sentence, so "look at main. Go on"
    /// never joins), a later word opens with markup, a word opens with a bracket (except the
    /// attached "@" remainder), or a word has no core.
    private static func key(for words: [Word], firstIsRemainder: Bool) -> String? {
        var key = ""
        for (offset, word) in words.enumerated() {
            let isFirst = offset == 0
            let isLast = offset == words.count - 1
            guard !word.core.isEmpty else { return nil }
            if !isLast, !(word.trailing.isEmpty || word.trailing == ["."]) { return nil }
            if !isLast, !word.trailing.isEmpty, words[offset + 1].core.first?.isLowercase != true { return nil }
            if !isFirst, word.hasLeadingMarkup { return nil }
            if !(isFirst && firstIsRemainder), word.hasLeadingBrackets { return nil }
            let piece = String(word.core).lowercased()
            key += spokenSeparators[piece] ?? piece
            if !isLast, !word.trailing.isEmpty { key += "." }
        }
        return key.isEmpty ? nil : key
    }

    /// Lowercased, with markup removed: "app_state.swift" and "AppState.swift" stay distinct.
    private static func strictKey(_ name: String) -> String {
        String(name.lowercased().filter { !markup.contains($0) })
    }

    /// Without "_" and "-", so "app state dot swift" also finds "app_state.swift" or "app-state.swift".
    private static func looseKey(_ key: String) -> String {
        key.filter { $0 != "_" && $0 != "-" }
    }
}
