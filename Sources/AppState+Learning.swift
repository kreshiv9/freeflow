import Foundation
import os.log

private let learningLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Learning")

// MARK: - Learning loop

/// Run Log Fix, the learned store's review actions and the Undo offers. Logs carry outcome
/// codes and counts only, never a term or any text.
extension AppState {
    /// The manual vocabulary and corrections merged with learned items for a dictation into
    /// `category`. Main thread only: a background pipeline merges copies taken on main.
    func effectiveVocabulary(for category: DictationAppCategory?) -> EffectiveVocabulary {
        EffectiveVocabulary.merge(
            manualVocabulary: customVocabulary,
            manualCorrections: dictionaryCorrections,
            learned: learnedVocabulary,
            category: LearnedVocabulary.Category(category),
            now: Date()
        )
    }

    /// The learned keyterms for a dictation into `category`: all the dictation start needs.
    /// Nothing learned costs nothing; otherwise it reads the index ranked off main, and ranks
    /// here only when a dictation starts before a change has been ranked.
    func learnedKeyterms(for category: DictationAppCategory?) -> [String] {
        guard !learnedVocabulary.items.isEmpty else { return [] }
        let learnedCategory = LearnedVocabulary.Category(category)
        if let learnedKeytermIndex {
            return learnedKeytermIndex.keyterms(for: learnedCategory, now: Date())
        }
        return EffectiveVocabulary.learnedKeyterms(
            manualVocabulary: customVocabulary,
            manualCorrections: dictionaryCorrections,
            learned: learnedVocabulary,
            category: learnedCategory,
            now: Date()
        )
    }

    /// Ranks the learned keyterms of every category off main on copies taken here. Called on
    /// main when the learned store, Custom Vocabulary or Corrections change; a newer change
    /// discards an older ranking.
    func refreshLearnedKeytermIndex() {
        learnedKeytermIndexGeneration &+= 1
        learnedKeytermIndex = nil
        guard !learnedVocabulary.items.isEmpty else { return }
        let generation = learnedKeytermIndexGeneration
        let manualVocabulary = customVocabulary
        let manualCorrections = dictionaryCorrections
        let learned = learnedVocabulary
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let index = EffectiveVocabulary.LearnedKeytermIndex(
                manualVocabulary: manualVocabulary,
                manualCorrections: manualCorrections,
                learned: learned,
                now: Date()
            )
            DispatchQueue.main.async {
                guard let self, self.learnedKeytermIndexGeneration == generation else { return }
                self.learnedKeytermIndex = index
            }
        }
    }

    /// Called on the main thread once a dictation's paste is scheduled. Keeps the Deepgram
    /// words and keyterms in memory for a later Fix, and counts hits of learned terms in the
    /// raw transcript: the scan runs off main on a copy of the store, and only the counts are
    /// applied on main, by item id. Nothing is stored or logged; nothing happens while
    /// learning is off.
    func recordLearningEvidence(
        entryID: UUID,
        evidence: (words: [DeepgramStreamingCore.RecognizedWord], keyterms: [String])?,
        rawTranscript: String
    ) {
        guard learningEnabled else { return }
        let now = Date()
        if let evidence, !evidence.words.isEmpty || !evidence.keyterms.isEmpty {
            dictationRecords.append(
                DictationRecord(id: entryID, createdAt: now, words: evidence.words, keyterms: evidence.keyterms),
                now: now
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + DictationRecordRing.lifetime + 1) { [weak self] in
                self?.dictationRecords.removeExpired(now: Date())
            }
        }
        guard !learnedVocabulary.items.isEmpty, !rawTranscript.isEmpty else { return }
        let snapshot = learnedVocabulary
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hitIDs = snapshot.hitItemIDs(inRawTranscript: rawTranscript)
            guard !hitIDs.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.learningEnabled else { return }
                var store = self.learnedVocabulary
                if store.recordHits(itemIDs: hitIDs, now: now) {
                    self.learnedVocabulary = store
                }
            }
        }
    }

    /// Saves the learned store LearnedVocabulary.saveDelay after the last change.
    func scheduleLearnedVocabularySave() {
        learnedSaveWorkItem?.cancel()
        let save = DispatchWorkItem { [weak self] in
            self?.saveLearnedVocabularyNow()
        }
        learnedSaveWorkItem = save
        DispatchQueue.main.asyncAfter(deadline: .now() + LearnedVocabulary.saveDelay, execute: save)
    }

    /// Saves the learned store at once: after the delay, on Delete all, and when the app quits
    /// with a save pending.
    func saveLearnedVocabularyNow() {
        learnedSaveWorkItem?.cancel()
        learnedSaveWorkItem = nil
        learnedVocabulary.save(to: .standard)
    }

    /// Run Log "Fix": learns from what the row pasted and what the user says it should have
    /// been. Returns the result line for the row, with what it learned so the line can follow
    /// a later Undo; the outcome is never stored.
    @MainActor
    func learnFromRunLogFix(item: PipelineHistoryItem, correctedText: String) async -> RunLogFix.Result {
        guard learningEnabled else { return RunLogFix.Result(text: RunLogFix.learningOffText) }
        guard let pasted = RunLogFix.pastedText(for: item) else { return RunLogFix.Result(text: RunLogFix.unchangedText) }
        let final = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty, final != pasted else { return RunLogFix.Result(text: RunLogFix.unchangedText) }

        let record = dictationRecords.record(id: item.id, now: Date())
        let confidences = record?.confidences() ?? [:]
        let manualTerms = EffectiveVocabulary.manualTermKeys(vocabulary: customVocabulary, corrections: dictionaryCorrections)
        let learnedTerms = learnedVocabulary.termKeys
        let learnedRules = learnedVocabulary.ruleKeys
        let tombstones = Set(learnedVocabulary.tombstones)
        let outcome: CorrectionLearner.Outcome? = await Task.detached(priority: .userInitiated) {
            // The word list loads once, here, off the main thread.
            guard let lexicon = LearningWordList.bundled else { return nil }
            return CorrectionLearner.learn(
                pasted: pasted,
                final: final,
                lexicon: lexicon,
                confidences: confidences,
                manualTerms: manualTerms,
                learnedTerms: learnedTerms,
                learnedRules: learnedRules,
                isTombstoned: { tombstones.contains(LearnedVocabulary.termHash($0)) }
            )
        }.value
        guard let outcome else {
            os_log(.error, log: learningLog, "run log fix: word list missing")
            return RunLogFix.Result(text: RunLogFix.wordListMissingText)
        }
        // The switch may have been turned off while the learner ran.
        guard learningEnabled else { return RunLogFix.Result(text: RunLogFix.learningOffText) }

        let reason: CorrectionLearner.Reason?
        if case .nothing(let nothingReason) = outcome { reason = nothingReason } else { reason = nil }
        var store = learnedVocabulary
        guard let change = RunLogFix.apply(
            outcome,
            entryID: item.id,
            observation: LearnedVocabulary.Observation(
                source: .runLog,
                category: LearnedVocabulary.Category(
                    TextContextCore.category(bundleIdentifier: item.contextBundleIdentifier, websiteDomain: nil)
                ),
                settled: true,
                sentKeyterms: record?.keyterms ?? [],
                pasted: pasted,
                final: final
            ),
            to: &store,
            now: Date()
        ) else {
            os_log(.info, log: learningLog, "run log fix: entry already counted")
            return RunLogFix.Result(text: reason.map { RunLogFix.resultText(for: nil, reason: $0) } ?? RunLogFix.alreadyCountedText)
        }
        learnedVocabulary = store
        os_log(
            .info, log: learningLog,
            "run log fix: %{public}@; %d new, %d rules, %d pending, evidence %d",
            change.code, change.addedItemIDs.count, change.addedRules.count, change.pendingAdded, record == nil ? 0 : 1
        )
        if change.hasLearned {
            offerLearnedUndo(change)
        }
        return RunLogFix.Result(text: RunLogFix.resultText(for: change, reason: reason), learned: change.hasLearned ? change : nil)
    }

    /// Shows "Learned: X · Undo" (merged with a toast of the last toastBatchSeconds) unless the
    /// overlay is in use (canShowLearnedToast), and offers Undo in the menu bar for
    /// undoMenuSeconds.
    @MainActor
    func offerLearnedUndo(_ change: LearnedVocabulary.Change) {
        let now = Date()
        let offered: LearnedVocabulary.Change
        if let startedAt = learnedToastBatchStartedAt, let last = lastLearnedChange,
           now.timeIntervalSince(startedAt) <= LearnedVocabulary.toastBatchSeconds {
            offered = last.merging(change)
        } else {
            offered = change
            learnedToastBatchStartedAt = now
        }
        lastLearnedChange = offered
        showsLearnedUndoInMenu = true
        learnedUndoMenuWorkItem?.cancel()
        let expiry = DispatchWorkItem { [weak self] in
            self?.showsLearnedUndoInMenu = false
            self?.learnedUndoMenuWorkItem = nil
        }
        learnedUndoMenuWorkItem = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + LearnedVocabulary.undoMenuSeconds, execute: expiry)
        if canShowLearnedToast {
            overlayManager.showLearned(offered.toastText)
        }
    }

    /// Removes the last learned batch and tombstones it, so the same fix is not learned again.
    /// The Run Log entries it counted are released for a corrected Fix.
    @MainActor
    func undoLastLearned() {
        guard let change = lastLearnedChange else { return }
        var store = learnedVocabulary
        store.undo(change)
        learnedVocabulary = store
        clearLearnedUndoOffer()
        overlayManager.dismissLearnedToast()
        os_log(.info, log: learningLog, "undo last learned: %d terms, %d rules", change.addedItemIDs.count, change.addedRules.count)
    }

    /// Removes every learned item, pending hash, tombstone and counter. The manual Custom
    /// Vocabulary and Corrections are not touched.
    @MainActor
    func deleteAllLearnedData() {
        learnedVocabulary = LearnedVocabulary()
        // Saving the empty store removes the stored key now, not after the save delay.
        saveLearnedVocabularyNow()
        dictationRecords = DictationRecordRing()
        clearLearnedUndoOffer()
        overlayManager.dismissLearnedToast()
        os_log(.info, log: learningLog, "deleted all learned data")
    }

    @MainActor
    func setLearnedItemStarred(_ id: UUID, _ starred: Bool) {
        learnedVocabulary.setStarred(id, starred)
    }

    @MainActor
    func removeLearnedItem(_ id: UUID) {
        learnedVocabulary.removeItem(id)
    }

    @MainActor
    func removeLearnedRule(itemID: UUID, variantID: UUID) {
        learnedVocabulary.removeRule(itemID: itemID, variantID: variantID)
    }

    /// Editing a learned term makes it manual: the edited text joins Custom Vocabulary, the
    /// term's learned rules become manual corrections to it, and the learned item goes away
    /// without a tombstone.
    @MainActor
    func moveLearnedItemToVocabulary(_ id: UUID, as text: String) {
        let entries = VocabularyDraftMerge.entries(text)
        guard !entries.isEmpty else { return }
        var store = learnedVocabulary
        guard let item = store.takeForManualEdit(id) else { return }
        let term = entries.first { LearnedVocabulary.key($0) == LearnedVocabulary.key(item.text) } ?? entries[0]
        let rules = LearnedVocabulary.manualRules(for: item, as: term, existing: dictionaryCorrections)
        customVocabulary = VocabularyDraftMerge.appending(entries, to: customVocabulary)
        if !rules.isEmpty {
            dictionaryCorrections += rules
        }
        learnedVocabulary = store
    }

    /// Editing a learned rule makes it a manual correction.
    @MainActor
    func moveLearnedRuleToCorrections(itemID: UUID, variantID: UUID) {
        var store = learnedVocabulary
        guard let rule = store.takeRuleForManualEdit(itemID: itemID, variantID: variantID) else { return }
        learnedVocabulary = store
        dictionaryCorrections.append(rule)
    }

    @MainActor
    private func clearLearnedUndoOffer() {
        lastLearnedChange = nil
        learnedToastBatchStartedAt = nil
        showsLearnedUndoInMenu = false
        learnedUndoMenuWorkItem?.cancel()
        learnedUndoMenuWorkItem = nil
    }
}
