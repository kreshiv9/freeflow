import AppKit
import Carbon
import Combine
import Foundation
import os.log

private let composerWatchLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "ComposerWatch")

// MARK: - Composer watch

/// The ChatGPT composer and the Claude Code panel fallback: main-thread glue around the pure
/// code in ComposerWatch and the Accessibility reads in ComposerWatchSession. A confirmed send
/// feeds the same matcher, learner and store as the hook. Composer text stays in memory while a
/// watch is armed; logs and counters carry outcome codes and counts only.
extension AppState {
    /// Every FreeFlow write passes here as it is scheduled. Only the paste a dictation just
    /// announced can leave a watch running.
    func noteFreeFlowWrite() {
        finishComposerEvent(composerWatch?.noteFreeFlowWrite(isTrackedPaste: composerWatchExpectsPaste) ?? .none)
        composerWatchExpectsPaste = false
    }

    /// On the event tap's path, after its consume decision: nothing here waits or reads
    /// Accessibility, and it returns at once when no watch is armed.
    func handleComposerKeyActivity(_ activity: KeyActivity) {
        guard composerWatch != nil else { return }
        let event: ComposerWatch.Event = composerWatch?.note(activity, now: Date()) ?? .none
        composerWatchSession?.readSoon(after: ComposerWatch.keyReadDelay)
        finishComposerEvent(event)
    }

    /// A dispatched paste the gate allows: it joins the composer's watch, or starts one. The
    /// watch exists before the session arms, so keys from now on count. The target comes from
    /// when the dictation started, so another app may be frontmost by now; that app gets no
    /// session, and the paste, which went to it, is forgotten.
    func armComposerWatch(entryID: UUID, paste: LearningPaste, target: ContextTarget) {
        guard learningEnabled, !IsSecureEventInputEnabled(), hotkeyManager.isTapInstalled else {
            // No watch can run, the same as one that ended at once.
            let keepsPaste = ComposerWatchGate.keepsPastes(target: target, hookIsListening: claudeHookListener != nil, after: .secureInput)
            if !keepsPaste { dictationRecords.clearPaste(id: entryID) }
            return
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              ComposerWatchGate.isTargetApp(target, bundleIdentifier: application.bundleIdentifier) else {
            dictationRecords.clearPaste(id: entryID)
            endComposerWatch(.appSwitch)
            return
        }
        let now = Date()
        let pid = application.processIdentifier
        if let session = composerWatchSession, session.pid == pid, composerWatch?.target == target {
            composerWatch?.addPaste(entryID: entryID, now: now)
            session.add(pasted: paste.pasted)
            return
        }
        endComposerWatch(.appSwitch)
        let generation = composerWatchGeneration
        composerWatch = ComposerWatch(entryID: entryID, target: target, now: now)
        let session = ComposerWatchSession(
            pid: pid, bundleIdentifier: application.bundleIdentifier, target: target, pasted: paste.pasted
        )
        composerWatchSession = session
        composerWatchActivation = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let self, self.composerWatchGeneration == generation, activated?.processIdentifier != pid else { return }
                self.endComposerWatch(.appSwitch)
            }
        session.start { [weak self] event in
            DispatchQueue.main.async {
                self?.handleComposerSessionEvent(event, generation: generation)
            }
        }
    }

    private func handleComposerSessionEvent(_ event: ComposerWatchSession.Event, generation: Int) {
        guard composerWatchGeneration == generation, composerWatch != nil else { return }
        guard !IsSecureEventInputEnabled() else {
            endComposerWatch(.secureInput)
            return
        }
        switch event {
        case .armFailed(let reason):
            endComposerWatch(reason)
        case .valueChanged(let at):
            composerWatch?.noteValueChanged(at: at)
        case .deleted(let text, let holdsPaste, let at):
            composerWatch?.note(deleted: text, holdsPaste: holdsPaste, now: at)
        case .read(let read, let startedAt):
            let now = Date()
            let sinceMouseDown = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
            let result: ComposerWatch.Event = composerWatch?.observe(
                read, startedAt: startedAt, mouseDownAt: now.addingTimeInterval(-sinceMouseDown), now: now
            ) ?? .none
            finishComposerEvent(result)
        }
    }

    private func finishComposerEvent(_ event: ComposerWatch.Event) {
        switch event {
        case .none:
            break
        case .ended(let reason):
            endComposerWatch(reason)
        case .sent(let final, let fromPayload):
            guard let entryIDs = composerWatch?.entryIDs, let target = composerWatch?.target else { return }
            closeComposerWatch(outcome: fromPayload ? "sentFromPayload" : "sent", keepsPastes: true, counts: true)
            Task { @MainActor [weak self] in
                await self?.learnFromComposerSend(final, entryIDs: entryIDs, target: target)
            }
        }
    }

    /// Ends the watch and its session; the composer text goes with them, and so do its pastes
    /// unless the hook can still match them.
    func endComposerWatch(_ reason: ComposerWatch.EndReason, counts: Bool = true) {
        let keepsPastes = composerWatch.map {
            ComposerWatchGate.keepsPastes(target: $0.target, hookIsListening: claudeHookListener != nil, after: reason)
        } ?? false
        closeComposerWatch(outcome: reason.rawValue, keepsPastes: keepsPastes, counts: counts)
    }

    /// The counters wait for the next main-thread turn: a store change re-ranks the keyterms,
    /// and this can run on the tap's path or just before a dictation start reads them.
    private func closeComposerWatch(outcome: String, keepsPastes: Bool, counts: Bool) {
        composerWatchGeneration &+= 1
        composerWatchSession?.stop()
        composerWatchSession = nil
        composerWatchActivation = nil
        guard let watch = composerWatch else { return }
        composerWatch = nil
        if !keepsPastes {
            for id in watch.entryIDs { dictationRecords.clearPaste(id: id) }
        }
        os_log(
            .info, log: composerWatchLog, "composer watch ended: %{public}@; %d replaced, %d payloads",
            outcome, watch.replacements, watch.payloads
        )
        guard counts else { return }
        let replacements = watch.replacements, payloads = watch.payloads
        DispatchQueue.main.async { [weak self] in
            guard let self, self.learningEnabled else { return }
            var store = self.learnedVocabulary
            store.countComposerWatch(outcome: outcome, replacements: replacements, payloads: payloads)
            self.learnedVocabulary = store
        }
    }

    /// One send: each paste it holds keeps its own record and is judged against its own span of
    /// the composer, and the rest are forgotten. A paste with no span teaches nothing, since the
    /// whole composer holds typed text and other dictations. `claim` gives the credit once, so a
    /// hook prompt seen for the same send learns nothing twice.
    @MainActor
    private func learnFromComposerSend(_ final: String, entryIDs: [UUID], target: ContextTarget) async {
        let pastes = dictationRecords.pastes(ids: entryIDs, now: Date())
        let (match, windows) = await Task.detached(priority: .utility) { () -> (SentTextMatcher.Match, [UUID: String]) in
            let normalizedFinal = ComposerText.normalized(final)
            let normalizedPastes = pastes.map { (id: $0.id, pasted: ComposerText.normalized($0.pasted)) }
            let match = SentTextMatcher.matches(normalizedFinal, in: normalizedPastes)
            let credited = pastes.filter { match.credited.contains($0.id) }
            return (match, ComposerText.windows(of: credited, in: final))
        }.value
        os_log(
            .info, log: composerWatchLog, "composer send: %d of %d pastes matched, %d located, %d superseded",
            match.credited.count, pastes.count, windows.count, match.superseded.count
        )
        if learningEnabled {
            if !match.superseded.isEmpty {
                var store = learnedVocabulary
                store.countReDictations(match.superseded.count)
                learnedVocabulary = store
            }
            let sighting = SentTextLearning.Sighting.composerSend(ComposerWatchGate.source(for: target))
            for record in dictationRecords.claim(match, now: Date()) {
                guard let window = windows[record.id] else { continue }
                await learnFromSentText(record: record, sighting: sighting, final: window)
            }
        }
        for id in entryIDs { dictationRecords.clearPaste(id: id) }
    }
}
