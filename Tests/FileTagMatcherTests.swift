import Foundation

/// Invented file names and dictations only. Whether Cursor and Windsurf turn the pasted
/// "@File" text into a mention needs the live IDE and is a pending manual test, as is what
/// tagging does in their code editor and integrated terminal (the gate is the app alone).
enum FileTagMatcherTests {
    static func run() {
        testEachTrigger()
        testFuzzyForms()
        testQuotedBacktickedMarkup()
        testDotfiles()
        testUnmatchedTriggersUntouched()
        testLongestMatchWins()
        testMultipleTags()
        testResolve()
        testDictationPlanGate()
        testStatusSuffix()
        testPreference()
    }

    private static let files = [
        "AppState.swift", "app_state.swift", "SettingsView.swift", ".env", "README.md", "build-config.json",
        "app.ts", "app.ts.map", ".gitignore", "Makefile", "Makefile.local", "AppDelegate.swift"
    ]

    private static func plan(_ text: String, _ fileNames: [String] = FileTagMatcherTests.files) -> SnippetExpansionPlan {
        FileTagMatcher.plan(for: text, fileNames: fileNames)
    }

    private static func expanded(_ text: String, _ fileNames: [String] = FileTagMatcherTests.files) -> String {
        plan(text, fileNames).expandedText
    }

    private static func testEachTrigger() {
        for trigger in ["tag", "tagged", "at", "@", "Tag", "AT", "TAGGED", "tag,", "At:"] {
            TestSupport.expectEqual(
                plan("look \(trigger) app state dot swift please"),
                SnippetExpansionPlan(
                    placeholderText: "look ⟦S1⟧ please",
                    expandedText: "look @AppState.swift please",
                    expansions: ["@AppState.swift"]
                )
            )
        }

        let attached = plan("open @AppState.swift now")
        TestSupport.expectEqual(attached.placeholderText, "open ⟦S1⟧ now")
        TestSupport.expectEqual(attached.expandedText, "open @AppState.swift now")
        TestSupport.expectEqual(attached.expansions, ["@AppState.swift"])
        TestSupport.expectEqual(expanded("open @appstate.swift now"), "open @AppState.swift now")
        TestSupport.expectEqual(expanded("open @app state dot swift"), "open @AppState.swift")
    }

    private static func testFuzzyForms() {
        let rows: [(spoken: String, expected: String)] = [
            ("tag app state dot swift", "@AppState.swift"),
            ("tag app underscore state dot swift", "@app_state.swift"),
            ("tag appstate.swift", "@AppState.swift"),
            ("tag AppState.swift", "@AppState.swift"),
            ("tag App State Dot Swift", "@AppState.swift"),
            ("tag app_state.swift", "@app_state.swift"),
            ("tag app-state dot swift", "@AppState.swift"),
            ("tag settings view dot swift", "@SettingsView.swift"),
            ("tag build dash config dot json", "@build-config.json"),
            ("tag build config dot json", "@build-config.json"),
            ("tag readme dot md", "@README.md"),
            ("tag app state.swift", "@AppState.swift"),
            ("check tag app state. swift, then", "check @AppState.swift, then"),
            ("AT App State Dot Swift?", "@AppState.swift?"),
            ("Look at app state dot Swift.", "Look @AppState.swift.")
        ]
        for row in rows {
            TestSupport.expectEqual(expanded(row.spoken), row.expected)
        }
        // Without a snake_case candidate the separator is ignored.
        TestSupport.expectEqual(expanded("tag app underscore state dot swift", ["AppState.swift"]), "@AppState.swift")
    }

    /// Markup is consumed only when it wraps the name on both sides, so an opening quote that
    /// closes later stays; brackets and outer punctuation stay, and punctuation inside a
    /// consumed closing quote moves after the tag.
    private static func testQuotedBacktickedMarkup() {
        let rows: [(spoken: String, expected: String)] = [
            ("tag `AppState.swift` now", "@AppState.swift now"),
            ("tag \"app state dot swift\".", "@AppState.swift."),
            ("tag \"app state dot swift.\"", "@AppState.swift."),
            ("tag **AppState.swift**", "@AppState.swift"),
            ("(tag app state dot swift)", "(@AppState.swift)"),
            ("tag “AppState.swift”,", "@AppState.swift,"),
            ("He said \"look at app state dot swift\"", "He said \"look @AppState.swift\""),
            ("\"at app state dot swift\"", "@AppState.swift"),
            ("\"look at app state dot swift\"", "\"look @AppState.swift\""),
            ("tag \"app state dot swift is great\"", "\"@AppState.swift is great\""),
            ("see (@AppState.swift)", "see (@AppState.swift)")
        ]
        for row in rows {
            TestSupport.expectEqual(expanded(row.spoken), row.expected)
        }
        TestSupport.expectEqual(plan("see (@AppState.swift)").expansions.count, 1)
    }

    private static func testDotfiles() {
        TestSupport.expectEqual(expanded("tag dot env"), "@.env")
        TestSupport.expectEqual(expanded("check at dot env."), "check @.env.")
        TestSupport.expectEqual(expanded("at dot git ignore please"), "@.gitignore please")
        TestSupport.expect(!plan("tag env").hasMatches, "A dotfile needs the spoken dot")
    }

    private static func testUnmatchedTriggersUntouched() {
        for text in [
            "meet at noon", "look at it, tag nothing here", "at app state", "mail me@example.com about it",
            "tag app, state dot swift", "the at sign", "that cat at", "tag", "at the app state",
            "where are we at", "@everyone look", "tag \" app state dot swift \""
        ] {
            TestSupport.expectEqual(
                plan(text),
                SnippetExpansionPlan(placeholderText: text, expandedText: text, expansions: [])
            )
        }
        TestSupport.expect(!plan("tag app state dot swift", []).hasMatches, "No file names means no tags")

        // A sentence-ending "." never joins a base name to the next sentence's first word,
        // even when that word is the extension (speech-to-text capitalizes it).
        let sentenceBoundaries: [(text: String, fileNames: [String])] = [
            ("Let's look at main. Go to the bottom.", ["main.go"]),
            ("Look at main. Go ahead and rebase.", ["main.go"]),
            ("The bug is at index. Js frameworks do that.", ["index.js"]),
            ("We met at app. Ts was there.", ["app.ts"]),
            ("We are at home. MD is next", ["home.md"]),
            ("I tagged main. Go check it.", ["main.go"])
        ]
        for row in sentenceBoundaries {
            TestSupport.expectEqual(
                plan(row.text, row.fileNames),
                SnippetExpansionPlan(placeholderText: row.text, expandedText: row.text, expansions: [])
            )
        }
        TestSupport.expectEqual(expanded("tag main. go now", ["main.go"]), "@main.go now")
    }

    private static func testLongestMatchWins() {
        TestSupport.expectEqual(expanded("tag app dot ts dot map"), "@app.ts.map")
        TestSupport.expectEqual(expanded("tag app dot ts"), "@app.ts")
        TestSupport.expectEqual(expanded("tag makefile dot local"), "@Makefile.local")
        TestSupport.expectEqual(expanded("tag makefile"), "@Makefile")
        TestSupport.expectEqual(expanded("look at tag app state dot swift"), "look at @AppState.swift")
        // Ties go to the first collected name (the window title's file comes first).
        TestSupport.expectEqual(
            expanded("at app state dot swift", ["AppState.swift", "appstate.swift"]),
            "@AppState.swift"
        )
    }

    private static let multiple = FileTagMatcher.plan(
        for: "compare tag app state dot swift with at settings view dot swift and meet at noon",
        fileNames: files
    )

    private static func testMultipleTags() {
        TestSupport.expectEqual(
            multiple,
            SnippetExpansionPlan(
                placeholderText: "compare ⟦S1⟧ with ⟦S2⟧ and meet at noon",
                expandedText: "compare @AppState.swift with @SettingsView.swift and meet at noon",
                expansions: ["@AppState.swift", "@SettingsView.swift"]
            )
        )
    }

    private static func testResolve() {
        TestSupport.expectEqual(
            multiple.resolve("Compare ⟦S1⟧ with ⟦S2⟧."),
            "Compare @AppState.swift with @SettingsView.swift."
        )
        TestSupport.expectEqual(
            multiple.resolve("compare ⟦s1⟧ with ⟦s2⟧"),
            "compare @AppState.swift with @SettingsView.swift"
        )
        TestSupport.expectEqual(multiple.resolve("Compare ⟦S1⟧."), nil)
        TestSupport.expectEqual(multiple.resolve("⟦S1⟧ ⟦S1⟧ ⟦S2⟧"), nil)
        TestSupport.expectEqual(multiple.resolve("⟦S1⟧ ⟦S2⟧ ⟦S3⟧"), nil)
    }

    private static func testDictationPlanGate() {
        let raw = "look tag app state dot swift"
        let noSnippets = SnippetExpansion.plan(for: raw, snippets: [])
        func gate(
            corrected: String = raw,
            rawTranscript: String = raw,
            snippetPlan: SnippetExpansionPlan = noSnippets,
            enabled: Bool = true,
            bundle: String? = IdentifierExtractor.cursorBundleIdentifier,
            fileNames: [String] = files
        ) -> SnippetExpansionPlan? {
            FileTagMatcher.dictationPlan(
                correctedTranscript: corrected,
                rawTranscript: rawTranscript,
                snippetPlan: snippetPlan,
                enabled: enabled,
                bundleIdentifier: bundle,
                fileNames: fileNames
            )
        }

        TestSupport.expectEqual(gate()?.expansions, ["@AppState.swift"])
        TestSupport.expectEqual(gate(bundle: IdentifierExtractor.cursorBundleIdentifier.uppercased())?.expansions, ["@AppState.swift"])
        TestSupport.expectEqual(gate(bundle: "com.exafunction.windsurf")?.expansions, ["@AppState.swift"])
        TestSupport.expect(gate(bundle: "com.microsoft.VSCode") == nil, "VS Code gets identifiers but no tagging")
        TestSupport.expect(gate(bundle: nil) == nil, "An unknown app is never tagged")
        TestSupport.expect(gate(enabled: false) == nil, "The setting turns tagging off")
        TestSupport.expect(gate(fileNames: []) == nil, "No collected names means no tagging")

        // Wispr's limitation: a dictionary correction or a snippet in this dictation disables tagging.
        let corrected = DictionaryCorrection.apply([DictionaryCorrection(from: "look", to: "Look")], to: raw)
        TestSupport.expect(corrected != raw, "The synthetic correction must change the text")
        TestSupport.expect(gate(corrected: corrected) == nil, "A correction disables tagging")
        let snippets = SnippetExpansion.plan(
            for: raw, snippets: [SnippetExpansion.Snippet(trigger: "look", expansion: "Synthetic expansion")]
        )
        TestSupport.expect(snippets.hasMatches, "The synthetic snippet must match")
        TestSupport.expect(gate(snippetPlan: snippets) == nil, "A snippet disables tagging")

        TestSupport.expect(
            gate(corrected: "meet at noon", rawTranscript: "meet at noon") == nil,
            "A dictation with no match has no plan"
        )
    }

    private static func testStatusSuffix() {
        TestSupport.expectEqual(FileTagMatcher.statusSuffix(taggedCount: 0), "")
        TestSupport.expectEqual(FileTagMatcher.statusSuffix(taggedCount: 1), ", 1 file tagged")
        TestSupport.expectEqual(FileTagMatcher.statusSuffix(taggedCount: 3), ", 3 files tagged")
        TestSupport.expectEqual(
            CursorFormatting.processingStatus(
                outcome: "Post-processing succeeded",
                expandedSnippetCount: 0,
                taggedFileCount: 2,
                fittedToCursor: true,
                pressEnterDetected: true
            ),
            "Post-processing succeeded, 2 files tagged, fitted to cursor; detected press enter command"
        )
    }

    private static func testPreference() {
        let suiteName = "FreeFlowTests.FileTagging.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TestSupport.expectEqual(FileTagMatcher.storageKey, "vibe_coding_file_tagging_enabled")
        TestSupport.expect(FileTagMatcher.load(from: defaults), "Tagging is on by default")
        TestSupport.expect(
            defaults.object(forKey: FileTagMatcher.storageKey) == nil,
            "Reading the default must not write it"
        )
        defaults.set(false, forKey: FileTagMatcher.storageKey)
        TestSupport.expect(!FileTagMatcher.load(from: defaults), "A stored false loads false")
        defaults.set("yes", forKey: FileTagMatcher.storageKey)
        TestSupport.expect(FileTagMatcher.load(from: defaults), "A non-Bool value reads as on")
    }
}
