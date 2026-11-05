import Cocoa
import os.log

private let shortcutLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Shortcuts")

enum GlobalShortcutBackendError: LocalizedError {
    case eventTapUnavailable
    case eventTapRunLoopSourceUnavailable

    var errorDescription: String? {
        switch self {
        case .eventTapUnavailable:
            return "Global shortcut monitoring could not start. \(AppName.displayName) requires keyboard monitoring permission for global shortcuts."
        case .eventTapRunLoopSourceUnavailable:
            return "Global shortcut monitoring could not start because the event tap run loop source could not be created."
        }
    }
}

final class GlobalShortcutBackend {
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var fnKeyIsDown = false

    var onInputEvent: ((ShortcutInputEvent) -> ShortcutConsumeDecision)?
    var onEscapeKeyPressed: (() -> Bool)?
    /// Told about each key the tap let through, after the decision was made. It returns nothing,
    /// so it cannot change what the tap consumes.
    var onKeyActivity: ((KeyActivity) -> Void)?

    var isTapInstalled: Bool {
        eventTap != nil
    }

    func start() throws {
        stop()
        try installEventTap()
        fnKeyIsDown = ModifierKeyEventState.currentFunctionKeyIsDown()
    }

    func stop() {
        tearDownEventTap()
        notifyBackendReset()
    }

    deinit {
        stop()
    }

    private func installEventTap() throws {
        let eventMask = [
            CGEventType.flagsChanged,
            CGEventType.keyDown,
            CGEventType.keyUp
        ].reduce(CGEventMask(0)) { partialResult, eventType in
            partialResult | (CGEventMask(1) << eventType.rawValue)
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let backend = Unmanaged<GlobalShortcutBackend>.fromOpaque(userInfo).takeUnretainedValue()
            return backend.handleEventTap(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            os_log(.error, log: shortcutLog, "Failed to install global shortcut event tap")
            throw GlobalShortcutBackendError.eventTapUnavailable
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            os_log(.error, log: shortcutLog, "Failed to create run loop source for global shortcut event tap")
            throw GlobalShortcutBackendError.eventTapRunLoopSourceUnavailable
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        eventTapRunLoopSource = source
    }

    private func tearDownEventTap() {
        if let source = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTapRunLoopSource = nil
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
    }

    private func notifyBackendReset() {
        fnKeyIsDown = false
        _ = onInputEvent?(.backendReset)
        onKeyActivity?(.reset)
    }

    func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            notifyBackendReset()
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                fnKeyIsDown = ModifierKeyEventState.currentFunctionKeyIsDown()
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged, .keyDown, .keyUp:
            guard let nsEvent = NSEvent(cgEvent: event) else {
                if type == .keyDown { reportKeyDown(event) }
                return Unmanaged.passUnretained(event)
            }

            let shouldConsume: Bool
            switch type {
            case .flagsChanged:
                shouldConsume = handleFlagsChanged(nsEvent)
            case .keyDown:
                shouldConsume = handleKeyDown(nsEvent)
            case .keyUp:
                shouldConsume = handleKeyUp(nsEvent)
            default:
                shouldConsume = false
            }

            if type == .keyDown && !shouldConsume { reportKeyDown(event) }
            return shouldConsume ? nil : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// The key's category only: its code and flags stop here, and its characters are never read.
    private func reportKeyDown(_ event: CGEvent) {
        guard let onKeyActivity else { return }
        onKeyActivity(.key(CommitKeyClassifier.category(
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            isOwnEvent: event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
        )))
    }

    private func handleFlagsChanged(_ event: NSEvent) -> Bool {
        guard ShortcutBinding.modifierKeyCodes.contains(event.keyCode),
              let isDown = ModifierKeyEventState.isKeyDown(for: event) else {
            return false
        }

        if event.keyCode == ModifierKeyEventState.fnKeyCode {
            fnKeyIsDown = isDown
        }

        return onInputEvent?(.modifierChanged(keyCode: event.keyCode, isDown: isDown)) == .consume
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            guard !event.isARepeat else { return false }
            return onEscapeKeyPressed?() ?? false
        }

        guard !ShortcutBinding.modifierKeyCodes.contains(event.keyCode) else { return false }
        let snapshotDecision = onInputEvent?(
            .modifierSnapshot(ModifierKeyEventState.pressedModifierKeyCodes(
                for: event,
                trustedFunctionKeyIsDown: fnKeyIsDown
            ))
        ) ?? .passthrough
        let keyDecision = onInputEvent?(
            .keyChanged(keyCode: event.keyCode, isDown: true, isRepeat: event.isARepeat)
        ) ?? .passthrough
        return snapshotDecision == .consume || keyDecision == .consume
    }

    private func handleKeyUp(_ event: NSEvent) -> Bool {
        guard !ShortcutBinding.modifierKeyCodes.contains(event.keyCode) else { return false }
        let snapshotDecision = onInputEvent?(
            .modifierSnapshot(ModifierKeyEventState.pressedModifierKeyCodes(
                for: event,
                trustedFunctionKeyIsDown: fnKeyIsDown
            ))
        ) ?? .passthrough
        let keyDecision = onInputEvent?(
            .keyChanged(keyCode: event.keyCode, isDown: false, isRepeat: false)
        ) ?? .passthrough
        return snapshotDecision == .consume || keyDecision == .consume
    }
}
