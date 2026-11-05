import CoreGraphics
import Foundation

/// What the event tap tells a composer watch: the category of a key it let through. The key's
/// code and flags stop at the classifier in the tap, so no key code or character crosses this.
enum KeyActivity: Equatable {
    case key(CommitKeyClassifier.Category)
    /// The tap stopped or was disabled, so it can no longer show that no edit key was pressed.
    case reset
}

/// Sorts a key press by what it can do to a composer. The default is `edit`, so an unknown key
/// fails closed: a non-QWERTY layout can only produce `unsettled`, never a false learn. Pure.
enum CommitKeyClassifier {
    enum Category: Equatable {
        /// Return or Enter, alone or with Command or Control: it may send.
        case commit
        /// Return or Enter with Shift or Option.
        case newline
        case edit
        case undo
        /// It moves the cursor or the focus, or copies; the text stays as it is.
        case navigation
        /// FreeFlow posted it.
        case own
    }

    private static let commitKeys: Set<UInt16> = [36, 76]
    /// Arrows, Home, End, Page Up, Page Down and Escape.
    private static let movementKeys: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121, 53]
    /// F1 to F20.
    private static let functionKeys: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]
    /// Command+A, Command+C and Command+Tab.
    private static let commandNavigationKeys: Set<UInt16> = [0, 8, 48]
    private static let zKey: UInt16 = 6

    static func category(keyCode: UInt16, flags: CGEventFlags, isOwnEvent: Bool) -> Category {
        if isOwnEvent { return .own }
        if commitKeys.contains(keyCode) {
            return flags.contains(.maskShift) || flags.contains(.maskAlternate) ? .newline : .commit
        }
        if movementKeys.contains(keyCode) || functionKeys.contains(keyCode) { return .navigation }
        if flags.contains(.maskCommand) {
            if commandNavigationKeys.contains(keyCode) { return .navigation }
            // Command+Shift+Z is redo, which changes the text like any edit.
            if keyCode == zKey, !flags.contains(.maskShift) { return .undo }
        }
        return .edit
    }
}

/// Reads the info dictionary of Chrome's value-changed notification. Pure.
enum ComposerTextChange {
    /// The text one Delete removed, which on a send is the whole sent text. Nil for anything
    /// else: Insert, Typing, Delete plus Typing, or an unexpected shape.
    static func deletedText(from userInfo: [String: Any]) -> String? {
        if let state = userInfo["AXTextStateChangeType"], state as? Int != 1 { return nil }
        guard let changes = userInfo["AXTextChangeValues"] as? [Any], changes.count == 1,
              let change = changes[0] as? [String: Any],
              change["AXTextEditType"] as? Int == 1,
              let text = change["AXTextChangeValue"] as? String, !text.isEmpty else { return nil }
        return text
    }
}

/// Composer text against what FreeFlow pasted: composers rewrite a paste as Markdown, so both
/// sides are compared without the marks they add. Pure; nothing here keeps text.
enum ComposerText {
    /// A line's leading list, heading or quote markers, each followed by a space or the line's end.
    private static let lineMarkers = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:(?:[-*+•]|#{1,6}|>+|[0-9]{1,9}[.)])(?:[ \t]+|$))+"#
    )

    /// One line of text without zero-width characters, with object-replacement characters and
    /// no-break spaces as spaces, and without each line's leading markers.
    static func normalized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF:
                continue
            case 0xFFFC, 0x00A0, 0x202F:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        let lines = String(scalars).split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let line = String(line)
            let range = NSRange(location: 0, length: line.utf16.count)
            let kept = lineMarkers.stringByReplacingMatches(in: line, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            return kept.isEmpty ? nil : kept
        }
        return lines.joined(separator: " ")
    }

    /// The composer still holds at least one of the pastes.
    static func holds(_ pastes: [String], in value: String) -> Bool {
        let composer = normalized(value)
        return pastes.contains { paste in
            SentTextMatcher.coverage(of: normalized(paste), in: composer) >= SentTextMatcher.minimumCoverage
        }
    }

    /// The span of `composer` each paste holds, so typed text around it and other dictations in
    /// the same composer are not compared with it. `pastes` are the ones SentTextMatcher
    /// credited, oldest first. Like the matcher it goes newest first, and each paste takes its
    /// span's words away from the older ones. A paste with no span of its own has no entry, and
    /// neither do the pastes older than it, since its words are then still among theirs.
    static func windows(of pastes: [(id: UUID, pasted: String)], in composer: String) -> [UUID: String] {
        var remaining = CorrectionLearner.tokens(normalized(composer))
        var windows: [UUID: String] = [:]
        for paste in pastes.reversed() {
            guard let span = span(of: paste.pasted, in: remaining) else { break }
            windows[paste.id] = remaining[span].map(\.raw).joined(separator: " ")
            remaining.removeSubrange(span)
        }
        return windows
    }

    /// Where `pasted` sits in `tokens`. The span grows at each edge by the pasted words left
    /// unmatched there, which keeps a fix at the edge inside it. Nil below the matcher's coverage
    /// or over CorrectionLearner.maxTokens. Of the two alignments, the tighter span wins, so a
    /// repeated phrase picks the copy that holds the paste as one run. Nil also when they tie
    /// over different text: either could be typed text or another dictation.
    private static func span(of pasted: String, in tokens: [CorrectionLearner.Token]) -> ClosedRange<Int>? {
        let pastedWords = CorrectionLearner.tokens(normalized(pasted)).map(\.fold)
        guard !pastedWords.isEmpty, !tokens.isEmpty,
              pastedWords.count <= CorrectionLearner.maxTokens,
              tokens.count <= CorrectionLearner.maxTokens else { return nil }
        let composerWords = tokens.map(\.fold)

        func span(_ tieBreak: CorrectionLearner.TieBreak) -> ClosedRange<Int>? {
            let matched = CorrectionLearner.script(pastedWords, composerWords, tieBreak: tieBreak)
                .compactMap { step -> (pasted: Int, composer: Int)? in
                    if case .equal(let pasted, let composer) = step { return (pasted, composer) }
                    return nil
                }
            guard let first = matched.first, let last = matched.last,
                  Double(matched.count) / Double(pastedWords.count) >= SentTextMatcher.minimumCoverage else { return nil }
            let lower = max(0, first.composer - first.pasted)
            let upper = min(composerWords.count - 1, last.composer + (pastedWords.count - 1 - last.pasted))
            return lower...upper
        }
        guard let latest = span(.latest), let earliest = span(.earliest) else { return nil }
        if earliest.count != latest.count { return earliest.count < latest.count ? earliest : latest }
        return tokens[earliest].map(\.raw) == tokens[latest].map(\.raw) ? latest : nil
    }
}

/// What one read of the pinned composer found. Only a read that still holds a paste carries text.
struct ComposerRead: Equatable {
    enum Kind: Equatable {
        case holdsPaste(String)
        /// Text that holds no paste. Deliberately without the text.
        case other
        /// Empty, or only the placeholder.
        case blank
        /// The element is gone and no acceptable replacement has focus.
        case gone
        /// The read failed, or the value is over the length cap.
        case unreadable
    }

    var kind: Kind
    /// The pinned element was replaced, and this read is from the new one.
    var replaced = false
    /// The pinned element did not have the app's focus when last checked.
    var focusAway = false
}

/// One armed composer, from the first paste into it until a confirmed send or an end. It keeps
/// the newest read that still holds a paste. The tap sees a key before the app does and Chrome's
/// Accessibility tree can lag behind that, so a read is final only with evidence that it shows
/// the last edit key: a value change reported since that key, or `quietGap` of nothing at all. A
/// send is the composer emptying or going away within `sendWindow` of a commit key with no edit
/// in between, or emptying right after a click. A Delete payload that holds a paste beats a read,
/// because it is what the app itself removed. Everything else ends without learning. Pure: no
/// clock, no Accessibility; the caller feeds it key categories, value changes and reads. Text
/// lives here only while armed, and every end drops it.
struct ComposerWatch: Equatable {
    enum EndReason: String, Equatable {
        case unsettled, abandoned, notFound, unreadable, timeout, lost, focusLost, appSwitch, ownWrite
        case pastedThenUndone, tapReset, secureInput, killSwitch, cancelled, privateWindow, editMessage, notComposer
    }

    enum Event: Equatable {
        case none
        case sent(final: String, fromPayload: Bool)
        case ended(EndReason)
    }

    /// Reads taken this soon after a paste may not show it yet.
    static let settle: TimeInterval = 0.3
    /// How long after a paste a composer may go on not showing it.
    static let findWindow: TimeInterval = 1.5
    static let changeReadDelay: TimeInterval = 0.02
    static let keyReadDelay: TimeInterval = 0.06
    static let pollInterval: TimeInterval = 0.25
    /// No composer text outlives this in memory, counted from the newest paste.
    static let ceiling: TimeInterval = 60
    static let focusGrace: TimeInterval = 1.5
    static let sendWindow: TimeInterval = 1.5
    /// Chrome updates its Accessibility tree tens of milliseconds after a key, so a read started
    /// sooner could hold half a word. The payload's half-word guard uses the same gap.
    static let finalReadGap: TimeInterval = 0.05
    /// With no value change reported since the last edit key, a read or payload counts only this
    /// long after it: the key may have changed nothing, or notifications may not be arriving.
    /// Chrome can take up to 500 ms to send its updates on a complex page.
    static let quietGap: TimeInterval = 0.5
    static let undoWindow: TimeInterval = 5
    /// Longer values are not compared.
    static let maxValueLength = 65_536

    private(set) var entryIDs: [UUID]
    let target: ContextTarget
    private(set) var isEnded = false
    private(set) var replacements = 0
    private(set) var payloads = 0

    private var newestPasteAt: Date
    /// A read that started before this is not final.
    private var readsCountFrom: Date
    private var found = false
    private var lastGood: String?
    private var lastGoodAt: Date?
    private var payload: String?
    private var payloadAt: Date?
    private var commitAt: Date?
    private var lastUserEditAt: Date?
    /// When the first value change since `lastUserEditAt` was reported.
    private var editSeenAt: Date?
    private var goneSince: Date?
    private var focusAwaySince: Date?

    /// The composer text this watch holds, for tests of what an end clears.
    var heldText: String? {
        lastGood ?? payload
    }

    init(entryID: UUID, target: ContextTarget, now: Date) {
        entryIDs = [entryID]
        self.target = target
        newestPasteAt = now
        readsCountFrom = now.addingTimeInterval(Self.settle)
    }

    /// Another dictation into the same composer. What was read before it is no longer final.
    mutating func addPaste(entryID: UUID, now: Date) {
        guard !isEnded else { return }
        entryIDs.append(entryID)
        newestPasteAt = now
        readsCountFrom = max(readsCountFrom, now.addingTimeInterval(Self.settle))
        commitAt = nil
        payload = nil
        payloadAt = nil
    }

    mutating func note(_ activity: KeyActivity, now: Date) -> Event {
        guard !isEnded else { return .none }
        switch activity {
        case .reset:
            return ending(.tapReset)
        case .key(let category):
            switch category {
            case .own, .navigation:
                break
            case .edit, .newline:
                noteEdit(at: now)
            case .undo:
                if now.timeIntervalSince(newestPasteAt) <= Self.undoWindow { return ending(.pastedThenUndone) }
                noteEdit(at: now)
            case .commit:
                if let earlier = commitAt { noteEdit(at: earlier) }
                commitAt = now
            }
            return .none
        }
    }

    /// The app reported a change of the composer's value, stamped in the same order as the keys:
    /// the first one after an edit key shows the edit has reached the Accessibility tree.
    mutating func noteValueChanged(at time: Date) {
        guard !isEnded, editSeenAt == nil, let edit = lastUserEditAt, time >= edit else { return }
        editSeenAt = time
    }

    /// A Delete payload from the app. Only one that holds a paste can be what was sent.
    mutating func note(deleted text: String, holdsPaste: Bool, now: Date) {
        guard !isEnded else { return }
        payloads += 1
        guard holdsPaste else { return }
        payload = text
        payloadAt = now
    }

    /// A FreeFlow write other than the paste this watch expects ends it: the composer now holds
    /// text the user did not write, and a span FreeFlow wrote itself teaches nothing.
    mutating func noteFreeFlowWrite(isTrackedPaste: Bool) -> Event {
        guard !isEnded, !isTrackedPaste else { return .none }
        return ending(.ownWrite)
    }

    mutating func end() {
        isEnded = true
        lastGood = nil
        lastGoodAt = nil
        payload = nil
        payloadAt = nil
        commitAt = nil
    }

    /// `startedAt` is when the read began, `now` when it reached the watch. `mouseDownAt` is the
    /// last left mouse down, which proves a click send only if it came between the newest paste
    /// and this read.
    mutating func observe(_ read: ComposerRead, startedAt: Date, mouseDownAt: Date?, now: Date) -> Event {
        guard !isEnded else { return .none }
        if read.replaced { replacements += 1 }
        if now.timeIntervalSince(newestPasteAt) > Self.ceiling { return ending(.timeout) }
        // A Return that emptied nothing was a newline or a menu pick.
        if let commit = commitAt, now.timeIntervalSince(commit) > Self.sendWindow { noteEdit(at: commit) }
        guard startedAt >= newestPasteAt.addingTimeInterval(Self.settle) else { return .none }
        if read.focusAway {
            let since = focusAwaySince ?? startedAt
            focusAwaySince = since
            if now.timeIntervalSince(since) > Self.focusGrace { return ending(.focusLost) }
        } else {
            focusAwaySince = nil
        }
        if read.kind != .gone { goneSince = nil }

        let isPastFindWindow = now.timeIntervalSince(newestPasteAt) >= Self.findWindow
        switch read.kind {
        case .holdsPaste(let text):
            found = true
            if lastGoodAt.map({ startedAt >= $0 }) ?? true {
                lastGood = text
                lastGoodAt = startedAt
            }
            if let at = payloadAt, at < startedAt {
                payload = nil
                payloadAt = nil
            }
            return .none
        case .blank:
            return cleared(replaced: read.replaced, startedAt: startedAt, mouseDownAt: mouseDownAt, now: now)
        case .other:
            // The Claude Code panel can show a free-text suggestion once it is empty.
            if target == .claudeCodePanel {
                return cleared(replaced: read.replaced, startedAt: startedAt, mouseDownAt: mouseDownAt, now: now)
            }
            if read.replaced || (!found && isPastFindWindow) { return ending(.notFound) }
            // The composer no longer holds a paste, so an earlier read cannot be what it sends.
            lastGood = nil
            lastGoodAt = nil
            return .none
        case .gone:
            if let commit = commitAt, startedAt >= commit {
                return found ? confirmed(anchor: commit) : ending(.notFound)
            }
            let since = goneSince ?? startedAt
            goneSince = since
            return now.timeIntervalSince(since) > Self.focusGrace ? ending(.lost) : .none
        case .unreadable:
            return !found && isPastFindWindow ? ending(.unreadable) : .none
        }
    }

    /// The composer no longer holds the paste. A paste never seen was turned into an attachment
    /// or has not landed. A re-mount with no commit is most likely another conversation, and so
    /// is not a send even after a click.
    private mutating func cleared(replaced: Bool, startedAt: Date, mouseDownAt: Date?, now: Date) -> Event {
        guard found else {
            return now.timeIntervalSince(newestPasteAt) >= Self.findWindow ? ending(.notFound) : .none
        }
        if let commit = commitAt, startedAt >= commit { return confirmed(anchor: commit) }
        if replaced { return ending(.notFound) }
        // A recent edit key could be what emptied it, unless a final read shows it did not.
        if let edit = lastUserEditAt, now.timeIntervalSince(edit) <= Self.sendWindow, finalRead == nil {
            return ending(.abandoned)
        }
        if let mouse = mouseDownAt, mouse >= newestPasteAt, mouse <= startedAt,
           now.timeIntervalSince(mouse) <= Self.sendWindow {
            return confirmed(anchor: mouse)
        }
        return ending(.abandoned)
    }

    /// A send happened at `anchor`. The payload needs the last edit key to have shown by then,
    /// since a Delete can miss the last keystrokes of a batch; otherwise the last read must be
    /// final.
    private mutating func confirmed(anchor: Date) -> Event {
        let event: Event
        if let payload, let payloadAt, payloadAt >= anchor, showsLastEdit(at: anchor) {
            event = .sent(final: payload, fromPayload: true)
        } else if let finalRead {
            event = .sent(final: finalRead, fromPayload: false)
        } else {
            event = .ended(.unsettled)
        }
        end()
        return event
    }

    /// The newest read that still holds a paste, if it can be trusted as the composer's text.
    private var finalRead: String? {
        guard let lastGood, let lastGoodAt, lastGoodAt >= readsCountFrom, showsLastEdit(at: lastGoodAt) else { return nil }
        return lastGood
    }

    /// Whether what the app reported by `time` can include the last edit key. A change reported
    /// after a send began is the send's own, so it counts only up to `time`.
    private func showsLastEdit(at time: Date) -> Bool {
        guard let edit = lastUserEditAt else { return true }
        let gap = time.timeIntervalSince(edit)
        if let seen = editSeenAt, seen <= time, gap >= Self.finalReadGap { return true }
        return gap >= Self.quietGap
    }

    /// `time` can be a Return's own, older than the value change that Return caused.
    private mutating func noteEdit(at time: Date) {
        commitAt = nil
        payload = nil
        payloadAt = nil
        lastUserEditAt = time
        if let seen = editSeenAt, seen < time { editSeenAt = nil }
        readsCountFrom = max(readsCountFrom, time.addingTimeInterval(Self.finalReadGap))
    }

    private mutating func ending(_ reason: EndReason) -> Event {
        end()
        return .ended(reason)
    }
}

/// What the gate reads about a focused element. Labels only, never its value.
struct ComposerField: Equatable {
    var role: String?
    var subrole: String?
    var description: String?
    var title: String?
    var placeholder: String?
}

/// Who may be watched. An allowlist, checked before any value is read. Pure.
enum ComposerWatchGate {
    private static let textAreaRole = "AXTextArea"
    private static let secureSubrole = "AXSecureTextField"
    private static let editMessageLabel = "edit message"

    /// A dictation FreeFlow sent itself shows no edit. The VS Code panel is only the fallback for
    /// a hook that is not reporting.
    static func mayArm(target: ContextTarget?, pressedEnter: Bool, hookIsReporting: Bool) -> Bool {
        guard !pressedEnter else { return false }
        switch target {
        case .chatGPTWeb, .chatGPTApp:
            return true
        case .claudeCodePanel:
            return !hookIsReporting
        case .googleSearch, nil:
            return false
        }
    }

    /// The app `target` lives in. Every other app gets no observation at all, so this comes
    /// before anything of the app is read.
    static func isTargetApp(_ target: ContextTarget, bundleIdentifier: String?) -> Bool {
        switch target {
        case .chatGPTWeb: ContextTarget.isChrome(bundleIdentifier: bundleIdentifier)
        case .chatGPTApp: ContextTarget.isChatGPTApp(bundleIdentifier: bundleIdentifier)
        case .claudeCodePanel: ContextTarget.isVSCode(bundleIdentifier: bundleIdentifier)
        case .googleSearch: false
        }
    }

    /// Why this field may not be watched, going by its role and labels alone, or nil.
    static func fieldRefusal(_ field: ComposerField) -> ComposerWatch.EndReason? {
        guard field.subrole != secureSubrole, field.role == textAreaRole else { return .notComposer }
        let labels = [field.description, field.title, field.placeholder]
        let isEditor = labels.contains { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == editMessageLabel }
        return isEditor ? .editMessage : nil
    }

    /// Whether this field is `target`'s composer. `websiteDomain` is only known for a page in
    /// Chrome.
    static func classifies(_ field: ComposerField, as target: ContextTarget, bundleIdentifier: String?, websiteDomain: String?) -> Bool {
        ContextTarget.classify(
            bundleIdentifier: bundleIdentifier,
            websiteDomain: websiteDomain,
            focusedRole: field.role,
            focusedLabel: field.description ?? field.title,
            insideWebArea: true
        ) == target
    }

    /// Whether a watch's pastes outlive its end. While the hook listens, the prompt it reports
    /// can still match a panel paste the watch gave up on, so the ring's lifetime and `claim`
    /// handle those. The kill switch, Delete all and Undo AI edit still forget them.
    static func keepsPastes(target: ContextTarget, hookIsListening: Bool, after reason: ComposerWatch.EndReason) -> Bool {
        guard target == .claudeCodePanel, hookIsListening else { return false }
        return reason != .killSwitch && reason != .cancelled
    }

    static func source(for target: ContextTarget) -> LearningSource {
        switch target {
        case .claudeCodePanel: .claudeCode
        case .chatGPTWeb, .chatGPTApp: .chatGPT
        case .googleSearch: .googleSearch
        }
    }
}

enum ComposerValueRead: Equatable {
    case text(String)
    /// The element no longer exists (kAXErrorInvalidUIElement).
    case invalidElement
    case failed
}

/// A read that got no answer, such as a timeout, which says nothing about the value.
struct ComposerReadFailure: Error {}

/// The reads a composer watch needs, which tests fake. There are no writes to fake. The throwing
/// ones return nil when the app answered that there is no such value.
protocol ComposerAccessibility {
    associatedtype Element

    func focusedElement(pid: pid_t) -> Element?
    /// Nil when the element's role or a label could not be read: a label that timed out could
    /// be the one that refuses the element.
    func field(of element: Element) -> ComposerField?
    func value(of element: Element) -> ComposerValueRead
    func window(of element: Element) throws -> Element?
    func windowTitle(_ window: Element) throws -> String?
    func webDomain(of element: Element) throws -> String?
    func isSame(_ first: Element, _ second: Element) -> Bool
}

/// Pins the composer a paste landed in and reads it. Every element passes the gate before its
/// value is read, on arming and on re-resolving a replaced element. Not thread-safe: the session
/// uses it from one queue.
final class ComposerReader<AX: ComposerAccessibility> {
    enum Arming: Equatable {
        case armed
        /// No focused element yet, or a read failed; try again.
        case unavailable
        case refused(ComposerWatch.EndReason)
    }

    private struct Pin {
        let element: AX.Element
        let window: AX.Element?
        let placeholder: String?
    }

    private enum Resolution {
        case pin(Pin)
        case unavailable
        case refused(ComposerWatch.EndReason)
    }

    private let ax: AX
    private let pid: pid_t
    private let bundleIdentifier: String?
    private let target: ContextTarget
    private var pastes: [String]
    private var pin: Pin?
    /// The last focus check, reused by reads that do not check.
    private var focusAway = false

    var pinned: AX.Element? {
        pin?.element
    }

    init(ax: AX, pid: pid_t, bundleIdentifier: String?, target: ContextTarget, pasted: String) {
        self.ax = ax
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.target = target
        pastes = [pasted]
    }

    func add(pasted: String) {
        pastes.append(pasted)
    }

    func holdsPaste(_ text: String) -> Bool {
        ComposerText.holds(pastes, in: text)
    }

    func arm() -> Arming {
        switch resolveFocused() {
        case .pin(let resolved):
            pin = resolved
            return .armed
        case .unavailable:
            return .unavailable
        case .refused(let reason):
            return .refused(reason)
        }
    }

    func read(checkingFocus: Bool) -> ComposerRead {
        guard let current = pin else { return ComposerRead(kind: .gone) }
        var read: ComposerRead
        switch ax.value(of: current.element) {
        case .text(let value):
            read = ComposerRead(kind: kind(of: value, placeholder: current.placeholder))
        case .failed:
            read = ComposerRead(kind: .unreadable)
        case .invalidElement:
            read = readReplacement(of: current)
        }
        // A dead pin never has the focus: the watch times a gone element on its own, as lost.
        guard read.kind != .gone else { return read }
        if checkingFocus { focusAway = !hasFocus() }
        read.focusAway = focusAway
        return read
    }

    /// The cheapest refusal first, and nothing past a refusal is read: an app that is not the
    /// target's gets no read at all, and a window title is read only for the target's own field.
    /// A read that failed refuses nothing, so arming tries again; when that runs out the watch
    /// ends unreadable, without learning.
    private func resolveFocused() -> Resolution {
        guard ComposerWatchGate.isTargetApp(target, bundleIdentifier: bundleIdentifier) else { return .refused(.notComposer) }
        guard let focused = ax.focusedElement(pid: pid), let field = ax.field(of: focused) else { return .unavailable }
        if let reason = ComposerWatchGate.fieldRefusal(field) { return .refused(reason) }
        do {
            let isPage = target == .chatGPTWeb
            let domain = isPage ? try ax.webDomain(of: focused) : nil
            guard ComposerWatchGate.classifies(field, as: target, bundleIdentifier: bundleIdentifier, websiteDomain: domain) else {
                return .refused(.notComposer)
            }
            let window = try ax.window(of: focused)
            let title = isPage ? try window.flatMap(ax.windowTitle) : nil
            if ContextTermSources.isPrivateWindow(target: target, windowTitle: title) { return .refused(.privateWindow) }
            return .pin(Pin(element: focused, window: window, placeholder: field.placeholder))
        } catch {
            return .unavailable
        }
    }

    /// The composer re-mounted: the focused element takes over if it passes the same gate in the
    /// same window. Anything else is gone, and a refused element's value is never read.
    private func readReplacement(of current: Pin) -> ComposerRead {
        guard let window = current.window,
              case .pin(let replacement) = resolveFocused(),
              let replacementWindow = replacement.window,
              ax.isSame(replacementWindow, window) else { return ComposerRead(kind: .gone) }
        pin = replacement
        switch ax.value(of: replacement.element) {
        case .text(let value):
            return ComposerRead(kind: kind(of: value, placeholder: replacement.placeholder), replaced: true)
        case .failed:
            return ComposerRead(kind: .unreadable, replaced: true)
        case .invalidElement:
            return ComposerRead(kind: .gone, replaced: true)
        }
    }

    /// A value that is the placeholder is an empty composer, even when a paste would match it, so
    /// placeholder text can never be learned.
    private func kind(of value: String, placeholder: String?) -> ComposerRead.Kind {
        guard value.utf16.count <= ComposerWatch.maxValueLength else { return .unreadable }
        if TextContextCore.isPlaceholderValue(value, placeholder: placeholder, composer: target)
            || ComposerText.normalized(value).isEmpty {
            return .blank
        }
        return ComposerText.holds(pastes, in: value) ? .holdsPaste(value) : .other
    }

    private func hasFocus() -> Bool {
        guard let pinned, let focused = ax.focusedElement(pid: pid) else { return false }
        return ax.isSame(focused, pinned)
    }
}
