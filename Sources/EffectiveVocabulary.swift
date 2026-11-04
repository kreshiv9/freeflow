import Foundation

/// The one place manual and learned vocabulary meet. Every consumer reads this: the Deepgram
/// keyterm planner's learned slice, the cleanup and Edit Mode vocabulary, the corrections
/// applied to raw and cleaned text, and cursor fitting. Manual entries always win; pending
/// sightings never appear.
struct EffectiveVocabulary: Equatable {
    /// The Custom Vocabulary text, then the learned terms on their own lines.
    let vocabularyText: String
    /// The manual rules, then the learned rules whose heard phrase no manual rule has.
    let corrections: [DictionaryCorrection]
    /// Ranked learned terms for KeytermPlan.Tiers.learned; the planner cuts the slice.
    let learnedKeyterms: [String]

    /// - vocabularyText: learned active and ambiguous terms in rank order, except those that
    ///   are a manual entry or a manual correction target. Unchanged when none is left.
    /// - corrections: learned rules of active terms only, except a heard phrase that a manual
    ///   rule corrects or that is itself a manual entry or correction target; a term whose
    ///   casing is unknown (learned from searches) applies its rules only in the search
    ///   category, so a lowercase spelling never rewrites prose.
    /// - learnedKeyterms: see `learnedKeyterms(…)`.
    static func merge(
        manualVocabulary: String,
        manualCorrections: [DictionaryCorrection],
        learned: LearnedVocabulary,
        category: LearnedVocabulary.Category,
        now: Date
    ) -> EffectiveVocabulary {
        let manualKeys = manualTermKeys(vocabulary: manualVocabulary, corrections: manualCorrections)
        let allRanked = learned.rankedItems(category: category, now: now)
        let ranked = allRanked.filter { !manualKeys.contains(LearnedVocabulary.key($0.text)) }

        let learnedTerms = ranked.map(\.text)
        let vocabularyText = learnedTerms.isEmpty
            ? manualVocabulary
            : ([manualVocabulary] + learnedTerms).filter { !$0.isEmpty }.joined(separator: "\n")

        let protectedHeard = protectedHeardKeys(manualTermKeys: manualKeys, manualCorrections: manualCorrections)
        var learnedFroms = Set<String>()
        var learnedRules: [DictionaryCorrection] = []
        for item in allRanked where appliesRules(of: item) && (item.casingKnown || category == .search) {
            for variant in item.variants where variant.isRule {
                let fromKey = LearnedVocabulary.key(variant.heard)
                // Manual entries win: a learned rule never rewrites a word the user keeps.
                guard !protectedHeard.contains(fromKey), learnedFroms.insert(fromKey).inserted else { continue }
                learnedRules.append(DictionaryCorrection(id: variant.id, from: variant.heard, to: item.text))
            }
        }

        return EffectiveVocabulary(
            vocabularyText: vocabularyText,
            corrections: manualCorrections + learnedRules,
            learnedKeyterms: ranked.filter { isKeyterm($0, category: category, now: now) }.map(\.text)
        )
    }

    /// The ranked learned keyterms alone, which need no spellings or rules: active terms
    /// only, not dormant, not manual, and identifier-shaped terms only in the coding category.
    /// Secret-like terms never reach the store (LearnedVocabulary checks every term when it
    /// stores or loads it), so none is filtered here. The dictation start reads a
    /// LearnedKeytermIndex ranked ahead of time instead.
    static func learnedKeyterms(
        manualVocabulary: String,
        manualCorrections: [DictionaryCorrection],
        learned: LearnedVocabulary,
        category: LearnedVocabulary.Category,
        now: Date
    ) -> [String] {
        LearnedKeytermIndex(
            manualVocabulary: manualVocabulary,
            manualCorrections: manualCorrections,
            learned: learned,
            categories: [category],
            now: now
        ).keyterms(for: category, now: now)
    }

    private static func isKeyterm(_ item: LearnedVocabulary.Item, category: LearnedVocabulary.Category, now: Date) -> Bool {
        item.state == .active
            && !LearnedVocabulary.isDormant(item, now: now)
            && (category == .coding || !isIdentifierShaped(item.text))
    }

    /// learnedKeyterms(…) for every category, ranked once (off the main thread) so a
    /// dictation start only drops the terms that went dormant since. Every score decays at
    /// the same rate, so the order does not change as time passes; the index holds until the
    /// learned store or the manual lists change.
    struct LearnedKeytermIndex: Equatable {
        struct Entry: Equatable {
            let text: String
            let lastActive: Date
            let starred: Bool
        }

        private(set) var entries: [LearnedVocabulary.Category: [Entry]] = [:]

        init() {}

        init(
            manualVocabulary: String,
            manualCorrections: [DictionaryCorrection],
            learned: LearnedVocabulary,
            categories: [LearnedVocabulary.Category] = LearnedVocabulary.Category.allCases,
            now: Date
        ) {
            guard !learned.items.isEmpty else { return }
            let manualKeys = manualTermKeys(vocabulary: manualVocabulary, corrections: manualCorrections)
            var candidates = learned
            candidates.items.removeAll {
                $0.state != .active || LearnedVocabulary.isDormant($0, now: now)
                    || manualKeys.contains(LearnedVocabulary.key($0.text))
            }
            for category in categories {
                entries[category] = candidates.rankedItems(category: category, now: now)
                    .filter { category == .coding || !isIdentifierShaped($0.text) }
                    .map { Entry(text: $0.text, lastActive: $0.lastActive, starred: $0.starred) }
            }
        }

        /// The ranked keyterms for `category` that are not dormant at `now`.
        func keyterms(for category: LearnedVocabulary.Category, now: Date) -> [String] {
            (entries[category] ?? [])
                .filter { !LearnedVocabulary.isDormant(lastActive: $0.lastActive, starred: $0.starred, now: now) }
                .map(\.text)
        }
    }

    /// Why the Corrections card shows a learned rule as not in use.
    enum UnusedRuleReason: Equatable {
        /// Its term was changed back twice: still a spelling, but its rules are off.
        case notSure
        /// A manual correction, Custom Vocabulary entry or correction target keeps the heard
        /// phrase.
        case manualWins

        var helpText: String {
            switch self {
            case .notSure: "Learned, not in use: you changed this word back, so FreeFlow is not sure about it"
            case .manualWins: "Learned, not in use: your Custom Vocabulary or Corrections keep this word"
            }
        }
    }

    /// A learned rule as the Corrections card lists it.
    struct ListedRule: Identifiable {
        let rule: LearnedVocabulary.RuleRow
        /// Nil when merge applies the rule (a term of unknown casing only in searches).
        let unused: UnusedRuleReason?
        var id: UUID { rule.id }
    }

    /// Every learned rule, each marked with why merge does not apply it, by merge's own checks.
    static func listedRules(
        manualVocabulary: String,
        manualCorrections: [DictionaryCorrection],
        learned: LearnedVocabulary
    ) -> [ListedRule] {
        let rows = learned.ruleRows
        guard !rows.isEmpty else { return [] }
        let protectedHeard = protectedHeardKeys(
            manualTermKeys: manualTermKeys(vocabulary: manualVocabulary, corrections: manualCorrections),
            manualCorrections: manualCorrections
        )
        return rows.map { row in
            let unused: UnusedRuleReason? = if !appliesRules(of: row.item) {
                .notSure
            } else if protectedHeard.contains(LearnedVocabulary.key(row.variant.heard)) {
                .manualWins
            } else {
                nil
            }
            return ListedRule(rule: row, unused: unused)
        }
    }

    /// Only an active term's rules apply; an ambiguous term stays a spelling.
    private static func appliesRules(of item: LearnedVocabulary.Item) -> Bool {
        item.state == .active
    }

    /// Heard phrases no learned rule rewrites: manual correction sources, Custom Vocabulary
    /// entries and correction targets (`manualTermKeys`).
    private static func protectedHeardKeys(manualTermKeys: Set<String>, manualCorrections: [DictionaryCorrection]) -> Set<String> {
        manualTermKeys.union(
            manualCorrections.map(\.normalized).filter(\.isUsable).map { LearnedVocabulary.key($0.from) }
        )
    }

    /// Keys (LearnedVocabulary.key) of the Custom Vocabulary entries and the usable correction
    /// targets. The learner treats these as already known.
    static func manualTermKeys(vocabulary: String, corrections: [DictionaryCorrection]) -> Set<String> {
        let entries = VocabularyDraftMerge.entries(vocabulary)
        let targets = corrections.map(\.normalized).filter(\.isUsable).map(\.to)
        return Set((entries + targets).map(LearnedVocabulary.key))
    }

    private static let lowerCamelPattern = try! NSRegularExpression(pattern: #"^[a-z][a-z0-9]*[A-Z]"#)
    private static let fileNamePattern = try! NSRegularExpression(pattern: #"^[a-z][A-Za-z0-9_-]*\.[a-z0-9]{1,5}$"#)

    /// One token that is snake_case, lowerCamel or a lowercase-led file name: order_id, userId,
    /// useAuth.ts. Brand and model names (GPT-4o, JSON, GitHub, Next.js) are not.
    static func isIdentifierShaped(_ term: String) -> Bool {
        guard !term.isEmpty, !term.contains(where: \.isWhitespace) else { return false }
        if term.contains("_") { return true }
        let range = NSRange(term.startIndex..<term.endIndex, in: term)
        return lowerCamelPattern.firstMatch(in: term, range: range) != nil
            || fileNamePattern.firstMatch(in: term, range: range) != nil
    }
}
