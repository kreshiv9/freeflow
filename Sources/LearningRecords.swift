import Foundation

/// What Deepgram reported for one dictation: its final words with confidence and the
/// keyterms the stream used. In memory only, for the learning loop; never stored or logged.
struct DictationRecord: Equatable {
    /// The Run Log entry's id.
    let id: UUID
    let createdAt: Date
    let words: [DeepgramStreamingCore.RecognizedWord]
    let keyterms: [String]

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
    /// store, or a revert, stays, so that entry stays counted.
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
