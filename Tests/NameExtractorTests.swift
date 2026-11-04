import Foundation

/// Invented screen text only. Uses the embedded everyday list and either no tagger or a fake
/// one; never NLTagger, whose output depends on the OS model.
enum NameExtractorTests {
    private typealias Source = NameExtractor.Source

    static func run() {
        testEverydayWordsLookup()
        testClaudeReplyFixture()
        testChatGPTReplyFixture()
        testSearchQueryKeepsRareWordsOnly()
        testDistractorsNeverPass()
        testSecretsNeverPass()
        testUILabelsGiveNothing()
        testEverydayRunsNeedRepetitionOrTagger()
        testDeterministicCappedDeduped()
        testPathsGiveOnlyFileStems()
        testStandaloneWordBesideMultiWordTerm()
        testLongTokensExtractQuickly()
        testOwnNameTerms()
    }

    private static func terms(_ sources: [Source], tagger: NameExtractor.NameTagger? = nil) -> [String] {
        NameExtractor.terms(from: sources, everyday: EverydayWords.all, tagger: tagger)
    }

    private static func has(_ terms: [String], _ term: String) -> Bool {
        terms.contains { $0.lowercased() == term.lowercased() }
    }

    private static func testEverydayWordsLookup() {
        TestSupport.expect(EverydayWords.contains("the"), "Common words are everyday")
        TestSupport.expect(EverydayWords.contains("The"), "Lookup is case-insensitive")
        TestSupport.expect(EverydayWords.contains("repo"), "The tech supplement is included")
        TestSupport.expect(EverydayWords.contains("cloud"), "Ordinary nouns are everyday")
        TestSupport.expect(!EverydayWords.contains("supabase"), "Product names are not everyday")
        TestSupport.expect(!EverydayWords.contains("claude"), "Brand names are not everyday")
        TestSupport.expect(EverydayWords.all.count > 12_000, "The whole list is embedded")
    }

    private static func testClaudeReplyFixture() {
        let reply = """
        I updated `DeepgramStreamingCore.swift` so `normalizedKeyterms` skips terms that do not fit. Next, wire it into AppState.startStreamingIfEnabled.
        The Supabase client in useAuth.ts still calls the old endpoint, and Vercel logs show a 401.
        Run make check before you push to the feature branch.
        """
        let prompt = "ask claude to fix the deepgram keyterm budget in AppState and keep TextContextSnapshot pure"
        let result = terms([
            Source(text: reply, kind: .conversation),
            Source(text: prompt, kind: .conversation),
            Source(text: "freeflow", kind: .projectName),
        ])
        for expected in [
            "DeepgramStreamingCore", "normalizedKeyterms", "startStreamingIfEnabled", "useAuth", "Supabase",
            "Vercel", "AppState", "TextContextSnapshot", "freeflow",
        ] {
            TestSupport.expect(has(result, expected), "Claude reply terms must include \(expected): \(result.count) terms")
        }
        for excluded in ["Next", "Run", "The", "I", "make", "check", "401"] {
            TestSupport.expect(!has(result, excluded), "Claude reply terms must not include \(excluded)")
        }
    }

    private static func testChatGPTReplyFixture() {
        let reply = """
        ChatGPT said:
        Here are three options: Wispr Flow, Superwhisper and VoiceInk. Wispr Flow uses a model called Canto, while Superwhisper can run Whisper locally.
        If you need streaming, Deepgram Nova-3 and AssemblyAI Universal-3 are the usual picks.
        Next Steps
        1. Compare pricing
        2. Test with GPT-5 and Qwen3 on an M2 MacBook Air
        """
        let prompt = "You said:\nwhich dictation apps support streaming"
        let result = terms([
            Source(text: ContextTermSources.stripTurnLabel(reply, label: "ChatGPT said"), kind: .conversation),
            Source(text: ContextTermSources.stripTurnLabel(prompt, label: "You said"), kind: .conversation),
        ])
        for expected in [
            "Wispr Flow", "Superwhisper", "VoiceInk", "Canto", "Deepgram", "Nova-3", "AssemblyAI", "Universal-3",
            "GPT-5", "Qwen3", "MacBook Air",
        ] {
            TestSupport.expect(has(result, expected), "ChatGPT reply terms must include \(expected)")
        }
        for excluded in ["Next Steps", "Steps", "Compare", "Test", "Here", "If", "M2", "ChatGPT"] {
            TestSupport.expect(!has(result, excluded), "ChatGPT reply terms must not include \(excluded)")
        }
    }

    private static func testSearchQueryKeepsRareWordsOnly() {
        TestSupport.expectEqual(
            terms([Source(text: "supabase row level security policies", kind: .searchQuery)]),
            ["supabase"]
        )
        TestSupport.expectEqual(
            terms([Source(text: "supabase deepgram vercel qwenlab zorblax plinthbase quorvex", kind: .searchQuery)]),
            ["supabase", "deepgram", "vercel", "qwenlab", "zorblax"]
        )
        // Lowercase rare words count only in a typed search query.
        TestSupport.expectEqual(terms([Source(text: "supabase deepgram vercel", kind: .conversation)]), [])
    }

    /// Similar-sounding text that fails the filters never reaches the keyterms, and the
    /// user's own vocabulary always leads the connect list.
    private static func testDistractorsNeverPass() {
        let distractor = """
        Cloud Storage Pricing Overview
        Cloud costs went up this quarter.
        we moved the cloud code path behind a flag; see cloud.google.com/code for details.
        Contact clyde@example.com or call 555-0134.
        CLOUD_CODE_TOKEN=\("abc123" + "def456" + "ghi789" + "jkl012")
        Then export `CLOUD_CODE_TOKEN` and run `make check`.
        """
        let result = terms([Source(text: distractor, kind: .conversation), Source(text: distractor, kind: .field)])
        for excluded in [
            "Cloud", "Cloud Code", "cloud code", "Cloud Storage", "Cloud Storage Pricing Overview", "Clyde", "clyde",
            "555-0134", "CLOUD_CODE_TOKEN",
        ] {
            TestSupport.expect(!has(result, excluded), "Distractor terms must not include \(excluded)")
        }
        TestSupport.expect(!result.contains { $0.contains("abc123") }, "The token value must not become a term")

        let connect = DeepgramStreamingCore.KeytermPlan.connectTerms(.init(vocabulary: ["Claude Code"]))
        TestSupport.expectEqual(connect.first, "Claude Code")
        TestSupport.expect(
            DeepgramStreamingCore.KeytermPlan.configureTerms(connect: connect, screenTerms: result, identifiers: []) == nil,
            "No Cloud… term reaches the Configure"
        )
    }

    private static func testSecretsNeverPass() {
        let secrets = SecretFilterTests.prefixedFixtures + [
            "sk-" + "proj-" + "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd",
            "CorrectHorse" + "BatteryStaple",
            "hunter2" + "xyz",
            "AbCdEf" + "123456" + "GhIjKlMn",
            "3f9a1c0b7e" + "2d4a5f8c6b" + "1e0d9a7f3c" + "2b1a0e9d8c",
            "myToken" + "ValueHere",
            "dummySignature" + "Value",
        ]
        let templates: [(String) -> String] = [
            { "SYNTHETIC_API_KEY=\($0)" },
            { "  api_token: \($0)" },
            { "{\"password\": \"\($0)\"}" },
            { "export SYNTHETIC_SECRET=\($0)" },
            { "Authorization: Bearer \($0)" },
            { "-----BEGIN " + "PRIVATE KEY-----\n\($0)\n-----END " + "PRIVATE KEY-----" },
            { "Note for later, the password: \($0) until Friday." },
            { "Open https://example.com/callback?token=\($0)&mode=test to finish." },
        ]
        for secret in secrets {
            for template in templates {
                let text = template(secret)
                let result = terms([Source(text: text, kind: .field), Source(text: text, kind: .conversation)])
                for term in result {
                    TestSupport.expect(!sharesFragment(term, with: secret), "No term may carry part of a secret")
                }
            }
        }

        for text in ["Set `OPENAI_API_KEY` in your env file and restart.", "Read @SYNTHETIC_TOKEN first."] {
            TestSupport.expectEqual(terms([Source(text: text, kind: .conversation)]), [])
        }

        let prose = "the old one was hunter2xyz and then Passw0rd123 but GPT-5, Qwen3, gpt-4o-mini and Llama-3.1-8B are models"
        TestSupport.expectEqual(
            Set(terms([Source(text: prose, kind: .conversation)])),
            ["GPT-5", "Qwen3", "gpt-4o-mini", "Llama-3.1-8B"]
        )
    }

    /// The whole secret or any 8-character piece of it.
    private static func sharesFragment(_ term: String, with secret: String) -> Bool {
        if term.contains(secret) { return true }
        let characters = Array(secret)
        guard characters.count >= 8 else { return false }
        for start in 0...(characters.count - 8) where term.contains(String(characters[start..<start + 8])) {
            return true
        }
        return false
    }

    private static func testUILabelsGiveNothing() {
        let labels = "Show more | Copy code | Edit message | Ask anything | Search | Deep research | Create image"
        TestSupport.expectEqual(terms([Source(text: labels, kind: .nearby)]), [])
        TestSupport.expectEqual(terms([Source(text: "Cloud Storage Pricing Overview", kind: .conversation)]), [])
    }

    private static func testEverydayRunsNeedRepetitionOrTagger() {
        TestSupport.expectEqual(
            terms([Source(text: "We moved the docs into Cursor yesterday.", kind: .conversation)]), []
        )
        TestSupport.expectEqual(
            terms([Source(text: "I switched to Cursor last week and Cursor feels faster.", kind: .conversation)]),
            ["Cursor"]
        )
        TestSupport.expectEqual(terms([Source(text: "We met Will Rose at the meetup.", kind: .conversation)]), [])

        // A tagged span only confirms a run the rules found; "Meet Aoife" is never a term.
        let tagged = terms(
            [Source(text: "We met Will Rose at the meetup. Meet Aoife tomorrow.", kind: .conversation)],
            tagger: { _ in ["Will Rose", "Meet Aoife"] }
        )
        TestSupport.expect(has(tagged, "Will Rose"), "A tagged everyday run is rescued")
        TestSupport.expect(has(tagged, "Aoife"), "A rare name is kept")
        TestSupport.expect(!tagged.contains { $0.contains("Meet") }, "The tagger never creates a term")
    }

    private static func testDeterministicCappedDeduped() {
        let reply = "Wispr Flow and Superwhisper, then GPT-5 in useAuth.ts with Vercel and Supabase."
        let source = [Source(text: reply, kind: .conversation)]
        TestSupport.expectEqual(terms(source), terms(source))
        TestSupport.expectEqual(terms(source, tagger: { _ in [] }), terms(source))

        let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let lower = Array("ab")
        let names: [String] = (0..<40).map { index in
            "Zorblax\(upper[index % 26])\(lower[index / 26])qux"
        }
        let many = terms([Source(text: "we use " + names.joined(separator: " and "), kind: .conversation)])
        TestSupport.expectEqual(many.count, NameExtractor.maxTerms)
        TestSupport.expectEqual(NameExtractor.maxTerms, 30)

        TestSupport.expectEqual(terms([Source(text: "call useAuth now. UseAuth again", kind: .conversation)]), ["useAuth"])

        let field = "Open useAuth.ts and AppState.swift, then call DeepgramStreamingCore.normalizedKeyterms here."
        let fieldTerms = terms([Source(text: field, kind: .field)])
        TestSupport.expectEqual(fieldTerms, ["useAuth", "AppState", "normalizedKeyterms"])
        TestSupport.expect(!fieldTerms.contains { $0.contains(".") }, "No dotted term is ever produced")
    }

    /// A path gives only its file's stem: its folders can name the Mac account.
    private static func testPathsGiveOnlyFileStems() {
        TestSupport.expectEqual(
            terms([Source(
                text: "I read /Users/kaiexample/code/zorblax/Sources/AppState.swift and changed one line.",
                kind: .conversation
            )]),
            ["AppState"]
        )
        TestSupport.expectEqual(
            terms([Source(text: "Open Sources/AppState.swift and src/widgets/Zorblax.tsx next.", kind: .field)]),
            ["AppState", "Zorblax"]
        )
        TestSupport.expectEqual(terms([Source(text: "Ask @alice/frobnicate.ts about it.", kind: .conversation)]), ["frobnicate"])
        let all = terms([Source(text: "see `Sources/AppState.swift` in ~/code/zorblax-lab/useAuth.ts", kind: .conversation)])
        TestSupport.expect(!all.contains { $0.contains("/") || $0.contains("\\") }, "No term carries a path")
    }

    /// A single word also seen on its own stays next to the multi-word term; one seen only
    /// inside a backticked phrase gives way to it.
    private static func testStandaloneWordBesideMultiWordTerm() {
        TestSupport.expectEqual(
            terms([Source(text: "I bought a MacBook yesterday. Later the MacBook Air arrived.", kind: .conversation)]),
            ["MacBook Air", "MacBook"]
        )
        TestSupport.expectEqual(
            terms([Source(text: "we tried Canto first. then we tried Canto Labs too.", kind: .conversation)]),
            ["Canto Labs", "Canto"]
        )
        TestSupport.expectEqual(terms([Source(text: "Try `Zorblax Plinth` today.", kind: .conversation)]), ["Zorblax Plinth"])
    }

    /// Long tokens (an inline SVG path, letter and dash runs) cost linear time, not quadratic.
    private static func testLongTokensExtractQuickly() {
        var state: UInt64 = 7
        func next(_ bound: UInt64) -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (state >> 33) % bound
        }
        var path = ""
        while path.count < 4_000 {
            path += ["M", "l", "c", "h", "v"][Int(next(5))] + "\(next(40)).\(next(10))-\(next(20)).\(next(10))"
        }
        for text in [path, String(repeating: "abcdefghij", count: 400), String(repeating: "a-", count: 3_000)] {
            let started = CFAbsoluteTimeGetCurrent()
            _ = terms([Source(text: "Reply with " + text + " here", kind: .conversation)])
            TestSupport.expect(CFAbsoluteTimeGetCurrent() - started < 0.25, "A long token must not stall extraction")
        }
    }

    private static func testOwnNameTerms() {
        let everyday = EverydayWords.all
        TestSupport.expectEqual(NameExtractor.ownNameTerms(fullName: "Kai Example", everyday: everyday), ["Kai", "Kai Example"])
        TestSupport.expectEqual(NameExtractor.ownNameTerms(fullName: "  Kai   Example ", everyday: everyday), ["Kai", "Kai Example"])
        TestSupport.expectEqual(NameExtractor.ownNameTerms(fullName: "Kai", everyday: everyday), ["Kai"])
        TestSupport.expectEqual(NameExtractor.ownNameTerms(fullName: "Al Example", everyday: everyday), ["Al Example"])
        TestSupport.expectEqual(NameExtractor.ownNameTerms(fullName: "Will Example", everyday: everyday), ["Will Example"])
        for blank in [nil, "", "   "] as [String?] {
            TestSupport.expectEqual(NameExtractor.ownNameTerms(fullName: blank, everyday: everyday), [])
        }
    }
}
