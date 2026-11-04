import Foundation

/// Invented window titles, labels and bundle identifiers only.
enum ContextTermSourcesTests {
    private typealias Sources = ContextTermSources

    static func run() {
        testChromeTitleParsing()
        testGoogleQueryParsing()
        testVSCodeTitleParsing()
        testClassify()
        testPrimesAccessibility()
        testTurnLabels()
        testSourcesPerTarget()
        testKeptTailRedactsBeforeTrimming()
        testComposerPlaceholders()
    }

    /// Each composer's own placeholder texts match as whole values only; typed text that
    /// mentions the same words does not, and no other composer or app takes them.
    private static func testComposerPlaceholders() {
        for value in [
            "⌘ Esc to focus or unfocus Claude",
            "ctrl esc to focus or unfocus Claude",
            "  ⌘ Esc to focus or unfocus Claude\n",
            "Ctrl+Esc to focus or unfocus Claude Code",
            "⌘ Esc to attach selected text",
            "ctrl esc to attach selected text",
            "⌘⇧Esc to attach selected text",
            "Cmd + Shift + K to focus or unfocus Claude",
            "Ask Claude to edit…",
            "Ask Claude to edit...",
            "Queue another message…",
        ] {
            TestSupport.expect(ContextTarget.claudeCodePanel.isComposerPlaceholder(value), "\(value) is a Claude Code placeholder")
        }
        for value in [
            "How do I use ⌘ Esc to focus or unfocus Claude in the panel?",
            "Use ⌘ Esc to focus or unfocus Claude",
            "⌘ Esc to focus or unfocus Claude and then run the tests",
            "Ask Claude to edit the synthetic README",
            "Queue another message after this one",
            "Ask anything",
            "",
            // Short sentences with ordinary words where the shortcut goes are typed text.
            "Make sure to attach selected text",
            "Remember to attach selected text",
            "How to attach selected text",
            "How to attach the selected text",
            "I want to attach selected text",
            "Options to attach selected text",
            "Remember to focus or unfocus Claude",
            "Press Esc to focus or unfocus Claude",
        ] {
            TestSupport.expect(!ContextTarget.claudeCodePanel.isComposerPlaceholder(value), "\(value) is typed text")
        }

        for target in [ContextTarget.chatGPTWeb, .chatGPTApp] {
            for value in [
                "Ask anything", "Ask anything…", "ask anything ", "Ask ChatGPT", "Message ChatGPT", "Do anything",
                "Work with ChatGPT", "Ask ChatGPT anything locally in synthetic-project", "Ask ChatGPT anything in the cloud",
            ] {
                TestSupport.expect(target.isComposerPlaceholder(value), "\(value) is a ChatGPT placeholder")
            }
            for value in [
                "Ask anything about the synthetic API", "Can I ask anything here?", "Follow up", "Message ChatGPT later",
                "⌘ Esc to focus or unfocus Claude",
                // The project is one word, so a longer typed tail is kept.
                "Ask ChatGPT anything in Spanish please", "Ask ChatGPT anything in the world about Rome",
            ] {
                TestSupport.expect(!target.isComposerPlaceholder(value), "\(value) is typed text")
            }
        }
        TestSupport.expect(!ContextTarget.googleSearch.isComposerPlaceholder("Ask anything"), "Google has no placeholder")
    }

    private static func testChromeTitleParsing() {
        TestSupport.expectEqual(
            Sources.chromePage(fromAccessibilityTitle: "supabase row level security - Google Search - Google Chrome - Work"),
            Sources.ChromeTitle(page: "supabase row level security - Google Search", isPrivate: false)
        )
        let incognito = Sources.chromePage(
            fromAccessibilityTitle: "deepgram pricing - Google Search - Pinned - Google Chrome (Incognito)"
        )
        TestSupport.expectEqual(incognito?.isPrivate, true)
        TestSupport.expectEqual(incognito?.page, "deepgram pricing - Google Search - Pinned")
        TestSupport.expectEqual(
            Sources.chromePage(fromAccessibilityTitle: "Synthetic page - Google Chrome (Guest)")?.isPrivate, true
        )
        TestSupport.expectEqual(Sources.chromePage(fromAccessibilityTitle: "x - Google Chrome Beta")?.page, "x")
        TestSupport.expectEqual(Sources.chromePage(fromAccessibilityTitle: "x - Google Chrome Canary")?.page, "x")
        // The private marker is localized, so any other text after the Chrome name and channel
        // counts as private; only a profile suffix does not.
        for title in [
            "Synthetic page - Google Chrome (Inkognito)", "Synthetic page - Google Chrome Beta (Incognito)",
            "Synthetic page - Google Chrome (Invitado)",
        ] {
            TestSupport.expectEqual(Sources.chromePage(fromAccessibilityTitle: title)?.isPrivate, true)
        }
        for title in ["Synthetic page - Google Chrome", "Synthetic page - Google Chrome Dev - Work", "x - Google Chrome Beta"] {
            TestSupport.expectEqual(Sources.chromePage(fromAccessibilityTitle: title)?.isPrivate, false)
        }
        TestSupport.expectEqual(Sources.chromePage(fromAccessibilityTitle: "google.com/search?q=wispr"), nil)
        TestSupport.expectEqual(
            Sources.chromePage(fromAccessibilityTitle: "ChatGPT - Google Chrome").flatMap { Sources.googleQuery(fromPage: $0.page) },
            nil
        )
    }

    private static func testGoogleQueryParsing() {
        TestSupport.expectEqual(
            Sources.googleQuery(fromPage: "supabase row level security - Google Search"), "supabase row level security"
        )
        TestSupport.expectEqual(Sources.googleQuery(fromPage: "deepgram pricing - Google Search - Pinned"), "deepgram pricing")
        TestSupport.expectEqual(Sources.googleQuery(fromPage: "ChatGPT"), nil)
        TestSupport.expectEqual(Sources.googleQuery(fromPage: " - Google Search"), nil)
    }

    private static func testVSCodeTitleParsing() {
        TestSupport.expectEqual(
            Sources.vscodeTitle("● useAuth.ts — freeflow — Visual Studio Code"),
            Sources.VSCodeTitle(editor: "useAuth.ts", project: "freeflow")
        )
        TestSupport.expectEqual(Sources.vscodeTitle("freeflow"), Sources.VSCodeTitle(editor: nil, project: "freeflow"))
        TestSupport.expectEqual(Sources.vscodeTitle(""), Sources.VSCodeTitle(editor: nil, project: nil))
        // A remote window's host and a workspace marker never reach the folder name.
        TestSupport.expectEqual(
            Sources.vscodeTitle("● useAuth.ts — zorblax-lab [SSH: devbox-07.corp.example.internal] — Visual Studio Code"),
            Sources.VSCodeTitle(editor: "useAuth.ts", project: "zorblax-lab")
        )
        TestSupport.expectEqual(
            Sources.vscodeTitle("zorblax-lab (Workspace) [WSL: Synthetic]"),
            Sources.VSCodeTitle(editor: nil, project: "zorblax-lab")
        )
    }

    private static func testClassify() {
        func classify(
            _ bundle: String?, domain: String? = nil, role: String? = nil, label: String? = nil, webArea: Bool = false
        ) -> ContextTarget? {
            ContextTarget.classify(
                bundleIdentifier: bundle, websiteDomain: domain, focusedRole: role, focusedLabel: label,
                insideWebArea: webArea
            )
        }
        TestSupport.expectEqual(
            classify("com.microsoft.VSCode", role: "AXTextArea", label: "Message input", webArea: true), .claudeCodePanel
        )
        TestSupport.expectEqual(
            classify("com.microsoft.VSCodeInsiders", role: "AXTextArea", label: "Message input", webArea: true),
            .claudeCodePanel
        )
        TestSupport.expectEqual(classify("com.google.Chrome", domain: "chatgpt.com", webArea: true), .chatGPTWeb)
        TestSupport.expectEqual(classify("com.google.Chrome", domain: "chat.openai.com", webArea: true), .chatGPTWeb)
        TestSupport.expectEqual(classify("com.openai.codex", role: "AXTextArea", webArea: true), .chatGPTApp)
        TestSupport.expectEqual(classify("com.google.Chrome", domain: "google.com", webArea: true), .googleSearch)
        TestSupport.expectEqual(classify("com.google.Chrome.canary", domain: "google.co.uk", webArea: true), .googleSearch)

        TestSupport.expectEqual(classify("com.openai.chat", role: "AXTextArea", webArea: true), nil)
        TestSupport.expectEqual(classify("com.openai.atlas", domain: "chatgpt.com", role: "AXTextArea", webArea: true), nil)
        TestSupport.expectEqual(classify("com.apple.Safari", domain: "google.com", role: "AXTextArea", webArea: true), nil)
        TestSupport.expectEqual(classify("com.microsoft.VSCode", role: "AXTextArea", webArea: true), nil)
        TestSupport.expectEqual(classify("com.microsoft.VSCode", role: "AXTextArea", label: "Message input"), nil)
        TestSupport.expectEqual(classify("com.google.Chrome", domain: "mail.google.com", webArea: true), nil)
        TestSupport.expectEqual(classify("com.google.Chrome", domain: "docs.google.com", webArea: true), nil)
        TestSupport.expectEqual(classify("com.brave.Browser", domain: "chatgpt.com", role: "AXTextArea", webArea: true), nil)
        TestSupport.expectEqual(classify(nil, domain: "chatgpt.com", webArea: true), nil)
    }

    private static func testPrimesAccessibility() {
        for bundle in [
            "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.openai.codex",
        ] {
            TestSupport.expect(ContextTarget.primesAccessibility(bundleIdentifier: bundle), "\(bundle) is primed")
        }
        for bundle in ["com.apple.Safari", "com.openai.chat", "com.apple.Terminal", nil] as [String?] {
            TestSupport.expect(!ContextTarget.primesAccessibility(bundleIdentifier: bundle), "Other apps are not primed")
        }
        TestSupport.expect(ContextTarget.readsFocusedLabel(bundleIdentifier: "com.microsoft.VSCode"), "VS Code reads the label")
        TestSupport.expect(!ContextTarget.readsFocusedLabel(bundleIdentifier: "com.openai.codex"), "Only VS Code reads the label")
        for bundle in ["com.google.Chrome", "com.google.Chrome.beta", " COM.GOOGLE.CHROME.CANARY "] {
            TestSupport.expect(ContextTarget.isChrome(bundleIdentifier: bundle), "\(bundle) is Chrome")
        }
        for bundle in ["com.apple.Safari", "com.microsoft.VSCode", "com.google.Chrome.app.synthetic", "", nil] as [String?] {
            TestSupport.expect(!ContextTarget.isChrome(bundleIdentifier: bundle), "Only Chrome is Chrome")
        }
    }

    private static func testTurnLabels() {
        TestSupport.expectEqual(
            Sources.stripTurnLabel("ChatGPT said: Here are options", label: "ChatGPT said"), "Here are options"
        )
        TestSupport.expectEqual(Sources.stripTurnLabel("You said:\nhi there", label: "You said"), "hi there")
        TestSupport.expectEqual(Sources.stripTurnLabel("  plain text", label: "You said"), "plain text")
        TestSupport.expect(Sources.needsOuterTurn(text: "ChatGPT said:", label: "ChatGPT said"), "A bare heading needs its turn")
        TestSupport.expect(
            !Sources.needsOuterTurn(text: "ChatGPT said: a full synthetic reply", label: "ChatGPT said"),
            "A full turn is kept"
        )

        TestSupport.expect(Sources.isClaudeAssistantLabel("Claude"), "Plain assistant article")
        TestSupport.expect(Sources.isClaudeAssistantLabel("Claude, Read"), "Assistant article with a tool")
        TestSupport.expect(!Sources.isClaudeAssistantLabel("Claude Code conversation"), "The region is not a reply")
        TestSupport.expect(!Sources.isClaudeAssistantLabel("Claudette"), "Prefix words are not replies")
        TestSupport.expect(!Sources.isClaudeAssistantLabel(nil), "A missing label is not a reply")
        TestSupport.expect(Sources.isClaudeUserLabel("You"), "User article")
        TestSupport.expect(Sources.isClaudeUserLabel("You, queued"), "Queued user article")
        TestSupport.expect(!Sources.isClaudeUserLabel("Your"), "Other labels are not the user")
    }

    private static func testSourcesPerTarget() {
        TestSupport.expect(
            Sources.isPrivateWindow(target: .chatGPTWeb, windowTitle: "ChatGPT - Google Chrome (Incognito)"),
            "Incognito windows give no screen terms"
        )
        TestSupport.expect(
            Sources.isPrivateWindow(target: .googleSearch, windowTitle: "Google Chrome"),
            "An unparsable Chrome title fails safe"
        )
        TestSupport.expect(Sources.isPrivateWindow(target: .googleSearch, windowTitle: nil), "A missing title fails safe")
        TestSupport.expect(
            !Sources.isPrivateWindow(target: .chatGPTWeb, windowTitle: "ChatGPT - Google Chrome"),
            "A normal Chrome window is not private"
        )
        TestSupport.expect(!Sources.isPrivateWindow(target: .claudeCodePanel, windowTitle: nil), "VS Code is never private")

        TestSupport.expectEqual(
            Sources.sources(
                for: .googleSearch,
                windowTitle: "plinthbase pricing - Google Search - Google Chrome",
                fieldText: "plinthbase free tier",
                conversation: ["ignored synthetic reply"]
            ),
            [
                NameExtractor.Source(text: "plinthbase pricing", kind: .searchQuery),
                NameExtractor.Source(text: "plinthbase free tier", kind: .searchQuery),
            ]
        )

        TestSupport.expectEqual(
            Sources.sources(
                for: .claudeCodePanel,
                windowTitle: "● useAuth.ts — freeflow — Visual Studio Code",
                fieldText: "rename the synthetic hook",
                conversation: ["Synthetic reply", "  "]
            ),
            [
                NameExtractor.Source(text: "rename the synthetic hook", kind: .field),
                NameExtractor.Source(text: "useAuth.ts", kind: .title),
                NameExtractor.Source(text: "freeflow", kind: .projectName),
                NameExtractor.Source(text: "Synthetic reply", kind: .conversation),
            ]
        )

        let remote = Sources.sources(
            for: .claudeCodePanel,
            windowTitle: "useAuth.ts — zorblax-lab [SSH: devbox-07.corp.example.internal] — Visual Studio Code",
            fieldText: nil,
            conversation: []
        )
        TestSupport.expect(
            remote.contains(NameExtractor.Source(text: "zorblax-lab", kind: .projectName)), "The folder name stays"
        )
        TestSupport.expect(!remote.contains { $0.text.contains("devbox") }, "The remote host is never a source")

        let web = Sources.sources(
            for: .chatGPTWeb, windowTitle: "ChatGPT - Google Chrome", fieldText: "", conversation: ["Synthetic reply"]
        )
        TestSupport.expectEqual(web, [NameExtractor.Source(text: "Synthetic reply", kind: .conversation)])

        TestSupport.expectEqual(
            Sources.sources(
                for: .chatGPTApp, windowTitle: "Synthetic chat title", fieldText: nil, conversation: []
            ),
            [NameExtractor.Source(text: "Synthetic chat title", kind: .title)]
        )
    }

    /// A key on the 4,000-character tail cut is redacted whole or dropped: no term shares an
    /// 8-character piece with it.
    private static func testKeptTailRedactsBeforeTrimming() {
        let limit = ContextTermSources.maxAssistantCharacters
        // Invented. A plain trim at 4,000 characters that keeps only its last 8 to 19
        // characters lets a piece of it become a term.
        let key = "sk-" + "ant-" + "api03-" + "uzZ7T_JRpqWRFiVE5c" + "KUQ-z6uG1ynA-SLYFpupip"
        let reply = "Here is the synthetic config you asked for."
        let filler = String(repeating: "We renamed Zorblax to Plinthbase and kept the tests. ", count: 80)
        for keyStart in stride(from: 1, to: key.count, by: 2) {
            // The cut falls `keyStart` characters into the key.
            let tail = String(key.dropFirst(keyStart)) + " " + filler.prefix(limit - (key.count - keyStart) - 1)
            let text = reply + " " + String(key.prefix(keyStart)) + tail
            TestSupport.expect(text.hasSuffix(tail) && tail.count == limit, "The fixture must cut the key at the limit")
            let kept = Sources.keptTail(text, limit: limit)
            TestSupport.expect(kept.count <= limit, "The tail keeps at most the limit")
            let terms = NameExtractor.terms(
                from: [NameExtractor.Source(text: kept, kind: .conversation)], everyday: EverydayWords.all, tagger: nil
            )
            let characters = Array(key)
            for term in terms {
                for start in 0...(characters.count - 8) {
                    TestSupport.expect(
                        !term.contains(String(characters[start..<start + 8])), "No term carries part of a cut key"
                    )
                }
            }
            TestSupport.expect(terms.contains("Plinthbase"), "Names near the cut are kept")
        }

        TestSupport.expectEqual(Sources.keptTail("short synthetic reply", limit: limit), "short synthetic reply")
        TestSupport.expectEqual(Sources.keptTail("alpha beta gamma", limit: 8), " gamma")
        TestSupport.expectEqual(Sources.keptTail("alpha beta gamma", limit: 6), " gamma")
        TestSupport.expectEqual(Sources.keptTail("anything", limit: 0), "")
        // The read cut (twice the limit) splits the key; its fragment is dropped, not kept.
        let readCut = Sources.keptTail(String(repeating: "w", count: 10) + key + " tail of the reply", limit: 15)
        TestSupport.expectEqual(readCut, " of the reply")
    }
}
