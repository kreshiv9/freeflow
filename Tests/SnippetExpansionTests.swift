import Foundation

enum SnippetExpansionTests {
    static func run() {
        testTriggerAloneMatchesWholeText()
        testTriggerInsideSentenceWithPunctuation()
        testWordBoundaryRejection()
        testLongestTriggerWinsAndScanResumes()
        testMultipleTriggersInOrder()
        testResolveRoundTrip()
        testResolveMissingPlaceholderReturnsNil()
        testResolveDuplicatedOrUnknownPlaceholderReturnsNil()
        testNoMatchesPassThrough()
        testExpansionLimitAndIneligibleTriggers()
        testPinnedStrings()
    }

    private static let signature = "Synthetic signature block"
    private static let regards = "Synthetic regards"
    private static let street = "Synthetic street 1"

    private static let fixtures = [
        SnippetExpansion.Snippet(trigger: "sig", expansion: signature),
        SnippetExpansion.Snippet(trigger: "my sig", expansion: regards),
        SnippetExpansion.Snippet(trigger: "addr", expansion: street)
    ]

    private static func plan(
        _ text: String,
        _ snippets: [SnippetExpansion.Snippet] = SnippetExpansionTests.fixtures
    ) -> SnippetExpansionPlan {
        SnippetExpansion.plan(for: text, snippets: snippets)
    }

    private static func testTriggerAloneMatchesWholeText() {
        let alone = plan("sig")
        TestSupport.expectEqual(alone.placeholderText, "⟦S1⟧")
        TestSupport.expectEqual(alone.expansions, [signature])
        TestSupport.expectEqual(alone.expandedText, signature)
        // The whole-transcript macro path in AppState runs first, ignores punctuation
        // and would already have returned the bare payload; the planner keeps the dot.
        TestSupport.expectEqual(plan("Sig.").placeholderText, "⟦S1⟧.")
    }

    private static func testTriggerInsideSentenceWithPunctuation() {
        let result = plan("Send my sig, then sig! and addr.")
        TestSupport.expectEqual(result.placeholderText, "Send ⟦S1⟧, then ⟦S2⟧! and ⟦S3⟧.")
        TestSupport.expectEqual(result.expansions, [regards, signature, street])
        TestSupport.expectEqual(result.expandedText, "Send \(regards), then \(signature)! and \(street).")
        TestSupport.expectEqual(plan("SIG").expandedText, signature)
    }

    private static func testWordBoundaryRejection() {
        let input = "my signature and sigs and sig_2 and resig and sig5 and 日本sig"
        let rejected = plan(input)
        TestSupport.expect(!rejected.hasMatches, "A trigger must not match inside a word")
        TestSupport.expectEqual(rejected.placeholderText, input)
        for text in ["(sig)", "sig?", "\"sig\""] {
            TestSupport.expect(plan(text).hasMatches, "Punctuation next to a trigger must not block it: \(text)")
        }
    }

    private static func testLongestTriggerWinsAndScanResumes() {
        TestSupport.expectEqual(plan("MY SIG").expansions, [regards])

        let goNow = [
            SnippetExpansion.Snippet(trigger: "go now", expansion: "Synthetic go"),
            SnippetExpansion.Snippet(trigger: "now now", expansion: "Synthetic now")
        ]
        TestSupport.expectEqual(plan("go now now now", goNow).placeholderText, "⟦S1⟧ ⟦S2⟧")

        let duplicates = [
            SnippetExpansion.Snippet(trigger: "sig", expansion: "Synthetic first"),
            SnippetExpansion.Snippet(trigger: "sig", expansion: "Synthetic second")
        ]
        TestSupport.expectEqual(plan("sig", duplicates).expansions, ["Synthetic first"])
    }

    private static func testMultipleTriggersInOrder() {
        let result = plan("sig then addr then sig")
        TestSupport.expectEqual(result.placeholderText, "⟦S1⟧ then ⟦S2⟧ then ⟦S3⟧")
        TestSupport.expectEqual(result.expansions, [signature, street, signature])
    }

    private static func testResolveRoundTrip() {
        let result = plan("Send my sig, then sig! and addr.")
        TestSupport.expectEqual(result.resolve(result.placeholderText), result.expandedText)
        TestSupport.expectEqual(result.resolve("⟦S2⟧ and ⟦S1⟧, ⟦S3⟧"), "\(signature) and \(regards), \(street)")
        TestSupport.expectEqual(result.resolve("⟦s1⟧ ⟦s2⟧ ⟦s3⟧"), "\(regards) \(signature) \(street)")

        // A single pass: an expansion that itself holds a token is never re-substituted.
        let nested = [
            SnippetExpansion.Snippet(trigger: "sig", expansion: "see ⟦S2⟧ there"),
            SnippetExpansion.Snippet(trigger: "addr", expansion: street)
        ]
        let nestedPlan = plan("sig and addr", nested)
        TestSupport.expectEqual(nestedPlan.resolve(nestedPlan.placeholderText), "see ⟦S2⟧ there and \(street)")
    }

    private static func testResolveMissingPlaceholderReturnsNil() {
        let three = plan("sig then addr then sig")
        TestSupport.expect(three.resolve("⟦S1⟧ then ⟦S2⟧ then") == nil, "A missing placeholder must not resolve")
        let one = plan("sig")
        TestSupport.expect(one.resolve("Thanks!") == nil, "Text without the placeholder must not resolve")
        TestSupport.expect(one.resolve("") == nil, "Empty output must not resolve")
    }

    private static func testResolveDuplicatedOrUnknownPlaceholderReturnsNil() {
        let three = plan("sig then addr then sig")
        TestSupport.expect(three.resolve("⟦S1⟧ ⟦S1⟧ ⟦S2⟧ ⟦S3⟧") == nil, "A duplicated placeholder must not resolve")
        TestSupport.expect(three.resolve("⟦S1⟧ ⟦S2⟧ ⟦S3⟧ ⟦S4⟧") == nil, "An unknown placeholder must not resolve")
        TestSupport.expect(three.resolve("⟦S0⟧ ⟦S1⟧ ⟦S2⟧ ⟦S3⟧") == nil, "Index zero must not resolve")
    }

    private static func testNoMatchesPassThrough() {
        let result = plan("hello there")
        TestSupport.expect(!result.hasMatches, "Text without a trigger has no matches")
        TestSupport.expectEqual(result.expansions, [])
        TestSupport.expectEqual(result.placeholderText, "hello there")
        TestSupport.expectEqual(result.expandedText, "hello there")
        TestSupport.expectEqual(result.resolve("Hello there."), "Hello there.")
    }

    private static func testExpansionLimitAndIneligibleTriggers() {
        TestSupport.expectEqual(SnippetExpansion.maxExpansionLength, 4000)
        let atLimit = String(repeating: "x", count: 4000)
        let overLimit = String(repeating: "x", count: 4001)
        TestSupport.expectEqual(
            plan("sig", [SnippetExpansion.Snippet(trigger: "sig", expansion: atLimit)]).expandedText,
            atLimit
        )
        let skipped = plan("say sig now", [SnippetExpansion.Snippet(trigger: "sig", expansion: overLimit)])
        TestSupport.expect(!skipped.hasMatches, "An oversize expansion is skipped, never cut")
        TestSupport.expectEqual(skipped.expandedText, "say sig now")

        for trigger in ["", "   ", ".", "..."] {
            let result = plan("say . now...", [SnippetExpansion.Snippet(trigger: trigger, expansion: "Synthetic")])
            TestSupport.expect(!result.hasMatches, "Trigger \"\(trigger)\" must never fire")
        }
        TestSupport.expectEqual(
            plan("say sig now", [SnippetExpansion.Snippet(trigger: "  sig ", expansion: "Synthetic")]).expandedText,
            "say Synthetic now"
        )
    }

    private static func testPinnedStrings() {
        TestSupport.expectEqual(SnippetExpansion.placeholder(1), "⟦S1⟧")
        TestSupport.expectEqual(SnippetExpansion.placeholder(7), "⟦S7⟧")
        TestSupport.expectEqual(
            SnippetExpansion.cleanupInstruction,
            "Keep every ⟦…⟧ token exactly as written, in place; never remove, reorder or reword them."
        )
        TestSupport.expectEqual(SnippetExpansion.statusSuffix(expandedCount: 0), "")
        TestSupport.expectEqual(SnippetExpansion.statusSuffix(expandedCount: 1), ", 1 snippet expanded")
        TestSupport.expectEqual(SnippetExpansion.statusSuffix(expandedCount: 2), ", 2 snippets expanded")
    }
}
