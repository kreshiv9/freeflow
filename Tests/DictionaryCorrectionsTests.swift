import Foundation

enum DictionaryCorrectionsTests {
    static func run() {
        testWholeWordBoundaries()
        testOutputKeepsSavedCasing()
        testMultiWordRule()
        testLongestRuleWinsOnOverlap()
        testRuleNeverReappliesToOwnOutput()
        testUnicodeLetters()
        testPunctuationAndSpacingPreserved()
        testUnusableRulesAreIgnored()
        testSnippetPlaceholdersAreNeverRewritten()
        testWordBoundedTextScan()
        testPersistenceRoundTrip()
        testFieldLimits()
        testVocabularyText()
    }

    private static func rule(_ from: String, _ to: String) -> DictionaryCorrection {
        DictionaryCorrection(from: from, to: to)
    }

    private static func apply(_ rules: [DictionaryCorrection], _ text: String) -> String {
        DictionaryCorrection.apply(rules, to: text)
    }

    /// Letters, digits, underscores and CJK neighbours block a hit; punctuation and
    /// whitespace neighbours allow it.
    private static func testWholeWordBoundaries() {
        let sig = [rule("sig", "Sig")]
        TestSupport.expectEqual(
            apply(sig, "sig signature sig_2 sig5 (sig) sig. 日本sig"),
            "Sig signature sig_2 sig5 (Sig) Sig. 日本sig"
        )
        TestSupport.expectEqual(apply([rule("cloud", "Claude")], "cloud\nnext"), "Claude\nnext")
    }

    private static func testOutputKeepsSavedCasing() {
        TestSupport.expectEqual(apply([rule("cloud", "Claude")], "CLOUD cloud Cloud"), "Claude Claude Claude")
        TestSupport.expectEqual(
            apply([rule("cloud core", "Claude Code")], "Cloud Core and CLOUD CORE"),
            "Claude Code and Claude Code"
        )
        TestSupport.expectEqual(apply([rule("claude", "Claude")], "claude said"), "Claude said")
    }

    private static func testMultiWordRule() {
        let rules = [rule("cloud core", "Claude Code")]
        TestSupport.expectEqual(apply(rules, "open cloud core now"), "open Claude Code now")
        TestSupport.expectEqual(apply(rules, "cloud and core"), "cloud and core")
        TestSupport.expectEqual(apply(rules, "cloud  core"), "cloud  core")
        TestSupport.expectEqual(apply(rules, "cloud core first"), "Claude Code first")
        TestSupport.expectEqual(apply(rules, "last cloud core"), "last Claude Code")
    }

    private static func testLongestRuleWinsOnOverlap() {
        let short = rule("cloud", "Claude")
        let long = rule("cloud core", "Claude Code")
        for rules in [[short, long], [long, short]] {
            TestSupport.expectEqual(apply(rules, "cloud core and cloud"), "Claude Code and Claude")
        }
        TestSupport.expectEqual(apply([rule("sig", "First"), rule("sig", "Second")], "sig"), "First")
    }

    private static func testRuleNeverReappliesToOwnOutput() {
        let code = [rule("code", "Claude Code")]
        let once = apply(code, "code review")
        TestSupport.expectEqual(once, "Claude Code review")
        TestSupport.expectEqual(apply(code, once), once)
        TestSupport.expectEqual(apply(code, "Claude Code review"), "Claude Code review")
        TestSupport.expectEqual(apply(code, "Claude Code and code"), "Claude Code and Claude Code")

        let doubling = [rule("x", "x x")]
        TestSupport.expectEqual(apply(doubling, "x"), "x x")
        TestSupport.expectEqual(apply(doubling, "x x"), "x x")

        let gpt = [rule("gpt", "GPT-4")]
        TestSupport.expectEqual(apply(gpt, "gpt"), "GPT-4")
        TestSupport.expectEqual(apply(gpt, "GPT-4"), "GPT-4")

        // Known limit of the own-output guard: when `to` is a whole-word sub-phrase of
        // `from`, the output still contains a fresh `from`, so a second pass (the one on
        // cleaned output) collapses one more repeat. Pinned so the behavior is explicit.
        let stutter = [rule("the the", "the")]
        let collapsedOnce = apply(stutter, "the the the")
        TestSupport.expectEqual(collapsedOnce, "the the")
        TestSupport.expectEqual(apply(stutter, collapsedOnce), "the")
        TestSupport.expectEqual(apply(stutter, "the the"), "the")
        TestSupport.expectEqual(apply(stutter, "the"), "the")

        // One pass over the original text: the second rule never sees the first rule's output.
        TestSupport.expectEqual(apply([rule("cloud", "Claude Code"), rule("code", "X")], "cloud code"), "Claude Code X")
    }

    private static func testUnicodeLetters() {
        let munich = [rule("münchen", "München")]
        TestSupport.expectEqual(apply(munich, "MÜNCHEN"), "München")
        TestSupport.expectEqual(apply(munich, "münchen"), "München")

        let cafe = [rule("café", "Café")]
        TestSupport.expectEqual(apply(cafe, "cafe"), "cafe")
        TestSupport.expectEqual(apply(cafe, "caf\u{E9}"), "Café")
        TestSupport.expectEqual(apply(cafe, "cafe\u{301}"), "Café")

        TestSupport.expectEqual(apply([rule("naïve", "naive")], "Naïve naïvely"), "naive naïvely")
        TestSupport.expectEqual(apply([rule("über", "Uber")], "über-cool"), "Uber-cool")
        TestSupport.expectEqual(apply([rule("日本", "Japan")], "日本 語"), "Japan 語")
    }

    private static func testPunctuationAndSpacingPreserved() {
        let sig = [rule("sig", "Sig")]
        TestSupport.expectEqual(apply(sig, "Hello,  sig!\nBye"), "Hello,  Sig!\nBye")
        TestSupport.expectEqual(apply(sig, ""), "")
        TestSupport.expectEqual(apply(sig, "Nothing to change here."), "Nothing to change here.")
    }

    private static func testUnusableRulesAreIgnored() {
        TestSupport.expectEqual(apply([rule("", "Sig")], "sig"), "sig")
        TestSupport.expectEqual(apply([rule("   ", "Sig")], "sig"), "sig")
        TestSupport.expectEqual(apply([rule("sig", "")], "sig"), "sig")
        TestSupport.expectEqual(apply([rule("  sig ", "Sig")], "sig"), "Sig")

        TestSupport.expect(!rule("", "").isUsable && rule("", "").isBlank, "An empty row is blank and unusable")
        TestSupport.expect(!rule("a", "").isUsable && !rule("a", "").isBlank, "A half-filled row is neither")
        TestSupport.expect(!rule("", "b").isUsable && !rule("", "b").isBlank, "A half-filled row is neither")
        TestSupport.expect(rule("a", "b").isUsable && !rule("a", "b").isBlank, "A full row is usable")
    }

    /// The second pass runs on cleaned output that still holds snippet placeholders;
    /// the brackets count as word characters so a rule can never rewrite a token.
    private static func testSnippetPlaceholdersAreNeverRewritten() {
        TestSupport.expect(
            WordBoundedText.isWordCharacter("\u{27E6}") && WordBoundedText.isWordCharacter("\u{27E7}"),
            "Placeholder brackets must block a boundary"
        )
        let rules = [rule("s1", "x"), rule("s", "y")]
        TestSupport.expectEqual(apply(rules, "a ⟦S1⟧ b"), "a ⟦S1⟧ b")
        TestSupport.expectEqual(apply(rules, "s1 ⟦S1⟧ s ⟦s2⟧ S1"), "x ⟦S1⟧ y ⟦s2⟧ x")
        TestSupport.expectEqual(apply([rule("a s1", "z")], "a ⟦S1⟧"), "a ⟦S1⟧")

        let plan = SnippetExpansion.plan(
            for: "say sig now",
            snippets: [SnippetExpansion.Snippet(trigger: "sig", expansion: "Synthetic expansion")]
        )
        TestSupport.expectEqual(plan.resolve(apply(rules, "Say ⟦S1⟧ now.")), "Say Synthetic expansion now.")
    }

    /// The shared matcher: Character offsets, one left-to-right scan that resumes after
    /// an accepted hit, longest phrase first with the lowest index breaking ties.
    private static func testWordBoundedTextScan() {
        typealias Match = WordBoundedText.Match

        TestSupport.expectEqual(
            WordBoundedText("日本 x").matches(ofPhrases: ["x"]),
            [Match(range: 3..<4, phraseIndex: 0)]
        )
        TestSupport.expectEqual(WordBoundedText("a").matches(ofPhrases: [""]), [])
        TestSupport.expectEqual(
            WordBoundedText("a a a").matches(ofPhrases: ["a a"]),
            [Match(range: 0..<3, phraseIndex: 0)]
        )
        // An overlap rejection never hides a later legitimate hit.
        TestSupport.expectEqual(
            WordBoundedText("go now now now").matches(ofPhrases: ["go now", "now now"]),
            [Match(range: 0..<6, phraseIndex: 0), Match(range: 7..<14, phraseIndex: 1)]
        )
        TestSupport.expectEqual(
            WordBoundedText("AB").matches(ofPhrases: ["a", "ab"]),
            [Match(range: 0..<2, phraseIndex: 1)]
        )
        TestSupport.expectEqual(
            WordBoundedText("ab").matches(ofPhrases: ["ab", "ab"]),
            [Match(range: 0..<2, phraseIndex: 0)]
        )
        TestSupport.expectEqual(
            WordBoundedText("a b c").replacing([(range: 0..<1, text: "X"), (range: 4..<5, text: "Z")]),
            "X b Z"
        )
    }

    private static func testPersistenceRoundTrip() {
        let suite = "FreeFlowTests.DictionaryCorrections.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(DictionaryCorrection.storageKey, "dictionary_corrections")
        TestSupport.expectEqual(DictionaryCorrection.load(from: defaults), [])
        TestSupport.expect(
            defaults.object(forKey: DictionaryCorrection.storageKey) == nil,
            "Loading an absent key must not persist anything"
        )

        let saved = [
            DictionaryCorrection(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, from: "cloud", to: "Claude"),
            DictionaryCorrection(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, from: "cloud core", to: "Claude Code")
        ]
        DictionaryCorrection.save(saved, to: defaults)
        TestSupport.expectEqual(DictionaryCorrection.load(from: UserDefaults(suiteName: suite)!), saved)

        defaults.set("not data", forKey: DictionaryCorrection.storageKey)
        TestSupport.expectEqual(DictionaryCorrection.load(from: defaults), [])
        defaults.set(Data("garbage".utf8), forKey: DictionaryCorrection.storageKey)
        TestSupport.expectEqual(DictionaryCorrection.load(from: defaults), [])

        let longField = String(repeating: "a", count: 70)
        let json = "[{\"id\":\"00000000-0000-0000-0000-000000000003\",\"from\":\"\(longField)\",\"to\":\"b\"}]"
        defaults.set(Data(json.utf8), forKey: DictionaryCorrection.storageKey)
        let loaded = DictionaryCorrection.load(from: defaults)
        TestSupport.expectEqual(loaded.map(\.from), [String(repeating: "a", count: 60)])
        TestSupport.expectEqual(loaded.map(\.to), ["b"])
    }

    private static func testFieldLimits() {
        TestSupport.expectEqual(DictionaryCorrection.maxFieldLength, 60)
        TestSupport.expectEqual(DictionaryCorrection.normalizedField("  cloud\n"), "cloud")
        let sixty = String(repeating: "a", count: 60)
        TestSupport.expectEqual(DictionaryCorrection.normalizedField(sixty + "b"), sixty)
        TestSupport.expectEqual(DictionaryCorrection.normalizedField(sixty), sixty)
        let fiftyNine = String(repeating: "a", count: 59)
        TestSupport.expectEqual(DictionaryCorrection.normalizedField(fiftyNine + " b"), fiftyNine)
        TestSupport.expectEqual(DictionaryCorrection.normalizedField("   "), "")
    }

    private static func testVocabularyText() {
        let rules = [rule("cloud", "Claude Code"), rule("x", "")]
        TestSupport.expectEqual(DictionaryCorrection.vocabularyText("Foo, Bar", merging: rules), "Foo, Bar\nClaude Code")
        TestSupport.expectEqual(DictionaryCorrection.vocabularyText("", merging: rules), "Claude Code")
        TestSupport.expectEqual(DictionaryCorrection.vocabularyText("Foo, Bar", merging: [rule("x", "")]), "Foo, Bar")
        TestSupport.expectEqual(DictionaryCorrection.vocabularyText("Foo, Bar", merging: []), "Foo, Bar")
    }
}
