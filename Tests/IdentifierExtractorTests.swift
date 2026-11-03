import Foundation

/// Invented code snippets, file names and window titles only. The Accessibility walk that
/// reads them from Cursor, Windsurf and VS Code needs a live IDE and is a pending manual test.
enum IdentifierExtractorTests {
    static func run() {
        testCaseStyles()
        testPlainWordsKeywordsAndAcronymsDropped()
        testDottedPaths()
        testStopWords()
        testBounds()
        testDedupeAndBoundaries()
        testRandomLookingTokensDropped()
        testEmailURLPathAndAttributeContextsSkipped()
        testCap()
        testWindowTitleParsing()
        testFileNamesFromLabels()
        testSecretsFileNames()
        testSecretsWindowTitles()
        testCleanupTerms()
        testCollectsCodeContextBundles()
        testCodeContextStaysOutOfPromptSection()
        testIdentifiersKeepCaseAtCursor()
    }

    private typealias Extractor = IdentifierExtractor

    private static func testCaseStyles() {
        // AppState folds into appState under the case-insensitive dedupe.
        TestSupport.expectEqual(
            Extractor.identifiers(in: ["let appState = AppState(); var user_name = MAX_RETRY_COUNT; URLSession iPhone"]),
            ["appState", "user_name", "MAX_RETRY_COUNT", "URLSession", "iPhone"]
        )
        TestSupport.expectEqual(
            Extractor.identifiers(in: [
                "fetchUserProfile PipelineHistoryStore load_settings MAX_RETRY_COUNT URLSessionTask task "
                    + "kAXFocusedUIElementAttribute getHTTPResponseCode sha256Digest iOS macOS UIView _private_value"
            ]),
            [
                "fetchUserProfile", "PipelineHistoryStore", "load_settings", "MAX_RETRY_COUNT", "URLSessionTask",
                "kAXFocusedUIElementAttribute", "getHTTPResponseCode", "sha256Digest", "iOS", "macOS", "UIView",
                "_private_value"
            ]
        )
    }

    private static func testPlainWordsKeywordsAndAcronymsDropped() {
        TestSupport.expectEqual(
            Extractor.identifiers(in: ["return value func Sources HTTP JSON TODO IDs URLs the and __init__ __DEV__ Session aB"]),
            []
        )
    }

    private static func testDottedPaths() {
        TestSupport.expectEqual(
            Extractor.identifiers(in: [
                "self.appState.isRecording; AppState.shared; os.log; e.g. i.e. fileName.count self.viewModel this.state Self.defaultValue"
            ]),
            ["appState.isRecording", "isRecording", "AppState.shared", "fileName.count", "viewModel", "defaultValue"]
        )
        // A member after "?.", "!.", ").", "]." or a leading-dot modifier is still a name.
        TestSupport.expectEqual(
            Extractor.identifiers(in: [
                "self.delegate?.didFinishLoading(); user?.profileName; foo().barBaz(); items[0].displayName; "
                    + ".environmentObject(appState); x!.forceValue"
            ]),
            ["didFinishLoading", "profileName", "barBaz", "displayName", "environmentObject", "appState", "forceValue"]
        )
        TestSupport.expectEqual(Extractor.identifiers(in: ["let name = user?.firstName"]), ["firstName"])
        TestSupport.expectEqual(Extractor.identifiers(in: ["getUser().lastName"]), ["getUser", "lastName"])
        TestSupport.expectEqual(
            Extractor.identifiers(in: ["context.textContext?.codeIdentifiers"]),
            ["context.textContext", "textContext", "codeIdentifiers"]
        )
        // Parts of a dotted host or path still never match on their own.
        TestSupport.expectEqual(Extractor.identifiers(in: ["https://api.someHost.com/x/y.someThing"]), [])
    }

    private static func testStopWords() {
        TestSupport.expectEqual(
            Extractor.identifiers(in: ["isNaN NaN IBOutlet IBAction size_t uint8_t static_cast NS_ASSUME_NONNULL_BEGIN realName"]),
            ["realName"]
        )
    }

    private static func testBounds() {
        let sixty = "fetch" + String(repeating: "Value", count: 11)
        let sixtyOne = sixty + "s"
        TestSupport.expectEqual(sixty.count, 60)
        TestSupport.expectEqual(
            Extractor.identifiers(in: ["aB aBc \(sixty) \(sixtyOne) _1_2 a_1"]),
            ["aBc", sixty, "a_1"]
        )
        // The path is over 60 characters, but its code-shaped last part is kept.
        TestSupport.expectEqual(
            Extractor.identifiers(in: ["longName." + String(repeating: "a", count: 50) + ".lastPartName"]),
            ["lastPartName"]
        )
    }

    private static func testDedupeAndBoundaries() {
        TestSupport.expectEqual(Extractor.identifiers(in: ["fooBar FooBar barBaz fooBar"]), ["fooBar", "barBaz"])
        TestSupport.expectEqual(Extractor.identifiers(in: ["fooBar", "FOOBAR barBaz"]), ["fooBar", "barBaz"])
        TestSupport.expectEqual(Extractor.identifiers(in: ["9abc_def foo-barBaz"]), ["barBaz"])
        TestSupport.expectEqual(Extractor.identifiers(in: ["fooBar."]), ["fooBar"])
    }

    /// Generated tokens (keys, hashes, IDs) never become vocabulary. No real key prefixes.
    private static func testRandomLookingTokensDropped() {
        TestSupport.expectEqual(
            Extractor.identifiers(in: ["aB3dEfGh9KlMnOpQrStUv zz_Q7fKp2XwLm9RtB4vNc deadBEEF01234567 x9Y8z7W"]),
            []
        )
    }

    private static func testEmailURLPathAndAttributeContextsSkipped() {
        TestSupport.expectEqual(
            Extractor.identifiers(in: [
                "contact jane.doe@example.com or https://github.com/org/repo.git and /usr/local/lib_dir C:\\some_dir @objc @MainActor"
            ]),
            []
        )
    }

    private static func testCap() {
        let many = (0..<200).map { "syntheticName\($0)Value" }.joined(separator: " ")
        let capped = Extractor.identifiers(in: [many])
        TestSupport.expectEqual(capped.count, 150)
        TestSupport.expectEqual(capped.first, "syntheticName0Value")
        TestSupport.expectEqual(capped.last, "syntheticName149Value")
        TestSupport.expectEqual(
            Extractor.identifiers(in: [many], limit: 3),
            ["syntheticName0Value", "syntheticName1Value", "syntheticName2Value"]
        )
    }

    private static func testWindowTitleParsing() {
        let rows: [(title: String, expected: String)] = [
            ("AppState.swift — synthetic-project", "AppState.swift"),
            ("● AppState.swift — synthetic-project — Cursor", "AppState.swift"),
            ("synthetic-project — Sources/AppState.swift", "AppState.swift"),
            ("AppState.swift (Working Tree) — synthetic-project", "AppState.swift"),
            (".env — synthetic-project", ".env"),
            ("Makefile — synthetic-project", "Makefile"),
            ("notes.md - synthetic-project", "notes.md")
        ]
        for row in rows {
            TestSupport.expectEqual(Extractor.fileName(from: row.title), row.expected)
        }
        for title in [
            "Welcome — synthetic-project", "Untitled-1 — synthetic-project", "Cursor", "Cursor Settings",
            "v1.2 — x", "Release 1.2.3 — notes", "", "example.com — x"
        ] {
            TestSupport.expect(Extractor.fileName(from: title) == nil, "No file name expected in: \(title)")
        }
        TestSupport.expectEqual(Extractor.fileName(from: nil), nil)
    }

    private static func testFileNamesFromLabels() {
        TestSupport.expectEqual(
            Extractor.fileNames(fromLabels: [
                "AppState.swift — synthetic-project", "AppState.swift", "SettingsView.swift, Editor Group 1",
                "Sources › TextContextCore.swift", "Sources", "README.md • Modified", ".gitignore", "index.d.ts",
                "@SyntheticChip.swift", "Open Editors", "https://example.com/a.js", "user@example.com", "v1.2.3",
                "e.g.", "License", "appstate.swift", "AppState.swift:42"
            ]),
            [
                "AppState.swift", "SettingsView.swift", "TextContextCore.swift", "README.md", ".gitignore",
                "index.d.ts", "SyntheticChip.swift"
            ]
        )
        TestSupport.expectEqual(Extractor.fileNames(fromLabels: (0..<250).map { "file\($0).swift" }).count, 200)
        TestSupport.expectEqual(Extractor.fileNames(fromLabels: [String(repeating: "a", count: 301) + " big.swift"]), [])
    }

    private static func testSecretsFileNames() {
        for name in [
            ".env", ".env.local", ".npmrc", "id_rsa", "id_ed25519.pub", "server.pem", "signing.key",
            "AuthKey_SYNTHETIC.p8", "app_secrets.json", "aws-credentials.txt", "production.env", "app.env",
            "local.env", "docker.env", "app.env.local", "env.production", ".dev.vars", "prod.tfvars",
            "terraform.tfstate", "credentials", "secrets", ".ssh", ".aws"
        ] {
            TestSupport.expect(Extractor.isSecretsFileName(name), "Expected a secrets file: \(name)")
        }
        for name in [
            "AppState.swift", "README.md", "keyboard.swift", "monkey.ts", "environment.swift", "vite-env.d.ts",
            "envelope.ts"
        ] {
            TestSupport.expect(!Extractor.isSecretsFileName(name), "Not a secrets file: \(name)")
        }
        TestSupport.expect(!Extractor.isSecretsFileName(nil), "No title is not a secrets file")
    }

    /// The editor-text guard reads every title piece, so extensionless secrets files that are
    /// never file-name-like (id_rsa, credentials) and their folders still stop the read.
    private static func testSecretsWindowTitles() {
        for title in [
            "id_rsa — .ssh — Cursor", "credentials — .aws — Cursor", "id_ed25519 — Visual Studio Code",
            "● id_rsa — Cursor", "production.env — synthetic-project", "● app.env — synthetic-project — Cursor",
            ".env.local — synthetic-project", "config — .kube — Windsurf", "synthetic-project — secrets"
        ] {
            TestSupport.expect(Extractor.titleShowsSecretsFile(title), "Expected a secrets title: \(title)")
        }
        // The file-name parse alone finds nothing here, so the guard must not rely on it.
        TestSupport.expectEqual(Extractor.fileName(from: "id_ed25519 — Visual Studio Code"), nil)
        for title in [
            "AppState.swift — synthetic-project — Cursor", "Welcome — synthetic-project", "keyboard.swift — x",
            "Visual Studio Code", ""
        ] {
            TestSupport.expect(!Extractor.titleShowsSecretsFile(title), "Not a secrets title: \(title)")
        }
        TestSupport.expect(!Extractor.titleShowsSecretsFile(nil), "No title is not a secrets title")
    }

    /// Only the identifiers the vocabulary lacks, until the shared cap; the vocabulary itself
    /// is passed to cleanup unchanged.
    private static func testCleanupTerms() {
        TestSupport.expectEqual(
            Extractor.cleanupTerms(["fooBar", "synthetic term", "bazQux", "FOOBAR"], after: "Synthetic Term\nOther, Third"),
            ["fooBar", "bazQux"]
        )
        TestSupport.expectEqual(Extractor.cleanupTerms(["fooBar", "bazQux"], after: ""), ["fooBar", "bazQux"])
        TestSupport.expectEqual(Extractor.cleanupTerms([], after: "a, b"), [])

        let base199 = (0..<199).map { "term\($0)" }.joined(separator: ", ")
        TestSupport.expectEqual(Extractor.cleanupTerms(["oneName", "twoName", "threeName"], after: base199), ["oneName"])
        let base250 = (0..<250).map { "term\($0)" }.joined(separator: ", ")
        TestSupport.expectEqual(Extractor.cleanupTerms(["oneName"], after: base250), [])
    }

    private static func testCollectsCodeContextBundles() {
        for bundle in [
            Extractor.cursorBundleIdentifier, "com.exafunction.windsurf", "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders"
        ] {
            TestSupport.expect(
                Extractor.collectsCodeContext(bundleIdentifier: bundle, category: .coding),
                "Code context expected for \(bundle)"
            )
        }
        for bundle in ["com.apple.dt.Xcode", "dev.zed.Zed", "com.apple.Terminal"] {
            TestSupport.expect(
                !Extractor.collectsCodeContext(bundleIdentifier: bundle, category: .coding),
                "No code context for \(bundle)"
            )
        }
        TestSupport.expect(!Extractor.collectsCodeContext(bundleIdentifier: nil, category: .coding), "nil bundle")
        TestSupport.expect(
            !Extractor.collectsCodeContext(bundleIdentifier: Extractor.cursorBundleIdentifier, category: .other),
            "Only a coding category collects code context"
        )
    }

    /// Identifiers and file names never enter the CONTEXT block, so they are never sent there.
    private static func testCodeContextStaysOutOfPromptSection() {
        let snapshot = TextContextSnapshot(
            appName: "Synthetic Editor",
            bundleIdentifier: Extractor.cursorBundleIdentifier,
            category: .coding,
            textBeforeCursor: "Synthetic before",
            codeIdentifiers: ["syntheticHelperName"],
            fileNames: ["SyntheticFile.swift"]
        )
        let section = TextContextCore.promptSection(for: snapshot)
        TestSupport.expect(!section.contains("syntheticHelperName"), "Identifiers must stay out of the CONTEXT block")
        TestSupport.expect(!section.contains("SyntheticFile.swift"), "File names must stay out of the CONTEXT block")
        TestSupport.expect(section.contains("Synthetic before"), "The block itself is unchanged")
    }

    /// A sentence-start identifier keeps its lowercase start, but an identifier never keeps
    /// a capital that cleanup added when the paste lands mid-sentence.
    private static func testIdentifiersKeepCaseAtCursor() {
        TestSupport.expectEqual(
            CursorFormatting.adjust("user_name is optional.", before: "", after: nil).text,
            "User_name is optional."
        )
        let keep: Set<String> = ["user_name"]
        let kept = CursorFormatting.adjust("user_name is optional.", before: "", after: nil, keepLowercase: keep)
        TestSupport.expectEqual(kept.text, "user_name is optional.")
        TestSupport.expect(!kept.changedCasing, "A kept identifier must not change case")

        let midSentence = CursorFormatting.adjust(
            "User_name is optional.", before: "the field ", after: nil, keepLowercase: keep
        )
        TestSupport.expectEqual(midSentence.text, "user_name is optional.")
        TestSupport.expect(midSentence.changedCasing, "Mid-sentence, the added capital must go")
        TestSupport.expectEqual(
            CursorFormatting.adjust(
                "user_name is optional.",
                in: TextContextSnapshot(textBeforeCursor: "Done. ", fieldTextRead: true),
                keepLowercase: keep
            ).text,
            "user_name is optional."
        )
    }
}
