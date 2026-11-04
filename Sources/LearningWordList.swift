import Foundation

/// The learner's word lists: EverydayWords for the everyday tier, the bundled
/// LearningKnownWords.txt for known words, and the system's common first names. Read once,
/// lazily, off the main thread (the Run Log Fix task is the only caller).
struct LearningWordList: LearningLexicon, Sendable {
    static let resourceName = "LearningKnownWords"
    static let firstNamesPath = "/usr/share/dict/propernames"
    /// The resource holds about 82,000 words. A shorter list means a broken or missing file,
    /// and learning then fails closed: with an empty known tier every heard word would look
    /// like a non-word and become a rule at once.
    static let minimumKnownWords = 10_000

    private let known: Set<String>
    private let firstNames: Set<String>

    /// Nil when the known words are fewer than `minimumKnownWords`. Missing first names
    /// leave that filter empty.
    init?(knownWordsText: String, firstNamesText: String?) {
        let known = Self.parse(knownWordsText)
        guard known.count >= Self.minimumKnownWords else { return nil }
        self.known = known
        self.firstNames = firstNamesText.map(Self.parse) ?? []
    }

    /// One lowercased word per line; blank lines and lines starting with "#" are skipped.
    static func parse(_ text: String) -> Set<String> {
        var words = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let word = line.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, !word.hasPrefix("#") else { continue }
            words.insert(word.lowercased())
        }
        return words
    }

    /// The known words at `knownWordsURL` with the first names at `firstNamesPath`; nil when
    /// the known words cannot be read or are too few. An unreadable first-names file leaves
    /// that filter empty.
    static func load(knownWordsURL: URL?, firstNamesPath: String) -> LearningWordList? {
        guard let knownWordsURL, let text = try? String(contentsOf: knownWordsURL, encoding: .utf8) else { return nil }
        return LearningWordList(
            knownWordsText: text,
            firstNamesText: try? String(contentsOfFile: firstNamesPath, encoding: .utf8)
        )
    }

    /// The app bundle's list, loaded on first use (about 60 ms) and kept for the session.
    static let bundled: LearningWordList? = load(
        knownWordsURL: Bundle.main.url(forResource: resourceName, withExtension: "txt"),
        firstNamesPath: firstNamesPath
    )

    func isEveryday(_ lowercased: String) -> Bool {
        EverydayWords.contains(lowercased)
    }

    func isKnown(_ lowercased: String) -> Bool {
        known.contains(lowercased) || EverydayWords.contains(lowercased)
    }

    func isFirstName(_ lowercased: String) -> Bool {
        firstNames.contains(lowercased)
    }
}
