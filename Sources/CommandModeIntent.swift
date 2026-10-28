import Foundation

/// Engine opened by an Edit Mode web search. A missing or invalid preference
/// means Google; nothing is persisted until the Settings picker changes.
enum WebSearchEngine: String, CaseIterable, Identifiable {
    case google
    case perplexity
    case duckDuckGo

    var id: String { rawValue }

    static let storageKey = "command_mode_search_engine"
    static let defaultEngine: WebSearchEngine = .google

    var displayName: String {
        switch self {
        case .google: "Google"
        case .perplexity: "Perplexity"
        case .duckDuckGo: "DuckDuckGo"
        }
    }

    private var searchPrefix: String {
        switch self {
        case .google: "https://www.google.com/search?q="
        case .perplexity: "https://www.perplexity.ai/search?q="
        case .duckDuckGo: "https://duckduckgo.com/?q="
        }
    }

    /// The ASCII unreserved set only (`.alphanumerics` would leave non-ASCII letters raw), so a
    /// transcript can never add a scheme, host or query parameter: space -> %20, & -> %26, é -> %C3%A9.
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    func url(for query: String) -> URL? {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: Self.unreservedCharacters) else {
            return nil
        }
        return URL(string: searchPrefix + encodedQuery)
    }

    /// Returns Google for missing/invalid values without persisting a default.
    static func load(from defaults: UserDefaults) -> WebSearchEngine {
        guard let raw = defaults.object(forKey: storageKey) as? String,
              let engine = WebSearchEngine(rawValue: raw) else { return defaultEngine }
        return engine
    }
}

/// What a spoken Edit Mode command asks for once the transcript is known.
enum CommandIntentKind: Equatable {
    case editText
    case webSearch(query: String)
    case noTarget
}

/// Pure classification of a spoken Edit Mode command. No model call: a search cue or,
/// with nothing to edit, a question opens the browser; everything else edits text.
enum CommandModeIntent {
    /// Longest cue first so "search for" is stripped whole before "search" can match.
    static let searchCues = [
        "web search for", "web search", "search for", "find online", "look up", "lookup", "search", "google"
    ]
    static let questionWords: Set<String> = [
        "who", "what", "when", "where", "why", "how", "is", "are", "can", "does", "do"
    ]

    /// A cue wins even over a selection. The question heuristic applies only when there is
    /// no editable text, because a question over selected text is still an edit instruction.
    static func classify(command: String, hasEditableText: Bool) -> CommandIntentKind {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if let cue = searchCues.first(where: { lowered == $0 || lowered.hasPrefix($0 + " ") }) {
            let query = stripTrailingPunctuation(
                String(trimmed.dropFirst(cue.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
            // A bare cue has nothing to search for and falls through.
            if !query.isEmpty { return .webSearch(query: query) }
        }
        guard !hasEditableText else { return .editText }
        let firstWord = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map {
            $0.prefix(while: { $0.isLetter }).lowercased()
        } ?? ""
        if trimmed.hasSuffix("?") || questionWords.contains(firstWord) {
            return .webSearch(query: stripTrailingPunctuation(trimmed))
        }
        return .noTarget
    }

    /// Longest field, in UTF-16 units, that stands in for a selection. Matches the text-context
    /// read cap, so a press that selected nothing can never send a huge document anywhere.
    static let maxWholeFieldLength = 100_000

    /// The captured field text a manual press edits when nothing is selected: nil for a missing,
    /// blank or over-cap field, which then counts as no field at all.
    static func wholeFieldText(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (value as NSString).length <= maxWholeFieldLength else { return nil }
        return value
    }

    private static func stripTrailingPunctuation(_ text: String) -> String {
        var query = Substring(text)
        while let last = query.last, ".?!,".contains(last) {
            query.removeLast()
        }
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Processing statuses stored on the Run Log row; the Run Log compares them exactly.
    static let webSearchProcessingStatus = "Edit mode: web search"
    static let noTargetProcessingStatus = "Edit mode: no text field"
    /// A failed whole-field transform has no fallback text: the field text is not a result.
    static let wholeFieldFailedProcessingStatus = "Edit mode failed, field unchanged (manual)"
    /// Status shown after the browser opened. Nothing is pasted.
    static let webSearchStatusText = "Web search opened"
    /// Overlay and status when no editable field was focused; the spoken command is on the clipboard.
    static let noTargetOverlayMessage = "Edit Mode needs a text field — text copied"
    /// Overlay and status when the whole-field write was refused or unverified; the result is on the clipboard.
    static let fieldChangedOverlayMessage = "Field changed — result copied"
    /// Status after a verified whole-field write.
    static let wholeFieldReplacedStatusText = "Replaced field text"
    /// Status when the transform failed; the field is never overwritten with the fallback text.
    static let wholeFieldFailedStatusText = "Edit failed — field unchanged"
}
