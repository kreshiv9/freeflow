import ApplicationServices
import Foundation

/// What a Chrome window's Accessibility title says about a Google search. English UI only.
/// Titles stay in memory for the length of a watch; never stored or logged. A page can title
/// itself like a results page, so a title alone teaches nothing: it must still resemble a recent
/// paste. Results URLs are read only through `query(fromResultsURL:)`, and only their `q`.
enum GoogleSearchTitle {
    enum Kind: Equatable {
        case results(String)
        /// An Incognito or Guest window.
        case privateWindow
        /// No title, or none with the Chrome suffix: it cannot show the window is not private.
        case unknownPrivacy
        /// Another page. `isURLFlash`: Chrome shows the URL between a commit and the new title.
        case other(isURLFlash: Bool)
    }

    private static let urlShapedPage = try! NSRegularExpression(
        pattern: #"^(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?:[/?#].*)?$"#,
        options: [.caseInsensitive]
    )
    private static let homePages: Set<String> = ["Google", "New Tab"]
    /// What Chrome appends to a tab's title for its state. English UI only.
    private static let tabStates = [" - Pinned", " - Audio playing", " - Audio muted"]

    /// The page without the tab states after it, so a pinned homepage still reads as the
    /// homepage; "Google - x" stays what it is.
    private static func withoutTabStates(_ page: String) -> String {
        var page = page
        while let state = tabStates.first(where: { page.hasSuffix($0) }) {
            page.removeLast(state.count)
        }
        return page
    }

    static func classify(_ title: String?) -> Kind {
        guard let title, let parsed = ContextTermSources.chromePage(fromAccessibilityTitle: title) else {
            return .unknownPrivacy
        }
        if parsed.isPrivate { return .privateWindow }
        if let query = ContextTermSources.googleQuery(fromPage: parsed.page) { return .results(query) }
        let range = NSRange(location: 0, length: (parsed.page as NSString).length)
        return .other(isURLFlash: urlShapedPage.firstMatch(in: parsed.page, range: range) != nil)
    }

    /// A paste arms a watch only in a Chrome window that is known not to be private and shows
    /// Google's homepage, a results page or a New Tab, on google.com or a page without a domain.
    /// Other Google products and named windows do not arm it.
    static func arms(bundleIdentifier: String?, websiteDomain: String?, windowTitle: String?) -> Bool {
        guard ContextTarget.isChrome(bundleIdentifier: bundleIdentifier),
              domainMayArm(bundleIdentifier: bundleIdentifier, websiteDomain: websiteDomain),
              let windowTitle,
              let parsed = ContextTermSources.chromePage(fromAccessibilityTitle: windowTitle),
              !parsed.isPrivate else { return false }
        return homePages.contains(withoutTabStates(parsed.page)) || ContextTermSources.googleQuery(fromPage: parsed.page) != nil
    }

    /// False for a page already known not to be Google, whose window gets no read at all. No
    /// domain leaves the decision to the title: the address bar has none, and neither does a
    /// dictation without Context Awareness.
    static func domainMayArm(bundleIdentifier: String?, websiteDomain: String?) -> Bool {
        websiteDomain == nil || ContextTarget.isGoogleSearch(bundleIdentifier: bundleIdentifier, websiteDomain: websiteDomain)
    }

    /// A dictation into Google search, for the vocabulary it gets: Google's domain, or a window
    /// that would arm a watch (the address bar and New Tab have no domain). A private or named
    /// window on google.com counts too: rules only apply there, and nothing is observed.
    static func isSearchSurface(bundleIdentifier: String?, websiteDomain: String?, windowTitle: String?) -> Bool {
        ContextTarget.isGoogleSearch(bundleIdentifier: bundleIdentifier, websiteDomain: websiteDomain)
            || arms(bundleIdentifier: bundleIdentifier, websiteDomain: websiteDomain, windowTitle: windowTitle)
    }

    /// Both sides of a search comparison: without `site:x`, a leading `-x`, quotes, the token
    /// `OR` and a trailing `. ? !`.
    static func normalizedQuery(_ query: String) -> String {
        let tokens = query
            .filter { !"\"“”".contains($0) }
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { token in
                token != "OR" && !token.lowercased().hasPrefix("site:") && !(token.hasPrefix("-") && token.count > 1)
            }
        var text = tokens.joined(separator: " ")
        while let last = text.last, ".?!".contains(last) {
            text.removeLast()
        }
        return text
    }

    /// `q` of a google.com results URL, with `+` as a space (URLComponents does not decode it).
    /// Nothing else of the URL is read: it also carries session tokens.
    static func query(fromResultsURL url: URL) -> String? {
        guard let domain = TextContextCore.domain(from: url),
              ContextTarget.isGoogleSearch(bundleIdentifier: "com.google.chrome", websiteDomain: domain),
              url.path == "/search",
              let encodedQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else { return nil }
        for item in encodedQuery.split(separator: "&") {
            let parts = item.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "q" else { continue }
            let value = parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            return value.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        return nil
    }
}

/// One paste into Chrome's Google search, watched through the pinned window's titles until a
/// search shows what was sent. Signal A compares the paste with the first results title of the
/// first `signalAWindow` seconds; when FreeFlow itself pressed Enter that title shows no edit,
/// so it only proves the send and starts the chain. Signal B compares consecutive results
/// titles, each within `signalBWindow` seconds with nothing else in between. Pure: no clock, no
/// Accessibility; the caller feeds it titles.
struct GoogleSearchWatch: Equatable {
    enum EndReason: String, Equatable {
        case timeout, ceiling, privateWindow, otherTitle
        /// The first results do not hold the paste, or the paste is gone.
        case notThePaste

        /// Whether what the first results sent still counts as kept. A window that turned out
        /// private and a search that is not the paste teach nothing.
        var keepsEvidence: Bool {
            switch self {
            case .timeout, .ceiling, .otherTitle: true
            case .privateWindow, .notThePaste: false
            }
        }
    }

    enum Event: Equatable {
        case none
        case signalA(query: String)
        /// The first results when FreeFlow itself pressed Enter.
        case firstResults(query: String)
        case signalB(previous: String, query: String)
        case ended(EndReason)
    }

    /// What the app does about an event. The caller supplies the watched dictation's paste.
    enum Action: Equatable {
        case nothing
        case end(EndReason)
        case learn(SentTextLearning.Sighting, final: String)
    }

    /// What the first results sent, held in memory for the length of the watch: a fix on the
    /// results page would show the words were not kept after all.
    struct KeptSearch: Equatable {
        let pasted: String
        let query: String
        /// The paste went out as it was.
        let unchanged: Bool
    }

    static let signalAWindow: TimeInterval = 60
    static let signalBWindow: TimeInterval = 120
    /// No title outlives this in memory.
    static let ceiling: TimeInterval = 180

    let entryID: UUID
    private let startedAt: Date
    private let pressedEnter: Bool
    /// The results page already showing when the paste landed (T0), which proves nothing.
    private let initialQuery: String?
    private var previousQuery: String?
    private var previousQueryAt: Date?
    private(set) var isEnded = false
    private(set) var keptSearch: KeptSearch?
    private var keptSearchIsVoid = false

    init(entryID: UUID, initialTitle: String?, pressedEnter: Bool, now: Date) {
        self.entryID = entryID
        self.pressedEnter = pressedEnter
        startedAt = now
        if case .results(let query) = GoogleSearchTitle.classify(initialTitle) {
            initialQuery = query
        } else {
            initialQuery = nil
        }
    }

    mutating func end() {
        isEnded = true
    }

    /// A private window ends the watch at once. An unknown title never teaches or ends anything.
    /// Before the first results any other title is ignored; in the chain only a URL flash is.
    mutating func observe(title: String?, now: Date) -> Event {
        guard !isEnded else { return .none }
        if now.timeIntervalSince(startedAt) > Self.ceiling { return ending(.ceiling) }
        let kind = GoogleSearchTitle.classify(title)
        if kind == .privateWindow { return ending(.privateWindow) }

        if let previous = previousQuery, let previousAt = previousQueryAt {
            if now.timeIntervalSince(previousAt) > Self.signalBWindow { return ending(.timeout) }
            switch kind {
            case .results(let query):
                guard query != previous else { return .none }
                previousQuery = query
                previousQueryAt = now
                return .signalB(previous: previous, query: query)
            case .other(isURLFlash: false):
                return ending(.otherTitle)
            case .other(isURLFlash: true), .unknownPrivacy, .privateWindow:
                return .none
            }
        }

        if now.timeIntervalSince(startedAt) > Self.signalAWindow { return ending(.timeout) }
        guard case .results(let query) = kind, query != initialQuery else { return .none }
        previousQuery = query
        previousQueryAt = now
        return pressedEnter ? .firstResults(query: query) : .signalA(query: query)
    }

    /// The first results must hold the paste, which no source has observed yet, whoever pressed
    /// Enter: an unrelated title (a tab switch) ends the watch and starts no chain. Signal B
    /// needs the paste too, since it only learns changes of the paste's words.
    static func action(for event: Event, paste: LearningPaste?) -> Action {
        func firstResults(_ sighting: SentTextLearning.Sighting, _ query: String) -> Action {
            guard let paste, !paste.observed,
                  SentTextMatcher.coverage(
                      of: GoogleSearchTitle.normalizedQuery(paste.pasted), in: GoogleSearchTitle.normalizedQuery(query)
                  ) >= SentTextMatcher.minimumCoverage else { return .end(.notThePaste) }
            return .learn(sighting, final: query)
        }
        switch event {
        case .none:
            return .nothing
        case .ended(let reason):
            return .end(reason)
        case .signalA(let query):
            return firstResults(.firstResults, query)
        case .firstResults(let query):
            return firstResults(.firstResultsAfterEnter, query)
        case .signalB(let previous, let query):
            return paste == nil ? .end(.notThePaste) : .learn(.nextResults(previous: previous), final: query)
        }
    }

    /// Takes what applying a verdict decided. A void holds: Signal B outranks a first results
    /// verdict that arrives after it.
    mutating func note(_ applied: SentTextLearning.Applied) {
        if applied.voidsKeptSearch {
            keptSearchIsVoid = true
            keptSearch = nil
        }
        if let kept = applied.keptSearch, !keptSearchIsVoid {
            keptSearch = kept
        }
    }

    private mutating func ending(_ reason: EndReason) -> Event {
        isEnded = true
        return .ended(reason)
    }

    /// What a search teaches: never a case-only change (searches are typed in lowercase) and,
    /// for Signal B (`pasted` given), only a change of words the paste actually held.
    static func searchOutcome(_ outcome: CorrectionLearner.Outcome, restrictedTo pasted: String?) -> CorrectionLearner.Outcome {
        guard case .learned(let candidates) = outcome else { return outcome }
        let pastedWords = pasted.map { Set(CorrectionLearner.tokens($0).map(\.fold)) }
        let kept = candidates.filter { candidate in
            guard candidate.heard.lowercased() != candidate.term.lowercased() else { return false }
            guard let pastedWords else { return true }
            return CorrectionLearner.tokens(candidate.heard).allSatisfy { pastedWords.contains($0.fold) }
        }
        return kept.isEmpty ? .nothing(.styleOrUnchanged) : .learned(kept)
    }
}

/// Polls the pinned Chrome window's title on a utility queue. Reads `kAXTitle` only and never
/// writes an attribute.
final class GoogleTitlePoller {
    static let interval: DispatchTimeInterval = .milliseconds(250)
    private static let messagingTimeout: Float = 0.1

    private let window: AXUIElement
    private var timer: DispatchSourceTimer?

    init(window: AXUIElement) {
        self.window = window
    }

    deinit {
        timer?.cancel()
    }

    /// The application's focused window and its title. Off the main thread: Accessibility reads
    /// can block on the other app.
    static func focusedWindow(pid: pid_t) -> (window: AXUIElement, title: String?)? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        var title: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        return (window, status == .success ? title as? String : nil)
    }

    /// `onTitle` gets each read, nil when it failed, on the poller's queue; `onClosed` ends the
    /// polling when the window is gone.
    func start(onTitle: @escaping (String?) -> Void, onClosed: @escaping () -> Void) {
        guard timer == nil else { return }
        let window = window
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.zachlatta.freeflow.google-title", qos: .utility))
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.setEventHandler { [weak timer] in
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
            if status == .invalidUIElement {
                timer?.cancel()
                onClosed()
                return
            }
            onTitle(status == .success ? value as? String : nil)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
