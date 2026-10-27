import Foundation

enum ShortcutCoreTests {
    static func run() {
        testBareFnHoldLifecycle()
        testDefaultShortcutSpecificityOrdering()
        testRightOptionPresetIsSideSpecific()
        testExactModifierMatching()
        testReducerHonorsExactModifierMatching()
        testRepeatedKeyDownDoesNotReactivate()
        testPasteAgainFiresOnLeadingEdgeOnly()
        testBackendResetClearsActiveBindings()
        testBindingMigrationAndIdentity()
        testConflictDetection()
        testHoldSessionControllerLifecycle()
        testToggleSessionControllerLifecycle()
        testHoldToToggleSessionControllerLifecycle()
        testQuickTapThenRetapBecomesHandsFree()
        testQuickTapWithoutRetapStopsAtDeadlineThenStartsASeparateDictation()
        testOverdueTapStopWinsOverLatePress()
        testLongHoldStopsImmediatelyOnRelease()
        testToggleReactivationInsideCancelWindowCancels()
        testToggleShortcutPressDoesNotCancelItsOwnSession()
        testDoubleTapSessionStopsWithToggleShortcut()
        testHoldToToggleSwitchThenHoldTapStops()
        testResetClearsDeferredTapStop()
        testToggleShortcutEndPressDoesNotStartHoldSession()
        testHoldShortcutEndPressSwallowsAddedToggleActivation()
        testWindowsCountFromRecordingStart()
    }

    private static func testBareFnHoldLifecycle() {
        let configuration = ShortcutConfiguration(hold: .defaultHold, toggle: .disabled)
        let down = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 63, isDown: true),
            configuration: configuration
        )
        let up = ShortcutMatcher.reduce(
            state: down.state,
            event: .modifierChanged(keyCode: 63, isDown: false),
            configuration: configuration
        )

        TestSupport.expectEqual(down.emittedEvents, [.holdActivated])
        TestSupport.expectEqual(down.consumeDecision, .consume)
        TestSupport.expectEqual(up.emittedEvents, [.holdDeactivated])
        TestSupport.expectEqual(up.consumeDecision, .consume)
    }

    private static func testDefaultShortcutSpecificityOrdering() {
        let configuration = ShortcutConfiguration(
            hold: .defaultHold,
            toggle: .defaultToggle
        )
        let commandDown = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 55, isDown: true),
            configuration: configuration
        )
        let fnDown = ShortcutMatcher.reduce(
            state: commandDown.state,
            event: .modifierChanged(keyCode: 63, isDown: true),
            configuration: configuration
        )
        let fnUp = ShortcutMatcher.reduce(
            state: fnDown.state,
            event: .modifierChanged(keyCode: 63, isDown: false),
            configuration: configuration
        )

        TestSupport.expectEqual(fnDown.emittedEvents, [.toggleActivated, .holdActivated])
        TestSupport.expectEqual(fnUp.emittedEvents, [.holdDeactivated, .toggleDeactivated])
    }

    private static func testRightOptionPresetIsSideSpecific() {
        let configuration = ShortcutConfiguration(
            hold: ShortcutPreset.rightOption.binding,
            toggle: .disabled
        )
        let leftOption = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 58, isDown: true),
            configuration: configuration
        )
        let rightOption = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 61, isDown: true),
            configuration: configuration
        )

        TestSupport.expectEqual(leftOption.emittedEvents, [])
        TestSupport.expectEqual(rightOption.emittedEvents, [.holdActivated])
    }

    private static func testExactModifierMatching() {
        TestSupport.expect(
            ShortcutBinding.exactModifierKeyCodesMatch([54], exactModifierKeyCodes: [54, 55]),
            "A generic Command binding should accept Right Command"
        )
        TestSupport.expect(
            ShortcutBinding.exactModifierKeyCodesMatch([55], exactModifierKeyCodes: [54, 55]),
            "A generic Command binding should accept Left Command"
        )
        TestSupport.expect(
            !ShortcutBinding.exactModifierKeyCodesMatch([55, 56], exactModifierKeyCodes: [55]),
            "Unexpected Shift should invalidate an exact Command binding"
        )
        TestSupport.expect(
            ShortcutBinding.exactModifierKeyCodesMatch(
                [55, 56],
                exactModifierKeyCodes: [55],
                permittedAdditionalExactMatchModifiers: [.shift]
            ),
            "Explicitly permitted Shift should not invalidate an exact Command binding"
        )
    }

    private static func testReducerHonorsExactModifierMatching() {
        let binding = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.command],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55]
        )

        let rightCommandState = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 54, isDown: true),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        ).state
        let rightCommandKey = ShortcutMatcher.reduce(
            state: rightCommandState,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        )
        TestSupport.expectEqual(rightCommandKey.emittedEvents, [])

        let leftCommandState = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 55, isDown: true),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        ).state
        let leftCommandKey = ShortcutMatcher.reduce(
            state: leftCommandState,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        )
        TestSupport.expectEqual(leftCommandKey.emittedEvents, [.holdActivated])

        let shiftedState = ShortcutMatcher.reduce(
            state: leftCommandState,
            event: .modifierChanged(keyCode: 56, isDown: true),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        ).state
        let shiftedKey = ShortcutMatcher.reduce(
            state: shiftedState,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: ShortcutConfiguration(hold: binding, toggle: .disabled)
        )
        TestSupport.expectEqual(shiftedKey.emittedEvents, [])

        let permittedConfiguration = ShortcutConfiguration(
            hold: binding,
            toggle: .disabled,
            permittedAdditionalExactMatchModifiers: [.shift]
        )
        let permittedKey = ShortcutMatcher.reduce(
            state: shiftedState,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: permittedConfiguration
        )
        TestSupport.expectEqual(permittedKey.emittedEvents, [.holdActivated])
    }

    private static func testRepeatedKeyDownDoesNotReactivate() {
        let binding = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [],
            kind: .key,
            preset: nil
        )
        let configuration = ShortcutConfiguration(hold: binding, toggle: .disabled)
        let first = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: configuration
        )
        let repeated = ShortcutMatcher.reduce(
            state: first.state,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: true),
            configuration: configuration
        )

        TestSupport.expectEqual(first.emittedEvents, [.holdActivated])
        TestSupport.expectEqual(repeated.emittedEvents, [])
        TestSupport.expectEqual(repeated.state, first.state)
        TestSupport.expectEqual(repeated.consumeDecision, .consume)
    }

    private static func testPasteAgainFiresOnLeadingEdgeOnly() {
        let binding = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [],
            kind: .key,
            preset: nil
        )
        let configuration = ShortcutConfiguration(hold: .disabled, toggle: .disabled, copyAgain: binding)
        let firstDown = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: configuration
        )
        let repeated = ShortcutMatcher.reduce(
            state: firstDown.state,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: true),
            configuration: configuration
        )
        let up = ShortcutMatcher.reduce(
            state: repeated.state,
            event: .keyChanged(keyCode: 96, isDown: false, isRepeat: false),
            configuration: configuration
        )
        let secondDown = ShortcutMatcher.reduce(
            state: up.state,
            event: .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
            configuration: configuration
        )

        TestSupport.expectEqual(firstDown.emittedEvents, [.copyAgainTriggered])
        TestSupport.expectEqual(repeated.emittedEvents, [])
        TestSupport.expectEqual(up.emittedEvents, [])
        TestSupport.expectEqual(secondDown.emittedEvents, [.copyAgainTriggered])
    }

    private static func testBackendResetClearsActiveBindings() {
        let configuration = ShortcutConfiguration(hold: .defaultHold, toggle: .defaultToggle)
        let commandDown = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .modifierChanged(keyCode: 55, isDown: true),
            configuration: configuration
        )
        let fnDown = ShortcutMatcher.reduce(
            state: commandDown.state,
            event: .modifierChanged(keyCode: 63, isDown: true),
            configuration: configuration
        )
        let reset = ShortcutMatcher.reduce(
            state: fnDown.state,
            event: .backendReset,
            configuration: configuration
        )

        TestSupport.expectEqual(reset.emittedEvents, [.holdDeactivated, .toggleDeactivated])
        TestSupport.expectEqual(reset.consumeDecision, .passthrough)
        TestSupport.expect(reset.state.pressedKeyCodes.isEmpty, "Backend reset should clear pressed keys")
        TestSupport.expect(reset.state.pressedModifierKeyCodes.isEmpty, "Backend reset should clear modifiers")
        TestSupport.expect(!reset.state.holdIsActive && !reset.state.toggleIsActive, "Backend reset should clear active bindings")
    }

    private static func testBindingMigrationAndIdentity() {
        let stored = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [999, 61]
        )
        let normalized = stored.normalizedForStorageMigration()
        TestSupport.expectEqual(normalized.exactModifierKeyCodes, [61])
        TestSupport.expectEqual(normalized.modifiers, [.option])

        let first = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.command, .option],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [55, 58]
        )
        let second = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.option, .command],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [58, 55]
        )
        TestSupport.expectEqual(first.id, second.id)
    }

    private static func testConflictDetection() {
        let first = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.command],
            kind: .key,
            preset: nil
        )
        let same = ShortcutBinding(
            keyCode: 96,
            keyDisplay: "F5",
            modifiers: [.command],
            kind: .key,
            preset: nil
        )
        let different = ShortcutBinding(
            keyCode: 97,
            keyDisplay: "F6",
            modifiers: [.command],
            kind: .key,
            preset: nil
        )

        TestSupport.expect(first.conflicts(with: same), "Equivalent bindings should conflict")
        TestSupport.expect(same.conflicts(with: first), "Conflict detection should be symmetric")
        TestSupport.expect(!first.conflicts(with: different), "Different primary keys should not conflict")
        TestSupport.expect(!first.conflicts(with: .disabled), "Disabled bindings should not conflict")
    }

    /// A hold longer than the double-tap window still stops on release.
    private static func testHoldSessionControllerLifecycle() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: true), nil)
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        now = 1
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), .stop)
        TestSupport.expectEqual(controller.activeMode, nil)
    }

    /// A toggle press after the cancel window stops the session.
    private static func testToggleSessionControllerLifecycle() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .start(.toggle))
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.toggleStopArmed, true)
        now = 1
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .stop)
        TestSupport.expectEqual(controller.activeMode, nil)
    }

    private static func testHoldToToggleSessionControllerLifecycle() {
        let controller = DictationShortcutSessionController()
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .switchedToToggle)
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.activeMode, .toggle)
        TestSupport.expectEqual(controller.handle(event: .copyAgainTriggered, isTranscribing: false), nil)
        controller.beginManual(mode: .hold)
        TestSupport.expectEqual(controller.activeMode, .hold)
        controller.forceToggleMode()
        TestSupport.expectEqual(controller.activeMode, .toggle)
        controller.reset()
        TestSupport.expectEqual(controller.activeMode, nil)
        TestSupport.expectEqual(controller.toggleStopArmed, false)
    }

    private static func testQuickTapThenRetapBecomesHandsFree() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        now = 0.2
        TestSupport.expectEqual(
            controller.handle(event: .holdDeactivated, isTranscribing: false),
            .stopUnlessRetapped(deadline: 0.5)
        )
        TestSupport.expectEqual(controller.activeMode, .hold)
        TestSupport.expectEqual(controller.pendingTapStopDeadline, 0.5)
        now = 0.4
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .switchedToToggle)
        TestSupport.expectEqual(controller.activeMode, .toggle)
        TestSupport.expectEqual(controller.pendingTapStopDeadline, nil)
        now = 0.45
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), nil)
        // A stale timer must not end the hands-free session.
        TestSupport.expectEqual(controller.resolvePendingTapStop(deadline: 0.5), nil)
        TestSupport.expectEqual(controller.activeMode, .toggle)
        now = 3
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .stop)
        TestSupport.expectEqual(controller.activeMode, nil)
    }

    private static func testQuickTapWithoutRetapStopsAtDeadlineThenStartsASeparateDictation() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        now = 0.2
        TestSupport.expectEqual(
            controller.handle(event: .holdDeactivated, isTranscribing: false),
            .stopUnlessRetapped(deadline: 0.5)
        )
        // A mismatched deadline is ignored.
        TestSupport.expectEqual(controller.resolvePendingTapStop(deadline: 0.4), nil)
        TestSupport.expectEqual(controller.activeMode, .hold)
        now = 0.5
        TestSupport.expectEqual(controller.resolvePendingTapStop(deadline: 0.5), .stop)
        TestSupport.expectEqual(controller.activeMode, nil)
        // A second, separate dictation.
        now = 0.8
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        now = 0.9
        TestSupport.expectEqual(
            controller.handle(event: .holdDeactivated, isTranscribing: false),
            .stopUnlessRetapped(deadline: 1.3)
        )
        now = 1.3
        TestSupport.expectEqual(controller.resolvePendingTapStop(deadline: 1.3), .stop)
        TestSupport.expectEqual(controller.activeMode, nil)
    }

    private static func testOverdueTapStopWinsOverLatePress() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        now = 0.2
        TestSupport.expectEqual(
            controller.handle(event: .holdDeactivated, isTranscribing: false),
            .stopUnlessRetapped(deadline: 0.5)
        )
        // The timer is late: the deferred stop wins and the press is consumed.
        now = 0.6
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .stop)
        TestSupport.expectEqual(controller.activeMode, nil)
        TestSupport.expectEqual(controller.resolvePendingTapStop(deadline: 0.5), nil)
    }

    private static func testLongHoldStopsImmediatelyOnRelease() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        now = 0.6
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), .stop)
        TestSupport.expectEqual(controller.activeMode, nil)
        TestSupport.expectEqual(controller.pendingTapStopDeadline, nil)

        // Boundary: a release at exactly the window stops immediately.
        var boundaryNow: TimeInterval = 0
        let boundary = DictationShortcutSessionController(now: { boundaryNow })
        TestSupport.expectEqual(boundary.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        boundaryNow = 0.5
        TestSupport.expectEqual(boundary.handle(event: .holdDeactivated, isTranscribing: false), .stop)
        TestSupport.expectEqual(boundary.activeMode, nil)
    }

    private static func testToggleReactivationInsideCancelWindowCancels() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .start(.toggle))
        now = 0.1
        TestSupport.expectEqual(controller.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        now = 0.3
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .cancel)
        TestSupport.expectEqual(controller.activeMode, nil)

        var lateNow: TimeInterval = 0
        let late = DictationShortcutSessionController(now: { lateNow })
        TestSupport.expectEqual(late.handle(event: .toggleActivated, isTranscribing: false), .start(.toggle))
        lateNow = 0.1
        TestSupport.expectEqual(late.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        lateNow = 0.7
        TestSupport.expectEqual(late.handle(event: .toggleActivated, isTranscribing: false), .stop)
        TestSupport.expectEqual(late.activeMode, nil)
    }

    /// The default ⌘+Fn press emits .toggleActivated then .holdActivated in the
    /// same keypress (see testDefaultShortcutSpecificityOrdering); the trailing
    /// hold activation must not end the session it just started.
    private static func testToggleShortcutPressDoesNotCancelItsOwnSession() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .start(.toggle))
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.holdStopArmed, false)
        now = 0.1
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.holdStopArmed, true)
        // A bare hold tap inside the window cancels.
        now = 0.2
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .cancel)
        TestSupport.expectEqual(controller.activeMode, nil)

        var lateNow: TimeInterval = 0
        let late = DictationShortcutSessionController(now: { lateNow })
        TestSupport.expectEqual(late.handle(event: .toggleActivated, isTranscribing: false), .start(.toggle))
        TestSupport.expectEqual(late.handle(event: .holdActivated, isTranscribing: false), nil)
        lateNow = 0.1
        TestSupport.expectEqual(late.handle(event: .holdDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(late.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        lateNow = 1
        TestSupport.expectEqual(late.handle(event: .holdActivated, isTranscribing: false), .stop)
        TestSupport.expectEqual(late.activeMode, nil)
    }

    /// Double-tap entry arms the toggle shortcut, so a non-overlapping toggle
    /// binding can end a hands-free session with one press.
    private static func testDoubleTapSessionStopsWithToggleShortcut() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        now = 0.2
        TestSupport.expectEqual(
            controller.handle(event: .holdDeactivated, isTranscribing: false),
            .stopUnlessRetapped(deadline: 0.5)
        )
        now = 0.4
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .switchedToToggle)
        TestSupport.expectEqual(controller.toggleStopArmed, true)
        now = 0.45
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), nil)
        now = 2
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .stop)
        TestSupport.expectEqual(controller.activeMode, nil)
    }

    private static func testHoldToToggleSwitchThenHoldTapStops() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        now = 0.1
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .switchedToToggle)
        TestSupport.expectEqual(controller.pendingTapStopDeadline, nil)
        now = 0.2
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), nil)
        now = 0.3
        TestSupport.expectEqual(controller.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        now = 2
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .stop)
        TestSupport.expectEqual(controller.activeMode, nil)

        // The cancel window counts from the first press, not from the switch.
        var earlyNow: TimeInterval = 0
        let early = DictationShortcutSessionController(now: { earlyNow })
        TestSupport.expectEqual(early.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        earlyNow = 0.1
        TestSupport.expectEqual(early.handle(event: .toggleActivated, isTranscribing: false), .switchedToToggle)
        earlyNow = 0.2
        TestSupport.expectEqual(early.handle(event: .holdDeactivated, isTranscribing: false), nil)
        earlyNow = 0.3
        TestSupport.expectEqual(early.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        earlyNow = 0.4
        TestSupport.expectEqual(early.handle(event: .holdActivated, isTranscribing: false), .cancel)
        TestSupport.expectEqual(early.activeMode, nil)
    }

    private static func testResetClearsDeferredTapStop() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        now = 0.2
        TestSupport.expectEqual(
            controller.handle(event: .holdDeactivated, isTranscribing: false),
            .stopUnlessRetapped(deadline: 0.5)
        )
        controller.reset()
        TestSupport.expectEqual(controller.pendingTapStopDeadline, nil)
        TestSupport.expectEqual(controller.holdStopArmed, false)
        TestSupport.expectEqual(controller.resolvePendingTapStop(deadline: 0.5), nil)

        // Manual sessions also get a cancel window.
        now = 0
        controller.beginManual(mode: .toggle)
        now = 0.2
        TestSupport.expectEqual(controller.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .cancel)
        TestSupport.expectEqual(controller.activeMode, nil)
    }

    /// The default ⌘+Fn press that ends a toggle session also emits a trailing
    /// .holdActivated (see testDefaultShortcutSpecificityOrdering). It must not
    /// start a hold dictation, for a cancel or a stop, even though AppState
    /// resets the controller and leaves isTranscribing false on cancel.
    private static func testToggleShortcutEndPressDoesNotStartHoldSession() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .start(.toggle))
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), nil)
        now = 0.1
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        now = 0.3
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .cancel)
        // AppState's cancel path resets the controller before the trailing event arrives.
        controller.reset()
        TestSupport.expectEqual(controller.swallowsActivationsUntilRelease, true)
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.activeMode, nil)
        now = 0.4
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.swallowsActivationsUntilRelease, false)
        // A fresh press after the release starts normally.
        now = 1
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        TestSupport.expectEqual(controller.activeMode, .hold)

        // Same keypress after the cancel window: a stop, still without a hold start.
        var lateNow: TimeInterval = 0
        let late = DictationShortcutSessionController(now: { lateNow })
        TestSupport.expectEqual(late.handle(event: .toggleActivated, isTranscribing: false), .start(.toggle))
        TestSupport.expectEqual(late.handle(event: .holdActivated, isTranscribing: false), nil)
        lateNow = 0.1
        TestSupport.expectEqual(late.handle(event: .holdDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(late.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        lateNow = 1
        TestSupport.expectEqual(late.handle(event: .toggleActivated, isTranscribing: false), .stop)
        late.reset()
        TestSupport.expectEqual(late.handle(event: .holdActivated, isTranscribing: false), nil)
        TestSupport.expectEqual(late.activeMode, nil)
        // Releasing ⌘ first leaves Fn's hold binding active: only .toggleDeactivated arrives.
        lateNow = 1.1
        TestSupport.expectEqual(late.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        lateNow = 1.2
        TestSupport.expectEqual(late.handle(event: .holdDeactivated, isTranscribing: false), nil)
        lateNow = 2
        TestSupport.expectEqual(late.handle(event: .toggleActivated, isTranscribing: false), .start(.toggle))
    }

    /// Reverse order: Fn alone ends the session, then ⌘ is added before Fn is
    /// released. The added .toggleActivated belongs to the ending keypress.
    private static func testHoldShortcutEndPressSwallowsAddedToggleActivation() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .start(.toggle))
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), nil)
        now = 0.1
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        now = 0.3
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .cancel)
        controller.reset()
        // Adding ⌘ keeps the Fn hold binding active, so only .toggleActivated arrives.
        now = 0.35
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.activeMode, nil)
        now = 0.4
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        now = 1
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .start(.toggle))
        TestSupport.expectEqual(controller.activeMode, .toggle)
    }

    /// With a Shortcut Start Delay the recording begins after the press; both
    /// half-second windows count from `markRecordingStarted()`.
    private static func testWindowsCountFromRecordingStart() {
        var now: TimeInterval = 0
        let controller = DictationShortcutSessionController(now: { now })
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .start(.toggle))
        now = 0.1
        TestSupport.expectEqual(controller.handle(event: .toggleDeactivated, isTranscribing: false), nil)
        now = 0.5
        controller.markRecordingStarted()
        now = 0.8
        TestSupport.expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false), .cancel)
        TestSupport.expectEqual(controller.activeMode, nil)

        var tapNow: TimeInterval = 0
        let tap = DictationShortcutSessionController(now: { tapNow })
        TestSupport.expectEqual(tap.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        tapNow = 0.5
        tap.markRecordingStarted()
        tapNow = 0.7
        TestSupport.expectEqual(
            tap.handle(event: .holdDeactivated, isTranscribing: false),
            .stopUnlessRetapped(deadline: 1.0)
        )
        tapNow = 0.9
        TestSupport.expectEqual(tap.handle(event: .holdActivated, isTranscribing: false), .switchedToToggle)
        TestSupport.expectEqual(tap.activeMode, .toggle)

        // Without a session there is nothing to anchor.
        let idle = DictationShortcutSessionController(now: { 5 })
        idle.markRecordingStarted()
        TestSupport.expectEqual(idle.activeMode, nil)
        TestSupport.expectEqual(idle.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
    }
}
