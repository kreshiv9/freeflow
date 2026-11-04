import Foundation
import ApplicationServices
import AppKit
import os.log

private let textContextLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "TextContext")

struct AppSelectionSnapshot {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
    let textInsertionTarget: AppTextInsertionTarget?
    let usesOriginalFieldInsertion: Bool
}

struct AppContext {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
    let currentActivity: String
    let contextSystemPrompt: String?
    let contextPrompt: String?
    let screenshotDataURL: String?
    let screenshotMimeType: String?
    let screenshotError: String?
    var textContext: TextContextSnapshot? = nil

    var contextSummary: String {
        currentActivity
    }

    var summaryForPostProcessing: String {
        ContextInferenceFailure.usableSummary(currentActivity)
    }

    /// The CONTEXT section for cleanup and Edit Mode prompts. Text context is sent as a
    /// labeled block; the legacy screenshot path sends its two-sentence summary.
    var promptSectionForPostProcessing: String {
        if let textContext {
            return TextContextCore.promptSection(for: textContext)
        }
        // Run-history retries rebuild context from the stored block.
        if TextContextCore.isPromptSection(currentActivity) {
            return currentActivity.hasSuffix("\n") ? currentActivity : currentActivity + "\n"
        }
        return ContextInferenceFailure.promptSection(for: currentActivity)
    }
}

enum DesktopScreenshotFallbackPreference {
    static let storageKey = "context_desktop_screenshot_fallback_enabled"

    static func load(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: storageKey) == nil
            ? true
            : defaults.bool(forKey: storageKey)
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults) {
        defaults.set(enabled, forKey: storageKey)
    }
}

final class AppContextService {
    static let defaultContextModel = "qwen/qwen3.8-27b"
    static let defaultContextPrompt = """
You are a context synthesis assistant for a speech-to-text pipeline.
Given app/window metadata and an optional screenshot, output exactly two sentences that describe what the user is doing right now and the likely writing intent in the current window.
Prioritize concrete details only from the context: for email, identify recipients, subject or thread cues, and whether the user is replying or composing; for terminal/code/text work, identify the active command, file, document title, or topic.
If details are missing, state uncertainty instead of inventing facts.
Return only two sentences, no labels, no markdown, no extra commentary.
"""
    static let defaultContextPromptDate = "2026-02-24"
    static let defaultScreenshotMaxDimension: CGFloat = 1024

    private let apiKey: String
    private let baseURL: String
    private let customContextPrompt: String
    private let contextModel: String
    private let maxScreenshotDataURILength = 500_000
    private let screenshotCompressionPrimary = 0.5
    private let screenshotMaxDimension: CGFloat
    private let desktopScreenshotFallbackEnabled: Bool
    private var contextRequestTimeoutSeconds: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "context_request_timeout_seconds")
        return override > 0 ? override : 20
    }

    init(
        apiKey: String,
        baseURL: String = "https://api.groq.com/openai/v1",
        customContextPrompt: String = "",
        contextModel: String = AppContextService.defaultContextModel,
        screenshotMaxDimension: CGFloat = AppContextService.defaultScreenshotMaxDimension,
        desktopScreenshotFallbackEnabled: Bool = true
    ) {
        self.apiKey = apiKey
        self.desktopScreenshotFallbackEnabled = desktopScreenshotFallbackEnabled
        self.baseURL = baseURL
        self.customContextPrompt = customContextPrompt
        let trimmedModel = contextModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contextModel = trimmedModel.isEmpty ? Self.defaultContextModel : trimmedModel
        self.screenshotMaxDimension = screenshotMaxDimension > 0
            ? screenshotMaxDimension
            : AppContextService.defaultScreenshotMaxDimension
    }

    private func resolveContextPrompt() -> String {
        let trimmedPrompt = customContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPrompt.isEmpty ? Self.defaultContextPrompt : trimmedPrompt
    }

    /// Captures the mode and optional target together; off skips insertion-target reads.
    /// A manual Edit Mode press also captures the focused field so its text can stand in for a selection.
    func collectSelectionSnapshot(
        captureInsertionTarget: Bool = false, manualCommandRequested: Bool = false
    ) -> AppSelectionSnapshot {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return AppSelectionSnapshot(
                appName: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                selectedText: nil,
                textInsertionTarget: nil,
                usesOriginalFieldInsertion: captureInsertionTarget
            )
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        let textInsertionTarget = captureInsertionTarget || manualCommandRequested ? AppTextInsertionTarget.capture(
            from: appElement, processIdentifier: frontmostApp.processIdentifier
        ) : nil
        return AppSelectionSnapshot(
            appName: frontmostApp.localizedName,
            bundleIdentifier: frontmostApp.bundleIdentifier,
            // Kept only for the Run Log row, so redacted like the text-context title.
            windowTitle: focusedWindowTitle(from: appElement).map(SecretFilter.redact) ?? frontmostApp.localizedName,
            selectedText: !captureInsertionTarget || textInsertionTarget != nil ? rawSelectedText(from: appElement) : nil,
            textInsertionTarget: textInsertionTarget,
            usesOriginalFieldInsertion: captureInsertionTarget
        )
    }

    // MARK: - Text context

    static let textContextScreenshotStatus = "Off (using text context)"
    private static let textContextMessagingTimeout: Float = 0.25
    private static let textContextBudgetSeconds: CFAbsoluteTime = 0.3
    private static let nearbyAncestorLevels = 3
    private static let nearbyMaxElements = 150
    private static let nearbyMaxDepth = 6
    private static let maxFullValueLength = 100_000
    private static let codeContextBudgetSeconds: CFAbsoluteTime = 0.15
    private static let codeContextMessagingTimeout: Float = 0.1
    private static let codeContextMaxElements = 600
    private static let codeContextMaxDepth = 40

    /// Reads Wispr-style context through Accessibility: app type, text around the cursor,
    /// and nearby labels. No screenshot and no model call; reads stop at a short budget.
    /// In Cursor, Windsurf and VS Code it also collects file names and code identifiers
    /// on a separate short budget. Secret-shaped text is redacted as it is read.
    ///
    /// With `wantsSpeechTerms` (a Deepgram stream is live), the Claude Code panel, ChatGPT
    /// and Google search also give on-screen names (`ContextTermSources`), and
    /// `onSpeechTerms` runs at most once with those names and the code identifiers: before
    /// the code walk for the Claude Code panel, whose editors mostly read empty, and after it
    /// everywhere else.
    func collectTextContext(
        readFieldText: Bool,
        wantsSpeechTerms: Bool = false,
        onSpeechTerms: (_ screenTerms: [String], _ identifiers: [String]) -> Void = { _, _ in }
    ) -> AppContext {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return Self.textAppContext(snapshot: nil, appName: nil, bundleIdentifier: nil, windowTitle: nil)
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.textContextMessagingTimeout)
        let appName = frontmostApp.localizedName
        let bundleIdentifier = frontmostApp.bundleIdentifier
        let shownTitle = focusedWindowTitle(from: appElement)
        let windowTitle = shownTitle.map(SecretFilter.redact) ?? appName
        // The secrets-file checks read the title as shown, since redaction can hide the file
        // name they look for; only the redacted title is kept.
        let titleForChecks = shownTitle ?? appName
        guard readFieldText else {
            return Self.textAppContext(
                snapshot: nil, appName: appName, bundleIdentifier: bundleIdentifier, windowTitle: windowTitle
            )
        }

        var snapshot = TextContextSnapshot(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            category: TextContextCore.category(bundleIdentifier: bundleIdentifier, websiteDomain: nil),
            windowTitle: windowTitle
        )
        let readsTerms = wantsSpeechTerms && ContextTermSources.isEnabled
        let field = readFieldContext(
            into: &snapshot,
            appElement: appElement,
            shownWindowTitle: titleForChecks,
            readsSpeechSources: readsTerms,
            deadline: CFAbsoluteTimeGetCurrent() + Self.textContextBudgetSeconds
        )
        if readsTerms, snapshot.omission == nil, let field, let target = field.target {
            snapshot.contextTerms = speechTerms(target: target, snapshot: snapshot, field: field)
        }
        let termsBeforeCodeWalk = field?.target == .claudeCodePanel
        if wantsSpeechTerms, termsBeforeCodeWalk {
            onSpeechTerms(snapshot.contextTerms, [])
        }
        // A secrets-file title still reads file-name labels for @-mention tagging, but
        // readCodeContext reads no editor text under it.
        if snapshot.omission == nil || snapshot.omission == .secretsFile,
           IdentifierExtractor.collectsCodeContext(bundleIdentifier: bundleIdentifier, category: snapshot.category) {
            readCodeContext(
                into: &snapshot,
                appElement: appElement,
                shownWindowTitle: titleForChecks,
                deadline: CFAbsoluteTimeGetCurrent() + Self.codeContextBudgetSeconds
            )
        }
        if wantsSpeechTerms, !termsBeforeCodeWalk {
            onSpeechTerms(snapshot.contextTerms, snapshot.codeIdentifiers)
        }
        return Self.textAppContext(
            snapshot: snapshot, appName: appName, bundleIdentifier: bundleIdentifier, windowTitle: windowTitle
        )
    }

    private static func textAppContext(
        snapshot: TextContextSnapshot?,
        appName: String?,
        bundleIdentifier: String?,
        windowTitle: String?
    ) -> AppContext {
        AppContext(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: snapshot?.selectedText,
            currentActivity: snapshot.map(TextContextCore.promptSection(for:)) ?? "",
            contextSystemPrompt: nil,
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: textContextScreenshotStatus,
            textContext: snapshot
        )
    }

    /// The focused field, its web area (browsers always; VS Code and ChatGPT.app only when a
    /// target needs it) and its context target. Local to one collection; never stored.
    private struct FocusedField {
        let element: AXUIElement
        let webArea: AXUIElement?
        let target: ContextTarget?
    }

    /// Nil when the field was not read: an omission, or no focused element. The secrets-file
    /// omission reads `shownWindowTitle`, the title before redaction.
    private func readFieldContext(
        into snapshot: inout TextContextSnapshot,
        appElement: AXUIElement,
        shownWindowTitle: String?,
        readsSpeechSources: Bool,
        deadline: CFAbsoluteTime
    ) -> FocusedField? {
        if TextContextCore.isSensitiveApp(
            bundleIdentifier: snapshot.bundleIdentifier,
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        ) {
            snapshot.omission = .sensitiveApp
            return nil
        }
        // A deliberate trade-off: terminal scrollback can hold unlabeled secrets that no rule
        // recognizes, so terminal text is never read. Cursor formatting then has no text to fit
        // a terminal paste to, so it keeps the cleanup's casing and adds no leading space.
        if TextContextCore.isTerminal(bundleIdentifier: snapshot.bundleIdentifier) {
            snapshot.omission = .terminal
            return nil
        }

        guard let focused = accessibilityElement(
            from: appElement, attribute: kAXFocusedUIElementAttribute as CFString
        ) else { return nil }
        AXUIElementSetMessagingTimeout(focused, Self.textContextMessagingTimeout)

        let role = accessibilityRawString(from: focused, attribute: kAXRoleAttribute as CFString)
        let subrole = accessibilityRawString(from: focused, attribute: kAXSubroleAttribute as CFString)
        if subrole == kAXSecureTextFieldSubrole as String {
            snapshot.omission = .secureField
            return nil
        }

        var webArea: AXUIElement?
        var label: String?
        let isBrowser = TextContextCore.isBrowser(bundleIdentifier: snapshot.bundleIdentifier)
        // In browsers, only page content is read; the address bar and toolbars are skipped.
        if isBrowser {
            guard let browserWebArea = ancestor(of: focused, role: "AXWebArea", deadline: deadline) else {
                snapshot.omission = .browserControls
                return nil
            }
            webArea = browserWebArea
            snapshot.websiteDomain = accessibilityURL(from: browserWebArea).flatMap(TextContextCore.domain(from:))
        }
        // The category comes from the page's domain before any omission, so a page whose title
        // names a secrets file keeps its AI chat, email or messaging behaviour.
        let decision = TextContextCore.fieldReadDecision(
            bundleIdentifier: snapshot.bundleIdentifier,
            websiteDomain: snapshot.websiteDomain,
            windowTitle: shownWindowTitle
        )
        snapshot.category = decision.category
        if let omission = decision.omission {
            snapshot.omission = omission
            return nil
        }
        // The label tells the Claude Code composer apart from VS Code's editors, both for its
        // placeholder below and for the conversation read, so it is read with or without a
        // Deepgram stream.
        if !isBrowser, role == kAXTextAreaRole as String,
           ContextTarget.readsFocusedLabel(bundleIdentifier: snapshot.bundleIdentifier) {
            label = accessibilityRawString(from: focused, attribute: kAXDescriptionAttribute as CFString)
                ?? accessibilityRawString(from: focused, attribute: kAXTitleAttribute as CFString)
        }
        // The composer the field would be if it sits in a web area; outside browsers that is
        // only checked when the conversation read needs the web area.
        let composer = ContextTarget.classify(
            bundleIdentifier: snapshot.bundleIdentifier, websiteDomain: snapshot.websiteDomain,
            focusedRole: role, focusedLabel: label, insideWebArea: true
        )
        if !isBrowser, readsSpeechSources, composer != nil {
            // The Claude Code composer and ChatGPT.app's composer sit in a web area that
            // only the conversation read needs.
            webArea = ancestor(of: focused, role: "AXWebArea", deadline: deadline)
        }
        let target = ContextTarget.classify(
            bundleIdentifier: snapshot.bundleIdentifier, websiteDomain: snapshot.websiteDomain,
            focusedRole: role, focusedLabel: label, insideWebArea: webArea != nil
        )
        let field = FocusedField(element: focused, webArea: webArea, target: target)

        // An empty composer can report its placeholder as its value; it then reads as empty.
        if AppTextInsertionCore.canCapture(role: role, subrole: subrole),
           let slices = cursorText(from: focused, composer: composer) {
            snapshot.fieldTextRead = true
            snapshot.textBeforeCursor = slices.before
            snapshot.selectedText = slices.selected
            snapshot.textAfterCursor = slices.after
        }

        // Google's suggestions list sits next to its search box and can hold past searches.
        guard target != .googleSearch, CFAbsoluteTimeGetCurrent() < deadline else { return field }
        snapshot.nearbyText = nearbyText(
            around: focused,
            excluding: [snapshot.textBeforeCursor, snapshot.selectedText, snapshot.textAfterCursor, snapshot.windowTitle],
            deadline: deadline
        )
        return field
    }

    /// On-screen names for one target's Deepgram Configure: none from an Incognito or Guest
    /// window. The conversation, title and query text stay inside this function; only the
    /// extracted terms leave it, and the log line carries counts and the target code only.
    private func speechTerms(target: ContextTarget, snapshot: TextContextSnapshot, field: FocusedField) -> [String] {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard !ContextTermSources.isPrivateWindow(target: target, windowTitle: snapshot.windowTitle) else { return [] }
        var conversation: [String] = []
        var tailMessages = 0
        if ContextTermSources.readsConversationTail, target != .googleSearch, let webArea = field.webArea {
            let tail = conversationTail(
                target: target, webArea: webArea, composer: field.element,
                deadline: startedAt + ContextTermSources.tailBudgetSeconds
            )
            conversation = tail.texts
            tailMessages = tail.messages
        }
        let fieldText = [snapshot.textBeforeCursor, snapshot.selectedText, snapshot.textAfterCursor]
            .compactMap { $0 }
            .joined(separator: "\n")
        let sources = ContextTermSources.sources(
            for: target, windowTitle: snapshot.windowTitle, fieldText: fieldText, conversation: conversation
        )
        let tagger: NameExtractor.NameTagger? = NameExtractor.usesNameTagger ? NameExtractor.nameTagger : nil
        let terms = NameExtractor.terms(from: sources, everyday: EverydayWords.all, tagger: tagger)
        os_log(
            .debug, log: textContextLog,
            "context terms: target=%{public}@ sources=%d terms=%d tail=%d msgs in %d ms",
            target.rawValue, sources.count, terms.count, tailMessages,
            Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())
        )
        return terms
    }

    /// The newest Claude replies and the user's last message (Claude Code panel), or the
    /// last "ChatGPT said" and "You said" turns (ChatGPT), found with Chromium's search
    /// predicate from the composer backwards. Read-only, no child enumeration, at most
    /// `ContextTermSources.maxTailMessages` messages and stops at `deadline`. Assistant text
    /// keeps its newest `maxAssistantCharacters`, the user's its last `maxUserCharacters`.
    private func conversationTail(
        target: ContextTarget,
        webArea: AXUIElement,
        composer: AXUIElement,
        deadline: CFAbsoluteTime
    ) -> (texts: [String], messages: Int) {
        var remainingMessages = ContextTermSources.maxTailMessages
        var messages = 0
        AXUIElementSetMessagingTimeout(webArea, ContextTermSources.tailMessagingTimeout)

        func spend() -> Bool {
            guard remainingMessages > 0, CFAbsoluteTimeGetCurrent() < deadline else { return false }
            remainingMessages -= 1
            messages += 1
            return true
        }
        /// Newest first: the search runs backwards from the composer.
        func search(key: String, text: String, limit: Int) -> [AXUIElement] {
            guard spend() else { return [] }
            let parameter: [String: Any] = [
                "AXSearchKey": key,
                "AXSearchText": text,
                "AXResultsLimit": limit,
                "AXStartElement": composer,
                "AXDirection": "AXDirectionPrevious",
            ]
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                webArea, "AXUIElementsForSearchPredicate" as CFString, parameter as CFDictionary, &value
            ) == .success, let results = value as? [AnyObject] else { return [] }
            return results.compactMap { result in
                CFGetTypeID(result) == AXUIElementGetTypeID() ? unsafeBitCast(result, to: AXUIElement.self) : nil
            }
        }
        func label(of element: AXUIElement) -> String? {
            guard spend() else { return nil }
            AXUIElementSetMessagingTimeout(element, ContextTermSources.tailMessagingTimeout)
            return accessibilityRawString(from: element, attribute: kAXDescriptionAttribute as CFString)
        }
        func parent(of element: AXUIElement) -> AXUIElement? {
            guard spend() else { return nil }
            AXUIElementSetMessagingTimeout(element, ContextTermSources.tailMessagingTimeout)
            return accessibilityElement(from: element, attribute: kAXParentAttribute as CFString)
        }
        /// The element's whole text, through the web area's text markers.
        func turnText(of element: AXUIElement) -> String? {
            guard spend() else { return nil }
            var range: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                webArea, "AXTextMarkerRangeForUIElement" as CFString, element, &range
            ) == .success, let range, spend() else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                webArea, "AXStringForTextMarkerRange" as CFString, range, &value
            ) == .success else { return nil }
            if let text = value as? String { return text }
            return (value as? NSAttributedString)?.string
        }
        /// A heading's turn: its parent, or one level more when the parent holds little
        /// more than the label; the label itself is stripped.
        func headingTurn(_ heading: AXUIElement, label: String) -> String? {
            guard let turn = parent(of: heading), var text = turnText(of: turn) else { return nil }
            if ContextTermSources.needsOuterTurn(text: text, label: label),
               let outer = parent(of: turn), let outerText = turnText(of: outer) {
                text = outerText
            }
            return ContextTermSources.stripTurnLabel(text, label: label)
        }

        var assistantTexts: [String] = []
        var userText: String?
        switch target {
        case .claudeCodePanel:
            // The search text also matches the "Claude Code conversation" region; labels
            // tell the reply articles apart.
            var assistantArticles: [AXUIElement] = []
            for article in search(key: "AXLandmarkSearchKey", text: ContextTermSources.claudeAssistantLabel, limit: 3)
            where assistantArticles.count < 2 && ContextTermSources.isClaudeAssistantLabel(label(of: article)) {
                assistantArticles.append(article)
            }
            let userArticle = search(key: "AXLandmarkSearchKey", text: ContextTermSources.claudeUserLabel, limit: 1)
                .first { ContextTermSources.isClaudeUserLabel(label(of: $0)) }
            assistantTexts = assistantArticles.compactMap { turnText(of: $0) }
            userText = userArticle.flatMap { turnText(of: $0) }
        case .chatGPTWeb, .chatGPTApp:
            let assistantHeading = search(
                key: "AXHeadingSearchKey", text: ContextTermSources.chatGPTAssistantHeading, limit: 1
            ).first
            let userHeading = search(key: "AXHeadingSearchKey", text: ContextTermSources.chatGPTUserHeading, limit: 1).first
            assistantTexts = assistantHeading
                .flatMap { headingTurn($0, label: ContextTermSources.chatGPTAssistantHeading) }
                .map { [$0] } ?? []
            userText = userHeading.flatMap { headingTurn($0, label: ContextTermSources.chatGPTUserHeading) }
        case .googleSearch:
            return ([], 0)
        }

        // Newest first: keep the newest assistant text up to the cap, redacted before each
        // trim so a secret on the cut leaves no fragment.
        var keptAssistant: [String] = []
        var remainingCharacters = ContextTermSources.maxAssistantCharacters
        for text in assistantTexts where remainingCharacters > 0 {
            let kept = ContextTermSources.keptTail(text, limit: remainingCharacters)
            keptAssistant.append(kept)
            remainingCharacters -= kept.count
        }
        var texts = keptAssistant
        if let userText {
            texts.append(ContextTermSources.keptTail(userText, limit: ContextTermSources.maxUserCharacters))
        }
        return (texts, messages)
    }

    /// Prefers range reads so large documents are never copied whole. A value that is the
    /// field's placeholder (`AXPlaceholderValue`, or one of `composer`'s own placeholder texts,
    /// which the Claude Code panel and ChatGPT draw with CSS) gives empty slices: an empty
    /// field, not text before the cursor.
    private func cursorText(from element: AXUIElement, composer: ContextTarget?) -> CursorTextSlices? {
        guard let selection = accessibilitySelectedRange(from: element) else { return nil }
        let placeholder = accessibilityRawString(from: element, attribute: kAXPlaceholderValueAttribute as CFString)

        if let count = accessibilityInt(from: element, attribute: kAXNumberOfCharactersAttribute as CFString),
           let ranges = TextContextCore.cursorReadRanges(selection: selection, characterCount: count),
           let before = accessibilityString(from: element, range: ranges.before),
           let selected = accessibilityString(from: element, range: ranges.selected),
           let after = accessibilityString(from: element, range: ranges.after) {
            return TextContextCore.normalizedSlices(
                before: before, selected: selected, after: after, placeholder: placeholder, composer: composer,
                cuts: TextContextCore.readCuts(of: ranges, selection: selection, characterCount: count)
            )
        }

        guard let value = accessibilityTextValue(from: element),
              (value as NSString).length <= Self.maxFullValueLength else { return nil }
        return TextContextCore.cursorSlices(in: value, selection: selection, placeholder: placeholder, composer: composer)
    }

    /// Collects short labels and values near the focused field (names, recipients, thread
    /// lines), skipping the field itself and secure controls, within element and time limits.
    private func nearbyText(around focused: AXUIElement, excluding: [String?], deadline: CFAbsoluteTime) -> String? {
        var root = focused
        for _ in 0..<Self.nearbyAncestorLevels {
            guard CFAbsoluteTimeGetCurrent() < deadline,
                  let parent = accessibilityElement(from: root, attribute: kAXParentAttribute as CFString) else { break }
            AXUIElementSetMessagingTimeout(parent, Self.textContextMessagingTimeout)
            let parentRole = accessibilityRawString(from: parent, attribute: kAXRoleAttribute as CFString)
            if parentRole == kAXWindowRole as String || parentRole == kAXApplicationRole as String { break }
            root = parent
        }
        guard !CFEqual(root, focused) else { return nil }

        var candidates: [String] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < Self.nearbyMaxElements, CFAbsoluteTimeGetCurrent() < deadline {
            let (element, depth) = queue[index]
            index += 1
            if CFEqual(element, focused) { continue }
            AXUIElementSetMessagingTimeout(element, Self.textContextMessagingTimeout)

            let role = accessibilityRawString(from: element, attribute: kAXRoleAttribute as CFString)
            let subrole = accessibilityRawString(from: element, attribute: kAXSubroleAttribute as CFString)
            if subrole == kAXSecureTextFieldSubrole as String { continue }
            if role == kAXStaticTextRole as String || AppTextInsertionCore.canCapture(role: role, subrole: subrole) {
                if let text = accessibilityTextValue(from: element), text.count <= TextContextCore.maxNearbyCharacters {
                    candidates.append(text)
                }
            }

            guard depth < Self.nearbyMaxDepth, queue.count < Self.nearbyMaxElements * 2 else { continue }
            for child in accessibilityChildren(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return TextContextCore.nearbyText(from: candidates, excluding: excluding)
    }

    /// Code editors only: walks the focused window breadth-first for file names (window
    /// title, tab and row titles and descriptions) and for identifiers in the visible text of
    /// editors other than the focused field, whose text was already read. Skips secure fields
    /// and reads no editor text while the window title, as shown before redaction, shows a
    /// secrets file or folder, with or without an extension (id_rsa, credentials, .ssh). Never
    /// writes an attribute and never logs; the editor text stays local to this function, and
    /// the partial results stand when the deadline passes.
    private func readCodeContext(
        into snapshot: inout TextContextSnapshot,
        appElement: AXUIElement,
        shownWindowTitle: String?,
        deadline: CFAbsoluteTime
    ) {
        var labels = [snapshot.windowTitle].compactMap { $0 }
        let readsEditorText = !IdentifierExtractor.titleShowsSecretsFile(shownWindowTitle)
        // Already read, so no extra calls; first, so they survive the identifier cap.
        var editorTexts = readsEditorText
            ? [snapshot.textBeforeCursor, snapshot.selectedText, snapshot.textAfterCursor, snapshot.nearbyText]
                .compactMap { $0 }
            : []
        var remaining = IdentifierExtractor.maxEditorCharacters
        defer {
            snapshot.fileNames = IdentifierExtractor.fileNames(fromLabels: labels)
            snapshot.codeIdentifiers = IdentifierExtractor.identifiers(in: editorTexts)
        }

        guard let window = accessibilityElement(
            from: appElement, attribute: kAXFocusedWindowAttribute as CFString
        ) else { return }
        let focused = accessibilityElement(from: appElement, attribute: kAXFocusedUIElementAttribute as CFString)

        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0
        while index < queue.count, index < Self.codeContextMaxElements, CFAbsoluteTimeGetCurrent() < deadline {
            let (element, depth) = queue[index]
            index += 1
            AXUIElementSetMessagingTimeout(element, Self.codeContextMessagingTimeout)

            let attributes = codeContextAttributes(of: element)
            if attributes.subrole == kAXSecureTextFieldSubrole as String { continue }
            labels += [attributes.title, attributes.description].compactMap { $0 }

            if attributes.role == kAXTextAreaRole as String {
                let isFocused = focused.map { CFEqual($0, element) } ?? false
                if readsEditorText, remaining > 0, !isFocused,
                   let text = visibleEditorText(from: element, limit: remaining) {
                    editorTexts.append(SecretFilter.redact(text))
                    remaining -= text.count
                }
                continue
            }

            guard depth < Self.codeContextMaxDepth, queue.count < Self.codeContextMaxElements * 2 else { continue }
            for child in attributes.children {
                queue.append((child, depth + 1))
            }
        }
    }

    private struct CodeContextAttributes {
        let role: String?
        let subrole: String?
        let title: String?
        let description: String?
        let children: [AXUIElement]
    }

    /// One batched read per element. An attribute the element lacks comes back as an
    /// AXValue error and reads as nil. When the batched call itself is refused, the
    /// attributes are read one by one, unless the element timed out or is gone.
    private func codeContextAttributes(of element: AXUIElement) -> CodeContextAttributes {
        let names = [
            kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute
        ] as CFArray
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values
        )
        guard result == .success, let array = values as? [AnyObject], array.count == 5 else {
            guard result != .cannotComplete, result != .invalidUIElement else {
                return CodeContextAttributes(role: nil, subrole: nil, title: nil, description: nil, children: [])
            }
            return CodeContextAttributes(
                role: accessibilityRawString(from: element, attribute: kAXRoleAttribute as CFString),
                subrole: accessibilityRawString(from: element, attribute: kAXSubroleAttribute as CFString),
                title: accessibilityRawString(from: element, attribute: kAXTitleAttribute as CFString),
                description: accessibilityRawString(from: element, attribute: kAXDescriptionAttribute as CFString),
                children: accessibilityChildren(of: element)
            )
        }

        func usable(_ value: AnyObject) -> AnyObject? {
            if CFGetTypeID(value) == AXValueGetTypeID(),
               AXValueGetType(unsafeBitCast(value, to: AXValue.self)) == .axError {
                return nil
            }
            return value
        }
        func string(_ value: AnyObject) -> String? {
            guard let text = usable(value) as? String, !text.isEmpty else { return nil }
            return text
        }
        let children = (usable(array[4]) as? [AnyObject] ?? []).compactMap { child in
            CFGetTypeID(child) == AXUIElementGetTypeID() ? unsafeBitCast(child, to: AXUIElement.self) : nil
        }
        return CodeContextAttributes(
            role: string(array[0]),
            subrole: string(array[1]),
            title: string(array[2]),
            description: string(array[3]),
            children: children
        )
    }

    /// The visible part of an editor by range, else a prefix by range, else a value that is
    /// not too large; never more than `limit` characters.
    private func visibleEditorText(from element: AXUIElement, limit: Int) -> String? {
        if let visible = accessibilityRange(from: element, attribute: kAXVisibleCharacterRangeAttribute as CFString),
           visible.location != NSNotFound, visible.length > 0,
           let text = accessibilityString(
               from: element, range: NSRange(location: visible.location, length: min(visible.length, limit * 2))
           ), !text.isEmpty {
            return String(text.prefix(limit))
        }
        if let count = accessibilityInt(from: element, attribute: kAXNumberOfCharactersAttribute as CFString),
           count > 0,
           let text = accessibilityString(from: element, range: NSRange(location: 0, length: min(count, limit * 2))),
           !text.isEmpty {
            return String(text.prefix(limit))
        }
        guard let value = accessibilityTextValue(from: element), !value.isEmpty,
              (value as NSString).length <= Self.maxFullValueLength else { return nil }
        return String(value.prefix(limit))
    }

    private func ancestor(of element: AXUIElement, role targetRole: String, deadline: CFAbsoluteTime) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<32 {
            guard let candidate = current, CFAbsoluteTimeGetCurrent() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(candidate, Self.textContextMessagingTimeout)
            if accessibilityRawString(from: candidate, attribute: kAXRoleAttribute as CFString) == targetRole {
                return candidate
            }
            current = accessibilityElement(from: candidate, attribute: kAXParentAttribute as CFString)
        }
        return nil
    }

    private func accessibilitySelectedRange(from element: AXUIElement) -> NSRange? {
        accessibilityRange(from: element, attribute: kAXSelectedTextRangeAttribute as CFString)
    }

    private func accessibilityRange(from element: AXUIElement, attribute: CFString) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(rawValue, to: AXValue.self), .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func accessibilityInt(from element: AXUIElement, attribute: CFString) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    /// Returns "" for an empty range without asking the app; nil when the app cannot answer.
    private func accessibilityString(from element: AXUIElement, range: NSRange) -> String? {
        guard range.length > 0 else { return "" }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value
        ) == .success else { return nil }
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }

    private func accessibilityTextValue(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }

    private func accessibilityURL(from element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url }
        return (value as? String).flatMap(URL.init(string:))
    }

    private func accessibilityChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AnyObject] else { return [] }
        return children.compactMap { child in
            CFGetTypeID(child) == AXUIElementGetTypeID() ? unsafeBitCast(child, to: AXUIElement.self) : nil
        }
    }

    // MARK: - Legacy screenshot context

    func collectContext() async -> AppContext {
        let contextSystemPrompt = resolveContextPrompt()

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return AppContext(
                appName: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                selectedText: nil,
                currentActivity: "You are dictating in an unrecognized context.",
                contextSystemPrompt: contextSystemPrompt,
                contextPrompt: nil,
                screenshotDataURL: nil,
                screenshotMimeType: nil,
                screenshotError: "No frontmost application"
            )
        }

        let appName = frontmostApp.localizedName
        let bundleIdentifier = frontmostApp.bundleIdentifier
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)

        let shownTitle = focusedWindowTitle(from: appElement)
        // The model request and the Run Log get the redacted title; only the window match
        // below compares the title as shown with the window list's names.
        let windowTitle = shownTitle.map(SecretFilter.redact) ?? appName
        let selectedText = selectedText(from: appElement)
        let screenshot = captureActiveWindowScreenshot(
            processIdentifier: frontmostApp.processIdentifier,
            appElement: appElement,
            focusedWindowTitle: shownTitle ?? appName
        )
        let currentActivity: String
        let contextPrompt: String?
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch await inferActivityWithLLM(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: selectedText,
                screenshotDataURL: screenshot.dataURL,
                contextSystemPrompt: contextSystemPrompt
            ) {
            case .success(let result):
                currentActivity = result.activity
                contextPrompt = result.prompt
            case .failure(let error):
                currentActivity = error.summary
                contextPrompt = nil
            }
        } else {
            currentActivity = ContextInferenceFailure.missingAPIKey.summary
            contextPrompt = nil
        }

        return AppContext(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: selectedText,
            currentActivity: currentActivity,
            contextSystemPrompt: contextSystemPrompt,
            contextPrompt: contextPrompt,
            screenshotDataURL: screenshot.dataURL,
            screenshotMimeType: screenshot.mimeType,
            screenshotError: screenshot.error
        )
    }

    private func inferActivityWithLLM(
        appName: String?,
        bundleIdentifier: String?,
        windowTitle: String?,
        selectedText: String?,
        screenshotDataURL: String?,
        contextSystemPrompt: String
    ) async -> Result<(activity: String, prompt: String), ContextInferenceFailure> {
        let attempts: [(model: String, screenshotDataURL: String?)] =
            if let screenshotDataURL {
                [
                    (contextModel, screenshotDataURL),
                    (contextModel, nil)
                ]
            } else {
                [
                    (contextModel, nil)
                ]
            }

        var lastFailure = ContextInferenceFailure.emptySummary
        for attempt in attempts {
            switch await inferActivityWithLLM(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: selectedText,
                screenshotDataURL: attempt.screenshotDataURL,
                contextSystemPrompt: contextSystemPrompt,
                model: attempt.model
            ) {
            case .success(let inferred): return .success(inferred)
            case .failure(let error):
                lastFailure = error
                // Removing an image cannot repair auth, a missing model, or
                // throttling. Avoid sending the same failing request twice.
                if case .httpStatus(let status) = error,
                   [401, 403, 404, 429].contains(status) { return .failure(error) }
            }
        }

        return .failure(lastFailure)
    }

    private func inferActivityWithLLM(
        appName: String?,
        bundleIdentifier: String?,
        windowTitle: String?,
        selectedText: String?,
        screenshotDataURL: String?,
        contextSystemPrompt: String,
        model: String
    ) async -> Result<(activity: String, prompt: String), ContextInferenceFailure> {
        do {
            var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
            request.httpMethod = "POST"
            request.timeoutInterval = contextRequestTimeoutSeconds
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let metadata = """
App: \(appName ?? "Unknown")
Bundle ID: \(bundleIdentifier ?? "Unknown")
Window: \(windowTitle ?? "Unknown")
Selected text: \(selectedText ?? "None")
"""

            let textOnlyPrompt = "Analyze the context and infer the user's current activity in exactly two sentences.\n\n\(metadata)"
            var userMessageDescription: String
            var userMessage: Any = textOnlyPrompt

            if let screenshotDataURL {
                userMessageDescription = "[screenshot attached]\nAnalyze the screenshot plus metadata to infer current activity.\n\(metadata)"
                userMessage = [
                    [
                        "type": "text",
                        "text": "Analyze the screenshot plus metadata to infer current activity."
                    ],
                    [
                        "type": "text",
                        "text": metadata
                    ],
                    [
                        "type": "image_url",
                        "image_url": ["url": screenshotDataURL]
                    ]
                ]
            } else {
                userMessageDescription = textOnlyPrompt
            }

            let fullPrompt = "Model: \(model)\n\n[System]\n\(contextSystemPrompt)\n[User]\n\(userMessageDescription)"

            var payload: [String: Any] = [
                "model": model,
                "temperature": 0.2,
                "messages": [
                    ["role": "system", "content": contextSystemPrompt],
                    ["role": "user", "content": userMessage]
                ]
            ]

            payload.merge(Self.inferenceRequestOptions(for: model)) { _, option in option }

            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            let (data, response) = try await LLMAPITransport.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            return Self.inferenceResult(data: data, status: httpResponse.statusCode, model: model, prompt: fullPrompt)
        } catch {
            if (error as? URLError)?.code == .timedOut { return .failure(.timeout) }
            return .failure(.network)
        }
    }

    static func inferenceRequestOptions(for model: String) -> [String: Any] {
        // Two sentences need a small completion budget. Leaving this unset
        // can reserve more output tokens than Groq's free-tier TPM limit.
        var options: [String: Any] = ["max_completion_tokens": 512]
        let config = ModelConfiguration.config(for: model)
        if let effort = config.reasoningEffort { options["reasoning_effort"] = effort }
        if let include = config.includeReasoning { options["include_reasoning"] = include }
        return options
    }

    static func inferenceResult(
        data: Data, status: Int, model: String, prompt: String
    ) -> Result<(activity: String, prompt: String), ContextInferenceFailure> {
        guard status == 200 else { return .failure(.httpStatus(status)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return .failure(.invalidResponse)
        }
        guard let activity = activitySummary(from: content, model: model) else {
            return .failure(.emptySummary)
        }
        return .success((activity: activity, prompt: prompt))
    }

    static func activitySummary(from rawContent: String, model: String) -> String? {
        var content = rawContent
        if ModelConfiguration.config(for: model).shouldStripThinkTags {
            content = ModelConfiguration.stripThinkTags(content)
        }

        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return normalizedActivitySummary(cleaned)
    }

    private static func normalizedActivitySummary(_ value: String) -> String {
        let sentences = value
            .split(whereSeparator: { $0 == "." || $0 == "。" || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sentences.count <= 2 {
            return value
        }

        let firstTwo = sentences.prefix(2)
        return firstTwo.joined(separator: ". ") + "."
    }

    private func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard let focusedWindow = accessibilityElement(from: appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        if let windowTitle = accessibilityString(from: focusedWindow, attribute: kAXTitleAttribute as CFString) {
            return trimmedText(windowTitle)
        }

        return nil
    }

    private func selectedText(from appElement: AXUIElement) -> String? {
        if let focusedElement = accessibilityElement(from: appElement, attribute: kAXFocusedUIElementAttribute as CFString),
           let selectedText = accessibilityString(from: focusedElement, attribute: kAXSelectedTextAttribute as CFString) {
            return trimmedText(selectedText)
        }

        if let selectedText = accessibilityString(from: appElement, attribute: kAXSelectedTextAttribute as CFString) {
            return trimmedText(selectedText)
        }

        return nil
    }

    private func rawSelectedText(from appElement: AXUIElement) -> String? {
        if let focusedElement = accessibilityElement(from: appElement, attribute: kAXFocusedUIElementAttribute as CFString),
           let selectedText = accessibilityRawString(from: focusedElement, attribute: kAXSelectedTextAttribute as CFString) {
            return selectedText
        }

        if let selectedText = accessibilityRawString(from: appElement, attribute: kAXSelectedTextAttribute as CFString) {
            return selectedText
        }

        return nil
    }

    private func accessibilityElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func accessibilityString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return trimmedText(stringValue)
    }

    private func accessibilityRawString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return stringValue.isEmpty ? nil : stringValue
    }

    private func accessibilityPoint(from element: AXUIElement, attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func accessibilitySize(from element: AXUIElement, attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func captureActiveWindowScreenshot(
        processIdentifier: pid_t,
        appElement: AXUIElement,
        focusedWindowTitle: String?
    ) -> (dataURL: String?, mimeType: String?, error: String?) {
        if !CGPreflightScreenCaptureAccess() {
            return (
                nil,
                nil,
                "Screen recording permission not granted. Enable in System Settings > Privacy & Security > Screen Recording."
            )
        }

        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]

        guard let windows else {
            return (nil, nil, "Unable to read window list")
        }

        let ownerPIDKey = kCGWindowOwnerPID as String
        let layerKey = kCGWindowLayer as String
        let onScreenKey = kCGWindowIsOnscreen as String
        let windowIDKey = kCGWindowNumber as String
        let boundsKey = kCGWindowBounds as String
        let nameKey = kCGWindowName as String

        struct CandidateWindow {
            let id: CGWindowID
            let layer: Int
            let area: Int
            let bounds: CGRect?
            let name: String?
        }

        let candidateWindows = windows.compactMap { windowInfo -> CandidateWindow? in
            guard let ownerPID = windowInfo[ownerPIDKey] as? Int,
                  ownerPID == processIdentifier else {
                return nil
            }
            guard let isOnScreen = windowInfo[onScreenKey] as? Bool, isOnScreen else { return nil }
            guard let windowIDValue = windowInfo[windowIDKey] as? Int else { return nil }
            let layer = (windowInfo[layerKey] as? Int) ?? 0
            let bounds = boundsRect(windowInfo[boundsKey])
            let width = bounds?.width ?? 1
            let height = bounds?.height ?? 1
            let area = Int(width * height)
            let name = trimmedText(windowInfo[nameKey] as? String)

            return CandidateWindow(
                id: CGWindowID(windowIDValue),
                layer: layer,
                area: area,
                bounds: bounds,
                name: name
            )
        }

        if let focusedWindowBounds = focusedWindowBounds(from: appElement), !focusedWindowBounds.isNull {
            if let activeWindow = candidateWindows
                .compactMap({ candidate -> (CandidateWindow, CGFloat)? in
                    guard let candidateBounds = candidate.bounds else { return nil }
                    let intersection = candidateBounds.intersection(focusedWindowBounds)
                    guard !intersection.isNull else { return nil }
                    let overlap = intersection.width * intersection.height
                    return (candidate, overlap)
                })
                .sorted(by: { lhs, rhs in
                    if lhs.0.layer == rhs.0.layer {
                        return lhs.1 > rhs.1
                    }
                    return lhs.0.layer < rhs.0.layer
                })
                    .first?.0 {
                if let dataURL = captureWindowImage(
                    windowID: activeWindow.id,
                    fileType: .jpeg,
                    mimeType: "image/jpeg",
                    compression: screenshotCompressionPrimary,
                    maxDimension: screenshotMaxDimension
                ) {
                    return (dataURL, "image/jpeg", nil)
                }
            }

            if let focusedWindowTitle,
               let activeWindow = candidateWindows
                   .filter({ candidate in
                       let normalizedName = candidate.name?
                           .lowercased()
                           .trimmingCharacters(in: .whitespacesAndNewlines)
                       let normalizedTarget = focusedWindowTitle
                           .lowercased()
                           .trimmingCharacters(in: .whitespacesAndNewlines)
                       guard let normalizedName, !normalizedName.isEmpty,
                             !normalizedTarget.isEmpty else {
                           return false
                       }

                       return normalizedName == normalizedTarget || normalizedName.contains(normalizedTarget)
                   })
                   .sorted(by: { lhs, rhs in
                       if lhs.layer == rhs.layer {
                           return lhs.area > rhs.area
                       }
                       return lhs.layer < rhs.layer
                   })
                   .first {
                if let dataURL = captureWindowImage(
                    windowID: activeWindow.id,
                    fileType: .jpeg,
                    mimeType: "image/jpeg",
                    compression: screenshotCompressionPrimary,
                    maxDimension: screenshotMaxDimension
                ) {
                    return (dataURL, "image/jpeg", nil)
                }
            }
        }

        return captureDesktopFallback {
            captureDesktopScreenshot()
        }
    }

    // Keep the preference boundary ahead of all desktop capture and image work.
    // The injected operation also lets tests verify this without Screen Recording.
    func captureDesktopFallback(
        using capture: () -> (dataURL: String?, mimeType: String?, error: String?)
    ) -> (dataURL: String?, mimeType: String?, error: String?) {
        guard desktopScreenshotFallbackEnabled else {
            return (nil, nil, "Active-window screenshot unavailable; full-desktop fallback is disabled in Settings.")
        }
        return capture()
    }

    private func captureDesktopScreenshot() -> (dataURL: String?, mimeType: String?, error: String?) {
        guard let fullScreenImage = CGWindowListCreateImage(
            CGRect.infinite,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return (nil, nil, "Could not capture screenshot from the active window")
        }

        if let croppedImage = croppedWhitespaceImage(from: fullScreenImage),
           let dataURL = convertImageToDataURL(
            croppedImage,
            mimeType: "image/jpeg",
            fileType: .jpeg,
            compression: screenshotCompressionPrimary,
            maxDimension: screenshotMaxDimension
        ) {
            return (dataURL, "image/jpeg", nil)
        }

        return (nil, nil, "Could not capture screenshot within size limits")
    }

    private func captureWindowImage(
        windowID: CGWindowID,
        fileType: NSBitmapImageRep.FileType,
        mimeType: String,
        compression: Double? = nil,
        maxDimension: CGFloat? = nil
    ) -> String? {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution]
        ) else {
            return nil
        }

        if let dataURL = convertImageToDataURL(
            image,
            mimeType: mimeType,
            fileType: fileType,
            compression: compression,
            maxDimension: maxDimension
        ) {
            return dataURL
        }

        return nil
    }

    private func boundsValue(_ value: Any?) -> CGSize? {
        guard let bounds = value as? [String: Any],
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat else {
            return nil
        }

        return CGSize(width: width, height: height)
    }

    private func boundsRect(_ value: Any?) -> CGRect? {
        guard let bounds = value as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func focusedWindowBounds(from appElement: AXUIElement) -> CGRect? {
        guard let focusedWindow = accessibilityElement(
            from: appElement,
            attribute: kAXFocusedWindowAttribute as CFString
        ),
              let point = accessibilityPoint(from: focusedWindow, attribute: kAXPositionAttribute as CFString),
              let size = accessibilitySize(from: focusedWindow, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }

    private func convertImageToDataURL(
        _ image: CGImage,
        mimeType: String,
        fileType: NSBitmapImageRep.FileType,
        compression: Double?,
        maxDimension: CGFloat?
    ) -> String? {
        let compressionSteps: [Double] = if let compression {
            [compression, compression * 0.5, compression * 0.25]
        } else {
            [1.0]
        }
        let dimensionSteps: [CGFloat?] = if let maxDimension {
            [maxDimension, maxDimension * 0.75, maxDimension * 0.5]
        } else {
            [nil]
        }

        for dim in dimensionSteps {
            let imageToEncode = dim.flatMap { resizedImage(for: image, maxDimension: $0) } ?? image
            let rep = NSBitmapImageRep(cgImage: imageToEncode)

            for comp in compressionSteps {
                guard let imageData = rep.representation(
                    using: fileType,
                    properties: [.compressionFactor: comp]
                ) else { continue }

                let base64 = imageData.base64EncodedString()
                if base64.count <= maxScreenshotDataURILength {
                    return "data:\(mimeType);base64,\(base64)"
                }
            }
        }

        return nil
    }

    private func croppedWhitespaceImage(from image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let byteCount = bytesPerRow * height
        var pixelData = Array(repeating: UInt8(0), count: byteCount)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixelData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }

        let drawRect = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        context.draw(image, in: drawRect)

        let whiteThreshold: UInt8 = 245
        let alphaThreshold: UInt8 = 5
        var minX = width
        var minY = height
        var maxX: Int = -1
        var maxY: Int = -1
        var hasContent = false

        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let offset = rowOffset + x * bytesPerPixel
                let r = pixelData[offset]
                let g = pixelData[offset + 1]
                let b = pixelData[offset + 2]
                let a = pixelData[offset + 3]

                if a <= alphaThreshold { continue }
                if r >= whiteThreshold && g >= whiteThreshold && b >= whiteThreshold {
                    continue
                }

                hasContent = true
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard hasContent else { return image }

        let cropRect = CGRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(maxX - minX + 1),
            height: CGFloat(maxY - minY + 1)
        )

        return image.cropping(to: cropRect) ?? image
    }

    private func resizedImage(for image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        guard width > maxDimension || height > maxDimension else {
            return image
        }

        let scale = min(maxDimension / width, maxDimension / height, 1.0)
        let targetSize = CGSize(width: width * scale, height: height * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: image.bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))
        return context.makeImage()
    }

    private func trimmedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? nil : trimmed
    }
}
