import CryptoKit
import Foundation

/// "Learn automatically". A missing preference keeps learning on (the user's decision).
/// Off stops learning (Run Log Fix, hit counts, Deepgram evidence) and the aging of learned
/// items, which stay in use until deleted; expired evidence is still deleted at launch.
enum LearningPreference {
    static let storageKey = "auto_learning_enabled"
    static let defaultEnabled = true

    /// The stored choice, or the default for a missing or invalid value; never persists one.
    static func load(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: storageKey) as? Bool) ?? defaultEnabled
    }
}

/// Where a fix was observed. Every source of the learning plan is defined now so this build
/// can read a store written by a later one.
enum LearningSource: String, Codable, CaseIterable, Sendable {
    case runLog
    case claudeCode
    case chatGPT
    case googleSearch
    case cleanup

    var displayName: String {
        switch self {
        case .runLog: "Run Log"
        case .claudeCode: "Claude Code"
        case .chatGPT: "ChatGPT"
        case .googleSearch: "Google search"
        case .cleanup: "cleanup"
        }
    }

    /// Search queries are typed lowercase, so they never tell a term's casing.
    var knowsCasing: Bool { self != .googleSearch }
}

/// Terms and rules learned from the user's fixes, stored as versioned JSON under
/// `storageKey`. Holds derived items only: terms, heard phrases of at most four words,
/// counts, dates, sources and categories; never a sentence. Pending sightings and
/// tombstones are SHA-256 hashes of the normalized text (minimization, not secrecy: short
/// words can be guessed from their hashes); counted Run Log entries are hashes of their random
/// ids. Pure: no logging and no clock; callers pass `now`.
struct LearnedVocabulary: Codable, Equatable {
    static let storageKey = "learned_vocabulary_v1"

    static let maxActiveItems = 200
    static let maxPending = 500
    static let maxSightings = 8
    static let maxVariants = 8
    static let day: TimeInterval = 86_400
    /// A pending sighting expires this long after it was first seen.
    static let pendingLifetime = 30 * day
    /// An item unused this long is no longer sent as a keyterm…
    static let dormantAfter = 90 * day
    /// …and is deleted after this long, unless starred.
    static let deleteAfter = 180 * day
    static let scoreHalfLife = 30 * day
    /// Reverts and rule-later sightings count inside this window.
    static let evidenceWindow = 30 * day
    static let revertsForAmbiguous = 2
    static let ruleLaterSightings = 2
    static let ruleLaterKeytermSightings = 1
    static let correctionWeight = 3.0
    static let hitWeight = 1.0
    static let categoryBoost = 1.5
    /// Learnings this close together share one toast and one Undo.
    static let toastBatchSeconds: TimeInterval = 10
    /// How long the menu bar offers Undo Last Learned.
    static let undoMenuSeconds: TimeInterval = 600
    /// Changes are saved this long after the last one (and when the app quits), so a hit
    /// counted after a dictation never encodes the store on the way to the paste.
    static let saveDelay: TimeInterval = 1

    enum Category: String, Codable, CaseIterable, Sendable {
        case coding
        case aiChat
        case search
        case other

        init(_ category: DictationAppCategory?) {
            switch category {
            case .coding: self = .coding
            case .aiChat: self = .aiChat
            default: self = .other
            }
        }
    }

    enum State: String, Codable, Sendable {
        case active
        /// Changed back to an ordinary word twice: kept as a spelling, no longer a keyterm.
        case ambiguous
    }

    /// One way the term was heard. `isRule` makes it a correction rule heard -> term.
    struct HeardVariant: Codable, Equatable, Identifiable {
        var id = UUID()
        var heard: String
        /// The most recent sightings of this pair, at most maxSightings.
        var sightings: [Date] = []
        /// Sightings while the term was among that dictation's sent keyterms.
        var keytermSightings = 0
        /// Times the heard phrase was kept unchanged in an observed final text.
        var keptUnchanged = 0
        var ruleLaterEligible = false
        var isRule = false
    }

    struct Item: Codable, Equatable, Identifiable {
        var id = UUID()
        var text: String
        var casingKnown: Bool
        /// Sorted and unique.
        var sources: [LearningSource]
        var categoryCounts: [String: Int] = [:]
        var corrections = 0
        var hits = 0
        var keytermFailures = 0
        var revertDates: [Date] = []
        /// At most maxVariants.
        var variants: [HeardVariant] = []
        var firstSeen: Date
        var lastSeen: Date
        var lastUsed: Date?
        var starred = false
        var state: State = .active
        /// Frecency, decayed with scoreHalfLife from scoreDate.
        var score = 0.0
        var scoreDate: Date

        /// The later of the last correction and the last hit.
        var lastActive: Date { max(lastSeen, lastUsed ?? lastSeen) }

        func decayedScore(at now: Date) -> Double {
            score * pow(0.5, max(0, now.timeIntervalSince(scoreDate)) / LearnedVocabulary.scoreHalfLife)
        }

        /// The category with the most observations; ties go to the first name in sort order.
        var mainCategory: Category? {
            categoryCounts
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .first
                .flatMap { Category(rawValue: $0.key) }
        }

        fileprivate mutating func bumpScore(_ weight: Double, now: Date) {
            score = decayedScore(at: now) + weight
            scoreDate = max(scoreDate, now)
        }
    }

    /// A sighting that is not active yet: only a hash of the normalized pair and dates.
    struct Pending: Codable, Equatable {
        var pairHash: String
        var count: Int
        var firstSeen: Date
        var lastSeen: Date
    }

    /// A Run Log entry whose Fix counted a sighting: a hash of the entry's random id and when.
    struct CountedEntry: Codable, Equatable {
        var entryHash: String
        var countedAt: Date
    }

    /// One fix to learn from. `pasted` and `final` serve only the kept-unchanged check and are
    /// never stored.
    struct Observation {
        var source: LearningSource
        var category: Category
        /// The final text is known to be what was sent (Run Log Fix always is).
        var settled: Bool
        /// The keyterms that dictation actually sent to Deepgram.
        var sentKeyterms: [String]
        var pasted: String
        var final: String
    }

    /// A learned rule as the Corrections card shows it.
    struct RuleRow: Identifiable {
        let item: Item
        let variant: HeardVariant
        var id: UUID { variant.id }
    }

    struct RuleRef: Equatable {
        let itemID: UUID
        let variantID: UUID
    }

    struct RulePair: Equatable {
        let heard: String
        let term: String
    }

    /// What one apply changed. In memory only: it drives the toast, the result text and Undo.
    struct Change: Equatable {
        var addedItemIDs: [UUID] = []
        var addedRules: [RuleRef] = []
        var pendingAdded = 0
        /// Existing terms seen again.
        var updatedTerms: [String] = []
        var reverts = 0
        var refused = 0
        /// A text-free outcome code for logs and counters.
        var code = ""
        var learnedTerms: [String] = []
        var learnedRules: [RulePair] = []
        /// The Run Log entries this change counted (entryHash): Undo releases them, so the
        /// same dictation can be fixed again.
        var countedEntryHashes: [String] = []

        /// A new term or rule that the toast announces and Undo removes.
        var hasLearned: Bool { !addedItemIDs.isEmpty || !addedRules.isEmpty }

        /// The fix counted as a sighting: something was learned, became pending, was seen
        /// again or was reverted.
        var countedSighting: Bool { hasLearned || pendingAdded > 0 || !updatedTerms.isEmpty || reverts > 0 }

        /// "Rule: versel → Vercel" when the change is one rule for at most its own new term,
        /// otherwise "Learned: A, B".
        var toastText: String {
            if learnedRules.count == 1, let rule = learnedRules.first,
               learnedTerms.isEmpty || learnedTerms == [rule.term] {
                return "Rule: \(rule.heard) → \(rule.term)"
            }
            return "Learned: " + announcedTerms.joined(separator: ", ")
        }

        /// The menu item's short name: the rule, or the first term and how many more.
        var menuTitle: String {
            if learnedRules.count == 1, let rule = learnedRules.first,
               learnedTerms.isEmpty || learnedTerms == [rule.term] {
                return "\(rule.heard) → \(rule.term)"
            }
            let terms = announcedTerms
            guard let first = terms.first else { return "" }
            return terms.count == 1 ? first : "\(first) +\(terms.count - 1)"
        }

        private var announcedTerms: [String] {
            var terms = learnedTerms
            for rule in learnedRules where !terms.contains(rule.term) { terms.append(rule.term) }
            return terms
        }

        /// This change followed by `later`, for a batched toast and one Undo.
        func merging(_ later: Change) -> Change {
            var merged = self
            merged.addedItemIDs += later.addedItemIDs.filter { !merged.addedItemIDs.contains($0) }
            merged.addedRules += later.addedRules.filter { !merged.addedRules.contains($0) }
            merged.pendingAdded += later.pendingAdded
            merged.updatedTerms += later.updatedTerms.filter { !merged.updatedTerms.contains($0) }
            merged.reverts += later.reverts
            merged.refused += later.refused
            merged.learnedTerms += later.learnedTerms.filter { !merged.learnedTerms.contains($0) }
            merged.learnedRules += later.learnedRules.filter { !merged.learnedRules.contains($0) }
            merged.countedEntryHashes += later.countedEntryHashes.filter { !merged.countedEntryHashes.contains($0) }
            merged.code = merged.hasLearned ? "learned" : later.code
            return merged
        }
    }

    var version = 1
    var items: [Item] = []
    var pending: [Pending] = []
    /// Sorted SHA-256 hex of deleted terms and pairs; never re-learned.
    var tombstones: [String] = []
    /// Text-free outcome counts for the activity line.
    var counters: [String: Int] = [:]
    /// Run Log entries whose Fix counted a sighting, kept for evidenceWindow (at most
    /// maxPending): fixing the same dictation again, even after a relaunch, adds nothing.
    /// Optional so a store saved without it still loads; nil when empty.
    var countedEntries: [CountedEntry]?

    // MARK: Persistence

    /// The stored store; a missing key or undecodable data loads as empty, like
    /// DictionaryCorrection.load, and is replaced on the next write. Only a change writes (a
    /// quit without a pending save does not), so data from a newer build stays until this
    /// build changes the store. Terms are checked here once rather than on every dictation:
    /// apply stores only storable text, and this drops any term the current filters (secrets
    /// included) reject.
    static func load(from defaults: UserDefaults) -> LearnedVocabulary {
        guard let data = defaults.data(forKey: storageKey),
              var decoded = try? JSONDecoder().decode(LearnedVocabulary.self, from: data) else {
            return LearnedVocabulary()
        }
        decoded.items.removeAll { !isStorable($0.text) }
        return decoded
    }

    /// An empty store removes the key, so nothing learned leaves nothing behind.
    func save(to defaults: UserDefaults) {
        guard self != LearnedVocabulary() else {
            Self.removeStored(from: defaults)
            return
        }
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    static func removeStored(from defaults: UserDefaults) {
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: Keys and hashes

    /// Lowercased with whitespace runs collapsed: how terms and heard phrases are compared.
    static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func termHash(_ term: String) -> String {
        sha256Hex("t\u{1F}" + key(term))
    }

    static func pairHash(heard: String, term: String) -> String {
        sha256Hex("p\u{1F}" + key(heard) + "\u{1F}" + key(term))
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func isTombstoned(term: String) -> Bool {
        tombstones.contains(Self.termHash(term))
    }

    func isTombstoned(heard: String, term: String) -> Bool {
        tombstones.contains(Self.pairHash(heard: heard, term: term))
    }

    static func entryHash(_ entryID: UUID) -> String {
        sha256Hex("e\u{1F}" + entryID.uuidString)
    }

    /// A Fix of this Run Log entry counted a sighting within evidenceWindow.
    func hasCounted(entryID: UUID, now: Date) -> Bool {
        let hash = Self.entryHash(entryID)
        return (countedEntries ?? []).contains {
            $0.entryHash == hash && now.timeIntervalSince($0.countedAt) <= Self.evidenceWindow
        }
    }

    /// Remembers that a Fix of this Run Log entry counted a sighting; returns its hash.
    mutating func markCounted(entryID: UUID, now: Date) -> String {
        let hash = Self.entryHash(entryID)
        var entries = (countedEntries ?? []).filter { $0.entryHash != hash }
        entries.append(CountedEntry(entryHash: hash, countedAt: now))
        if entries.count > Self.maxPending {
            entries.removeFirst(entries.count - Self.maxPending)
        }
        countedEntries = entries
        return hash
    }

    private mutating func keepCountedEntries(where isKept: (CountedEntry) -> Bool) {
        guard let entries = countedEntries else { return }
        let kept = entries.filter(isKept)
        countedEntries = kept.isEmpty ? nil : kept
    }

    /// Keys of every learned term, active or ambiguous: the learner never learns away from them.
    var termKeys: Set<String> {
        Set(items.map { Self.key($0.text) })
    }

    /// CorrectionLearner.ruleKey of every learned rule: changing one's output back reverts it.
    var ruleKeys: Set<String> {
        Set(items.flatMap { item in
            item.variants.filter(\.isRule).map { CorrectionLearner.ruleKey(heard: $0.heard, term: item.text) }
        })
    }

    private mutating func tombstone(_ hash: String) {
        guard !tombstones.contains(hash) else { return }
        tombstones.append(hash)
        tombstones.sort()
    }

    private mutating func tombstoneItem(_ item: Item) {
        tombstone(Self.termHash(item.text))
        for variant in item.variants {
            tombstone(Self.pairHash(heard: variant.heard, term: item.text))
        }
    }

    private mutating func count(_ code: String, by amount: Int = 1) {
        counters[code, default: 0] += amount
    }

    private func itemIndex(forKey termKey: String) -> Int? {
        items.firstIndex { Self.key($0.text) == termKey }
    }

    // MARK: Learning

    /// Records what the learner found in one observation. Prunes first, then counts the heard
    /// phrases kept unchanged, then applies each candidate:
    /// - a revert deletes the learned rule it undid and tombstones the pair, or else counts
    ///   toward the ambiguous state (two within evidenceWindow); manual terms are not tracked;
    /// - a term already learned counts one more correction, takes a case-only fix's casing,
    ///   and records the heard variant;
    /// - a strong, settled candidate becomes an active term; anything else waits as a pending
    ///   hash and becomes active on a second sighting within pendingLifetime; a pending
    ///   sighting of the same pair counts as an earlier sighting whatever the new one's
    ///   strength;
    /// - a rule is made now for a strong, settled `ruleNow` candidate, or later once the pair
    ///   was seen ruleLaterSightings times in evidenceWindow, at least once while the term was
    ///   a sent keyterm, and its heard phrase was never kept unchanged. Tombstoned pairs never
    ///   become rules.
    /// The caps hold after the candidates too; the terms this change learned are kept.
    mutating func apply(_ outcome: CorrectionLearner.Outcome, from observation: Observation, now: Date) -> Change {
        _ = prune(now: now)
        recordKeptUnchanged(pasted: observation.pasted, final: observation.final)
        var change = Change()
        switch outcome {
        case .nothing(let reason):
            change.code = "nothing:\(reason.rawValue)"
            count(change.code)
            return change
        case .learned(let candidates):
            let sentKeys = Set(observation.sentKeyterms.map(Self.key))
            for candidate in candidates {
                if candidate.isRevert {
                    applyRevert(candidate, now: now, change: &change)
                } else {
                    apply(candidate, observation: observation, sentKeys: sentKeys, now: now, change: &change)
                }
            }
            capPending()
            capItems(now: now, keeping: Set(change.addedItemIDs))
        }
        if change.hasLearned {
            change.code = "learned"
        } else if change.pendingAdded > 0 {
            change.code = "pending"
        } else if !change.updatedTerms.isEmpty {
            change.code = "seenAgain"
        } else if change.reverts > 0 {
            change.code = "revert"
        } else {
            change.code = "refused"
        }
        return change
    }

    /// A term or heard phrase the store refuses: a list separator, too long, or secret-like.
    static func isStorable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= DictionaryCorrection.maxFieldLength
            && !trimmed.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "," || $0 == ";" })
            && !SecretFilter.isSecretLike(trimmed)
    }

    /// Counts each heard phrase (not a rule) that both texts contain. Each text is tokenized
    /// once and a phrase is looked up, so the cost grows with the texts plus the variants.
    private mutating func recordKeptUnchanged(pasted: String, final: String) {
        guard !items.isEmpty, !pasted.isEmpty, !final.isEmpty else { return }
        let heardKeys = items.map { item in item.variants.map { $0.isRule ? "" : Self.key($0.heard) } }
        let maxWords = heardKeys.joined().map { $0.isEmpty ? 0 : $0.split(separator: " ").count }.max() ?? 0
        guard maxWords > 0 else { return }
        let pastedPhrases = Self.phraseKeys(pasted, maxWords: maxWords)
        let finalPhrases = Self.phraseKeys(final, maxWords: maxWords)
        for itemIndex in items.indices {
            for variantIndex in items[itemIndex].variants.indices {
                let heardKey = heardKeys[itemIndex][variantIndex]
                if !heardKey.isEmpty, pastedPhrases.contains(heardKey), finalPhrases.contains(heardKey) {
                    items[itemIndex].variants[variantIndex].keptUnchanged += 1
                }
            }
        }
    }

    /// Every run of 1...maxWords words of `text` as the learner tokenizes it, lowercased and
    /// joined by single spaces (the form of `key(heard)`). A run never crosses punctuation
    /// between two words, so "cloud. Code" holds no "cloud code".
    static func phraseKeys(_ text: String, maxWords: Int) -> Set<String> {
        let tokens = CorrectionLearner.tokens(text)
        var phrases = Set<String>()
        for start in tokens.indices {
            var phrase = tokens[start].fold
            phrases.insert(phrase)
            var end = start + 1
            while end < tokens.count, end - start < maxWords,
                  tokens[end - 1].raw.hasSuffix(tokens[end - 1].core), tokens[end].raw.hasPrefix(tokens[end].core) {
                phrase += " " + tokens[end].fold
                phrases.insert(phrase)
                end += 1
            }
        }
        return phrases
    }

    private mutating func applyRevert(_ candidate: CorrectionLearner.Candidate, now: Date, change: inout Change) {
        // The heard side is the learned term; the user changed it back to `candidate.term`.
        guard let index = itemIndex(forKey: Self.key(candidate.heard)) else { return }
        change.reverts += 1
        count("revert")
        let restoredKey = Self.key(candidate.term)
        if let variantIndex = items[index].variants.firstIndex(where: { $0.isRule && Self.key($0.heard) == restoredKey }) {
            items[index].variants[variantIndex].isRule = false
            items[index].variants[variantIndex].ruleLaterEligible = false
            tombstone(Self.pairHash(heard: items[index].variants[variantIndex].heard, term: items[index].text))
            return
        }
        items[index].revertDates.append(now)
        let recent = items[index].revertDates.filter { now.timeIntervalSince($0) <= Self.evidenceWindow }
        if recent.count >= Self.revertsForAmbiguous {
            items[index].state = .ambiguous
        }
    }

    private mutating func apply(
        _ candidate: CorrectionLearner.Candidate,
        observation: Observation,
        sentKeys: Set<String>,
        now: Date,
        change: inout Change
    ) {
        guard Self.isStorable(candidate.term), Self.isStorable(candidate.heard), !isTombstoned(term: candidate.term) else {
            change.refused += 1
            count("refused")
            return
        }
        let termKey = Self.key(candidate.term)
        let wasKeyterm = sentKeys.contains(termKey)
        let categoryKey = observation.category.rawValue
        // A pending sighting of this pair (prune removed those older than pendingLifetime) is
        // an earlier sighting whatever this candidate's strength, so its hash is used up here.
        let pairHash = Self.pairHash(heard: candidate.heard, term: candidate.term)
        var sightingDates = [now]
        if let pendingIndex = pending.firstIndex(where: { $0.pairHash == pairHash }) {
            sightingDates.insert(pending[pendingIndex].firstSeen, at: 0)
            pending.remove(at: pendingIndex)
        }
        if let index = itemIndex(forKey: termKey) {
            items[index].corrections += sightingDates.count
            items[index].bumpScore(Self.correctionWeight * Double(sightingDates.count), now: now)
            items[index].lastSeen = max(items[index].lastSeen, now)
            if !items[index].sources.contains(observation.source) {
                items[index].sources = (items[index].sources + [observation.source]).sorted { $0.rawValue < $1.rawValue }
            }
            items[index].categoryCounts[categoryKey, default: 0] += 1
            if wasKeyterm { items[index].keytermFailures += 1 }
            let caseOnly = candidate.heard.lowercased() == candidate.term.lowercased()
            if observation.source.knowsCasing, caseOnly || !items[index].casingKnown {
                items[index].text = candidate.term
                items[index].casingKnown = true
            }
            change.updatedTerms.append(items[index].text)
            upsertVariant(candidate, itemIndex: index, sightingDates: sightingDates, wasKeyterm: wasKeyterm, observation: observation, now: now, change: &change)
            return
        }
        // A first sighting that is weak or unsettled waits; a second one activates the term.
        if sightingDates.count == 1, candidate.strength == .weak || !observation.settled {
            pending.append(Pending(pairHash: pairHash, count: 1, firstSeen: now, lastSeen: now))
            change.pendingAdded += 1
            count("pending")
            return
        }
        var item = Item(
            text: candidate.term,
            casingKnown: observation.source.knowsCasing,
            sources: [observation.source],
            firstSeen: now,
            lastSeen: now,
            scoreDate: now
        )
        item.categoryCounts[categoryKey] = 1
        item.corrections = sightingDates.count
        item.score = Self.correctionWeight * Double(sightingDates.count)
        if wasKeyterm { item.keytermFailures = 1 }
        items.append(item)
        change.addedItemIDs.append(item.id)
        change.learnedTerms.append(item.text)
        count("learnedActive")
        upsertVariant(candidate, itemIndex: items.count - 1, sightingDates: sightingDates, wasKeyterm: wasKeyterm, observation: observation, now: now, change: &change)
    }

    private mutating func upsertVariant(
        _ candidate: CorrectionLearner.Candidate,
        itemIndex: Int,
        sightingDates: [Date],
        wasKeyterm: Bool,
        observation: Observation,
        now: Date,
        change: inout Change
    ) {
        let heardKey = Self.key(candidate.heard)
        let variantIndex: Int
        if let existing = items[itemIndex].variants.firstIndex(where: { Self.key($0.heard) == heardKey }) {
            variantIndex = existing
        } else {
            if items[itemIndex].variants.count >= Self.maxVariants {
                // Make room by dropping the least recently seen variant that is not a rule.
                if let oldest = items[itemIndex].variants.indices
                    .filter({ !items[itemIndex].variants[$0].isRule })
                    .min(by: { (items[itemIndex].variants[$0].sightings.last ?? .distantPast) < (items[itemIndex].variants[$1].sightings.last ?? .distantPast) }) {
                    items[itemIndex].variants.remove(at: oldest)
                } else {
                    return
                }
            }
            items[itemIndex].variants.append(HeardVariant(heard: candidate.heard))
            variantIndex = items[itemIndex].variants.count - 1
        }
        var variant = items[itemIndex].variants[variantIndex]
        variant.sightings = Array((variant.sightings + sightingDates).sorted().suffix(Self.maxSightings))
        if wasKeyterm { variant.keytermSightings += 1 }
        variant.ruleLaterEligible = variant.ruleLaterEligible || candidate.ruleNow || candidate.ruleLater
        let term = items[itemIndex].text
        if !variant.isRule, !isTombstoned(heard: variant.heard, term: term) {
            let ruleNow = candidate.ruleNow && candidate.strength == .strong && observation.settled
            let recentSightings = variant.sightings.filter { now.timeIntervalSince($0) <= Self.evidenceWindow }.count
            let ruleLater = variant.ruleLaterEligible
                && recentSightings >= Self.ruleLaterSightings
                && variant.keytermSightings >= Self.ruleLaterKeytermSightings
                && variant.keptUnchanged == 0
            if ruleNow || ruleLater {
                variant.isRule = true
                change.addedRules.append(RuleRef(itemID: items[itemIndex].id, variantID: variant.id))
                change.learnedRules.append(RulePair(heard: variant.heard, term: term))
                count("ruleCreated")
            }
        }
        items[itemIndex].variants[variantIndex] = variant
    }

    /// Counts a hit for every learned term the raw transcript contains as whole words: the
    /// recognizer got it right. True when anything changed.
    mutating func recordHits(inRawTranscript rawTranscript: String, now: Date) -> Bool {
        recordHits(itemIDs: hitItemIDs(inRawTranscript: rawTranscript), now: now)
    }

    /// The ids of the learned terms the raw transcript contains as whole words. It does not
    /// change the store, so a dictation scans a copy off the main thread.
    func hitItemIDs(inRawTranscript rawTranscript: String) -> Set<UUID> {
        guard !items.isEmpty, !rawTranscript.isEmpty else { return [] }
        return Set(WordBoundedText(rawTranscript).matches(ofPhrases: items.map(\.text)).map { items[$0.phraseIndex].id })
    }

    /// Counts a hit for each of `ids` still in the store. True when anything changed.
    mutating func recordHits(itemIDs ids: Set<UUID>, now: Date) -> Bool {
        var changed = false
        for index in items.indices where ids.contains(items[index].id) {
            items[index].hits += 1
            items[index].lastUsed = now
            items[index].bumpScore(Self.hitWeight, now: now)
            changed = true
        }
        return changed
    }

    // MARK: Review and undo

    /// Removes what `change` added: its new terms (tombstoned with all their pairs) and its
    /// new rules on older terms (tombstoned pairs). Counts on older terms stay. The Run Log
    /// entries it counted are released, so a corrected Fix of the same dictation can count.
    mutating func undo(_ change: Change) {
        for id in change.addedItemIDs {
            if let index = items.firstIndex(where: { $0.id == id }) {
                tombstoneItem(items.remove(at: index))
            }
        }
        for rule in change.addedRules where !change.addedItemIDs.contains(rule.itemID) {
            removeRule(itemID: rule.itemID, variantID: rule.variantID)
        }
        let released = Set(change.countedEntryHashes)
        keepCountedEntries { !released.contains($0.entryHash) }
        count("undo")
    }

    /// Deletes a term and tombstones it and its pairs.
    @discardableResult
    mutating func removeItem(_ id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        tombstoneItem(items.remove(at: index))
        return true
    }

    /// Stops a learned rule and tombstones its pair; the term stays.
    @discardableResult
    mutating func removeRule(itemID: UUID, variantID: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              let variantIndex = items[index].variants.firstIndex(where: { $0.id == variantID }) else { return false }
        items[index].variants[variantIndex].isRule = false
        items[index].variants[variantIndex].ruleLaterEligible = false
        tombstone(Self.pairHash(heard: items[index].variants[variantIndex].heard, term: items[index].text))
        return true
    }

    mutating func setStarred(_ id: UUID, _ starred: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].starred = starred
    }

    /// Removes a term the user is moving to the manual list, without a tombstone.
    mutating func takeForManualEdit(_ id: UUID) -> Item? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// The manual corrections that keep a moved term's learned rules working: heard -> `term`
    /// for each rule, except a heard phrase that `existing` already corrects or that is `term`.
    static func manualRules(for item: Item, as term: String, existing: [DictionaryCorrection]) -> [DictionaryCorrection] {
        var froms = Set(existing.map(\.normalized).filter(\.isUsable).map { key($0.from) })
        froms.insert(key(term))
        return item.variants
            .filter { $0.isRule && froms.insert(key($0.heard)).inserted }
            .map { DictionaryCorrection(from: $0.heard, to: term).normalized }
            .filter(\.isUsable)
    }

    /// Removes a learned rule the user is moving to the manual corrections, without a
    /// tombstone, and returns it as a manual rule.
    mutating func takeRuleForManualEdit(itemID: UUID, variantID: UUID) -> DictionaryCorrection? {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              let variantIndex = items[index].variants.firstIndex(where: { $0.id == variantID && $0.isRule }) else { return nil }
        let variant = items[index].variants.remove(at: variantIndex)
        return DictionaryCorrection(from: variant.heard, to: items[index].text)
    }

    // MARK: Aging

    /// expireEvidence, then deletes terms unused for deleteAfter and enforces the caps (lowest
    /// score first). Starred terms are exempt. True when anything changed.
    mutating func prune(now: Date) -> Bool {
        let expired = expireEvidence(now: now)
        let before = self
        items.removeAll { !$0.starred && now.timeIntervalSince($0.lastActive) > Self.deleteAfter }
        capItems(now: now)
        return expired || self != before
    }

    /// Expires pending sightings after pendingLifetime (the oldest first past maxPending),
    /// revert dates and counted Run Log entries after evidenceWindow. It only deletes evidence
    /// and never learns, so it runs at launch even while learning is off. True when anything
    /// changed.
    mutating func expireEvidence(now: Date) -> Bool {
        let before = self
        pending.removeAll { now.timeIntervalSince($0.firstSeen) > Self.pendingLifetime }
        capPending()
        for index in items.indices {
            items[index].revertDates.removeAll { now.timeIntervalSince($0) > Self.evidenceWindow }
        }
        keepCountedEntries { now.timeIntervalSince($0.countedAt) <= Self.evidenceWindow }
        return self != before
    }

    /// Past maxPending, drops the least recently seen pending sightings.
    private mutating func capPending() {
        guard pending.count > Self.maxPending else { return }
        pending.sort { $0.lastSeen > $1.lastSeen }
        pending.removeLast(pending.count - Self.maxPending)
    }

    /// Past maxActiveItems, drops the lowest-ranked terms; starred terms and `kept` are exempt.
    private mutating func capItems(now: Date, keeping kept: Set<UUID> = []) {
        guard items.count > Self.maxActiveItems else { return }
        let droppable = items.filter { !$0.starred && !kept.contains($0.id) }
        let excess = min(items.count - Self.maxActiveItems, droppable.count)
        guard excess > 0 else { return }
        let dropped = Set(Self.ranked(droppable, category: nil, now: now).suffix(excess).map(\.id))
        items.removeAll { dropped.contains($0.id) }
    }

    /// No hit or correction for dormantAfter: still a spelling, no longer a keyterm. A starred
    /// term never ages.
    static func isDormant(_ item: Item, now: Date) -> Bool {
        isDormant(lastActive: item.lastActive, starred: item.starred, now: now)
    }

    static func isDormant(lastActive: Date, starred: Bool, now: Date) -> Bool {
        !starred && now.timeIntervalSince(lastActive) > dormantAfter
    }

    // MARK: Ranking and UI text

    /// Starred first, then the decayed score (×categoryBoost when the item's main category is
    /// `category`), then the most recently seen, then the text.
    func rankedItems(category: Category?, now: Date) -> [Item] {
        Self.ranked(items, category: category, now: now)
    }

    private static func ranked(_ items: [Item], category: Category?, now: Date) -> [Item] {
        // Each item's sort keys once, not per comparison: mainCategory sorts a dictionary and
        // the decayed score calls pow.
        let keys = items.map { item in
            (
                starred: item.starred,
                weight: item.decayedScore(at: now) * (category != nil && item.mainCategory == category ? categoryBoost : 1),
                lastSeen: item.lastSeen
            )
        }
        return items.indices.sorted { i, j in
            if keys[i].starred != keys[j].starred { return keys[i].starred }
            if keys[i].weight != keys[j].weight { return keys[i].weight > keys[j].weight }
            if keys[i].lastSeen != keys[j].lastSeen { return keys[i].lastSeen > keys[j].lastSeen }
            return items[i].text.localizedStandardCompare(items[j].text) == .orderedAscending
        }.map { items[$0] }
    }

    /// Every learned rule, by term then heard phrase. EffectiveVocabulary.listedRules marks
    /// the ones it does not apply.
    var ruleRows: [RuleRow] {
        items
            .flatMap { item in item.variants.filter(\.isRule).map { RuleRow(item: item, variant: $0) } }
            .sorted { a, b in
                let byTerm = a.item.text.localizedStandardCompare(b.item.text)
                if byTerm != .orderedSame { return byTerm == .orderedAscending }
                return a.variant.heard.localizedStandardCompare(b.variant.heard) == .orderedAscending
            }
    }

    /// Counts only, and as history: what fixes led to so far, not what the store holds now
    /// (the chips show that), e.g. "So far: learned 3 · not sure 1 · rewrites skipped 4 ·
    /// other skipped 2". Rewrites are the reasons the Fix result calls a rewrite.
    var activityLine: String {
        let learned = counters["learnedActive"] ?? 0
        let notSure = counters["pending"] ?? 0
        let rewrites = RunLogFix.rewriteReasons.reduce(0) { $0 + (counters["nothing:\($1.rawValue)"] ?? 0) }
        let other = counters.filter { $0.key.hasPrefix("nothing:") }.values.reduce(0, +) - rewrites
            + (counters["refused"] ?? 0)
        guard learned + notSure + rewrites + other > 0 else { return "Nothing learned yet" }
        var parts = ["learned \(learned)"]
        if notSure > 0 { parts.append("not sure \(notSure)") }
        if rewrites > 0 { parts.append("rewrites skipped \(rewrites)") }
        if other > 0 { parts.append("other skipped \(other)") }
        return "So far: " + parts.joined(separator: " · ")
    }

    /// "From Run Log · 3 fixes · used 12× · 2 d ago": sources and counts, never a sentence.
    static func tooltip(for item: Item, now: Date) -> String {
        var parts = ["From " + item.sources.map(\.displayName).joined(separator: ", ")]
        parts.append(item.corrections == 1 ? "1 fix" : "\(item.corrections) fixes")
        if item.hits > 0 { parts.append("used \(item.hits)×") }
        let days = Int(max(0, now.timeIntervalSince(item.lastActive)) / day)
        parts.append(days == 0 ? "today" : "\(days) d ago")
        if item.state == .ambiguous { parts.append("not sure") }
        return parts.joined(separator: " · ")
    }
}
