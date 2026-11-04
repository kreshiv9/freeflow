import Foundation

/// The sound-alike test of the learning loop: a small in-repo English consonant key plus
/// letter distance. Written for FreeFlow (not a vendored algorithm). Pure and deterministic.
///
/// Two spellings sound alike when their consonant keys are equal, or one edit apart when the
/// longer key has at least `nearKeyMinimumLength` letters, or when their letter distance is at
/// most `maxLetterDistance`. On the synthetic lab pairs this accepts 22 of 22 mishearings
/// (cloud/Claude, whisper/Wispr, deep gram/Deepgram, versel/Vercel, get hub/GitHub, kwen/Qwen,
/// post gress/Postgres, super base/Supabase, …) and 0 of 19 ordinary swaps (bug/issue,
/// React/Vue, cache/Kafka, …).
enum LearningPhonetics {
    /// Spoken separators that disappear when an identifier is written ("use auth dot ts").
    static let spokenJoiners: Set<String> = ["dot", "underscore", "dash", "hyphen", "slash", "hashtag", "hash", "at"]
    /// Keys this long or longer may differ by one edit and still match.
    static let nearKeyMinimumLength = 5
    static let maxLetterDistance = 0.34

    /// Lowercased letters and digits of all words. Spoken joiners are dropped only when the
    /// text has more than one word, so "dot" alone keeps its letters.
    static func letterKey(_ text: String) -> [Character] {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace })
        let kept = words.count > 1 ? words.filter { !spokenJoiners.contains(String($0)) } : words
        return Array(kept.joined().filter { $0.isLetter || $0.isNumber })
    }

    static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Edit distance between the letter keys over the longer key: 0 is the same letters, 1 when
    /// either side has none.
    static func letterDistance(_ a: String, _ b: String) -> Double {
        let x = letterKey(a), y = letterKey(b)
        guard !x.isEmpty, !y.isEmpty else { return 1 }
        return Double(levenshtein(x, y)) / Double(max(x.count, y.count))
    }

    /// Digraphs rewritten in this order before the letters are mapped one by one. "X" stands
    /// for the sh sound and "0" for th; both survive the letter pass as "x" and "0".
    private static let digraphs: [(String, String)] = [
        ("x", "ks"), ("tch", "X"), ("sch", "sk"), ("ph", "f"), ("ck", "k"), ("sh", "X"), ("ch", "X"),
        ("th", "0"), ("wh", "w"), ("qu", "k"), ("dg", "j"), ("gh", ""), ("ew", "u"),
    ]

    /// A consonant skeleton of the letters (digits ignored), joiners dropped as in `letterKey`:
    /// - a silent first letter of kn, gn, wr and ps goes;
    /// - the digraph table above, in order;
    /// - c is s before e, i or y and k otherwise; q, g and k are k; s and z are s; f and v are
    ///   f; b and p are p; d and t are t;
    /// - vowels (and y) are dropped, except a leading one, which is kept as "a";
    /// - h and w are kept only as the first letter before a vowel;
    /// - repeats collapse ("tt" is "t").
    /// cloud and Claude are "klt", deep gram and Deepgram "tpkrm", kwen and Qwen "kn".
    static func consonantKey(_ text: String) -> String {
        var letters = String(letterKey(text).filter(\.isLetter))
        guard !letters.isEmpty else { return "" }
        if letters.hasPrefix("kn") || letters.hasPrefix("gn") || letters.hasPrefix("wr") || letters.hasPrefix("ps") {
            letters.removeFirst()
        }
        for (from, to) in digraphs {
            letters = letters.replacingOccurrences(of: from, with: to)
        }
        let characters = Array(letters)
        var key: [Character] = []
        for (index, character) in characters.enumerated() {
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            let nextIsVowel = next.map { "aeiou".contains($0) } ?? false
            let mapped: Character?
            switch character {
            case "a", "e", "i", "o", "u", "y": mapped = index == 0 ? "a" : nil
            case "c": mapped = (next.map { "eiy".contains($0) } ?? false) ? "s" : "k"
            case "q", "g", "k": mapped = "k"
            case "z", "s": mapped = "s"
            case "v", "f": mapped = "f"
            case "b", "p": mapped = "p"
            case "d", "t": mapped = "t"
            case "X": mapped = "x"
            case "h", "w": mapped = index == 0 && nextIsVowel ? character : nil
            default: mapped = character
            }
            if let mapped, key.last != mapped { key.append(mapped) }
        }
        return String(key)
    }

    /// Equal consonant keys, or keys one edit apart when the longer has at least
    /// `nearKeyMinimumLength` letters. An empty key never matches.
    static func keysSoundAlike(_ a: String, _ b: String) -> Bool {
        let x = Array(consonantKey(a)), y = Array(consonantKey(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        return max(x.count, y.count) >= nearKeyMinimumLength && levenshtein(x, y) <= 1
    }

    /// `keysSoundAlike`, or a letter distance of at most `maxLetterDistance`.
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        keysSoundAlike(a, b) || letterDistance(a, b) <= maxLetterDistance
    }
}
