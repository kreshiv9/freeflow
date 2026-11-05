import Darwin
import Foundation

/// The hook entry, its merge into a settings file, the prompt normalizer and the health check.
/// Invented prompts and settings only. The installer tests work in temporary directories and
/// never touch a real settings file.
enum ClaudeCodeHookTests {
    private typealias Settings = ClaudeCodeHookSettings
    private typealias Installer = ClaudeCodeHookInstaller
    private static let app = "FreeFlow"
    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func run() {
        testPreference()
        testSnippetIsPinned()
        testHookPromptNormalization()
        testContextBlocks()
        testWorstCasePromptsStayLinear()
        testFrameParsing()
        testInstallIntoMissingOrEmpty()
        testInstallKeepsOtherHooks()
        testInstallWhenOursIsPresent()
        testOtherAppIsLeftAlone()
        testInvalidSettingsThrow()
        testUninstall()
        testInstallerInvalidJSONWritesNothing()
        testInstallerBackups()
        testInstallerCreatesMissingFile()
        testConnectAfterHandAddedSnippet()
        testInstallerKeepsSymlink()
        testInstallerStatus()
        testHealth()
    }

    // MARK: Fixtures

    private static func json(_ text: String) -> Data {
        Data(text.utf8)
    }

    private static func object(_ data: Data) -> NSDictionary {
        (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary ?? [:]
    }

    private static func withTemporaryDirectory(_ body: (URL) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreeFlowHookTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        body(directory)
    }

    private static func mode(of url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    private static func ourGroups(in data: Data, event: String = "UserPromptSubmit") -> [NSDictionary] {
        ((object(data)["hooks"] as? NSDictionary)?[event] as? [NSDictionary]) ?? []
    }

    private static func backups(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.contains(".freeflow-backup-") }
            .sorted()
    }

    // MARK: Preference

    private static func testPreference() {
        let suite = "FreeFlowTests.ClaudeCodeHook.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        TestSupport.expectEqual(ClaudeCodeHookPreference.storageKey, "claude_code_hook_connected")
        TestSupport.expect(!ClaudeCodeHookPreference.load(from: defaults), "Not connected until the user connects")
        defaults.set("yes", forKey: ClaudeCodeHookPreference.storageKey)
        TestSupport.expect(!ClaudeCodeHookPreference.load(from: defaults), "An invalid value means not connected")
        defaults.set(true, forKey: ClaudeCodeHookPreference.storageKey)
        TestSupport.expect(ClaudeCodeHookPreference.load(from: defaults), "The stored choice wins")
    }

    // MARK: Hook entry

    private static func testSnippetIsPinned() {
        let expected = #"""
        {
          "hooks": {
            "UserPromptSubmit": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/bin/sh",
                    "args": [
                      "-c",
                      "[ \"$CLAUDE_CODE_ENTRYPOINT\" = claude-vscode ] || exit 0; /usr/bin/nc -U -w 2 \"$HOME/Library/Application Support/FreeFlow/learn/hook.sock\" >/dev/null 2>&1; exit 0"
                    ],
                    "async": true,
                    "timeout": 5
                  }
                ]
              }
            ]
          }
        }
        """#
        TestSupport.expectEqual(Settings.snippet(appName: "FreeFlow"), expected)
        TestSupport.expectEqual(
            Settings.snippet(appName: "FreeFlow Dev"),
            expected.replacingOccurrences(of: "Support/FreeFlow/learn", with: "Support/FreeFlow Dev/learn")
        )

        // What the sheet shows is what Connect writes into an empty file.
        let snippet = json(Settings.snippet(appName: app))
        guard let installed = try? Settings.installing(into: nil, appName: app) else {
            TestSupport.expect(false, "Installing into nothing succeeds")
            return
        }
        TestSupport.expectEqual(object(installed.data), object(snippet))

        let hook = (ourGroups(in: snippet).first?["hooks"] as? [NSDictionary])?.first
        TestSupport.expectEqual(hook?["async"] as? Bool, true)
        TestSupport.expectEqual(hook?["timeout"] as? Int, 5)
        // Exec form, as the decision memo gives it: no outer shell.
        TestSupport.expectEqual(hook?["command"] as? String, "/bin/sh")
        let args = hook?["args"] as? [String] ?? []
        TestSupport.expectEqual(args.count, 2)
        TestSupport.expectEqual(args.first, "-c")
        let script = args.last ?? ""
        TestSupport.expect(script.hasPrefix(#"[ "$CLAUDE_CODE_ENTRYPOINT" = claude-vscode ] || exit 0;"#), "Only the VS Code extension")
        TestSupport.expect(script.hasSuffix("; exit 0"), "Always exits 0")
        TestSupport.expect(script.contains(">/dev/null 2>&1"), "Prints nothing")

        // The listener binds the path the command connects to, per app.
        let support = URL(fileURLWithPath: "/Users/synthetic/Library/Application Support", isDirectory: true)
        for name in ["FreeFlow", "FreeFlow Dev"] {
            TestSupport.expect(
                ClaudeHookListener.socketURL(applicationSupport: support, appName: name).path
                    .hasSuffix(Settings.socketPathMarker(appName: name)),
                "The socket path matches the command"
            )
        }
    }

    // MARK: Normalization (H1-H5)

    private static func testHookPromptNormalization() {
        // H1, H2: IDE blocks are removed whole, with selected code in them.
        TestSupport.expectEqual(
            HookPrompt.userText("<ide_selection>The user selected:\nlet secret = 1\n</ide_selection>\nask cloud to refactor"),
            "ask cloud to refactor"
        )
        TestSupport.expectEqual(
            HookPrompt.userText("<ide_opened_file>The user opened parser.swift</ide_opened_file>\nfix the parser"),
            "fix the parser"
        )
        // H3: paste-marker lines go, their body stays.
        TestSupport.expectEqual(
            HookPrompt.userText("before\n<pasted_content id=\"2bba\">\nasked by voice\n</pasted_content id=\"2bba\">\nafter"),
            "before asked by voice after"
        )
        // H4: slash commands teach nothing, also behind an IDE block.
        TestSupport.expectEqual(HookPrompt.userText("/compact"), nil)
        TestSupport.expectEqual(HookPrompt.userText("<ide_opened_file>x</ide_opened_file>\n/compact keep it"), nil)
        TestSupport.expectEqual(HookPrompt.userText("  \n "), nil)
        TestSupport.expectEqual(HookPrompt.userText("<ide_selection>only context</ide_selection>"), nil)
        // H5: look-alikes are the user's text.
        TestSupport.expectEqual(HookPrompt.userText("<ide_selections>x</ide_selections> keep"), "<ide_selections>x</ide_selections> keep")
        TestSupport.expectEqual(HookPrompt.userText("use <browserslist>x</browserslist>"), "use <browserslist>x</browserslist>")
        TestSupport.expectEqual(
            HookPrompt.userText("<pasted_content id=\"xyz1\">\nbody"),
            "<pasted_content id=\"xyz1\"> body"
        )
        TestSupport.expectEqual(HookPrompt.userText("inline <pasted_content id=\"2bba\"> mention"), "inline <pasted_content id=\"2bba\"> mention")
        TestSupport.expectEqual(HookPrompt.userText("<browser url=\"x\">page text\nmore</browser>\nsearch it"), "search it")
        TestSupport.expectEqual(HookPrompt.userText("<browser>page</browser> search it"), "search it")
        TestSupport.expectEqual(HookPrompt.userText("line one\nline two\n\nline three"), "line one line two line three")
    }

    private static func testContextBlocks() {
        // Each block ends at its first closing tag, and what follows stays.
        TestSupport.expectEqual(
            HookPrompt.userText("<ide_selection>a</ide_selection> keep <ide_selection>b</ide_selection> this"),
            "keep this"
        )
        TestSupport.expectEqual(HookPrompt.userText("<ide_selection>a</ide_selection></ide_selection> keep"), "</ide_selection> keep")
        // An unclosed tag is the user's text.
        TestSupport.expectEqual(HookPrompt.userText("<ide_selection> keep this"), "<ide_selection> keep this")
        TestSupport.expectEqual(HookPrompt.userText("<browser url=\"x\"> keep this"), "<browser url=\"x\"> keep this")
        TestSupport.expectEqual(HookPrompt.userText("keep <browser"), "keep <browser")
        TestSupport.expectEqual(HookPrompt.userText("keep <browser x"), "keep <browser x")
        TestSupport.expectEqual(
            HookPrompt.userText("<ide_selection>a</ide_selection> keep <ide_selection>b"),
            "keep <ide_selection>b"
        )
        // Attributes may span lines, and the tag ends at its first ">".
        TestSupport.expectEqual(HookPrompt.userText("<browser\nurl=\"x\"\ntitle=\"y\">page</browser>keep"), "keep")
        TestSupport.expectEqual(HookPrompt.userText("<browser a <browser b>page</browser> keep"), "keep")
        TestSupport.expectEqual(HookPrompt.userText("<browser a </browser> keep"), "<browser a </browser> keep")
        // Text around a block is untouched, whatever its script.
        TestSupport.expectEqual(HookPrompt.userText("caf\u{E9} <ide_opened_file>\u{1F600}</ide_opened_file> na\u{EF}ve"), "caf\u{E9} na\u{EF}ve")
    }

    /// The frame cap's worth of repeated unclosed tags, which made the earlier regular expression
    /// backtrack quadratically while the listener's stop() waited.
    private static func testWorstCasePromptsStayLinear() {
        let started = Date()
        let pieces = [
            "<browser x ", "<ide_selection>", "<ide_opened_file>", "<browser>", "<browser x>", "<browser", "</browser", "<",
        ]
        for piece in pieces {
            let prompt = String(repeating: piece, count: HookFrameBuffer.maxBytes / piece.utf8.count)
            TestSupport.expectEqual(HookPrompt.userText(prompt)?.isEmpty, false)
        }
        TestSupport.expect(Date().timeIntervalSince(started) < 5, "Worst-case prompts stay fast")
    }

    private static func testFrameParsing() {
        func frame(_ text: String) -> HookPrompt.Frame { HookPrompt.frame(from: json(text)) }
        TestSupport.expectEqual(frame(#"{"prompt":"hello there"}"#), .prompt("hello there"))
        TestSupport.expectEqual(
            frame(#"{"hook_event_name":"UserPromptSubmit","prompt":"hello there","cwd":"/synthetic","session_id":"1","transcript_path":"/synthetic/t","session_title":"x"}"#),
            .prompt("hello there")
        )
        TestSupport.expectEqual(frame(#"{"prompt":"/compact"}"#), .skipped)
        TestSupport.expectEqual(frame(#"{"prompt":""}"#), .skipped)
        for malformed in [
            "", "not json", "[1,2]", "\"text\"", "{}", #"{"prompt":7}"#, #"{"prompt":null}"#,
            #"{"hook_event_name":"Stop","prompt":"hello"}"#, #"{"hook_event_name":3,"prompt":"hello"}"#,
        ] {
            TestSupport.expectEqual(frame(malformed), .malformed)
        }
    }

    // MARK: Merge

    private static func testInstallIntoMissingOrEmpty() {
        let expected = object(json(Settings.snippet(appName: app)))
        for data in [nil, Data(), json("  \n\t "), json("{}")] as [Data?] {
            guard let result = try? Settings.installing(into: data, appName: app) else {
                TestSupport.expect(false, "Installing into nothing or {} succeeds")
                continue
            }
            TestSupport.expect(result.changed, "A new entry is a change")
            TestSupport.expectEqual(object(result.data), expected)
            TestSupport.expect(Settings.isInstalled(in: result.data, appName: app), "The entry is found again")
        }
    }

    private static let settingsWithOtherHooks = #"""
    {
      "env": {"SYNTHETIC": "value/with/slashes"},
      "model": "synthetic",
      "number": 1.5,
      "hooks": {
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/synthetic/check"}]}],
        "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/synthetic/other", "timeout": 3}]}]
      }
    }
    """#

    private static func testInstallKeepsOtherHooks() {
        let original = json(settingsWithOtherHooks)
        guard let installed = try? Settings.installing(into: original, appName: app),
              let removed = try? Settings.removing(from: installed.data, appName: app) else {
            TestSupport.expect(false, "Merging into valid settings succeeds")
            return
        }
        TestSupport.expect(installed.changed, "A new entry is a change")
        TestSupport.expectEqual(object(removed.data), object(original))
        let groups = ourGroups(in: installed.data)
        TestSupport.expectEqual(groups.count, 2)
        TestSupport.expectEqual((groups[0]["hooks"] as? [NSDictionary])?.first?["command"] as? String, "/synthetic/other")
        TestSupport.expect(Settings.isInstalled(in: installed.data, appName: app), "Ours comes after the other entry")
        TestSupport.expectEqual(ourGroups(in: installed.data, event: "PreToolUse").count, 1)
        TestSupport.expect(
            String(decoding: installed.data, as: UTF8.self).contains("value/with/slashes"),
            "Slashes stay readable"
        )
    }

    private static func testInstallWhenOursIsPresent() {
        guard let first = try? Settings.installing(into: nil, appName: app),
              let second = try? Settings.installing(into: first.data, appName: app) else {
            TestSupport.expect(false, "Installing succeeds")
            return
        }
        TestSupport.expect(!second.changed, "An identical entry changes nothing")
        TestSupport.expectEqual(second.data, first.data)

        // Other forms of ours are older variants: the first is replaced where it sits, and the
        // rest go.
        let olderForms = #"""
        {"hooks":{"UserPromptSubmit":[
          {"hooks":[{"type":"command","command":"/synthetic/before"}]},
          {"hooks":[{"type":"command","command":"/usr/bin/nc -U \"$HOME/Library/Application Support/FreeFlow/learn/hook.sock\"","async":true,"timeout":5}]},
          {"hooks":[{"type":"command","command":"/synthetic/after"},{"type":"command","command":"/bin/sh","args":["-c","/usr/bin/nc -U \"$HOME/Library/Application Support/FreeFlow/learn/hook.sock\""]}]}
        ]}}
        """#
        guard let replaced = try? Settings.installing(into: json(olderForms), appName: app) else {
            TestSupport.expect(false, "Replacing an older variant succeeds")
            return
        }
        TestSupport.expect(replaced.changed, "An older variant is a change")
        let groups = ourGroups(in: replaced.data)
        let hooks = groups.map { ($0["hooks"] as? [NSDictionary]) ?? [] }
        TestSupport.expectEqual(hooks.map(\.count), [1, 1, 1])
        TestSupport.expectEqual(hooks[0][0]["command"] as? String, "/synthetic/before")
        TestSupport.expectEqual(hooks[1][0]["command"] as? String, Settings.command)
        TestSupport.expectEqual(hooks[1][0]["args"] as? [String], ["-c", Settings.script(appName: app)])
        TestSupport.expectEqual(hooks[2][0]["command"] as? String, "/synthetic/after")
    }

    private static func testOtherAppIsLeftAlone() {
        guard let dev = try? Settings.installing(into: nil, appName: "FreeFlow Dev"),
              let both = try? Settings.installing(into: dev.data, appName: "FreeFlow"),
              let removed = try? Settings.removing(from: both.data, appName: "FreeFlow") else {
            TestSupport.expect(false, "Both apps can install")
            return
        }
        TestSupport.expect(both.changed, "Another app's entry is not ours")
        TestSupport.expectEqual(ourGroups(in: both.data).count, 2)
        TestSupport.expectEqual(object(removed.data), object(dev.data))
        TestSupport.expect(!Settings.isInstalled(in: dev.data, appName: "FreeFlow"), "FreeFlow Dev's entry is not FreeFlow's")
    }

    private static func testInvalidSettingsThrow() {
        func installError(_ text: String) -> Settings.SettingsError? {
            do {
                _ = try Settings.installing(into: json(text), appName: app)
                return nil
            } catch {
                return error as? Settings.SettingsError
            }
        }
        func removeError(_ text: String) -> Settings.SettingsError? {
            do {
                _ = try Settings.removing(from: json(text), appName: app)
                return nil
            } catch {
                return error as? Settings.SettingsError
            }
        }
        for text in ["{not json", "// comment\n{}"] {
            TestSupport.expectEqual(installError(text), .invalidJSON)
            TestSupport.expectEqual(removeError(text), .invalidJSON)
            TestSupport.expect(!Settings.isInstalled(in: json(text), appName: app), "Invalid JSON holds no entry")
        }
        for text in ["[]", #"{"hooks":[]}"#, #"{"hooks":{"UserPromptSubmit":{}}}"#] {
            TestSupport.expectEqual(installError(text), .unexpectedShape)
            TestSupport.expectEqual(removeError(text), .unexpectedShape)
        }
    }

    private static func testUninstall() {
        guard let only = try? Settings.installing(into: json("{}"), appName: app),
              let emptied = try? Settings.removing(from: only.data, appName: app) else {
            TestSupport.expect(false, "Install then remove succeeds")
            return
        }
        TestSupport.expect(emptied.changed, "Removing ours is a change")
        TestSupport.expectEqual(object(emptied.data), [:])

        // A group that holds another hook stays, without ours.
        let shared = """
        {"hooks":{"UserPromptSubmit":[{"hooks":[
          {"type":"command","command":"/synthetic/other"},
          {"type":"command","command":"\(Settings.socketPathMarker(appName: app))"}
        ]}]}}
        """
        guard let kept = try? Settings.removing(from: json(shared), appName: app) else {
            TestSupport.expect(false, "Removing from a shared group succeeds")
            return
        }
        TestSupport.expect(kept.changed, "Removing ours is a change")
        let hooks = ourGroups(in: kept.data).first?["hooks"] as? [NSDictionary]
        TestSupport.expectEqual(hooks?.count, 1)
        TestSupport.expectEqual(hooks?.first?["command"] as? String, "/synthetic/other")

        // Nothing of ours: unchanged, even with an empty section it did not empty.
        for text in [settingsWithOtherHooks, "{}", "", #"{"hooks":{"UserPromptSubmit":[]}}"#] {
            guard let absent = try? Settings.removing(from: json(text), appName: app) else {
                TestSupport.expect(false, "Removing nothing succeeds")
                continue
            }
            TestSupport.expect(!absent.changed, "Nothing to remove is no change")
            TestSupport.expectEqual(absent.data, json(text))
        }
    }

    // MARK: Installer

    private static func installer(_ directory: URL, at date: Date = start) -> Installer {
        Installer(settingsURL: directory.appendingPathComponent("settings.json"), appName: app, now: { date })
    }

    private static func testInstallerInvalidJSONWritesNothing() {
        withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("settings.json")
            let bytes = json("{ \"model\": \"synthetic\", // comment\n}")
            try? bytes.write(to: url)
            TestSupport.expectEqual(installer(directory).connect(), .invalidJSON)
            TestSupport.expectEqual(installer(directory).disconnect(), .invalidJSON)
            TestSupport.expectEqual(try? Data(contentsOf: url), bytes)
            TestSupport.expectEqual(backups(in: directory), [])
            try? json("[]").write(to: url)
            TestSupport.expectEqual(installer(directory).connect(), .unexpectedShape)
            TestSupport.expectEqual(try? Data(contentsOf: url), json("[]"))
            TestSupport.expectEqual(backups(in: directory), [])
        }
    }

    private static func testInstallerBackups() {
        withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("settings.json")
            let original = json(settingsWithOtherHooks)
            try? original.write(to: url)
            chmod(url.path, 0o640)

            let connected = installer(directory).connect()
            guard case .done(let backup?) = connected else {
                TestSupport.expect(false, "Connect writes with a backup")
                return
            }
            TestSupport.expectEqual(try? Data(contentsOf: backup), original)
            TestSupport.expectEqual(mode(of: backup), 0o640)
            TestSupport.expectEqual(mode(of: url), 0o640)
            TestSupport.expect(
                backup.lastPathComponent.hasPrefix("settings.json.freeflow-backup-2026"),
                "A UTC stamp beside the file"
            )
            TestSupport.expectEqual(backup.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
            let afterConnect = try? Data(contentsOf: url)
            TestSupport.expect(afterConnect.map { Settings.isInstalled(in: $0, appName: app) } ?? false, "The entry is in the file")

            // A second connect writes nothing and makes no backup.
            TestSupport.expectEqual(installer(directory).connect(), .alreadyDone)
            TestSupport.expectEqual(try? Data(contentsOf: url), afterConnect)
            TestSupport.expectEqual(backups(in: directory).count, 1)

            // Disconnect at the same instant never overwrites the first backup.
            guard case .done(let secondBackup?) = installer(directory).disconnect() else {
                TestSupport.expect(false, "Disconnect writes with a backup")
                return
            }
            TestSupport.expect(secondBackup != backup, "Two distinct backups")
            TestSupport.expectEqual(try? Data(contentsOf: backup), original)
            TestSupport.expectEqual(try? Data(contentsOf: secondBackup), afterConnect)
            TestSupport.expectEqual(backups(in: directory).count, 2)
            TestSupport.expectEqual((try? Data(contentsOf: url)).map(object), object(original))
            TestSupport.expectEqual(mode(of: url), 0o640)

            TestSupport.expectEqual(installer(directory).disconnect(), .alreadyDone)
            TestSupport.expectEqual(backups(in: directory).count, 2)
            let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.contains("freeflow-tmp") }
            TestSupport.expectEqual(leftovers, [])
        }
    }

    private static func testInstallerCreatesMissingFile() {
        withTemporaryDirectory { directory in
            let nested = directory.appendingPathComponent("not-there-yet", isDirectory: true)
            let url = nested.appendingPathComponent("settings.json")
            TestSupport.expectEqual(installer(nested).disconnect(), .alreadyDone)
            TestSupport.expect(!FileManager.default.fileExists(atPath: nested.path), "Disconnect creates nothing")
            TestSupport.expectEqual(installer(nested).connect(), .done(backup: nil))
            TestSupport.expectEqual(mode(of: url), 0o600)
            TestSupport.expectEqual(backups(in: nested), [])
            TestSupport.expectEqual(installer(nested).status(), .connected)
        }
    }

    /// A hand-added snippet does nothing until Connect, which then finds it, writes nothing and
    /// starts listening; invalid JSON still fails, as the sheet says.
    private static func testConnectAfterHandAddedSnippet() {
        withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("settings.json")
            try? json(Settings.snippet(appName: app)).write(to: url)
            TestSupport.expectEqual(installer(directory).status(), .connected)
            TestSupport.expectEqual(installer(directory).connect(), .alreadyDone)
            TestSupport.expectEqual(backups(in: directory), [])

            try? json("// comment\n" + Settings.snippet(appName: app)).write(to: url)
            TestSupport.expectEqual(installer(directory).connect(), .invalidJSON)
        }
    }

    private static func testInstallerKeepsSymlink() {
        withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("elsewhere.json")
            let link = directory.appendingPathComponent("settings.json")
            try? json("{\"model\":\"synthetic\"}").write(to: target)
            chmod(target.path, 0o600)
            try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            guard case .done(let backup?) = installer(directory).connect() else {
                TestSupport.expect(false, "Connect through a symlink writes with a backup")
                return
            }
            TestSupport.expect(
                (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil,
                "The link stays a link"
            )
            TestSupport.expect(
                (try? Data(contentsOf: target)).map { Settings.isInstalled(in: $0, appName: app) } ?? false,
                "Its target is updated"
            )
            TestSupport.expectEqual(mode(of: target), 0o600)
            TestSupport.expectEqual(mode(of: backup), 0o600)
            TestSupport.expect(backup.lastPathComponent.hasPrefix("elsewhere.json.freeflow-backup-"), "The backup sits beside the target")
        }
    }

    private static func testInstallerStatus() {
        withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("settings.json")
            TestSupport.expectEqual(installer(directory).status(), .notConnected)
            try? json("{}").write(to: url)
            TestSupport.expectEqual(installer(directory).status(), .notConnected)
            _ = installer(directory).connect()
            TestSupport.expectEqual(installer(directory).status(), .connected)
            try? json("{broken").write(to: url)
            TestSupport.expectEqual(installer(directory).status(), .invalid)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            TestSupport.expectEqual(installer(directory).status(), .unreadable)
            TestSupport.expectEqual(installer(directory).connect(), .ioFailure)
        }
    }

    // MARK: Health

    private static func testHealth() {
        TestSupport.expectEqual(ClaudeHookHealth.warningText, "Claude Code isn't reporting prompts")
        var health = ClaudeHookHealth()
        for index in 0..<4 {
            health.notePaste(at: start + Double(index))
        }
        TestSupport.expect(!health.isUnhealthy(now: start + 10_000), "Four unanswered pastes do not warn")
        health.notePaste(at: start + 10)
        TestSupport.expect(!health.isUnhealthy(now: start + 10 + 599), "The fifth is 599 s old")
        TestSupport.expect(health.isUnhealthy(now: start + 10 + 600), "The fifth is 600 s old")
        health.notePaste(at: start + 11_000)
        TestSupport.expect(health.isUnhealthy(now: start + 11_001), "A sixth paste keeps the warning")
        health.note(.prompt("synthetic words"))
        TestSupport.expect(!health.isUnhealthy(now: start + 20_000), "A prompt clears it")
        for index in 0..<6 {
            health.notePaste(at: start + Double(index))
        }
        TestSupport.expect(health.isUnhealthy(now: start + 1_000), "It warns again")
        // Only a valid frame shows delivery works.
        health.note(HookPrompt.frame(from: json("{not json")))
        TestSupport.expect(health.isUnhealthy(now: start + 1_000), "A malformed frame does not clear it")
        // A slash prompt is a valid frame, which clears the warning too.
        health.note(HookPrompt.frame(from: json(#"{"prompt":"/compact"}"#)))
        TestSupport.expect(!health.isUnhealthy(now: start + 1_000), "A slash prompt clears it")
    }
}
