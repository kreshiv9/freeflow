import Foundation

/// Picks AssemblyAI's fixed scenario prompt from the destination category FreeFlow already
/// computes. Kept out of AssemblyAIStreamingCore so the core builds without the text-context
/// classifiers. Only the bundle identifier and the page's domain choose a template (the window
/// title only tells a private Chrome window apart), and the result is a fixed case, so screen
/// text, field text, titles, URLs and names cannot reach the prompt.
extension AssemblyAIStreamingCore.PromptScenario {
    static func resolve(bundleIdentifier: String?, websiteDomain: String?) -> Self {
        // First: terminals are in the coding category too.
        if TextContextCore.isTerminal(bundleIdentifier: bundleIdentifier) { return .terminal }
        if CleanupFastPath.isSearchBox(websiteDomain: websiteDomain) { return .googleSearch }
        switch TextContextCore.category(bundleIdentifier: bundleIdentifier, websiteDomain: websiteDomain) {
        // VS Code (so the Claude Code panel too), Cursor, Windsurf, Xcode, JetBrains, github.com.
        case .coding: return .codingAssistant
        // The ChatGPT app (com.openai.codex), ChatGPT Classic, Claude, chatgpt.com, claude.ai.
        case .aiChat: return .aiChat
        case .email: return .email
        case .workMessaging, .personalMessaging, .other: return .dictation
        }
    }

    /// The scenario text context refines the connect prompt to, or nil to keep the connect
    /// prompt (chosen from the bundle only). A Chrome window that is Incognito or Guest, or
    /// whose title does not parse, refines nothing, failing safe like
    /// ContextTermSources.isPrivateWindow, so the kind of page in a private window is never
    /// sent. The title is only checked for those markers.
    static func refinement(bundleIdentifier: String?, websiteDomain: String?, windowTitle: String?) -> Self? {
        if ContextTarget.isChrome(bundleIdentifier: bundleIdentifier),
           windowTitle.flatMap(ContextTermSources.chromePage(fromAccessibilityTitle:))?.isPrivate != false {
            return nil
        }
        return resolve(bundleIdentifier: bundleIdentifier, websiteDomain: websiteDomain)
    }
}
