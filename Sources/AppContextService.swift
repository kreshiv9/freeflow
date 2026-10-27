import Foundation
import ApplicationServices
import AppKit

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
    func collectSelectionSnapshot(captureInsertionTarget: Bool = false) -> AppSelectionSnapshot {
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
        let textInsertionTarget = captureInsertionTarget ? AppTextInsertionTarget.capture(
            from: appElement, processIdentifier: frontmostApp.processIdentifier
        ) : nil
        return AppSelectionSnapshot(
            appName: frontmostApp.localizedName,
            bundleIdentifier: frontmostApp.bundleIdentifier,
            windowTitle: focusedWindowTitle(from: appElement) ?? frontmostApp.localizedName,
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

    /// Reads Wispr-style context through Accessibility: app type, text around the cursor,
    /// and nearby labels. No screenshot and no model call; reads stop at a short budget.
    func collectTextContext(readFieldText: Bool) -> AppContext {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return Self.textAppContext(snapshot: nil, appName: nil, bundleIdentifier: nil, windowTitle: nil)
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.textContextMessagingTimeout)
        let appName = frontmostApp.localizedName
        let bundleIdentifier = frontmostApp.bundleIdentifier
        let windowTitle = focusedWindowTitle(from: appElement) ?? appName
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
        readFieldContext(
            into: &snapshot,
            appElement: appElement,
            deadline: CFAbsoluteTimeGetCurrent() + Self.textContextBudgetSeconds
        )
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

    private func readFieldContext(
        into snapshot: inout TextContextSnapshot,
        appElement: AXUIElement,
        deadline: CFAbsoluteTime
    ) {
        if TextContextCore.isSensitiveApp(
            bundleIdentifier: snapshot.bundleIdentifier,
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        ) {
            snapshot.omission = .sensitiveApp
            return
        }

        guard let focused = accessibilityElement(
            from: appElement, attribute: kAXFocusedUIElementAttribute as CFString
        ) else { return }
        AXUIElementSetMessagingTimeout(focused, Self.textContextMessagingTimeout)

        let role = accessibilityRawString(from: focused, attribute: kAXRoleAttribute as CFString)
        let subrole = accessibilityRawString(from: focused, attribute: kAXSubroleAttribute as CFString)
        if subrole == kAXSecureTextFieldSubrole as String {
            snapshot.omission = .secureField
            return
        }

        // In browsers, only page content is read; the address bar and toolbars are skipped.
        if TextContextCore.isBrowser(bundleIdentifier: snapshot.bundleIdentifier) {
            guard let webArea = ancestor(of: focused, role: "AXWebArea", deadline: deadline) else {
                snapshot.omission = .browserControls
                return
            }
            snapshot.websiteDomain = accessibilityURL(from: webArea).flatMap(TextContextCore.domain(from:))
            snapshot.category = TextContextCore.category(
                bundleIdentifier: snapshot.bundleIdentifier, websiteDomain: snapshot.websiteDomain
            )
            if TextContextCore.isSensitiveDomain(snapshot.websiteDomain) {
                snapshot.omission = .sensitiveWebsite
                return
            }
        }

        if AppTextInsertionCore.canCapture(role: role, subrole: subrole),
           let slices = cursorText(from: focused) {
            snapshot.textBeforeCursor = slices.before
            snapshot.selectedText = slices.selected
            snapshot.textAfterCursor = slices.after
        }

        guard CFAbsoluteTimeGetCurrent() < deadline else { return }
        snapshot.nearbyText = nearbyText(
            around: focused,
            excluding: [snapshot.textBeforeCursor, snapshot.selectedText, snapshot.textAfterCursor, snapshot.windowTitle],
            deadline: deadline
        )
    }

    /// Prefers range reads so large documents are never copied whole.
    private func cursorText(from element: AXUIElement) -> CursorTextSlices? {
        guard let selection = accessibilitySelectedRange(from: element) else { return nil }
        let placeholder = accessibilityRawString(from: element, attribute: kAXPlaceholderValueAttribute as CFString)

        if let count = accessibilityInt(from: element, attribute: kAXNumberOfCharactersAttribute as CFString),
           let ranges = TextContextCore.cursorReadRanges(selection: selection, characterCount: count),
           let before = accessibilityString(from: element, range: ranges.before),
           let selected = accessibilityString(from: element, range: ranges.selected),
           let after = accessibilityString(from: element, range: ranges.after) {
            return TextContextCore.normalizedSlices(
                before: before, selected: selected, after: after, placeholder: placeholder
            )
        }

        guard let value = accessibilityTextValue(from: element),
              (value as NSString).length <= Self.maxFullValueLength,
              let slices = TextContextCore.cursorSlices(in: value, selection: selection) else { return nil }
        if let placeholder, !placeholder.isEmpty, value == placeholder { return nil }
        return slices
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
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
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

        let windowTitle = focusedWindowTitle(from: appElement) ?? appName
        let selectedText = selectedText(from: appElement)
        let screenshot = captureActiveWindowScreenshot(
            processIdentifier: frontmostApp.processIdentifier,
            appElement: appElement,
            focusedWindowTitle: windowTitle
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
