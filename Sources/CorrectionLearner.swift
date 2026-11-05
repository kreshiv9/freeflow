import Foundation

/// The word lists the learner consults. Every argument is already lowercased.
protocol LearningLexicon {
    /// Everyday English (EverydayWords: SCOWL size 20 and below plus the tech supplement).
    func isEveryday(_ lowercased: String) -> Bool
    /// Any known English word, everyday words included (SCOWL size 50 and below).
    func isKnown(_ lowercased: String) -> Bool
    /// A common first name.
    func isFirstName(_ lowercased: String) -> Bool
}

/// Decides what a user's fix of pasted text teaches: misheard words and names become learned
/// terms, and a few become correction rules. Pure and deterministic: no logging, no I/O, no
/// clock, and the same result on every macOS version.
///
/// The steps, from the learning-loop decision memo (section 2):
/// 1. Tokenize both sides and align the case-folded word cores with an in-repo LCS (a fixed
///    tie-break, so the stdlib's changing `difference(from:)` never decides).
/// 2. Peel stutters (a deleted or inserted word equal to its neighbour) as other changes.
/// 3. Group the changes into hunks. Case-only neighbours join a hunk ("cloud code" ->
///    "Claude Code"), never across sentence punctuation or at a sentence start, and a hunk is
///    split where both sides have sentence punctuation.
/// 4. Resolve each hunk: several strong single-word fixes side by side, else the whole hunk,
///    else a small partition search with edge trims (both sides at most `maxSideWords`).
/// 5. Judge each candidate: filters (address, secret, number, tombstoned, known, inflection,
///    affix, everyday on both sides, first-name swap, …), the sound-alike test, the term shape,
///    Deepgram confidence, and whether a rule is allowed now or later.
/// 6. Gate the whole edit: rewrite budget, other changes, kept share; keep at most
///    `maxCandidates`, strong first.
enum CorrectionLearner {
    enum Strength: String, Codable, Sendable {
        case strong
        case weak
    }

    struct Candidate: Equatable, Sendable {
        var heard: String
        var term: String
        var strength: Strength
        /// A rule may be created at once (the heard side is a lowercase non-word).
        var ruleNow: Bool
        /// A rule may be created after repeated evidence.
        var ruleLater: Bool
        /// The user changed a vocabulary term back to an ordinary word: revert evidence only.
        var isRevert: Bool = false
    }

    /// Why nothing was learned. Codes only, safe for counters and logs.
    enum Reason: String, Sendable {
        case empty, tooLong, notFound, rewrite, rewording, notThisDictation, unchanged, notWord,
             address, secret, number, tombstoned, alreadyKnownTerm, sentenceGlue, dottedShorthand,
             shortCase, styleOnly, inflection, affixEdit, everydayBothSides, commonNameSwap,
             protectedTerm, mergeIntoWord, `extension`, ordinaryWords, notSoundAlike,
             phraseUnsupported, confidentChange, hunkTooLong, contentEdit, styleOrUnchanged
    }

    enum Outcome: Equatable, Sendable {
        case learned([Candidate])
        case nothing(Reason)
    }

    /// Which of several equally long alignments the LCS picks. Outcomes are the same under
    /// both; tests run both to prove it.
    enum TieBreak: Sendable {
        case earliest
        case latest
    }

    // MARK: Thresholds (memo 2.11)

    static let maxSideWords = 4
    static let rewriteFloor = 4
    static let rewriteShare = 0.4
    static let minKeptShare = 0.5
    static let maxOtherChanged = 3
    static let maxCandidates = 4
    static let strongLetterDistance = LearningPhonetics.maxLetterDistance
    static let weakLetterDistance = 1.0 / 3.0
    static let lowConfidence = 0.65
    static let highConfidence = 0.95
    static let maxTermCharacters = 60
    static let partialRewriteWords = 3
    /// Longer inputs are not aligned (the LCS table is n × m).
    static let maxTokens = 1_000
    /// Without the edit gates nothing else stops a heavy rewrite, and each hunk can cost hundreds
    /// of judge calls, so this many hunks are resolved at most.
    static let maxUngatedHunks = 32

    // MARK: Tokens

    struct Token {
        let raw: String
        let core: String
        var fold: String { core.lowercased() }
    }

    private static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?\"'()[]{}<>…“”‘’`*#>~")
    private static let sentencePunctuation: Set<Character> = [".", "!", "?", ";", ":"]

    /// Whitespace-separated tokens; the core is the token without edge punctuation. Backticks,
    /// object-replacement characters and no-break spaces are ignored, and tokens with no core
    /// or made only of "-" and "_" are dropped.
    static func tokens(_ text: String) -> [Token] {
        text.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\u{FFFC}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map { raw in Token(raw: String(raw), core: String(raw).trimmingCharacters(in: edgePunctuation)) }
            .filter { !$0.core.isEmpty && !$0.core.allSatisfy { "-_".contains($0) } }
    }

    // MARK: Alignment

    enum Step {
        case equal(Int, Int)
        case removed(Int)
        case inserted(Int)
    }

    /// Plain O(n·m) LCS over a flat table with a documented tie-break, so every macOS version
    /// produces the same script. `.earliest` prefers removing from `a` first when both moves
    /// keep the longest match; `.latest` builds the script backwards with the mirror rule.
    static func script(_ a: [String], _ b: [String], tieBreak: TieBreak) -> [Step] {
        let n = a.count, m = b.count
        let width = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        var steps: [Step] = []
        switch tieBreak {
        case .earliest:
            // table[i][j] = LCS length of a[i...] and b[j...]
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        table[i * width + j] = a[i] == b[j]
                            ? table[(i + 1) * width + j + 1] + 1
                            : max(table[(i + 1) * width + j], table[i * width + j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n || j < m {
                if i < n, j < m, a[i] == b[j] {
                    steps.append(.equal(i, j)); i += 1; j += 1
                } else if j >= m || (i < n && table[(i + 1) * width + j] >= table[i * width + j + 1]) {
                    steps.append(.removed(i)); i += 1
                } else {
                    steps.append(.inserted(j)); j += 1
                }
            }
        case .latest:
            // table[i][j] = LCS length of a[..<i] and b[..<j]
            if n > 0 && m > 0 {
                for i in 1...n {
                    for j in 1...m {
                        table[i * width + j] = a[i - 1] == b[j - 1]
                            ? table[(i - 1) * width + j - 1] + 1
                            : max(table[(i - 1) * width + j], table[i * width + j - 1])
                    }
                }
            }
            var i = n, j = m
            var reversed: [Step] = []
            while i > 0 || j > 0 {
                if i > 0, j > 0, a[i - 1] == b[j - 1] {
                    reversed.append(.equal(i - 1, j - 1)); i -= 1; j -= 1
                } else if j == 0 || (i > 0 && table[(i - 1) * width + j] >= table[i * width + j - 1]) {
                    reversed.append(.removed(i - 1)); i -= 1
                } else {
                    reversed.append(.inserted(j - 1)); j -= 1
                }
            }
            steps = reversed.reversed()
        }
        return steps
    }

    struct Hunk {
        var old: [Int] = []
        var new: [Int] = []
        /// No exact match precedes the hunk (it touches the start of the text).
        var leading = false
        /// No exact match follows the hunk (it touches the end of the text).
        var trailing = false
    }

    private static func endsSentence(_ token: Token) -> Bool {
        token.raw.last.map { sentencePunctuation.contains($0) } ?? false
    }

    private static func endsClause(_ token: Token) -> Bool {
        token.raw.last.map { sentencePunctuation.contains($0) || $0 == "," } ?? false
    }

    /// Runs between exact matches. Case-only matches join a neighbouring run unless sentence
    /// punctuation separates them or they start a sentence; a hunk with sentence punctuation
    /// on both sides is split there.
    static func hunks(_ steps: [Step], _ old: [Token], _ new: [Token]) -> [Hunk] {
        var result: [Hunk] = []
        var current: Hunk?
        var seenExact = false
        var pendingCase: [(Int, Int)] = []
        func boundaryBefore(_ i: Int, _ j: Int) -> Bool {
            (i > 0 && endsSentence(old[i - 1])) || (j > 0 && endsClause(new[j - 1]))
        }
        func flushPendingAsOwnHunk(trailing: Bool) {
            guard !pendingCase.isEmpty else { return }
            var hunk = Hunk()
            hunk.leading = !seenExact
            hunk.trailing = trailing
            for (a, b) in pendingCase {
                hunk.old.append(a)
                hunk.new.append(b)
            }
            result.append(hunk)
            pendingCase = []
        }
        func close() {
            if var hunk = current {
                for (i, j) in pendingCase {
                    hunk.old.append(i)
                    hunk.new.append(j)
                }
                pendingCase = []
                result.append(hunk)
            }
            current = nil
        }
        func atSentenceStart(_ j: Int) -> Bool { j == 0 || endsSentence(new[j - 1]) }
        func open(at i: Int?, _ j: Int?) {
            if pendingCase.contains(where: { atSentenceStart($0.1) }) { flushPendingAsOwnHunk(trailing: false) }
            current = Hunk()
            current!.leading = !seenExact
            // Preceding case-only tokens attach only when no sentence boundary separates them.
            if let last = pendingCase.last {
                let nextOld = i ?? (last.0 + 1), nextNew = j ?? (last.1 + 1)
                if boundaryBefore(nextOld, nextNew) {
                    flushPendingAsOwnHunk(trailing: false)
                    current!.leading = !seenExact
                }
            }
            for (a, b) in pendingCase {
                current!.old.append(a)
                current!.new.append(b)
            }
            pendingCase = []
        }
        for step in steps {
            switch step {
            case .equal(let i, let j):
                if old[i].core != new[j].core {
                    // Case-only.
                    if current != nil {
                        if boundaryBefore(i, j) {
                            close()
                            pendingCase.append((i, j))
                        } else {
                            current!.old.append(i)
                            current!.new.append(j)
                        }
                    } else {
                        pendingCase.append((i, j))
                    }
                } else {
                    if current != nil { close() } else { flushPendingAsOwnHunk(trailing: false) }
                    seenExact = true
                }
            case .removed(let i):
                if current == nil { open(at: i, nil) }
                current!.old.append(i)
            case .inserted(let j):
                if current == nil { open(at: nil, j) }
                current!.new.append(j)
            }
        }
        if current != nil {
            current!.trailing = true
            close()
        } else {
            flushPendingAsOwnHunk(trailing: true)
        }
        let sorted = result.map { hunk -> Hunk in
            var hunk = hunk
            hunk.old.sort()
            hunk.new.sort()
            return hunk
        }
        var split: [Hunk] = []
        for hunk in sorted {
            if let oldEnd = hunk.old.dropLast().firstIndex(where: { endsSentence(old[$0]) }),
               let newEnd = hunk.new.dropLast().firstIndex(where: { endsClause(new[$0]) }) {
                var first = Hunk(), second = Hunk()
                first.old = Array(hunk.old[...oldEnd])
                first.new = Array(hunk.new[...newEnd])
                first.leading = hunk.leading
                second.old = Array(hunk.old[(oldEnd + 1)...])
                second.new = Array(hunk.new[(newEnd + 1)...])
                second.trailing = hunk.trailing
                split.append(first)
                split.append(second)
            } else {
                split.append(hunk)
            }
        }
        return split
    }

    // MARK: Filters

    private static let addressTopLevelDomains: Set<String> = [
        "com", "org", "net", "io", "ai", "dev", "app", "co", "so", "sh", "me", "gg", "xyz", "edu", "gov",
    ]

    /// A path, e-mail address, markup, URL or lowercase dotted host.
    static func isAddressOrMarkup(_ text: String) -> Bool {
        if text.contains(where: { "/\\<>@".contains($0) }) || text.hasPrefix("~") { return true }
        let lowered = text.lowercased()
        if lowered.contains("://") || lowered.hasPrefix("www.") { return true }
        let parts = lowered.split(separator: ".")
        if text == lowered, parts.count >= 2, let tld = parts.last, addressTopLevelDomains.contains(String(tld)) {
            return true
        }
        return false
    }

    static func isNumberLike(_ text: String) -> Bool {
        text.contains(where: \.isNumber) && !text.contains(where: \.isLetter)
    }

    /// Digits, inner punctuation, an acronym or camelCase: a model name, identifier or file.
    static func isCodeShaped(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        if word.contains(where: \.isNumber) { return true }
        if word.dropFirst().dropLast().contains(where: { "._-+#/".contains($0) }) { return true }
        if letters.count >= 2 && letters.allSatisfy(\.isUppercase) { return true }
        return letters.dropFirst().contains(where: \.isUppercase) && letters.contains(where: \.isLowercase)
    }

    private static let inflectionSuffixes = ["s", "es", "ed", "d", "ing", "er", "est", "'s", "ly"]
    private static let irregularForms: [Set<String>] = [
        ["run", "ran"], ["go", "went"], ["is", "was"], ["are", "were"], ["do", "did"],
        ["have", "had"], ["write", "wrote"], ["make", "made"], ["get", "got"],
    ]

    static func isInflection(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        if inflectionSuffixes.contains(where: { long == short + $0 }) { return true }
        if short.hasSuffix("e"), inflectionSuffixes.contains(where: { long == short.dropLast() + $0 }) { return true }
        return irregularForms.contains { $0.contains(x) && $0.contains(y) }
    }

    private static let spokenDigits: [String: String] = [
        "zero": "0", "oh": "o", "one": "1", "won": "1", "two": "2", "to": "2", "too": "2",
        "three": "3", "four": "4", "for": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "ate": "8", "nine": "9", "ten": "10", "point": "",
    ]

    /// The heard words as compared with the term: spoken digits ("for oh") are mapped only when
    /// the term has digits ("4o").
    private static func heardForDistance(_ heardWords: [String], term: String) -> String {
        term.contains(where: \.isNumber)
            ? heardWords.map { spokenDigits[$0.lowercased()] ?? $0 }.joined(separator: " ")
            : heardWords.joined(separator: " ")
    }

    /// A known word, or a hyphenated word whose parts are all known.
    private static func isKnown(_ word: String, _ lexicon: LearningLexicon) -> Bool {
        let lowered = word.lowercased()
        func known(_ part: String) -> Bool { lexicon.isKnown(part) || lexicon.isEveryday(part) }
        return known(lowered) || lowered.split(separator: "-").allSatisfy { known(String($0)) }
    }

    /// A known word that only gained a prefix or suffix is a content edit (socket -> websocket).
    private static func isAffixEdit(_ heard: String, _ term: String, lexicon: LearningLexicon) -> Bool {
        let h = heard.lowercased(), t = term.lowercased()
        guard isKnown(h, lexicon), h != t, t.count - h.count >= 2 else { return false }
        return t.hasPrefix(h) || t.hasSuffix(h)
    }

    /// Is one term token plausibly what the heard run was? Used to accept multi-word phrases.
    private static func supports(_ heardRun: [Token], _ termToken: Token, lexicon: LearningLexicon) -> Bool {
        let heardWords = heardRun.map(\.core)
        if heardWords.count == 1, isAffixEdit(heardWords[0], termToken.core, lexicon: lexicon) { return false }
        let heardText = heardForDistance(heardWords, term: termToken.core)
        if LearningPhonetics.letterKey(heardText) == LearningPhonetics.letterKey(termToken.core) { return true }
        return LearningPhonetics.keysSoundAlike(heardWords.joined(separator: " "), termToken.core)
            || LearningPhonetics.letterDistance(heardText, termToken.core) <= strongLetterDistance
    }

    /// A monotone segmentation of the heard tokens over the term tokens in which every term
    /// token is supported. Blocks "deep gram socket" -> "Deepgram websocket" as one phrase.
    private static func phraseSupported(_ heard: [Token], _ term: [Token], lexicon: LearningLexicon) -> Bool {
        if term.count == 1 { return true }
        func search(_ heardIndex: Int, _ termIndex: Int) -> Bool {
            if termIndex == term.count { return heardIndex == heard.count }
            let remainingTerms = term.count - termIndex
            guard heard.count - heardIndex >= remainingTerms else { return false }
            for length in 1...(heard.count - heardIndex - remainingTerms + 1) {
                if supports(Array(heard[heardIndex..<(heardIndex + length)]), term[termIndex], lexicon: lexicon),
                   search(heardIndex + length, termIndex + 1) {
                    return true
                }
            }
            return false
        }
        return search(0, 0)
    }

    // MARK: Judge

    /// Everything the judge needs beyond the hunk itself.
    private struct Context {
        let lexicon: LearningLexicon
        let manualTerms: Set<String>
        /// Manual and learned terms: the heard side is never learned away from these.
        let vocabularyTerms: Set<String>
        /// `ruleKey`s of the learned rules: changing a rule's output back reverts it.
        let learnedRules: Set<String>
        let isTombstoned: (String) -> Bool
    }

    /// How `learn` receives a learned rule heard -> term: both sides lowercased with whitespace
    /// runs collapsed (LearnedVocabulary.key).
    static func ruleKey(heard: String, term: String) -> String {
        func key(_ text: String) -> String { text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return key(heard) + "\u{1F}" + key(term)
    }

    private struct Judgement {
        var candidate: Candidate?
        var reason: Reason?
        /// A style-only change (case or punctuation): it counts toward the rewrite budget.
        var style = false

        static func learned(_ candidate: Candidate) -> Judgement { Judgement(candidate: candidate) }
        static func rejected(_ reason: Reason) -> Judgement { Judgement(reason: reason) }
        static func styleOnly(_ reason: Reason) -> Judgement { Judgement(reason: reason, style: true) }
    }

    private static let gluePattern = try! NSRegularExpression(pattern: #"([.!?,;])\s+(?=\p{Lu})"#)
    private static let sentenceInsidePattern = try! NSRegularExpression(pattern: #"[.!?]\s"#)
    private static let dottedShorthandPattern = try! NSRegularExpression(pattern: #"^(\p{Ll}\.)+\p{Ll}\.?$"#)

    private static func fullRange(_ text: String) -> NSRange {
        NSRange(text.startIndex..<text.endIndex, in: text)
    }

    private static func unglued(_ text: String) -> String {
        gluePattern.stringByReplacingMatches(in: text, range: fullRange(text), withTemplate: "$1")
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: fullRange(text)) != nil
    }

    private static func judge(
        heard: [Token],
        term: [Token],
        atSentenceStart: Bool,
        minConfidence: Double?,
        context: Context
    ) -> Judgement {
        let lexicon = context.lexicon
        let heardText = heard.map(\.core).joined(separator: " ")
        let termText = term.map(\.core).joined(separator: " ")
        guard heardText != termText else { return .styleOnly(.unchanged) }
        guard termText.count <= maxTermCharacters, termText.contains(where: \.isLetter) else { return .rejected(.notWord) }
        if isAddressOrMarkup(termText) || isAddressOrMarkup(heardText) { return .rejected(.address) }
        if term.contains(where: { SecretFilter.isSecretLike($0.core) }) { return .rejected(.secret) }
        if heard.allSatisfy({ isNumberLike($0.core) }) || term.allSatisfy({ isNumberLike($0.core) }) {
            return .rejected(.number)
        }
        if context.isTombstoned(termText.lowercased()) { return .rejected(.tombstoned) }
        if context.manualTerms.contains(termText.lowercased()) { return .rejected(.alreadyKnownTerm) }
        let heardRaw = heard.map(\.raw).joined(separator: " "), termRaw = term.map(\.raw).joined(separator: " ")
        if unglued(heardRaw) == unglued(termRaw) || matches(sentenceInsidePattern, termText) {
            return .rejected(.sentenceGlue)
        }
        if matches(dottedShorthandPattern, termText),
           termText.replacingOccurrences(of: ".", with: "") == heardText.lowercased() {
            return .rejected(.dottedShorthand)
        }
        let caseOnly = heardText.lowercased() == termText.lowercased()
        if caseOnly && termText.filter(\.isLetter).count <= 2 { return .styleOnly(.shortCase) }
        func codeShaped(_ word: String) -> Bool {
            guard isCodeShaped(word) else { return false }
            // A hyphenated phrase of known lowercase words ("multi-step") is prose, not code.
            let parts = word.split(separator: "-")
            if parts.count > 1, !word.contains(where: { "._+#/".contains($0) || $0.isNumber }),
               parts.allSatisfy({ isKnown(String($0), lexicon) }), !word.dropFirst().contains(where: \.isUppercase) {
                return false
            }
            return true
        }
        let codeShape = term.contains { codeShaped($0.core) }
        let termWords = term.map(\.core), heardWords = heard.map(\.core)
        let unknownTerm = termWords.contains { !isKnown($0, lexicon) && !lexicon.isFirstName($0.lowercased()) }
        let capitalizedName = termWords.enumerated().contains { index, word in
            (word.first?.isUppercase ?? false) && !(index == 0 && atSentenceStart) && !lexicon.isEveryday(word.lowercased())
        }
        let termShaped = codeShape || unknownTerm || capitalizedName
        let everydayTerm = termWords.allSatisfy { lexicon.isEveryday($0.lowercased()) } && !codeShape
        let everydayHeard = heardWords.allSatisfy { lexicon.isEveryday($0.lowercased()) }

        if caseOnly {
            if codeShape {
                return .learned(Candidate(heard: heardText, term: termText, strength: .strong, ruleNow: false, ruleLater: false))
            }
            if capitalizedName && !(term.count == 1 && termText.count <= 2) {
                let strength: Strength = (minConfidence ?? 1) < lowConfidence ? .strong : .weak
                return .learned(Candidate(heard: heardText, term: termText, strength: strength, ruleNow: false, ruleLater: false))
            }
            return .styleOnly(.styleOnly)
        }
        if heard.count == 1, term.count == 1, isInflection(heardText, termText) { return .rejected(.inflection) }
        if heard.count == 1, term.count == 1, isAffixEdit(heardText, termText, lexicon: lexicon) { return .rejected(.affixEdit) }
        if everydayTerm && everydayHeard && !capitalizedName { return .rejected(.everydayBothSides) }
        if heard.count == 1, term.count == 1, lexicon.isFirstName(heardText.lowercased()), lexicon.isFirstName(termText.lowercased()) {
            return .rejected(.commonNameSwap)
        }
        let heardForTerm = heardForDistance(heardWords, term: termText)
        let distance = LearningPhonetics.letterDistance(heardForTerm, termText)
        let keysMatch = LearningPhonetics.keysSoundAlike(heardText, termText)
            || LearningPhonetics.letterKey(heardForTerm) == LearningPhonetics.letterKey(termText)
        if context.vocabularyTerms.contains(heardText.lowercased()) {
            // Never learn away from a vocabulary term; changing it back to an ordinary
            // sound-alike word, or to what one of its learned rules rewrote, is revert evidence.
            // A rule's heard side is a non-word or a name, so its shape does not matter here.
            let undoesRule = context.learnedRules.contains(ruleKey(heard: termText, term: heardText))
            if undoesRule || (!termShaped && (keysMatch || distance <= strongLetterDistance)) {
                return .learned(Candidate(heard: heardText, term: termText, strength: .weak, ruleNow: false, ruleLater: false, isRevert: true))
            }
            return .rejected(.protectedTerm)
        }
        if heard.count > 2 * term.count && !termShaped { return .rejected(.mergeIntoWord) }
        // The term only extends what was heard by 3 or more letters (socket -> websocket).
        let heardKey = String(LearningPhonetics.letterKey(heardForTerm)), termKey = String(LearningPhonetics.letterKey(termText))
        if heardKey.count >= 3, termKey.count - heardKey.count >= 3, termKey.hasPrefix(heardKey) || termKey.hasSuffix(heardKey) {
            return .rejected(.extension)
        }
        guard termShaped else {
            return .rejected(keysMatch || distance <= strongLetterDistance ? .ordinaryWords : .notSoundAlike)
        }
        guard distance <= strongLetterDistance || keysMatch else { return .rejected(.notSoundAlike) }
        guard phraseSupported(heard, term, lexicon: lexicon) else { return .rejected(.phraseUnsupported) }
        var strength: Strength? = .strong
        if let confidence = minConfidence {
            if confidence >= highConfidence, !keysMatch, distance > weakLetterDistance { strength = nil }
            if confidence >= highConfidence, strength == .strong, heardWords.allSatisfy({
                isKnown($0, lexicon) || lexicon.isFirstName($0.lowercased())
                    || (($0.first?.isUppercase ?? false) && !atSentenceStart) || isCodeShaped($0)
            }) {
                strength = .weak
            }
        }
        guard let strength else { return .rejected(.confidentChange) }
        // A capitalized or code-shaped heard word may be a real product (Grok vs Groq): never a rule at once.
        let heardLooksLikeTerm = heardWords.enumerated().contains { index, word in
            isCodeShaped(word) || ((word.first?.isUppercase ?? false) && !(index == 0 && atSentenceStart))
        }
        let heardIsNonWord = !heardLooksLikeTerm && heardWords.contains {
            !isKnown($0, lexicon) && !lexicon.isFirstName($0.lowercased()) && !isCodeShaped($0) && $0.count >= 3
        }
        let heardLowered = heardText.lowercased()
        let heardSingleCommon = heard.count == 1
            && (lexicon.isEveryday(heardLowered) || lexicon.isFirstName(heardLowered) || isKnown(heardText, lexicon))
        let camel = termWords.count == 1 && termWords[0].dropFirst().contains(where: \.isUppercase)
            && termWords[0].contains(where: \.isLowercase)
        let snake = termWords.count == 1 && termWords[0].dropFirst().dropLast().contains("_")
        let heardIsIdentifierPhrase = heard.count > 1 && (camel || snake) && heardWords.allSatisfy { isKnown($0, lexicon) }
        let ruleNow = heardIsNonWord
        let ruleLater = !ruleNow && !heardSingleCommon && !heardIsIdentifierPhrase
        return .learned(Candidate(heard: heardText, term: termText, strength: strength, ruleNow: ruleNow, ruleLater: ruleLater))
    }

    // MARK: Resolve one hunk

    private struct Resolution {
        var candidates: [Candidate] = []
        var leftover = 0
        var nonSoundAlike = 0
        var styleWords = 0
        var groups = 0
        var fixedHeard = 0
        var reasons: [Reason] = []
    }

    private static func compositions(_ n: Int, into parts: Int) -> [[Int]] {
        if parts == 1 { return n >= 1 ? [[n]] : [] }
        guard n >= parts else { return [] }
        var result: [[Int]] = []
        for first in 1...(n - parts + 1) {
            for rest in compositions(n - first, into: parts - 1) {
                result.append([first] + rest)
            }
        }
        return result
    }

    /// Only a fix whose letters change is free of the rewrite budget.
    private static func budgetWords(_ candidate: Candidate, heardCount: Int, termCount: Int) -> Int {
        candidate.heard.lowercased() == candidate.term.lowercased() ? max(heardCount, termCount) : 0
    }

    /// A fix the user already settled: the term was removed (tombstoned) or is manual vocabulary.
    private static func isSettled(_ reason: Reason?) -> Bool {
        reason == .tombstoned || reason == .alreadyKnownTerm
    }

    /// Both sides are non-empty. In order: several strong single-word fixes side by side; the
    /// whole hunk; a partition search over edge trims and aligned groups, only when both sides
    /// have at most `maxSideWords` words (a longer hunk counts as changed words that do not
    /// sound alike). The search keeps the most candidates, then the most strong ones, then the
    /// fewest leftover words, then the fewest groups. A settled fix (a removed or manual term)
    /// is never learned in part: not as a phrase around settled words, and not as a piece of a
    /// settled phrase.
    private static func resolve(
        _ heard: [Token],
        _ term: [Token],
        caseHeard: Set<Int>,
        caseTerm: Set<Int>,
        leadingEdge: Bool,
        trailingEdge: Bool,
        atSentenceStart: Bool,
        confidence: Double?,
        context: Context
    ) -> Resolution {
        /// Why a longer span of the term side around `range` is settled, if one is.
        func settledSpanReason(around range: Range<Int>) -> Reason? {
            for length in stride(from: min(maxSideWords, term.count), to: range.count, by: -1) {
                for start in max(0, range.upperBound - length)...min(range.lowerBound, term.count - length) {
                    let text = term[start..<(start + length)].map(\.core).joined(separator: " ").lowercased()
                    if context.isTombstoned(text) { return .tombstoned }
                    if context.manualTerms.contains(text) { return .alreadyKnownTerm }
                }
            }
            return nil
        }
        if heard.count == term.count, heard.count > 1 {
            var resolution = Resolution()
            resolution.groups = heard.count
            var allDecided = true
            var changed = 0
            for (index, (a, b)) in zip(heard, term).enumerated() where a.core != b.core {
                changed += 1
                let judgement = judge(heard: [a], term: [b], atSentenceStart: atSentenceStart, minConfidence: confidence, context: context)
                let settled = judgement.candidate == nil ? judgement.reason : settledSpanReason(around: index..<(index + 1))
                if let candidate = judgement.candidate, candidate.strength == .strong, settled == nil {
                    resolution.candidates.append(candidate)
                    resolution.fixedHeard += 1
                    resolution.styleWords += budgetWords(candidate, heardCount: 1, termCount: 1)
                } else if let settled, isSettled(settled) {
                    // A settled word is still a fix, and it is never learned again inside a phrase.
                    resolution.fixedHeard += 1
                    resolution.reasons.append(settled)
                } else {
                    allDecided = false
                    break
                }
            }
            if allDecided && changed >= 2 { return resolution }
        }
        if heard.count <= maxSideWords, term.count <= maxSideWords, term.count <= 2 * heard.count {
            let judgement = judge(heard: heard, term: term, atSentenceStart: atSentenceStart, minConfidence: confidence, context: context)
            if let candidate = judgement.candidate {
                var resolution = Resolution()
                resolution.candidates = [candidate]
                resolution.groups = 1
                resolution.fixedHeard = heard.count
                resolution.styleWords = budgetWords(candidate, heardCount: heard.count, termCount: term.count)
                return resolution
            }
            if isSettled(judgement.reason), let reason = judgement.reason {
                // The whole hunk is a settled term: none of its parts is learned on its own.
                var resolution = Resolution()
                resolution.groups = 1
                resolution.fixedHeard = heard.count
                resolution.reasons = [reason]
                return resolution
            }
        }
        guard heard.count <= maxSideWords, term.count <= maxSideWords else {
            var resolution = Resolution()
            resolution.leftover = max(heard.count, term.count)
            resolution.nonSoundAlike = resolution.leftover
            resolution.reasons.append(.hunkTooLong)
            return resolution
        }
        var best: Resolution?
        func better(_ a: Resolution, _ b: Resolution) -> Bool {
            let strongA = a.candidates.filter { $0.strength == .strong }.count
            let strongB = b.candidates.filter { $0.strength == .strong }.count
            if a.candidates.count != b.candidates.count { return a.candidates.count > b.candidates.count }
            if strongA != strongB { return strongA > strongB }
            if a.leftover != b.leftover { return a.leftover < b.leftover }
            return a.groups < b.groups
        }
        let n = heard.count, m = term.count
        for heardLead in 0..<n {
            for heardTail in 0..<(n - heardLead) {
                for termLead in 0..<m {
                    for termTail in 0..<(m - termLead) {
                        // Never trim a case-only matched word.
                        let trimmedHeard = Set(0..<heardLead).union(Set((n - heardTail)..<n))
                        let trimmedTerm = Set(0..<termLead).union(Set((m - termTail)..<m))
                        if !trimmedHeard.isDisjoint(with: caseHeard) || !trimmedTerm.isDisjoint(with: caseTerm) { continue }
                        let heardCore = Array(heard[heardLead..<(n - heardTail)])
                        let termCore = Array(term[termLead..<(m - termTail)])
                        // Term-side trims are free only at the dictation's edges (typed around it).
                        let freeTermTrim = (leadingEdge ? termLead : 0) + (trailingEdge ? termTail : 0)
                        let trimmedWords = heardLead + heardTail + termLead + termTail - freeTermTrim
                        for groupCount in 1...min(heardCore.count, termCore.count) {
                            for heardSizes in compositions(heardCore.count, into: groupCount) {
                                for termSizes in compositions(termCore.count, into: groupCount) {
                                    var resolution = Resolution()
                                    resolution.leftover = trimmedWords
                                    resolution.groups = groupCount
                                    var heardIndex = 0, termIndex = 0
                                    for group in 0..<groupCount {
                                        let heardGroup = Array(heardCore[heardIndex..<(heardIndex + heardSizes[group])])
                                        let termGroup = Array(termCore[termIndex..<(termIndex + termSizes[group])])
                                        let termRange = (termLead + termIndex)..<(termLead + termIndex + termSizes[group])
                                        heardIndex += heardSizes[group]
                                        termIndex += termSizes[group]
                                        if heardGroup.map(\.core) == termGroup.map(\.core) { continue }
                                        guard termGroup.count <= 2 * heardGroup.count else {
                                            resolution.leftover += max(heardGroup.count, termGroup.count)
                                            resolution.reasons.append(.hunkTooLong)
                                            continue
                                        }
                                        let judgement = judge(
                                            heard: heardGroup,
                                            term: termGroup,
                                            atSentenceStart: atSentenceStart && group == 0 && termLead == 0,
                                            minConfidence: confidence,
                                            context: context
                                        )
                                        let settled = judgement.candidate == nil
                                            ? judgement.reason
                                            : settledSpanReason(around: termRange)
                                        if let settled, isSettled(settled) {
                                            // A settled term, or a piece of a settled phrase: a fix, never learned.
                                            resolution.fixedHeard += heardGroup.count
                                            resolution.reasons.append(settled)
                                        } else if let candidate = judgement.candidate {
                                            resolution.candidates.append(candidate)
                                            resolution.fixedHeard += heardGroup.count
                                            resolution.styleWords += budgetWords(candidate, heardCount: heardGroup.count, termCount: termGroup.count)
                                        } else if judgement.style {
                                            resolution.styleWords += max(heardGroup.count, termGroup.count)
                                        } else {
                                            resolution.leftover += max(heardGroup.count, termGroup.count)
                                            if let reason = judgement.reason { resolution.reasons.append(reason) }
                                            let a = heardGroup.map(\.core).joined(separator: " ")
                                            let b = termGroup.map(\.core).joined(separator: " ")
                                            if !LearningPhonetics.soundsAlike(a, b) {
                                                resolution.nonSoundAlike += max(heardGroup.count, termGroup.count)
                                            }
                                        }
                                    }
                                    // Trims that are not free are changed words that do not sound alike.
                                    resolution.nonSoundAlike += trimmedWords
                                    if best.map({ better(resolution, $0) }) ?? true { best = resolution }
                                }
                            }
                        }
                    }
                }
            }
        }
        return best ?? Resolution()
    }

    // MARK: Whole edit

    /// The old words of every run of changes that only removes words.
    private static func pureDeletions(_ steps: [Step]) -> Set<Int> {
        var deleted = Set<Int>()
        var run: [Int] = []
        var runInserts = false
        func endRun() {
            if !runInserts { deleted.formUnion(run) }
            run = []
            runInserts = false
        }
        for step in steps {
            switch step {
            case .equal: endRun()
            case .removed(let index): run.append(index)
            case .inserted: runInserts = true
            }
        }
        endRun()
        return deleted
    }

    /// What the fix from `pasted` to `final` teaches. `confidences` maps lowercased Deepgram
    /// words to their confidence (keyterm words already removed); `manualTerms` and
    /// `learnedTerms` hold lowercased vocabulary keys; `learnedRules` holds the `ruleKey` of
    /// each learned rule; `isTombstoned` receives a lowercased term. A term in `manualTerms` is
    /// already known; the heard side is never learned away from a manual or learned term, and
    /// changing a learned rule's output back to its heard phrase is a revert. With
    /// `appliesEditGates` false (cleanup's edit of the raw text, which normally removes filler)
    /// each hunk is judged alone: the whole-edit gates and the partial-rewrite downgrade are
    /// skipped, and pure deletions are peeled first, so a filler beside a sentence-start capital
    /// does not grow a hunk past `maxSideWords`; resolving stops after `maxUngatedHunks` hunks or
    /// once `maxCandidates` strong candidates make the rest irrelevant.
    static func learn(
        pasted: String,
        final: String,
        lexicon: LearningLexicon,
        confidences: [String: Double] = [:],
        manualTerms: Set<String> = [],
        learnedTerms: Set<String> = [],
        learnedRules: Set<String> = [],
        isTombstoned: @escaping (String) -> Bool = { _ in false },
        tieBreak: TieBreak = .earliest,
        appliesEditGates: Bool = true
    ) -> Outcome {
        var old = tokens(pasted), new = tokens(final)
        guard !old.isEmpty, !new.isEmpty else { return .nothing(.empty) }
        guard old.count <= maxTokens, new.count <= maxTokens else { return .nothing(.tooLong) }
        let context = Context(
            lexicon: lexicon,
            manualTerms: manualTerms,
            vocabularyTerms: manualTerms.union(learnedTerms),
            learnedRules: learnedRules,
            isTombstoned: isTombstoned
        )
        var steps = script(old.map(\.fold), new.map(\.fold), tieBreak: tieBreak)
        // Drop duplicated words (stutters) the user deleted or that the recognizer repeated.
        var otherFromDuplicates = 0
        var dropOld = Set<Int>(), dropNew = Set<Int>()
        for step in steps {
            if case .removed(let i) = step, i > 0, old[i].fold == old[i - 1].fold {
                dropOld.insert(i)
                otherFromDuplicates += 1
            }
            if case .removed(let i) = step, i + 1 < old.count, old[i].fold == old[i + 1].fold, !dropOld.contains(i) {
                dropOld.insert(i)
                otherFromDuplicates += 1
            }
            if case .inserted(let j) = step, j > 0, new[j].fold == new[j - 1].fold {
                dropNew.insert(j)
                otherFromDuplicates += 1
            }
        }
        if !dropOld.isEmpty || !dropNew.isEmpty {
            old = old.enumerated().filter { !dropOld.contains($0.offset) }.map(\.element)
            new = new.enumerated().filter { !dropNew.contains($0.offset) }.map(\.element)
            steps = script(old.map(\.fold), new.map(\.fold), tieBreak: tieBreak)
        }
        if !appliesEditGates {
            let deleted = pureDeletions(steps)
            if !deleted.isEmpty {
                old = old.enumerated().filter { !deleted.contains($0.offset) }.map(\.element)
                steps = script(old.map(\.fold), new.map(\.fold), tieBreak: tieBreak)
            }
        }
        let kept = steps.reduce(0) { count, step in
            if case .equal = step { return count + 1 }
            return count
        }
        guard kept > 0 || old.count <= 2 else { return .nothing(.notFound) }
        var caseOnlyOld = Set<Int>(), caseOnlyNew = Set<Int>()
        for step in steps {
            if case .equal(let i, let j) = step, old[i].core != new[j].core {
                caseOnlyOld.insert(i)
                caseOnlyNew.insert(j)
            }
        }
        let rewriteBudget = max(rewriteFloor, Int((rewriteShare * Double(old.count)).rounded(.down)))

        var found: [Candidate] = []
        var reasons: [Reason] = []
        var other = otherFromDuplicates, nonSoundAlike = otherFromDuplicates, styleWords = 0, fixed = 0
        var resolvedHunks = 0
        func pairKey(_ candidate: Candidate) -> String {
            candidate.heard.lowercased() + "\u{1F}" + candidate.term.lowercased()
        }
        // Every count only grows, so an edit over the rewrite budget or with too many other
        // changes stops early instead of resolving its remaining hunks.
        if appliesEditGates, nonSoundAlike + styleWords > rewriteBudget { return .nothing(.rewrite) }
        for hunk in hunks(steps, old, new) {
            let heard = hunk.old.map { old[$0] }, term = hunk.new.map { new[$0] }
            if heard.isEmpty && (hunk.leading || hunk.trailing) { continue }
            if heard.isEmpty || term.isEmpty {
                other += heard.count + term.count
                nonSoundAlike += heard.count + term.count
            } else {
                let firstNew = hunk.new.first ?? 0
                let atStart = firstNew == 0 || new[firstNew - 1].raw.last.map { ".!?:".contains($0) } == true
                let heardConfidences = heard.map { confidences[$0.fold] }
                let confidence = heardConfidences.contains(where: { $0 == nil }) ? nil : heardConfidences.compactMap { $0 }.min()
                let caseHeard = Set(hunk.old.enumerated().filter { caseOnlyOld.contains($0.element) }.map(\.offset))
                let caseTerm = Set(hunk.new.enumerated().filter { caseOnlyNew.contains($0.element) }.map(\.offset))
                let resolution = resolve(
                    heard,
                    term,
                    caseHeard: caseHeard,
                    caseTerm: caseTerm,
                    leadingEdge: hunk.leading && !hunk.trailing,
                    trailingEdge: hunk.trailing && !hunk.leading,
                    atSentenceStart: atStart,
                    confidence: confidence,
                    context: context
                )
                found += resolution.candidates
                other += resolution.leftover
                nonSoundAlike += resolution.nonSoundAlike
                styleWords += resolution.styleWords
                fixed += resolution.fixedHeard
                reasons += resolution.reasons
                resolvedHunks += 1
            }
            if appliesEditGates {
                if nonSoundAlike + styleWords > rewriteBudget { return .nothing(.rewrite) }
                if other > maxOtherChanged { return .nothing(.rewording) }
            } else if resolvedHunks >= maxUngatedHunks
                || Set(found.filter { $0.strength == .strong }.map(pairKey)).count >= maxCandidates {
                break
            }
        }
        if appliesEditGates {
            if other > maxOtherChanged { return .nothing(.rewording) }
            let exactKept = steps.reduce(0) { count, step in
                if case .equal(let i, let j) = step, old[i].core == new[j].core { return count + 1 }
                return count
            }
            if old.count - fixed > 0, Double(exactKept) < minKeptShare * Double(old.count - fixed) {
                return .nothing(.notThisDictation)
            }
        }
        var seen = Set<String>()
        found = found.filter { seen.insert(pairKey($0)).inserted }
        if found.isEmpty { return .nothing(reasons.first ?? (other > 0 ? .contentEdit : .styleOrUnchanged)) }
        if appliesEditGates, nonSoundAlike >= partialRewriteWords {
            // A partial rewrite: every candidate becomes weak and none is a rule at once.
            found = found.map { candidate in
                var candidate = candidate
                candidate.strength = .weak
                candidate.ruleNow = false
                return candidate
            }
        }
        if found.count > maxCandidates {
            found = found.filter { $0.strength == .strong } + found.filter { $0.strength == .weak }
            found = Array(found.prefix(maxCandidates))
        }
        return .learned(found)
    }
}
