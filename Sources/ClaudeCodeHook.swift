import Darwin
import Foundation

/// Whether the user connected Claude Code. A missing or invalid value means not connected; only
/// Connect, Disconnect and a status refresh that finds the entry removed write it.
enum ClaudeCodeHookPreference {
    static let storageKey = "claude_code_hook_connected"
    static let defaultConnected = false

    static func load(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: storageKey) as? Bool) ?? defaultConnected
    }
}

/// What the Claude Code hook sends over the socket: untrusted text that stays in memory only and
/// is never stored or logged.
enum HookPrompt {
    enum Frame: Equatable {
        /// The text the user sent, without IDE blocks and paste markers.
        case prompt(String)
        /// A valid frame with nothing to learn from: a slash command or an empty prompt.
        case skipped
        case malformed
    }

    private static let plainBlocks: [(open: [UInt8], close: [UInt8])] = [
        (Array("<ide_selection>".utf8), Array("</ide_selection>".utf8)),
        (Array("<ide_opened_file>".utf8), Array("</ide_opened_file>".utf8)),
    ]
    private static let browserOpen = Array("<browser".utf8)
    private static let browserClose = Array("</browser>".utf8)
    private static let tagEnd = UInt8(ascii: ">")
    /// What may follow `<browser` before its attributes.
    private static let attributeSeparators = Set(" \t\n\r\u{0B}\u{0C}".utf8)
    private static let pasteMarkerLines = try! NSRegularExpression(
        pattern: #"^[ \t]*</?pasted_content id="[0-9a-fA-F]+">[ \t]*$"#,
        options: [.anchorsMatchLines]
    )

    /// Reads only `prompt` and, when present, `hook_event_name`, which must be UserPromptSubmit.
    /// Every other field (paths, session ids) is dropped unread.
    static func frame(from data: Data) -> Frame {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = object["prompt"] as? String else { return .malformed }
        if let event = object["hook_event_name"], event as? String != "UserPromptSubmit" { return .malformed }
        return userText(prompt).map(Frame.prompt) ?? .skipped
    }

    /// What the user typed or dictated: whole IDE and browser blocks removed, paste-marker lines
    /// deleted with their body kept (it may be FreeFlow's own paste), whitespace runs and
    /// newlines as single spaces. Nil when nothing is left or for a slash command.
    static func userText(_ prompt: String) -> String? {
        let withoutBlocks = removingContextBlocks(from: prompt)
        let stripped = pasteMarkerLines.stringByReplacingMatches(
            in: withoutBlocks, range: NSRange(location: 0, length: (withoutBlocks as NSString).length), withTemplate: " "
        )
        let text = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty || text.hasPrefix("/") ? nil : text
    }

    /// Each whole `<ide_selection>`, `<ide_opened_file>` and `<browser …>` block, up to its first
    /// closing tag, as one space; an unclosed tag stays as text. The prompt is untrusted and the
    /// listener's `stop()` waits for this, so it is one pass over the bytes rather than a regular
    /// expression, which backtracks quadratically on repeated unclosed tags: a closing tag found
    /// missing once is never searched for again. Tags are ASCII, so cuts keep valid UTF-8.
    private static func removingContextBlocks(from prompt: String) -> String {
        let bytes = Array(prompt.utf8)
        var missing = Set<[UInt8]>()

        func end(ofClosing closing: [UInt8], from start: Int) -> Int? {
            guard !missing.contains(closing) else { return nil }
            guard let found = firstIndex(of: closing, in: bytes, from: start) else {
                missing.insert(closing)
                return nil
            }
            return found + closing.count
        }

        func endOfBlock(at start: Int) -> Int? {
            let rest = bytes[start...]
            for block in plainBlocks where rest.starts(with: block.open) {
                return end(ofClosing: block.close, from: start + block.open.count)
            }
            let next = start + browserOpen.count
            guard rest.starts(with: browserOpen), next < bytes.count, !missing.contains(browserClose) else { return nil }
            if bytes[next] == tagEnd { return end(ofClosing: browserClose, from: next + 1) }
            guard attributeSeparators.contains(bytes[next]) else { return nil }
            guard let tagClose = firstIndex(of: [tagEnd], in: bytes, from: next + 1) else {
                // No ">" at all means no closing tag either.
                missing.insert(browserClose)
                return nil
            }
            return end(ofClosing: browserClose, from: tagClose + 1)
        }

        var kept: [UInt8] = []
        kept.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "<"), let end = endOfBlock(at: index) {
                kept.append(UInt8(ascii: " "))
                index = end
            } else {
                kept.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: kept, as: UTF8.self)
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard start + pattern.count <= bytes.count else { return nil }
        for index in start...(bytes.count - pattern.count) where bytes[index] == pattern[0] {
            if bytes[index...].starts(with: pattern) { return index }
        }
        return nil
    }
}

/// The hook entry and its merge into Claude Code's settings JSON. Pure: operates on Data.
enum ClaudeCodeHookSettings {
    enum SettingsError: Error, Equatable {
        case invalidJSON
        /// The root, `hooks` or `hooks.UserPromptSubmit` has the wrong type.
        case unexpectedShape
    }

    private static let eventKey = "UserPromptSubmit"
    private static let writingOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    /// The part of the command that names this app's socket. An entry holding it in `command`
    /// or `args` is ours, whatever its form, and FreeFlow and FreeFlow Dev keep apart.
    static func socketPathMarker(appName: String) -> String {
        "/Library/Application Support/\(appName)/learn/hook.sock"
    }

    /// Exec form (`command` plus `args`, no outer shell), as the decision memo gives it.
    static let command = "/bin/sh"

    /// Runs only for the VS Code extension, sends the hook's JSON to the socket and always
    /// exits 0. A missing or stale socket makes `nc` fail at once. `appName` is this app's own
    /// bundle name.
    static func script(appName: String) -> String {
        "[ \"$CLAUDE_CODE_ENTRYPOINT\" = claude-vscode ] || exit 0; "
            + "/usr/bin/nc -U -w 2 \"$HOME\(socketPathMarker(appName: appName))\" >/dev/null 2>&1; exit 0"
    }

    /// The exact JSON the consent sheet shows and "Copy snippet" copies.
    static func snippet(appName: String) -> String {
        let escapedScript = script(appName: appName)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "hooks": {
            "UserPromptSubmit": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "\(command)",
                    "args": [
                      "-c",
                      "\(escapedScript)"
                    ],
                    "async": true,
                    "timeout": 5
                  }
                ]
              }
            ]
          }
        }
        """
    }

    private static func hookEntry(appName: String) -> [String: Any] {
        ["type": "command", "command": command, "args": ["-c", script(appName: appName)], "async": true, "timeout": 5]
    }

    private static func isOurHook(_ hook: Any, appName: String) -> Bool {
        guard let hook = hook as? [String: Any] else { return false }
        let marker = socketPathMarker(appName: appName)
        if (hook["command"] as? String)?.contains(marker) == true { return true }
        return (hook["args"] as? [Any])?.contains { ($0 as? String)?.contains(marker) == true } == true
    }

    private static func settingsRoot(of data: Data?) throws -> [String: Any] {
        guard let data, !String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) else { return [:] }
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw SettingsError.invalidJSON
        }
        guard let root = parsed as? [String: Any] else { throw SettingsError.unexpectedShape }
        return root
    }

    private static func section(in root: [String: Any]) throws -> (hooks: [String: Any], groups: [Any]) {
        guard let value = root["hooks"] else { return ([:], []) }
        guard let hooks = value as? [String: Any] else { throw SettingsError.unexpectedShape }
        guard let groupsValue = hooks[eventKey] else { return (hooks, []) }
        guard let groups = groupsValue as? [Any] else { throw SettingsError.unexpectedShape }
        return (hooks, groups)
    }

    private static func encoded(_ root: [String: Any]) throws -> Data {
        guard var data = try? JSONSerialization.data(withJSONObject: root, options: writingOptions) else {
            throw SettingsError.unexpectedShape
        }
        data.append(0x0A)
        return data
    }

    /// `data` with exactly one current entry of ours: an older variant is replaced where it
    /// sits, otherwise a new group is appended. Every other key and hook stays. Nil, empty or
    /// whitespace-only data counts as `{}`. Foundation does not keep key order or spacing.
    static func installing(into data: Data?, appName: String) throws -> (data: Data, changed: Bool) {
        var root = try settingsRoot(of: data)
        var (hooks, groups) = try section(in: root)
        let entry = hookEntry(appName: appName)
        var placed = false
        var changed = false
        var updated: [Any] = []
        for group in groups {
            guard var groupObject = group as? [String: Any], let groupHooks = groupObject["hooks"] as? [Any],
                  groupHooks.contains(where: { isOurHook($0, appName: appName) }) else {
                updated.append(group)
                continue
            }
            var kept: [Any] = []
            for hook in groupHooks {
                guard isOurHook(hook, appName: appName) else {
                    kept.append(hook)
                    continue
                }
                if placed {
                    changed = true
                } else {
                    placed = true
                    if !NSDictionary(dictionary: entry).isEqual(hook) { changed = true }
                    kept.append(entry)
                }
            }
            if kept.isEmpty { continue }
            groupObject["hooks"] = kept
            updated.append(groupObject)
        }
        if !placed {
            updated.append(["hooks": [entry]])
            changed = true
        }
        guard changed else { return (data ?? Data(), false) }
        groups = updated
        hooks[eventKey] = groups
        root["hooks"] = hooks
        return (try encoded(root), true)
    }

    /// `data` without our entries, and without a group, array or `hooks` key that removing them
    /// left empty. Everything else stays; `changed` is false when no entry of ours is there.
    static func removing(from data: Data, appName: String) throws -> (data: Data, changed: Bool) {
        var root = try settingsRoot(of: data)
        var (hooks, groups) = try section(in: root)
        var changed = false
        var updated: [Any] = []
        for group in groups {
            guard var groupObject = group as? [String: Any], let groupHooks = groupObject["hooks"] as? [Any],
                  groupHooks.contains(where: { isOurHook($0, appName: appName) }) else {
                updated.append(group)
                continue
            }
            changed = true
            let kept = groupHooks.filter { !isOurHook($0, appName: appName) }
            if kept.isEmpty { continue }
            groupObject["hooks"] = kept
            updated.append(groupObject)
        }
        guard changed else { return (data, false) }
        groups = updated
        if groups.isEmpty {
            hooks.removeValue(forKey: eventKey)
        } else {
            hooks[eventKey] = groups
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return (try encoded(root), true)
    }

    /// False for invalid JSON and a wrong shape too; the installer's status tells those apart.
    static func isInstalled(in data: Data, appName: String) -> Bool {
        (try? isInstalledChecked(in: data, appName: appName)) ?? false
    }

    fileprivate static func isInstalledChecked(in data: Data, appName: String) throws -> Bool {
        try section(in: settingsRoot(of: data)).groups.contains { group in
            guard let groupHooks = (group as? [String: Any])?["hooks"] as? [Any] else { return false }
            return groupHooks.contains { isOurHook($0, appName: appName) }
        }
    }
}

/// Connects and disconnects one settings file, given by `settingsURL`: only the app's glue names
/// the real one, so tests work in temporary directories. A write resolves a symlink first (the
/// link stays), copies the original beside the resolved file with its mode, never over an
/// existing backup, and replaces the file atomically with the same mode. Nothing is written for
/// invalid JSON or a no-op; a missing file is created with mode 0600 and needs no backup.
/// FreeFlow never deletes a backup.
struct ClaudeCodeHookInstaller {
    enum Status: Equatable {
        case connected
        case notConnected
        /// Not JSON, or the root or hooks section has the wrong type.
        case invalid
        case unreadable
    }

    enum Outcome: Equatable {
        /// The file was written; `backup` is nil when it did not exist before.
        case done(backup: URL?)
        /// Already as asked; nothing was written.
        case alreadyDone
        case invalidJSON
        case unexpectedShape
        case ioFailure
    }

    private static let newFileMode: mode_t = 0o600
    private static let backupInfix = ".freeflow-backup-"
    private static let maxBackupAttempts = 1_000

    let settingsURL: URL
    let appName: String
    var now: () -> Date = Date.init

    func status() -> Status {
        let target = resolvedSettingsURL()
        guard FileManager.default.fileExists(atPath: target.path) else { return .notConnected }
        guard let data = try? Data(contentsOf: target) else { return .unreadable }
        do {
            return try ClaudeCodeHookSettings.isInstalledChecked(in: data, appName: appName) ? .connected : .notConnected
        } catch {
            return .invalid
        }
    }

    func connect() -> Outcome {
        rewrite { try ClaudeCodeHookSettings.installing(into: $0, appName: appName) }
    }

    func disconnect() -> Outcome {
        rewrite { data in
            guard let data else { return (Data(), false) }
            return try ClaudeCodeHookSettings.removing(from: data, appName: appName)
        }
    }

    private func rewrite(_ transform: (Data?) throws -> (data: Data, changed: Bool)) -> Outcome {
        let target = resolvedSettingsURL()
        let exists = FileManager.default.fileExists(atPath: target.path)
        let current: Data?
        if exists {
            guard let data = try? Data(contentsOf: target) else { return .ioFailure }
            current = data
        } else {
            current = nil
        }
        let result: (data: Data, changed: Bool)
        do {
            result = try transform(current)
        } catch ClaudeCodeHookSettings.SettingsError.invalidJSON {
            return .invalidJSON
        } catch ClaudeCodeHookSettings.SettingsError.unexpectedShape {
            return .unexpectedShape
        } catch {
            return .ioFailure
        }
        guard result.changed else { return .alreadyDone }

        guard let current else {
            guard (try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )) != nil, replace(target, with: result.data, mode: Self.newFileMode) else { return .ioFailure }
            return .done(backup: nil)
        }
        var info = stat()
        guard stat(target.path, &info) == 0 else { return .ioFailure }
        let mode = info.st_mode & 0o7777
        guard let backup = writeBackup(current, of: target, mode: mode),
              replace(target, with: result.data, mode: mode) else { return .ioFailure }
        return .done(backup: backup)
    }

    /// Follows the file's own symlinks, so a link stays a link and its target is what changes.
    private func resolvedSettingsURL() -> URL {
        var url = settingsURL
        for _ in 0..<16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { break }
            url = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        }
        return url
    }

    private func writeBackup(_ data: Data, of target: URL, mode: mode_t) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let base = target.lastPathComponent + Self.backupInfix + formatter.string(from: now())
        for attempt in 0..<Self.maxBackupAttempts {
            let name = attempt == 0 ? base : "\(base)-\(attempt)"
            let url = target.deletingLastPathComponent().appendingPathComponent(name)
            switch Self.writeExclusive(data, to: url, mode: mode) {
            case .written: return url
            case .exists: continue
            case .failed: return nil
            }
        }
        return nil
    }

    /// Writes a sibling with the final mode from its first byte, so the old or new contents are
    /// never briefly readable by others, then renames it over the file.
    private func replace(_ target: URL, with data: Data, mode: mode_t) -> Bool {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".freeflow-tmp-\(UUID().uuidString)")
        guard case .written = Self.writeExclusive(data, to: temporary, mode: mode) else { return false }
        guard Darwin.rename(temporary.path, target.path) == 0 else {
            Darwin.unlink(temporary.path)
            return false
        }
        return true
    }

    private enum ExclusiveWrite {
        case written
        case exists
        case failed
    }

    private static func writeExclusive(_ data: Data, to url: URL, mode: mode_t) -> ExclusiveWrite {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { return errno == EEXIST ? .exists : .failed }
        defer { Darwin.close(fd) }
        // The umask may have narrowed the requested mode.
        var succeeded = fchmod(fd, mode) == 0
        if succeeded {
            succeeded = data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += written
                }
                return true
            }
        }
        if succeeded { succeeded = fsync(fd) == 0 }
        if !succeeded { Darwin.unlink(url.path) }
        return succeeded ? .written : .failed
    }
}

/// "Claude Code isn't reporting prompts": the last `missedPastes` dispatched pastes that count
/// (LearningPaste.countsForHookHealth) all went `window` seconds without any frame. Any valid frame clears it, a slash command
/// included, since the warning is about delivery. In memory only.
struct ClaudeHookHealth: Equatable {
    static let missedPastes = 5
    static let window: TimeInterval = 600
    static let warningText = "Claude Code isn't reporting prompts"
    /// Newer pastes are enough to tell, so older dates are dropped past this.
    private static let maxTrackedPastes = 4 * missedPastes

    private var pastes: [Date] = []

    mutating func notePaste(at date: Date) {
        pastes.append(date)
        if pastes.count > Self.maxTrackedPastes {
            pastes.removeFirst(pastes.count - Self.maxTrackedPastes)
        }
    }

    /// Only a valid frame shows delivery works; the listener drops malformed ones anyway.
    mutating func note(_ frame: HookPrompt.Frame) {
        guard frame != .malformed else { return }
        pastes.removeAll()
    }

    func isUnhealthy(now: Date) -> Bool {
        pastes.filter { now.timeIntervalSince($0) >= Self.window }.count >= Self.missedPastes
    }
}
