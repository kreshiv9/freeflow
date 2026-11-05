import Foundation

/// A copy of what CorrectionLearner needs to know about the vocabulary.
struct LearnerKnowledge: Sendable {
    let manualTerms: Set<String>
    let learnedTerms: Set<String>
    let learnedRules: Set<String>
    let tombstones: Set<String>

    func isTombstoned(_ term: String) -> Bool {
        tombstones.contains(LearnedVocabulary.termHash(term))
    }

    func outcome(pasted: String, final: String, lexicon: LearningLexicon, confidences: [String: Double]) -> CorrectionLearner.Outcome {
        CorrectionLearner.learn(
            pasted: pasted,
            final: final,
            lexicon: lexicon,
            confidences: confidences,
            manualTerms: manualTerms,
            learnedTerms: learnedTerms,
            learnedRules: learnedRules,
            isTombstoned: isTombstoned
        )
    }
}

/// What the streaming provider reported for one dictation: its final words with confidence and
/// the keyterms the stream used; and the paste, when a sent-text source can observe it. In memory
/// only, for the learning loop; never stored or logged.
struct DictationRecord: Equatable {
    /// The Run Log entry's id.
    let id: UUID
    let createdAt: Date
    let words: [DeepgramStreamingCore.RecognizedWord]
    let keyterms: [String]
    var paste: LearningPaste? = nil

    /// The lowest confidence of each lowercased word. Words of a sent keyterm are left out,
    /// because keyterms inflate confidence.
    func confidences() -> [String: Double] {
        let keytermWords = Set(keyterms.flatMap { $0.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) })
        var result: [String: Double] = [:]
        for word in words {
            let key = word.word.lowercased()
            guard !key.isEmpty, !keytermWords.contains(key) else { continue }
            result[key] = min(result[key] ?? word.confidence, word.confidence)
        }
        return result
    }
}

/// The last `capacity` dictation records, each kept for `lifetime`.
struct DictationRecordRing: Equatable {
    static let capacity = 8
    static let lifetime: TimeInterval = 600

    private(set) var records: [DictationRecord] = []

    mutating func append(_ record: DictationRecord, now: Date) {
        removeExpired(now: now)
        records.removeAll { $0.id == record.id }
        records.append(record)
        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }
    }

    mutating func removeExpired(now: Date) {
        records.removeAll { now.timeIntervalSince($0.createdAt) >= Self.lifetime }
    }

    func record(id: UUID, now: Date) -> DictationRecord? {
        records.last { $0.id == id && now.timeIntervalSince($0.createdAt) < Self.lifetime }
    }

    /// Marks a paste as seen by a source, so no later prompt or title learns from it again.
    /// False when it is gone or was already observed.
    mutating func markObserved(id: UUID) -> Bool {
        guard let index = records.lastIndex(where: { $0.id == id }), records[index].paste?.observed == false else { return false }
        records[index].paste?.observed = true
        return true
    }

    /// Forgets a paste no source can still observe; the record keeps its words and keyterms.
    mutating func clearPaste(id: UUID) {
        guard let index = records.lastIndex(where: { $0.id == id }) else { return }
        records[index].paste = nil
    }

    /// The live records whose paste no source has observed yet, oldest first.
    func unobservedPastes(now: Date) -> [DictationRecord] {
        records.filter { record in
            now.timeIntervalSince(record.createdAt) < Self.lifetime && record.paste?.observed == false
        }
    }

    /// A dispatched paste joins its dictation's record, or a new one when the stream left no
    /// evidence. A paste that was skipped never gets here.
    mutating func attachPaste(_ paste: LearningPaste, id: UUID, now: Date) {
        if let index = records.lastIndex(where: { $0.id == id }) {
            records[index].paste = paste
        } else {
            append(DictationRecord(id: id, createdAt: now, words: [], keyterms: [], paste: paste), now: now)
        }
    }

    /// The unobserved pastes into `destination`, oldest first, for SentTextMatcher.
    func pastes(into destination: LearningPaste.Destination, now: Date) -> [(id: UUID, pasted: String)] {
        unobservedPastes(now: now).compactMap { record in
            guard let paste = record.paste, paste.destination == destination else { return nil }
            return (record.id, paste.pasted)
        }
    }

    /// Takes one prompt's match: credited pastes are marked observed before any further await,
    /// so a second frame cannot reuse them, and are returned to learn from. Superseded pastes
    /// were never sent, so they are forgotten and no later prompt can match them.
    mutating func claim(_ match: SentTextMatcher.Match, now: Date) -> [DictationRecord] {
        for id in match.superseded { clearPaste(id: id) }
        return match.credited.compactMap { id in
            guard markObserved(id: id) else { return nil }
            return record(id: id, now: now)
        }
    }
}

/// What FreeFlow pasted for a dictation a sent-text source can observe. In memory only, at most
/// as long as its DictationRecord; never stored or logged.
struct LearningPaste: Equatable {
    enum Destination: Equatable {
        case vsCode
        case chrome
    }

    /// The text as inserted.
    let pasted: String
    /// The transcript before cleanup.
    let raw: String
    let destination: Destination
    let category: LearnedVocabulary.Category
    /// FreeFlow pressed Enter itself after the paste.
    let pressedEnter: Bool
    /// The health check counts this paste: the Claude Code composer by its role and label, or
    /// any VS Code paste when the focused field was not classified.
    let countsForHookHealth: Bool
    var observed = false

    /// Nil for anything no source may learn from: an empty paste, another app (only VS Code and
    /// Chrome are observed at all), VS Code while no hook listener runs (nothing could use the
    /// text, so it is not kept), and text FreeFlow wrote itself, namely Edit Mode, voice macros,
    /// snippets, file tags and auto-applied transforms. `composerClassified` is false when no
    /// field was read: Context Awareness off, screenshot context, a capture that missed the stop
    /// deadline or an omission. Matching works without it, so the health check must too.
    static func eligible(
        inserted: String,
        raw: String,
        bundleIdentifier: String?,
        category: LearnedVocabulary.Category,
        composerTarget: ContextTarget?,
        composerClassified: Bool,
        listensForPrompts: Bool,
        pressedEnter: Bool,
        isCommandMode: Bool,
        isVoiceMacro: Bool,
        expandedSnippetCount: Int,
        taggedFileCount: Int,
        autoApplied: Bool
    ) -> LearningPaste? {
        guard !inserted.isEmpty, !isCommandMode, !isVoiceMacro, expandedSnippetCount == 0, taggedFileCount == 0, !autoApplied else {
            return nil
        }
        let destination: Destination
        if ContextTarget.isVSCode(bundleIdentifier: bundleIdentifier) {
            guard listensForPrompts else { return nil }
            destination = .vsCode
        } else if ContextTarget.isChrome(bundleIdentifier: bundleIdentifier) {
            destination = .chrome
        } else {
            return nil
        }
        return LearningPaste(
            pasted: inserted,
            raw: raw,
            destination: destination,
            category: category,
            pressedEnter: pressedEnter,
            countsForHookHealth: composerTarget == .claudeCodePanel || (destination == .vsCode && !composerClassified)
        )
    }
}

/// Decides whether a sent prompt holds a recent paste. Pure.
enum SentTextMatcher {
    static let minimumCoverage = 0.6

    /// What one prompt says about the recent pastes.
    struct Match: Equatable {
        /// The pastes the prompt holds, oldest first.
        var credited: [UUID] = []
        /// The pastes that resemble the prompt only through words a newer paste holds: text
        /// deleted and dictated again, which was never sent. Oldest first.
        var superseded: [UUID] = []
    }

    /// The share of the paste's words found in order in `final`. 0 for an empty side or one over
    /// CorrectionLearner.maxTokens, and when too few words are shared to reach minimumCoverage,
    /// which skips the alignment for an unrelated prompt.
    static func coverage(of pasted: String, in final: String) -> Double {
        alignment(of: folds(pasted), in: folds(final)).coverage
    }

    /// Newest first, each credited paste takes the words of `final` it aligned to, so an older
    /// paste is tested only against what is left: two pastes in one prompt both match, and a
    /// re-dictation does not credit the take it replaced (both sides come from speech
    /// recognition, so that pair teaches nothing). Pastes of the same words are credited once
    /// per prompt, the newest (`pastes` is oldest first).
    static func matches(_ final: String, in pastes: [(id: UUID, pasted: String)]) -> Match {
        let finalWords = folds(final)
        var remaining = finalWords
        var seen = Set<String>()
        var match = Match()
        for paste in pastes.reversed() {
            let words = folds(paste.pasted)
            let found = alignment(of: words, in: remaining)
            if seen.insert(words.joined(separator: " ")).inserted, found.coverage >= minimumCoverage {
                match.credited.insert(paste.id, at: 0)
                let taken = Set(found.aligned)
                remaining = remaining.enumerated().filter { !taken.contains($0.offset) }.map(\.element)
            } else if alignment(of: words, in: finalWords).coverage >= minimumCoverage {
                match.superseded.insert(paste.id, at: 0)
            }
        }
        return match
    }

    private static func folds(_ text: String) -> [String] {
        CorrectionLearner.tokens(text).map(\.fold)
    }

    /// `aligned` holds the indices of the final words matched, as late as they can be: a newer
    /// paste usually sits later in the prompt, so an older one keeps the earlier words.
    private static func alignment(of pastedWords: [String], in finalWords: [String]) -> (coverage: Double, aligned: [Int]) {
        guard !pastedWords.isEmpty, !finalWords.isEmpty,
              pastedWords.count <= CorrectionLearner.maxTokens, finalWords.count <= CorrectionLearner.maxTokens else { return (0, []) }
        var available: [String: Int] = [:]
        for word in finalWords { available[word, default: 0] += 1 }
        var shared = 0
        for word in pastedWords where available[word, default: 0] > 0 {
            available[word, default: 0] -= 1
            shared += 1
        }
        guard Double(shared) / Double(pastedWords.count) >= minimumCoverage else { return (0, []) }
        let aligned = CorrectionLearner.script(pastedWords, finalWords, tieBreak: .latest).compactMap { step -> Int? in
            if case .equal(_, let index) = step { return index }
            return nil
        }
        return (Double(aligned.count) / Double(pastedWords.count), aligned)
    }
}

/// A change cleanup made from raw R to pasted P that the sent text F kept: evidence that the
/// recognizer keeps mishearing a term, with no edit from the user. Pure.
enum CleanupFixSignal {
    /// R -> P judged hunk by hunk (normal filler removal would fail the whole-edit gates). Keeps
    /// a candidate that is not a revert, not the work of a learned rule, not a weak case-only
    /// change (ordinary capitalization), and whose term is still in `final`.
    static func keptFixes(
        raw: String,
        pasted: String,
        final: String,
        lexicon: LearningLexicon,
        confidences: [String: Double],
        manualTerms: Set<String>,
        learnedTerms: Set<String>,
        learnedRules: Set<String>,
        isTombstoned: @escaping (String) -> Bool
    ) -> [CorrectionLearner.Candidate] {
        guard raw != pasted else { return [] }
        guard case .learned(let candidates) = CorrectionLearner.learn(
            pasted: raw,
            final: pasted,
            lexicon: lexicon,
            confidences: confidences,
            manualTerms: manualTerms,
            learnedTerms: learnedTerms,
            learnedRules: learnedRules,
            isTombstoned: isTombstoned,
            appliesEditGates: false
        ) else { return [] }
        let finalPhrases = LearnedVocabulary.phraseKeys(final, maxWords: CorrectionLearner.maxSideWords)
        return candidates.filter { candidate in
            guard !candidate.isRevert,
                  !learnedRules.contains(CorrectionLearner.ruleKey(heard: candidate.heard, term: candidate.term)),
                  finalPhrases.contains(LearnedVocabulary.key(candidate.term)) else { return false }
            return !(candidate.strength == .weak && candidate.heard.lowercased() == candidate.term.lowercased())
        }
    }
}

/// What one sighting of sent text teaches, apart from the app's glue: `judge` runs the learner
/// off main on copies, `apply` writes the store on main, and the glue only dispatches. Pure.
/// Text stays in memory; only derived terms reach the store.
enum SentTextLearning {
    enum Sighting: Equatable, Sendable {
        /// The prompt the Claude Code hook reported.
        case hookPrompt
        /// Signal A: the first results title of a paste the user could still edit.
        case firstResults
        /// The first results title when FreeFlow itself pressed Enter: it proves the send but
        /// shows no edit, so only kept cleanup fixes count.
        case firstResultsAfterEnter
        /// Signal B: one results title to the next.
        case nextResults(previous: String)
    }

    struct Verdict: Equatable, Sendable {
        let sighting: Sighting
        let category: LearnedVocabulary.Category
        /// Both sides as compared: normalized queries for a search.
        let compared: String
        let observed: String
        let outcome: CorrectionLearner.Outcome
        let fixes: [CorrectionLearner.Candidate]
    }

    /// The paste (or for Signal B the previous query) against `final`, plus the cleanup fixes
    /// `final` kept. A search compares normalized queries and never learns from case alone, and
    /// Signal B, which comes after the dictation's first observation, keeps no cleanup fix and
    /// only changes of words the paste held.
    static func judge(
        _ sighting: Sighting,
        paste: LearningPaste,
        final: String,
        knowledge: LearnerKnowledge,
        lexicon: LearningLexicon,
        confidences: [String: Double]
    ) -> Verdict {
        let isSearch = sighting != .hookPrompt
        var earlier = paste.pasted
        var restrictedTo: String?
        if case .nextResults(let previous) = sighting {
            earlier = previous
            restrictedTo = paste.pasted
        }
        let compared = isSearch ? GoogleSearchTitle.normalizedQuery(earlier) : earlier
        let observed = isSearch ? GoogleSearchTitle.normalizedQuery(final) : final
        let found = knowledge.outcome(pasted: compared, final: observed, lexicon: lexicon, confidences: confidences)
        let fixes = restrictedTo != nil ? [] : CleanupFixSignal.keptFixes(
            raw: paste.raw,
            pasted: paste.pasted,
            final: observed,
            lexicon: lexicon,
            confidences: confidences,
            manualTerms: knowledge.manualTerms,
            learnedTerms: knowledge.learnedTerms,
            learnedRules: knowledge.learnedRules,
            isTombstoned: knowledge.isTombstoned
        )
        return Verdict(
            sighting: sighting,
            category: isSearch ? .search : paste.category,
            compared: compared,
            observed: observed,
            outcome: isSearch ? GoogleSearchWatch.searchOutcome(found, restrictedTo: restrictedTo) : found,
            fixes: fixes
        )
    }

    struct Applied: Equatable {
        var change = LearnedVocabulary.Change()
        /// What the source taught, without the cleanup fixes: a text-free code for logs.
        var code = ""
        /// `store` was written, so it needs saving.
        var touchedStore = false
        /// What a search's first results sent; it counts as kept once the watch ends.
        var keptSearch: GoogleSearchWatch.KeptSearch?
        /// Signal B changed words of the paste, so what the first results sent was not kept.
        var voidsKeptSearch = false
    }

    /// Applies a verdict to `store`. A prompt is what was finally sent, so a prompt that changed
    /// nothing counts as accepted at once. A search can still be fixed on the results page: its
    /// first results record nothing as kept until the watch ends with no Signal B change, and
    /// Signal B touches the store only when it learned something. One dictation is one
    /// observation, so RunLogFix.apply ignores an entry already counted.
    static func apply(
        _ verdict: Verdict,
        entryID: UUID,
        sentKeyterms: [String],
        to store: inout LearnedVocabulary,
        now: Date
    ) -> Applied {
        var applied = Applied()
        let unchanged = verdict.outcome == .nothing(.styleOrUnchanged)

        /// An empty `pasted` and `final` make the store skip its kept-unchanged count.
        func applySource(_ source: LearningSource, keptCheck: Bool) {
            let observation = LearnedVocabulary.Observation(
                source: source,
                category: verdict.category,
                settled: true,
                sentKeyterms: sentKeyterms,
                pasted: keptCheck ? verdict.compared : "",
                final: keptCheck ? verdict.observed : ""
            )
            if let change = RunLogFix.apply(verdict.outcome, entryID: entryID, observation: observation, to: &store, now: now) {
                applied.change = change
                applied.code = change.code
                applied.touchedStore = true
            } else {
                applied.code = "alreadyCounted"
            }
        }

        switch verdict.sighting {
        case .hookPrompt:
            if unchanged {
                store.recordAccepted(pasted: verdict.compared, final: verdict.observed, now: now)
                applied.code = "acceptedUnchanged"
                applied.touchedStore = true
            } else {
                applySource(.claudeCode, keptCheck: true)
            }
        case .firstResults, .firstResultsAfterEnter:
            applied.keptSearch = GoogleSearchWatch.KeptSearch(pasted: verdict.compared, query: verdict.observed, unchanged: unchanged)
            if verdict.sighting == .firstResultsAfterEnter || unchanged {
                applied.code = "heldForWatchEnd"
            } else {
                applySource(.googleSearch, keptCheck: false)
            }
        case .nextResults:
            guard case .learned = verdict.outcome else {
                applied.code = "noChange"
                return applied
            }
            applied.voidsKeptSearch = true
            applySource(.googleSearch, keptCheck: false)
        }

        if !verdict.fixes.isEmpty {
            applied.change = applied.change.merging(store.applyCleanupFixes(
                verdict.fixes,
                entryID: entryID,
                observation: LearnedVocabulary.Observation(
                    source: .cleanup, category: verdict.category, settled: true, sentKeyterms: sentKeyterms,
                    pasted: verdict.compared, final: verdict.observed
                ),
                now: now
            ))
            applied.touchedStore = true
        }
        return applied
    }

    /// A watch ended with no Signal B change: what its first results sent was kept.
    static func applyKept(_ kept: GoogleSearchWatch.KeptSearch, to store: inout LearnedVocabulary, now: Date) {
        if kept.unchanged {
            store.recordAccepted(pasted: kept.pasted, final: kept.query, now: now)
        } else {
            store.recordKept(pasted: kept.pasted, final: kept.query, now: now)
        }
    }

    /// Undo AI edit: nothing more is learned from that dictation, and its kept cleanup fix stops
    /// counting. True when the store changed. A term already learned stays; Undo and the chip's
    /// delete remove those.
    static func cancel(entryID: UUID, records: inout DictationRecordRing, store: inout LearnedVocabulary) -> Bool {
        records.clearPaste(id: entryID)
        return store.cancelCleanupCredit(entryID: entryID)
    }
}

/// The Run Log's "Fix" action: the user types what they meant and the learner compares it with
/// what FreeFlow pasted. The outcome is shown, never stored.
enum RunLogFix {
    /// What a dictation row pasted: the cleaned text, or the raw text when cleanup produced
    /// none. Nil for Edit Mode and transform rows and for rows without text.
    static func pastedText(for item: PipelineHistoryItem) -> String? {
        guard item.intent == .dictation else { return nil }
        let cleaned = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return cleaned }
        let raw = item.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    static let learningOffText = "Learning is off. Turn on Learn automatically in Settings."
    static let unchangedText = "Nothing to learn: the text is unchanged."
    static let wordListMissingText = "Not learned: the word list is missing from this build."
    static let pendingText = "Not sure yet. One more fix like this will teach it."
    static let alreadyCountedText = "Already counted: FreeFlow learns from each dictation once."
    static let noLongerLearnedText = "No longer learned: undone, deleted or edited since."
    static let rewriteText = "Not learned: this looks like a rewrite, not a misheard word."

    /// The reasons the result line calls a rewrite; the activity line counts the same ones.
    static let rewriteReasons: Set<CorrectionLearner.Reason> = [
        .rewrite, .rewording, .notThisDictation, .hunkTooLong, .contentEdit,
    ]

    /// What a Fix shows under its editor: the result line, and the change when it learned
    /// something, so the line can follow a later Undo or delete.
    struct Result {
        let text: String
        var learned: LearnedVocabulary.Change?
    }

    /// Applies a Fix's outcome to `store` unless a Fix of the same Run Log entry already
    /// counted a sighting within the evidence window (the store keeps a hash of the entry id,
    /// so this holds across relaunches): one dictation is one observation however often it is
    /// fixed, so repeating a Fix never activates a pending term or makes a rule. Nil when
    /// nothing was applied. A Fix that counted nothing can be retried. Undo of what a Fix
    /// learned releases its entry only when Undo takes back every sighting the Fix counted
    /// (new terms, their rules and pending sightings): a sighting of a term already in the
    /// store, or a revert, stays, so that entry stays counted. The sent-text sources apply their
    /// outcomes here too, so they and a later Fix share the same one observation.
    static func apply(
        _ outcome: CorrectionLearner.Outcome,
        entryID: UUID,
        observation: LearnedVocabulary.Observation,
        to store: inout LearnedVocabulary,
        now: Date
    ) -> LearnedVocabulary.Change? {
        guard !store.hasCounted(entryID: entryID, now: now) else { return nil }
        var change = store.apply(outcome, from: observation, now: now)
        if change.countedSighting {
            let entryHash = store.markCounted(entryID: entryID, now: now)
            if change.updatedTerms.isEmpty, change.reverts == 0 {
                change.countedEntryHashes = [entryHash]
            }
        }
        return change
    }

    /// Whether anything `change` learned is still in the store: one of its new terms, or one
    /// of its new rules still on.
    static func isStillLearned(_ change: LearnedVocabulary.Change, in store: LearnedVocabulary) -> Bool {
        change.addedItemIDs.contains { id in store.items.contains { $0.id == id } }
            || change.addedRules.contains { rule in
                store.items.first { $0.id == rule.itemID }?.variants.contains { $0.id == rule.variantID && $0.isRule } ?? false
            }
    }

    /// The result line under the Fix editor. A pending sighting never names its term.
    static func resultText(for change: LearnedVocabulary.Change?, reason: CorrectionLearner.Reason?) -> String {
        if let change {
            if change.hasLearned { return change.toastText }
            if change.pendingAdded > 0 { return pendingText }
            if let term = change.updatedTerms.first { return "Already learned: \(term). Counted this fix too." }
            if change.reverts > 0 { return "Noted: you changed a learned word back." }
        }
        if let reason, rewriteReasons.contains(reason) { return rewriteText }
        switch reason {
        case .tombstoned:
            return "Not learned: you removed this before."
        case .alreadyKnownTerm:
            return "Not learned: already in your vocabulary."
        case .protectedTerm:
            return "Not learned: the word you changed is in your vocabulary, so FreeFlow keeps it."
        case .unchanged, .styleOnly, .shortCase, .styleOrUnchanged, .sentenceGlue, .dottedShorthand:
            return "Nothing to learn: only punctuation or capitalization changed."
        case .tooLong:
            return "Not learned: the text is too long to compare."
        case .secret, .address, .number:
            return "Not learned: addresses, numbers and keys are never learned."
        default:
            return "Not learned: this does not look like a misheard word or name."
        }
    }
}
