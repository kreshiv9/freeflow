import Foundation

/// The Chrome title parser, the arming gate and the Google watch state machine with an injected
/// clock. Invented queries, titles and profile names only; no Accessibility call is made.
enum GoogleSearchWatchTests {
    private typealias Title = GoogleSearchTitle
    private typealias Watch = GoogleSearchWatch
    private typealias Candidate = CorrectionLearner.Candidate

    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let chrome = "com.google.Chrome"

    static func run() {
        testTitleKinds()
        testResultsURLParser()
        testArmingGate()
        testDomainGateBeforeAnyRead()
        testSearchSurface()
        testNormalization()
        testSignalA()
        testSignalBChain()
        testWatchLimitsAndEnds()
        testEventActions()
        testSearchOutcomes()
    }

    private static func results(_ query: String) -> String {
        "\(query) - Google Search - Google Chrome"
    }

    // MARK: T1-T12

    private static func testTitleKinds() {
        // T1-T3: plain, a profile and a pinned tab.
        TestSupport.expectEqual(Title.classify("wispr flow pricing - Google Search - Google Chrome"), .results("wispr flow pricing"))
        TestSupport.expectEqual(Title.classify("wispr flow pricing - Google Search - Google Chrome - Work"), .results("wispr flow pricing"))
        TestSupport.expectEqual(Title.classify("wispr flow pricing - Google Search - Pinned - Google Chrome"), .results("wispr flow pricing"))
        // T4, T5: private windows.
        TestSupport.expectEqual(Title.classify("wispr flow pricing - Google Search - Google Chrome (Incognito)"), .privateWindow)
        TestSupport.expectEqual(Title.classify("wispr flow pricing - Google Search - Google Chrome (Guest)"), .privateWindow)
        // T6-T8: a URL flash, the homepage and another site.
        TestSupport.expectEqual(Title.classify("google.com/search?q=wispr+flow - Google Chrome"), .other(isURLFlash: true))
        TestSupport.expectEqual(Title.classify("www.google.com/search?q=wispr flow - Google Chrome"), .other(isURLFlash: true))
        TestSupport.expectEqual(Title.classify("Google - Google Chrome"), .other(isURLFlash: false))
        TestSupport.expectEqual(Title.classify("Synthetic Site - Google Chrome"), .other(isURLFlash: false))
        // T9: a query that holds " - ".
        TestSupport.expectEqual(Title.classify("rust - ownership - Google Search - Google Chrome"), .results("rust - ownership"))
        // T10: the NSWindow form has a query but cannot show the window is not private.
        TestSupport.expectEqual(ContextTermSources.googleQuery(fromPage: "wispr flow - Google Search"), "wispr flow")
        TestSupport.expectEqual(Title.classify("wispr flow - Google Search"), .unknownPrivacy)
        TestSupport.expectEqual(Title.classify(nil), .unknownPrivacy)
        // T11: another Google product. T12: a named window.
        TestSupport.expectEqual(Title.classify("Overview - Google Search Console - Google Chrome"), .other(isURLFlash: false))
        TestSupport.expectEqual(Title.classify("Research - Google Chrome"), .other(isURLFlash: false))
    }

    // MARK: U1-U4

    private static func testResultsURLParser() {
        func query(_ text: String) -> String? {
            URL(string: text).flatMap(Title.query(fromResultsURL:))
        }
        TestSupport.expectEqual(query("https://www.google.com/search?q=wispr+flow+pricing&sca_esv=synthetic"), "wispr flow pricing")
        TestSupport.expectEqual(query("https://www.google.com/search?sourceid=chrome&q=c%2B%2B+lambda"), "c++ lambda")
        TestSupport.expectEqual(query("https://www.google.com/maps?q=wispr"), nil)
        TestSupport.expectEqual(query("https://example.com/search?q=wispr"), nil)
        TestSupport.expectEqual(query("https://mail.google.com/search?q=wispr"), nil)
        TestSupport.expectEqual(query("https://www.google.co.uk/search?q=wispr"), "wispr")
        TestSupport.expectEqual(query("https://www.google.com/search?tbm=isch"), nil)
    }

    // MARK: Arming

    private static func testArmingGate() {
        func arms(_ title: String?, domain: String? = nil, bundle: String? = chrome) -> Bool {
            Title.arms(bundleIdentifier: bundle, websiteDomain: domain, windowTitle: title)
        }
        TestSupport.expect(arms("Google - Google Chrome"), "The homepage arms, without a domain")
        TestSupport.expect(arms("Google - Google Chrome", domain: "google.com"), "The homepage arms")
        TestSupport.expect(arms(results("wispr flow"), domain: "google.com"), "A results page arms")
        TestSupport.expect(arms(results("wispr flow"), domain: "google.co.uk"), "A country domain arms")
        TestSupport.expect(arms("New Tab - Google Chrome"), "A New Tab arms: a results title must still follow")
        TestSupport.expect(arms("Google - Google Chrome - Work"), "A profile window arms")

        TestSupport.expect(!arms("Google - Google Chrome (Incognito)"), "Incognito")
        TestSupport.expect(!arms("Google - Google Chrome (Guest)"), "Guest")
        TestSupport.expect(!arms(nil), "No title")
        TestSupport.expect(!arms("Google"), "No Chrome suffix")
        TestSupport.expect(!arms("Google - Google Chrome", bundle: "com.apple.Safari"), "Another browser")
        TestSupport.expect(!arms("Google - Google Chrome", bundle: nil), "No bundle")
        TestSupport.expect(!arms("Inbox - Google Chrome", domain: "mail.google.com"), "Gmail")
        TestSupport.expect(!arms("Google - Google Chrome", domain: "mail.google.com"), "A mail page titled Google")
        TestSupport.expect(!arms("Google - Google Chrome", domain: "docs.google.com"), "Docs")
        TestSupport.expect(!arms("Google - Google Chrome", domain: "chatgpt.com"), "ChatGPT")
        TestSupport.expect(!arms("Google Maps - Google Chrome"), "Maps")
        TestSupport.expect(!arms("Google - Google Chrome", domain: "example.com"), "A page titled Google elsewhere")
        TestSupport.expect(!arms("Research - Google Chrome"), "A named window")

        // Chrome's tab state follows the page's title, and hides neither page.
        TestSupport.expect(arms("Google - Pinned - Google Chrome", domain: "google.com"), "A pinned homepage")
        TestSupport.expect(arms("Google - Pinned - Google Chrome"), "A pinned homepage, without a domain")
        TestSupport.expect(arms("New Tab - Pinned - Google Chrome"), "A pinned New Tab")
        TestSupport.expect(arms("Google - Audio playing - Google Chrome"), "A homepage playing audio")
        TestSupport.expect(arms("Google - Audio playing - Pinned - Google Chrome"), "Two tab states")
        TestSupport.expect(!arms("Google - Pinned - Google Chrome (Incognito)"), "A pinned Incognito tab")
        TestSupport.expect(!arms("Google - Pinned - Google Chrome", domain: "mail.google.com"), "A pinned Gmail tab")
        TestSupport.expect(!arms("Google - Synthetic - Google Chrome"), "A page merely titled Google - x")
        TestSupport.expect(!arms("Google - Synthetic - Pinned - Google Chrome"), "The same page, pinned")
        TestSupport.expect(!arms("Pinned - Google Chrome"), "A page titled Pinned")
    }

    /// A page already known not to be Google gets no Accessibility read of its window.
    private static func testDomainGateBeforeAnyRead() {
        func mayArm(_ domain: String?, bundle: String? = chrome) -> Bool {
            Title.domainMayArm(bundleIdentifier: bundle, websiteDomain: domain)
        }
        TestSupport.expect(mayArm(nil), "No domain: the title decides")
        TestSupport.expect(mayArm("google.com"), "Google")
        TestSupport.expect(mayArm("google.co.uk"), "A country domain")
        for domain in ["chatgpt.com", "mail.google.com", "docs.google.com", "example.com"] {
            TestSupport.expect(!mayArm(domain), "\(domain) is rejected before the read")
            // Never armed by any title either.
            TestSupport.expect(
                !Title.arms(bundleIdentifier: chrome, websiteDomain: domain, windowTitle: results("wispr flow")),
                "\(domain) never arms"
            )
        }
    }

    private static func testSearchSurface() {
        func surface(_ title: String?, domain: String? = nil, bundle: String? = chrome) -> Bool {
            Title.isSearchSurface(bundleIdentifier: bundle, websiteDomain: domain, windowTitle: title)
        }
        // The address bar and New Tab have no domain, like any dictation without Context Awareness.
        TestSupport.expect(surface("New Tab - Google Chrome"), "The address bar on a New Tab")
        TestSupport.expect(surface("Google - Google Chrome"), "The homepage without a domain")
        TestSupport.expect(surface(results("wispr flow")), "A results page without a domain")
        // Google's own domain counts in any window: rules only apply there, nothing is observed.
        TestSupport.expect(surface("Google - Google Chrome (Incognito)", domain: "google.com"), "Incognito on google.com")
        TestSupport.expect(surface("Research - Google Chrome", domain: "google.com"), "A named window on google.com")
        TestSupport.expect(surface(nil, domain: "google.com"), "No title on google.com")

        TestSupport.expect(!surface("Google - Google Chrome (Incognito)"), "Incognito with no domain")
        TestSupport.expect(!surface("Research - Google Chrome"), "A named window with no domain")
        TestSupport.expect(!surface("Google - Google Chrome", domain: "mail.google.com"), "Gmail")
        TestSupport.expect(!surface("Synthetic Site - Google Chrome"), "Another site")
        TestSupport.expect(!surface(nil), "Nothing known")
        TestSupport.expect(!surface("Google - Google Chrome", bundle: "com.apple.Safari"), "Another browser")
    }

    // MARK: Normalization

    private static func testNormalization() {
        TestSupport.expectEqual(Title.normalizedQuery("wispr flow site:example.com"), "wispr flow")
        TestSupport.expectEqual(Title.normalizedQuery("wispr flow -reddit"), "wispr flow")
        TestSupport.expectEqual(Title.normalizedQuery("\"wispr flow\" pricing"), "wispr flow pricing")
        TestSupport.expectEqual(Title.normalizedQuery("wispr OR whisper"), "wispr whisper")
        TestSupport.expectEqual(Title.normalizedQuery("wispr or whisper"), "wispr or whisper")
        TestSupport.expectEqual(Title.normalizedQuery("what is wispr flow?"), "what is wispr flow")
        TestSupport.expectEqual(Title.normalizedQuery("wispr flow."), "wispr flow")
        TestSupport.expectEqual(Title.normalizedQuery("wow!?"), "wow")
        TestSupport.expectEqual(Title.normalizedQuery("C++ lambda"), "C++ lambda")
        TestSupport.expectEqual(Title.normalizedQuery("rust - ownership"), "rust - ownership")
    }

    // MARK: State machine

    private static func watch(_ initial: String? = "Google - Google Chrome", pressedEnter: Bool = false) -> Watch {
        Watch(entryID: UUID(), initialTitle: initial, pressedEnter: pressedEnter, now: start)
    }

    private static func testSignalA() {
        var first = watch()
        TestSupport.expectEqual(first.observe(title: "Google - Google Chrome", now: start + 1), .none)
        TestSupport.expectEqual(first.observe(title: "google.com/search?q=wispr - Google Chrome", now: start + 2), .none)
        TestSupport.expectEqual(first.observe(title: "Synthetic Site - Google Chrome", now: start + 3), .none)
        TestSupport.expectEqual(first.observe(title: results("wispr flow"), now: start + 4), .signalA(query: "wispr flow"))

        // The results page that was already showing proves nothing.
        var onResults = watch(results("old query"))
        TestSupport.expectEqual(onResults.observe(title: results("old query"), now: start + 1), .none)
        TestSupport.expectEqual(onResults.observe(title: results("wispr flow"), now: start + 2), .signalA(query: "wispr flow"))

        var late = watch()
        TestSupport.expectEqual(late.observe(title: results("wispr flow"), now: start + Watch.signalAWindow), .signalA(query: "wispr flow"))
        var tooLate = watch()
        TestSupport.expectEqual(tooLate.observe(title: results("wispr flow"), now: start + Watch.signalAWindow + 1), .ended(.timeout))
        TestSupport.expect(tooLate.isEnded, "The watch has ended")

        // An unknown title neither teaches nor ends anything, a results form without Chrome's
        // suffix included.
        var unknown = watch()
        TestSupport.expectEqual(unknown.observe(title: "wispr flow - Google Search", now: start + 1), .none)
        TestSupport.expectEqual(unknown.observe(title: nil, now: start + 2), .none)
        TestSupport.expect(!unknown.isEnded, "Still watching")
    }

    private static func testSignalBChain() {
        // W11: FreeFlow pressed Enter, so the first results only prove the send and start the chain.
        var pressed = watch(pressedEnter: true)
        TestSupport.expectEqual(pressed.observe(title: results("whisper flow"), now: start + 1), .firstResults(query: "whisper flow"))
        TestSupport.expectEqual(pressed.observe(title: results("whisper flow"), now: start + 2), .none)
        TestSupport.expectEqual(
            pressed.observe(title: results("wispr flow"), now: start + 3),
            .signalB(previous: "whisper flow", query: "wispr flow")
        )

        // After Signal A the chain goes on, and each link has its own window.
        var chain = watch()
        TestSupport.expectEqual(chain.observe(title: results("one"), now: start + 1), .signalA(query: "one"))
        TestSupport.expectEqual(chain.observe(title: "google.com/search?q=two - Google Chrome", now: start + 2), .none)
        TestSupport.expectEqual(chain.observe(title: nil, now: start + 3), .none)
        TestSupport.expectEqual(chain.observe(title: results("two"), now: start + 100), .signalB(previous: "one", query: "two"))
        TestSupport.expectEqual(chain.observe(title: results("three"), now: start + 150), .signalB(previous: "two", query: "three"))

        // W10: any other title ends the chain.
        var other = watch()
        _ = other.observe(title: results("one"), now: start + 1)
        TestSupport.expectEqual(other.observe(title: "Synthetic Site - Google Chrome", now: start + 2), .ended(.otherTitle))
        TestSupport.expectEqual(other.observe(title: results("two"), now: start + 3), .none)
    }

    private static func testWatchLimitsAndEnds() {
        var linkTooLate = watch()
        _ = linkTooLate.observe(title: results("one"), now: start + 1)
        TestSupport.expectEqual(linkTooLate.observe(title: results("two"), now: start + 1 + Watch.signalBWindow + 1), .ended(.timeout))

        var ceiling = watch()
        _ = ceiling.observe(title: results("one"), now: start + 50)
        _ = ceiling.observe(title: results("two"), now: start + 150)
        TestSupport.expectEqual(ceiling.observe(title: results("three"), now: start + Watch.ceiling + 1), .ended(.ceiling))

        var incognito = watch()
        _ = incognito.observe(title: results("one"), now: start + 1)
        TestSupport.expectEqual(
            incognito.observe(title: "two - Google Search - Google Chrome (Incognito)", now: start + 2),
            .ended(.privateWindow)
        )
        TestSupport.expectEqual(incognito.observe(title: results("three"), now: start + 3), .none)

        var incognitoFirst = watch()
        TestSupport.expectEqual(
            incognitoFirst.observe(title: "one - Google Search - Google Chrome (Incognito)", now: start + 1),
            .ended(.privateWindow)
        )

        // A named window never shows results, so it never signals.
        var named = watch("Research - Google Chrome")
        for offset in 1...5 {
            TestSupport.expectEqual(named.observe(title: "Research - Google Chrome", now: start + Double(offset)), .none)
        }

        var ended = watch()
        ended.end()
        TestSupport.expect(ended.isEnded, "end() ends it")
        TestSupport.expectEqual(ended.observe(title: results("one"), now: start + 1), .none)
    }

    // MARK: Actions

    private static func testEventActions() {
        func paste(_ text: String, observed: Bool = false) -> LearningPaste {
            var paste = LearningPaste(
                pasted: text, raw: text, destination: .chrome, category: .search, pressedEnter: false, countsForHookHealth: false
            )
            paste.observed = observed
            return paste
        }
        typealias Action = Watch.Action
        let pasted = paste("Whisper flow pricing.")
        TestSupport.expectEqual(Watch.action(for: .none, paste: pasted), Action.nothing)
        TestSupport.expectEqual(Watch.action(for: .ended(.timeout), paste: pasted), Action.end(.timeout))

        // The first results must hold the paste, whoever pressed Enter.
        TestSupport.expectEqual(
            Watch.action(for: .signalA(query: "wispr flow pricing"), paste: pasted),
            Action.learn(.firstResults, final: "wispr flow pricing")
        )
        TestSupport.expectEqual(
            Watch.action(for: .firstResults(query: "whisper flow pricing"), paste: pasted),
            Action.learn(.firstResultsAfterEnter, final: "whisper flow pricing")
        )
        for event in [Watch.Event.signalA(query: "weather in a made up town"), .firstResults(query: "weather in a made up town")] {
            TestSupport.expectEqual(Watch.action(for: event, paste: pasted), Action.end(.notThePaste))
            TestSupport.expectEqual(Watch.action(for: event, paste: nil), Action.end(.notThePaste))
        }
        TestSupport.expectEqual(
            Watch.action(for: .signalA(query: "whisper flow pricing"), paste: paste("whisper flow pricing", observed: true)),
            Action.end(.notThePaste)
        )

        // Signal B runs on a query the paste need not hold, once the paste is observed.
        TestSupport.expectEqual(
            Watch.action(for: .signalB(previous: "one", query: "two"), paste: paste("whisper flow pricing", observed: true)),
            Action.learn(.nextResults(previous: "one"), final: "two")
        )
        TestSupport.expectEqual(Watch.action(for: .signalB(previous: "one", query: "two"), paste: nil), Action.end(.notThePaste))

        // What the first results sent is held until the watch ends, unless Signal B changed it,
        // even when its verdict arrives after Signal B's.
        var held = watch()
        let kept = Watch.KeptSearch(pasted: "one", query: "one", unchanged: true)
        var first = SentTextLearning.Applied()
        first.keptSearch = kept
        held.note(first)
        TestSupport.expectEqual(held.keptSearch, kept)
        held.note(SentTextLearning.Applied())
        TestSupport.expectEqual(held.keptSearch, kept)
        var fixed = SentTextLearning.Applied()
        fixed.voidsKeptSearch = true
        held.note(fixed)
        TestSupport.expectEqual(held.keptSearch, nil)
        held.note(first)
        TestSupport.expectEqual(held.keptSearch, nil)
    }

    // MARK: Search outcomes

    private static func learn(_ pasted: String, _ final: String) -> CorrectionLearner.Outcome {
        CorrectionLearner.learn(
            pasted: Title.normalizedQuery(pasted),
            final: Title.normalizedQuery(final),
            lexicon: CorrectionLearnerTests.lexicon
        )
    }

    private static func testSearchOutcomes() {
        func candidates(_ outcome: CorrectionLearner.Outcome) -> [String] {
            guard case .learned(let found) = outcome else { return [] }
            return found.map { "\($0.heard)->\($0.term)" }
        }
        // M16-M18.
        let m16 = Watch.searchOutcome(learn("whisper flow pricing", "wispr flow pricing"), restrictedTo: nil)
        TestSupport.expectEqual(candidates(m16), ["whisper->wispr"])
        TestSupport.expectEqual(candidates(Watch.searchOutcome(learn("claude code", "claude code vs cursor"), restrictedTo: nil)), [])
        TestSupport.expectEqual(candidates(Watch.searchOutcome(learn("cursor vs windsurf", "cursor vs zed"), restrictedTo: nil)), [])
        // Trailing punctuation and operators are not edits.
        TestSupport.expectEqual(candidates(Watch.searchOutcome(learn("wispr flow.", "wispr flow site:example.com"), restrictedTo: nil)), [])

        // A case-only change never teaches a search.
        let caseOnly = CorrectionLearner.Outcome.learned([
            Candidate(heard: "Claude Code", term: "claude code", strength: .weak, ruleNow: false, ruleLater: false),
        ])
        TestSupport.expectEqual(Watch.searchOutcome(caseOnly, restrictedTo: nil), .nothing(.styleOrUnchanged))
        let mixed = CorrectionLearner.Outcome.learned([
            Candidate(heard: "Claude Code", term: "claude code", strength: .weak, ruleNow: false, ruleLater: false),
            Candidate(heard: "whisper", term: "wispr", strength: .strong, ruleNow: false, ruleLater: false),
        ])
        TestSupport.expectEqual(candidates(Watch.searchOutcome(mixed, restrictedTo: nil)), ["whisper->wispr"])

        // Signal B keeps only words that came from the paste.
        let fix = CorrectionLearner.Outcome.learned([
            Candidate(heard: "whisper", term: "wispr", strength: .strong, ruleNow: false, ruleLater: false),
        ])
        TestSupport.expectEqual(candidates(Watch.searchOutcome(fix, restrictedTo: "Whisper, flow pricing")), ["whisper->wispr"])
        TestSupport.expectEqual(Watch.searchOutcome(fix, restrictedTo: "typed by hand"), .nothing(.styleOrUnchanged))
        // A verdict of nothing passes through with its reason.
        TestSupport.expectEqual(Watch.searchOutcome(.nothing(.rewrite), restrictedTo: nil), .nothing(.rewrite))
    }
}
