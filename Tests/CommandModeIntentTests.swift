import Foundation

enum CommandModeIntentTests {
    static func run() {
        testSearchCues()
        testQuestionHeuristic()
        testCueStrippingAndPunctuation()
        testSearchURLs()
        testEnginePersistence()
        testWholeFieldCap()
        testPinnedStatuses()
    }

    /// The field stands in for a selection only when it has text and fits the cap, counted in
    /// UTF-16 units like the text-context read it mirrors; anything else is no field.
    private static func testWholeFieldCap() {
        TestSupport.expectEqual(CommandModeIntent.maxWholeFieldLength, 100_000)
        TestSupport.expectEqual(CommandModeIntent.wholeFieldText(nil), nil)
        TestSupport.expectEqual(CommandModeIntent.wholeFieldText(""), nil)
        TestSupport.expectEqual(CommandModeIntent.wholeFieldText(" \n\t"), nil)
        TestSupport.expectEqual(CommandModeIntent.wholeFieldText(" draft "), " draft ")
        let atCap = String(repeating: "a", count: 100_000)
        TestSupport.expectEqual(CommandModeIntent.wholeFieldText(atCap), atCap)
        TestSupport.expectEqual(CommandModeIntent.wholeFieldText(atCap + "b"), nil)
        // One emoji is two UTF-16 units, so this field is one unit over the cap.
        TestSupport.expectEqual(CommandModeIntent.wholeFieldText(String(repeating: "a", count: 99_999) + "🧪"), nil)
    }

    /// A cue opens a search whether or not there is text to edit; it needs a word boundary
    /// and a non-empty query.
    private static func testSearchCues() {
        let cases: [(command: String, editable: Bool, query: String)] = [
            ("search for swift actors", true, "swift actors"),
            ("Search For Swift actors?", true, "Swift actors"),
            ("google rust traits.", false, "rust traits"),
            ("look up the weather", true, "the weather"),
            ("lookup the weather", true, "the weather"),
            ("web search for cats", true, "cats"),
            ("web search cats", true, "cats"),
            ("find online best pizza", false, "best pizza")
        ]
        for testCase in cases {
            TestSupport.expectEqual(
                CommandModeIntent.classify(command: testCase.command, hasEditableText: testCase.editable),
                .webSearch(query: testCase.query)
            )
        }

        TestSupport.expectEqual(CommandModeIntent.classify(command: "searching for typos", hasEditableText: true), .editText)
        TestSupport.expectEqual(CommandModeIntent.classify(command: "search", hasEditableText: true), .editText)
        TestSupport.expectEqual(CommandModeIntent.classify(command: "search", hasEditableText: false), .noTarget)
        TestSupport.expectEqual(CommandModeIntent.classify(command: "", hasEditableText: true), .editText)
        TestSupport.expectEqual(CommandModeIntent.classify(command: "", hasEditableText: false), .noTarget)
    }

    /// Without editable text a question becomes a search; with text to edit it is an instruction.
    private static func testQuestionHeuristic() {
        TestSupport.expectEqual(
            CommandModeIntent.classify(command: "what's the capital of peru", hasEditableText: false),
            .webSearch(query: "what's the capital of peru")
        )
        TestSupport.expectEqual(
            CommandModeIntent.classify(command: "is swift open source?", hasEditableText: false),
            .webSearch(query: "is swift open source")
        )
        TestSupport.expectEqual(
            CommandModeIntent.classify(command: "How do I exit vim", hasEditableText: false),
            .webSearch(query: "How do I exit vim")
        )
        TestSupport.expectEqual(CommandModeIntent.classify(command: "make it shorter", hasEditableText: false), .noTarget)
        TestSupport.expectEqual(
            CommandModeIntent.classify(command: "what's the capital of peru", hasEditableText: true),
            .editText
        )
        TestSupport.expectEqual(CommandModeIntent.classify(command: "make it shorter", hasEditableText: true), .editText)
    }

    private static func testCueStrippingAndPunctuation() {
        TestSupport.expectEqual(
            CommandModeIntent.classify(command: "  search for   c++ & rust!,  ", hasEditableText: true),
            .webSearch(query: "c++ & rust")
        )
        TestSupport.expectEqual(
            CommandModeIntent.classify(command: "Search for 'swift actors'.", hasEditableText: true),
            .webSearch(query: "'swift actors'")
        )
    }

    /// Only the query is percent-encoded, with the ASCII unreserved set, so spaces, reserved
    /// characters and non-ASCII letters can never change the URL's structure.
    private static func testSearchURLs() {
        TestSupport.expectEqual(
            WebSearchEngine.google.url(for: "swift actors")?.absoluteString,
            "https://www.google.com/search?q=swift%20actors"
        )
        TestSupport.expectEqual(
            WebSearchEngine.perplexity.url(for: "a&b")?.absoluteString,
            "https://www.perplexity.ai/search?q=a%26b"
        )
        TestSupport.expectEqual(
            WebSearchEngine.duckDuckGo.url(for: "c++")?.absoluteString,
            "https://duckduckgo.com/?q=c%2B%2B"
        )
        TestSupport.expectEqual(
            WebSearchEngine.google.url(for: "café")?.absoluteString,
            "https://www.google.com/search?q=caf%C3%A9"
        )
        TestSupport.expectEqual(
            WebSearchEngine.google.url(for: "?=/#")?.absoluteString,
            "https://www.google.com/search?q=%3F%3D%2F%23"
        )
        TestSupport.expectEqual(
            WebSearchEngine.google.url(for: "")?.absoluteString,
            "https://www.google.com/search?q="
        )
    }

    private static func testEnginePersistence() {
        let suite = "FreeFlowTests.WebSearchEngine.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(WebSearchEngine.storageKey, "command_mode_search_engine")
        TestSupport.expectEqual(WebSearchEngine.defaultEngine, .google)
        TestSupport.expectEqual(WebSearchEngine.allCases, [.google, .perplexity, .duckDuckGo])
        TestSupport.expectEqual(WebSearchEngine.allCases.map(\.displayName), ["Google", "Perplexity", "DuckDuckGo"])
        for engine in WebSearchEngine.allCases {
            TestSupport.expectEqual(engine.id, engine.rawValue)
        }

        TestSupport.expectEqual(WebSearchEngine.load(from: defaults), .google)
        TestSupport.expect(
            defaults.object(forKey: WebSearchEngine.storageKey) == nil,
            "Loading the default must not persist an engine"
        )

        for engine in WebSearchEngine.allCases {
            defaults.set(engine.rawValue, forKey: WebSearchEngine.storageKey)
            let reloaded = UserDefaults(suiteName: suite)!
            TestSupport.expectEqual(WebSearchEngine.load(from: reloaded), engine)
        }

        defaults.set("bing", forKey: WebSearchEngine.storageKey)
        TestSupport.expectEqual(WebSearchEngine.load(from: defaults), .google)
        defaults.set(42, forKey: WebSearchEngine.storageKey)
        TestSupport.expectEqual(WebSearchEngine.load(from: defaults), .google)
    }

    /// The Run Log compares processing statuses exactly and the overlay truncates long toasts,
    /// so the strings are pinned here. The paths that show them need live capture and are
    /// covered by the manual tests.
    private static func testPinnedStatuses() {
        TestSupport.expectEqual(CommandModeIntent.webSearchProcessingStatus, "Edit mode: web search")
        TestSupport.expectEqual(CommandModeIntent.noTargetProcessingStatus, "Edit mode: no text field")
        TestSupport.expectEqual(
            CommandModeIntent.wholeFieldFailedProcessingStatus, "Edit mode failed, field unchanged (manual)"
        )
        TestSupport.expectEqual(CommandModeIntent.noTargetOverlayMessage, "Edit Mode needs a text field — text copied")
        TestSupport.expectEqual(CommandModeIntent.fieldChangedOverlayMessage, "Field changed — result copied")
        for status in [
            CommandModeIntent.webSearchProcessingStatus, CommandModeIntent.noTargetProcessingStatus,
            CommandModeIntent.wholeFieldFailedProcessingStatus,
            CommandModeIntent.webSearchStatusText, CommandModeIntent.noTargetOverlayMessage,
            CommandModeIntent.fieldChangedOverlayMessage, CommandModeIntent.wholeFieldReplacedStatusText,
            CommandModeIntent.wholeFieldFailedStatusText
        ] {
            TestSupport.expect(!status.hasPrefix("Error:"), "A command outcome must not render as an error row")
        }
        // RecordingOverlay.maxToastMessageLength
        for message in [CommandModeIntent.noTargetOverlayMessage, CommandModeIntent.fieldChangedOverlayMessage] {
            TestSupport.expect(message.count <= 90, "Overlay messages must fit the toast without truncation")
        }
    }
}
