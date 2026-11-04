import Foundation

/// The apps whose on-screen names go to Deepgram as keyterms. Every other app keeps only
/// the IDE identifiers it had before.
enum ContextTarget: String, Equatable, Sendable {
    /// The Claude Code composer in the VS Code extension panel.
    case claudeCodePanel
    /// chatgpt.com (or chat.openai.com) in Chrome.
    case chatGPTWeb
    /// /Applications/ChatGPT.app, bundle com.openai.codex.
    case chatGPTApp
    /// A google.com (or google.<country>) page in Chrome.
    case googleSearch

    /// Lowercased, like every bundle comparison here.
    private static let chromeBundles: Set<String> = [
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.dev", "com.google.chrome.canary"
    ]
    private static let vscodeBundles: Set<String> = ["com.microsoft.vscode", "com.microsoft.vscodeinsiders"]
    private static let chatGPTAppBundle = "com.openai.codex"
    private static let chatGPTDomains: Set<String> = ["chatgpt.com", "chat.openai.com"]
    private static let googleSearchDomain = try! NSRegularExpression(pattern: #"^google\.[a-z]{2,3}(\.[a-z]{2})?$"#)
    private static let textAreaRole = "AXTextArea"

    /// Pure: nil for every other app, page or field, including ChatGPT Classic, Atlas,
    /// Safari, VS Code editors, Gmail and Google Docs.
    static func classify(
        bundleIdentifier: String?,
        websiteDomain: String?,
        focusedRole: String?,
        focusedLabel: String?,
        insideWebArea: Bool
    ) -> ContextTarget? {
        guard let bundle = normalized(bundleIdentifier) else { return nil }
        if chromeBundles.contains(bundle), let domain = websiteDomain?.lowercased() {
            if chatGPTDomains.contains(domain) { return .chatGPTWeb }
            let range = NSRange(location: 0, length: (domain as NSString).length)
            if googleSearchDomain.firstMatch(in: domain, range: range) != nil { return .googleSearch }
            return nil
        }
        guard focusedRole == textAreaRole, insideWebArea else { return nil }
        if vscodeBundles.contains(bundle), focusedLabel == ContextTermSources.claudeComposerLabel {
            return .claudeCodePanel
        }
        return bundle == chatGPTAppBundle ? .chatGPTApp : nil
    }

    /// The activation-time AXRole read covers Chrome, VS Code and ChatGPT.app only, and
    /// stops with the master switch.
    static func primesAccessibility(bundleIdentifier: String?) -> Bool {
        guard ContextTermSources.isEnabled, let bundle = normalized(bundleIdentifier) else { return false }
        return chromeBundles.contains(bundle) || vscodeBundles.contains(bundle) || bundle == chatGPTAppBundle
    }

    /// Only VS Code needs the focused field's label, to tell the Claude composer apart.
    static func readsFocusedLabel(bundleIdentifier: String?) -> Bool {
        guard let bundle = normalized(bundleIdentifier) else { return false }
        return vscodeBundles.contains(bundle)
    }

    private static func normalized(_ bundleIdentifier: String?) -> String? {
        guard let value = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Composer placeholders

    /// True when `value`, as a whole, is a text this composer shows while it is empty. The
    /// Claude Code panel draws its placeholder with CSS (`:empty:before { content:
    /// attr(data-placeholder) }`) instead of `aria-placeholder`, so Chromium reports it as the
    /// field's value and `AXPlaceholderValue` stays empty; ChatGPT's composers may do the same.
    /// Only whole values match, ignoring case, surrounding whitespace and a trailing "…" or
    /// "...", so typed text that merely mentions these words is kept. Claude's own prompt
    /// suggestions, shown the same way, are free text and cannot be told apart.
    func isComposerPlaceholder(_ value: String) -> Bool {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for ellipsis in ["…", "..."] where text.hasSuffix(ellipsis) {
            text = String(text.dropLast(ellipsis.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty, text.count <= Self.maxPlaceholderLength else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        switch self {
        case .claudeCodePanel:
            return Self.claudeCodePlaceholders.contains(text)
                || Self.claudeCodeShortcutPlaceholder.firstMatch(in: text, range: range) != nil
        case .chatGPTWeb, .chatGPTApp:
            return Self.chatGPTPlaceholders.contains(text)
                || Self.chatGPTAnythingPlaceholder.firstMatch(in: text, range: range) != nil
        case .googleSearch:
            return false
        }
    }

    /// Longer values are typed text.
    private static let maxPlaceholderLength = 120

    /// The Claude Code extension's fixed placeholders (webview `index.js` 2.1.281 to 2.1.317),
    /// lowercased and without the trailing ellipsis: "Ask Claude to edit…" and, while Claude
    /// is busy, "Queue another message…".
    private static let claudeCodePlaceholders: Set<String> = ["ask claude to edit", "queue another message"]

    /// "<shortcut> to focus or unfocus Claude" and "<shortcut> to attach selected text", where
    /// the extension writes the shortcut as "⌘ Esc" on macOS and "ctrl esc" elsewhere. The
    /// slot must read as a key chord: one to three modifiers (a glyph, or a word followed by a
    /// space, "+" or "-") and then a named key or a letter. Ordinary words there ("Make sure to
    /// attach selected text", "How to attach selected text") are typed text.
    private static let claudeCodeShortcutPlaceholder = try! NSRegularExpression(
        pattern: #"^(?:[⌘⌃⌥⇧](?: ?\+ ?| |-)?|(?:cmd|command|ctrl|control|alt|opt|option|shift)(?: ?\+ ?| |-)){1,3}"#
            + #"(?:esc|escape|enter|return|tab|space|f[0-9]{1,2}|[a-z])"#
            + #" to (?:focus or unfocus claude(?: code)?|attach selected text)$"#
    )

    /// chatgpt.com's "Ask anything" and the ChatGPT app's main composer placeholders (its
    /// webview message catalog), lowercased and without the trailing ellipsis. Short phrases a
    /// message could start with ("Follow up") are left out, so typed text is never dropped.
    private static let chatGPTPlaceholders: Set<String> = [
        "ask anything", "ask chatgpt", "message chatgpt", "do anything", "work with chatgpt", "new chat in this project",
    ]

    /// The ChatGPT app's hotkey window: "Ask ChatGPT anything[ locally| in the cloud|
    /// in a worktree][ in <project>]". The project is taken as one word (a folder name), so
    /// typed text such as "Ask ChatGPT anything in Spanish please" is kept; a project name
    /// with spaces is read as text.
    private static let chatGPTAnythingPlaceholder = try! NSRegularExpression(
        pattern: #"^ask chatgpt anything(?: (?:locally|in the cloud|in a worktree))?(?: in \S{1,60})?$"#
    )
}

/// Pure policy for the per-target screen sources: Accessibility label constants, read
/// budgets, window-title parsers and the sources handed to `NameExtractor`. The
/// Accessibility reads themselves live in `AppContextService`.
enum ContextTermSources {
    /// Rollback switch: off stops the new reads, the screen keyterms and the target priming.
    /// Redaction, the omissions and the keyterm budget stay.
    static let isEnabled = true
    /// Rollback switch for the Claude and ChatGPT conversation reads alone.
    static let readsConversationTail = true

    static let claudeComposerLabel = "Message input"
    static let claudeAssistantLabel = "Claude"
    static let claudeUserLabel = "You"
    static let chatGPTAssistantHeading = "ChatGPT said"
    static let chatGPTUserHeading = "You said"

    /// Accessibility messages the conversation tail may send, at most.
    static let maxTailMessages = 12
    static let tailBudgetSeconds: CFAbsoluteTime = 0.12
    static let tailMessagingTimeout: Float = 0.05
    /// The newest assistant text kept across both replies, and the user's last message.
    static let maxAssistantCharacters = 4_000
    static let maxUserCharacters = 2_000

    /// "Claude", "Claude, <tool>" and "Claude, thinking"; not the "Claude Code
    /// conversation" region.
    static func isClaudeAssistantLabel(_ label: String?) -> Bool {
        guard let label else { return false }
        return label == claudeAssistantLabel || label.hasPrefix(claudeAssistantLabel + ", ")
    }

    static func isClaudeUserLabel(_ label: String?) -> Bool {
        label == claudeUserLabel || label == claudeUserLabel + ", queued"
    }

    /// Drops a leading turn label ("ChatGPT said:") and the colon and whitespace after it.
    static func stripTurnLabel(_ text: String, label: String) -> String {
        var rest = text.drop(while: \.isWhitespace)
        guard rest.hasPrefix(label) else { return String(rest) }
        rest = rest.dropFirst(label.count)
        if rest.first == ":" { rest = rest.dropFirst() }
        return String(rest.drop(while: \.isWhitespace))
    }

    /// A heading's parent that holds little more than the label is not the whole turn.
    static func needsOuterTurn(text: String, label: String) -> Bool {
        text.count < 2 * label.count
    }

    /// The last `limit` characters of a turn, redacted before the trim like the cursor slices:
    /// up to twice the limit is read and redacted, then trimmed, each cut dropping the token
    /// it splits. A secret on either cut is replaced whole or dropped, never kept as a
    /// fragment no rule recognizes.
    static func keptTail(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        func suffix(_ text: String, _ count: Int) -> String {
            guard text.count > count else { return text }
            let start = text.index(text.endIndex, offsetBy: -count)
            return text[text.index(before: start)].isWhitespace
                ? String(text[start...])
                : TextContextCore.droppingLeadingPartialToken(text[start...])
        }
        return suffix(SecretFilter.redact(suffix(text, 2 * limit)), limit)
    }

    // MARK: - Window titles

    struct ChromeTitle: Equatable {
        let page: String
        let isPrivate: Bool
    }

    /// Chrome's Accessibility window title is "<page>[ - tab state] - Google Chrome[ Beta|Dev|
    /// Canary][ (Incognito)| (Guest)| - <profile>]". Nil without the Chrome suffix; the
    /// profile name is never kept. The private marker is localized ("(Inkognito)"), so it
    /// fails safe: anything after the Chrome name and channel other than " - <profile>"
    /// counts as private.
    static func chromePage(fromAccessibilityTitle title: String) -> ChromeTitle? {
        guard let suffix = title.range(of: " - Google Chrome", options: .backwards) else { return nil }
        let page = title[..<suffix.lowerBound].trimmingCharacters(in: .whitespaces)
        var tail = title[suffix.upperBound...]
        guard !page.isEmpty else { return nil }
        if let channel = chromeChannels.first(where: { tail.hasPrefix($0) }) { tail = tail.dropFirst(channel.count) }
        return ChromeTitle(page: page, isPrivate: !(tail.isEmpty || tail.hasPrefix(" - ")))
    }

    private static let chromeChannels = [" Beta", " Dev", " Canary"]

    /// "<query> - Google Search[ - tab state]" gives the query. English UI only.
    static func googleQuery(fromPage page: String) -> String? {
        guard let suffix = page.range(of: " - Google Search", options: .backwards) else { return nil }
        let query = page[..<suffix.lowerBound].trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? nil : query
    }

    struct VSCodeTitle: Equatable {
        let editor: String?
        let project: String?
    }

    private static let vscodeAppNames: Set<String> = [
        "Visual Studio Code", "Visual Studio Code - Insiders", "Code", "Code - Insiders"
    ]

    /// A remote window's "[SSH: host]", "[WSL: Ubuntu]" or "[Dev Container: …]" suffix, which
    /// can name an internal host.
    private static let remoteSuffix = try! NSRegularExpression(pattern: #"\s*\[[^\]]*\]$"#)

    /// VS Code's default title "[● ]<editor> — <folder>[ — <profile>][ — Visual Studio Code]".
    /// One piece is the folder. The folder keeps only its name: a remote suffix and a
    /// "(Workspace)" marker are dropped.
    static func vscodeTitle(_ title: String) -> VSCodeTitle {
        var pieces = title.components(separatedBy: " — ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let last = pieces.last, vscodeAppNames.contains(last) { pieces.removeLast() }
        if let first = pieces.first, first.hasPrefix("● ") { pieces[0] = String(first.dropFirst(2)) }
        switch pieces.count {
        case 0: return VSCodeTitle(editor: nil, project: nil)
        case 1: return VSCodeTitle(editor: nil, project: projectName(pieces[0]))
        default: return VSCodeTitle(editor: pieces[0], project: projectName(pieces[1]))
        }
    }

    private static func projectName(_ piece: String) -> String? {
        var name = remoteSuffix.stringByReplacingMatches(
            in: piece, range: NSRange(location: 0, length: (piece as NSString).length), withTemplate: ""
        )
        if name.hasSuffix(" (Workspace)") { name.removeLast(" (Workspace)".count) }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Chrome targets in an Incognito or Guest window give no screen terms. Fails safe: a
    /// title that does not parse cannot show the window is not private.
    static func isPrivateWindow(target: ContextTarget, windowTitle: String?) -> Bool {
        switch target {
        case .chatGPTWeb, .googleSearch:
            guard let windowTitle, let parsed = chromePage(fromAccessibilityTitle: windowTitle) else { return true }
            return parsed.isPrivate
        case .claudeCodePanel, .chatGPTApp:
            return false
        }
    }

    // MARK: - Sources

    /// The texts `NameExtractor` reads for one target, empty texts dropped. Google search
    /// treats the box text and the previous query (from the title) as search queries;
    /// chatgpt.com's title is only "ChatGPT", so it is not read there.
    static func sources(
        for target: ContextTarget,
        windowTitle: String?,
        fieldText: String?,
        conversation: [String]
    ) -> [NameExtractor.Source] {
        var sources: [NameExtractor.Source] = []
        func append(_ text: String?, _ kind: NameExtractor.SourceKind) {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            sources.append(NameExtractor.Source(text: text, kind: kind))
        }
        switch target {
        case .claudeCodePanel:
            let title = windowTitle.map(vscodeTitle)
            append(fieldText, .field)
            append(title?.editor, .title)
            append(title?.project, .projectName)
        case .chatGPTWeb:
            append(fieldText, .field)
        case .chatGPTApp:
            append(fieldText, .field)
            append(windowTitle, .title)
        case .googleSearch:
            let page = windowTitle.flatMap(chromePage(fromAccessibilityTitle:))?.page
            append(page.flatMap(googleQuery(fromPage:)), .searchQuery)
            append(fieldText, .searchQuery)
            return sources
        }
        for text in conversation { append(text, .conversation) }
        return sources
    }
}
