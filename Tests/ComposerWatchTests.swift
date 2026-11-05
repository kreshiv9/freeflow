import CoreGraphics
import Foundation

/// The composer watch: its key classifier, payload parser, span locator, arming gate, reader and
/// state machine, with an injected clock and a fake Accessibility protocol. Invented text,
/// titles and domains only; no Accessibility call is made and no app is touched.
enum ComposerWatchTests {
    private typealias Watch = ComposerWatch
    private typealias Read = ComposerRead
    private typealias Reader = ComposerReader<FakeAX>

    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let entry = UUID()
    private static let pasted = "ask cloud to refactor the parser"
    private static let fixed = "ask Claude to refactor the parser"
    private static let chrome = "com.google.Chrome"
    private static let chatGPTApp = "com.openai.codex"
    private static let vsCode = "com.microsoft.VSCode"
    private static let composerField = ComposerField(role: "AXTextArea")
    private static let panelField = ComposerField(role: "AXTextArea", description: "Message input")
    private static let chatGPTTitle = "ChatGPT - Google Chrome"

    static func run() {
        testClassifierTriples()
        testSettledSend()
        testUnsettledSend()
        testPayloadSend()
        testAbandoned()
        testClickSend()
        testElementReplaced()
        testFreeFlowWrite()
        testCeiling()
        testEditMessageIsNeverArmed()
        testEndClearsEverything()
        testLifecycle()
        testSeveralDictations()
        testPayloadParser()
        testNormalization()
        testSpanLocator()
        testFallbackPlaceholderGuard()
        testReaderLimits()
        testMayArm()
        testPastesAfterAnEnd()
        testLiveAccessibilityNeverWrites()
        testAppStateWiring()
    }

    // MARK: Fixtures

    private final class FakeAX: ComposerAccessibility {
        enum Call: Equatable {
            case focus, field, window, title, domain
        }

        var focused: Int?
        var fields: [Int: ComposerField] = [:]
        var values: [Int: ComposerValueRead] = [:]
        var windows: [Int: Int] = [:]
        var titles: [Int: String] = [:]
        var domains: [Int: String] = [:]
        /// These reads fail, as a timeout does, instead of answering.
        var failing: [Call] = []
        private(set) var valueReads: [Int] = []
        /// Every read but the value's, in order.
        private(set) var calls: [Call] = []

        func focusedElement(pid: pid_t) -> Int? {
            calls.append(.focus)
            return focused
        }

        func field(of element: Int) -> ComposerField? {
            calls.append(.field)
            return fields[element]
        }

        func window(of element: Int) throws -> Int? {
            try answer(.window)
            return windows[element]
        }

        func windowTitle(_ window: Int) throws -> String? {
            try answer(.title)
            return titles[window]
        }

        func webDomain(of element: Int) throws -> String? {
            try answer(.domain)
            return domains[element]
        }

        func isSame(_ first: Int, _ second: Int) -> Bool { first == second }

        private func answer(_ call: Call) throws {
            calls.append(call)
            if failing.contains(call) { throw ComposerReadFailure() }
        }

        func value(of element: Int) -> ComposerValueRead {
            valueReads.append(element)
            return values[element] ?? .failed
        }

        /// A focused element in a window, as a composer of chatgpt.com by default.
        func place(
            _ element: Int,
            field: ComposerField = composerField,
            window: Int = 100,
            title: String? = chatGPTTitle,
            domain: String? = "chatgpt.com",
            value: ComposerValueRead = .text(pasted)
        ) {
            focused = element
            fields[element] = field
            windows[element] = window
            titles[window] = title
            domains[element] = domain
            values[element] = value
        }
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private static func watch(target: ContextTarget = .chatGPTWeb) -> Watch {
        Watch(entryID: entry, target: target, now: start)
    }

    private static func holds(_ text: String = pasted) -> Read {
        Read(kind: .holdsPaste(text))
    }

    private static let blank = Read(kind: .blank)
    private static let other = Read(kind: .other)

    /// A read delivered at `seconds`, started then too unless `startedAt` says otherwise.
    private static func observe(
        _ watch: inout Watch,
        _ read: Read,
        _ seconds: TimeInterval,
        startedAt: TimeInterval? = nil,
        mouse: TimeInterval? = nil
    ) -> Watch.Event {
        watch.observe(read, startedAt: at(startedAt ?? seconds), mouseDownAt: mouse.map(at), now: at(seconds))
    }

    private static func press(
        _ watch: inout Watch,
        _ keyCode: UInt16,
        _ flags: CGEventFlags = [],
        own: Bool = false,
        at seconds: TimeInterval
    ) -> Watch.Event {
        watch.note(.key(CommitKeyClassifier.category(keyCode: keyCode, flags: flags, isOwnEvent: own)), now: Self.at(seconds))
    }

    private static func edit(_ watch: inout Watch, _ seconds: TimeInterval) {
        TestSupport.expectEqual(press(&watch, 51, at: seconds), .none)
    }

    private static func commit(_ watch: inout Watch, _ seconds: TimeInterval) {
        TestSupport.expectEqual(press(&watch, 36, at: seconds), .none)
    }

    private static func changed(_ watch: inout Watch, _ seconds: TimeInterval) {
        watch.noteValueChanged(at: at(seconds))
    }

    private static func window(of paste: String, in composer: String) -> String? {
        let id = UUID()
        return ComposerText.windows(of: [(id: id, pasted: paste)], in: composer)[id]
    }

    private static func reader(_ ax: FakeAX, bundle: String? = chrome, target: ContextTarget = .chatGPTWeb, pasted: String = pasted) -> Reader {
        Reader(ax: ax, pid: 42, bundleIdentifier: bundle, target: target, pasted: pasted)
    }

    // MARK: CommitKeyClassifier triples

    private static func testClassifierTriples() {
        typealias Category = CommitKeyClassifier.Category
        let triples: [(UInt16, CGEventFlags, Bool, Category)] = [
            (36, [], false, .commit),
            (76, [], false, .commit),
            (36, .maskCommand, false, .commit),
            (36, .maskControl, false, .commit),
            (36, .maskShift, false, .newline),
            (36, .maskAlternate, false, .newline),
            (76, .maskShift, false, .newline),
            (36, [], true, .own),
            (9, .maskCommand, true, .own),
            (51, [], false, .edit),
            (117, [], false, .edit),
            (0, [], false, .edit),
            (49, [], false, .edit),
            (0, .maskShift, false, .edit),
            (9, .maskCommand, false, .edit),
            (7, .maskCommand, false, .edit),
            (40, .maskControl, false, .edit),
            (48, [], false, .edit),
            (6, .maskCommand, false, .undo),
            (6, [.maskCommand, .maskShift], false, .edit),
            (0, .maskCommand, false, .navigation),
            (8, .maskCommand, false, .navigation),
            (48, .maskCommand, false, .navigation),
            (123, [], false, .navigation),
            (124, .maskShift, false, .navigation),
            (125, [], false, .navigation),
            (126, .maskAlternate, false, .navigation),
            (115, [], false, .navigation),
            (119, [], false, .navigation),
            (116, [], false, .navigation),
            (121, [], false, .navigation),
            (53, [], false, .navigation),
            (122, [], false, .navigation),
            (96, .maskCommand, false, .navigation),
            // An unknown key fails closed.
            (250, [], false, .edit),
        ]
        for (keyCode, flags, own, expected) in triples {
            TestSupport.expectEqual(CommitKeyClassifier.category(keyCode: keyCode, flags: flags, isOwnEvent: own), expected)
        }
    }

    // MARK: W1, W2

    private static func testSettledSend() {
        var settled = watch()
        TestSupport.expectEqual(observe(&settled, holds(), 0.5), .none)
        edit(&settled, 1.0)
        changed(&settled, 1.03)
        TestSupport.expectEqual(observe(&settled, holds(fixed), 1.1), .none)
        commit(&settled, 2.0)
        changed(&settled, 2.01)
        TestSupport.expectEqual(observe(&settled, blank, 2.02), .sent(final: fixed, fromPayload: false))
        TestSupport.expect(settled.isEnded, "A send ends the watch")
        TestSupport.expect(settled.heldText == nil, "A send drops the text")

        // No value change at all, as when notifications do not arrive: a read this long after
        // the last key still counts.
        var polled = watch()
        _ = observe(&polled, holds(), 0.5)
        edit(&polled, 1.0)
        _ = observe(&polled, holds(fixed), 1.6)
        commit(&polled, 2.0)
        TestSupport.expectEqual(observe(&polled, blank, 2.02), .sent(final: fixed, fromPayload: false))
    }

    private static func testUnsettledSend() {
        // W2: an edit key after the last read.
        var late = watch()
        TestSupport.expectEqual(observe(&late, holds(), 1.0), .none)
        edit(&late, 1.5)
        commit(&late, 1.6)
        TestSupport.expectEqual(observe(&late, blank, 1.62), .ended(.unsettled))

        // W2b: a read started 30 ms after the edit key could hold half a word.
        var soon = watch()
        _ = observe(&soon, holds(), 1.0)
        edit(&soon, 1.5)
        TestSupport.expectEqual(observe(&soon, holds(fixed), 1.53), .none)
        commit(&soon, 1.6)
        TestSupport.expectEqual(observe(&soon, blank, 1.62), .ended(.unsettled))

        // W2c: a read started before the edit key and delivered after it.
        var crossed = watch()
        _ = observe(&crossed, holds(), 1.0)
        edit(&crossed, 1.5)
        TestSupport.expectEqual(observe(&crossed, holds(fixed), 1.52, startedAt: 1.49), .none)
        commit(&crossed, 1.6)
        TestSupport.expectEqual(observe(&crossed, blank, 1.62), .ended(.unsettled))

        // W2d: a stale read just before a fast Return. It started past the gap and holds the
        // paste, but Chrome had not shown the last letter yet. The clear's own change is no
        // evidence for it.
        let halfWord = "ask Claude to refactor the pars"
        var stale = watch()
        _ = observe(&stale, holds(), 1.0)
        edit(&stale, 1.5)
        TestSupport.expectEqual(observe(&stale, holds(halfWord), 1.56), .none)
        commit(&stale, 1.62)
        changed(&stale, 1.65)
        TestSupport.expectEqual(observe(&stale, blank, 1.7), .ended(.unsettled))

        // W2e: the same rhythm, with the edit reported before the read: learned, fast.
        var shown = watch()
        _ = observe(&shown, holds(), 1.0)
        edit(&shown, 1.5)
        changed(&shown, 1.53)
        TestSupport.expectEqual(observe(&shown, holds(fixed), 1.56), .none)
        commit(&shown, 1.62)
        changed(&shown, 1.65)
        TestSupport.expectEqual(observe(&shown, blank, 1.7), .sent(final: fixed, fromPayload: false))

        // W2f: the change came after the read began, so the read cannot show it.
        var readFirst = watch()
        _ = observe(&readFirst, holds(), 1.0)
        edit(&readFirst, 1.5)
        TestSupport.expectEqual(observe(&readFirst, holds(halfWord), 1.59, startedAt: 1.56), .none)
        changed(&readFirst, 1.58)
        commit(&readFirst, 1.62)
        TestSupport.expectEqual(observe(&readFirst, blank, 1.7), .ended(.unsettled))

        // W2g: a change from before the last key says nothing about it, in either arrival order.
        var earlierKey = watch()
        _ = observe(&earlierKey, holds(), 1.0)
        edit(&earlierKey, 1.4)
        changed(&earlierKey, 1.43)
        edit(&earlierKey, 1.5)
        _ = observe(&earlierKey, holds(halfWord), 1.56)
        commit(&earlierKey, 1.62)
        TestSupport.expectEqual(observe(&earlierKey, blank, 1.7), .ended(.unsettled))
        var deliveredLate = watch()
        _ = observe(&deliveredLate, holds(), 1.0)
        edit(&deliveredLate, 1.5)
        changed(&deliveredLate, 1.49)
        _ = observe(&deliveredLate, holds(halfWord), 1.56)
        commit(&deliveredLate, 1.62)
        TestSupport.expectEqual(observe(&deliveredLate, blank, 1.7), .ended(.unsettled))

        // W2h: no change reported, and not quiet for long enough.
        var tooSoon = watch()
        _ = observe(&tooSoon, holds(), 1.0)
        edit(&tooSoon, 1.5)
        _ = observe(&tooSoon, holds(fixed), 1.9)
        commit(&tooSoon, 2.0)
        TestSupport.expectEqual(observe(&tooSoon, blank, 2.02), .ended(.unsettled))
    }

    // MARK: W3

    private static func testPayloadSend() {
        // W3: the same keys as W2, with the clear's Delete payload.
        var exact = watch()
        _ = observe(&exact, holds(), 1.0)
        edit(&exact, 1.5)
        changed(&exact, 1.53)
        commit(&exact, 1.6)
        exact.note(deleted: fixed, holdsPaste: true, now: at(1.61))
        TestSupport.expectEqual(exact.payloads, 1)
        TestSupport.expectEqual(observe(&exact, blank, 1.62), .sent(final: fixed, fromPayload: true))

        // A payload with a final read too wins: it is what the app removed.
        var both = watch()
        _ = observe(&both, holds(fixed), 1.0)
        commit(&both, 1.6)
        both.note(deleted: "\(fixed) today", holdsPaste: true, now: at(1.61))
        TestSupport.expectEqual(observe(&both, blank, 1.62), .sent(final: "\(fixed) today", fromPayload: true))

        // W3b: a payload that does not hold the paste.
        var foreign = watch()
        _ = observe(&foreign, holds(), 1.0)
        edit(&foreign, 1.5)
        commit(&foreign, 1.6)
        foreign.note(deleted: "x", holdsPaste: false, now: at(1.61))
        TestSupport.expectEqual(foreign.payloads, 1)
        TestSupport.expectEqual(observe(&foreign, blank, 1.62), .ended(.unsettled))

        // W3c: an edit key 30 ms before the commit: the Delete may miss the last keystroke.
        var halfWord = watch()
        _ = observe(&halfWord, holds(), 1.0)
        edit(&halfWord, 1.57)
        changed(&halfWord, 1.58)
        commit(&halfWord, 1.6)
        halfWord.note(deleted: fixed, holdsPaste: true, now: at(1.61))
        TestSupport.expectEqual(observe(&halfWord, blank, 1.62), .ended(.unsettled))

        // W3d: a payload older than the commit is not what the commit removed.
        var old = watch()
        _ = observe(&old, holds(), 1.0)
        edit(&old, 1.5)
        changed(&old, 1.53)
        old.note(deleted: fixed, holdsPaste: true, now: at(1.55))
        commit(&old, 1.6)
        TestSupport.expectEqual(observe(&old, blank, 1.62), .ended(.unsettled))

        // W3e: Chrome had not shown the last key by the commit, so the Delete can miss it. The
        // gap is long enough; it is the evidence that is missing, and the clear's own change is
        // none.
        var lagging = watch()
        _ = observe(&lagging, holds(), 1.0)
        edit(&lagging, 1.5)
        commit(&lagging, 1.62)
        changed(&lagging, 1.65)
        lagging.note(deleted: "ask Claude to refactor the pars", holdsPaste: true, now: at(1.65))
        TestSupport.expectEqual(observe(&lagging, blank, 1.7), .ended(.unsettled))

        // W3f: quiet long enough before the commit, a payload needs no reported change.
        var quiet = watch()
        _ = observe(&quiet, holds(), 1.0)
        edit(&quiet, 1.5)
        commit(&quiet, 2.1)
        quiet.note(deleted: fixed, holdsPaste: true, now: at(2.11))
        TestSupport.expectEqual(observe(&quiet, blank, 2.12), .sent(final: fixed, fromPayload: true))

        // A newer read that still holds the paste shows the Delete was not the send.
        var undone = watch()
        _ = observe(&undone, holds(), 0.5)
        undone.note(deleted: fixed, holdsPaste: true, now: at(0.6))
        _ = observe(&undone, holds(), 0.7)
        commit(&undone, 2.0)
        TestSupport.expectEqual(observe(&undone, blank, 2.02), .sent(final: pasted, fromPayload: false))
    }

    // MARK: W4, W5

    private static func testAbandoned() {
        var cleared = watch()
        _ = observe(&cleared, holds(), 0.5)
        TestSupport.expectEqual(press(&cleared, 0, .maskCommand, at: 0.9), .none)
        edit(&cleared, 1.0)
        cleared.note(deleted: pasted, holdsPaste: true, now: at(1.01))
        TestSupport.expectEqual(observe(&cleared, blank, 1.02), .ended(.abandoned))
        TestSupport.expect(cleared.heldText == nil, "An abandon drops the text")
    }

    private static func testClickSend() {
        var click = watch()
        _ = observe(&click, holds(), 0.5)
        TestSupport.expectEqual(observe(&click, blank, 2.1, mouse: 2.0), .sent(final: pasted, fromPayload: false))

        // The payload of a click send, at or after the click.
        var payload = watch()
        _ = observe(&payload, holds(), 0.5)
        payload.note(deleted: fixed, holdsPaste: true, now: at(2.05))
        TestSupport.expectEqual(observe(&payload, blank, 2.1, mouse: 2.0), .sent(final: fixed, fromPayload: true))

        // W5b: no key and no mouse.
        var neither = watch()
        _ = observe(&neither, holds(), 0.5)
        TestSupport.expectEqual(observe(&neither, blank, 2.1), .ended(.abandoned))

        // W5c: an edit key just before the click.
        var edited = watch()
        _ = observe(&edited, holds(), 0.5)
        edit(&edited, 1.9)
        TestSupport.expectEqual(observe(&edited, blank, 2.1, mouse: 2.0), .ended(.abandoned))

        // W5d: a keyboard fix a final read showed cannot be what emptied the composer, so the
        // click sends the fixed text. Without the click it is still no send.
        var fixedThenClicked = watch()
        _ = observe(&fixedThenClicked, holds(), 0.5)
        edit(&fixedThenClicked, 1.0)
        changed(&fixedThenClicked, 1.03)
        _ = observe(&fixedThenClicked, holds(fixed), 1.06)
        TestSupport.expectEqual(observe(&fixedThenClicked, blank, 2.1, mouse: 2.0), .sent(final: fixed, fromPayload: false))
        var fixedNoClick = watch()
        _ = observe(&fixedNoClick, holds(), 0.5)
        edit(&fixedNoClick, 1.0)
        changed(&fixedNoClick, 1.03)
        _ = observe(&fixedNoClick, holds(fixed), 1.06)
        TestSupport.expectEqual(observe(&fixedNoClick, blank, 2.1), .ended(.abandoned))

        // W5e: the read after the edit is not final, so that edit could have emptied it.
        var notFinal = watch()
        _ = observe(&notFinal, holds(), 0.5)
        edit(&notFinal, 1.0)
        _ = observe(&notFinal, holds(fixed), 1.06)
        TestSupport.expectEqual(observe(&notFinal, blank, 2.1, mouse: 2.0), .ended(.abandoned))

        // A click too long ago, one before the paste, or one after the read began proves nothing.
        var stale = watch()
        _ = observe(&stale, holds(), 0.5)
        TestSupport.expectEqual(observe(&stale, blank, 4.0, mouse: 2.0), .ended(.abandoned))
        var beforePaste = watch()
        _ = observe(&beforePaste, holds(), 0.5)
        TestSupport.expectEqual(observe(&beforePaste, blank, 1.0, mouse: -0.2), .ended(.abandoned))
        var afterRead = watch()
        _ = observe(&afterRead, holds(), 0.5)
        TestSupport.expectEqual(observe(&afterRead, blank, 2.1, startedAt: 2.0, mouse: 2.05), .ended(.abandoned))
    }

    // MARK: W6

    private static func testElementReplaced() {
        // W6: re-resolved in the same window, the paste is found again.
        let ax = FakeAX()
        ax.place(1)
        let replaced = reader(ax)
        TestSupport.expectEqual(replaced.arm(), .armed)
        TestSupport.expectEqual(replaced.pinned, 1)
        TestSupport.expectEqual(ax.valueReads, [])
        ax.values[1] = .invalidElement
        ax.place(2)
        let read = replaced.read(checkingFocus: true)
        TestSupport.expectEqual(read, Read(kind: .holdsPaste(pasted), replaced: true))
        TestSupport.expectEqual(replaced.pinned, 2)
        var running = watch()
        _ = observe(&running, read, 0.5)
        TestSupport.expectEqual(running.replacements, 1)
        TestSupport.expect(!running.isEnded, "The watch continues")
        commit(&running, 1.0)
        TestSupport.expectEqual(observe(&running, blank, 1.02), .sent(final: pasted, fromPayload: false))

        // W6b: another window takes focus, and its element's value is never read.
        let otherWindow = FakeAX()
        otherWindow.place(1)
        let lost = reader(otherWindow)
        _ = lost.arm()
        otherWindow.values[1] = .invalidElement
        otherWindow.place(2, window: 200)
        TestSupport.expectEqual(lost.read(checkingFocus: false).kind, .gone)
        TestSupport.expect(!otherWindow.valueReads.contains(2), "Other window's value is not read")
        TestSupport.expectEqual(lost.pinned, 1)

        // W6c: the replacement is blank with no commit: likely another conversation.
        let blanked = FakeAX()
        blanked.place(1)
        let emptied = reader(blanked)
        _ = emptied.arm()
        blanked.values[1] = .invalidElement
        blanked.place(2, value: .text(""))
        let blankRead = emptied.read(checkingFocus: false)
        TestSupport.expectEqual(blankRead, Read(kind: .blank, replaced: true))
        var noCommit = watch()
        _ = observe(&noCommit, holds(), 0.5)
        TestSupport.expectEqual(observe(&noCommit, blankRead, 1.0), .ended(.notFound))
        var withClick = watch()
        _ = observe(&withClick, holds(), 0.5)
        TestSupport.expectEqual(observe(&withClick, blankRead, 1.0, mouse: 0.9), .ended(.notFound))

        // W6c2: the replacement holds other text: a re-mount with no recoverable text.
        var replacedOther = watch()
        _ = observe(&replacedOther, holds(), 0.5)
        TestSupport.expectEqual(observe(&replacedOther, Read(kind: .other, replaced: true), 1.0), .ended(.notFound))

        // W6d: blank after a commit is the send.
        var afterCommit = watch()
        _ = observe(&afterCommit, holds(), 0.5)
        commit(&afterCommit, 0.9)
        TestSupport.expectEqual(observe(&afterCommit, blankRead, 1.0), .sent(final: pasted, fromPayload: false))

        // W6e: the replacement sits on another domain, so it is not read.
        let otherDomain = FakeAX()
        otherDomain.place(1)
        let tabSwitch = reader(otherDomain)
        _ = tabSwitch.arm()
        otherDomain.values[1] = .invalidElement
        otherDomain.place(2, domain: "mail.example.com")
        TestSupport.expectEqual(tabSwitch.read(checkingFocus: false).kind, .gone)
        TestSupport.expect(!otherDomain.valueReads.contains(2), "Another domain's value is not read")

        // W6f: gone with a commit is the send; without one it is lost after the grace.
        var goneSent = watch()
        _ = observe(&goneSent, holds(), 0.5)
        commit(&goneSent, 1.0)
        TestSupport.expectEqual(observe(&goneSent, Read(kind: .gone), 1.02), .sent(final: pasted, fromPayload: false))
        var goneLost = watch()
        _ = observe(&goneLost, holds(), 0.5)
        TestSupport.expectEqual(observe(&goneLost, Read(kind: .gone), 1.0), .none)
        TestSupport.expectEqual(observe(&goneLost, Read(kind: .gone), 2.0), .none)
        TestSupport.expectEqual(observe(&goneLost, Read(kind: .gone), 2.6), .ended(.lost))
        var goneBack = watch()
        _ = observe(&goneBack, holds(), 0.5)
        TestSupport.expectEqual(observe(&goneBack, Read(kind: .gone), 1.0), .none)
        TestSupport.expectEqual(observe(&goneBack, Read(kind: .holdsPaste(pasted), replaced: true), 2.0), .none)
        TestSupport.expectEqual(observe(&goneBack, Read(kind: .gone), 3.0), .none)
        TestSupport.expect(!goneBack.isEnded, "Back within the grace, the clock restarts")

        // W6g: what the reader really produces when the pinned element dies and another one has
        // the focus, polled with its focus check. It ends as lost, not as focus lost.
        let destroyed = FakeAX()
        destroyed.place(1)
        let dead = reader(destroyed)
        _ = dead.arm()
        destroyed.values[1] = .invalidElement
        destroyed.place(2, window: 200)
        var deadWatch = watch()
        _ = observe(&deadWatch, holds(), 0.5)
        let goneRead = dead.read(checkingFocus: true)
        TestSupport.expectEqual(goneRead, Read(kind: .gone))
        TestSupport.expectEqual(observe(&deadWatch, goneRead, 1.0), .none)
        TestSupport.expectEqual(observe(&deadWatch, dead.read(checkingFocus: true), 2.0), .none)
        TestSupport.expectEqual(observe(&deadWatch, dead.read(checkingFocus: true), 2.6), .ended(.lost))

        // The paste was never seen, so a send at the commit cannot be credited.
        var goneUnseen = watch()
        commit(&goneUnseen, 0.4)
        TestSupport.expectEqual(observe(&goneUnseen, Read(kind: .gone), 0.5), .ended(.notFound))
    }

    // MARK: W7, W8

    private static func testFreeFlowWrite() {
        var own = watch()
        _ = observe(&own, holds(), 0.5)
        TestSupport.expectEqual(own.noteFreeFlowWrite(isTrackedPaste: false), .ended(.ownWrite))
        TestSupport.expect(own.heldText == nil, "The text goes with it")
        TestSupport.expectEqual(observe(&own, holds(), 1.0), .none)
        TestSupport.expect(own.heldText == nil, "Later reads keep nothing")

        var tracked = watch()
        _ = observe(&tracked, holds(), 0.5)
        TestSupport.expectEqual(tracked.noteFreeFlowWrite(isTrackedPaste: true), .none)
        TestSupport.expect(!tracked.isEnded, "The expected paste leaves the watch running")
        TestSupport.expectEqual(tracked.heldText, pasted)
    }

    private static func testCeiling() {
        var alone = watch()
        _ = observe(&alone, holds(), 0.5)
        TestSupport.expectEqual(observe(&alone, holds(), 60.5), .ended(.timeout))
        TestSupport.expect(alone.heldText == nil, "No text outlives the ceiling")

        var extended = watch()
        _ = observe(&extended, holds(), 0.5)
        extended.addPaste(entryID: UUID(), now: at(40))
        TestSupport.expectEqual(observe(&extended, holds(), 90), .none)
        TestSupport.expectEqual(observe(&extended, holds(), 101), .ended(.timeout))
    }

    // MARK: W9

    private static func testEditMessageIsNeverArmed() {
        func refusal(
            _ field: ComposerField,
            target: ContextTarget = .chatGPTWeb,
            bundle: String = chrome,
            title: String? = chatGPTTitle,
            domain: String? = "chatgpt.com"
        ) -> Reader.Arming {
            let ax = FakeAX()
            ax.place(1, field: field, title: title, domain: domain)
            let arming = reader(ax, bundle: bundle, target: target).arm()
            TestSupport.expectEqual(ax.valueReads, [])
            return arming
        }
        for label in ["Edit message", "edit MESSAGE", "  Edit message\n"] {
            TestSupport.expectEqual(refusal(ComposerField(role: "AXTextArea", description: label)), .refused(.editMessage))
            TestSupport.expectEqual(refusal(ComposerField(role: "AXTextArea", title: label)), .refused(.editMessage))
            TestSupport.expectEqual(refusal(ComposerField(role: "AXTextArea", placeholder: label)), .refused(.editMessage))
            TestSupport.expectEqual(
                refusal(ComposerField(role: "AXTextArea", description: label), target: .chatGPTApp, bundle: chatGPTApp, title: "ChatGPT", domain: nil),
                .refused(.editMessage)
            )
        }
        // Text that only mentions it is still a composer.
        TestSupport.expectEqual(refusal(ComposerField(role: "AXTextArea", description: "Edit message here")), .armed)

        TestSupport.expectEqual(refusal(ComposerField(role: "AXTextArea", subrole: "AXSecureTextField")), .refused(.notComposer))
        TestSupport.expectEqual(refusal(ComposerField(role: "AXTextField")), .refused(.notComposer))
        // The Chrome address bar has no domain.
        TestSupport.expectEqual(refusal(composerField, domain: nil), .refused(.notComposer))
        TestSupport.expectEqual(refusal(composerField, domain: "mail.example.com"), .refused(.notComposer))
        TestSupport.expectEqual(refusal(composerField, title: "ChatGPT - Google Chrome (Incognito)"), .refused(.privateWindow))
        TestSupport.expectEqual(refusal(composerField, title: "ChatGPT - Google Chrome (Guest)"), .refused(.privateWindow))
        TestSupport.expectEqual(refusal(composerField, title: "No browser suffix here"), .refused(.privateWindow))
        TestSupport.expectEqual(refusal(composerField, title: nil), .refused(.privateWindow))
        // A VS Code editor is not the Claude Code box, and another app is not on the list.
        TestSupport.expectEqual(
            refusal(ComposerField(role: "AXTextArea", description: "Synthetic editor"), target: .claudeCodePanel, bundle: vsCode, title: nil, domain: nil),
            .refused(.notComposer)
        )
        TestSupport.expectEqual(refusal(panelField, target: .claudeCodePanel, bundle: vsCode, title: nil, domain: nil), .armed)
        TestSupport.expectEqual(refusal(composerField, target: .chatGPTApp, bundle: chatGPTApp, title: nil, domain: nil), .armed)
        TestSupport.expectEqual(refusal(composerField, target: .chatGPTApp, bundle: "com.openai.chat", title: nil, domain: nil), .refused(.notComposer))
        TestSupport.expectEqual(refusal(composerField, bundle: "com.apple.Safari"), .refused(.notComposer))

        // Nothing focused yet, or no role yet: try again rather than refuse.
        let empty = FakeAX()
        TestSupport.expectEqual(reader(empty).arm(), .unavailable)
        empty.focused = 1
        TestSupport.expectEqual(reader(empty).arm(), .unavailable)

        // An app that is not the target's gets no read at all, not even of its labels.
        let otherApps: [(String?, ContextTarget)] = [
            ("com.example.mail", .chatGPTWeb),
            ("com.example.mail", .chatGPTApp),
            ("com.example.mail", .claudeCodePanel),
            (nil, .chatGPTWeb),
            (chatGPTApp, .chatGPTWeb),
            (chrome, .chatGPTApp),
            (vsCode, .chatGPTWeb),
            (chrome, .claudeCodePanel),
            ("com.openai.chat", .chatGPTApp),
        ]
        for (bundle, target) in otherApps {
            let ax = FakeAX()
            ax.place(1, field: panelField)
            TestSupport.expectEqual(reader(ax, bundle: bundle, target: target).arm(), .refused(.notComposer))
            TestSupport.expectEqual(ax.calls, [])
            TestSupport.expectEqual(ax.valueReads, [])
            TestSupport.expect(!ComposerWatchGate.isTargetApp(target, bundleIdentifier: bundle), "Not the target's app")
        }
        TestSupport.expect(ComposerWatchGate.isTargetApp(.chatGPTWeb, bundleIdentifier: chrome), "Chrome")
        TestSupport.expect(ComposerWatchGate.isTargetApp(.chatGPTApp, bundleIdentifier: chatGPTApp), "The ChatGPT app")
        TestSupport.expect(ComposerWatchGate.isTargetApp(.claudeCodePanel, bundleIdentifier: vsCode), "VS Code")
        TestSupport.expect(!ComposerWatchGate.isTargetApp(.googleSearch, bundleIdentifier: chrome), "Google has its own watch")

        // Inside the app, each refusal stops the reads after it: the title of another tab or of
        // a field that is no composer is never read, and only a page needs one at all.
        func calls(
            _ field: ComposerField,
            target: ContextTarget = .chatGPTWeb,
            bundle: String = chrome,
            domain: String? = "chatgpt.com"
        ) -> [FakeAX.Call] {
            let ax = FakeAX()
            ax.place(1, field: field, domain: domain)
            _ = reader(ax, bundle: bundle, target: target).arm()
            return ax.calls
        }
        TestSupport.expectEqual(calls(ComposerField(role: "AXTextField")), [.focus, .field])
        TestSupport.expectEqual(calls(ComposerField(role: "AXTextArea", description: "Edit message")), [.focus, .field])
        TestSupport.expectEqual(calls(composerField, domain: "mail.example.com"), [.focus, .field, .domain])
        TestSupport.expectEqual(calls(composerField), [.focus, .field, .domain, .window, .title])
        TestSupport.expectEqual(calls(composerField, target: .chatGPTApp, bundle: chatGPTApp), [.focus, .field, .window])
        TestSupport.expectEqual(calls(panelField, target: .claudeCodePanel, bundle: vsCode), [.focus, .field, .window])
        TestSupport.expectEqual(calls(composerField, target: .claudeCodePanel, bundle: vsCode), [.focus, .field])

        // A read that failed refuses nothing, however it fails, and arming works once it answers.
        for failure in [FakeAX.Call.domain, .window, .title] {
            let stalled = FakeAX()
            stalled.place(1)
            stalled.failing = [failure]
            let retrying = reader(stalled)
            TestSupport.expectEqual(retrying.arm(), .unavailable)
            TestSupport.expect(retrying.pinned == nil, "Nothing is pinned yet")
            TestSupport.expectEqual(stalled.valueReads, [])
            stalled.failing = []
            TestSupport.expectEqual(retrying.arm(), .armed)
        }
        // Once answered, a private window is still refused.
        let answered = FakeAX()
        answered.place(1, title: "ChatGPT - Google Chrome (Incognito)")
        answered.failing = [.title]
        let privateWindow = reader(answered)
        TestSupport.expectEqual(privateWindow.arm(), .unavailable)
        answered.failing = []
        TestSupport.expectEqual(privateWindow.arm(), .refused(.privateWindow))
        // A replacement whose reads fail is no replacement yet, and its value is not read.
        let failingReplacement = FakeAX()
        failingReplacement.place(1)
        let replacing = reader(failingReplacement)
        _ = replacing.arm()
        failingReplacement.values[1] = .invalidElement
        failingReplacement.place(2)
        failingReplacement.failing = [.title]
        TestSupport.expectEqual(replacing.read(checkingFocus: false).kind, .gone)
        TestSupport.expect(!failingReplacement.valueReads.contains(2), "A failing replacement's value is not read")

        // A replacement that is the Edit message editor is gone, and is not read.
        let ax = FakeAX()
        ax.place(1)
        let replaced = reader(ax)
        _ = replaced.arm()
        ax.values[1] = .invalidElement
        ax.place(2, field: ComposerField(role: "AXTextArea", description: "Edit message"))
        TestSupport.expectEqual(replaced.read(checkingFocus: false).kind, .gone)
        TestSupport.expect(!ax.valueReads.contains(2), "The editor's value is not read")
    }

    // MARK: W12

    /// The socket's closure stays covered by ClaudeHookListenerTests.testStopClosesEverything, and
    /// the kill switch's call to end() by testAppStateWiring, since AppState cannot run in a test.
    private static func testEndClearsEverything() {
        var ended = watch()
        _ = observe(&ended, holds(), 0.5)
        ended.note(deleted: fixed, holdsPaste: true, now: at(0.6))
        TestSupport.expect(ended.heldText != nil, "Text is held while armed")
        ended.end()
        TestSupport.expect(ended.heldText == nil, "End clears the text")
        TestSupport.expect(ended.isEnded, "End ends")
        TestSupport.expectEqual(observe(&ended, holds(), 0.7), .none)
        TestSupport.expectEqual(press(&ended, 36, at: 0.8), .none)
        ended.note(deleted: fixed, holdsPaste: true, now: at(0.9))
        TestSupport.expectEqual(ended.noteFreeFlowWrite(isTrackedPaste: false), .none)
        TestSupport.expectEqual(ended.payloads, 1)
        TestSupport.expect(ended.heldText == nil, "Nothing is kept after the end")
    }

    // MARK: Lifecycle

    private static func testLifecycle() {
        // A Return that never clears was a newline or a menu pick, so it counts as an edit.
        var menuPick = watch()
        _ = observe(&menuPick, holds(), 0.5)
        commit(&menuPick, 1.0)
        TestSupport.expectEqual(observe(&menuPick, holds(), 1.2), .none)
        TestSupport.expectEqual(observe(&menuPick, holds(), 2.6), .none)
        TestSupport.expectEqual(observe(&menuPick, holds(fixed), 2.7), .none)
        commit(&menuPick, 3.0)
        TestSupport.expectEqual(observe(&menuPick, blank, 3.02), .sent(final: fixed, fromPayload: false))

        // A Return with no read since is an edit once it is old.
        var slowClear = watch()
        _ = observe(&slowClear, holds(), 0.5)
        commit(&slowClear, 1.0)
        TestSupport.expectEqual(observe(&slowClear, blank, 2.6), .ended(.abandoned))

        // Two quick Returns: the first counts as an edit at its own time.
        var twice = watch()
        _ = observe(&twice, holds(), 0.5)
        commit(&twice, 1.0)
        commit(&twice, 1.1)
        TestSupport.expectEqual(observe(&twice, blank, 1.12), .ended(.unsettled))

        // A read older than the commit shows nothing about it.
        var older = watch()
        _ = observe(&older, holds(), 0.5)
        commit(&older, 1.0)
        TestSupport.expectEqual(observe(&older, blank, 1.02, startedAt: 0.99), .ended(.abandoned))

        // Shift+Return is an edit.
        var newline = watch()
        _ = observe(&newline, holds(), 0.5)
        TestSupport.expectEqual(press(&newline, 36, .maskShift, at: 1.0), .none)
        commit(&newline, 1.02)
        TestSupport.expectEqual(observe(&newline, blank, 1.04), .ended(.unsettled))

        // Navigation and FreeFlow's own keys leave the read final.
        var moved = watch()
        _ = observe(&moved, holds(), 0.5)
        TestSupport.expectEqual(press(&moved, 123, at: 0.9), .none)
        TestSupport.expectEqual(press(&moved, 9, .maskCommand, own: true, at: 0.95), .none)
        commit(&moved, 1.0)
        TestSupport.expectEqual(observe(&moved, blank, 1.02), .sent(final: pasted, fromPayload: false))

        // Reads before the settle are ignored, whatever they show.
        var early = watch()
        TestSupport.expectEqual(observe(&early, blank, 0.1), .none)
        TestSupport.expectEqual(observe(&early, Read(kind: .gone), 0.2), .none)
        TestSupport.expect(early.heldText == nil, "A read before the settle keeps nothing")
        TestSupport.expectEqual(observe(&early, holds(), 0.2), .none)
        TestSupport.expect(early.heldText == nil, "Even one holding the paste")
        TestSupport.expectEqual(observe(&early, holds(), 0.4), .none)
        TestSupport.expectEqual(early.heldText, pasted)

        // Blank through the find window: an attachment. Other: a re-mount with no text.
        var attachment = watch()
        TestSupport.expectEqual(observe(&attachment, blank, 0.5), .none)
        TestSupport.expectEqual(observe(&attachment, blank, 1.4), .none)
        TestSupport.expectEqual(observe(&attachment, blank, 1.6), .ended(.notFound))
        var elsewhere = watch()
        TestSupport.expectEqual(observe(&elsewhere, other, 0.5), .none)
        TestSupport.expectEqual(observe(&elsewhere, other, 1.6), .ended(.notFound))
        var failing = watch()
        TestSupport.expectEqual(observe(&failing, Read(kind: .unreadable), 0.5), .none)
        TestSupport.expectEqual(observe(&failing, Read(kind: .unreadable), 1.6), .ended(.unreadable))

        // A paste seen once outlives a failing read.
        var seen = watch()
        _ = observe(&seen, holds(), 0.5)
        TestSupport.expectEqual(observe(&seen, Read(kind: .unreadable), 2.0), .none)
        commit(&seen, 2.1)
        TestSupport.expectEqual(observe(&seen, blank, 2.12), .sent(final: pasted, fromPayload: false))

        // A send before the paste was ever found.
        var unseen = watch()
        commit(&unseen, 0.2)
        TestSupport.expectEqual(observe(&unseen, blank, 0.5), .none)
        TestSupport.expectEqual(observe(&unseen, blank, 1.6), .ended(.notFound))

        // Text that holds no paste voids an earlier read: it cannot be what is then sent.
        var replacedText = watch()
        _ = observe(&replacedText, holds(), 0.5)
        TestSupport.expectEqual(observe(&replacedText, other, 1.0), .none)
        commit(&replacedText, 1.1)
        TestSupport.expectEqual(observe(&replacedText, blank, 1.12), .ended(.unsettled))

        // Focus away within the grace, and a click send still learns.
        var focusBack = watch()
        _ = observe(&focusBack, holds(), 0.5)
        var away = holds()
        away.focusAway = true
        TestSupport.expectEqual(observe(&focusBack, away, 1.0), .none)
        var awayBlank = blank
        awayBlank.focusAway = true
        TestSupport.expectEqual(observe(&focusBack, awayBlank, 1.2, mouse: 1.1), .sent(final: pasted, fromPayload: false))
        // Past the grace.
        var focusLost = watch()
        _ = observe(&focusLost, holds(), 0.5)
        TestSupport.expectEqual(observe(&focusLost, away, 1.0), .none)
        TestSupport.expectEqual(observe(&focusLost, away, 2.0), .none)
        TestSupport.expectEqual(observe(&focusLost, away, 2.6), .ended(.focusLost))
        // Back in time, the clock restarts.
        var returned = watch()
        _ = observe(&returned, away, 1.0)
        _ = observe(&returned, holds(), 2.0)
        TestSupport.expectEqual(observe(&returned, away, 2.5), .none)
        TestSupport.expectEqual(observe(&returned, away, 3.9), .none)

        // A blind tap cannot show that no edit key was pressed.
        var blind = watch()
        _ = observe(&blind, holds(), 0.5)
        TestSupport.expectEqual(blind.note(.reset, now: at(1.0)), .ended(.tapReset))
        TestSupport.expect(blind.heldText == nil, "The reset drops the text")

        // Pasted then undone within five seconds; later it is an edit.
        var undone = watch()
        _ = observe(&undone, holds(), 0.5)
        TestSupport.expectEqual(press(&undone, 6, .maskCommand, at: 4.9), .ended(.pastedThenUndone))
        var late = watch()
        _ = observe(&late, holds(), 0.5)
        TestSupport.expectEqual(press(&late, 6, .maskCommand, at: 5.5), .none)
        commit(&late, 5.52)
        TestSupport.expectEqual(observe(&late, blank, 5.54), .ended(.unsettled))

        // A second paste moves the point where reads count.
        var second = watch()
        _ = observe(&second, holds(), 0.5)
        second.addPaste(entryID: UUID(), now: at(1.0))
        TestSupport.expectEqual(observe(&second, holds(), 1.1), .none)
        commit(&second, 1.2)
        TestSupport.expectEqual(observe(&second, blank, 1.25), .none)
        TestSupport.expectEqual(observe(&second, blank, 1.35), .ended(.unsettled))

        // A second paste drops a commit and a payload from before it: the clear they point to
        // cannot be what emptied a composer that has just been pasted into.
        var overtaken = watch()
        _ = observe(&overtaken, holds(), 0.5)
        commit(&overtaken, 1.0)
        overtaken.note(deleted: fixed, holdsPaste: true, now: at(1.01))
        overtaken.addPaste(entryID: UUID(), now: at(1.02))
        TestSupport.expectEqual(observe(&overtaken, blank, 1.4), .ended(.abandoned))
        var payloadOnly = watch()
        payloadOnly.note(deleted: fixed, holdsPaste: true, now: at(0.4))
        TestSupport.expectEqual(payloadOnly.heldText, fixed)
        payloadOnly.addPaste(entryID: UUID(), now: at(0.5))
        TestSupport.expect(payloadOnly.heldText == nil, "The payload goes with the second paste")
    }

    // MARK: Several dictations

    private static func testSeveralDictations() {
        let first = UUID(), second = UUID()
        let refactor = "ask cloud to refactor the parser", deploy = "deploy it to versel tonight"
        let final = "\(fixed)\nand then deploy it to Vercel tonight"

        var both = Watch(entryID: first, target: .chatGPTWeb, now: start)
        both.addPaste(entryID: second, now: at(1))
        TestSupport.expectEqual(both.entryIDs, [first, second])
        _ = observe(&both, holds(final), 1.5)
        commit(&both, 2)
        TestSupport.expectEqual(observe(&both, blank, 2.02), .sent(final: final, fromPayload: false))

        let pastes = [(id: first, pasted: refactor), (id: second, pasted: deploy)]
        let match = SentTextMatcher.matches(
            ComposerText.normalized(final),
            in: pastes.map { (id: $0.id, pasted: ComposerText.normalized($0.pasted)) }
        )
        TestSupport.expectEqual(match.credited, [first, second])
        let spans = ComposerText.windows(of: pastes, in: final)
        TestSupport.expectEqual(spans[first], fixed)
        TestSupport.expectEqual(spans[second], "deploy it to Vercel tonight")

        // Two takes of one sentence, the first one fixed. Each compares with its own words: the
        // older paste must not see the newer one's span, or alis -> Alyssa would be learned.
        let alis = UUID(), alyssa = UUID()
        let sentBoth = "ask Alice about it ask Alyssa about it"
        let takesInOne = [(id: alis, pasted: "ask alis about it"), (id: alyssa, pasted: "ask Alyssa about it")]
        TestSupport.expectEqual(SentTextMatcher.matches(sentBoth, in: takesInOne).credited, [alis, alyssa])
        let takeSpans = ComposerText.windows(of: takesInOne, in: sentBoth)
        TestSupport.expectEqual(takeSpans[alis], "ask Alice about it")
        TestSupport.expectEqual(takeSpans[alyssa], "ask Alyssa about it")

        // A paste with no span of its own leaves its words among the older pastes', so those get
        // none either. Here the newer paste fits both copies of its phrase.
        let older = UUID(), newer = UUID()
        let unclear = ComposerText.windows(
            of: [(id: older, pasted: "run the tests now please"), (id: newer, pasted: "call the apy")],
            in: "run the tests now please call the API and call the app"
        )
        TestSupport.expectEqual(unclear, [:])
        // The newer paste is still located when only the older one fails.
        let partial = ComposerText.windows(
            of: [(id: older, pasted: "call the apy"), (id: newer, pasted: "run the tests now please")],
            in: "run the tests now please call the API and call the app"
        )
        TestSupport.expectEqual(partial, [newer: "run the tests now please"])

        func record(_ id: UUID, _ pasted: String, at seconds: TimeInterval) -> DictationRecord {
            DictationRecord(
                id: id, createdAt: Self.at(seconds), words: [], keyterms: [],
                paste: LearningPaste(pasted: pasted, raw: pasted, destination: .chrome, category: .coding, pressedEnter: false, countsForHookHealth: false)
            )
        }
        var ring = DictationRecordRing()
        ring.append(record(first, refactor, at: 0), now: at(0))
        ring.append(record(second, deploy, at: 1), now: at(1))
        TestSupport.expectEqual(ring.claim(match, now: at(3)).map(\.id), [first, second])

        // One deleted and dictated again: the newer take gets the credit, the older counts as
        // superseded, and an observed paste is not offered again.
        let retake = "ask Claude to refactor the parser"
        let takes = [(id: first, pasted: refactor), (id: second, pasted: retake)]
        let taken = SentTextMatcher.matches(retake, in: takes)
        TestSupport.expectEqual(taken, SentTextMatcher.Match(credited: [second], superseded: [first]))
        var retakes = DictationRecordRing()
        retakes.append(record(first, refactor, at: 0), now: at(0))
        retakes.append(record(second, retake, at: 1), now: at(1))
        TestSupport.expectEqual(retakes.pastes(ids: [first, second], now: at(2)).map(\.id), [first, second])
        TestSupport.expectEqual(retakes.claim(taken, now: at(2)).map(\.id), [second])
        TestSupport.expectEqual(retakes.pastes(ids: [first, second], now: at(3)).map(\.id), [])
    }

    // MARK: Payload parser

    private static func testPayloadParser() {
        func parse(_ info: [String: Any]) -> String? {
            ComposerTextChange.deletedText(from: info)
        }
        func change(_ type: Any = 1, _ value: Any? = "sent text") -> [String: Any] {
            var entry: [String: Any] = ["AXTextEditType": type]
            if let value { entry["AXTextChangeValue"] = value }
            return entry
        }
        func info(_ changes: Any, state: Any? = 1) -> [String: Any] {
            var info: [String: Any] = ["AXTextChangeValues": changes]
            if let state { info["AXTextStateChangeType"] = state }
            return info
        }
        TestSupport.expectEqual(parse(info([change()])), "sent text")
        TestSupport.expectEqual(parse(info([change(NSNumber(value: 1))], state: NSNumber(value: 1))), "sent text")
        TestSupport.expect(parse(info([change()], state: 2)) == nil, "A selection change")
        TestSupport.expectEqual(parse(info([change()], state: nil)), "sent text")
        TestSupport.expect(parse(info([change(2)])) == nil, "Insert")
        TestSupport.expect(parse(info([change(3)])) == nil, "Typing")
        TestSupport.expect(parse(info([change(1), change(3, "x")])) == nil, "Delete plus Typing")
        TestSupport.expect(parse(info([] as [Any])) == nil, "Empty array")
        TestSupport.expect(parse(info("not an array")) == nil, "Not an array")
        TestSupport.expect(parse(info(["not a dictionary"])) == nil, "Not a dictionary")
        TestSupport.expect(parse(info([change(1, nil)])) == nil, "No value")
        TestSupport.expect(parse(info([change(1, 7)])) == nil, "A value that is no string")
        TestSupport.expect(parse(info([change(1, "")])) == nil, "An empty string")
        TestSupport.expect(parse(info([change("1")])) == nil, "A type that is no number")
        TestSupport.expect(parse([:]) == nil, "Nothing at all")
    }

    // MARK: Span locator

    private static func testNormalization() {
        let normalized = ComposerText.normalized
        TestSupport.expectEqual(normalized("a\u{200B}b\u{200C}c\u{200D}d\u{2060}e\u{FEFF}f"), "abcdef")
        TestSupport.expectEqual(normalized("a\u{00A0}b\u{202F}c\u{FFFC}d"), "a b c d")
        TestSupport.expectEqual(normalized("- one\n* two\n+ three\n• four"), "one two three four")
        TestSupport.expectEqual(normalized("# one\n## two\n> three\n>> four"), "one two three four")
        TestSupport.expectEqual(normalized("1. one\n2) two\n  10. three"), "one two three")
        TestSupport.expectEqual(normalized("- > nested"), "nested")
        TestSupport.expectEqual(normalized("  \n\n \u{FFFC} \n"), "")
        // Only markers followed by a space count.
        TestSupport.expectEqual(normalized("**bold** words"), "**bold** words")
        TestSupport.expectEqual(normalized("1.5 million"), "1.5 million")
        TestSupport.expectEqual(normalized("#tag -flag"), "#tag -flag")
        TestSupport.expectEqual(normalized("one - two"), "one - two")
    }

    private static func testSpanLocator() {
        func window(_ composer: String, of paste: String = pasted) -> String? {
            ComposerWatchTests.window(of: paste, in: composer)
        }
        // Variants a composer can show. Holds is true for each.
        let variants: [(String, String)] = [
            ("ask Claude\u{00A0}to refactor the parser", fixed),
            ("ask Claude\nto refactor the parser", fixed),
            ("- ask **Claude** to `refactor` the parser", "ask **Claude** to refactor the parser"),
            ("1. ask Claude to refactor the parser", fixed),
            ("1) ask Claude to refactor the parser", fixed),
            ("# ask Claude to refactor the parser", fixed),
            ("> ask Claude to refactor the parser", fixed),
            ("ask Cla\u{200B}ude to refactor the parser", fixed),
            ("\u{FFFC} ask Claude to refactor the parser", fixed),
            ("before anything ask Claude to refactor the parser and then rest", fixed),
        ]
        for (composer, expected) in variants {
            TestSupport.expectEqual(window(composer), expected)
            TestSupport.expect(ComposerText.holds([pasted], in: composer), "The composer holds the paste")
        }
        // The same variants with other words hold nothing.
        for composer in [
            "- what is the weather like in a synthetic town",
            "1. what is the weather like\nin a synthetic town",
            "# something else\u{00A0}entirely",
        ] {
            TestSupport.expect(window(composer) == nil, "Below the coverage")
            TestSupport.expect(!ComposerText.holds([pasted], in: composer), "The composer holds no paste")
        }
        TestSupport.expect(!ComposerText.holds([], in: pasted), "No pastes")

        // A fix at either edge stays inside the span; typed text does not.
        TestSupport.expectEqual(
            window("hey Claude can refactor the parser thanks", of: "cloud can refactor the parser"),
            "Claude can refactor the parser"
        )
        TestSupport.expectEqual(
            window("please refactor the parser with Qwen today", of: "refactor the parser with kwen"),
            "refactor the parser with Qwen"
        )
        // At the very start and end, the growth stops at the composer's edge.
        TestSupport.expectEqual(
            window("refactor the parser with Qwen", of: "kwen refactor the parser with kwen"),
            "refactor the parser with Qwen"
        )

        // Two pastes get their own spans.
        let composer = "ask Claude to refactor the parser and deploy it to Vercel tonight"
        TestSupport.expectEqual(window(composer), fixed)
        TestSupport.expectEqual(window(composer, of: "deploy it to versel tonight"), "deploy it to Vercel tonight")

        // A repeated phrase: the copy that holds the paste as one run, at either end.
        TestSupport.expectEqual(window("run this and then run the tests", of: "run the tests"), "run the tests")
        TestSupport.expectEqual(window("run the tests and then run", of: "run the tests"), "run the tests")

        // Two equally long spans: either could be typed text, so neither is compared. A word
        // from the typed copy must not be learned, as apy -> app would be.
        TestSupport.expect(window("call the API and call the app", of: "call the apy") == nil, "Two spans tie")
        TestSupport.expect(window("ask Alice about it ask Alyssa about it", of: "ask alis about it") == nil, "Two spans tie")
        // Copies that read the same teach the same, so that is no tie.
        TestSupport.expectEqual(window("run the tests then run the tests", of: "run the tests"), "run the tests")

        // Too little of the paste, or too much text.
        TestSupport.expect(window("ask nothing here", of: "ask cloud to refactor the parser") == nil, "Below 0.6")
        TestSupport.expect(window("") == nil, "An empty composer")
        TestSupport.expect(window(pasted, of: "") == nil, "An empty paste")
        let tooLong = Array(repeating: "word", count: CorrectionLearner.maxTokens + 1).joined(separator: " ")
        TestSupport.expect(window(tooLong, of: "word word") == nil, "A composer over the limit")
        TestSupport.expect(window("word word", of: tooLong) == nil, "A paste over the limit")
    }

    // MARK: Fallback

    private static func testFallbackPlaceholderGuard() {
        func panelReader(value: String, field: ComposerField = panelField, pasted: String = pasted) -> Reader {
            let ax = FakeAX()
            ax.place(1, field: field, title: nil, domain: nil, value: .text(value))
            let reader = reader(ax, bundle: vsCode, target: .claudeCodePanel, pasted: pasted)
            TestSupport.expectEqual(reader.arm(), .armed)
            return reader
        }
        for placeholder in ["Ask Claude to edit…", "Queue another message…", "⌘ Esc to focus or unfocus Claude", "  ask claude to edit...  "] {
            TestSupport.expectEqual(panelReader(value: placeholder).read(checkingFocus: false).kind, .blank)
        }
        TestSupport.expectEqual(
            panelReader(
                value: "Synthetic placeholder",
                field: ComposerField(role: "AXTextArea", description: "Message input", placeholder: "Synthetic placeholder")
            ).read(checkingFocus: false).kind,
            .blank
        )

        // A paste that reads like the placeholder is never found, so it is never learned.
        let lookalike = panelReader(value: "Ask Claude to edit…", pasted: "ask claude to edit")
        TestSupport.expectEqual(lookalike.read(checkingFocus: false).kind, .blank)
        var neverFound = watch(target: .claudeCodePanel)
        TestSupport.expectEqual(observe(&neverFound, blank, 0.5), .none)
        TestSupport.expectEqual(observe(&neverFound, blank, 1.6), .ended(.notFound))

        // Sent: the box shows its placeholder, or a free-text suggestion.
        var placeholderShown = watch(target: .claudeCodePanel)
        _ = observe(&placeholderShown, holds(), 0.5)
        commit(&placeholderShown, 1.0)
        let sentWithBlank = observe(&placeholderShown, panelReader(value: "Ask Claude to edit…").read(checkingFocus: false), 1.02)
        TestSupport.expectEqual(sentWithBlank, .sent(final: pasted, fromPayload: false))

        let suggestion = panelReader(value: "add a synthetic suggestion about something else").read(checkingFocus: false)
        TestSupport.expectEqual(suggestion.kind, .other)
        var suggested = watch(target: .claudeCodePanel)
        _ = observe(&suggested, holds(), 0.5)
        commit(&suggested, 1.0)
        let sentWithOther = observe(&suggested, suggestion, 1.02)
        TestSupport.expectEqual(sentWithOther, .sent(final: pasted, fromPayload: false))

        for sent in [sentWithBlank, sentWithOther] {
            guard case .sent(let final, _) = sent else { fatalError("Expected a send") }
            TestSupport.expect(!ContextTarget.claudeCodePanel.isComposerPlaceholder(final), "Placeholder text is never final")
        }

        // Other in the panel with no commit is not a send.
        var typedOver = watch(target: .claudeCodePanel)
        _ = observe(&typedOver, holds(), 0.5)
        TestSupport.expectEqual(observe(&typedOver, other, 1.0), .ended(.abandoned))

        // In ChatGPT other text is not an empty composer, even with a commit.
        var notSent = watch()
        _ = observe(&notSent, holds(), 0.5)
        commit(&notSent, 1.0)
        TestSupport.expectEqual(observe(&notSent, other, 1.02), .none)
        TestSupport.expect(!notSent.isEnded, "Not a send")

        // ChatGPT's own placeholder reads as blank too.
        let ax = FakeAX()
        ax.place(1, value: .text("Ask anything"))
        let chatGPT = reader(ax)
        _ = chatGPT.arm()
        TestSupport.expectEqual(chatGPT.read(checkingFocus: false).kind, .blank)
    }

    // MARK: Reader

    private static func testReaderLimits() {
        let ax = FakeAX()
        ax.place(1)
        let reader = reader(ax)
        TestSupport.expectEqual(reader.read(checkingFocus: false).kind, .gone)
        TestSupport.expectEqual(ax.valueReads, [])
        TestSupport.expectEqual(reader.arm(), .armed)

        // Over the length cap nothing is compared.
        ax.values[1] = .text(String(repeating: "a", count: ComposerWatch.maxValueLength + 1))
        TestSupport.expectEqual(reader.read(checkingFocus: false).kind, .unreadable)
        ax.values[1] = .failed
        TestSupport.expectEqual(reader.read(checkingFocus: false).kind, .unreadable)
        ax.values[1] = .text("")
        TestSupport.expectEqual(reader.read(checkingFocus: false).kind, .blank)
        ax.values[1] = .text(" \u{FFFC}\n")
        TestSupport.expectEqual(reader.read(checkingFocus: false).kind, .blank)
        ax.values[1] = .text("something else entirely")
        TestSupport.expectEqual(reader.read(checkingFocus: false).kind, .other)

        // A later paste counts, and so does a payload that holds it.
        let added = "deploy it to versel tonight"
        ax.values[1] = .text(added)
        TestSupport.expectEqual(reader.read(checkingFocus: false).kind, .other)
        TestSupport.expect(!reader.holdsPaste(added), "Not yet")
        reader.add(pasted: added)
        TestSupport.expectEqual(reader.read(checkingFocus: false).kind, .holdsPaste(added))
        TestSupport.expect(reader.holdsPaste(added), "Now it is held")

        // Focus is checked when asked, and the last answer stays until then.
        ax.focused = 9
        TestSupport.expectEqual(reader.read(checkingFocus: false).focusAway, false)
        TestSupport.expectEqual(reader.read(checkingFocus: true).focusAway, true)
        TestSupport.expectEqual(reader.read(checkingFocus: false).focusAway, true)
        ax.focused = nil
        TestSupport.expectEqual(reader.read(checkingFocus: true).focusAway, true)
        ax.focused = 1
        TestSupport.expectEqual(reader.read(checkingFocus: true).focusAway, false)

        // Without a window to compare, a replacement cannot be accepted.
        let windowless = FakeAX()
        windowless.place(1, title: nil, domain: nil)
        windowless.windows[1] = nil
        let app = ComposerWatchTests.reader(windowless, bundle: chatGPTApp, target: .chatGPTApp)
        TestSupport.expectEqual(app.arm(), .armed)
        windowless.values[1] = .invalidElement
        windowless.place(2, title: nil, domain: nil)
        TestSupport.expectEqual(app.read(checkingFocus: false).kind, .gone)
    }

    private static func testMayArm() {
        func mayArm(_ target: ContextTarget?, enter: Bool = false, reporting: Bool = false) -> Bool {
            ComposerWatchGate.mayArm(target: target, pressedEnter: enter, hookIsReporting: reporting)
        }
        TestSupport.expect(mayArm(.chatGPTWeb), "ChatGPT in Chrome")
        TestSupport.expect(mayArm(.chatGPTApp), "The ChatGPT app")
        TestSupport.expect(mayArm(.chatGPTWeb, reporting: true), "The hook says nothing about ChatGPT")
        TestSupport.expect(!mayArm(.chatGPTWeb, enter: true), "FreeFlow pressed Enter")
        TestSupport.expect(!mayArm(.chatGPTApp, enter: true), "FreeFlow pressed Enter")
        TestSupport.expect(mayArm(.claudeCodePanel), "The hook is not reporting")
        TestSupport.expect(!mayArm(.claudeCodePanel, reporting: true), "A healthy hook covers the panel")
        TestSupport.expect(!mayArm(.claudeCodePanel, enter: true), "FreeFlow pressed Enter")
        TestSupport.expect(!mayArm(nil), "No composer")
        TestSupport.expect(!mayArm(.googleSearch), "Google has its own watch")

        TestSupport.expectEqual(ComposerWatchGate.source(for: .claudeCodePanel), .claudeCode)
        TestSupport.expectEqual(ComposerWatchGate.source(for: .chatGPTWeb), .chatGPT)
        TestSupport.expectEqual(ComposerWatchGate.source(for: .chatGPTApp), .chatGPT)
    }

    // MARK: Pastes after an end

    /// The fallback gives up, but the hook is still listening: its prompt can match the paste.
    private static func testPastesAfterAnEnd() {
        func keeps(_ reason: Watch.EndReason, target: ContextTarget = .claudeCodePanel, listening: Bool = true) -> Bool {
            ComposerWatchGate.keepsPastes(target: target, hookIsListening: listening, after: reason)
        }
        for reason in [Watch.EndReason.unsettled, .focusLost, .abandoned, .appSwitch, .timeout, .notFound, .lost, .ownWrite] {
            TestSupport.expect(keeps(reason), "The hook can still match it")
            TestSupport.expect(!keeps(reason, listening: false), "Nothing else can use it")
            TestSupport.expect(!keeps(reason, target: .chatGPTWeb), "The hook says nothing about ChatGPT")
            TestSupport.expect(!keeps(reason, target: .chatGPTApp), "The hook says nothing about ChatGPT")
        }
        TestSupport.expect(!keeps(.killSwitch), "The kill switch forgets it")
        TestSupport.expect(!keeps(.cancelled), "Delete all and Undo AI edit forget it")
    }

    // MARK: Read-only

    /// The watch's sources never name a write, a forced accessibility mode or an action.
    private static func testLiveAccessibilityNeverWrites() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for path in ["Sources/ComposerWatchSession.swift", "Sources/ComposerWatch.swift"] {
            guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
                fatalError("Could not read \(path)")
            }
            for forbidden in ["AXUIElementSetAttributeValue", "AXUIElementPerformAction", "AXManualAccessibility", "AXEnhancedUserInterface"] {
                TestSupport.expect(!source.contains(forbidden), "\(path) names \(forbidden)")
            }
        }
    }

    // MARK: AppState wiring

    /// AppState cannot run in a test, and the insertion harness shims performAfterShortcutReleased,
    /// so these calls are pinned by source. Removing one would leave the suite green while the
    /// watch went on reading after the switch was off (W12) or past a FreeFlow write (W7).
    private static func testAppStateWiring() {
        func body(of declaration: String, in path: String) -> String {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8),
                  let start = source.range(of: declaration),
                  let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else {
                fatalError("Could not find \(declaration) in \(path)")
            }
            return String(source[start.lowerBound..<end.upperBound])
        }
        let appState = "Sources/AppState.swift", sources = "Sources/AppState+LearningSources.swift"
        TestSupport.expect(
            body(of: "@Published var learningEnabled", in: appState).contains("syncLearningSources()"),
            "Turning learning off syncs the sources"
        )
        TestSupport.expect(
            body(of: "func syncLearningSources()", in: sources).contains("endComposerWatch(.killSwitch, counts: false)"),
            "The kill switch ends the watch at once"
        )
        TestSupport.expect(
            body(of: "func performAfterShortcutReleased", in: appState).contains("if attempt == 0 { noteFreeFlowWrite() }"),
            "Every FreeFlow write is noted once, as it is scheduled"
        )
        TestSupport.expect(
            body(of: "func cancelLearningCredit", in: sources).contains("endComposerWatch(.cancelled, counts: false)"),
            "Undo AI edit ends the dictation's watch"
        )
        TestSupport.expect(
            body(of: "func forgetFailedInsertion", in: sources).contains("endComposerWatch(.cancelled, counts: false)"),
            "An insertion that did not land ends the dictation's watch"
        )
        TestSupport.expect(
            body(of: "func deleteAllLearnedData", in: "Sources/AppState+Learning.swift").contains("endComposerWatch(.cancelled, counts: false)"),
            "Delete all ends the watch"
        )
    }
}
