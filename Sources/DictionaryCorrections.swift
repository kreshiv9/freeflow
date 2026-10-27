import Foundation

/// A "Correct a misspelling" dictionary rule: a word or phrase the transcription
/// provider keeps hearing (`from`) and the spelling the user wants instead (`to`).
struct DictionaryCorrection: Codable, Equatable, Identifiable {
    static let storageKey = "dictionary_corrections"
    static let maxFieldLength = 60

    var id: UUID = UUID()
    var from: String
    var to: String

    /// Trimmed, cut to `maxFieldLength`, trimmed again; every stored and applied rule has this form.
    static func normalizedField(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxFieldLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalized: DictionaryCorrection {
        DictionaryCorrection(id: id, from: Self.normalizedField(from), to: Self.normalizedField(to))
    }

    /// Both fields have content after normalizing; only these rules apply.
    var isUsable: Bool {
        !Self.normalizedField(from).isEmpty && !Self.normalizedField(to).isEmpty
    }

    /// Neither field has content: an untouched editor row, never persisted.
    var isBlank: Bool {
        Self.normalizedField(from).isEmpty && Self.normalizedField(to).isEmpty
    }

    /// JSON data like `voice_macros`. A missing key, another type or undecodable data
    /// loads as [] without persisting anything; decoded rows are re-normalized so a
    /// hand-edited plist cannot exceed the limit.
    static func load(from defaults: UserDefaults) -> [DictionaryCorrection] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([DictionaryCorrection].self, from: data) else {
            return []
        }
        return decoded.map(\.normalized)
    }

    static func save(_ corrections: [DictionaryCorrection], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(corrections) {
            defaults.set(data, forKey: storageKey)
        }
    }

    /// The raw Custom Vocabulary text with each usable rule's `to` appended on its own
    /// line, so cleanup keeps the corrected spellings; unchanged when no rule is usable.
    static func vocabularyText(_ rawVocabulary: String, merging corrections: [DictionaryCorrection]) -> String {
        let spellings = corrections.map(\.normalized).filter(\.isUsable).map(\.to)
        guard !spellings.isEmpty else { return rawVocabulary }
        return ([rawVocabulary] + spellings).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Replaces every whole-word, case-insensitive occurrence of a usable rule's `from`
    /// with its `to` in one pass over the original text, so rules never chain and the
    /// longest `from` wins at a position. A hit that lies inside a whole-word copy of the
    /// same rule's `to` is left alone, so a rule never duplicates its own output: the
    /// second pass on cleaned output cannot turn "Claude Code" into "Claude Claude Code".
    /// The pass is idempotent unless `to` is itself a whole-word sub-phrase of `from`;
    /// a stutter rule like "the the" -> "the" collapses one more repeat on each pass.
    static func apply(_ corrections: [DictionaryCorrection], to text: String) -> String {
        let rules = corrections.map(\.normalized).filter(\.isUsable)
        guard !rules.isEmpty, !text.isEmpty else { return text }

        let source = WordBoundedText(text)
        var ownRanges: [Int: [Range<Int>]] = [:]
        let accepted = source.matches(ofPhrases: rules.map(\.from)).filter { hit in
            if ownRanges[hit.phraseIndex] == nil {
                ownRanges[hit.phraseIndex] = source.matches(ofPhrases: [rules[hit.phraseIndex].to]).map(\.range)
            }
            return !(ownRanges[hit.phraseIndex] ?? []).contains { own in
                own != hit.range
                    && own.lowerBound <= hit.range.lowerBound
                    && hit.range.upperBound <= own.upperBound
            }
        }
        return source.replacing(accepted.map { (range: $0.range, text: rules[$0.phraseIndex].to) })
    }
}
