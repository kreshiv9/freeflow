import Foundation

private actor AssemblyAIRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        requests.append(request)
    }
}

/// Synthetic keys, invented terms and hand-written JSON fixtures only. No socket is
/// opened: the service tests never call start(), and validation uses a stub transport.
enum AssemblyAIStreamingCoreTests {
    private typealias Core = AssemblyAIStreamingCore
    private typealias Scenario = AssemblyAIStreamingCore.PromptScenario
    private typealias Policy = AssemblyAIStreamingCore.CommitPolicy
    private static let syntheticKey = "synthetic-assemblyai-key"

    static func run() async {
        testListenURL()
        testLanguageCodes()
        testKeytermEncoding()
        testKeytermNormalization()
        testUpdateTermsUsesKeytermPlan()
        testUpdateConfigurationMessage()
        testPromptTemplates()
        testPromptScenarioResolution()
        testScreenTextNeverReachesPrompt()
        testOverrides()
        testParsesServerMessages()
        testFailureClassification()
        testTurnAssembler()
        testCommitConstants()
        testCommitDecision()
        testBacklogEstimate()
        testChunking()
        testKeyValidationRequestAndMapping()
        await testValidateAPIKeyWithStubTransport()
        await testServiceWithoutNetwork()
    }

    private static func configuration(
        languageCode: String = "en",
        keyterms: [String] = [],
        keytermsEnabled: Bool = true,
        promptScenario: Scenario? = nil,
        mode: Core.Mode? = nil
    ) -> Core.Configuration {
        Core.Configuration(
            apiKey: syntheticKey,
            languageCode: languageCode,
            sampleRate: 16000,
            keyterms: keyterms,
            keytermsEnabled: keytermsEnabled,
            promptScenario: promptScenario,
            mode: mode
        )
    }

    private static func query(for configuration: Core.Configuration) -> String {
        let url = Core.listenURL(for: configuration)
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
    }

    /// The decoded value of one query item, or nil when the item is absent.
    private static func queryValue(_ name: String, in configuration: Core.Configuration) -> String? {
        let items = URLComponents(url: Core.listenURL(for: configuration), resolvingAgainstBaseURL: false)?.queryItems
        return items?.first { $0.name == name }?.value
    }

    private static func jsonStrings(_ text: String?) -> [String]? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String]
    }

    private static func jsonObject(_ text: String?) -> [String: Any]? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: URL

    private static func testListenURL() {
        let base = "speech_model=universal-3-6-pro&language_codes=%5B%22en%22%5D&encoding=pcm_s16le"
            + "&sample_rate=16000&min_turn_silence=5000&max_turn_silence=10000&inactivity_timeout=30"
        TestSupport.expectEqual(query(for: configuration()), base)

        let full = configuration(keyterms: ["Wispr Flow", "C#"], promptScenario: .dictation, mode: .maxAccuracy)
        TestSupport.expectEqual(
            query(for: full),
            base + "&mode=max_accuracy&prompt=A%20person%20dictating%20text%20on%20a%20computer."
                + "&keyterms_prompt=%5B%22Wispr%20Flow%22%2C%22C%23%22%5D"
        )

        let url = Core.listenURL(for: full)
        TestSupport.expectEqual(url.scheme, "wss")
        TestSupport.expectEqual(url.host, "streaming.assemblyai.com")
        TestSupport.expectEqual(url.path, "/v3/ws")
        TestSupport.expect(!url.absoluteString.contains(syntheticKey), "The key must never be in the URL")
        TestSupport.expect(!url.absoluteString.contains("format_turns"), "Universal-3.6 Pro always formats turns")
        TestSupport.expect(!url.absoluteString.contains("token="), "Auth goes in the header, not a token item")
        TestSupport.expectEqual(Core.authorizationHeaderValue(apiKey: " synthetic-key \n"), "synthetic-key")

        TestSupport.expectEqual(queryValue("mode", in: configuration()), nil)
        TestSupport.expectEqual(queryValue("mode", in: configuration(mode: .minLatency)), "min_latency")
        TestSupport.expectEqual(queryValue("mode", in: configuration(mode: .balanced)), "balanced")
        TestSupport.expectEqual(queryValue("prompt", in: configuration()), nil)
        TestSupport.expectEqual(queryValue("keyterms_prompt", in: configuration()), nil)
    }

    private static func testLanguageCodes() {
        for auto in [nil, "", "  "] as [String?] {
            TestSupport.expectEqual(Core.languageCode(for: auto), "en")
        }
        TestSupport.expectEqual(Core.languageCode(for: "EN"), "en")
        TestSupport.expectEqual(Core.languageCode(for: "ES "), "es")
        TestSupport.expectEqual(Core.languageCode(for: "ro"), "ro")
        // Languages the app offers that AssemblyAI does not list never stream in English.
        for unlisted in ["pl", "uk", "cs", "el", "th", "id", "hu", "xx"] {
            TestSupport.expectEqual(Core.languageCode(for: unlisted), nil)
        }
        TestSupport.expectEqual(Core.supportedLanguageCodes.count, 32)
        TestSupport.expectEqual(jsonStrings(queryValue("language_codes", in: configuration(languageCode: "es"))), ["es"])
    }

    private static func testKeytermEncoding() {
        let terms = ["Smith & Sons", "C#", "a+b", #"say "hi""#, #"back\slash"#, "x=y", "100%", "Zoë", "東京"]
        let config = configuration(keyterms: terms)
        TestSupport.expectEqual(jsonStrings(queryValue("keyterms_prompt", in: config)), terms)

        let raw = query(for: config)
        guard let range = raw.range(of: "keyterms_prompt=") else {
            fatalError("keyterms_prompt missing from \(raw)")
        }
        let value = String(raw[range.upperBound...])
        for character in ["&", "#", "+", " ", "\"", "=", "\\"] {
            TestSupport.expect(!value.contains(character), "\(character) must be percent-encoded in keyterms_prompt")
        }
        TestSupport.expectEqual(jsonStrings(value.removingPercentEncoding), terms)
    }

    private static func testKeytermNormalization() {
        let fifty = String(repeating: "k", count: 50)
        let fiftyOne = String(repeating: "m", count: 51)
        TestSupport.expectEqual(
            Core.normalizedKeyterms(["  Wispr \t Flow ", "", "  \n", fifty, fiftyOne, "wispr flow", "Kai"]),
            ["Wispr Flow", fifty, "Kai"]
        )
        let many = (0..<150).map { "Term\($0)" }
        TestSupport.expectEqual(Core.normalizedKeyterms(many), Array(many.prefix(100)))
        let normalized = Core.normalizedKeyterms(many + ["  A  b "])
        TestSupport.expectEqual(Core.normalizedKeyterms(normalized), normalized)

        TestSupport.expectEqual(queryValue("keyterms_prompt", in: configuration(keyterms: ["", "   "])), nil)
        TestSupport.expectEqual(
            queryValue("keyterms_prompt", in: configuration(keyterms: ["Wispr Flow"], keytermsEnabled: false)), nil
        )
    }

    private static func testUpdateTermsUsesKeytermPlan() {
        let secretLike = "gh" + "p_" + String(repeating: "FAKEfake", count: 4)
        let longName = String(repeating: "n", count: 55)
        let plan = Core.updateTerms(
            connect: ["Wispr Flow", "wispr flow", "Synthetic Term"],
            screenTerms: ["Supabase", "devbox.example.internal", secretLike, longName, "Kai Example"],
            identifiers: ["useAuth", "appState.isRecording"]
        )
        TestSupport.expectEqual(plan?.terms, ["Wispr Flow", "Synthetic Term", "Supabase", "Kai Example", "useAuth"])
        TestSupport.expectEqual(plan?.screenCount, 2)
        TestSupport.expectEqual(plan?.identifierCount, 1)
        TestSupport.expect(
            Core.updateTerms(connect: ["Synthetic Term"], screenTerms: ["synthetic term", longName], identifiers: ["a.b"]) == nil,
            "No update when nothing new fits"
        )
        let full = (0..<100).map { "term\($0)" }
        TestSupport.expect(
            Core.updateTerms(connect: full, screenTerms: ["Supabase"], identifiers: []) == nil,
            "No update when the connect list is at the cap"
        )
    }

    private static func testUpdateConfigurationMessage() {
        TestSupport.expectEqual(
            Core.updateConfigurationMessage(keyterms: ["A", " B ", "a"], prompt: nil),
            #"{"keyterms_prompt":["A","B"],"type":"UpdateConfiguration"}"#
        )
        TestSupport.expectEqual(
            Core.updateConfigurationMessage(keyterms: nil, prompt: .email),
            #"{"prompt":"A person dictating an email message.","type":"UpdateConfiguration"}"#
        )
        TestSupport.expectEqual(
            Core.updateConfigurationMessage(keyterms: ["A"], prompt: .aiChat),
            #"{"keyterms_prompt":["A"],"prompt":"A person dictating a message to an AI chat assistant.","type":"UpdateConfiguration"}"#
        )
        // [] would clear every keyterm, so an empty list is left out.
        TestSupport.expectEqual(
            Core.updateConfigurationMessage(keyterms: [], prompt: .email),
            #"{"prompt":"A person dictating an email message.","type":"UpdateConfiguration"}"#
        )
        TestSupport.expectEqual(Core.updateConfigurationMessage(keyterms: ["  "], prompt: nil), nil)
        TestSupport.expectEqual(Core.updateConfigurationMessage(keyterms: nil, prompt: nil), nil)
    }

    // MARK: Prompt

    private static func testPromptTemplates() {
        TestSupport.expectEqual(Core.sendsPrompt, true)
        TestSupport.expectEqual(
            Scenario.allCases.map(\.rawValue), ["coding", "ai-chat", "search", "email", "terminal", "dictation"]
        )
        TestSupport.expectEqual(Set(Scenario.allCases.map(\.prompt)).count, Scenario.allCases.count)
        for scenario in Scenario.allCases {
            let words = scenario.prompt.split(whereSeparator: \.isWhitespace).count
            TestSupport.expect((5...15).contains(words), "\(scenario) prompt must be 5-15 words, got \(words)")
            TestSupport.expect(scenario.prompt.count <= Core.maxPromptCharacters, "\(scenario) prompt is too long")
            for brand in ["Claude", "ChatGPT", "Google", "OpenAI", "Anthropic", "Gmail"] {
                TestSupport.expect(!scenario.prompt.contains(brand), "\(scenario) prompt must not name \(brand)")
            }
            TestSupport.expectEqual(queryValue("prompt", in: configuration(promptScenario: scenario)), scenario.prompt)
            TestSupport.expectEqual(Scenario(rawValue: scenario.rawValue), scenario)
        }
    }

    private static func testPromptScenarioResolution() {
        let cases: [(String?, String?, Scenario)] = [
            ("com.microsoft.VSCode", nil, .codingAssistant),
            ("com.todesktop.230313mzl4w4u92", nil, .codingAssistant),
            ("com.apple.Safari", "github.com", .codingAssistant),
            ("com.apple.Terminal", nil, .terminal),
            ("com.googlecode.iterm2", nil, .terminal),
            ("com.openai.codex", nil, .aiChat),
            ("com.anthropic.claudefordesktop", nil, .aiChat),
            ("com.google.Chrome", "chatgpt.com", .aiChat),
            ("com.apple.Safari", "claude.ai", .aiChat),
            ("com.google.Chrome", "google.com", .googleSearch),
            ("com.google.Chrome", "www.google.com", .googleSearch),
            ("com.google.Chrome", "mail.google.com", .email),
            ("com.apple.mail", nil, .email),
            ("com.google.Chrome", nil, .dictation),
            ("com.apple.TextEdit", nil, .dictation),
            ("com.tinyspeck.slackmacgap", nil, .dictation),
            (nil, nil, .dictation),
        ]
        for (bundle, domain, expected) in cases {
            TestSupport.expectEqual(Scenario.resolve(bundleIdentifier: bundle, websiteDomain: domain), expected)
        }
    }

    /// Text context carries screen text, titles and names; only the bundle and domain pick
    /// the prompt, so none of it can reach the prompt the URL or an update carries.
    private static func testScreenTextNeverReachesPrompt() {
        let markers = ["ZqxFieldBefore", "ZqxSelected", "ZqxFieldAfter", "ZqxNearby", "ZqxWindowTitle", "ZqxScreenName"]
        let userName = "Zqx Example Person"
        var snapshot = TextContextSnapshot()
        snapshot.appName = "Google Chrome"
        snapshot.bundleIdentifier = "com.google.Chrome"
        snapshot.category = .aiChat
        snapshot.websiteDomain = "chatgpt.com"
        snapshot.windowTitle = "ZqxWindowTitle - \(userName)"
        snapshot.textBeforeCursor = "ZqxFieldBefore"
        snapshot.selectedText = "ZqxSelected"
        snapshot.textAfterCursor = "ZqxFieldAfter"
        snapshot.nearbyText = "ZqxNearby \(userName)"
        snapshot.contextTerms = ["ZqxScreenName", userName]

        let scenario = Scenario.resolve(bundleIdentifier: snapshot.bundleIdentifier, websiteDomain: snapshot.websiteDomain)
        TestSupport.expectEqual(scenario, .aiChat)
        let urlPrompt = queryValue("prompt", in: configuration(promptScenario: scenario)) ?? ""
        let updatePrompt = jsonObject(Core.updateConfigurationMessage(keyterms: nil, prompt: scenario))?["prompt"] as? String ?? ""
        let combinedUpdate = Core.updateConfigurationMessage(keyterms: snapshot.contextTerms, prompt: scenario)
        let combinedPrompt = jsonObject(combinedUpdate)?["prompt"] as? String ?? ""
        for prompt in [urlPrompt, updatePrompt, combinedPrompt] {
            TestSupport.expect(Scenario.allCases.map(\.prompt).contains(prompt), "The prompt must be a fixed template")
            for forbidden in markers + [userName, "chatgpt", "Chrome"] {
                TestSupport.expect(!prompt.contains(forbidden), "\(forbidden) must not reach the prompt")
            }
        }

        // Even a bundle or domain carrying a marker only selects a template.
        let sentinel = Scenario.resolve(bundleIdentifier: "com.zqx.sentinel", websiteDomain: "zqx-sentinel.example")
        TestSupport.expectEqual(sentinel, .dictation)
        TestSupport.expect(!sentinel.prompt.lowercased().contains("zqx"), "A domain must never reach the prompt")
    }

    private static func testOverrides() {
        typealias Overrides = Core.Overrides
        TestSupport.expectEqual(Overrides.promptEnabledStorageKey, "assemblyai_prompt_enabled")
        TestSupport.expectEqual(Overrides.keytermsEnabledStorageKey, "assemblyai_keyterms_enabled")
        TestSupport.expectEqual(Overrides.modeStorageKey, "assemblyai_mode")

        let suite = "FreeFlowTests.AssemblyAIOverrides.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(Overrides.load(from: defaults), Overrides(promptEnabled: true, keytermsEnabled: true, mode: nil))
        for key in [Overrides.promptEnabledStorageKey, Overrides.keytermsEnabledStorageKey, Overrides.modeStorageKey] {
            TestSupport.expect(defaults.object(forKey: key) == nil, "Loading must not persist \(key)")
        }

        defaults.set(false, forKey: Overrides.promptEnabledStorageKey)
        defaults.set(false, forKey: Overrides.keytermsEnabledStorageKey)
        defaults.set("max_accuracy", forKey: Overrides.modeStorageKey)
        TestSupport.expectEqual(
            Overrides.load(from: defaults), Overrides(promptEnabled: false, keytermsEnabled: false, mode: .maxAccuracy)
        )

        defaults.set("false", forKey: Overrides.promptEnabledStorageKey)
        defaults.set("no", forKey: Overrides.keytermsEnabledStorageKey)
        defaults.set("turbo", forKey: Overrides.modeStorageKey)
        TestSupport.expectEqual(Overrides.load(from: defaults), Overrides())
        defaults.set(3, forKey: Overrides.modeStorageKey)
        TestSupport.expectEqual(Overrides.load(from: defaults).mode, nil)
        defaults.set("min_latency", forKey: Overrides.modeStorageKey)
        TestSupport.expectEqual(Overrides.load(from: defaults).mode, .minLatency)
    }

    // MARK: Messages

    private static func message(_ json: String) -> Core.ServerMessage {
        Core.ServerMessage(data: Data(json.utf8))
    }

    private static func testParsesServerMessages() {
        TestSupport.expectEqual(
            message(#"{"type":"Begin","id":"synthetic-id","expires_at":1,"configuration":{"model":"universal-3-6-pro","mode":"balanced"}}"#),
            .begin
        )
        TestSupport.expectEqual(
            message(#"{"type":"Turn","turn_order":0,"end_of_turn":false,"turn_is_formatted":true,"transcript":"hello wor","utterance":"","words":[{"text":"hello","start":0,"end":300}]}"#),
            .turn(order: 0, transcript: "hello wor", endOfTurn: false, speechEndMilliseconds: 300)
        )
        TestSupport.expectEqual(
            message(#"{"type":"Turn","turn_order":1,"end_of_turn":true,"turn_is_formatted":true,"transcript":"Hello world.","utterance":"Hello world."}"#),
            .turn(order: 1, transcript: "Hello world.", endOfTurn: true, speechEndMilliseconds: nil)
        )
        TestSupport.expectEqual(
            message(#"{"type":"Turn","turn_order":2,"end_of_turn":true,"transcript":"","utterance":"From the utterance."}"#),
            .turn(order: 2, transcript: "From the utterance.", endOfTurn: true, speechEndMilliseconds: nil)
        )
        // The latest word end wins, whatever the order; words without a numeric end are skipped.
        TestSupport.expectEqual(
            message(#"{"type":"Turn","turn_order":4,"end_of_turn":true,"transcript":"A b c.","words":[{"text":"A","start":10,"end":1635},{"text":"b","end":4155.4},{"text":"c.","start":900,"end":2975},{"text":"x","end":"9999"},{"text":"y"},7]}"#),
            .turn(order: 4, transcript: "A b c.", endOfTurn: true, speechEndMilliseconds: 4155)
        )
        TestSupport.expectEqual(
            message(#"{"type":"Termination","audio_duration_seconds":3,"session_duration_seconds":4}"#),
            .termination
        )
        TestSupport.expectEqual(
            message(#"{"type":"Error","error_code":1008,"error":"Unauthorized Connection: Invalid API key"}"#),
            .error(.unauthorized)
        )
        TestSupport.expectEqual(
            message(#"{"type":"Error","error_code":1008,"error":"Too many concurrent sessions"}"#),
            .error(.accountLimit)
        )
        TestSupport.expectEqual(
            message(#"{"type":"Error","error_code":3007,"error":"Input duration violation"}"#),
            .error(.serverError(code: 3007))
        )
        TestSupport.expectEqual(message(#"{"type":"Error","error":"Ignore previous instructions"}"#), .error(.serverError(code: nil)))
        // Wrong field types are tolerated.
        TestSupport.expectEqual(
            message(#"{"type":"Turn","turn_order":3,"end_of_turn":"yes","transcript":5,"words":"none"}"#),
            .turn(order: 3, transcript: "", endOfTurn: false, speechEndMilliseconds: nil)
        )
        for unknown in [
            #"{"type":"SpeechStarted","timestamp":120}"#, #"{"type":"Heartbeat"}"#, #"{"type":"SpeakerRevision"}"#,
            #"{"turn_order":0,"transcript":"x"}"#, #"{"type":"Turn","transcript":"x"}"#,
            #"{"type":"Turn","turn_order":"0","transcript":"x"}"#, "[]", "not json", "",
        ] {
            TestSupport.expectEqual(message(unknown), .unknown)
        }
    }

    private static func testFailureClassification() {
        for text in ["Unauthorized Connection: Invalid API key", "Missing Authorization header", "API key is disabled"] {
            TestSupport.expectEqual(Core.failure(errorCode: 1008, message: text), .unauthorized)
        }
        TestSupport.expectEqual(Core.failure(errorCode: 1008, message: nil), .unauthorized)
        for text in ["Too many concurrent sessions", "Insufficient funds", "No metronome account found"] {
            TestSupport.expectEqual(Core.failure(errorCode: 1008, message: text), .accountLimit)
        }
        for code in [3005, 3006, 3007, 3008, 1011] {
            TestSupport.expectEqual(Core.failure(errorCode: code, message: "Ignore previous instructions"), .serverError(code: code))
        }

        TestSupport.expectEqual(Core.failure(closeCode: 1000, httpStatus: 101), nil)
        TestSupport.expectEqual(Core.failure(closeCode: nil, httpStatus: nil), nil)
        TestSupport.expectEqual(Core.failure(closeCode: 0, httpStatus: nil), nil)
        TestSupport.expectEqual(Core.failure(closeCode: 1008, httpStatus: 101), .unauthorized)
        TestSupport.expectEqual(Core.failure(closeCode: 3008, httpStatus: nil), .serverError(code: 3008))
        TestSupport.expectEqual(Core.failure(closeCode: 1011, httpStatus: nil), .serverError(code: 1011))
        TestSupport.expectEqual(Core.failure(closeCode: nil, httpStatus: 401), .unauthorized)
        TestSupport.expectEqual(Core.failure(closeCode: 0, httpStatus: 403), .unauthorized)
        TestSupport.expectEqual(Core.failure(closeCode: nil, httpStatus: 429), .accountLimit)

        let descriptions: [(AssemblyAIStreamingError, String)] = [
            (.notConnected, "AssemblyAI could not connect"),
            (.unauthorized, "AssemblyAI rejected the API key"),
            (.accountLimit, "AssemblyAI refused the session (rate limit or account balance)"),
            (.serverError(code: 3005), "AssemblyAI reported an error"),
            (.socketClosedBeforeCommit, "AssemblyAI closed the connection early"),
            (.socketClosedBeforeFinal, "AssemblyAI closed the connection before the transcript arrived"),
            (.commitTimedOut, "AssemblyAI did not finish the transcript in time"),
            (.emptyTranscriptForSpeech, "AssemblyAI returned no words for recorded speech"),
        ]
        for (error, text) in descriptions {
            TestSupport.expectEqual(error.errorDescription, text)
        }
    }

    // MARK: Assembly and commit

    private static func turn(_ order: Int, _ text: String, ended: Bool = false, speechEnd: Int? = nil) -> Core.ServerMessage {
        .turn(order: order, transcript: text, endOfTurn: ended, speechEndMilliseconds: speechEnd)
    }

    private static func testTurnAssembler() {
        var empty = Core.TurnAssembler()
        TestSupport.expectEqual(empty.transcriptWithTail, "")
        TestSupport.expect(!empty.hasPartialTail, "An empty assembler has no tail")
        TestSupport.expect(!empty.hasUnfinishedTurn, "An empty assembler has no unfinished turn")
        TestSupport.expectEqual(empty.finalSpeechEndMilliseconds, nil)
        empty.apply(.begin)
        empty.apply(.unknown)
        TestSupport.expectEqual(empty.turnMessageCount, 0)

        var assembler = Core.TurnAssembler()
        assembler.apply(turn(0, "hello", speechEnd: 400))
        assembler.apply(turn(0, "hello wor", speechEnd: 700))
        TestSupport.expectEqual(assembler.finalTranscript, "")
        TestSupport.expectEqual(assembler.partialTail, "hello wor")
        TestSupport.expect(assembler.hasUnfinishedTurn, "A partial turn is unfinished")
        TestSupport.expectEqual(assembler.finalSpeechEndMilliseconds, nil)
        assembler.apply(turn(0, " Hello world. ", ended: true, speechEnd: 900))
        assembler.apply(turn(0, "late revision", speechEnd: 5000))
        TestSupport.expectEqual(assembler.finalTranscript, "Hello world.")
        TestSupport.expect(!assembler.hasPartialTail, "An ended turn leaves no tail")
        TestSupport.expect(!assembler.hasUnfinishedTurn, "An ended turn is finished")
        TestSupport.expectEqual(assembler.finalSpeechEndMilliseconds, 900)
        assembler.apply(turn(2, "Third.", ended: true, speechEnd: 3000))
        assembler.apply(turn(1, "Second.", ended: true, speechEnd: 2000))
        assembler.apply(turn(3, "", ended: true))
        assembler.apply(turn(4, "and four", speechEnd: 4000))
        TestSupport.expectEqual(assembler.finalTranscript, "Hello world. Second. Third.")
        TestSupport.expectEqual(assembler.partialTail, "and four")
        TestSupport.expectEqual(assembler.transcriptWithTail, "Hello world. Second. Third. and four")
        TestSupport.expectEqual(assembler.finalSpeechEndMilliseconds, 3000)
        TestSupport.expect(assembler.hasUnfinishedTurn, "Turn 4 is unfinished")
        TestSupport.expectEqual(assembler.turnMessageCount, 8)
        TestSupport.expect(!assembler.hasEndOfTurnAfterCommit, "Nothing ended after a commit that never came")
        TestSupport.expect(!assembler.hasReceivedTermination, "No Termination yet")
        assembler.markCommitted()
        assembler.apply(turn(4, "And four.", ended: true, speechEnd: 4200))
        TestSupport.expect(assembler.hasEndOfTurnAfterCommit, "Turn 4 ended after the commit")
        TestSupport.expectEqual(assembler.transcriptWithTail, "Hello world. Second. Third. And four.")
        assembler.apply(.termination)
        TestSupport.expect(assembler.hasReceivedTermination, "Termination is recorded")
    }

    private static func testCommitConstants() {
        TestSupport.expectEqual(Policy.timeout, 3)
        TestSupport.expectEqual(Policy.coverageSlackMilliseconds, 300)
        TestSupport.expectEqual(Core.minTurnSilenceMilliseconds, 5000)
        TestSupport.expectEqual(Policy.commitMessages, [#"{"type":"ForceEndpoint"}"#, #"{"type":"Terminate"}"#])
        TestSupport.expectEqual(Policy.terminateMessage, #"{"type":"Terminate"}"#)
        TestSupport.expectEqual(Policy.TranscriptPath.finals.rawValue, "assemblyai-final")
        TestSupport.expectEqual(Policy.TranscriptPath.finalsWithPartialTail.rawValue, "assemblyai-final+partial-tail")
    }

    private static func decision(
        before: [Core.ServerMessage],
        after: [Core.ServerMessage] = [],
        socketState: Policy.SocketState = .open,
        failure: AssemblyAIStreamingError? = nil,
        elapsed: TimeInterval = 0.2,
        heardSpeech: Bool = true,
        audioSent: Int = 2000,
        backlog: Int = 0
    ) -> Policy.Decision {
        var assembler = Core.TurnAssembler()
        before.forEach { assembler.apply($0) }
        assembler.markCommitted()
        after.forEach { assembler.apply($0) }
        return Policy.decision(
            assembler: assembler,
            socketState: socketState,
            failure: failure,
            elapsedSinceCommit: elapsed,
            recorderHeardSpeech: heardSpeech,
            audioMillisecondsSent: audioSent,
            backlogMillisecondsAtCommit: backlog
        )
    }

    private static func testCommitDecision() {
        let spoken = turn(0, "hello wor", speechEnd: 1500)
        let forced = turn(0, "Hello world.", ended: true, speechEnd: 1800)
        // Fast path: ForceEndpoint's end_of_turn over all the audio resolves at once.
        TestSupport.expectEqual(decision(before: [spoken], after: [forced]), .resolve("Hello world.", .finals))
        // Release up to min_turn_silence minus the slack after the last word still covers it.
        TestSupport.expectEqual(
            decision(before: [spoken], after: [forced], audioSent: 1800 + 4699),
            .resolve("Hello world.", .finals)
        )
        // A final word further from the end could be a late natural end of turn with
        // speech after it, so Termination decides.
        TestSupport.expectEqual(decision(before: [spoken], after: [forced], audioSent: 1800 + 4700), .wait)
        // Audio still queued behind the throttle at the commit: ForceEndpoint may have
        // answered before it, so Termination decides.
        TestSupport.expectEqual(decision(before: [spoken], after: [forced], backlog: 300), .wait)
        TestSupport.expectEqual(
            decision(before: [spoken], after: [forced, turn(1, "and more", speechEnd: 2000), .termination], backlog: 300),
            .resolve("Hello world. and more", .finalsWithPartialTail)
        )
        TestSupport.expectEqual(
            decision(
                before: [spoken],
                after: [forced, turn(1, "And more.", ended: true, speechEnd: 2000), .termination],
                backlog: 300
            ),
            .resolve("Hello world. And more.", .finals)
        )
        // A final without word times cannot prove coverage.
        TestSupport.expectEqual(decision(before: [], after: [turn(0, "Hello.", ended: true)]), .wait)
        // A turn that ended before the commit waits for the open one.
        TestSupport.expectEqual(
            decision(before: [turn(0, "First.", ended: true, speechEnd: 900), turn(1, "second", speechEnd: 1500)]),
            .wait
        )
        TestSupport.expectEqual(
            decision(
                before: [turn(0, "First.", ended: true, speechEnd: 900), turn(1, "second", speechEnd: 1500)],
                after: [turn(1, "Second.", ended: true, speechEnd: 1700)]
            ),
            .resolve("First. Second.", .finals)
        )
        // Only a pre-commit end_of_turn: ForceEndpoint had no turn to end, so Termination decides.
        TestSupport.expectEqual(decision(before: [turn(0, "First.", ended: true, speechEnd: 900)], elapsed: 1), .wait)
        TestSupport.expectEqual(
            decision(before: [turn(0, "First.", ended: true, speechEnd: 900)], after: [.termination]),
            .resolve("First.", .finals)
        )
        // An ended turn with a later unfinished one waits.
        TestSupport.expectEqual(
            decision(before: [turn(1, "next", speechEnd: 1900)], after: [turn(0, "First.", ended: true, speechEnd: 900)]),
            .wait
        )
        // Failures always fall back, even after text.
        TestSupport.expectEqual(
            decision(before: [spoken], after: [forced], failure: .unauthorized),
            .fallBack(.unauthorized)
        )
        // Timeout: the ended turns plus the latest unfinished turn.
        TestSupport.expectEqual(
            decision(before: [turn(0, "First.", ended: true, speechEnd: 900), turn(1, "second par")], elapsed: 3),
            .resolve("First. second par", .finalsWithPartialTail)
        )
        TestSupport.expectEqual(
            decision(before: [turn(0, "First.", ended: true, speechEnd: 900)], elapsed: 3),
            .resolve("First.", .finals)
        )
        TestSupport.expectEqual(
            decision(before: [spoken], after: [forced], elapsed: 3, backlog: 300),
            .resolve("Hello world.", .finals)
        )
        TestSupport.expectEqual(decision(before: [], elapsed: 3), .fallBack(.commitTimedOut))
        TestSupport.expectEqual(decision(before: [], elapsed: 3, heardSpeech: false), .resolve("", .finals))
        TestSupport.expectEqual(decision(before: [], elapsed: 2.9), .wait)
        // Termination with no words.
        TestSupport.expectEqual(decision(before: [], after: [.termination]), .fallBack(.emptyTranscriptForSpeech))
        TestSupport.expectEqual(decision(before: [], after: [.termination], heardSpeech: false), .resolve("", .finals))
        TestSupport.expectEqual(
            decision(before: [turn(0, "unfinished")], after: [.termination]),
            .resolve("unfinished", .finalsWithPartialTail)
        )
        // Closes.
        TestSupport.expectEqual(
            decision(before: [turn(0, "First.", ended: true, speechEnd: 900)], socketState: .closedAbnormally),
            .fallBack(.socketClosedBeforeFinal)
        )
        TestSupport.expectEqual(
            decision(before: [turn(0, "First.", ended: true, speechEnd: 900)], socketState: .closedNormally),
            .resolve("First.", .finals)
        )
        TestSupport.expectEqual(
            decision(before: [], socketState: .closedNormally),
            .fallBack(.emptyTranscriptForSpeech)
        )
    }

    /// The burst held until Begin drains at 1.25x real time behind the live audio.
    private static func testBacklogEstimate() {
        TestSupport.expectEqual(Core.throttleRealTimeFactor, 1.25)
        // 400 ms held until Begin plus 100 ms live, 0.1 s after Begin: 125 ms processable.
        TestSupport.expectEqual(Core.estimatedBacklogMilliseconds(audioMillisecondsSent: 500, secondsSinceBegin: 0.1), 375)
        // The same burst has drained 1.6 s after Begin (400 + 1600 sent, 2000 processable).
        TestSupport.expectEqual(Core.estimatedBacklogMilliseconds(audioMillisecondsSent: 2000, secondsSinceBegin: 1.6), 0)
        TestSupport.expectEqual(Core.estimatedBacklogMilliseconds(audioMillisecondsSent: 2300, secondsSinceBegin: 2), 0)
        TestSupport.expectEqual(Core.estimatedBacklogMilliseconds(audioMillisecondsSent: 300, secondsSinceBegin: 0), 300)
        TestSupport.expectEqual(Core.estimatedBacklogMilliseconds(audioMillisecondsSent: 300, secondsSinceBegin: -1), 300)
        TestSupport.expectEqual(Core.estimatedBacklogMilliseconds(audioMillisecondsSent: 0, secondsSinceBegin: 0), 0)
    }

    // MARK: Audio

    private static func testChunking() {
        let frameBytes = Core.frameBytes(sampleRate: 16000)
        TestSupport.expectEqual(frameBytes, 1600)
        TestSupport.expectEqual(DeepgramStreamingCore.audioMilliseconds(bytes: frameBytes, sampleRate: 16000), 50)

        var aggregator = DeepgramStreamingCore.FrameAggregator(frameBytes: frameBytes)
        var frames: [Data] = []
        for size in [100, 3000, 500] {
            frames += aggregator.append(Data((0..<size).map { UInt8(truncatingIfNeeded: $0 + 1) }))
        }
        TestSupport.expectEqual(frames.map(\.count), [1600, 1600])
        guard let partial = aggregator.flush() else { fatalError("Expected a partial frame") }
        TestSupport.expectEqual(partial.count, 400)

        let padded = Core.paddedFinalChunk(partial, frameBytes: frameBytes)
        TestSupport.expectEqual(padded.count, 1600)
        TestSupport.expectEqual(padded.prefix(400), partial)
        TestSupport.expect(padded.dropFirst(400).allSatisfy { $0 == 0 }, "Padding must be silence")
        TestSupport.expectEqual(Core.paddedFinalChunk(frames[0], frameBytes: frameBytes), frames[0])
        TestSupport.expectEqual(Core.paddedFinalChunk(Data(), frameBytes: frameBytes), Data())
        for chunk in frames + [padded] {
            let milliseconds = DeepgramStreamingCore.audioMilliseconds(bytes: chunk.count, sampleRate: 16000)
            TestSupport.expect((50...1000).contains(milliseconds), "Every chunk must be 50-1000 ms, got \(milliseconds)")
        }
    }

    // MARK: Key validation

    private static func testKeyValidationRequestAndMapping() {
        let request = Core.validationRequest(apiKey: " synthetic-key ")
        TestSupport.expectEqual(request?.url?.absoluteString, "https://token.assemblyai.com/v1/token")
        TestSupport.expectEqual(request?.httpMethod, "POST")
        TestSupport.expectEqual(request?.value(forHTTPHeaderField: "Authorization"), "synthetic-key")
        TestSupport.expectEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        TestSupport.expectEqual(request?.timeoutInterval, 10)
        TestSupport.expectEqual(
            request?.httpBody.flatMap { String(data: $0, encoding: .utf8) },
            #"{"expires_in_seconds":60,"product":"streaming"}"#
        )
        TestSupport.expectEqual(Core.validationRequest(apiKey: "  "), nil)

        TestSupport.expectEqual(Core.KeyValidation(statusCode: 200), .valid)
        TestSupport.expectEqual(Core.KeyValidation(statusCode: 401), .invalid)
        TestSupport.expectEqual(Core.KeyValidation(statusCode: 403), .invalid)
        for status in [0, 400, 404, 429, 500] {
            TestSupport.expectEqual(Core.KeyValidation(statusCode: status), .unreachable)
        }
        TestSupport.expectEqual(Core.KeyValidation.valid.statusText, "Valid")
        TestSupport.expectEqual(Core.KeyValidation.invalid.statusText, "Invalid")
        TestSupport.expectEqual(Core.KeyValidation.unreachable.statusText, "Could not reach AssemblyAI")
    }

    private static func testValidateAPIKeyWithStubTransport() async {
        let recorder = AssemblyAIRequestRecorder()
        func stub(status: Int) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
            { request in
                await recorder.append(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"token":"synthetic-token"}"#.utf8), response)
            }
        }

        let outcomes: [(Int, Core.KeyValidation)] = [(200, .valid), (401, .invalid), (403, .invalid), (500, .unreachable)]
        for (status, expected) in outcomes {
            let result = await Core.validateAPIKey(syntheticKey, transport: stub(status: status))
            TestSupport.expectEqual(result, expected)
        }

        struct SyntheticTransportFailure: Error {}
        let unreachable = await Core.validateAPIKey(syntheticKey) { _ in throw SyntheticTransportFailure() }
        TestSupport.expectEqual(unreachable, .unreachable)

        let emptyKey = await Core.validateAPIKey("  \n", transport: stub(status: 200))
        TestSupport.expectEqual(emptyKey, .invalid)
        let requests = await recorder.requests
        TestSupport.expectEqual(requests.count, outcomes.count)
        for request in requests {
            TestSupport.expectEqual(request.url?.absoluteString, "https://token.assemblyai.com/v1/token")
            TestSupport.expectEqual(request.value(forHTTPHeaderField: "Authorization"), syntheticKey)
        }
    }

    // MARK: Service (never started, so no socket)

    private static func expectCommitThrows(_ service: AssemblyAIStreamingService, _ expected: AssemblyAIStreamingError) async {
        do {
            _ = try await service.commitAndAwaitFinal()
            fatalError("The commit must throw \(expected)")
        } catch let error as AssemblyAIStreamingError {
            TestSupport.expectEqual(error, expected)
        } catch {
            fatalError("Unexpected error \(error)")
        }
    }

    private static func testServiceWithoutNetwork() async {
        typealias Report = DeepgramStreamingCore.KeytermReport
        let service = AssemblyAIStreamingService(
            config: configuration(keyterms: ["Wispr Flow", "wispr flow", "Kai"], promptScenario: .dictation)
        )
        TestSupport.expectEqual(service.transcriptionSource, "assemblyai")
        TestSupport.expectEqual(
            service.keytermReport,
            Report(connectCount: 2, screenCount: nil, identifierCount: nil, audioMillisecondsBeforeUpdate: nil)
        )

        // Before Begin the update is held ahead of the audio...
        service.updateKeyterms(screenTerms: ["Supabase"], identifiers: ["useAuth"])
        service.updateKeyterms(screenTerms: ["Vercel"], identifiers: [])
        TestSupport.expectEqual(
            service.keytermReport,
            Report(connectCount: 2, screenCount: 1, identifierCount: 1, audioMillisecondsBeforeUpdate: 0)
        )
        service.appendPCM16(Data(count: 3200))
        service.setRecorderHeardSpeech(true)
        // ...and with no Begin the commit throws at once, so the file upload runs.
        await expectCommitThrows(service, .notConnected)
        // A held update that never went out must not show in the Run Log.
        TestSupport.expectEqual(
            service.keytermReport,
            Report(connectCount: 2, screenCount: nil, identifierCount: nil, audioMillisecondsBeforeUpdate: nil)
        )
        TestSupport.expectEqual(service.transcriptionSource, "assemblyai")
        service.cancel()
        service.cancel()
        service.updateKeyterms(screenTerms: ["Supabase"], identifiers: [])
        service.updatePromptScenario(.email)
        TestSupport.expectEqual(service.keytermReport.screenCount, nil)
        await expectCommitThrows(service, .notConnected)

        // Keyterms off: none at connect and no updates.
        let noKeyterms = AssemblyAIStreamingService(config: configuration(keyterms: ["Wispr Flow"], keytermsEnabled: false))
        noKeyterms.updateKeyterms(screenTerms: ["Supabase"], identifiers: [])
        TestSupport.expectEqual(
            noKeyterms.keytermReport,
            Report(connectCount: 0, screenCount: nil, identifierCount: nil, audioMillisecondsBeforeUpdate: nil)
        )
        noKeyterms.cancel()

        // Too much audio before Begin abandons the stream.
        let overflow = AssemblyAIStreamingService(config: configuration())
        overflow.appendPCM16(Data(count: DeepgramStreamingCore.maxPendingAudioBytes(sampleRate: 16000) + 3200))
        await expectCommitThrows(overflow, .notConnected)
        overflow.cancel()
    }
}
