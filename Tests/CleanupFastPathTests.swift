import Foundation

enum CleanupFastPathTests {
    static func run() {
        testAlreadyCleanPositives()
        testAlreadyCleanNegatives()
        testGates()
        testAutoDetectNeedsEnglishText()
        testCustomSystemPrompt()
        testSearchBox()
        testSearchBoxNeedsQueryShape()
        testSearchBoxIgnoresPausePunctuation()
        testPastedText()
        testPlanText()
        testTimedOutText()
        testStatuses()
    }

    /// Light, Casual, no site, no category, no Output Language, Auto-detect, no snippets, the
    /// default prompt: the stop path's usual dictation into a coding app or an unknown field.
    private static func reason(
        _ transcript: String,
        websiteDomain: String? = nil,
        category: DictationAppCategory? = nil,
        cleanupLevel: CleanupLevel = .light,
        style: DictationStyle? = .casual,
        outputLanguage: String = "",
        dictationLanguage: String = "",
        hasSnippetMatches: Bool = false,
        hasCustomSystemPrompt: Bool = false
    ) -> CleanupFastPath.Reason? {
        CleanupFastPath.reason(
            transcript: transcript,
            websiteDomain: websiteDomain,
            category: category,
            cleanupLevel: cleanupLevel,
            style: style,
            outputLanguage: outputLanguage,
            dictationLanguage: dictationLanguage,
            hasSnippetMatches: hasSnippetMatches,
            hasCustomSystemPrompt: hasCustomSystemPrompt
        )
    }

    private static func testAlreadyCleanPositives() {
        for transcript in [
            "Run the tests again.",
            "What's the weather in Tokyo?",
            "Sounds good, see you at 5 PM.",
            "Yes.",
            "Open the settings page!",
            "Sounds good. See you then.",
            "Please send the synthetic quarterly report to the whole team by Friday.",
            // "just" usually carries meaning, a comma the grammar needs, and a three-word sentence.
            "Just ship it.",
            "Run the linter, then push.",
            "Done. See you tomorrow."
        ] {
            TestSupport.expectEqual(reason(transcript), .alreadyClean)
        }
        TestSupport.expectEqual(
            "Please send the synthetic quarterly report to the whole team by Friday."
                .split(whereSeparator: \.isWhitespace).count,
            CleanupFastPath.maximumWords
        )
    }

    /// Anything the model would change goes to the model.
    private static func testAlreadyCleanNegatives() {
        for transcript in [
            "Please send the synthetic quarterly report to the whole team by Friday afternoon.",
            "Um, send the report today.",
            "Send the, uh, report today.",
            "So, like, send it today.",
            "Send it Monday, no wait, Tuesday.",
            "Meet at 2, actually 3.",
            "Scratch that, start over.",
            "Send it Monday, no, Tuesday.",
            "Send it Monday. No, Tuesday.",
            "Envoie-le lundi, non, mardi.",
            "Schick es Montag, nein, Dienstag.",
            "Trimite-l luni, nu, marți.",
            "I mean the blue one.",
            "Send it to Dana. I meant Dan.",
            "Send it Monday, oops, Tuesday.",
            "Whoops, send it Tuesday.",
            "Send it Monday no Tuesday.",
            "First milk, second eggs.",
            "Make a numbered list.",
            "Add a bullet here.",
            "New paragraph please.",
            "Hi Dana comma how are you?",
            "Add a period at the end.",
            "Open app state dot swift.",
            "send the report today.",
            "Can i send it today?",
            "Send the report today",
            "Send the the report today.",
            "The the report is ready.",
            // Stutters and false starts across a comma or dash, and repeated phrases.
            "Can you, can you send it?",
            "I- I think so.",
            "Send it to the, to the team.",
            "The, the report is ready.",
            "I want, I want to go.",
            "Send the \u{2014} the report.",
            "Send the \u{2013} the report.",
            "Send it to the to the team.",
            // Light fixes casing after an inner sentence mark and doubled spaces.
            "Sounds good. see you then.",
            "Done! see you then.",
            "He said \"Done.\" then left.",
            "Hello  world.",
            "Line one.\nLine two.",
            "   ",
            // Punctuation alone (a near-silent Whisper result) goes to cleanup, which returns EMPTY.
            "...",
            ".",
            "?",
            "!",
            "\u{2026}",
            "\"?\"",
            "?!",
            ". . .",
            "(...)",
            "- .",
            // Discourse fillers the prompt removes.
            "It was like really fast.",
            "So the build passed.",
            "Okay so the build passed.",
            "Ok, so run it again.",
            "We ship Friday, right?",
            "The build passed. So we can ship.",
            // Pause punctuation: a fragment split off by a period, a comma beside a function word.
            "Move the button. To the left side.",
            "Run the tests. And then deploy.",
            "Ship the fix. Tonight.",
            "I fixed the bug. Last night.",
            "Open the, settings page.",
            "Send it to the. Design team.",
            "Check, the logs again.",
            "Add a test, for the parser."
        ] {
            TestSupport.expect(reason(transcript) == nil, "Must reach cleanup: \(transcript)")
            TestSupport.expect(!CleanupFastPath.isAlreadyClean(transcript), "Must not be clean: \(transcript)")
            TestSupport.expect(
                reason(transcript, dictationLanguage: "English") == nil,
                "Must reach cleanup in English too: \(transcript)"
            )
        }
        // One letter or digit is enough content: a bare number or a one-word reply stays clean.
        TestSupport.expectEqual(reason("5."), .alreadyClean)
        TestSupport.expectEqual(reason("No."), .alreadyClean)
    }

    private static func testGates() {
        let clean = "Run the tests again."
        TestSupport.expect(reason(clean, cleanupLevel: .medium) == nil, "Medium asked for rewording")
        TestSupport.expect(reason(clean, cleanupLevel: CleanupLevel.none) == nil, "None never takes the fast path")
        TestSupport.expect(reason(clean, outputLanguage: "German") == nil, "Translation needs the model")
        TestSupport.expect(reason(clean, dictationLanguage: "Russian") == nil, "The text rules are English only")
        TestSupport.expect(reason(clean, style: .veryCasual) == nil, "Very casual rewrites casing")
        TestSupport.expect(reason(clean, style: .excited) == nil, "Excited may add exclamation points")
        TestSupport.expect(reason(clean, hasSnippetMatches: true) == nil, "Snippet and file-tag plans go to cleanup")

        TestSupport.expectEqual(reason(clean, dictationLanguage: "English"), .alreadyClean)
        TestSupport.expectEqual(reason(clean, dictationLanguage: " English "), .alreadyClean)
        TestSupport.expectEqual(reason(clean, style: .formal), .alreadyClean)
        TestSupport.expectEqual(reason(clean, style: nil), .alreadyClean)

        // Email keeps the prompt's salutation and closing layout, even for a short clean reply.
        let reply = "Hi Dana, thanks for the update."
        TestSupport.expect(CleanupFastPath.isAlreadyClean(reply), "The synthetic reply must be clean text")
        TestSupport.expect(reason(reply, category: .email, style: .formal) == nil, "Email goes to cleanup")
        for category in [DictationAppCategory.workMessaging, .personalMessaging, .coding, .other] {
            TestSupport.expectEqual(reason(clean, category: category), .alreadyClean)
        }
    }

    /// Auto-detect is the default language, so the English-only rules need English-looking
    /// text: accented or non-Latin letters go to the model.
    private static func testAutoDetectNeedsEnglishText() {
        for transcript in [
            "Este, mándalo hoy.",
            "Te veo mañana.",
            "Äh, ich komme morgen.",
            "Отправь отчёт сегодня."
        ] {
            TestSupport.expect(reason(transcript) == nil, "Auto-detect non-English must reach cleanup: \(transcript)")
            TestSupport.expect(
                !CleanupFastPath.appliesEnglishRules(transcript, dictationLanguage: ""),
                "Not English text: \(transcript)"
            )
        }
        let accented = "Meet at the café."
        TestSupport.expect(reason(accented) == nil, "Auto-detect needs ASCII letters")
        TestSupport.expectEqual(reason(accented, dictationLanguage: "English"), .alreadyClean)
        TestSupport.expect(CleanupFastPath.appliesEnglishRules("Run the tests 2x.", dictationLanguage: ""), "ASCII text")
        TestSupport.expect(
            !CleanupFastPath.appliesEnglishRules("Run the tests again.", dictationLanguage: "German"),
            "An explicit non-English language never applies the English rules"
        )
    }

    /// A custom prompt is the user's own instructions, so already-clean text and a clean
    /// search-box query still run it.
    private static func testCustomSystemPrompt() {
        let clean = "Please review the color palette."
        TestSupport.expect(reason(clean, hasCustomSystemPrompt: true) == nil, "A custom prompt must run")
        TestSupport.expectEqual(reason(clean), .alreadyClean)
        let query = "color of the sky at sunset"
        for level in [CleanupLevel.light, .medium] {
            TestSupport.expect(
                reason(query, websiteDomain: "google.com", cleanupLevel: level, hasCustomSystemPrompt: true) == nil,
                "A custom prompt must run in the search box too"
            )
            TestSupport.expectEqual(reason(query, websiteDomain: "google.com", cleanupLevel: level), .searchBox)
        }

        for prompt in ["", "  \n", PostProcessingService.defaultSystemPrompt, "\n" + PostProcessingService.defaultSystemPrompt + "\n"] {
            TestSupport.expect(!CleanupFastPath.isCustomSystemPrompt(prompt), "The default prompt is not custom")
        }
        TestSupport.expect(CleanupFastPath.isCustomSystemPrompt("Use British spelling."), "A saved prompt is custom")
    }

    /// A clean query in the google.com search box skips cleanup even lowercase and without an
    /// end mark, at Light or Medium, except at None, with an Output Language, in another
    /// language, with a snippet trigger or with a custom prompt. Messy wording still goes to
    /// the model.
    private static func testSearchBox() {
        let query = "weather in tokyo"
        TestSupport.expectEqual(reason(query, websiteDomain: "google.com"), .searchBox)
        TestSupport.expectEqual(reason(query, websiteDomain: "google.com", cleanupLevel: .medium), .searchBox)
        TestSupport.expectEqual(reason(query, websiteDomain: "google.com", style: .excited), .searchBox)
        TestSupport.expectEqual(reason(query, websiteDomain: "google.com", dictationLanguage: "English"), .searchBox)
        TestSupport.expectEqual(reason("can i freeze bread", websiteDomain: "google.com"), .searchBox)
        TestSupport.expectEqual(reason("Weather in Tokyo?", websiteDomain: "google.com"), .searchBox)
        // A snippet or file-tag trigger goes to cleanup, as everywhere else, at any level.
        for level in [CleanupLevel.light, .medium] {
            TestSupport.expect(
                reason(query, websiteDomain: "google.com", cleanupLevel: level, hasSnippetMatches: true) == nil,
                "A search with a snippet trigger reaches cleanup"
            )
            TestSupport.expect(
                reason("Weather in Tokyo?", websiteDomain: "google.com", cleanupLevel: level, hasSnippetMatches: true) == nil,
                "A clean-shaped search with a snippet trigger reaches cleanup"
            )
        }
        TestSupport.expect(
            reason(query, websiteDomain: "google.com", outputLanguage: "German") == nil,
            "An Output Language still translates"
        )
        TestSupport.expect(
            reason(query, websiteDomain: "google.com", cleanupLevel: CleanupLevel.none) == nil,
            "None keeps its own raw path"
        )
        // The wording rules are English, so another language goes to the model.
        TestSupport.expect(
            reason("wetter in berlin", websiteDomain: "google.com", dictationLanguage: "German") == nil,
            "An explicit non-English search reaches cleanup"
        )
        TestSupport.expect(reason("clima en tokio mañana", websiteDomain: "google.com") == nil, "Accented Auto-detect text")

        // Fillers, self-corrections, repeats and spoken commands are cleaned, at any level.
        for messy in [
            "um what's the uh weather in tokyo no wait osaka",
            "um weather in tokyo no wait osaka",
            "um weather in tokyo",
            "weather in tokyo no wait osaka",
            "weather in tokyo, no, osaka",
            "flights to osaka actually kyoto",
            "flights to osaka scratch that kyoto",
            "best the the pizza near me",
            "weather in tokyo question mark",
            "first milk second eggs",
            "like, best pizza near me",
            "best pizza near me i mean tacos",
            "best pizza near me I meant tacos",
            "weather in tokyo no osaka",
            "flights to osaka oops kyoto",
            "weather in, in tokyo",
            "pizza near me, near me",
            "weather in tokyo - in tokyo",
            "Weather in Tokyo, um, tomorrow?",
            "Weather in Tokyo. No wait, Osaka.",
            "weather in tokyo comma japan",
            "so cheap flights to boston",
            "okay so pizza near me",
            "cheap flights to boston right?",
            // Over-inclusive: any "like" goes to the model.
            "pizza places like this one"
        ] {
            TestSupport.expect(reason(messy, websiteDomain: "google.com") == nil, "Messy search reaches cleanup: \(messy)")
            TestSupport.expect(
                reason(messy, websiteDomain: "google.com", cleanupLevel: .medium) == nil,
                "Messy search reaches Medium cleanup: \(messy)"
            )
            TestSupport.expect(!CleanupFastPath.isSearchQuery(messy), "Messy text is not a clean query: \(messy)")
        }
        let messy = "um weather in tokyo no wait osaka"

        for domain in ["google.com", "www.google.com", " GOOGLE.COM "] {
            TestSupport.expect(CleanupFastPath.isSearchBox(websiteDomain: domain), "Search box: \(domain)")
        }
        for domain in [
            "mail.google.com", "docs.google.com", "gemini.google.com", "google.com.evil.invalid", "notgoogle.com", ""
        ] {
            TestSupport.expect(!CleanupFastPath.isSearchBox(websiteDomain: domain), "Not a search box: \(domain)")
            TestSupport.expect(reason(messy, websiteDomain: domain) == nil, "Messy text elsewhere is cleaned: \(domain)")
        }
        TestSupport.expect(!CleanupFastPath.isSearchBox(websiteDomain: nil), "No domain is not a search box")
        TestSupport.expect(reason(messy, websiteDomain: nil) == nil, "Messy text without a domain is cleaned")
        // Lowercase without an end mark is clean only in the search box.
        TestSupport.expect(reason(query, websiteDomain: "mail.google.com") == nil, "A lowercase fragment elsewhere is cleaned")
        TestSupport.expect(
            reason(query, websiteDomain: "google.com", hasCustomSystemPrompt: true) == nil,
            "A custom prompt runs in the search box"
        )
    }

    /// The pause-punctuation rule is the already-clean rule's alone: a pause comma in a search
    /// query is harmless, so the search box changes only for fillers.
    private static func testSearchBoxIgnoresPausePunctuation() {
        for query in ["flights to boston, for the weekend", "Weather in Tokyo. Tomorrow."] {
            TestSupport.expectEqual(reason(query, websiteDomain: "google.com"), .searchBox)
            TestSupport.expect(reason(query) == nil, "Pause punctuation outside the search box reaches cleanup: \(query)")
        }
        TestSupport.expect(
            !CleanupFastPath.isAlreadyClean("Flights to Boston, for the weekend."),
            "A comma before a function word is a pause"
        )
    }

    /// Text context knows only the domain, so a Maps review or any other google.com field
    /// matches too: only a short single-line query skips cleanup, and filler or punctuation
    /// alone never does.
    private static func testSearchBoxNeedsQueryShape() {
        let review = """
        um so the food was great, uh, the service was slow, no wait, it was fine actually, and \
        the synthetic dessert menu was long but we only tried two things and both were very good \
        so I would come back again with friends next month for the lunch menu, which looked cheaper
        """
        TestSupport.expect(review.split(whereSeparator: \.isWhitespace).count > 50, "The synthetic review must be long")
        TestSupport.expect(reason(review, websiteDomain: "google.com") == nil, "A long google.com dictation is cleaned")
        TestSupport.expect(
            reason("Weather in Tokyo.\nWeather in Osaka.", websiteDomain: "google.com") == nil,
            "Two lines are not a query"
        )

        let twentyWords = (1...CleanupFastPath.searchBoxMaximumWords).map { "synthetic\($0)" }.joined(separator: " ")
        TestSupport.expectEqual(reason(twentyWords, websiteDomain: "google.com"), .searchBox)
        TestSupport.expect(
            reason(twentyWords + " query", websiteDomain: "google.com") == nil,
            "A query longer than the cap is cleaned"
        )

        for fillerOnly in ["Um.", "uh", "Um, uh.", "So yeah.", "hmm...", "...", "?", "!"] {
            TestSupport.expect(!CleanupFastPath.isSearchQuery(fillerOnly), "Filler is not a query: \(fillerOnly)")
            TestSupport.expect(
                reason(fillerOnly, websiteDomain: "google.com") == nil,
                "Filler-only search-box text reaches cleanup: \(fillerOnly)"
            )
        }
        // A leading "no" is a search term, not a self-correction.
        for query in ["weather in tokyo", "Flights to Osaka?", "2 + 2", "Wetter in Berlin.", "can i freeze bread", "no bake cookies"] {
            TestSupport.expect(CleanupFastPath.isSearchQuery(query), "Query: \(query)")
        }
        TestSupport.expect(!CleanupFastPath.isSearchQuery("   "), "Blank text is not a query")
    }

    private static func testPastedText() {
        func pasted(_ text: String, style: DictationStyle? = .casual, dictationLanguage: String = "") -> String {
            CleanupFastPath.pastedText(text, style: style, dictationLanguage: dictationLanguage)
        }
        TestSupport.expectEqual(pasted("Run the tests again."), "Run the tests again")
        TestSupport.expectEqual(pasted("Run the tests again.", dictationLanguage: "English"), "Run the tests again")
        for unchanged in [
            "Done?",
            "Great!",
            "Meet at 5 p.m.",
            "Wait...",
            "Sounds good. See you then.",
            "Please send the synthetic quarterly report to the whole team by Friday afternoon.",
            "Insert ⟦S1⟧"
        ] {
            TestSupport.expectEqual(pasted(unchanged), unchanged)
        }
        for style in [DictationStyle.formal, .excited, nil] {
            TestSupport.expectEqual(pasted("Run the tests again.", style: style), "Run the tests again.")
        }

        // The Style rule is English only, as in the prompt: an explicit non-English language
        // or accented Auto-detect text keeps its period.
        TestSupport.expectEqual(pasted("Wetter in Berlin.", dictationLanguage: "German"), "Wetter in Berlin.")
        TestSupport.expectEqual(pasted("Te veo mañana."), "Te veo mañana.")
    }

    /// The text the stop path pastes for each outcome, composed from the snippet plan.
    private static func testPlanText() {
        // Applied to the placeholder text, so a snippet payload's own punctuation is never touched.
        let plan = SnippetExpansionPlan(
            placeholderText: "Sign as ⟦S1⟧",
            expandedText: "Sign as Synthetic Corp Inc.",
            expansions: ["Synthetic Corp Inc."]
        )
        TestSupport.expectEqual(
            CleanupFastPath.pastedText(for: plan, style: .casual, dictationLanguage: ""),
            "Sign as Synthetic Corp Inc."
        )
        // On the expanded text the same rule would trim the payload's own period.
        TestSupport.expectEqual(
            CleanupFastPath.pastedText(plan.expandedText, style: .casual, dictationLanguage: ""),
            "Sign as Synthetic Corp Inc"
        )

        let plain = SnippetExpansionPlan(
            placeholderText: "Run the tests again.",
            expandedText: "Run the tests again.",
            expansions: []
        )
        TestSupport.expectEqual(CleanupFastPath.pastedText(for: plain, style: .casual, dictationLanguage: ""), "Run the tests again")
        TestSupport.expectEqual(CleanupFastPath.pastedText(for: plain, style: .formal, dictationLanguage: ""), "Run the tests again.")

        // The deadline fallback pastes the expanded text, list-formatted when counted.
        let counted = SnippetExpansionPlan(
            placeholderText: "things to buy first milk second eggs third ⟦S1⟧",
            expandedText: "things to buy first milk second eggs third bread",
            expansions: ["bread"]
        )
        TestSupport.expectEqual(
            CleanupFastPath.timedOutText(for: counted),
            SpokenListFormatter.numberedList(from: counted.expandedText) ?? "missing list"
        )
        TestSupport.expectEqual(CleanupFastPath.timedOutText(for: plain), "Run the tests again.")
    }

    private static func testTimedOutText() {
        let counted = "things to buy first milk second eggs third bread"
        let formatted = SpokenListFormatter.numberedList(from: counted)
        TestSupport.expect(formatted != nil, "The synthetic counted list must format")
        TestSupport.expectEqual(CleanupFastPath.timedOutText(counted), formatted ?? "")
        TestSupport.expectEqual(CleanupFastPath.timedOutText("Synthetic plain sentence."), "Synthetic plain sentence.")
    }

    /// The Run Log renders the stored status verbatim and keys its error and silence-gate
    /// rows on specific strings, so the wording is pinned. AppState writes these on the stop
    /// path, which needs live capture and is covered by the manual test.
    private static func testStatuses() {
        TestSupport.expectEqual(CleanupFastPath.alreadyCleanProcessingStatus, "Fast path: already clean, skipped cleanup")
        TestSupport.expectEqual(CleanupFastPath.searchBoxProcessingStatus, "Fast path: search box, skipped cleanup")
        TestSupport.expectEqual(CleanupFastPath.timedOutProcessingStatus, "Cleanup timed out, using raw transcript")
        TestSupport.expectEqual(
            CleanupFastPath.timedOutRetryProcessingStatus,
            "Cleanup timed out on retry, using raw transcript"
        )
        TestSupport.expectEqual(
            CleanupFastPath.processingStatus(for: .alreadyClean),
            CleanupFastPath.alreadyCleanProcessingStatus
        )
        TestSupport.expectEqual(
            CleanupFastPath.processingStatus(for: .searchBox),
            CleanupFastPath.searchBoxProcessingStatus
        )
        for status in [CleanupFastPath.alreadyCleanProcessingStatus, CleanupFastPath.searchBoxProcessingStatus] {
            TestSupport.expect(status.contains("Fast path"), "A fast-path status must say so")
        }
        for status in [CleanupFastPath.timedOutProcessingStatus, CleanupFastPath.timedOutRetryProcessingStatus] {
            TestSupport.expect(status.contains("Cleanup timed out"), "A timeout status must say so")
        }
        for status in [
            CleanupFastPath.alreadyCleanProcessingStatus,
            CleanupFastPath.searchBoxProcessingStatus,
            CleanupFastPath.timedOutProcessingStatus,
            CleanupFastPath.timedOutRetryProcessingStatus
        ] {
            TestSupport.expect(!status.hasPrefix("Error:"), "Must not render as an error row: \(status)")
            TestSupport.expect(
                status != SilenceGatePreference.skippedProcessingStatus,
                "Must not render as a silence-gated row: \(status)"
            )
        }
    }
}
