import Foundation

/// Mid-sentence voice macros ("snippets"): a trigger spoken inside a sentence is
/// swapped for its expansion. Cleanup sees a placeholder token in the trigger's place
/// so the model never rewrites the expansion; it is spliced back afterwards. The
/// whole-transcript macro match in AppState runs first and is unchanged.
enum SnippetExpansion {
    struct Snippet: Equatable {
        var trigger: String
        var expansion: String
    }

    static let maxExpansionLength = 4000

    /// Added to the cleanup system prompt only when a plan has matches.
    static let cleanupInstruction = "Keep every ⟦…⟧ token exactly as written, in place; never remove, reorder or reword them."

    /// 1-based: "⟦S1⟧". U+27E6/U+27E7 never appear in speech-to-text output, and
    /// `WordBoundedText` treats them as word characters so no correction rule can
    /// match the index inside a token.
    static func placeholder(_ index: Int) -> String {
        "\u{27E6}S\(index)\u{27E7}"
    }

    fileprivate static let placeholderPattern = try! NSRegularExpression(pattern: "\u{27E6}[Ss]([0-9]+)\u{27E7}")

    /// Triggers match whole words, case-insensitively, longest first and left to right.
    /// A trigger needs a letter or digit (a punctuation-only command would fire at every
    /// sentence end) and an expansion over `maxExpansionLength` is skipped, never cut.
    static func plan(for text: String, snippets: [Snippet]) -> SnippetExpansionPlan {
        let eligible = snippets.compactMap { snippet -> Snippet? in
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trigger.contains(where: { $0.isLetter || $0.isNumber }),
                  snippet.expansion.count <= maxExpansionLength else { return nil }
            return Snippet(trigger: trigger, expansion: snippet.expansion)
        }
        let source = WordBoundedText(text)
        let hits = source.matches(ofPhrases: eligible.map(\.trigger))
        return SnippetExpansionPlan(
            placeholderText: source.replacing(hits.enumerated().map { (range: $1.range, text: placeholder($0 + 1)) }),
            expandedText: source.replacing(hits.map { (range: $0.range, text: eligible[$0.phraseIndex].expansion) }),
            expansions: hits.map { eligible[$0.phraseIndex].expansion }
        )
    }

    /// Run Log suffix appended to the existing processing status.
    static func statusSuffix(expandedCount: Int) -> String {
        switch expandedCount {
        case 0:
            return ""
        case 1:
            return ", 1 snippet expanded"
        default:
            return ", \(expandedCount) snippets expanded"
        }
    }
}

struct SnippetExpansionPlan: Equatable {
    /// The input with each matched trigger replaced by its placeholder, in order.
    let placeholderText: String
    /// The input with each trigger replaced by its expansion directly: the raw-path
    /// result and the cleanup fallback.
    let expandedText: String
    /// `expansions[i]` belongs to placeholder i + 1.
    let expansions: [String]

    var hasMatches: Bool { !expansions.isEmpty }

    /// Splices the expansions back into cleaned text in a single pass. Returns nil when
    /// any expected placeholder is missing or duplicated, or an unknown index appears.
    func resolve(_ cleanedText: String) -> String? {
        guard hasMatches else { return cleanedText }

        let fullRange = NSRange(cleanedText.startIndex..<cleanedText.endIndex, in: cleanedText)
        var seen = Set<Int>()
        var splices: [(range: Range<String.Index>, text: String)] = []
        for match in SnippetExpansion.placeholderPattern.matches(in: cleanedText, range: fullRange) {
            guard let tokenRange = Range(match.range, in: cleanedText),
                  let indexRange = Range(match.range(at: 1), in: cleanedText),
                  let index = Int(cleanedText[indexRange]),
                  (1...expansions.count).contains(index),
                  seen.insert(index).inserted else { return nil }
            splices.append((range: tokenRange, text: expansions[index - 1]))
        }
        guard seen.count == expansions.count else { return nil }

        var output = ""
        var cursor = cleanedText.startIndex
        for splice in splices {
            output += cleanedText[cursor..<splice.range.lowerBound]
            output += splice.text
            cursor = splice.range.upperBound
        }
        output += cleanedText[cursor...]
        return output
    }
}
