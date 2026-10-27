import Foundation

/// Synthetic text only. The stop path that passes the fitted text to the pasteboard
/// and the Accessibility insert needs live capture and is covered by the manual test.
enum CursorFormattingTests {
    static func run() {
        testSentenceStart()
        testContinuation()
        testProtectedFirstWords()
        testCJKJoining()
        testTrailingContinuation()
        testTrailingNewSentence()
        testMultiLineTranscript()
        testUnknownSidesAreUntouched()
        testSnapshotWrapper()
        testVocabularyTerms()
        testAppliesOnlyToPlainDictation()
        testDefaultAndStorage()
        testRunLogStatusSuffix()
    }

    private struct Row {
        let name: String
        let transcript: String
        let before: String?
        let after: String?
        var keep: Set<String> = []
        let expected: CursorFormatting.Adjustment
    }

    private static func check(_ rows: [Row]) {
        for row in rows {
            let actual = CursorFormatting.adjust(row.transcript, before: row.before, after: row.after, keepCapitalized: row.keep)
            TestSupport.expect(actual == row.expected, "\(row.name): expected \(row.expected), got \(actual)")
            TestSupport.expect(actual.changedAnything == row.expected.changedAnything, row.name)
        }
    }

    private static func testSentenceStart() {
        check([
            Row(name: "empty field", transcript: "hello there", before: "", after: "",
                expected: .init(text: "Hello there", changedCasing: true)),
            Row(name: "after a period", transcript: "next step", before: "Done.", after: nil,
                expected: .init(text: " Next step", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "after a period and a space", transcript: "next step", before: "Done. ", after: nil,
                expected: .init(text: "Next step", changedCasing: true)),
            Row(name: "after a newline", transcript: "second line", before: "First line\n", after: nil,
                expected: .init(text: "Second line", changedCasing: true)),
            Row(name: "after an opening quote", transcript: "hello", before: "He said “", after: nil,
                expected: .init(text: "Hello", changedCasing: true)),
            Row(name: "after an opening straight quote", transcript: "hello", before: "He said \"", after: nil,
                expected: .init(text: "Hello", changedCasing: true)),
            Row(name: "after a straight quote inside a bracket", transcript: "see below", before: "Note (\"", after: nil,
                expected: .init(text: "See below", changedCasing: true)),
            Row(name: "after a lone straight quote", transcript: "hello", before: "'", after: nil,
                expected: .init(text: "Hello", changedCasing: true)),
            Row(name: "after an opening bracket", transcript: "see below", before: "Note (", after: nil,
                expected: .init(text: "See below", changedCasing: true)),
            Row(name: "after an exclamation mark", transcript: "next step", before: "Done!", after: nil,
                expected: .init(text: " Next step", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "after a question mark", transcript: "next step", before: "Really?", after: nil,
                expected: .init(text: " Next step", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "Latin after a fullwidth exclamation mark", transcript: "next", before: "好！", after: nil,
                expected: .init(text: " Next", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "already capitalized after a period", transcript: "Next step", before: "Done.", after: nil,
                expected: .init(text: " Next step", addedLeadingSpace: true)),
            Row(name: "CamelCase name after a period", transcript: "iPhone 15 is out", before: "Done.", after: nil,
                expected: .init(text: " iPhone 15 is out", addedLeadingSpace: true)),
            Row(name: "CamelCase name at the field start", transcript: "macOS is out", before: "", after: nil,
                expected: .init(text: "macOS is out")),
            Row(name: "lowercase vocabulary term at the field start", transcript: "ollama is running", before: "", after: nil,
                keep: ["ollama"], expected: .init(text: "ollama is running")),
            Row(name: "lowercase vocabulary term possessive at the field start", transcript: "ollama's model", before: "",
                after: nil, keep: ["ollama"], expected: .init(text: "ollama's model")),
            Row(name: "capitalized vocabulary term still capitalizes", transcript: "ollama is running", before: "",
                after: nil, keep: ["Ollama"], expected: .init(text: "Ollama is running", changedCasing: true)),
            Row(name: "no vocabulary at the field start", transcript: "ollama is running", before: "", after: nil,
                expected: .init(text: "Ollama is running", changedCasing: true))
        ])
    }

    private static func testContinuation() {
        check([
            Row(name: "after a word", transcript: "Then we left.", before: "We went home and", after: nil,
                expected: .init(text: " then we left.", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "after a word and a space", transcript: "Then we left.", before: "We went home and ", after: nil,
                expected: .init(text: "then we left.", changedCasing: true)),
            Row(name: "after a comma", transcript: "We left", before: "Yes,", after: nil,
                expected: .init(text: " we left", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "after a semicolon", transcript: "Then", before: "first;", after: nil,
                expected: .init(text: " then", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "after a colon", transcript: "All good", before: "Status:", after: nil,
                expected: .init(text: " all good", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "after an emoji", transcript: "And then we left", before: "We had fun 😀", after: nil,
                expected: .init(text: " and then we left", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "after a closing quote", transcript: "And left", before: "He said “hi”", after: nil,
                expected: .init(text: " and left", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "after a closing straight quote", transcript: "And left", before: "He said \"hi\"", after: nil,
                expected: .init(text: " and left", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "after a closing straight quote and a space", transcript: "And left", before: "He said \"hi\" ",
                after: nil, expected: .init(text: "and left", changedCasing: true)),
            Row(name: "after a possessive apostrophe", transcript: "toys are here", before: "the kids'", after: nil,
                expected: .init(text: " toys are here", addedLeadingSpace: true)),
            Row(name: "after a digit", transcript: "Is out", before: "Version 2", after: nil,
                expected: .init(text: " is out", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "after a closing bracket", transcript: "And bar", before: "foo)", after: nil,
                expected: .init(text: " and bar", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "already lowercase mid-sentence", transcript: "and bar", before: "foo", after: nil,
                expected: .init(text: " and bar", addedLeadingSpace: true))
        ])
    }

    private static func testProtectedFirstWords() {
        let vocabulary: Set<String> = ["Avery Quinn", "WebKit"]
        check([
            Row(name: "I'm", transcript: "I'm done", before: "and", after: nil,
                expected: .init(text: " I'm done", addedLeadingSpace: true)),
            Row(name: "I", transcript: "I think", before: "and", after: nil,
                expected: .init(text: " I think", addedLeadingSpace: true)),
            Row(name: "I'll with a curly apostrophe", transcript: "I’ll go", before: "and", after: nil,
                expected: .init(text: " I’ll go", addedLeadingSpace: true)),
            Row(name: "I've", transcript: "I've seen it", before: "and", after: nil,
                expected: .init(text: " I've seen it", addedLeadingSpace: true)),
            Row(name: "I'd", transcript: "I'd go", before: "and", after: nil,
                expected: .init(text: " I'd go", addedLeadingSpace: true)),
            Row(name: "acronym", transcript: "API key", before: "and", after: nil,
                expected: .init(text: " API key", addedLeadingSpace: true)),
            Row(name: "acronym with a trailing period", transcript: "NASA.", before: "and", after: nil,
                expected: .init(text: " NASA.", addedLeadingSpace: true)),
            Row(name: "CamelCase name", transcript: "WebKit bug", before: "and", after: nil,
                expected: .init(text: " WebKit bug", addedLeadingSpace: true)),
            Row(name: "vocabulary term", transcript: "Avery is here", before: "and", after: nil, keep: vocabulary,
                expected: .init(text: " Avery is here", addedLeadingSpace: true)),
            Row(name: "vocabulary term is case-insensitive", transcript: "Avery is here", before: "and", after: nil,
                keep: ["avery quinn"], expected: .init(text: " Avery is here", addedLeadingSpace: true)),
            Row(name: "vocabulary term possessive", transcript: "Avery's book", before: "and", after: nil, keep: vocabulary,
                expected: .init(text: " Avery's book", addedLeadingSpace: true)),
            Row(name: "vocabulary term curly possessive", transcript: "Avery’s book", before: "and", after: nil,
                keep: vocabulary, expected: .init(text: " Avery’s book", addedLeadingSpace: true)),
            Row(name: "no vocabulary", transcript: "Avery is here", before: "and", after: nil,
                expected: .init(text: " avery is here", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "no vocabulary possessive", transcript: "Avery's book", before: "and", after: nil,
                expected: .init(text: " avery's book", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "vocabulary term with a trailing comma", transcript: "Avery, hi", before: "and", after: nil,
                keep: vocabulary, expected: .init(text: " Avery, hi", addedLeadingSpace: true))
        ])
    }

    private static func testCJKJoining() {
        check([
            Row(name: "Japanese after Japanese", transcript: "元気です", before: "今日は", after: nil,
                expected: .init(text: "元気です")),
            Row(name: "Chinese after a fullwidth period", transcript: "你好", before: "好。", after: nil,
                expected: .init(text: "你好")),
            Row(name: "Japanese after Latin", transcript: "元気です", before: "Hello", after: nil,
                expected: .init(text: " 元気です", addedLeadingSpace: true)),
            Row(name: "Latin after Japanese", transcript: "hello", before: "今日は", after: nil,
                expected: .init(text: " hello", addedLeadingSpace: true)),
            Row(name: "Japanese before Japanese", transcript: "今日は。", before: nil, after: "元気です",
                expected: .init(text: "今日は。", handledTrailingEdge: true)),
            Row(name: "Latin before Japanese", transcript: "Hello.", before: nil, after: "元気です",
                expected: .init(text: "Hello. ", addedTrailingSpace: true, handledTrailingEdge: true)),
            // Closers are checked before the CJK join, so a fullwidth comma still drops the mark.
            Row(name: "fullwidth comma after Chinese", transcript: "你好。", before: nil, after: "，然后",
                expected: .init(text: "你好", droppedTrailingPunctuation: true, handledTrailingEdge: true))
        ])
    }

    private static func testTrailingContinuation() {
        check([
            Row(name: "lowercase follows", transcript: "We went home.", before: nil, after: "and then we left",
                expected: .init(text: "We went home ", addedTrailingSpace: true, droppedTrailingPunctuation: true,
                                handledTrailingEdge: true)),
            Row(name: "space then lowercase follows", transcript: "We went home.", before: nil, after: " and then",
                expected: .init(text: "We went home", droppedTrailingPunctuation: true, handledTrailingEdge: true)),
            Row(name: "digit follows", transcript: "We went home.", before: nil, after: "5 more",
                expected: .init(text: "We went home ", addedTrailingSpace: true, droppedTrailingPunctuation: true,
                                handledTrailingEdge: true)),
            Row(name: "comma follows", transcript: "We went home.", before: nil, after: ", then we left",
                expected: .init(text: "We went home", droppedTrailingPunctuation: true, handledTrailingEdge: true)),
            Row(name: "semicolon follows", transcript: "We left.", before: nil, after: "; then",
                expected: .init(text: "We left", droppedTrailingPunctuation: true, handledTrailingEdge: true)),
            Row(name: "colon follows", transcript: "We left.", before: nil, after: ": then",
                expected: .init(text: "We left", droppedTrailingPunctuation: true, handledTrailingEdge: true)),
            Row(name: "fullwidth closer follows Latin", transcript: "We left.", before: nil, after: "，然后",
                expected: .init(text: "We left", droppedTrailingPunctuation: true, handledTrailingEdge: true)),
            Row(name: "exclamation mark follows", transcript: "We went home.", before: nil, after: "!",
                expected: .init(text: "We went home", droppedTrailingPunctuation: true, handledTrailingEdge: true)),
            Row(name: "period follows", transcript: "We went home.", before: nil, after: ".",
                expected: .init(text: "We went home", droppedTrailingPunctuation: true, handledTrailingEdge: true)),
            Row(name: "inside brackets", transcript: "we went home.", before: "(", after: ")",
                expected: .init(text: "We went home", changedCasing: true, droppedTrailingPunctuation: true,
                                handledTrailingEdge: true)),
            Row(name: "closing quote follows", transcript: "We went home.", before: nil, after: "”",
                expected: .init(text: "We went home", droppedTrailingPunctuation: true, handledTrailingEdge: true)),
            Row(name: "closing straight quote follows", transcript: "We went home.", before: nil, after: "\"",
                expected: .init(text: "We went home", droppedTrailingPunctuation: true, handledTrailingEdge: true)),
            Row(name: "closing straight quote then a space follows", transcript: "We went home.", before: nil,
                after: "\" and", expected: .init(text: "We went home", droppedTrailingPunctuation: true,
                                                 handledTrailingEdge: true)),
            Row(name: "closing straight quote then a comma follows", transcript: "We went home.", before: nil,
                after: "\", and", expected: .init(text: "We went home", droppedTrailingPunctuation: true,
                                                  handledTrailingEdge: true)),
            Row(name: "closing straight apostrophe follows", transcript: "We went home.", before: nil, after: "' and",
                expected: .init(text: "We went home", droppedTrailingPunctuation: true, handledTrailingEdge: true)),
            Row(name: "ellipsis survives", transcript: "Well...", before: nil, after: "and",
                expected: .init(text: "Well... ", addedTrailingSpace: true, handledTrailingEdge: true)),
            Row(name: "double mark survives", transcript: "Hi?!", before: nil, after: "and",
                expected: .init(text: "Hi?! ", addedTrailingSpace: true, handledTrailingEdge: true))
        ])
    }

    private static func testTrailingNewSentence() {
        check([
            Row(name: "uppercase follows", transcript: "We went home.", before: nil, after: "Then we left.",
                expected: .init(text: "We went home. ", addedTrailingSpace: true, handledTrailingEdge: true)),
            Row(name: "emoji follows", transcript: "We went home.", before: nil, after: "😀",
                expected: .init(text: "We went home. ", addedTrailingSpace: true, handledTrailingEdge: true)),
            Row(name: "opening bracket follows", transcript: "We went home.", before: nil, after: "(see below)",
                expected: .init(text: "We went home. ", addedTrailingSpace: true, handledTrailingEdge: true)),
            Row(name: "opening straight quote follows", transcript: "We left.", before: nil, after: "\"quoted\" text",
                expected: .init(text: "We left. ", addedTrailingSpace: true, handledTrailingEdge: true)),
            // The common mid-paragraph click position: the fit keeps the mark and adds no space,
            // and the paste path must not add one either (handledTrailingEdge).
            Row(name: "space then uppercase follows", transcript: "New sentence.", before: nil, after: " Second sentence.",
                expected: .init(text: "New sentence.", handledTrailingEdge: true)),
            Row(name: "space then opening bracket follows", transcript: "New sentence.", before: nil, after: " (note)",
                expected: .init(text: "New sentence.", handledTrailingEdge: true)),
            Row(name: "space then emoji follows", transcript: "New sentence.", before: nil, after: " 😀",
                expected: .init(text: "New sentence.", handledTrailingEdge: true)),
            Row(name: "newline follows", transcript: "We went home.", before: nil, after: "\nNext line",
                expected: .init(text: "We went home.")),
            Row(name: "spaces then a newline follow", transcript: "We went home.", before: nil, after: "   \nNext line",
                expected: .init(text: "We went home.")),
            Row(name: "end of field", transcript: "We went home.", before: nil, after: "",
                expected: .init(text: "We went home.")),
            Row(name: "only spaces follow", transcript: "We went home.", before: nil, after: "   ",
                expected: .init(text: "We went home."))
        ])
    }

    /// A list keeps its own ending: only the leading rules apply.
    private static func testMultiLineTranscript() {
        check([
            Row(name: "list after a colon", transcript: "First item\nsecond item.", before: "Items:", after: "tail",
                expected: .init(text: " first item\nsecond item.", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "list after a period", transcript: "one\ntwo.", before: "Done.", after: "and",
                expected: .init(text: " One\ntwo.", changedCasing: true, addedLeadingSpace: true))
        ])
    }

    private static func testUnknownSidesAreUntouched() {
        for transcript in ["hello", "Hello", "Hello."] {
            TestSupport.expectEqual(
                CursorFormatting.adjust(transcript, before: nil, after: nil),
                CursorFormatting.Adjustment(text: transcript)
            )
        }
        check([
            Row(name: "only the start is known", transcript: "next step", before: "Done.", after: nil,
                expected: .init(text: " Next step", changedCasing: true, addedLeadingSpace: true)),
            Row(name: "only the end is known", transcript: "We left.", before: nil, after: "and",
                expected: .init(text: "We left ", addedTrailingSpace: true, droppedTrailingPunctuation: true,
                                handledTrailingEdge: true)),
            Row(name: "empty transcript", transcript: "", before: "Done.", after: "and",
                expected: .init(text: ""))
        ])
    }

    /// The snapshot stores an empty side as nil, so a field counts as read only when
    /// `fieldTextRead` is set or some text came back; an all-nil snapshot is "not read".
    private static func testSnapshotWrapper() {
        let unread = TextContextSnapshot(category: .other)
        TestSupport.expectEqual(
            CursorFormatting.adjust("hello", in: unread),
            CursorFormatting.Adjustment(text: "hello")
        )
        TestSupport.expect(!CursorFormatting.adjust("hello", in: unread).changedAnything, "An unread field must not be fitted")

        let emptyFieldRead = TextContextSnapshot(category: .other, fieldTextRead: true)
        TestSupport.expectEqual(
            CursorFormatting.adjust("hello there", in: emptyFieldRead),
            CursorFormatting.Adjustment(text: "Hello there", changedCasing: true)
        )

        let wholeFieldSelected = TextContextSnapshot(selectedText: "old draft")
        TestSupport.expectEqual(
            CursorFormatting.adjust("hello", in: wholeFieldSelected),
            CursorFormatting.Adjustment(text: "Hello", changedCasing: true)
        )

        let selectionReplacement = TextContextSnapshot(textBeforeCursor: "Hello ", selectedText: "world", textAfterCursor: ".")
        TestSupport.expectEqual(
            CursorFormatting.adjust("There.", in: selectionReplacement),
            CursorFormatting.Adjustment(text: "there", changedCasing: true, droppedTrailingPunctuation: true,
                                        handledTrailingEdge: true)
        )

        let endOfMessage = TextContextSnapshot(textBeforeCursor: "Hi Avery,")
        TestSupport.expectEqual(
            CursorFormatting.adjust("Thanks", in: endOfMessage),
            CursorFormatting.Adjustment(text: " thanks", changedCasing: true, addedLeadingSpace: true)
        )
    }

    private static func testVocabularyTerms() {
        TestSupport.expectEqual(
            CursorFormatting.keepCapitalizedTerms(from: "Avery Quinn, WebKit;  \n claude code ,,"),
            ["Avery Quinn", "WebKit", "claude code"]
        )
        TestSupport.expectEqual(CursorFormatting.keepCapitalizedTerms(from: ""), [])

        let merged = DictionaryCorrection.vocabularyText(
            "Avery",
            merging: [DictionaryCorrection(from: "web kit", to: "WebKit")]
        )
        let terms = CursorFormatting.keepCapitalizedTerms(from: merged)
        TestSupport.expectEqual(terms, ["Avery", "WebKit"])
        TestSupport.expectEqual(
            CursorFormatting.adjust("WebKit is open", before: "the", after: nil, keepCapitalized: terms),
            CursorFormatting.Adjustment(text: " WebKit is open", addedLeadingSpace: true)
        )
    }

    /// Edit Mode and voice macro payloads are never fitted, whatever the setting.
    private static func testAppliesOnlyToPlainDictation() {
        for enabled in [false, true] {
            for isCommandMode in [false, true] {
                for isVoiceMacro in [false, true] {
                    TestSupport.expectEqual(
                        CursorFormatting.applies(enabled: enabled, isCommandMode: isCommandMode, isVoiceMacro: isVoiceMacro),
                        enabled && !isCommandMode && !isVoiceMacro
                    )
                }
            }
        }
    }

    private static func testDefaultAndStorage() {
        let suite = "FreeFlowTests.CursorFormatting.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(CursorFormatting.storageKey, "cursor_formatting_enabled")
        TestSupport.expect(CursorFormatting.defaultEnabled, "Cursor fitting must default to on")
        TestSupport.expect(CursorFormatting.load(from: defaults), "A missing preference must keep cursor fitting on")
        TestSupport.expect(defaults.object(forKey: CursorFormatting.storageKey) == nil, "Loading the default must not persist a choice")

        for enabled in [false, true] {
            defaults.set(enabled, forKey: CursorFormatting.storageKey)
            let reloaded = UserDefaults(suiteName: suite)!
            TestSupport.expectEqual(CursorFormatting.load(from: reloaded), enabled)
            TestSupport.expectEqual(reloaded.object(forKey: CursorFormatting.storageKey) as? Bool, enabled)
        }

        defaults.set("invalid", forKey: CursorFormatting.storageKey)
        TestSupport.expect(CursorFormatting.load(from: defaults), "An invalid saved value must default to on")

        defaults.removeObject(forKey: CursorFormatting.storageKey)
        TestSupport.expect(CursorFormatting.load(from: defaults), "Removing a saved choice must restore on")
    }

    /// The Run Log keys rows on specific status strings, so the suffix and its place in the
    /// composed status are pinned here.
    private static func testRunLogStatusSuffix() {
        TestSupport.expectEqual(CursorFormatting.statusSuffix, ", fitted to cursor")
        TestSupport.expect(!CursorFormatting.statusSuffix.hasPrefix("Error:"), "A fitted dictation must not render as an error row")
        TestSupport.expect(
            CursorFormatting.statusSuffix != SilenceGatePreference.skippedProcessingStatus,
            "A fitted dictation must not render as a silence-gated row"
        )

        let outcome = "Post-processing succeeded"
        TestSupport.expectEqual(
            CursorFormatting.processingStatus(outcome: outcome, expandedSnippetCount: 0, fittedToCursor: false, pressEnterDetected: false),
            outcome
        )
        TestSupport.expectEqual(
            CursorFormatting.processingStatus(outcome: outcome, expandedSnippetCount: 0, fittedToCursor: true, pressEnterDetected: false),
            "Post-processing succeeded, fitted to cursor"
        )
        TestSupport.expectEqual(
            CursorFormatting.processingStatus(outcome: outcome, expandedSnippetCount: 0, fittedToCursor: true, pressEnterDetected: true),
            "Post-processing succeeded, fitted to cursor; detected press enter command"
        )
        TestSupport.expectEqual(
            CursorFormatting.processingStatus(outcome: outcome, expandedSnippetCount: 1, fittedToCursor: true, pressEnterDetected: true),
            "Post-processing succeeded, 1 snippet expanded, fitted to cursor; detected press enter command"
        )
        TestSupport.expectEqual(
            CursorFormatting.processingStatus(outcome: outcome, expandedSnippetCount: 2, fittedToCursor: false, pressEnterDetected: true),
            "Post-processing succeeded, 2 snippets expanded; detected press enter command"
        )

        TestSupport.expect(!CursorFormatting.Adjustment(text: "x").changedAnything, "A default adjustment changed nothing")
        TestSupport.expect(
            !CursorFormatting.Adjustment(text: "x", handledTrailingEdge: true).changedAnything,
            "Owning the trailing edge without changing text is not a change"
        )
        let singleFlags: [CursorFormatting.Adjustment] = [
            .init(text: "x", changedCasing: true),
            .init(text: "x", addedLeadingSpace: true),
            .init(text: "x", addedTrailingSpace: true),
            .init(text: "x", droppedTrailingPunctuation: true)
        ]
        for adjustment in singleFlags {
            TestSupport.expect(adjustment.changedAnything, "Any single flag counts as a change")
        }
    }
}
