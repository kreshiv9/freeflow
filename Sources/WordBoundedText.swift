import Foundation

/// A text prepared for the whole-word lookups shared by dictionary corrections and
/// snippet triggers. Matching is case-insensitive and diacritic-sensitive, done
/// Character by Character so offsets stay aligned with the original text, and a hit
/// may not touch a letter, digit or underscore on either side: "sig." and "(sig)"
/// match, "signature" and "sig_2" do not. The snippet placeholder brackets count as
/// word characters too, so a rule applied to cleaned output never rewrites "⟦S1⟧".
struct WordBoundedText {
    struct Match: Equatable {
        /// Character offsets into `characters`.
        let range: Range<Int>
        /// Index into the `phrases` argument of `matches(ofPhrases:)`.
        let phraseIndex: Int
    }

    let characters: [Character]
    private let folded: [String]

    init(_ text: String) {
        characters = Array(text)
        folded = Self.fold(characters)
    }

    /// Lowercases each Character on its own so the result stays aligned with the input.
    static func fold(_ characters: [Character]) -> [String] {
        characters.map { String($0).lowercased() }
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
            || character == "\u{27E6}" || character == "\u{27E7}"
    }

    func isWordBounded(_ range: Range<Int>) -> Bool {
        let startsAtBoundary = range.lowerBound == 0 || !Self.isWordCharacter(characters[range.lowerBound - 1])
        let endsAtBoundary = range.upperBound == characters.count || !Self.isWordCharacter(characters[range.upperBound])
        return startsAtBoundary && endsAtBoundary
    }

    /// One left-to-right scan. At each offset whose previous character is not a word
    /// character, the longest phrase that matches there (ties: lowest index) and is not
    /// followed by a word character wins, and the scan resumes after it, so matches never
    /// overlap. Empty phrases never match.
    func matches(ofPhrases phrases: [String]) -> [Match] {
        let foldedPhrases = phrases.map { Self.fold(Array($0)) }
        let candidates = foldedPhrases.indices
            .filter { !foldedPhrases[$0].isEmpty }
            .sorted { lhs, rhs in
                if foldedPhrases[lhs].count != foldedPhrases[rhs].count {
                    return foldedPhrases[lhs].count > foldedPhrases[rhs].count
                }
                return lhs < rhs
            }
        guard !candidates.isEmpty else { return [] }

        var result: [Match] = []
        var offset = 0
        while offset < characters.count {
            let startsAtBoundary = offset == 0 || !Self.isWordCharacter(characters[offset - 1])
            guard startsAtBoundary,
                  let hit = candidates.first(where: { phraseMatches(foldedPhrases[$0], at: offset) }) else {
                offset += 1
                continue
            }
            let range = offset..<(offset + foldedPhrases[hit].count)
            result.append(Match(range: range, phraseIndex: hit))
            offset = range.upperBound
        }
        return result
    }

    private func phraseMatches(_ phrase: [String], at offset: Int) -> Bool {
        let end = offset + phrase.count
        guard end <= characters.count, isWordBounded(offset..<end) else { return false }
        return folded[offset..<end].elementsEqual(phrase)
    }

    /// The text with each range swapped for its text; ranges must be ascending and non-overlapping.
    func replacing(_ replacements: [(range: Range<Int>, text: String)]) -> String {
        var output = ""
        var cursor = 0
        for replacement in replacements {
            output += String(characters[cursor..<replacement.range.lowerBound])
            output += replacement.text
            cursor = replacement.range.upperBound
        }
        output += String(characters[cursor...])
        return output
    }
}
