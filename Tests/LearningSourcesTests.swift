import Foundation

/// The sent-text sources' shared pieces: the paste matcher and ring rules, kept cleanup fixes
/// over several dictations, and provider-neutral streaming evidence. Invented text, injected
/// dates, stub sessions and throwaway UserDefaults suites only; no AppState and no network.
enum LearningSourcesTests {
    private typealias Store = LearnedVocabulary
    private typealias Candidate = CorrectionLearner.Candidate

    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let day = Store.day
    private static let lexicon = CorrectionLearnerTests.lexicon

    static func run() {
        testPasteCoverage()
        testHookPromptVerdict()
        testPasteEligibility()
        testRingAndMatcherRules()
        testReDictationIsNotCredited()
        testAttachPaste()
        testCleanupFixCounting()
        testCleanupFixCancellation()
        testCleanupFixExclusions()
        testCleanupFixRules()
        testKeptFixes()
        testCleanupStorage()
        testRecordAccepted()
        testSearchStorage()
        testHookSightings()
        testSearchSequences()
        testPressedEnterCreditsCleanupFixes()
        testCancelStopsLearning()
        testSearchSurfaceAppliesSearchRules()
        testEvidenceGate()
        testConfidencesOverAssemblyAIWords()
    }

    // MARK: Fixtures

    private static func paste(
        _ pasted: String,
        raw: String? = nil,
        destination: LearningPaste.Destination = .vsCode,
        observed: Bool = false
    ) -> LearningPaste {
        var paste = LearningPaste(
            pasted: pasted,
            raw: raw ?? pasted,
            destination: destination,
            category: .coding,
            pressedEnter: false,
            countsForHookHealth: destination == .vsCode
        )
        paste.observed = observed
        return paste
    }

    private static func record(id: UUID = UUID(), at date: Date = start, paste: LearningPaste?) -> DictationRecord {
        DictationRecord(id: id, createdAt: date, words: [], keyterms: [], paste: paste)
    }

    private static func fix(
        _ heard: String = "cloud code",
        _ term: String = "Claude Code",
        strength: CorrectionLearner.Strength = .strong,
        ruleNow: Bool = false,
        ruleLater: Bool = true
    ) -> Candidate {
        Candidate(heard: heard, term: term, strength: strength, ruleNow: ruleNow, ruleLater: ruleLater)
    }

    private static func observation(source: LearningSource = .cleanup, category: Store.Category = .coding, sentKeyterms: [String] = []) -> Store.Observation {
        Store.Observation(source: source, category: category, settled: true, sentKeyterms: sentKeyterms, pasted: "", final: "")
    }

    @discardableResult
    private static func credit(
        _ store: inout Store,
        _ candidates: [Candidate] = [fix()],
        entry: UUID = UUID(),
        sentKeyterms: [String] = [],
        at date: Date
    ) -> Store.Change {
        store.applyCleanupFixes(candidates, entryID: entry, observation: observation(sentKeyterms: sentKeyterms), now: date)
    }

    // MARK: L1-L3

    private static func testPasteCoverage() {
        typealias Matcher = SentTextMatcher
        TestSupport.expectEqual(Matcher.minimumCoverage, 0.6)
        // L1: a paste inside typed text.
        TestSupport.expect(
            Matcher.coverage(
                of: "ask cloud to refactor the parser",
                in: "before anything else ask Claude to refactor the parser and then run the synthetic tests"
            ) >= 0.6,
            "A paste located inside typed text is covered"
        )
        // A paste the user kept in full.
        TestSupport.expectApproximatelyEqual(Matcher.coverage(of: "Fix the Parser.", in: "fix the parser"), 1)
        // L2: an unrelated prompt.
        TestSupport.expect(
            Matcher.coverage(of: "ask cloud to refactor the parser", in: "what is the weather like in a synthetic town") < 0.6,
            "An unrelated prompt is not covered"
        )
        // L3: a scheduled-task prompt.
        TestSupport.expect(
            Matcher.coverage(
                of: "ask cloud to refactor the parser",
                in: "Scheduled task: run the nightly synthetic report and summarize any failures"
            ) < 0.6,
            "A scheduled-task prompt is not covered"
        )
        // Shared words out of order are not in the paste's order.
        TestSupport.expect(Matcher.coverage(of: "one two three four five", in: "five four three two one") < 0.6, "Order counts")
        TestSupport.expectEqual(Matcher.coverage(of: "", in: "words"), 0)
        TestSupport.expectEqual(Matcher.coverage(of: "words", in: ""), 0)
    }

    /// ST8: a hook prompt with markers gives the same verdict as without them.
    private static func testHookPromptVerdict() {
        let pasted = "ask cloud to refactor the parser"
        let plain = "ask Claude to refactor the parser"
        let marked = "<ide_selection>let synthetic = 1</ide_selection>\n<pasted_content id=\"2bba\">\n\(plain)\n</pasted_content id=\"2bba\">"
        let final = HookPrompt.userText(marked)
        TestSupport.expectEqual(final, plain)
        TestSupport.expectEqual(
            CorrectionLearner.learn(pasted: pasted, final: final ?? "", lexicon: lexicon),
            CorrectionLearner.learn(pasted: pasted, final: plain, lexicon: lexicon)
        )
        TestSupport.expect(SentTextMatcher.coverage(of: pasted, in: final ?? "") >= SentTextMatcher.minimumCoverage, "The paste is found")
    }

    private static func testPasteEligibility() {
        func eligible(
            inserted: String = "synthetic words",
            bundle: String? = "com.microsoft.VSCode",
            composer: ContextTarget? = .claudeCodePanel,
            classified: Bool = true,
            listening: Bool = true,
            isCommandMode: Bool = false,
            isVoiceMacro: Bool = false,
            snippets: Int = 0,
            files: Int = 0,
            autoApplied: Bool = false
        ) -> LearningPaste? {
            LearningPaste.eligible(
                inserted: inserted,
                raw: "synthetic raw",
                bundleIdentifier: bundle,
                category: .coding,
                composerTarget: composer,
                composerClassified: classified,
                listensForPrompts: listening,
                pressedEnter: true,
                isCommandMode: isCommandMode,
                isVoiceMacro: isVoiceMacro,
                expandedSnippetCount: snippets,
                taggedFileCount: files,
                autoApplied: autoApplied
            )
        }
        let vscode = eligible()
        TestSupport.expectEqual(vscode?.destination, .vsCode)
        TestSupport.expectEqual(vscode?.countsForHookHealth, true)
        TestSupport.expectEqual(vscode?.pressedEnter, true)
        TestSupport.expectEqual(vscode?.observed, false)
        TestSupport.expectEqual(vscode?.pasted, "synthetic words")
        TestSupport.expectEqual(vscode?.raw, "synthetic raw")
        // A field read and found to be an editor does not count for the health check...
        TestSupport.expectEqual(eligible(composer: nil)?.countsForHookHealth, false)
        // ...but with no field read (Context Awareness off, screenshot context, a missed
        // deadline) the composer is unknown, and every VS Code paste counts.
        TestSupport.expectEqual(eligible(composer: nil, classified: false)?.countsForHookHealth, true)
        TestSupport.expectEqual(eligible(bundle: "com.google.Chrome", composer: .googleSearch)?.destination, .chrome)
        TestSupport.expectEqual(eligible(bundle: "com.google.Chrome", composer: .googleSearch)?.countsForHookHealth, false)
        TestSupport.expectEqual(eligible(bundle: "com.google.Chrome", composer: nil, classified: false)?.countsForHookHealth, false)
        // With no hook listener nothing can use a VS Code paste, so its text is not kept. The
        // Google watch needs no listener.
        TestSupport.expect(eligible(listening: false) == nil, "VS Code with nothing listening")
        TestSupport.expect(eligible(composer: nil, classified: false, listening: false) == nil, "Also with no field read")
        TestSupport.expectEqual(eligible(bundle: "com.google.Chrome", composer: .googleSearch, listening: false)?.destination, .chrome)
        // Every other app is never observed, so its text is not kept at all.
        TestSupport.expect(eligible(bundle: "com.apple.Notes", composer: nil) == nil, "Another app")
        TestSupport.expect(eligible(bundle: nil, composer: nil) == nil, "No app")
        // Text FreeFlow wrote itself.
        TestSupport.expect(eligible(inserted: "") == nil, "Nothing pasted")
        TestSupport.expect(eligible(isCommandMode: true) == nil, "Edit Mode")
        TestSupport.expect(eligible(isVoiceMacro: true) == nil, "A voice macro")
        TestSupport.expect(eligible(snippets: 1) == nil, "A snippet")
        TestSupport.expect(eligible(files: 1) == nil, "A file tag")
        TestSupport.expect(eligible(autoApplied: true) == nil, "An auto-applied transform")
    }

    private static func testRingAndMatcherRules() {
        var ring = DictationRecordRing()
        let firstID = UUID(), secondID = UUID(), noPasteID = UUID()
        ring.append(record(id: firstID, paste: paste("first synthetic paste")), now: start)
        ring.append(record(id: secondID, at: start + 5, paste: paste("second synthetic paste")), now: start + 5)
        ring.append(DictationRecord(id: noPasteID, createdAt: start + 6, words: [], keyterms: []), now: start + 6)
        TestSupport.expectEqual(ring.unobservedPastes(now: start + 10).map(\.id), [firstID, secondID])

        TestSupport.expect(ring.markObserved(id: firstID), "The first mark counts")
        TestSupport.expect(!ring.markObserved(id: firstID), "A second frame cannot reuse it")
        TestSupport.expect(!ring.markObserved(id: noPasteID), "No paste to mark")
        TestSupport.expect(!ring.markObserved(id: UUID()), "An unknown record")
        TestSupport.expectEqual(ring.unobservedPastes(now: start + 10).map(\.id), [secondID])

        // Older than the ring's lifetime: not matched, even before it is removed.
        TestSupport.expectEqual(ring.unobservedPastes(now: start + 5 + 599).map(\.id), [secondID])
        TestSupport.expectEqual(ring.unobservedPastes(now: start + 5 + 600).map(\.id), [])

        ring.clearPaste(id: secondID)
        TestSupport.expectEqual(ring.unobservedPastes(now: start + 10).map(\.id), [])
        TestSupport.expect(ring.record(id: secondID, now: start + 10) != nil, "The record's evidence stays for Fix")

        let older = UUID(), newer = UUID(), unrelated = UUID()
        let words = "ask cloud to refactor the parser"
        TestSupport.expectEqual(
            SentTextMatcher.matches(
                "please ask Claude to refactor the parser now",
                in: [(id: older, pasted: words), (id: unrelated, pasted: "nothing alike here"), (id: newer, pasted: "Ask cloud to refactor the parser.")]
            ),
            SentTextMatcher.Match(credited: [newer], superseded: [older])
        )
        let otherPaste = UUID()
        TestSupport.expectEqual(
            SentTextMatcher.matches(
                "ask cloud to refactor the parser and then add synthetic tests for it",
                in: [(id: older, pasted: words), (id: otherPaste, pasted: "add synthetic tests for it")]
            ),
            SentTextMatcher.Match(credited: [older, otherPaste])
        )
        let tooLong = String(repeating: "word ", count: CorrectionLearner.maxTokens) + words
        TestSupport.expectEqual(SentTextMatcher.matches(tooLong, in: [(id: older, pasted: words)]), SentTextMatcher.Match())
        TestSupport.expectEqual(SentTextMatcher.coverage(of: tooLong, in: tooLong), 0)
    }

    /// A paste deleted and dictated again was never sent: both sides come from speech
    /// recognition, so that pair is never learned.
    private static func testReDictationIsNotCredited() {
        let first = UUID(), second = UUID()
        let unsent = "ask cloud to refactor the parser", sent = "ask Claude to refactor the parser"
        let pastes = [(id: first, pasted: unsent), (id: second, pasted: sent)]
        let expected = SentTextMatcher.Match(credited: [second], superseded: [first])
        TestSupport.expectEqual(SentTextMatcher.matches(sent, in: pastes), expected)
        TestSupport.expectEqual(SentTextMatcher.matches("please \(sent) today", in: pastes), expected)
        // The same take twice: only the newest is credited.
        TestSupport.expectEqual(
            SentTextMatcher.matches("\(sent) and \(sent)", in: [(id: first, pasted: sent), (id: second, pasted: sent)]),
            expected
        )

        // Two pastes in one prompt both match, in either order, even when they share words.
        let refactor = "ask cloud to refactor", test = "ask cloud to test it"
        let prompt = "ask Claude to refactor and ask Claude to test it"
        TestSupport.expectEqual(
            SentTextMatcher.matches(prompt, in: [(id: first, pasted: refactor), (id: second, pasted: test)]),
            SentTextMatcher.Match(credited: [first, second])
        )
        TestSupport.expectEqual(
            SentTextMatcher.matches("ask Claude to test it and ask Claude to refactor", in: [(id: first, pasted: test), (id: second, pasted: refactor)]),
            SentTextMatcher.Match(credited: [first, second])
        )

        // Claiming learns from the sent take only, and no later prompt can match the other.
        var ring = DictationRecordRing()
        ring.append(record(id: first, paste: paste(unsent)), now: start)
        ring.append(record(id: second, at: start + 1, paste: paste(sent)), now: start + 1)
        let claimed = ring.claim(expected, now: start + 2)
        TestSupport.expectEqual(claimed.map(\.id), [second])
        TestSupport.expectEqual(claimed.first?.paste?.observed, true)
        TestSupport.expect(ring.record(id: first, now: start + 2)?.paste == nil, "The unsent text is forgotten")
        TestSupport.expect(ring.record(id: first, now: start + 2) != nil, "Its evidence stays for Fix")
        TestSupport.expectEqual(ring.unobservedPastes(now: start + 2).map(\.id), [])
        TestSupport.expectEqual(ring.claim(expected, now: start + 3).map(\.id), [])

        // The regression itself: no term from the unsent take, and no toast.
        var store = Store()
        for record in claimed {
            guard let paste = record.paste else { continue }
            let applied = sight(.hookPrompt, paste: paste, final: sent, store: &store, entry: record.id, now: start + 2)
            TestSupport.expect(!applied.change.hasLearned, "Nothing was learned from the unsent take")
        }
        TestSupport.expectEqual(store.items.count, 0)
    }

    /// A paste joins its record only once it is dispatched, so one that was skipped leaves
    /// nothing to match, count or watch.
    private static func testAttachPaste() {
        var ring = DictationRecordRing()
        let withEvidence = UUID(), withoutEvidence = UUID(), skipped = UUID()
        ring.append(DictationRecord(id: withEvidence, createdAt: start, words: [], keyterms: ["Vercel"]), now: start)
        ring.append(DictationRecord(id: skipped, createdAt: start, words: [], keyterms: ["Vercel"]), now: start)
        ring.attachPaste(paste("synthetic words"), id: withEvidence, now: start + 1)
        TestSupport.expectEqual(ring.record(id: withEvidence, now: start + 1)?.keyterms, ["Vercel"])
        TestSupport.expectEqual(ring.record(id: withEvidence, now: start + 1)?.createdAt, start)
        TestSupport.expectEqual(ring.record(id: withEvidence, now: start + 1)?.paste?.pasted, "synthetic words")
        ring.attachPaste(paste("other words", destination: .chrome), id: withoutEvidence, now: start + 2)
        TestSupport.expectEqual(ring.record(id: withoutEvidence, now: start + 2)?.createdAt, start + 2)

        TestSupport.expectEqual(ring.pastes(into: .vsCode, now: start + 3).map(\.id), [withEvidence])
        TestSupport.expectEqual(ring.pastes(into: .chrome, now: start + 3).map(\.id), [withoutEvidence])
        TestSupport.expect(ring.record(id: skipped, now: start + 3)?.paste == nil, "A skipped paste never joined")
    }

    // MARK: Kept cleanup fixes

    private static func testCleanupFixCounting() {
        var store = Store()
        let entries = [UUID(), UUID(), UUID()]
        TestSupport.expectEqual(Store.cleanupFixDictations, 3)

        var change = credit(&store, entry: entries[0], at: start)
        TestSupport.expect(!change.hasLearned, "Dictation 1 teaches nothing")
        TestSupport.expectEqual(store.items.count, 0)
        TestSupport.expectEqual(store.cleanupCredits?.count, 1)

        // The same dictation counts once.
        credit(&store, entry: entries[0], at: start + 1)
        TestSupport.expectEqual(store.cleanupCredits?.count, 1)

        change = credit(&store, entry: entries[1], at: start + day)
        TestSupport.expect(!change.hasLearned, "Dictation 2 teaches nothing")
        TestSupport.expectEqual(store.items.count, 0)
        TestSupport.expectEqual(store.cleanupCredits?.count, 2)

        change = credit(&store, entry: entries[2], at: start + 2 * day)
        TestSupport.expect(change.hasLearned, "Dictation 3 teaches the term")
        TestSupport.expectEqual(change.learnedTerms, ["Claude Code"])
        TestSupport.expectEqual(store.items.count, 1)
        let item = store.items[0]
        TestSupport.expectEqual(item.text, "Claude Code")
        TestSupport.expectEqual(item.sources, [.cleanup])
        TestSupport.expectEqual(item.corrections, 3)
        TestSupport.expectEqual(item.state, .active)
        TestSupport.expect(item.casingKnown, "Cleanup's output has real casing")
        TestSupport.expectEqual(item.variants.first?.sightings, [start, start + day, start + 2 * day])
        TestSupport.expectEqual(store.cleanupCredits, nil)

        // Undo on the toast forgets it for good.
        store.undo(change)
        TestSupport.expectEqual(store.items.count, 0)
        for offset in 0..<3 {
            credit(&store, at: start + 3 * day + Double(offset))
        }
        TestSupport.expectEqual(store.items.count, 0)
        TestSupport.expectEqual(store.cleanupCredits, nil)
    }

    private static func testCleanupFixCancellation() {
        var store = Store()
        let first = UUID(), second = UUID()
        credit(&store, entry: first, at: start)
        credit(&store, entry: second, at: start + 1)
        TestSupport.expect(store.cancelCleanupCredit(entryID: second), "Undo AI edit cancels the credit")
        TestSupport.expect(!store.cancelCleanupCredit(entryID: second), "Nothing left to cancel")
        TestSupport.expect(!store.cancelCleanupCredit(entryID: UUID()), "Another entry has none")
        TestSupport.expectEqual(store.cleanupCredits?.count, 1)

        // The third dictation is only the second credit; a fourth activates.
        var change = credit(&store, at: start + 2)
        TestSupport.expect(!change.hasLearned, "The cancelled dictation does not count")
        let last = UUID()
        change = credit(&store, entry: last, at: start + 3)
        TestSupport.expect(change.hasLearned, "The next one does")

        // After activation Undo AI edit leaves the term; the toast's Undo removes it.
        TestSupport.expect(!store.cancelCleanupCredit(entryID: last), "No credit is left")
        TestSupport.expectEqual(store.items.count, 1)
    }

    private static func testCleanupFixExclusions() {
        // Credits older than the evidence window do not count.
        var aged = Store()
        credit(&aged, at: start)
        credit(&aged, at: start + day)
        credit(&aged, at: start + Store.evidenceWindow + 2 * day)
        TestSupport.expectEqual(aged.items.count, 0)
        TestSupport.expectEqual(aged.cleanupCredits?.count, 1)

        // Tombstoned terms and pairs.
        var tombstoned = Store()
        for offset in 0..<3 { credit(&tombstoned, at: start + Double(offset)) }
        TestSupport.expect(tombstoned.removeItem(tombstoned.items[0].id), "Deleted")
        credit(&tombstoned, at: start + 10)
        TestSupport.expectEqual(tombstoned.cleanupCredits, nil)
        TestSupport.expectEqual(tombstoned.items.count, 0)

        var pairTombstoned = Store()
        pairTombstoned.tombstones = [Store.pairHash(heard: "cloud code", term: "Claude Code")]
        credit(&pairTombstoned, at: start)
        TestSupport.expectEqual(pairTombstoned.cleanupCredits, nil)

        // Unstorable text gets no credit.
        var unstorable = Store()
        credit(&unstorable, [fix("a, b", "A, B")], at: start)
        TestSupport.expectEqual(unstorable.cleanupCredits, nil)

        // The credit cap holds, newest kept.
        var capped = Store()
        capped.cleanupCredits = (0..<(Store.maxPending + 5)).map { index in
            Store.CleanupCredit(pairHash: "p\(index)", entryHash: "e\(index)", countedAt: start + Double(index), wasKeyterm: false)
        }
        _ = capped.expireEvidence(now: start + Double(Store.maxPending))
        TestSupport.expectEqual(capped.cleanupCredits?.count, Store.maxPending)
        TestSupport.expect(capped.cleanupCredits?.contains { $0.pairHash == "p0" } == false, "The oldest go first")
    }

    private static func testCleanupFixRules() {
        // A keyterm credit at any of the three dictations makes a rule at activation.
        var withKeyterm = Store()
        credit(&withKeyterm, sentKeyterms: ["Claude Code"], at: start)
        credit(&withKeyterm, at: start + 1)
        let ruled = credit(&withKeyterm, at: start + 2)
        TestSupport.expectEqual(ruled.learnedRules, [Store.RulePair(heard: "cloud code", term: "Claude Code")])
        TestSupport.expectEqual(withKeyterm.items[0].variants.first?.isRule, true)
        TestSupport.expectEqual(withKeyterm.items[0].keytermFailures, 1)

        var withoutKeyterm = Store()
        for offset in 0..<3 { credit(&withoutKeyterm, at: start + Double(offset)) }
        TestSupport.expectEqual(withoutKeyterm.items.first?.variants.first?.isRule, false)

        // A candidate that may be a rule at once never is, from cleanup.
        var neverNow = Store()
        for offset in 0..<3 {
            credit(&neverNow, [fix("versel", "Vercel", ruleNow: true, ruleLater: false)], at: start + Double(offset))
        }
        TestSupport.expectEqual(neverNow.items.first?.text, "Vercel")
        TestSupport.expectEqual(neverNow.items.first?.variants.first?.isRule, false)

        // A term already in the store waits for three dictations too, also from a weak fix, so
        // Undo AI edit can still take a sighting back.
        var existing = Store()
        _ = existing.apply(.learned([fix(ruleLater: false)]), from: observation(source: .runLog), now: start)
        TestSupport.expectEqual(existing.items.first?.corrections, 1)
        let before = existing
        let cancelled = UUID()
        let waiting = credit(&existing, [fix(strength: .weak)], entry: cancelled, sentKeyterms: ["Claude Code"], at: start + 1)
        TestSupport.expectEqual(waiting.updatedTerms, [])
        TestSupport.expectEqual(existing.items.first?.corrections, 1)
        TestSupport.expect(existing.cancelCleanupCredit(entryID: cancelled), "Undo AI edit cancels the sighting")
        TestSupport.expectEqual(existing, before)

        let last = UUID()
        credit(&existing, [fix(strength: .weak)], sentKeyterms: ["Claude Code"], at: start + 2)
        credit(&existing, [fix(strength: .weak)], at: start + 3)
        let seenAgain = credit(&existing, [fix(strength: .weak)], entry: last, at: start + 4)
        TestSupport.expectEqual(seenAgain.updatedTerms, ["Claude Code"])
        TestSupport.expectEqual(existing.items.first?.corrections, 4)
        TestSupport.expectEqual(existing.items.first?.sources, [.cleanup, .runLog])
        TestSupport.expectEqual(existing.items.first?.keytermFailures, 1)
        TestSupport.expectEqual(existing.cleanupCredits, nil)
        // Rule-later needs eligibility and a keyterm sighting, and three cleanup sightings have both.
        TestSupport.expectEqual(seenAgain.learnedRules, [Store.RulePair(heard: "cloud code", term: "Claude Code")])
        // The limit: once the sightings are in, Undo AI edit cancels nothing; the toast's Undo
        // removes the new rule.
        TestSupport.expect(!existing.cancelCleanupCredit(entryID: last), "No credit is left")
        TestSupport.expectEqual(existing.items.first?.variants.first?.isRule, true)
        existing.undo(seenAgain)
        TestSupport.expectEqual(existing.items.first?.variants.first?.isRule, false)
    }

    private static func keptFixes(
        raw: String,
        pasted: String,
        final: String,
        manual: Set<String> = [],
        rules: Set<String> = [],
        tombstoned: Set<String> = []
    ) -> [String] {
        CleanupFixSignal.keptFixes(
            raw: raw,
            pasted: pasted,
            final: final,
            lexicon: lexicon,
            confidences: [:],
            manualTerms: manual,
            learnedTerms: [],
            learnedRules: rules,
            isTombstoned: { tombstoned.contains($0) }
        ).map { "\($0.heard)->\($0.term)" }
    }

    private static func testKeptFixes() {
        let raw = "um so ask cloud code to like refactor the uh parser"
        let pasted = "Ask Claude Code to refactor the parser."
        TestSupport.expectEqual(keptFixes(raw: raw, pasted: pasted, final: pasted), ["cloud code->Claude Code"])
        TestSupport.expectEqual(
            keptFixes(raw: raw, pasted: pasted, final: "first this: ask Claude Code to refactor the parser, then stop"),
            ["cloud code->Claude Code"]
        )
        // Nothing cleaned, or the term did not survive to the final text.
        TestSupport.expectEqual(keptFixes(raw: pasted, pasted: pasted, final: pasted), [])
        TestSupport.expectEqual(keptFixes(raw: raw, pasted: pasted, final: "ask someone to refactor the parser"), [])
        // A learned rule made that change, not cleanup.
        TestSupport.expectEqual(
            keptFixes(raw: raw, pasted: pasted, final: pasted, rules: [CorrectionLearner.ruleKey(heard: "cloud code", term: "Claude Code")]),
            []
        )
        // A manual term is already known.
        TestSupport.expectEqual(keptFixes(raw: raw, pasted: pasted, final: pasted, manual: ["claude code"]), [])
        // A tombstoned term.
        TestSupport.expectEqual(keptFixes(raw: raw, pasted: pasted, final: pasted, tombstoned: ["claude code"]), [])
        // Ordinary capitalization is not a term.
        TestSupport.expectEqual(keptFixes(raw: "wispr flow is great", pasted: "Wispr Flow is great.", final: "Wispr Flow is great."), [])
    }

    private static func testCleanupStorage() {
        let suite = "FreeFlowTests.LearningSources.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // A store written before this field still loads in full.
        var older = Store()
        _ = older.apply(.learned([fix(ruleLater: false)]), from: observation(source: .runLog), now: start)
        older.save(to: defaults)
        TestSupport.expect(
            (defaults.data(forKey: Store.storageKey).map { String(decoding: $0, as: UTF8.self) } ?? "").contains("cleanupCredits") == false,
            "Nil when empty"
        )
        var loaded = Store.loadChecked(from: defaults)
        TestSupport.expectEqual(loaded.status, .loaded)
        TestSupport.expectEqual(loaded.store.cleanupCredits, nil)

        // A round trip keeps credits, as hashes and dates only.
        var store = Store()
        let entry = UUID()
        credit(&store, [fix("kwen tokenizer", "Qwen Tokenizer")], entry: entry, sentKeyterms: ["Qwen Tokenizer"], at: start)
        store.save(to: defaults)
        loaded = Store.loadChecked(from: defaults)
        TestSupport.expectEqual(loaded.status, .loaded)
        TestSupport.expectEqual(loaded.store, store)
        let text = defaults.data(forKey: Store.storageKey).map { String(decoding: $0, as: UTF8.self) } ?? ""
        for word in ["kwen", "Qwen", "tokenizer", "Tokenizer", entry.uuidString] {
            TestSupport.expect(!text.contains(word), "A credit holds no text")
        }
        TestSupport.expectEqual(
            store.cleanupCredits,
            [Store.CleanupCredit(
                pairHash: Store.pairHash(heard: "kwen tokenizer", term: "Qwen Tokenizer"),
                entryHash: Store.entryHash(entry),
                countedAt: start,
                wasKeyterm: true
            )]
        )

        // An empty store leaves nothing behind.
        TestSupport.expect(store.cancelCleanupCredit(entryID: entry), "The credit goes")
        TestSupport.expectEqual(store, Store())
    }

    private static func testRecordAccepted() {
        var store = Store()
        _ = store.apply(.learned([fix("whisper", "Wispr", ruleLater: false)]), from: observation(source: .runLog), now: start)
        let activity = store.activityLine
        store.recordAccepted(pasted: "whisper is a word", final: "whisper is a word", now: start + 1)
        TestSupport.expectEqual(store.items[0].variants[0].keptUnchanged, 1)
        TestSupport.expectEqual(store.counters["acceptedUnchanged"], 1)
        TestSupport.expectEqual(store.activityLine, activity)
        TestSupport.expectEqual(store.items[0].corrections, 1)
    }

    private static func testSearchStorage() {
        TestSupport.expectEqual(Store.Category(.coding, isGoogleSearch: false), .coding)
        TestSupport.expectEqual(Store.Category(nil, isGoogleSearch: false), .other)
        TestSupport.expectEqual(Store.Category(.other, isGoogleSearch: true), .search)
        TestSupport.expectEqual(Store.Category(.aiChat, isGoogleSearch: true), .search)

        var store = Store()
        let change = store.apply(
            .learned([fix("whisper", "wispr", ruleLater: false)]),
            from: observation(source: .googleSearch, category: .search),
            now: start
        )
        TestSupport.expect(change.hasLearned, "A strong search fix teaches the term")
        TestSupport.expectEqual(store.items[0].casingKnown, false)
        TestSupport.expectEqual(store.items[0].sources, [.googleSearch])
        TestSupport.expectEqual(store.items[0].categoryCounts, ["search": 1])
        TestSupport.expectEqual(store.items[0].mainCategory, .search)

        // One observation per dictation holds across sources.
        var counted = Store()
        let entry = UUID()
        let first = RunLogFix.apply(
            .learned([fix("whisper", "wispr", ruleLater: false)]),
            entryID: entry,
            observation: observation(source: .googleSearch, category: .search),
            to: &counted,
            now: start
        )
        TestSupport.expect(first?.hasLearned == true, "Signal A counts")
        let second = RunLogFix.apply(
            .learned([fix("flow", "Flo", ruleLater: false)]),
            entryID: entry,
            observation: observation(source: .googleSearch, category: .search),
            to: &counted,
            now: start + 1
        )
        TestSupport.expect(second == nil, "Signal B on the same entry is ignored")
        TestSupport.expectEqual(counted.items.count, 1)
    }

    // MARK: Sightings

    private static func knowledge(of store: Store) -> LearnerKnowledge {
        LearnerKnowledge(
            manualTerms: [],
            learnedTerms: store.termKeys,
            learnedRules: store.ruleKeys,
            tombstones: Set(store.tombstones)
        )
    }

    /// What the app does for one sighting, minus the word list and the thread hop.
    @discardableResult
    private static func sight(
        _ sighting: SentTextLearning.Sighting,
        paste: LearningPaste,
        final: String,
        store: inout Store,
        entry: UUID = UUID(),
        keyterms: [String] = [],
        now: Date
    ) -> SentTextLearning.Applied {
        let verdict = SentTextLearning.judge(
            sighting, paste: paste, final: final, knowledge: knowledge(of: store), lexicon: lexicon, confidences: [:]
        )
        return SentTextLearning.apply(verdict, entryID: entry, sentKeyterms: keyterms, to: &store, now: now)
    }

    private static func storeWithWhisper() -> Store {
        var store = Store()
        _ = store.apply(.learned([fix("whisper", "Wispr")]), from: observation(source: .runLog), now: start)
        return store
    }

    private static func testHookSightings() {
        // A prompt that changed the paste teaches, and a phrase it kept counts at once.
        var store = storeWithWhisper()
        var applied = sight(
            .hookPrompt, paste: paste("ask versel about whisper"), final: "ask Vercel about whisper", store: &store, now: start + 1
        )
        TestSupport.expectEqual(applied.code, "learned")
        TestSupport.expect(applied.change.learnedTerms.contains("Vercel"), "The fix is learned")
        TestSupport.expect(applied.touchedStore, "The store changed")
        TestSupport.expect(applied.keptSearch == nil, "A prompt holds nothing back")
        TestSupport.expectEqual(store.items.first { $0.text == "Wispr" }?.variants.first?.keptUnchanged, 1)

        // A prompt sent as pasted is accepted at once.
        store = storeWithWhisper()
        applied = sight(.hookPrompt, paste: paste("ask whisper about it"), final: "ask whisper about it", store: &store, now: start + 1)
        TestSupport.expectEqual(applied.code, "acceptedUnchanged")
        TestSupport.expectEqual(store.counters["acceptedUnchanged"], 1)
        TestSupport.expectEqual(store.items[0].variants[0].keptUnchanged, 1)

        // An entry a Fix already counted stays one observation, but its kept cleanup fix counts.
        var counted = Store()
        let entry = UUID()
        _ = RunLogFix.apply(
            .learned([fix("versel", "Vercel", ruleLater: false)]), entryID: entry,
            observation: observation(source: .runLog), to: &counted, now: start
        )
        applied = sight(
            .hookPrompt,
            paste: paste("Ask Claude Code about kwen.", raw: "ask cloud code about kwen"),
            final: "Ask Claude Code about Qwen.",
            store: &counted,
            entry: entry,
            now: start + 1
        )
        TestSupport.expectEqual(applied.code, "alreadyCounted")
        TestSupport.expect(!counted.items.contains { $0.text == "Qwen" }, "Not a second observation")
        TestSupport.expectEqual(counted.cleanupCredits?.count, 1)
    }

    /// The glue's dispatch over one watch, then its end, with invented queries.
    private static func search(
        _ pasted: String,
        raw: String? = nil,
        pressedEnter: Bool = false,
        then queries: [String],
        store: inout Store,
        entry: UUID = UUID(),
        keyterms: [String] = []
    ) -> [GoogleSearchWatch.Action] {
        var watched = paste(pasted, raw: raw, destination: .chrome)
        var watch = GoogleSearchWatch(entryID: entry, initialTitle: "Google - Google Chrome", pressedEnter: pressedEnter, now: start)
        var actions: [GoogleSearchWatch.Action] = []
        for (offset, query) in queries.enumerated() {
            let now = start + Double(offset + 1)
            let action = GoogleSearchWatch.action(
                for: watch.observe(title: "\(query) - Google Search - Google Chrome", now: now), paste: watched
            )
            actions.append(action)
            if case .end(let reason) = action {
                if reason.keepsEvidence, let kept = watch.keptSearch {
                    SentTextLearning.applyKept(kept, to: &store, now: now)
                }
                return actions
            }
            guard case .learn(let sighting, let final) = action else { continue }
            if case .nextResults = sighting {} else { watched.observed = true }
            watch.note(sight(sighting, paste: watched, final: final, store: &store, entry: entry, keyterms: keyterms, now: now))
        }
        if let kept = watch.keptSearch {
            SentTextLearning.applyKept(kept, to: &store, now: start + Double(queries.count + 1))
        }
        return actions
    }

    private static func testSearchSequences() {
        typealias Action = GoogleSearchWatch.Action
        // Send, then fix on the results page: the dictation that was corrected is not counter-
        // evidence, so the fix can still make a rule.
        var fixed = storeWithWhisper()
        var actions = search(
            "whisper flow pricing", then: ["whisper flow pricing", "wispr flow pricing"], store: &fixed, keyterms: ["Wispr"]
        )
        TestSupport.expectEqual(actions, [
            .learn(.firstResults, final: "whisper flow pricing"),
            .learn(.nextResults(previous: "whisper flow pricing"), final: "wispr flow pricing"),
        ])
        TestSupport.expectEqual(fixed.items[0].variants[0].keptUnchanged, 0)
        TestSupport.expectEqual(fixed.counters["acceptedUnchanged"], nil)
        TestSupport.expectEqual(fixed.items[0].variants[0].isRule, true)
        TestSupport.expectEqual(fixed.items[0].corrections, 2)

        // Sent unchanged with no fix: it counts as kept only when the watch ends.
        var kept = storeWithWhisper()
        var watched = paste("whisper flow pricing", destination: .chrome)
        watched.observed = true
        let held = sight(.firstResults, paste: watched, final: "whisper flow pricing", store: &kept, now: start + 1)
        TestSupport.expectEqual(held.code, "heldForWatchEnd")
        TestSupport.expect(!held.touchedStore, "Nothing is written yet")
        TestSupport.expectEqual(kept.items[0].variants[0].keptUnchanged, 0)
        TestSupport.expectEqual(held.keptSearch?.unchanged, true)
        _ = search("whisper flow pricing", then: ["whisper flow pricing"], store: &kept)
        TestSupport.expectEqual(kept.items[0].variants[0].keptUnchanged, 1)
        TestSupport.expectEqual(kept.counters["acceptedUnchanged"], 1)

        // A fix before Enter teaches at once, and its kept phrases wait for the watch's end.
        var before = storeWithWhisper()
        let firstFix = sight(.firstResults, paste: paste("whisper versel pricing", destination: .chrome), final: "whisper vercel pricing", store: &before, now: start + 1)
        TestSupport.expect(firstFix.change.hasLearned, "Signal A teaches")
        TestSupport.expectEqual(before.items[0].variants[0].keptUnchanged, 0)
        TestSupport.expectEqual(firstFix.keptSearch?.unchanged, false)
        if let keptSearch = firstFix.keptSearch {
            let accepted = before.counters["acceptedUnchanged"]
            SentTextLearning.applyKept(keptSearch, to: &before, now: start + 2)
            TestSupport.expectEqual(before.items[0].variants[0].keptUnchanged, 1)
            TestSupport.expectEqual(before.counters["acceptedUnchanged"], accepted)
        }

        // Words typed by hand later are not the paste's: only the paste counts as kept.
        var typed = storeWithWhisper()
        actions = search("pricing page", then: ["pricing page", "whisper pricing", "whisper pricing page"], store: &typed)
        TestSupport.expectEqual(actions.count, 3)
        TestSupport.expectEqual(typed.items[0].variants[0].keptUnchanged, 0)
        TestSupport.expectEqual(typed.counters["acceptedUnchanged"], 1)

        // An unrelated next query changes nothing at all.
        var unrelated = storeWithWhisper()
        let beforeUnrelated = unrelated
        let quiet = sight(
            .nextResults(previous: "synthetic parser docs"),
            paste: paste("synthetic parser docs", destination: .chrome),
            final: "weather in a made up town",
            store: &unrelated,
            now: start + 1
        )
        TestSupport.expect(!quiet.touchedStore, "The store is not written")
        TestSupport.expect(!quiet.voidsKeptSearch, "The paste's words were not changed")
        TestSupport.expectEqual(unrelated, beforeUnrelated)

        // Only the first results keep cleanup fixes: Signal B comes after that observation.
        let cleaned = paste("pricing for Claude Code", raw: "um pricing for cloud code", destination: .chrome)
        func fixes(_ sighting: SentTextLearning.Sighting) -> [String] {
            SentTextLearning.judge(
                sighting, paste: cleaned, final: "pricing for Claude Code", knowledge: knowledge(of: Store()),
                lexicon: lexicon, confidences: [:]
            ).fixes.map(\.term)
        }
        TestSupport.expectEqual(fixes(.firstResults), ["Claude Code"])
        TestSupport.expectEqual(fixes(.firstResultsAfterEnter), ["Claude Code"])
        TestSupport.expectEqual(fixes(.hookPrompt), ["Claude Code"])
        TestSupport.expectEqual(fixes(.nextResults(previous: "pricing for cloud code")), [])

        // Signal B teaches only words of the paste, and only one observation per dictation.
        var handTyped = Store()
        let typedFix = sight(
            .nextResults(previous: "whisper flow pricing"),
            paste: paste("flow pricing page", destination: .chrome),
            final: "wispr flow pricing",
            store: &handTyped,
            now: start + 1
        )
        TestSupport.expect(!typedFix.touchedStore, "The fixed word was typed by hand")
        TestSupport.expectEqual(handTyped, Store())

        // A window that turned private and a search that is not the paste keep nothing.
        TestSupport.expect(!GoogleSearchWatch.EndReason.privateWindow.keepsEvidence, "Private window")
        TestSupport.expect(!GoogleSearchWatch.EndReason.notThePaste.keepsEvidence, "Not the paste")
        TestSupport.expect(GoogleSearchWatch.EndReason.timeout.keepsEvidence, "A quiet timeout")
    }

    /// W11 with the glue: FreeFlow pressed Enter, so the first results teach no edit, but a
    /// cleanup fix they hold counts, over three dictations.
    private static func testPressedEnterCreditsCleanupFixes() {
        var store = Store()
        let raw = "um pricing for cloud code", pasted = "pricing for Claude Code"
        for dictation in 1...3 {
            let actions = search(pasted, raw: raw, pressedEnter: true, then: [pasted], store: &store)
            TestSupport.expectEqual(actions, [.learn(.firstResultsAfterEnter, final: pasted)])
            TestSupport.expectEqual(store.cleanupCredits?.count, dictation == 3 ? nil : dictation)
        }
        TestSupport.expectEqual(store.items.map(\.text), ["Claude Code"])
        TestSupport.expectEqual(store.items[0].sources, [.cleanup])
        TestSupport.expectEqual(store.items[0].corrections, 3)

        // No source learning, even if the title differs from the paste.
        var noEdit = Store()
        let applied = sight(
            .firstResultsAfterEnter, paste: paste("use versel today", destination: .chrome), final: "use Vercel today",
            store: &noEdit, now: start + 1
        )
        TestSupport.expect(!applied.touchedStore, "FreeFlow pressed Enter: nothing the user edited")
        TestSupport.expectEqual(noEdit, Store())

        // A results title that does not hold the paste ends the watch and starts no chain.
        var other = Store()
        let actions = search(pasted, raw: raw, pressedEnter: true, then: ["weather in a made up town", pasted], store: &other)
        TestSupport.expectEqual(actions, [.end(.notThePaste)])
        TestSupport.expectEqual(other, Store())
    }

    /// Undo AI edit: the credit goes, and the same dictation teaches nothing further.
    private static func testCancelStopsLearning() {
        let entry = UUID()
        var ring = DictationRecordRing()
        ring.append(record(id: entry, paste: paste("Ask Claude Code about it.", raw: "ask cloud code about it")), now: start)
        var store = Store()
        credit(&store, entry: entry, at: start + 1)

        TestSupport.expect(SentTextLearning.cancel(entryID: entry, records: &ring, store: &store), "The credit is cancelled")
        TestSupport.expectEqual(store.cleanupCredits, nil)
        TestSupport.expectEqual(ring.pastes(into: .vsCode, now: start + 2).map(\.id), [])
        TestSupport.expectEqual(
            GoogleSearchWatch.action(for: .signalA(query: "Ask Claude Code about it"), paste: ring.record(id: entry, now: start + 2)?.paste),
            .end(.notThePaste)
        )
        TestSupport.expect(!SentTextLearning.cancel(entryID: entry, records: &ring, store: &store), "Nothing is left to cancel")
    }

    /// A dictation into the address bar or a New Tab has no domain but arms the watch, so a rule
    /// learned from a search, whose casing is unknown, applies there too.
    private static func testSearchSurfaceAppliesSearchRules() {
        var store = Store()
        _ = store.apply(
            .learned([fix("versel", "vercel", ruleNow: true, ruleLater: false)]),
            from: observation(source: .googleSearch, category: .search),
            now: start
        )
        func rules(windowTitle: String?, domain: String?) -> [String] {
            let category = Store.Category(
                .other,
                isGoogleSearch: GoogleSearchTitle.isSearchSurface(
                    bundleIdentifier: "com.google.Chrome", websiteDomain: domain, windowTitle: windowTitle
                )
            )
            return EffectiveVocabulary.merge(
                manualVocabulary: "", manualCorrections: [], learned: store, category: category, now: start
            ).corrections.map(\.from)
        }
        TestSupport.expectEqual(rules(windowTitle: "New Tab - Google Chrome", domain: nil), ["versel"])
        TestSupport.expectEqual(rules(windowTitle: "Google - Pinned - Google Chrome", domain: nil), ["versel"])
        TestSupport.expectEqual(rules(windowTitle: "wispr flow - Google Search - Google Chrome", domain: nil), ["versel"])
        TestSupport.expectEqual(rules(windowTitle: "Synthetic Site - Google Chrome", domain: nil), [])
        TestSupport.expectEqual(rules(windowTitle: "Google - Google Chrome", domain: "example.com"), [])
    }

    // MARK: Provider-neutral evidence

    private final class StubKeytermSession: KeytermStreamingSession {
        var transcriptionSource = "stub"
        func start() throws {}
        func appendPCM16(_ data: Data) {}
        func commitAndAwaitFinal() async throws -> String { "" }
        func cancel() {}
        func setRecorderHeardSpeech(_ heardSpeech: Bool) {}
        var acceptsKeytermUpdates: Bool { true }
        func updateKeyterms(screenTerms: [String], identifiers: [String]) {}
        var keytermReport: DeepgramStreamingCore.KeytermReport {
            DeepgramStreamingCore.KeytermReport(connectCount: 0, screenCount: nil, identifierCount: nil, audioMillisecondsBeforeUpdate: nil)
        }
        var learningEvidence: (words: [DeepgramStreamingCore.RecognizedWord], keyterms: [String]) {
            ([DeepgramStreamingCore.RecognizedWord(word: "sonny", punctuatedWord: "Sonny.", confidence: 0.5)], ["Vercel"])
        }
    }

    private final class StubPlainSession: StreamingTranscriptionSession {
        var transcriptionSource = "stub"
        func start() throws {}
        func appendPCM16(_ data: Data) {}
        func commitAndAwaitFinal() async throws -> String { "" }
        func cancel() {}
    }

    private static func testEvidenceGate() {
        let session = StubKeytermSession()
        for source in [
            PipelineStageTimings.deepgramTranscriptionSource, "deepgram-final", "deepgram-final+partial-tail",
            "assemblyai-final", "assemblyai-final+partial-tail", PipelineStageTimings.assemblyAITranscriptionSource,
        ] {
            let evidence = StreamingTranscriptionProvider.learningEvidence(from: session, transcriptionSource: source)
            TestSupport.expectEqual(evidence?.keyterms, ["Vercel"])
            TestSupport.expectEqual(evidence?.words.first?.word, "sonny")
        }
        for source in [
            PipelineStageTimings.fileTranscriptionSource,
            PipelineStageTimings.fileFallbackTranscriptionSource,
            PipelineStageTimings.fileFallbackSource(reason: "AssemblyAI rejected the API key"),
            PipelineStageTimings.realtimeTranscriptionSource,
        ] {
            TestSupport.expect(
                StreamingTranscriptionProvider.learningEvidence(from: session, transcriptionSource: source) == nil,
                "A file or realtime transcript gets no stream evidence"
            )
        }
        TestSupport.expect(
            StreamingTranscriptionProvider.learningEvidence(from: nil, transcriptionSource: "assemblyai-final") == nil,
            "No session"
        )
        TestSupport.expect(
            StreamingTranscriptionProvider.learningEvidence(from: StubPlainSession(), transcriptionSource: "assemblyai-final") == nil,
            "A session without keyterms"
        )

        // The real Deepgram session through the same gate, with no socket. AssemblyAI's frames
        // are tested in AssemblyAIStreamingCoreTests.
        let deepgram = DeepgramStreamingService(config: DeepgramStreamingCore.Configuration(
            apiKey: "synthetic-key", language: "en", sampleRate: 16000, keyterms: ["Vercel"]
        ))
        let evidence = StreamingTranscriptionProvider.learningEvidence(from: deepgram, transcriptionSource: "deepgram-final")
        TestSupport.expectEqual(evidence?.keyterms, ["Vercel"])
        TestSupport.expectEqual(evidence?.words, [])
        TestSupport.expect(
            StreamingTranscriptionProvider.learningEvidence(
                from: deepgram, transcriptionSource: PipelineStageTimings.fileTranscriptionSource
            ) == nil,
            "A file transcript gets no Deepgram evidence"
        )
    }

    private static func testConfidencesOverAssemblyAIWords() {
        let frame = #"""
        {"type":"Turn","turn_order":0,"end_of_turn":true,"transcript":"Ask Sonny. Sonny, Vercel","words":[
          {"text":"Ask","confidence":0.9,"start":0,"end":1},
          {"text":"Sonny.","confidence":0.6,"start":1,"end":2},
          {"text":"Sonny,","confidence":0.4,"start":2,"end":3},
          {"text":"Vercel","confidence":0.99,"start":3,"end":4}
        ]}
        """#
        let words = AssemblyAIStreamingCore.finalTurnWords(in: Data(frame.utf8))?.words ?? []
        let record = DictationRecord(id: UUID(), createdAt: start, words: words, keyterms: ["Vercel"])
        TestSupport.expectEqual(record.confidences(), ["ask": 0.9, "sonny": 0.4])
        // The keys are the learner's token folds.
        for word in words {
            TestSupport.expectEqual(CorrectionLearner.tokens(word.punctuatedWord).first?.fold, word.word)
        }
        let edgeWords = #"…“Hello”.,;:!?"'()[]{}<>`*#>~"#
        let token = CorrectionLearner.tokens(edgeWords).first
        let edgeFrameObject: [String: Any] = [
            "type": "Turn", "turn_order": 1, "end_of_turn": true,
            "words": [["text": edgeWords, "confidence": 0.5] as [String: Any]],
        ]
        let edgeFrame = try? JSONSerialization.data(withJSONObject: edgeFrameObject)
        TestSupport.expectEqual(
            edgeFrame.flatMap { AssemblyAIStreamingCore.finalTurnWords(in: $0)?.words.first?.word },
            token?.fold
        )
    }
}
