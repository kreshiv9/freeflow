import Foundation
import NaturalLanguage

/// Finds names and terms in screen text for Deepgram keyterms, with rules and no model:
/// file-name stems, code shapes, letter+digit model names, capitalized runs that are not at a
/// sentence start, backticked spans, @mentions, the VS Code folder name and rare words of a
/// typed search query. Secrets, emails, URLs, domains, numbers, everyday words, env-key
/// names, Title Case headings and UI labels never pass. NLTagger can only confirm a
/// candidate the rules already found. Pure apart from the injected tagger; never logs. Only
/// the returned terms leave this type; the source text is never kept.
enum NameExtractor {
    /// Rollback switch for the NLTagger signal; the rules run either way.
    static let usesNameTagger = true
    static let maxTerms = 30
    /// Terms whose only source is a search query, at most.
    static let maxSearchTerms = 5
    static let minLength = 3
    static let maxLength = 60

    enum SourceKind: Equatable, Sendable {
        case nearby
        case conversation
        case field
        case title
        case searchQuery
        case projectName

        var weight: Double {
            switch self {
            case .nearby: 1
            case .conversation: 2
            case .field, .title, .searchQuery, .projectName: 3
            }
        }
    }

    struct Source: Equatable, Sendable {
        let text: String
        let kind: SourceKind
    }

    /// Returns the spans a tagger labels as a person, place or organization name.
    typealias NameTagger = (String) -> [String]

    // MARK: - Patterns

    /// URLs, emails, lowercase bare domains and the redaction placeholder become spaces. Each
    /// mask starts only where its run of characters starts and has bounded pieces, so a long
    /// token (an SVG path, a letter run) costs linear time, not quadratic.
    private static let maskPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9+.\-])[A-Za-z][A-Za-z0-9+.\-]{0,31}://\S+"#),
        try! NSRegularExpression(pattern: #"\bwww\.\S+"#),
        try! NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9.\-]{1,253}\.[A-Za-z]{2,}"#
        ),
        try! NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9@.\-])(?:[a-z0-9\-]{1,63}\.){1,8}(?:com|org|net|io|dev|ai|app|co|gov|edu|me|so|sh|xyz|us|uk|ca|de)\b(?:/\S*)?"#
        ),
        try! NSRegularExpression(pattern: #"\[secret\]"#),
    ]
    private static let backtickPattern = try! NSRegularExpression(pattern: #"`([^`\n]{2,60})`"#)
    private static let mentionPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.])@([A-Za-z][A-Za-z0-9_.\-/]{2,80})"#
    )
    private static let wordPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9][A-Za-z0-9_+#\-./']*[A-Za-z0-9+#]|[A-Za-z]"#
    )
    private static let letterDigitNamePattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z]{2,}[A-Za-z]*(?:[\-.]?[0-9]+(?:\.[0-9]+)*[A-Za-z]*)(?:-[A-Za-z0-9]+)*$"#
    )

    // MARK: - Extraction

    /// Up to `maxTerms` terms, best first: score (source weight, +1 for code, file,
    /// letter+digit and multi-word shapes, +0.5 per extra occurrence, +0.5 when tagged), then
    /// first-seen order, so the output is deterministic. Every source is redacted first.
    /// Duplicates are removed case-insensitively keeping the first spelling, and a single
    /// word seen only inside a selected multi-word term is dropped.
    static func terms(from sources: [Source], everyday: Set<String>, tagger: NameTagger?) -> [String] {
        var accumulator = Accumulator()
        var taggedNames = Set<String>()

        for source in sources {
            var text = SecretFilter.redact(source.text)
            for pattern in maskPatterns {
                text = pattern.stringByReplacingMatches(
                    in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " "
                )
            }
            let weight = source.kind.weight

            // 8. The VS Code folder name, accepted whole.
            if source.kind == .projectName {
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if (3...50).contains(name.count), !everyday.contains(name.lowercased()),
                   name.split(separator: " ").count <= 3 {
                    accumulator.add(name, score: weight + 1)
                }
                continue
            }

            if usesNameTagger, let tagger, source.kind != .searchQuery {
                for name in tagger(text) { taggedNames.insert(name.lowercased()) }
            }

            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            // 6. Backticked spans: code-shaped or non-everyday words inside. A word from a
            //    span of several words is marked, so it can give way to the whole phrase.
            for match in backtickPattern.matches(in: text, range: fullRange) {
                let pieces = nsText.substring(with: match.range(at: 1)).split(separator: " ")
                for piece in pieces {
                    let word = String(piece)
                    if !IdentifierExtractor.identifiers(in: [word]).isEmpty
                        || (!everyday.contains(word.lowercased()) && word.allSatisfy(\.isLetter)) {
                        accumulator.add(stem(word), score: weight + 1, insideSpan: pieces.count > 1)
                    }
                }
            }
            // 7. @mentions: the handle, or a mentioned file's stem.
            for match in mentionPattern.matches(in: text, range: fullRange) {
                let handle = nsText.substring(with: match.range(at: 1))
                let last = handle.split(separator: "/").last.map(String.init) ?? handle
                let name = stem(last)
                if !everyday.contains(name.lowercased()) { accumulator.add(name, score: weight + 1) }
            }

            for line in text.components(separatedBy: .newlines) {
                extractWords(from: line, kind: source.kind, everyday: everyday, into: &accumulator)
            }
        }
        return accumulator.rankedTerms(taggedNames: taggedNames)
    }

    private struct Candidate {
        var display: String
        var score: Double
        var firstSeen: Int
        var count: Int
        /// Every occurrence was one word of a backticked span of several words.
        var onlyInsideSpan = false
    }

    /// An all-everyday capitalized run seen mid-sentence; it needs repetition or the tagger.
    private struct WeakRun {
        var display: String
        var count: Int
        var firstSeen: Int
        var weight: Double
    }

    private struct Accumulator {
        var candidates: [String: Candidate] = [:]
        var rejected = Set<String>()
        var searchTermKeys = Set<String>()
        var weakRuns: [String: WeakRun] = [:]
        var order = 0

        /// Trims edge punctuation, then counts a repeat or records a new candidate. Paths
        /// (which can carry a home folder's account name) and SCREAMING_SNAKE env-key names
        /// never pass, from any rule; a secret-like term is rejected for good.
        mutating func add(_ raw: String, score: Double, insideSpan: Bool = false) {
            let term = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"'()[]{}"))
            guard (minLength...maxLength).contains(term.count), term.contains(where: \.isLetter),
                  !term.contains(where: { $0 == "/" || $0 == "\\" }), !isScreamingSnake(term) else { return }
            let key = term.lowercased()
            guard !rejected.contains(key) else { return }
            if var existing = candidates[key] {
                existing.count += 1
                existing.score += 0.5
                existing.onlyInsideSpan = existing.onlyInsideSpan && insideSpan
                candidates[key] = existing
                return
            }
            if SecretFilter.isSecretLike(term) {
                rejected.insert(key)
                return
            }
            candidates[key] = Candidate(
                display: term, score: score, firstSeen: order, count: 1, onlyInsideSpan: insideSpan
            )
            order += 1
        }

        /// False once `maxSearchTerms` other search-only words were kept.
        mutating func admitsSearchTerm(_ word: String) -> Bool {
            let key = word.lowercased()
            guard searchTermKeys.contains(key) || searchTermKeys.count < maxSearchTerms else { return false }
            searchTermKeys.insert(key)
            return true
        }

        mutating func addWeakRun(_ phrase: String, weight: Double) {
            let key = phrase.lowercased()
            var run = weakRuns[key] ?? WeakRun(display: phrase, count: 0, firstSeen: order, weight: weight)
            run.count += 1
            weakRuns[key] = run
            order += 1
        }

        func rankedTerms(taggedNames: Set<String>) -> [String] {
            var ranked = candidates
            for (key, run) in weakRuns {
                let tagged = taggedNames.contains(key)
                guard run.count >= 2 || tagged, ranked[key] == nil else { continue }
                ranked[key] = Candidate(
                    display: run.display,
                    score: run.weight * 0.5 + (tagged ? 0.5 : 0) + Double(run.count - 1) * 0.5,
                    firstSeen: run.firstSeen,
                    count: run.count
                )
            }
            for key in ranked.keys where taggedNames.contains(key) {
                ranked[key]?.score += 0.5
            }

            let sorted = ranked.values
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.firstSeen < $1.firstSeen }
            // A single word seen only inside a selected multi-word term adds nothing; one also
            // seen on its own stays.
            let multiWordParts = sorted.prefix(maxTerms)
                .filter { $0.display.contains(" ") }
                .map { Set($0.display.lowercased().split(separator: " ").map(String.init)) }
            return sorted
                .filter { candidate in
                    guard candidate.onlyInsideSpan, !candidate.display.contains(" ") else { return true }
                    let key = candidate.display.lowercased()
                    return !multiWordParts.contains { $0.contains(key) }
                }
                .prefix(maxTerms)
                .map(\.display)
        }
    }

    private struct Word {
        let text: String
        let start: Int
        let end: Int
    }

    /// Rules 1-5 over one line's words, tracking sentence starts: the line start, after
    /// ".!?:", and the first word after a "1." style list number.
    private static func extractWords(
        from line: String,
        kind: SourceKind,
        everyday: Set<String>,
        into accumulator: inout Accumulator
    ) {
        let weight = kind.weight
        let nsLine = line as NSString
        let words = wordPattern.matches(in: line, range: NSRange(location: 0, length: nsLine.length)).map { match in
            Word(
                text: nsLine.substring(with: match.range),
                start: match.range.location,
                end: match.range.location + match.range.length
            )
        }
        func gap(before index: Int) -> String {
            let previousEnd = words[index - 1].end
            return nsLine.substring(with: NSRange(location: previousEnd, length: words[index].start - previousEnd))
        }
        let alphabeticWords = words.filter { $0.text.first?.isLetter == true }
        let capitalizedCount = alphabeticWords.filter { $0.text.first?.isUppercase == true }.count
        // Headings and UI label rows: 3+ words, at least 80% capitalized.
        let isTitleCaseLine = alphabeticWords.count >= 3
            && Double(capitalizedCount) / Double(alphabeticWords.count) >= 0.8

        var index = 0
        while index < words.count {
            let word = words[index]
            let text = word.text
            let isSentenceStart: Bool = {
                guard index > 0 else { return true }
                let previous = words[index - 1]
                let mark = (previous.text.last.map(String.init) ?? "")
                    + gap(before: index).trimmingCharacters(in: .whitespaces)
                if mark.contains(where: { ".!?:".contains($0) }) { return true }
                return index == 1 && previous.text.allSatisfy(\.isNumber)
            }()

            // 1. File names give their stem: useAuth.ts -> useAuth. A path gives only its
            //    file's stem, never its folders: Sources/AppState.swift -> AppState.
            if text.contains("."), let fileName = IdentifierExtractor.fileNames(fromLabels: [text]).first {
                let name = stem(fileName)
                if name.count >= 3, !everyday.contains(name.lowercased()) {
                    accumulator.add(name, score: weight + 1)
                }
                index += 1
                continue
            }
            // 2. Code shapes (camelCase, snake_case, macOS); the last part of a dotted path.
            //    Capitalized words (MacBook, DeepgramStreamingCore) go to rule 4 so "MacBook
            //    Air" stays one term. SCREAMING_SNAKE env-key names are never terms.
            if !isCapitalized(text) {
                let identifiers = IdentifierExtractor.identifiers(in: [text])
                if !identifiers.isEmpty {
                    for identifier in identifiers where !identifier.contains(".") && !isScreamingSnake(identifier) {
                        accumulator.add(identifier, score: weight + 1)
                    }
                    index += 1
                    continue
                }
                if isScreamingSnake(text) {
                    index += 1
                    continue
                }
            }
            // 3. Letter+digit model and product names: GPT-5, Nova-3, Qwen3, gpt-4o-mini.
            if isLetterDigitName(text) {
                accumulator.add(text, score: weight + 1)
                index += 1
                continue
            }
            // 4. Runs of one to four capitalized words, with acronyms inside a run. A
            //    sentence-initial everyday word is dropped from the run; a run with a rare word
            //    passes; an all-everyday run needs repetition or the tagger.
            if isCapitalized(text) {
                var run = [word]
                var next = index + 1
                while next < words.count, run.count < 4,
                      isCapitalized(words[next].text) || isAcronym(words[next].text),
                      gap(before: next) == " " {
                    run.append(words[next])
                    next += 1
                }
                var parts = run.map(\.text)
                if isSentenceStart, let first = parts.first, everyday.contains(first.lowercased()) {
                    parts.removeFirst()
                }
                if !parts.isEmpty {
                    let phrase = parts.joined(separator: " ")
                    let hasRareWord = parts.contains { !everyday.contains($0.lowercased()) && !isAcronym($0) }
                    if hasRareWord {
                        if !(isTitleCaseLine && parts.count == 1 && parts[0].count < 4) {
                            accumulator.add(phrase, score: weight + (parts.count > 1 ? 1 : 0.5))
                        }
                    } else if !isTitleCaseLine, !(isSentenceStart && parts.count == run.count) {
                        accumulator.addWeakRun(phrase, weight: weight)
                    }
                }
                index = next
                continue
            }
            // 5. Rare lowercase words, only from a typed search query.
            if kind == .searchQuery, text.count >= 4, text.allSatisfy(\.isLetter),
               !everyday.contains(text.lowercased()), accumulator.admitsSearchTerm(text) {
                accumulator.add(text, score: weight)
            }
            index += 1
        }
    }

    // MARK: - Own name

    /// The Mac account's first name and full name, for the connect-time keyterms. Each must
    /// be 3-60 characters with a letter, not an everyday word and not secret-like; duplicates
    /// are removed case-insensitively. Empty for a missing or blank name.
    static func ownNameTerms(fullName: String?, everyday: Set<String>) -> [String] {
        let words = (fullName ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        guard let firstWord = words.first else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for term in [firstWord, words.joined(separator: " ")] {
            guard (minLength...maxLength).contains(term.count),
                  term.contains(where: \.isLetter),
                  !everyday.contains(term.lowercased()),
                  !SecretFilter.isSecretLike(term),
                  seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
        }
        return result
    }

    // MARK: - NLTagger

    /// Person, place and organization names NLTagger finds in `text`.
    static func nameTagger(_ text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names: [String] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        let nameTags: Set<NLTag> = [.personalName, .placeName, .organizationName]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options
        ) { tag, range in
            if let tag, nameTags.contains(tag) { names.append(String(text[range])) }
            return true
        }
        return names
    }

    /// Builds the everyday word set, compiles the extraction and secret patterns and loads the
    /// tagger model on a utility queue, so the first dictation pays for none of them. Runs
    /// once per launch however often it is called.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async { _ = warmUp }
    }

    /// One extraction over a fixed, invented sentence.
    private static let warmUp: Void = {
        _ = terms(
            from: [Source(text: "Synthetic warm-up with Avery Quill in Lisbon.", kind: .conversation)],
            everyday: EverydayWords.all,
            tagger: usesNameTagger ? nameTagger : nil
        )
    }()

    // MARK: - Word shapes

    private static func stem(_ name: String) -> String {
        guard let dot = name.firstIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// An uppercase first letter, a lowercase letter later, and only letters, apostrophes and
    /// hyphens: Cursor, MacBook, O'Neil.
    private static func isCapitalized(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        return word.dropFirst().contains(where: \.isLowercase)
            && word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
    }

    /// At least two leading letters, at most four digits, fewer than three letter/digit
    /// switches, and a capital start or a "-" or ".": GPT-5 and Llama-3.1-8B, not hunter2xyz.
    /// A word too long to be a term is never matched, which also keeps the pattern linear.
    private static func isLetterDigitName(_ word: String) -> Bool {
        guard word.count <= maxLength, let first = word.first, word.contains(where: \.isNumber),
              letterDigitNamePattern.firstMatch(
                  in: word, range: NSRange(location: 0, length: (word as NSString).length)
              ) != nil,
              word.filter(\.isNumber).count <= 4,
              first.isUppercase || word.contains("-") || word.contains(".") else { return false }
        return letterDigitSwitches(in: word) < 3
    }

    private static func letterDigitSwitches(in word: String) -> Int {
        let characters = Array(word)
        var switches = 0
        for index in characters.indices.dropFirst()
        where (characters[index - 1].isLetter && characters[index].isNumber)
            || (characters[index - 1].isNumber && characters[index].isLetter) {
            switches += 1
        }
        return switches
    }

    private static func isScreamingSnake(_ word: String) -> Bool {
        word.contains("_") && !word.contains(where: \.isLowercase)
    }

    private static func isAcronym(_ word: String) -> Bool {
        (2...5).contains(word.count) && word.allSatisfy { $0.isUppercase && $0.isLetter }
    }
}
