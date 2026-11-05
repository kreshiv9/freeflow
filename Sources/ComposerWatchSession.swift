import ApplicationServices
import Foundation

/// The live reads behind ComposerReader. Read-only, and every element gets a messaging timeout.
struct LiveComposerAccessibility: ComposerAccessibility {
    private static let messagingTimeout: Float = 0.1
    private static let webAreaRole = "AXWebArea"
    private static let maxAncestors = 32
    private static let webAreaBudgetSeconds: CFAbsoluteTime = 0.3

    func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        return try? element(of: application, attribute: kAXFocusedUIElementAttribute)
    }

    func field(of element: AXUIElement) -> ComposerField? {
        do {
            guard let role = try string(of: element, attribute: kAXRoleAttribute) else { return nil }
            return try ComposerField(
                role: role,
                subrole: string(of: element, attribute: kAXSubroleAttribute),
                description: string(of: element, attribute: kAXDescriptionAttribute),
                title: string(of: element, attribute: kAXTitleAttribute),
                placeholder: string(of: element, attribute: kAXPlaceholderValueAttribute)
            )
        } catch {
            return nil
        }
    }

    func value(of element: AXUIElement) -> ComposerValueRead {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) {
        case .success:
            return (value as? String).map(ComposerValueRead.text) ?? .failed
        case .noValue:
            return .text("")
        case .invalidUIElement:
            return .invalidElement
        default:
            return .failed
        }
    }

    func window(of element: AXUIElement) throws -> AXUIElement? {
        try self.element(of: element, attribute: kAXWindowAttribute)
    }

    func windowTitle(_ window: AXUIElement) throws -> String? {
        try string(of: window, attribute: kAXTitleAttribute)
    }

    /// The domain of the web area holding `element`. Host only; the rest of the URL is dropped.
    /// Running out of budget is a failed read: the element may still be in a web area.
    func webDomain(of element: AXUIElement) throws -> String? {
        let deadline = CFAbsoluteTimeGetCurrent() + Self.webAreaBudgetSeconds
        var current: AXUIElement? = element
        for _ in 0..<Self.maxAncestors {
            guard let candidate = current else { return nil }
            guard CFAbsoluteTimeGetCurrent() < deadline else { throw ComposerReadFailure() }
            if try string(of: candidate, attribute: kAXRoleAttribute) == Self.webAreaRole {
                return try url(of: candidate).flatMap(TextContextCore.domain(from:))
            }
            current = try self.element(of: candidate, attribute: kAXParentAttribute)
        }
        return nil
    }

    func isSame(_ first: AXUIElement, _ second: AXUIElement) -> Bool {
        CFEqual(first, second)
    }

    /// Nil when the app answered that there is no such value. Throws when it did not answer, or
    /// the element went away, which says nothing about the value.
    private func copyValue(of element: AXUIElement, attribute: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, attribute as CFString, &value) {
        case .success:
            return value
        case .cannotComplete, .invalidUIElement, .failure:
            throw ComposerReadFailure()
        default:
            return nil
        }
    }

    private func element(of element: AXUIElement, attribute: String) throws -> AXUIElement? {
        guard let value = try copyValue(of: element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(result, Self.messagingTimeout)
        return result
    }

    private func string(of element: AXUIElement, attribute: String) throws -> String? {
        guard let text = try copyValue(of: element, attribute: attribute) as? String, !text.isEmpty else { return nil }
        return text
    }

    private func url(of element: AXUIElement) throws -> URL? {
        let value = try copyValue(of: element, attribute: kAXURLAttribute)
        if let url = value as? URL { return url }
        return (value as? String).flatMap(URL.init(string:))
    }
}

/// The Accessibility side of one composer watch: it pins the composer, observes it and polls it
/// on one utility queue, and reports to `onEvent` on that queue. Nothing here blocks the main
/// thread or the event tap, and no composer text is kept between reads. The caller stays on main
/// for `start`, `readSoon`, `add` and `stop`.
final class ComposerWatchSession {
    enum Event {
        case armFailed(ComposerWatch.EndReason)
        case read(ComposerRead, startedAt: Date)
        /// Carries only the time, stamped on main like the keys, so the two compare in order.
        case valueChanged(at: Date)
        case deleted(String, holdsPaste: Bool, at: Date)
    }

    private static let armRetryInterval: TimeInterval = 0.3

    let pid: pid_t

    private let queue = DispatchQueue(label: "com.zachlatta.freeflow.composer-watch", qos: .utility)

    // Confined to `queue`.
    private let reader: ComposerReader<LiveComposerAccessibility>
    private var onEvent: ((Event) -> Void)?
    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var pendingRead: DispatchWorkItem?
    private var pendingReadDeadline: DispatchTime?
    private var isClosed = false

    // Confined to main.
    private var timer: DispatchSourceTimer?
    private var runLoopSource: CFRunLoopSource?
    private var isStopped = false

    init(pid: pid_t, bundleIdentifier: String?, target: ContextTarget, pasted: String) {
        self.pid = pid
        reader = ComposerReader(
            ax: LiveComposerAccessibility(), pid: pid, bundleIdentifier: bundleIdentifier, target: target, pasted: pasted
        )
    }

    deinit {
        timer?.cancel()
    }

    func start(onEvent: @escaping (Event) -> Void) {
        let armUntil = Date().addingTimeInterval(ComposerWatch.findWindow)
        queue.async { [self] in
            self.onEvent = onEvent
            attemptArm(until: armUntil)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + ComposerWatch.settle,
            repeating: ComposerWatch.pollInterval
        )
        timer.setEventHandler { [weak self] in
            self?.performRead(checkingFocus: true)
        }
        self.timer = timer
        timer.resume()
    }

    func add(pasted: String) {
        queue.async { [self] in
            reader.add(pasted: pasted)
        }
    }

    /// A read at least `delay` from now, joined with any read already due after that.
    func readSoon(after delay: TimeInterval) {
        let deadline = DispatchTime.now() + delay
        queue.async { [self] in
            scheduleRead(at: deadline)
        }
    }

    /// Removes the run-loop source here, so the callback's unretained reference can no longer
    /// fire, and the notifications on the queue, since they message the other app.
    func stop() {
        isStopped = true
        timer?.cancel()
        timer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        queue.async { [self] in
            isClosed = true
            onEvent = nil
            pendingRead?.cancel()
            pendingRead = nil
            pendingReadDeadline = nil
            removeNotifications()
            observer = nil
        }
    }

    // MARK: On the queue

    private func attemptArm(until deadline: Date) {
        guard !isClosed else { return }
        switch reader.arm() {
        case .armed:
            installObserver()
        case .refused(let reason):
            onEvent?(.armFailed(reason))
        case .unavailable:
            guard Date() < deadline else {
                onEvent?(.armFailed(.unreadable))
                return
            }
            queue.asyncAfter(deadline: .now() + Self.armRetryInterval) { [weak self] in
                self?.attemptArm(until: deadline)
            }
        }
    }

    /// Any failure here leaves the poll running, so the watch only loses its payloads and speed.
    private func installObserver() {
        // Declared with an optional dictionary: a notification with no payload may pass null,
        // whatever the header says. Runs on the main run loop, so it only hands off.
        let callback: @convention(c) (AXObserver, AXUIElement, CFString, CFDictionary?, UnsafeMutableRawPointer?) -> Void = {
            _, _, notification, info, refcon in
            guard let refcon else { return }
            Unmanaged<ComposerWatchSession>.fromOpaque(refcon).takeUnretainedValue()
                .handOff(notification: notification, info: info)
        }
        var created: AXObserver?
        guard AXObserverCreateWithInfoCallback(
            pid, unsafeBitCast(callback, to: AXObserverCallbackWithInfo.self), &created
        ) == .success, let created else { return }
        observer = created
        moveNotifications()
        let source = AXObserverGetRunLoopSource(created)
        DispatchQueue.main.async { [self] in
            guard !isStopped else { return }
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    /// The pinned element only: value changes and its destruction.
    private func moveNotifications() {
        removeNotifications()
        guard let observer, let element = reader.pinned else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon)
        _ = AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
        observedElement = element
    }

    private func removeNotifications() {
        guard let observer, let element = observedElement else { return }
        _ = AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
        _ = AXObserverRemoveNotification(observer, element, kAXUIElementDestroyedNotification as CFString)
        observedElement = nil
    }

    private func handleNotification(_ notification: String, info: CFDictionary?, at time: Date) {
        guard !isClosed else { return }
        if notification == kAXUIElementDestroyedNotification {
            performRead(checkingFocus: false)
            return
        }
        onEvent?(.valueChanged(at: time))
        if let userInfo = info as? [String: Any], let deleted = ComposerTextChange.deletedText(from: userInfo) {
            // Text that holds no paste only counts as a delivery, and stays here.
            let holdsPaste = reader.holdsPaste(deleted)
            onEvent?(.deleted(holdsPaste ? deleted : "", holdsPaste: holdsPaste, at: time))
        }
        scheduleRead(at: .now() + ComposerWatch.changeReadDelay)
    }

    /// Only the latest deadline is kept, so each request gets a read at or after its own time.
    private func scheduleRead(at deadline: DispatchTime) {
        guard !isClosed else { return }
        if let pending = pendingReadDeadline, pending >= deadline { return }
        pendingRead?.cancel()
        let read = DispatchWorkItem { [weak self] in
            self?.pendingRead = nil
            self?.pendingReadDeadline = nil
            self?.performRead(checkingFocus: false)
        }
        pendingRead = read
        pendingReadDeadline = deadline
        queue.asyncAfter(deadline: deadline, execute: read)
    }

    private func performRead(checkingFocus: Bool) {
        guard !isClosed, reader.pinned != nil else { return }
        let startedAt = Date()
        let read = reader.read(checkingFocus: checkingFocus)
        if read.replaced { moveNotifications() }
        onEvent?(.read(read, startedAt: startedAt))
    }

    // MARK: On main

    private func handOff(notification: CFString, info: CFDictionary?) {
        let time = Date()
        queue.async { [self] in
            handleNotification(notification as String, info: info, at: time)
        }
    }
}
