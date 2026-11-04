import Foundation

/// The learned store, EffectiveVocabulary, the in-memory Deepgram records, Run Log Fix text and
/// the Learn automatically preference. Invented terms, injected dates and throwaway
/// UserDefaults suites only; no AppState.
enum LearnedVocabularyTests {
    private typealias Store = LearnedVocabulary
    private typealias Candidate = CorrectionLearner.Candidate

    static func run() {
        testSameStrongPairTwiceIsOneItem()
        testRuleLaterNeedsKeytermFailureAndNoKeptOccurrence()
        testWeakCandidatePendsAsHashAndExpires()
        testDeletedTermIsTombstoned()
        testRevertsMakeAmbiguousAndDeleteRules()
        testFrecencyDecays()
        testPlannerKeepsManualFirstAndCapsLearnedSlice()
        // ST8 (a hook prompt with markers gives the same verdict) needs the Claude Code
        // hook-prompt normalizer, which comes with the hook source in a later change.
        testUndoRemovesAndTombstones()
        testDeleteAllLeavesManualListsIntact()
        testSearchOnlyCasingScopesRules()
        testEditedItemMovesToManual()
        testRuleNowAppliesAsCorrection()
        testPendingActivatesOnSecondSighting()
        testAgingDormantThenDeleted()
        testCaps()
        testHitsUpdateUseAndScore()
        testIdentifierTermsOnlyInCoding()
        testManualWins()
        testUnstorableTermsAreRefused()
        testPersistence()
        testStoreHoldsNoSentences()
        testChangeTextAndMerging()
        testActivityLineAndTooltip()
        testLearningPreference()
        testDictationRecords()
        testRunLogFixText()
        testRunLogFixCountsOneSightingPerEntry()
        testUndoReleasesRunLogEntry()
        testUndoThenSameFixIsNotRelearned()
        testLearnedRuleRevertEndToEnd()
        testManualVocabularyStopsLearnedRule()
        testExpiryRunsWhileLearningIsOff()
        testHitsByItemID()
        testKeptUnchangedPhrases()
        testLearnedKeytermsMatchMerge()
        testLearnedKeytermIndex()
        testListedRulesShowWhatIsNotApplied()
        testSaverWritesOnlyChanges()
        testStoreThisBuildCannotReadIsKept()
        testLaunchSaveRemovesUnstorableTerms()
    }

    // MARK: Fixtures

    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let day = Store.day

    private static func candidate(
        _ heard: String,
        _ term: String,
        strength: CorrectionLearner.Strength = .strong,
        ruleNow: Bool = false,
        ruleLater: Bool = false,
        isRevert: Bool = false
    ) -> Candidate {
        Candidate(heard: heard, term: term, strength: strength, ruleNow: ruleNow, ruleLater: ruleLater, isRevert: isRevert)
    }

    private static func observation(
        source: LearningSource = .runLog,
        category: Store.Category = .other,
        sentKeyterms: [String] = [],
        pasted: String = "",
        final: String = ""
    ) -> Store.Observation {
        Store.Observation(source: source, category: category, settled: true, sentKeyterms: sentKeyterms, pasted: pasted, final: final)
    }

    @discardableResult
    private static func learn(
        _ store: inout Store,
        _ candidates: [Candidate],
        source: LearningSource = .runLog,
        category: Store.Category = .other,
        sentKeyterms: [String] = [],
        pasted: String = "",
        final: String = "",
        at now: Date
    ) -> Store.Change {
        store.apply(
            .learned(candidates),
            from: observation(source: source, category: category, sentKeyterms: sentKeyterms, pasted: pasted, final: final),
            now: now
        )
    }

    private static func effective(
        _ store: Store,
        manual: String = "",
        corrections: [DictionaryCorrection] = [],
        category: Store.Category = .other,
        now: Date
    ) -> EffectiveVocabulary {
        EffectiveVocabulary.merge(manualVocabulary: manual, manualCorrections: corrections, learned: store, category: category, now: now)
    }

    private static func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "LearnedVocabularyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            TestSupport.expect(false, "a test defaults suite opens")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    /// EverydayWords plus a few invented-test words, no first names.
    private struct SmallLexicon: LearningLexicon {
        func isEveryday(_ lowercased: String) -> Bool { EverydayWords.contains(lowercased) }
        func isKnown(_ lowercased: String) -> Bool { lowercased == "parser" || EverydayWords.contains(lowercased) }
        func isFirstName(_ lowercased: String) -> Bool { false }
    }

    // MARK: Store tests (memo ST1-ST12)

    /// ST1
    private static func testSameStrongPairTwiceIsOneItem() {
        var store = Store()
        let first = learn(&store, [candidate("cloud", "Claude")], at: start)
        let second = learn(&store, [candidate("cloud", "Claude")], at: start + 60)
        TestSupport.expectEqual(store.items.count, 1)
        TestSupport.expectEqual(store.items[0].corrections, 2)
        TestSupport.expectEqual(store.items[0].variants.count, 1)
        TestSupport.expectEqual(store.items[0].variants[0].sightings.count, 2)
        TestSupport.expect(first.hasLearned && first.learnedTerms == ["Claude"], "the first sighting learns the term")
        TestSupport.expect(!second.hasLearned && second.updatedTerms == ["Claude"], "the second only counts")
        TestSupport.expectEqual(second.code, "seenAgain")
    }

    /// ST2
    private static func testRuleLaterNeedsKeytermFailureAndNoKeptOccurrence() {
        let grok = candidate("Grok", "Groq", ruleLater: true)
        var store = Store()
        learn(&store, [grok], at: start)
        TestSupport.expect(!store.items[0].variants[0].isRule, "one sighting is not enough")
        let promoted = learn(&store, [grok], sentKeyterms: ["Groq"], at: start + day)
        TestSupport.expect(store.items[0].variants[0].isRule, "a fix while Groq was a keyterm promotes the rule")
        TestSupport.expectEqual(promoted.learnedRules, [Store.RulePair(heard: "Grok", term: "Groq")])
        TestSupport.expectEqual(promoted.toastText, "Rule: Grok → Groq")
        TestSupport.expectEqual(
            DictionaryCorrection.apply(effective(store, now: start + day).corrections, to: "try Grok today"),
            "try Groq today"
        )

        // One observed final that kept "Grok" blocks this promotion and later ones.
        var blocked = Store()
        learn(&blocked, [grok], at: start)
        _ = blocked.apply(
            .nothing(.styleOrUnchanged),
            from: observation(pasted: "compare Grok with the others", final: "compare Grok with the others."),
            now: start + day
        )
        TestSupport.expectEqual(blocked.items[0].variants[0].keptUnchanged, 1)
        learn(&blocked, [grok], sentKeyterms: ["Groq"], at: start + 2 * day)
        learn(&blocked, [grok], sentKeyterms: ["Groq"], at: start + 3 * day)
        TestSupport.expect(!blocked.items[0].variants[0].isRule, "kept-unchanged evidence blocks the rule")
    }

    /// ST3
    private static func testWeakCandidatePendsAsHashAndExpires() {
        var store = Store()
        let change = learn(&store, [candidate("anthropic", "Anthropic", strength: .weak)], at: start)
        TestSupport.expect(store.items.isEmpty, "a weak candidate is not active")
        TestSupport.expectEqual(store.pending.count, 1)
        TestSupport.expectEqual(change.pendingAdded, 1)
        TestSupport.expectEqual(change.code, "pending")
        let hash = store.pending[0].pairHash
        TestSupport.expectEqual(hash.count, 64)
        TestSupport.expect(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "the pair is a lowercase SHA-256 hex digest")
        TestSupport.expectEqual(hash, Store.pairHash(heard: "anthropic", term: "Anthropic"))
        let json = (try? JSONEncoder().encode(store)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        TestSupport.expect(!json.isEmpty, "the store encodes")
        TestSupport.expect(!json.lowercased().contains("anthropic"), "pending sightings store no text")
        TestSupport.expect(store.prune(now: start + 31 * day), "the pending sighting expires")
        TestSupport.expect(store.pending.isEmpty, "nothing pending after 31 days")
    }

    /// ST4
    private static func testDeletedTermIsTombstoned() {
        var store = Store()
        learn(&store, [candidate("cloud", "Claude")], at: start)
        TestSupport.expect(store.removeItem(store.items[0].id), "the term is deleted")
        TestSupport.expect(store.items.isEmpty, "no items left")
        TestSupport.expect(store.isTombstoned(term: "claude"), "the term is tombstoned")
        TestSupport.expect(store.isTombstoned(heard: "cloud", term: "Claude"), "its pair is tombstoned")
        let tombstones = Set(store.tombstones)
        let outcome = CorrectionLearner.learn(
            pasted: "ask cloud to refactor the parser",
            final: "ask Claude to refactor the parser",
            lexicon: SmallLexicon(),
            learnedTerms: store.termKeys,
            isTombstoned: { tombstones.contains(Store.termHash($0)) }
        )
        TestSupport.expectEqual(outcome, .nothing(.tombstoned))
        // Applying it anyway is refused.
        let change = learn(&store, [candidate("cloud", "Claude")], at: start + day)
        TestSupport.expect(!change.hasLearned && store.items.isEmpty, "a tombstoned term is never re-learned")
    }

    /// ST5
    private static func testRevertsMakeAmbiguousAndDeleteRules() {
        var store = Store()
        learn(&store, [candidate("cloud", "Claude")], at: start)
        let revert = candidate("Claude", "cloud", strength: .weak, isRevert: true)
        learn(&store, [revert], at: start + day)
        TestSupport.expectEqual(store.items[0].state, .active)
        learn(&store, [revert], at: start + 5 * day)
        TestSupport.expectEqual(store.items[0].state, .ambiguous)
        let merged = effective(store, now: start + 6 * day)
        TestSupport.expect(!merged.learnedKeyterms.contains("Claude"), "an ambiguous term is not a keyterm")
        TestSupport.expect(VocabularyDraftMerge.entries(merged.vocabularyText).contains("Claude"), "it stays a spelling")

        // Two reverts more than 30 days apart do not.
        var spaced = Store()
        learn(&spaced, [candidate("cloud", "Claude")], at: start)
        learn(&spaced, [revert], at: start + day)
        learn(&spaced, [revert], at: start + 40 * day)
        TestSupport.expectEqual(spaced.items[0].state, .active)

        // One revert of a learned rule's output deletes the rule and tombstones the pair.
        var ruled = Store()
        learn(&ruled, [candidate("versel", "Vercel", ruleNow: true)], at: start)
        TestSupport.expect(ruled.items[0].variants[0].isRule, "versel -> Vercel is a rule at once")
        let change = learn(&ruled, [candidate("Vercel", "versel", strength: .weak, isRevert: true)], at: start + day)
        TestSupport.expectEqual(change.code, "revert")
        TestSupport.expect(!ruled.items[0].variants[0].isRule, "the rule is gone")
        TestSupport.expect(ruled.isTombstoned(heard: "versel", term: "Vercel"), "the pair is tombstoned")
        TestSupport.expectEqual(ruled.items[0].state, .active)
        TestSupport.expect(ruled.items[0].revertDates.isEmpty, "a rule revert is not ambiguity evidence")
        // A revert of a manual term (not learned) is ignored.
        var manual = Store()
        learn(&manual, [candidate("Grok", "grok", strength: .weak, isRevert: true)], at: start)
        TestSupport.expect(manual.items.isEmpty && manual.tombstones.isEmpty, "manual terms are not tracked")
    }

    /// ST6
    private static func testFrecencyDecays() {
        var store = Store()
        for offset in 0..<3 {
            learn(&store, [candidate("cloud", "Claude")], at: start - 60 * day + Double(offset))
        }
        learn(&store, [candidate("versel", "Vercel")], at: start - day)
        let now = start
        let old = store.items.first { $0.text == "Claude" }!
        let recent = store.items.first { $0.text == "Vercel" }!
        TestSupport.expectApproximatelyEqual(old.decayedScore(at: now), 2.25, accuracy: 0.001)
        TestSupport.expectApproximatelyEqual(recent.decayedScore(at: now), 3 * pow(0.5, 1.0 / 30.0), accuracy: 0.001)
        TestSupport.expectEqual(store.rankedItems(category: nil, now: now).map(\.text), ["Vercel", "Claude"])
        // Starred first, whatever the score.
        store.setStarred(old.id, true)
        TestSupport.expectEqual(store.rankedItems(category: nil, now: now).map(\.text), ["Claude", "Vercel"])
        // The category boost.
        var boosted = Store()
        learn(&boosted, [candidate("kwen", "Qwen")], category: .coding, at: start)
        learn(&boosted, [candidate("versel", "Vercel")], category: .aiChat, at: start + 1)
        TestSupport.expectEqual(boosted.rankedItems(category: .coding, now: start + 2).map(\.text), ["Qwen", "Vercel"])
        TestSupport.expectEqual(boosted.rankedItems(category: .aiChat, now: start + 2).map(\.text), ["Vercel", "Qwen"])
    }

    /// Invented letter-only terms: "Zqaa", "Zqab", …
    private static func inventedTerm(_ index: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return "Zq" + String(letters[index / 26 % 26]) + String(letters[index % 26])
    }

    /// ST7
    private static func testPlannerKeepsManualFirstAndCapsLearnedSlice() {
        var store = Store()
        for index in 0..<40 {
            learn(&store, [candidate("zk\(inventedTerm(index).lowercased())", inventedTerm(index))], at: start + Double(index))
        }
        learn(&store, [candidate("pendingheard", "Pendingterm", strength: .weak)], at: start + 100)
        TestSupport.expectEqual(store.items.count, 40)
        for (manualCount, slice) in [(10, 25), (30, 20), (45, 10)] {
            let manualTerms = (0..<manualCount).map { "manual term \($0)" }
            let merged = effective(store, manual: manualTerms.joined(separator: "\n"), now: start + day)
            TestSupport.expectEqual(merged.learnedKeyterms.count, 40)
            let connect = DeepgramStreamingCore.KeytermPlan.connectTerms(.init(
                vocabulary: DeepgramStreamingCore.keyterms(fromVocabularyText: manualTerms.joined(separator: "\n")),
                learned: merged.learnedKeyterms
            ))
            TestSupport.expectEqual(Array(connect.prefix(manualCount)), manualTerms)
            TestSupport.expectEqual(Array(connect.dropFirst(manualCount)), Array(merged.learnedKeyterms.prefix(slice)))
            TestSupport.expect(!connect.contains("Pendingterm"), "pending items are never sent")
            TestSupport.expect(!merged.vocabularyText.contains("Pendingterm"), "pending items are never spellings")
        }
    }

    /// ST9
    private static func testUndoRemovesAndTombstones() {
        var store = Store()
        learn(&store, [candidate("cloud", "Claude")], at: start)
        let change = learn(&store, [candidate("versel", "Vercel", ruleNow: true)], at: start + 1)
        TestSupport.expectEqual(change.addedRules.count, 1)
        store.undo(change)
        TestSupport.expectEqual(store.items.map(\.text), ["Claude"])
        TestSupport.expect(store.isTombstoned(term: "Vercel"), "the undone term is tombstoned")
        TestSupport.expect(store.isTombstoned(heard: "versel", term: "Vercel"), "the undone pair is tombstoned")
        TestSupport.expect(!store.isTombstoned(term: "Claude"), "earlier terms stay")

        // A rule added to an older term: undo removes the rule only.
        var older = Store()
        learn(&older, [candidate("Grok", "Groq", ruleLater: true)], at: start)
        let promoted = learn(&older, [candidate("Grok", "Groq", ruleLater: true)], sentKeyterms: ["Groq"], at: start + day)
        older.undo(promoted)
        TestSupport.expectEqual(older.items.count, 1)
        TestSupport.expect(!older.items[0].variants[0].isRule, "the rule is undone")
        TestSupport.expectEqual(older.items[0].corrections, 2)
        TestSupport.expect(older.isTombstoned(heard: "Grok", term: "Groq") && !older.isTombstoned(term: "Groq"), "only the pair is tombstoned")
    }

    /// ST10
    private static func testDeleteAllLeavesManualListsIntact() {
        withDefaults { defaults in
            defaults.set("Alpha, Beta", forKey: "custom_vocabulary")
            DictionaryCorrection.save([DictionaryCorrection(from: "versel", to: "Vercel")], to: defaults)
            let vocabularyBefore = defaults.string(forKey: "custom_vocabulary")
            let correctionsBefore = defaults.data(forKey: DictionaryCorrection.storageKey)

            var store = Store()
            learn(&store, [candidate("cloud", "Claude")], at: start)
            learn(&store, [candidate("anthropic", "Anthropic", strength: .weak)], at: start)
            store.save(to: defaults)
            TestSupport.expect(defaults.data(forKey: Store.storageKey) != nil, "the store is saved")

            Store.removeStored(from: defaults)
            Store().save(to: defaults)
            TestSupport.expect(defaults.object(forKey: Store.storageKey) == nil, "nothing learned is left")
            TestSupport.expectEqual(defaults.string(forKey: "custom_vocabulary"), vocabularyBefore)
            TestSupport.expectEqual(defaults.data(forKey: DictionaryCorrection.storageKey), correctionsBefore)
        }
    }

    /// ST11
    private static func testSearchOnlyCasingScopesRules() {
        var store = Store()
        learn(&store, [candidate("versel", "vercel", ruleNow: true)], source: .googleSearch, category: .search, at: start)
        TestSupport.expect(!store.items[0].casingKnown, "a search fix does not tell the casing")
        let inSearch = effective(store, category: .search, now: start)
        let inChat = effective(store, category: .aiChat, now: start)
        TestSupport.expectEqual(DictionaryCorrection.apply(inSearch.corrections, to: "versel pricing"), "vercel pricing")
        TestSupport.expectEqual(DictionaryCorrection.apply(inChat.corrections, to: "deploy to versel"), "deploy to versel")
        TestSupport.expect(inChat.learnedKeyterms.contains("vercel"), "it is still a keyterm")

        learn(&store, [candidate("versel", "Vercel", ruleNow: true)], at: start + day)
        TestSupport.expectEqual(store.items.count, 1)
        TestSupport.expectEqual(store.items[0].text, "Vercel")
        TestSupport.expect(store.items[0].casingKnown, "a prose fix tells the casing")
        TestSupport.expectEqual(
            DictionaryCorrection.apply(effective(store, category: .aiChat, now: start + day).corrections, to: "deploy to versel"),
            "deploy to Vercel"
        )
    }

    /// ST12
    private static func testEditedItemMovesToManual() {
        var store = Store()
        learn(&store, [candidate("cloud code", "Claude Code", ruleLater: true)], at: start)
        guard let item = store.takeForManualEdit(store.items[0].id) else {
            TestSupport.expect(false, "the item is taken")
            return
        }
        TestSupport.expect(store.items.isEmpty, "the learned item is gone")
        TestSupport.expect(store.tombstones.isEmpty, "a move is not a delete")
        let manual = VocabularyDraftMerge.appending([item.text], to: "Alpha")
        TestSupport.expectEqual(manual, "Alpha,\nClaude Code")
        let merged = effective(store, manual: manual, now: start)
        TestSupport.expectEqual(merged.vocabularyText, manual)
        TestSupport.expectEqual(VocabularyDraftMerge.entries(merged.vocabularyText).filter { $0 == "Claude Code" }.count, 1)

        // A learned rule moved to the manual corrections.
        var ruled = Store()
        learn(&ruled, [candidate("versel", "Vercel", ruleNow: true)], at: start)
        let row = ruled.ruleRows[0]
        guard let rule = ruled.takeRuleForManualEdit(itemID: row.item.id, variantID: row.variant.id) else {
            TestSupport.expect(false, "the rule is taken")
            return
        }
        TestSupport.expectEqual(rule.from, "versel")
        TestSupport.expectEqual(rule.to, "Vercel")
        TestSupport.expect(ruled.ruleRows.isEmpty && ruled.tombstones.isEmpty, "the rule moved without a tombstone")
        TestSupport.expectEqual(ruled.items.map(\.text), ["Vercel"])

        // A term moved with its rules: they become manual corrections and keep applying.
        var withRules = Store()
        learn(&withRules, [candidate("versel", "Vercel", ruleNow: true)], at: start)
        learn(&withRules, [candidate("vercell", "Vercel", ruleNow: true)], at: start + 1)
        learn(&withRules, [candidate("Vercell", "Vercel")], at: start + 2)
        TestSupport.expectEqual(withRules.ruleRows.count, 2)
        guard let moved = withRules.takeForManualEdit(withRules.items[0].id) else {
            TestSupport.expect(false, "the item with rules is taken")
            return
        }
        let existing = [DictionaryCorrection(from: "vercell", to: "Vercel Inc")]
        let migrated = Store.manualRules(for: moved, as: "Vercel", existing: existing)
        TestSupport.expectEqual(migrated.map(\.from), ["versel"])
        TestSupport.expectEqual(migrated.map(\.to), ["Vercel"])
        let corrections = existing + migrated
        let afterMove = effective(withRules, manual: "Vercel", corrections: corrections, now: start + day)
        TestSupport.expect(withRules.ruleRows.isEmpty, "no learned rule is left")
        TestSupport.expectEqual(DictionaryCorrection.apply(afterMove.corrections, to: "deploy to versel"), "deploy to Vercel")
        TestSupport.expectEqual(DictionaryCorrection.apply(afterMove.corrections, to: "deploy to vercell"), "deploy to Vercel Inc")
        // A rule whose heard phrase is the edited term itself is dropped.
        TestSupport.expect(Store.manualRules(for: moved, as: "versel", existing: []).map(\.from) == ["vercell"], "no rule rewrites the term to itself")
    }

    // MARK: More store behaviour

    private static func testRuleNowAppliesAsCorrection() {
        var store = Store()
        let change = learn(&store, [candidate("versel", "Vercel", ruleNow: true)], at: start)
        TestSupport.expectEqual(change.toastText, "Rule: versel → Vercel")
        let merged = effective(store, now: start)
        TestSupport.expectEqual(DictionaryCorrection.apply(merged.corrections, to: "deploy to versel"), "deploy to Vercel")
        TestSupport.expectEqual(merged.corrections.map(\.id), [store.items[0].variants[0].id])
        // A weak candidate never makes a rule at once, even on activation.
        var weak = Store()
        learn(&weak, [candidate("versel", "Vercel", strength: .weak, ruleNow: true)], at: start)
        learn(&weak, [candidate("versel", "Vercel", strength: .weak, ruleNow: true)], at: start + day)
        TestSupport.expectEqual(weak.items.count, 1)
        TestSupport.expect(!weak.items[0].variants[0].isRule, "weak candidates wait for evidence")
    }

    private static func testPendingActivatesOnSecondSighting() {
        let weak = candidate("anthropic", "Anthropic", strength: .weak)
        var store = Store()
        learn(&store, [weak], at: start)
        let change = learn(&store, [weak], at: start + 29 * day)
        TestSupport.expect(change.hasLearned, "the second sighting within 30 days activates it")
        TestSupport.expect(store.pending.isEmpty, "the pending hash is used up")
        TestSupport.expectEqual(store.items[0].variants[0].sightings, [start, start + 29 * day])
        TestSupport.expectEqual(store.items[0].corrections, 2)

        var late = Store()
        learn(&late, [weak], at: start)
        let lateChange = learn(&late, [weak], at: start + 31 * day)
        TestSupport.expect(!lateChange.hasLearned && late.items.isEmpty, "after 31 days it starts over")
        TestSupport.expectEqual(late.pending.count, 1)
        TestSupport.expectEqual(late.pending[0].firstSeen, start + 31 * day)

        // A weak sighting (a confident Grok, memo M3), then a strong one of the same pair: the
        // pending sighting counts, and its hash is used up.
        let confidentGrok = candidate("Grok", "Groq", strength: .weak, ruleLater: true)
        var weakThenStrong = Store()
        learn(&weakThenStrong, [confidentGrok], at: start)
        let strong = learn(&weakThenStrong, [candidate("Grok", "Groq", ruleLater: true)], at: start + day)
        TestSupport.expect(strong.hasLearned, "the strong sighting learns the term")
        TestSupport.expect(weakThenStrong.pending.isEmpty, "no pending hash is left behind")
        TestSupport.expectEqual(weakThenStrong.items[0].variants[0].sightings, [start, start + day])
        TestSupport.expectEqual(weakThenStrong.items[0].corrections, 2)
        // So the next fix while Groq was a keyterm is the rule-later evidence it needs.
        learn(&weakThenStrong, [candidate("Grok", "Groq", ruleLater: true)], sentKeyterms: ["Groq"], at: start + 2 * day)
        TestSupport.expectEqual(weakThenStrong.ruleRows.count, 1)

        // A pending pair whose term was learned meanwhile from another heard phrase.
        var otherHeard = Store()
        learn(&otherHeard, [candidate("vursel", "Vercel", strength: .weak)], at: start)
        learn(&otherHeard, [candidate("versel", "Vercel")], at: start + 1)
        TestSupport.expectEqual(otherHeard.pending.count, 1)
        learn(&otherHeard, [candidate("vursel", "Vercel")], at: start + 2)
        TestSupport.expect(otherHeard.pending.isEmpty, "the pending pair is used up by the learned term")
        let vursel = otherHeard.items[0].variants.first { $0.heard == "vursel" }
        TestSupport.expectEqual(vursel?.sightings, [start, start + 2])
        TestSupport.expectEqual(otherHeard.items[0].corrections, 3)
    }

    private static func testAgingDormantThenDeleted() {
        var store = Store()
        learn(&store, [candidate("kwen", "Qwen")], at: start)
        learn(&store, [candidate("versel", "Vercel")], at: start)
        store.setStarred(store.items[1].id, true)
        let dormant = effective(store, now: start + 91 * day)
        TestSupport.expect(!dormant.learnedKeyterms.contains("Qwen"), "a dormant term is no longer a keyterm")
        TestSupport.expectEqual(dormant.learnedKeyterms, ["Vercel"])
        TestSupport.expect(VocabularyDraftMerge.entries(dormant.vocabularyText).contains("Qwen"), "it is still a spelling")
        TestSupport.expect(store.prune(now: start + 181 * day), "an unused term is deleted after 180 days")
        TestSupport.expectEqual(store.items.map(\.text), ["Vercel"])
        TestSupport.expect(store.tombstones.isEmpty, "aging is not a tombstone")
    }

    private static func testCaps() {
        var store = Store()
        store.items = (0..<(Store.maxActiveItems + 5)).map { index in
            Store.Item(
                text: inventedTerm(index),
                casingKnown: true,
                sources: [.runLog],
                corrections: 1,
                firstSeen: start,
                lastSeen: start + Double(index),
                starred: index == 0,
                score: Double(index),
                scoreDate: start
            )
        }
        store.pending = (0..<(Store.maxPending + 5)).map { index in
            Store.Pending(pairHash: Store.pairHash(heard: "h\(index)", term: "t\(index)"), count: 1, firstSeen: start, lastSeen: start + Double(index))
        }
        TestSupport.expect(store.prune(now: start + day), "the caps prune")
        TestSupport.expectEqual(store.items.count, Store.maxActiveItems)
        TestSupport.expectEqual(store.pending.count, Store.maxPending)
        TestSupport.expect(store.items.contains { $0.text == inventedTerm(0) }, "a starred term is kept despite its score")
        TestSupport.expect(!store.items.contains { $0.text == inventedTerm(1) }, "the lowest scores go first")
        TestSupport.expect(!store.pending.contains { $0.lastSeen == start }, "the oldest pending go first")

        // A Fix into a store at both caps: the caps still hold after it, and what it learned
        // and the starred term are kept.
        let now = start + day
        let change = learn(&store, [
            candidate("zkone", "Zqnewone"),
            candidate("zktwo", "Zqnewtwo"),
            candidate("zkthree", "Zqnewthree"),
            candidate("zkfour", "Zqnewfour"),
        ], at: now)
        TestSupport.expectEqual(change.addedItemIDs.count, 4)
        TestSupport.expectEqual(store.items.count, Store.maxActiveItems)
        TestSupport.expect(change.addedItemIDs.allSatisfy { id in store.items.contains { $0.id == id } }, "the new terms are kept")
        TestSupport.expect(store.items.contains { $0.text == inventedTerm(0) }, "the starred term is kept")
        TestSupport.expect(!store.items.contains { $0.text == inventedTerm(6) }, "the lowest scores make room")
        TestSupport.expect(store.items.contains { $0.text == inventedTerm(10) }, "only as many as needed")
        learn(&store, [candidate("zkpending", "Zqpending", strength: .weak)], at: now)
        TestSupport.expectEqual(store.pending.count, Store.maxPending)
        TestSupport.expect(store.pending.contains { $0.pairHash == Store.pairHash(heard: "zkpending", term: "Zqpending") }, "the new pending sighting is kept")
    }

    private static func testHitsUpdateUseAndScore() {
        var store = Store()
        learn(&store, [candidate("cloud code", "Claude Code")], at: start)
        TestSupport.expect(!store.recordHits(inRawTranscript: "nothing relevant here", now: start + day), "no hit, no change")
        TestSupport.expect(store.recordHits(inRawTranscript: "open claude code settings", now: start + day), "a whole-word hit counts")
        TestSupport.expectEqual(store.items[0].hits, 1)
        TestSupport.expectEqual(store.items[0].lastUsed, start + day)
        TestSupport.expectApproximatelyEqual(store.items[0].decayedScore(at: start + day), 3 * pow(0.5, 1.0 / 30.0) + 1, accuracy: 0.001)
        TestSupport.expect(!store.recordHits(inRawTranscript: "claude codex", now: start + 2 * day), "a partial word is no hit")
        // A hit keeps a term from going dormant.
        TestSupport.expect(!Store.isDormant(store.items[0], now: start + 91 * day), "used 90 days ago, not dormant")
    }

    private static func testIdentifierTermsOnlyInCoding() {
        var store = Store()
        for (index, term) in ["useAuth.ts", "order_id", "userId", "GPT-4o", "JSON"].enumerated() {
            learn(&store, [candidate("heard\(inventedTerm(index).lowercased())", term)], at: start + Double(index))
        }
        let coding = Set(effective(store, category: .coding, now: start + day).learnedKeyterms)
        let chat = Set(effective(store, category: .aiChat, now: start + day).learnedKeyterms)
        TestSupport.expectEqual(coding, ["useAuth.ts", "order_id", "userId", "GPT-4o", "JSON"])
        TestSupport.expectEqual(chat, ["GPT-4o", "JSON"])
        TestSupport.expect(EffectiveVocabulary.isIdentifierShaped("useAuth.ts"), "a lowerCamel file name")
        TestSupport.expect(EffectiveVocabulary.isIdentifierShaped("main.swift"), "a lowercase file name")
        TestSupport.expect(!EffectiveVocabulary.isIdentifierShaped("GitHub"), "a brand name")
        TestSupport.expect(!EffectiveVocabulary.isIdentifierShaped("Claude Code"), "a phrase")
    }

    private static func testManualWins() {
        var store = Store()
        learn(&store, [candidate("versel", "Vercel", ruleNow: true)], at: start)
        learn(&store, [candidate("kwen", "Qwen", ruleNow: true)], at: start + 1)
        let manualRule = DictionaryCorrection(from: "kwen", to: "Qwen 3")
        let merged = effective(store, manual: "vercel, Alpha", corrections: [manualRule], now: start + day)
        TestSupport.expectEqual(merged.vocabularyText, "vercel, Alpha\nQwen")
        TestSupport.expect(!merged.learnedKeyterms.contains("Vercel"), "a manual term is not repeated as learned")
        TestSupport.expectEqual(DictionaryCorrection.apply(merged.corrections, to: "use kwen on versel"), "use Qwen 3 on Vercel")
        TestSupport.expectEqual(merged.corrections.first, manualRule)
        TestSupport.expectEqual(
            EffectiveVocabulary.manualTermKeys(vocabulary: "Claude Code,\n  next.js ;Alpha", corrections: [manualRule, DictionaryCorrection(from: "x", to: "")]),
            ["claude code", "next.js", "alpha", "qwen 3"]
        )
        // Nothing learned: the manual values pass through unchanged.
        let empty = effective(Store(), manual: "Alpha", corrections: [manualRule], now: start)
        TestSupport.expectEqual(empty, EffectiveVocabulary(vocabularyText: "Alpha", corrections: [manualRule], learnedKeyterms: []))
    }

    private static func testUnstorableTermsAreRefused() {
        var store = Store()
        let change = learn(&store, [
            candidate("key", "sk-ant-FAKE0example0000"),
            candidate("alpha", "Alpha, Beta"),
            candidate("gamma", "Gamma;Delta"),
            candidate("long", String(repeating: "Zq", count: 31)),
        ], at: start)
        TestSupport.expect(store.items.isEmpty && store.pending.isEmpty, "nothing unstorable is kept")
        TestSupport.expectEqual(change.refused, 4)
        TestSupport.expectEqual(change.code, "refused")
    }

    private static func testPersistence() {
        TestSupport.expectEqual(Store.storageKey, "learned_vocabulary_v1")
        withDefaults { defaults in
            TestSupport.expectEqual(Store.load(from: defaults), Store())
            var store = Store()
            learn(&store, [candidate("versel", "Vercel", ruleNow: true)], category: .coding, sentKeyterms: ["Vercel"], at: start)
            learn(&store, [candidate("anthropic", "Anthropic", strength: .weak)], at: start)
            _ = store.apply(.nothing(.rewrite), from: observation(), now: start)
            store.save(to: defaults)
            TestSupport.expectEqual(Store.load(from: defaults), store)
            defaults.set(Data("not json".utf8), forKey: Store.storageKey)
            TestSupport.expectEqual(Store.load(from: defaults), Store())
            defaults.set("a string", forKey: Store.storageKey)
            TestSupport.expectEqual(Store.load(from: defaults), Store())
        }
    }

    /// Only derived items are kept: no word of the sentences the fix came from.
    private static func testStoreHoldsNoSentences() {
        var store = Store()
        let pasted = "please ask cloud to refactor the zebrafish parser tomorrow"
        let final = "please ask Claude to refactor the zebrafish parser tomorrow"
        learn(&store, [candidate("cloud", "Claude")], pasted: pasted, final: final, at: start)
        _ = store.apply(.nothing(.rewrite), from: observation(pasted: pasted, final: final), now: start + 1)
        let json = (try? JSONEncoder().encode(store)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        for word in ["please", "refactor", "zebrafish", "parser", "tomorrow"] {
            TestSupport.expect(!json.contains(word), "the store must not contain \(word)")
        }
        TestSupport.expect(json.contains("Claude"), "the learned term is stored")
    }

    private static func testChangeTextAndMerging() {
        var store = Store()
        let first = learn(&store, [candidate("cloud", "Claude"), candidate("kwen", "Qwen")], at: start)
        TestSupport.expectEqual(first.toastText, "Learned: Claude, Qwen")
        TestSupport.expectEqual(first.menuTitle, "Claude +1")
        let second = learn(&store, [candidate("versel", "Vercel", ruleNow: true)], at: start + 5)
        TestSupport.expectEqual(second.menuTitle, "versel → Vercel")
        let merged = first.merging(second)
        TestSupport.expectEqual(merged.addedItemIDs.count, 3)
        TestSupport.expectEqual(merged.addedRules.count, 1)
        TestSupport.expectEqual(merged.toastText, "Learned: Claude, Qwen, Vercel")
        TestSupport.expectEqual(merged.code, "learned")
        store.undo(merged)
        TestSupport.expect(store.items.isEmpty, "Undo removes the whole batch")
    }

    private static func testActivityLineAndTooltip() {
        var store = Store()
        TestSupport.expectEqual(store.activityLine, "Nothing learned yet")
        learn(&store, [candidate("cloud", "Claude")], at: start)
        learn(&store, [candidate("kwen", "Qwen")], at: start)
        learn(&store, [candidate("anthropic", "Anthropic", strength: .weak)], at: start)
        _ = store.apply(.nothing(.rewrite), from: observation(), now: start)
        _ = store.apply(.nothing(.rewording), from: observation(), now: start)
        _ = store.apply(.nothing(.everydayBothSides), from: observation(), now: start)
        TestSupport.expectEqual(store.activityLine, "So far: learned 2 · not sure 1 · rewrites skipped 2 · other skipped 1")
        // Every outcome the Fix result calls a rewrite counts as one here too.
        for reason in [CorrectionLearner.Reason.notThisDictation, .hunkTooLong, .contentEdit] {
            _ = store.apply(.nothing(reason), from: observation(), now: start)
        }
        TestSupport.expectEqual(store.activityLine, "So far: learned 2 · not sure 1 · rewrites skipped 5 · other skipped 1")
        for reason in RunLogFix.rewriteReasons {
            TestSupport.expectEqual(RunLogFix.resultText(for: nil, reason: reason), RunLogFix.rewriteText)
        }
        for reason in [CorrectionLearner.Reason.everydayBothSides, .tombstoned, .styleOnly, .notSoundAlike] {
            TestSupport.expect(RunLogFix.resultText(for: nil, reason: reason) != RunLogFix.rewriteText, "\(reason.rawValue) is not a rewrite")
        }

        _ = store.recordHits(inRawTranscript: "Claude Claude", now: start + 2 * day)
        let claude = store.items.first { $0.text == "Claude" }!
        TestSupport.expectEqual(Store.tooltip(for: claude, now: start + 4 * day), "From Run Log · 1 fix · used 1× · 2 d ago")
        learn(&store, [candidate("cloud", "Claude")], source: .chatGPT, at: start + 4 * day)
        let twice = store.items.first { $0.text == "Claude" }!
        TestSupport.expectEqual(Store.tooltip(for: twice, now: start + 4 * day), "From ChatGPT, Run Log · 2 fixes · used 1× · today")
    }

    private static func testLearningPreference() {
        withDefaults { defaults in
            TestSupport.expect(LearningPreference.load(from: defaults), "learning defaults on")
            TestSupport.expect(defaults.object(forKey: LearningPreference.storageKey) == nil, "loading never persists the default")
            defaults.set("yes", forKey: LearningPreference.storageKey)
            TestSupport.expect(LearningPreference.load(from: defaults), "an invalid value keeps the default")
            defaults.set(false, forKey: LearningPreference.storageKey)
            TestSupport.expect(!LearningPreference.load(from: defaults), "off is respected")
        }
        TestSupport.expectEqual(LearningPreference.storageKey, "auto_learning_enabled")
        TestSupport.expectEqual(Set(LearningSource.allCases.map(\.rawValue)), ["runLog", "claudeCode", "chatGPT", "googleSearch", "cleanup"])
    }

    // MARK: Records and Run Log Fix

    private static func word(_ text: String, _ confidence: Double) -> DeepgramStreamingCore.RecognizedWord {
        DeepgramStreamingCore.RecognizedWord(word: text, punctuatedWord: text, confidence: confidence)
    }

    private static func testDictationRecords() {
        var ring = DictationRecordRing()
        var ids: [UUID] = []
        for index in 0..<10 {
            let id = UUID()
            ids.append(id)
            ring.append(DictationRecord(id: id, createdAt: start + Double(index), words: [], keyterms: []), now: start + Double(index))
        }
        TestSupport.expectEqual(ring.records.count, DictationRecordRing.capacity)
        TestSupport.expect(ring.record(id: ids[0], now: start + 10) == nil, "the oldest are dropped")
        TestSupport.expect(ring.record(id: ids[9], now: start + 10) != nil, "the newest are kept")
        TestSupport.expect(ring.record(id: ids[9], now: start + 9 + 599) != nil, "kept for ten minutes")
        TestSupport.expect(ring.record(id: ids[9], now: start + 9 + 600) == nil, "expired after ten minutes")
        ring.removeExpired(now: start + 9 + 601)
        TestSupport.expect(ring.records.isEmpty, "expired records are removed")

        let record = DictationRecord(
            id: UUID(),
            createdAt: start,
            words: [word("Kwen", 0.7), word("kwen", 0.4), word("claude", 0.99), word("code", 0.98), word("today", 0.9)],
            keyterms: ["Claude Code", "Vercel"]
        )
        TestSupport.expectEqual(record.confidences(), ["kwen": 0.4, "today": 0.9])
    }

    private static func historyItem(
        intent: PipelineHistoryItemIntent = .dictation,
        raw: String,
        cleaned: String,
        bundle: String? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            intent: intent,
            timestamp: start,
            rawTranscript: raw,
            postProcessedTranscript: cleaned,
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "",
            postProcessingStatus: "",
            debugStatus: "",
            customVocabulary: "",
            contextBundleIdentifier: bundle
        )
    }

    private static func testRunLogFixText() {
        TestSupport.expectEqual(RunLogFix.pastedText(for: historyItem(raw: "open cloud code", cleaned: "Open cloud code. ")), "Open cloud code.")
        TestSupport.expectEqual(RunLogFix.pastedText(for: historyItem(raw: "open cloud code", cleaned: "  ")), "open cloud code")
        TestSupport.expect(RunLogFix.pastedText(for: historyItem(raw: " ", cleaned: "")) == nil, "an empty row has nothing to fix")
        TestSupport.expect(RunLogFix.pastedText(for: historyItem(intent: .transform, raw: "a", cleaned: "b")) == nil, "transform rows are not dictations")
        TestSupport.expect(RunLogFix.pastedText(for: historyItem(intent: .commandManual, raw: "a", cleaned: "b")) == nil, "Edit Mode rows are not dictations")

        var store = Store()
        let learned = learn(&store, [candidate("cloud code", "Claude Code")], at: start)
        TestSupport.expectEqual(RunLogFix.resultText(for: learned, reason: nil), "Learned: Claude Code")
        let pending = learn(&store, [candidate("anthropic", "Anthropic", strength: .weak)], at: start)
        let pendingText = RunLogFix.resultText(for: pending, reason: nil)
        TestSupport.expectEqual(pendingText, "Not sure yet. One more fix like this will teach it.")
        TestSupport.expect(!pendingText.contains("Anthropic"), "a pending result never names the term")
        let nothing = store.apply(.nothing(.tombstoned), from: observation(), now: start)
        TestSupport.expectEqual(RunLogFix.resultText(for: nothing, reason: .tombstoned), "Not learned: you removed this before.")
        TestSupport.expectEqual(RunLogFix.resultText(for: nil, reason: .rewrite), "Not learned: this looks like a rewrite, not a misheard word.")
        TestSupport.expectEqual(RunLogFix.resultText(for: nil, reason: .alreadyKnownTerm), "Not learned: already in your vocabulary.")
        TestSupport.expectEqual(
            RunLogFix.resultText(for: nil, reason: .protectedTerm),
            "Not learned: the word you changed is in your vocabulary, so FreeFlow keeps it."
        )
        TestSupport.expectEqual(RunLogFix.resultText(for: nil, reason: .styleOnly), "Nothing to learn: only punctuation or capitalization changed.")
        let again = learn(&store, [candidate("cloud code", "Claude Code")], at: start + 1)
        TestSupport.expectEqual(RunLogFix.resultText(for: again, reason: nil), "Already learned: Claude Code. Counted this fix too.")
    }

    // MARK: Review fixes

    /// One dictation is one observation: repeating a Fix of the same Run Log entry never adds
    /// a second sighting, so it cannot activate a pending term or promote a rule, even after a
    /// relaunch (the store keeps a hash of the entry id).
    private static func testRunLogFixCountsOneSightingPerEntry() {
        let entry = UUID()
        var store = Store()
        let weak = CorrectionLearner.Outcome.learned([candidate("anthropic", "Anthropic", strength: .weak)])
        let first = RunLogFix.apply(weak, entryID: entry, observation: observation(), to: &store, now: start)
        TestSupport.expectEqual(first?.pendingAdded, 1)
        TestSupport.expectEqual(first?.countedEntryHashes, [Store.entryHash(entry)])
        let repeated = RunLogFix.apply(weak, entryID: entry, observation: observation(), to: &store, now: start + 60)
        TestSupport.expect(repeated == nil, "a repeated Fix of the same entry is not applied")
        TestSupport.expect(store.items.isEmpty, "the pending term stays pending")
        TestSupport.expectEqual(store.pending.count, 1)
        let otherEntry = RunLogFix.apply(weak, entryID: UUID(), observation: observation(), to: &store, now: start + 120)
        TestSupport.expect(otherEntry?.hasLearned == true, "another dictation is a second sighting")

        // Rule later: Groq was learned from another dictation and was a sent keyterm here.
        var rules = Store()
        learn(&rules, [candidate("Grok", "Groq", ruleLater: true)], at: start)
        let grok = CorrectionLearner.Outcome.learned([candidate("Grok", "Groq", ruleLater: true)])
        let keytermObservation = observation(sentKeyterms: ["Groq"])
        let applied = RunLogFix.apply(grok, entryID: UUID(), observation: keytermObservation, to: &rules, now: start + day)
        TestSupport.expect(applied?.learnedRules.count == 1, "two dictations with a keyterm sighting make the rule")
        var single = Store()
        let onlyEntry = UUID()
        for offset in 0..<3 {
            _ = RunLogFix.apply(grok, entryID: onlyEntry, observation: keytermObservation, to: &single, now: start + Double(offset))
        }
        TestSupport.expectEqual(single.items.count, 1)
        TestSupport.expect(single.ruleRows.isEmpty, "one dictation fixed three times makes no rule")
        TestSupport.expectEqual(single.items[0].corrections, 1)
        TestSupport.expectEqual(single.items[0].variants[0].sightings.count, 1)

        // A Fix that counted nothing (a rewrite) can be retried with other text.
        var retry = Store()
        let retryEntry = UUID()
        let rewrite = RunLogFix.apply(.nothing(.rewrite), entryID: retryEntry, observation: observation(), to: &retry, now: start)
        TestSupport.expect(rewrite != nil && retry.countedEntries == nil, "nothing counted, nothing remembered")
        let retried = RunLogFix.apply(.learned([candidate("cloud", "Claude")]), entryID: retryEntry, observation: observation(), to: &retry, now: start + 1)
        TestSupport.expect(retried?.hasLearned == true && retry.hasCounted(entryID: retryEntry, now: start + 1), "the retry counts once")

        // After a relaunch (save and load) the same entry still counts once.
        withDefaults { defaults in
            var saved = Store()
            let relaunchEntry = UUID()
            _ = RunLogFix.apply(weak, entryID: relaunchEntry, observation: observation(), to: &saved, now: start)
            saved.save(to: defaults)
            var relaunched = Store.load(from: defaults)
            TestSupport.expectEqual(relaunched, saved)
            let json = defaults.data(forKey: Store.storageKey).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            TestSupport.expect(!json.contains(relaunchEntry.uuidString), "the entry id is stored only as a hash")
            let again = RunLogFix.apply(weak, entryID: relaunchEntry, observation: observation(), to: &relaunched, now: start + day)
            TestSupport.expect(again == nil, "a Fix of the same entry after a relaunch is not applied")
            TestSupport.expect(relaunched.items.isEmpty && relaunched.pending.count == 1, "the term stays pending")
            // The guard lasts as long as the evidence it protects.
            TestSupport.expect(relaunched.expireEvidence(now: start + 31 * day), "counted entries expire")
            TestSupport.expect(relaunched.countedEntries == nil, "nothing is left of the counted entry")
        }

        // A store saved before counted entries existed still loads.
        withDefaults { defaults in
            var store = Store()
            learn(&store, [candidate("cloud", "Claude")], at: start)
            let data = (try? JSONEncoder().encode(store)) ?? Data()
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            object["countedEntries"] = nil
            defaults.set(try? JSONSerialization.data(withJSONObject: object), forKey: Store.storageKey)
            TestSupport.expectEqual(Store.load(from: defaults).items.map(\.text), ["Claude"])
        }
    }

    /// Undo of a mistaken Fix releases its Run Log entry, so a corrected Fix of the same
    /// dictation is learned.
    private static func testUndoReleasesRunLogEntry() {
        let entry = UUID()
        var store = Store()
        let mistaken = RunLogFix.apply(.learned([candidate("claud", "Claud")]), entryID: entry, observation: observation(), to: &store, now: start)
        guard let mistaken, mistaken.hasLearned else {
            TestSupport.expect(false, "the mistaken Fix learns")
            return
        }
        TestSupport.expect(store.hasCounted(entryID: entry, now: start), "the entry is counted")
        store.undo(mistaken)
        TestSupport.expect(!store.hasCounted(entryID: entry, now: start + 1), "Undo releases the entry")
        TestSupport.expect(store.isTombstoned(term: "Claud"), "the mistaken term is tombstoned")
        let corrected = RunLogFix.apply(.learned([candidate("claud", "Claude")]), entryID: entry, observation: observation(), to: &store, now: start + 2)
        TestSupport.expect(corrected?.hasLearned == true, "the corrected Fix of the same entry is learned")
        TestSupport.expectEqual(store.items.map(\.text), ["Claude"])

        // Undo also forgets the pending sightings the Fix added, so a corrected Fix of the same
        // entry counts the weak term once: it stays pending.
        var mixed = Store()
        let mixedEntry = UUID()
        let weakGroqq = candidate("grok", "Groqq", strength: .weak)
        guard let mixedFix = RunLogFix.apply(.learned([candidate("claud", "Claud"), weakGroqq]), entryID: mixedEntry, observation: observation(), to: &mixed, now: start),
              mixedFix.hasLearned, mixed.pending.count == 1 else {
            TestSupport.expect(false, "the mixed Fix learns one term and pends one")
            return
        }
        mixed.undo(mixedFix)
        TestSupport.expect(mixed.items.isEmpty && mixed.pending.isEmpty, "Undo removes the term and forgets the pending sighting")
        TestSupport.expect(!mixed.hasCounted(entryID: mixedEntry, now: start + 1), "and releases the entry")
        let mixedAgain = RunLogFix.apply(.learned([candidate("claud", "Claude"), weakGroqq]), entryID: mixedEntry, observation: observation(), to: &mixed, now: start + 2)
        TestSupport.expectEqual(mixedAgain?.learnedTerms, ["Claude"])
        TestSupport.expectEqual(mixed.items.map(\.text), ["Claude"])
        TestSupport.expectEqual(mixed.pending.count, 1)

        // A Fix that also counted a sighting of a term already learned keeps its entry counted
        // after Undo: Undo cannot take that sighting back, so fixing the same dictation again
        // would count it twice and could make a rule from one dictation.
        var older = Store()
        learn(&older, [candidate("Versal", "Vercel")], at: start)
        let olderEntry = UUID()
        let sightingAndTerm = CorrectionLearner.Outcome.learned([candidate("versel", "Vercel", ruleLater: true), candidate("claud", "Claud")])
        let keytermObservation = observation(sentKeyterms: ["Vercel"])
        guard let olderFix = RunLogFix.apply(sightingAndTerm, entryID: olderEntry, observation: keytermObservation, to: &older, now: start + day),
              olderFix.hasLearned, olderFix.updatedTerms == ["Vercel"], older.ruleRows.isEmpty else {
            TestSupport.expect(false, "the Fix learns Claud and counts a Vercel sighting without a rule")
            return
        }
        TestSupport.expect(olderFix.countedEntryHashes.isEmpty, "Undo will not release this entry")
        older.undo(olderFix)
        TestSupport.expect(older.hasCounted(entryID: olderEntry, now: start + day + 1), "the entry stays counted")
        let olderAgain = RunLogFix.apply(sightingAndTerm, entryID: olderEntry, observation: keytermObservation, to: &older, now: start + day + 2)
        TestSupport.expect(olderAgain == nil, "a second Fix of the same dictation is not applied")
        TestSupport.expect(older.ruleRows.isEmpty, "no rule from one dictation")
        TestSupport.expectEqual(older.items.first?.variants.first { Store.key($0.heard) == "versel" }?.sightings.count, 1)

        // A batched Undo releases every entry of the batch; other entries stay counted.
        var batch = Store()
        let (a, b, c) = (UUID(), UUID(), UUID())
        let first = RunLogFix.apply(.learned([candidate("kwen", "Qwen")]), entryID: a, observation: observation(), to: &batch, now: start)
        let second = RunLogFix.apply(.learned([candidate("versel", "Vercel")]), entryID: b, observation: observation(), to: &batch, now: start + 1)
        _ = RunLogFix.apply(.learned([candidate("anthropic", "Anthropic", strength: .weak)]), entryID: c, observation: observation(), to: &batch, now: start + 2)
        guard let first, let second else {
            TestSupport.expect(false, "both Fixes learn")
            return
        }
        batch.undo(first.merging(second))
        TestSupport.expect(!batch.hasCounted(entryID: a, now: start + 3) && !batch.hasCounted(entryID: b, now: start + 3), "the batch is released")
        TestSupport.expect(batch.hasCounted(entryID: c, now: start + 3), "an entry outside the batch stays counted")

        // The Fix result line follows the Undo.
        var shown = Store()
        guard let learned = RunLogFix.apply(.learned([candidate("cloud", "Claude")]), entryID: UUID(), observation: observation(), to: &shown, now: start) else {
            TestSupport.expect(false, "the Fix learns")
            return
        }
        TestSupport.expect(RunLogFix.isStillLearned(learned, in: shown), "just learned")
        shown.undo(learned)
        TestSupport.expect(!RunLogFix.isStillLearned(learned, in: shown), "undone")
        var ruled = Store()
        learn(&ruled, [candidate("Grok", "Groq", ruleLater: true)], at: start)
        let promoted = learn(&ruled, [candidate("Grok", "Groq", ruleLater: true)], sentKeyterms: ["Groq"], at: start + day)
        TestSupport.expect(RunLogFix.isStillLearned(promoted, in: ruled), "a new rule on an older term")
        ruled.removeRule(itemID: promoted.addedRules[0].itemID, variantID: promoted.addedRules[0].variantID)
        TestSupport.expect(!RunLogFix.isStillLearned(promoted, in: ruled), "the rule was deleted")
    }

    /// Memo manual checks 1 and 2 end to end: a Fix learns Claude Code, Undo tombstones it,
    /// and the same Fix (or one into manual vocabulary) learns no part of it.
    private static func testUndoThenSameFixIsNotRelearned() {
        let pasted = "open cloud code settings", final = "open Claude Code settings"
        func fix(_ store: Store, manual: Set<String> = []) -> CorrectionLearner.Outcome {
            let tombstones = Set(store.tombstones)
            return CorrectionLearner.learn(
                pasted: pasted,
                final: final,
                lexicon: SmallLexicon(),
                manualTerms: manual,
                learnedTerms: store.termKeys,
                learnedRules: store.ruleKeys,
                isTombstoned: { tombstones.contains(Store.termHash($0)) }
            )
        }
        var store = Store()
        let first = fix(store)
        guard case .learned(let candidates) = first else {
            TestSupport.expect(false, "the first Fix learns")
            return
        }
        TestSupport.expectEqual(candidates.map(\.term), ["Claude Code"])
        let change = store.apply(first, from: observation(pasted: pasted, final: final), now: start)
        TestSupport.expect(change.hasLearned, "Claude Code is learned")
        store.undo(change)
        TestSupport.expectEqual(fix(store), .nothing(.tombstoned))
        TestSupport.expectEqual(RunLogFix.resultText(for: nil, reason: .tombstoned), "Not learned: you removed this before.")

        var deleted = Store()
        _ = deleted.apply(fix(deleted), from: observation(pasted: pasted, final: final), now: start)
        deleted.removeItem(deleted.items[0].id)
        TestSupport.expectEqual(fix(deleted), .nothing(.tombstoned))

        TestSupport.expectEqual(fix(Store(), manual: ["claude code"]), .nothing(.alreadyKnownTerm))
    }

    /// A rule learned now (versel -> Vercel) is undone by one change back through the learner.
    private static func testLearnedRuleRevertEndToEnd() {
        func fix(_ store: Store, _ pasted: String, _ final: String) -> CorrectionLearner.Outcome {
            CorrectionLearner.learn(
                pasted: pasted,
                final: final,
                lexicon: SmallLexicon(),
                learnedTerms: store.termKeys,
                learnedRules: store.ruleKeys
            )
        }
        var store = Store()
        let learned = fix(store, "deploy it to versel tonight", "deploy it to Vercel tonight")
        _ = store.apply(learned, from: observation(), now: start)
        TestSupport.expectEqual(store.ruleRows.count, 1)
        TestSupport.expectEqual(store.ruleKeys, [CorrectionLearner.ruleKey(heard: "versel", term: "Vercel")])
        let revert = fix(store, "deploy it to Vercel tonight", "deploy it to versel tonight")
        guard case .learned(let candidates) = revert, candidates.first?.isRevert == true else {
            TestSupport.expect(false, "changing the output back is a revert")
            return
        }
        let change = store.apply(revert, from: observation(), now: start + day)
        TestSupport.expectEqual(change.code, "revert")
        TestSupport.expect(store.ruleRows.isEmpty, "the rule is gone")
        TestSupport.expect(store.isTombstoned(heard: "versel", term: "Vercel"), "the pair is tombstoned")
        TestSupport.expectEqual(DictionaryCorrection.apply(effective(store, now: start + day).corrections, to: "deploy to versel"), "deploy to versel")
        TestSupport.expectEqual(store.items.map(\.text), ["Vercel"])
    }

    /// A manual entry spelled like a learned rule's heard phrase keeps that word.
    private static func testManualVocabularyStopsLearnedRule() {
        var store = Store()
        learn(&store, [candidate("Grok", "Groq", ruleLater: true)], at: start)
        learn(&store, [candidate("Grok", "Groq", ruleLater: true)], sentKeyterms: ["Groq"], at: start + day)
        TestSupport.expectEqual(store.ruleRows.count, 1)
        TestSupport.expectEqual(DictionaryCorrection.apply(effective(store, now: start + day).corrections, to: "ask Grok"), "ask Groq")
        let manualWord = effective(store, manual: "Alpha, Grok", now: start + day)
        TestSupport.expectEqual(DictionaryCorrection.apply(manualWord.corrections, to: "ask Grok"), "ask Grok")
        let manualTarget = effective(store, corrections: [DictionaryCorrection(from: "grock", to: "Grok")], now: start + day)
        TestSupport.expectEqual(DictionaryCorrection.apply(manualTarget.corrections, to: "ask Grok"), "ask Grok")
    }

    /// Expiry deletes evidence and never learns, so it runs while learning is off; learned
    /// items do not age then.
    private static func testExpiryRunsWhileLearningIsOff() {
        var store = Store()
        learn(&store, [candidate("anthropic", "Anthropic", strength: .weak)], at: start)
        learn(&store, [candidate("cloud", "Claude")], at: start)
        learn(&store, [candidate("Claude", "cloud", strength: .weak, isRevert: true)], at: start + day)
        TestSupport.expectEqual(store.pending.count, 1)
        TestSupport.expectEqual(store.items[0].revertDates.count, 1)
        TestSupport.expect(!store.expireEvidence(now: start + 29 * day), "nothing expires within 30 days")
        TestSupport.expect(store.expireEvidence(now: start + 200 * day), "pending and revert dates expire")
        TestSupport.expect(store.pending.isEmpty, "the pending hash is gone")
        TestSupport.expect(store.items[0].revertDates.isEmpty, "old revert dates are gone")
        TestSupport.expectEqual(store.items.map(\.text), ["Claude"])
        TestSupport.expect(store.prune(now: start + 200 * day), "aging deletes the unused term when learning is on")
        TestSupport.expect(store.items.isEmpty, "the term aged out")
    }

    /// The pipeline finds hit ids on a copy off main and applies the counts by id.
    private static func testHitsByItemID() {
        var store = Store()
        learn(&store, [candidate("cloud code", "Claude Code")], at: start)
        learn(&store, [candidate("versel", "Vercel")], at: start)
        let snapshot = store
        let ids = snapshot.hitItemIDs(inRawTranscript: "open claude code and deploy to vercel")
        TestSupport.expectEqual(ids, Set(store.items.map(\.id)))
        TestSupport.expect(snapshot.hitItemIDs(inRawTranscript: "claude codex").isEmpty, "a partial word is no hit")
        // An item deleted meanwhile is skipped.
        store.removeItem(store.items[1].id)
        TestSupport.expect(store.recordHits(itemIDs: ids, now: start + day), "the remaining item counts")
        TestSupport.expectEqual(store.items.map(\.hits), [1])
        TestSupport.expect(!store.recordHits(itemIDs: [], now: start + day), "no ids, no change")
    }

    /// Kept-unchanged phrases are looked up per word run, case-insensitively, never across
    /// punctuation, and in time that does not grow with variants times text length.
    private static func testKeptUnchangedPhrases() {
        TestSupport.expectEqual(
            Store.phraseKeys("Ask cloud. Code it", maxWords: 2),
            ["ask", "cloud", "code", "it", "ask cloud", "code it"]
        )
        var store = Store()
        learn(&store, [candidate("cloud code", "Claude Code", ruleLater: true)], at: start)
        learn(&store, [candidate("kwen", "Qwen", ruleLater: true)], at: start)
        _ = store.apply(.nothing(.styleOrUnchanged), from: observation(pasted: "ask cloud. Code it with Kwen", final: "ask cloud. Code it with kwen!"), now: start + 1)
        TestSupport.expectEqual(store.items[0].variants[0].keptUnchanged, 0)
        TestSupport.expectEqual(store.items[1].variants[0].keptUnchanged, 1)
        _ = store.apply(.nothing(.styleOrUnchanged), from: observation(pasted: "open cloud code now", final: "open (cloud code) now"), now: start + 2)
        TestSupport.expectEqual(store.items[0].variants[0].keptUnchanged, 1)

        // At the caps with a long text, applying a Fix stays fast.
        var full = Store()
        full.items = (0..<Store.maxActiveItems).map { index in
            var item = Store.Item(text: inventedTerm(index), casingKnown: true, sources: [.runLog], firstSeen: start, lastSeen: start, scoreDate: start)
            item.variants = (0..<Store.maxVariants).map { variant in Store.HeardVariant(heard: "zk\(index) v\(variant)") }
            return item
        }
        let longText = Array(repeating: "please check the notes and send them over", count: 100).joined(separator: " ")
        let started = Date()
        _ = full.apply(.nothing(.rewrite), from: observation(pasted: longText, final: longText + "."), now: start)
        TestSupport.expect(Date().timeIntervalSince(started) < 0.5, "a long Fix at the caps applies quickly")
    }

    /// The dictation start's keyterms equal the full merge's, and a term the filters reject is
    /// dropped when the store loads.
    private static func testLearnedKeytermsMatchMerge() {
        var store = Store()
        for (index, term) in ["useAuth.ts", "order_id", "GPT-4o", "Claude Code", "Vercel"].enumerated() {
            learn(&store, [candidate("heard\(inventedTerm(index).lowercased())", term)], category: index % 2 == 0 ? .coding : .aiChat, at: start + Double(index))
        }
        learn(&store, [candidate("kwen", "Qwen")], at: start - 100 * day)
        store.items[0].state = .ambiguous
        let manual = "Vercel, Alpha"
        for category in [Store.Category.coding, .aiChat, .search, .other] {
            let merged = effective(store, manual: manual, category: category, now: start + day)
            let keyterms = EffectiveVocabulary.learnedKeyterms(
                manualVocabulary: manual, manualCorrections: [], learned: store, category: category, now: start + day
            )
            TestSupport.expectEqual(keyterms, merged.learnedKeyterms)
        }
        withDefaults { defaults in
            var tampered = store
            tampered.items.append(Store.Item(text: "sk-ant-FAKE0example0000", casingKnown: true, sources: [.runLog], firstSeen: start, lastSeen: start, scoreDate: start))
            tampered.save(to: defaults)
            let loaded = Store.load(from: defaults)
            TestSupport.expectEqual(loaded, store)
        }
    }

    /// The dictation start reads keyterms ranked ahead of time: the same list as ranking at
    /// the start, at any later time until the inputs change, dormant terms dropped on time.
    private static func testLearnedKeytermIndex() {
        var store = Store()
        for (index, term) in ["useAuth.ts", "order_id", "GPT-4o", "Claude Code", "Vercel", "Qwen"].enumerated() {
            learn(&store, [candidate("heard\(inventedTerm(index).lowercased())", term)], category: index % 2 == 0 ? .coding : .aiChat, at: start + Double(index) * day)
        }
        _ = store.recordHits(inRawTranscript: "deploy to vercel", now: start + 20 * day)
        store.setStarred(store.items[2].id, true)
        store.items[3].state = .ambiguous
        let manual = "Qwen, Alpha"
        let corrections = [DictionaryCorrection(from: "grok", to: "Groq")]
        let built = start + 30 * day
        let index = EffectiveVocabulary.LearnedKeytermIndex(
            manualVocabulary: manual, manualCorrections: corrections, learned: store, now: built
        )
        for category in Store.Category.allCases {
            for now in [built, built + 30 * day, start + 90.5 * day, start + 92 * day, start + 200 * day] {
                let ranked = EffectiveVocabulary.learnedKeyterms(
                    manualVocabulary: manual, manualCorrections: corrections, learned: store, category: category, now: now
                )
                TestSupport.expectEqual(index.keyterms(for: category, now: now), ranked)
            }
        }
        TestSupport.expectEqual(index.keyterms(for: .aiChat, now: built), ["GPT-4o", "Vercel"])
        TestSupport.expectEqual(index.keyterms(for: .aiChat, now: start + 200 * day), ["GPT-4o"])
        // useAuth.ts went dormant after 90 days, order_id a day later.
        TestSupport.expectEqual(index.keyterms(for: .coding, now: start + 90.5 * day), ["GPT-4o", "Vercel", "order_id"])
        TestSupport.expectEqual(index.keyterms(for: .coding, now: start + 92 * day), ["GPT-4o", "Vercel"])
        TestSupport.expectEqual(
            EffectiveVocabulary.LearnedKeytermIndex(manualVocabulary: manual, manualCorrections: corrections, learned: Store(), now: built),
            EffectiveVocabulary.LearnedKeytermIndex()
        )
        TestSupport.expectEqual(EffectiveVocabulary.LearnedKeytermIndex().keyterms(for: .coding, now: built), [])
    }

    /// The Corrections card lists every learned rule and marks the ones merge does not apply:
    /// an ambiguous term's, and those whose heard phrase a manual entry keeps.
    private static func testListedRulesShowWhatIsNotApplied() {
        var store = Store()
        learn(&store, [candidate("versel", "Vercel", ruleNow: true)], at: start)
        learn(&store, [candidate("kwen", "Qwen", ruleNow: true)], at: start + 1)
        learn(&store, [candidate("post gress", "Postgres", ruleNow: true)], at: start + 2)
        learn(&store, [candidate("super base", "Supabase", ruleNow: true)], at: start + 3)
        let revert = candidate("Supabase", "superb", strength: .weak, isRevert: true)
        learn(&store, [revert], at: start + day)
        learn(&store, [revert], at: start + 2 * day)
        TestSupport.expectEqual(store.items.first { $0.text == "Supabase" }?.state, .ambiguous)

        let manual = "Alpha, kwen"
        let corrections = [DictionaryCorrection(from: "versel", to: "Versel")]
        let listed = EffectiveVocabulary.listedRules(manualVocabulary: manual, manualCorrections: corrections, learned: store)
        TestSupport.expectEqual(listed.map(\.rule.id), store.ruleRows.map(\.id))
        let unused = Dictionary(uniqueKeysWithValues: listed.map { ($0.rule.variant.heard, $0.unused) })
        TestSupport.expectEqual(unused["versel"], .some(.manualWins))
        TestSupport.expectEqual(unused["kwen"], .some(.manualWins))
        TestSupport.expectEqual(unused["super base"], .some(.notSure))
        TestSupport.expectEqual(unused["post gress"], .some(nil))
        // Exactly the rules listed as in use are the learned rules merge applies.
        let applied = Set(effective(store, manual: manual, corrections: corrections, now: start + 3 * day).corrections.map(\.id))
        for row in listed {
            TestSupport.expectEqual(applied.contains(row.rule.variant.id), row.unused == nil)
        }
        TestSupport.expect(EffectiveVocabulary.listedRules(manualVocabulary: "", manualCorrections: [], learned: Store()).isEmpty, "nothing learned, no rows")
    }

    /// A store with every kind of field, as this build writes it.
    private static func richStore() -> Store {
        var store = Store()
        learn(&store, [candidate("versel", "Vercel", ruleNow: true)], category: .coding, sentKeyterms: ["Vercel"], at: start)
        learn(&store, [candidate("kwen", "Qwen")], category: .aiChat, at: start + 1)
        learn(&store, [candidate("zkold", "Zqold")], at: start + 2)
        learn(&store, [candidate("anthropic", "Anthropic", strength: .weak)], at: start + 3)
        learn(&store, [candidate("Qwen", "queen", strength: .weak, isRevert: true)], at: start + 4)
        _ = store.recordHits(inRawTranscript: "deploy to vercel", now: start + 5)
        _ = store.apply(.nothing(.rewrite), from: observation(), now: start + 6)
        _ = store.markCounted(entryID: UUID(), now: start + 7)
        store.setStarred(store.items[0].id, true)
        store.removeItem(store.items[2].id)
        return store
    }

    /// Only a change is written: a quit or an assignment that changes nothing writes nothing,
    /// and a store this build wrote reads back in full.
    private static func testSaverWritesOnlyChanges() {
        withDefaults { defaults in
            TestSupport.expectEqual(Store.loadChecked(from: defaults).status, .missing)
            var fresh = LearnedVocabularySaver(status: .missing)
            TestSupport.expect(!fresh.saveIfChanged(Store(), to: defaults), "nothing changed, nothing written")

            let rich = richStore()
            TestSupport.expect(!rich.tombstones.isEmpty && !rich.pending.isEmpty && rich.countedEntries != nil, "the fixture has every field")
            rich.save(to: defaults)
            let loaded = Store.loadChecked(from: defaults)
            TestSupport.expectEqual(loaded.status, .loaded)
            TestSupport.expectEqual(loaded.store, rich)

            var saver = LearnedVocabularySaver(status: loaded.status)
            TestSupport.expect(!saver.keepsStoredUnread, "a store read in full is written")
            TestSupport.expect(!saver.noteChange(from: loaded.store, to: loaded.store), "an equal assignment is no change")
            TestSupport.expect(!saver.saveIfChanged(loaded.store, to: defaults), "a quit with nothing changed writes nothing")

            var changed = loaded.store
            learn(&changed, [candidate("post gress", "Postgres")], at: start + day)
            TestSupport.expect(saver.noteChange(from: loaded.store, to: changed), "learning is a change")
            TestSupport.expect(saver.saveIfChanged(changed, to: defaults), "a change is written")
            TestSupport.expectEqual(Store.load(from: defaults), changed)
            TestSupport.expect(!saver.saveIfChanged(changed, to: defaults), "and only once")

            // Deleting the last item writes the empty store, which removes the key.
            saver.noteChange(from: changed, to: Store())
            TestSupport.expect(saver.saveIfChanged(Store(), to: defaults), "the empty store is written")
            TestSupport.expect(defaults.object(forKey: Store.storageKey) == nil, "and leaves nothing behind")
        }
    }

    /// A stored store this build cannot read in full (undecodable, a newer version, or fields
    /// it does not know) keeps its bytes: learning stays in memory and nothing is written, not
    /// even an empty store. Delete all still removes it.
    private static func testStoreThisBuildCannotReadIsKept() {
        let rich = richStore()
        let richObject = (try? JSONEncoder().encode(rich))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        TestSupport.expect(!richObject.isEmpty, "the fixture encodes")
        func edited(_ edit: (inout [String: Any]) -> Void) -> Data {
            var object = richObject
            edit(&object)
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        func editFirstItem(_ object: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
            var items = object["items"] as? [[String: Any]] ?? []
            guard !items.isEmpty else { return }
            edit(&items[0])
            object["items"] = items
        }
        let cases: [(label: String, stored: Any, keepsItems: Bool)] = [
            ("not JSON", Data("not json".utf8), false),
            ("not data", "a string", false),
            ("an unknown state", edited { editFirstItem(&$0) { $0["state"] = "dormant" } }, false),
            ("a newer version", edited { $0["version"] = Store.currentVersion + 1 }, true),
            ("an unknown top-level field", edited { $0["futureField"] = ["count": 1] }, true),
            ("an unknown item field", edited { editFirstItem(&$0) { $0["futureItemField"] = 1 } }, true),
            ("an unknown variant field", edited {
                editFirstItem(&$0) { item in
                    var variants = item["variants"] as? [[String: Any]] ?? []
                    if !variants.isEmpty { variants[0]["futureVariantField"] = true }
                    item["variants"] = variants
                }
            }, true),
        ]
        for testCase in cases {
            withDefaults { defaults in
                defaults.set(testCase.stored, forKey: Store.storageKey)
                let before = defaults.object(forKey: Store.storageKey) as? NSObject
                let loaded = Store.loadChecked(from: defaults)
                TestSupport.expect(loaded.status == .keptUnread, "\(testCase.label) is kept unread")
                TestSupport.expect(
                    loaded.store.items.map(\.text) == (testCase.keepsItems ? rich.items.map(\.text) : []),
                    "\(testCase.label): what is readable is used in memory"
                )
                var saver = LearnedVocabularySaver(status: loaded.status)
                TestSupport.expect(saver.keepsStoredUnread, "\(testCase.label): not written")

                // Learning goes on in memory; the save and the quit write nothing.
                var store = loaded.store
                learn(&store, [candidate("post gress", "Postgres")], at: start + day)
                TestSupport.expect(saver.noteChange(from: loaded.store, to: store), "\(testCase.label): learning is a change")
                TestSupport.expect(!saver.saveIfChanged(store, to: defaults), "\(testCase.label): the change stays in memory")
                saver.noteChange(from: store, to: Store())
                TestSupport.expect(!saver.saveIfChanged(Store(), to: defaults), "\(testCase.label): an empty store does not remove it")
                // Deleting a learned term lasts only until the app quits too (the Learning card
                // says so): the next load has it again.
                if let first = loaded.store.items.first {
                    var removed = loaded.store
                    removed.removeItem(first.id)
                    saver.noteChange(from: loaded.store, to: removed)
                    TestSupport.expect(!saver.saveIfChanged(removed, to: defaults), "\(testCase.label): the delete stays in memory")
                    TestSupport.expect(Store.load(from: defaults).items.contains { $0.id == first.id }, "\(testCase.label): the deleted term is back at the next load")
                }
                TestSupport.expect(
                    (defaults.object(forKey: Store.storageKey) as? NSObject)?.isEqual(before) == true,
                    "\(testCase.label): the stored bytes are unchanged"
                )

                // Delete all removes it, and changes are written from then on.
                saver.deleteAll(from: defaults)
                TestSupport.expect(defaults.object(forKey: Store.storageKey) == nil, "\(testCase.label): Delete all removes it")
                TestSupport.expect(!saver.keepsStoredUnread, "\(testCase.label): written after Delete all")
                saver.noteChange(from: Store(), to: store)
                TestSupport.expect(saver.saveIfChanged(store, to: defaults), "\(testCase.label): the next change is written")
                TestSupport.expectEqual(Store.load(from: defaults), store)
            }
        }
    }

    /// A stored term the current filters reject (here an invented secret-shaped one) is left
    /// out at load and removed from defaults by the launch save, with nothing else changed. A
    /// store kept unread still keeps its bytes.
    private static func testLaunchSaveRemovesUnstorableTerms() {
        let fakeSecret = "sk-ant-FAKE0example0000"
        TestSupport.expect(!Store.isStorable(fakeSecret), "the fixture is unstorable")
        var store = Store()
        learn(&store, [candidate("versel", "Vercel"), candidate("kwen", "Qwen")], at: start)
        func stored(version: Int) -> Data {
            let data = (try? JSONEncoder().encode(store)) ?? Data()
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            var items = object["items"] as? [[String: Any]] ?? []
            if items.count == 2 { items[1]["text"] = fakeSecret }
            object["items"] = items
            object["version"] = version
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        func storedText(_ defaults: UserDefaults) -> String {
            defaults.data(forKey: Store.storageKey).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }

        withDefaults { defaults in
            defaults.set(stored(version: Store.currentVersion), forKey: Store.storageKey)
            TestSupport.expect(storedText(defaults).contains(fakeSecret), "the fixture is stored")
            let loaded = Store.loadChecked(from: defaults)
            TestSupport.expectEqual(loaded.status, .loaded)
            TestSupport.expect(loaded.droppedItems, "the load reports the dropped term")
            TestSupport.expectEqual(loaded.store.items.map(\.text), ["Vercel"])
            // AppState's launch: the saver from the load, then saveIfChanged.
            var saver = LearnedVocabularySaver(loaded: loaded)
            TestSupport.expect(saver.saveIfChanged(loaded.store, to: defaults), "the launch save rewrites the store")
            TestSupport.expect(!storedText(defaults).contains(fakeSecret), "the dropped term is gone from defaults")
            let reloaded = Store.loadChecked(from: defaults)
            TestSupport.expect(reloaded.status == .loaded && !reloaded.droppedItems, "the rewritten store loads in full")
            TestSupport.expectEqual(reloaded.store, loaded.store)
            var next = LearnedVocabularySaver(loaded: reloaded)
            TestSupport.expect(!next.saveIfChanged(reloaded.store, to: defaults), "the next launch writes nothing")
        }

        withDefaults { defaults in
            defaults.set(stored(version: Store.currentVersion + 1), forKey: Store.storageKey)
            let before = defaults.data(forKey: Store.storageKey)
            let loaded = Store.loadChecked(from: defaults)
            TestSupport.expect(loaded.status == .keptUnread && loaded.droppedItems, "a newer store drops the term in memory")
            TestSupport.expectEqual(loaded.store.items.map(\.text), ["Vercel"])
            var saver = LearnedVocabularySaver(loaded: loaded)
            TestSupport.expect(!saver.saveIfChanged(loaded.store, to: defaults), "a store kept unread is not written")
            TestSupport.expectEqual(defaults.data(forKey: Store.storageKey), before)
        }
    }
}
