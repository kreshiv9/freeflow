import Cocoa

/// The tap's consume decisions with and without the key-activity hook. Drives the real
/// handleEventTap with events that are created and never posted; start() is never called, so no
/// tap exists and nothing reaches another app.
enum GlobalShortcutBackendTests {
    static func run() {
        testFixturesReachTheRealPath()
        testDecisionsAreIdenticalWithTheHook()
        testHookFiresOnlyForPassedThroughKeyDowns()
        testHookCarriesCategoriesOnly()
        testOwnEventFlag()
        testResets()
    }

    // MARK: Fixtures

    private struct Key {
        let type: CGEventType
        let keyCode: UInt16
        var flags: CGEventFlags = []
        var isRepeat = false
    }

    private static let optionDown = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK))

    /// Each key down and up, its repeat, Escape in both forms and modifier changes, some of
    /// which change the backend's tracked Fn state for the keys after them.
    private static let keys: [Key] = {
        var keys: [Key] = []
        let plain: [(UInt16, CGEventFlags)] = [
            (36, []), (36, .maskCommand), (0, []), (51, []), (96, []), (76, []), (36, .maskShift), (9, .maskCommand),
        ]
        for (keyCode, flags) in plain {
            keys.append(Key(type: .keyDown, keyCode: keyCode, flags: flags))
            keys.append(Key(type: .keyDown, keyCode: keyCode, flags: flags, isRepeat: true))
            keys.append(Key(type: .keyUp, keyCode: keyCode, flags: flags))
        }
        keys.append(Key(type: .keyDown, keyCode: 53))
        keys.append(Key(type: .keyDown, keyCode: 53, isRepeat: true))
        keys.append(Key(type: .keyUp, keyCode: 53))
        keys.append(Key(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn))
        keys.append(Key(type: .keyDown, keyCode: 0, flags: .maskSecondaryFn))
        keys.append(Key(type: .flagsChanged, keyCode: 63))
        keys.append(Key(type: .flagsChanged, keyCode: 58, flags: optionDown))
        keys.append(Key(type: .keyDown, keyCode: 36, flags: optionDown))
        keys.append(Key(type: .flagsChanged, keyCode: 58))
        return keys
    }()

    private static func event(_ key: Key) -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: key.type != .keyUp) else {
            fatalError("Could not create a synthetic key event")
        }
        event.type = key.type
        event.flags = key.flags
        // Another process's event, unless a test says otherwise.
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()) + 1)
        if key.isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return event
    }

    private enum Script: CaseIterable {
        case consume, passthrough, consumeOnSnapshot, consumeOnKey

        func decision(_ event: ShortcutInputEvent) -> ShortcutConsumeDecision {
            switch (self, event) {
            case (.consume, _), (.consumeOnSnapshot, .modifierSnapshot), (.consumeOnKey, .keyChanged):
                return .consume
            default:
                return .passthrough
            }
        }
    }

    private struct Trace: Equatable {
        var consumed: [Bool] = []
        var inputs: [ShortcutInputEvent] = []
        var escapes = 0
    }

    private static func trace(_ script: Script, escapeConsumes: Bool, hook: ((KeyActivity) -> Void)?) -> Trace {
        let backend = GlobalShortcutBackend()
        var trace = Trace()
        backend.onInputEvent = { event in
            trace.inputs.append(event)
            return script.decision(event)
        }
        backend.onEscapeKeyPressed = {
            trace.escapes += 1
            return escapeConsumes
        }
        backend.onKeyActivity = hook
        for key in keys {
            trace.consumed.append(backend.handleEventTap(type: key.type, event: event(key)) == nil)
        }
        // The reset of its deinit is not part of what is compared.
        backend.onInputEvent = nil
        backend.onKeyActivity = nil
        return trace
    }

    // MARK: Tests

    /// An event NSEvent cannot convert takes the early return, which would prove nothing.
    private static func testFixturesReachTheRealPath() {
        for key in keys {
            TestSupport.expect(NSEvent(cgEvent: event(key)) != nil, "A fixture must convert to an NSEvent")
        }
        // The fixtures can actually be consumed, or comparing decisions would prove little.
        let consumed = trace(.consume, escapeConsumes: true, hook: nil)
        // All but Escape's repeat, which the backend always lets through.
        TestSupport.expectEqual(consumed.consumed.filter { $0 }.count, keys.count - 1)
        TestSupport.expect(trace(.passthrough, escapeConsumes: false, hook: nil).consumed.allSatisfy { !$0 }, "Nothing is consumed")
    }

    private static func testDecisionsAreIdenticalWithTheHook() {
        for script in Script.allCases {
            for escapeConsumes in [true, false] {
                let without = trace(script, escapeConsumes: escapeConsumes, hook: nil)
                let with = trace(script, escapeConsumes: escapeConsumes) { _ in }
                TestSupport.expectEqual(with, without)
                TestSupport.expect(!without.inputs.isEmpty, "The script saw the keys")
                TestSupport.expectEqual(without.escapes, 1)
            }
        }
    }

    private static func testHookFiresOnlyForPassedThroughKeyDowns() {
        for script in Script.allCases {
            for escapeConsumes in [true, false] {
                var reported: [KeyActivity] = []
                let traced = trace(script, escapeConsumes: escapeConsumes) { reported.append($0) }
                let expected: [KeyActivity] = zip(keys, traced.consumed).compactMap { key, consumed in
                    guard key.type == .keyDown, !consumed else { return nil }
                    return .key(CommitKeyClassifier.category(keyCode: key.keyCode, flags: key.flags, isOwnEvent: false))
                }
                TestSupport.expectEqual(reported, expected)
                TestSupport.expect(script != .passthrough || escapeConsumes || !reported.isEmpty, "The hook fired for passed keys")
            }
        }
    }

    /// Only a category crosses the hook; KeyActivity has no case that could carry a key code.
    private static func testHookCarriesCategoriesOnly() {
        func reported(_ keyCode: UInt16, _ flags: CGEventFlags = []) -> [KeyActivity] {
            let backend = GlobalShortcutBackend()
            var reported: [KeyActivity] = []
            backend.onKeyActivity = { reported.append($0) }
            _ = backend.handleEventTap(type: .keyDown, event: event(Key(type: .keyDown, keyCode: keyCode, flags: flags)))
            backend.onKeyActivity = nil
            return reported
        }
        TestSupport.expectEqual(reported(36, .maskCommand), [.key(.commit)])
        TestSupport.expectEqual(reported(36, .maskShift), [.key(.newline)])
        TestSupport.expectEqual(reported(0), [.key(.edit)])
        TestSupport.expectEqual(reported(6, .maskCommand), [.key(.undo)])
        TestSupport.expectEqual(reported(123), [.key(.navigation)])
    }

    private static func testOwnEventFlag() {
        func category(_ pid: Int64) -> KeyActivity? {
            let backend = GlobalShortcutBackend()
            var reported: KeyActivity?
            backend.onKeyActivity = { reported = $0 }
            let keyDown = event(Key(type: .keyDown, keyCode: 9, flags: .maskCommand))
            keyDown.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
            _ = backend.handleEventTap(type: .keyDown, event: keyDown)
            backend.onKeyActivity = nil
            return reported
        }
        TestSupport.expectEqual(category(Int64(getpid())), .key(.own))
        TestSupport.expectEqual(category(Int64(getpid()) + 1), .key(.edit))
    }

    /// A blind tap cannot show that no edit key was pressed.
    private static func testResets() {
        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let backend = GlobalShortcutBackend()
            var inputs: [ShortcutInputEvent] = []
            var activity: [KeyActivity] = []
            backend.onInputEvent = { event in
                inputs.append(event)
                return .passthrough
            }
            backend.onKeyActivity = { activity.append($0) }
            let result = backend.handleEventTap(type: type, event: event(Key(type: .keyDown, keyCode: 0)))
            TestSupport.expect(result != nil, "A tap notice passes through")
            TestSupport.expectEqual(inputs, [.backendReset])
            TestSupport.expectEqual(activity, [.reset])
            backend.onInputEvent = nil
            backend.onKeyActivity = nil
        }

        let backend = GlobalShortcutBackend()
        var activity: [KeyActivity] = []
        backend.onKeyActivity = { activity.append($0) }
        TestSupport.expect(!backend.isTapInstalled, "No tap without start()")
        backend.stop()
        TestSupport.expectEqual(activity, [.reset])
        backend.onKeyActivity = nil
    }
}
