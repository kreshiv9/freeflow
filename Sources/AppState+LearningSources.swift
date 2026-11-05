import AppKit
import Carbon
import Foundation
import os.log

private let learningSourcesLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "LearningSources")

// MARK: - Sent-text learning sources

/// The Claude Code hook, the Google search watch and kept cleanup fixes: main-thread glue around
/// the pure code in ClaudeCodeHook, ClaudeHookListener, GoogleSearchWatch and LearningRecords.
/// Everything feeds the same learner and store as Run Log Fix. Prompts, titles and queries stay
/// in memory; logs carry outcome codes and counts only.
///
/// This is the only place that names the real Claude Code settings file, which is read only once
/// the user has connected and written only by Connect and Disconnect.
extension AppState {
    static let claudeCodeSettingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("settings.json")

    static var claudeCodeSettingsDisplayPath: String {
        (claudeCodeSettingsURL.path as NSString).abbreviatingWithTildeInPath
    }

    static var claudeCodeHookSnippet: String {
        ClaudeCodeHookSettings.snippet(appName: AppName.displayName)
    }

    private var claudeCodeHookInstaller: ClaudeCodeHookInstaller {
        ClaudeCodeHookInstaller(settingsURL: Self.claudeCodeSettingsURL, appName: AppName.displayName)
    }

    // MARK: Switches

    /// Listens if and only if learning is on and the user connected Claude Code. Turning
    /// learning off also ends the Google watch at once.
    func syncLearningSources() {
        let wantsListener = learningEnabled && claudeCodeHookConnected
        if wantsListener, claudeHookListener == nil {
            let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let listener = ClaudeHookListener(
                socketURL: ClaudeHookListener.socketURL(applicationSupport: supportDirectory, appName: AppName.displayName)
            ) { [weak self] frame in
                DispatchQueue.main.async {
                    self?.handleClaudeHookFrame(frame)
                }
            }
            if let failure = listener.start() {
                os_log(.error, log: learningSourcesLog, "hook listener did not start: %{public}@", String(describing: failure))
                claudeHookStatusMessage = "FreeFlow could not open its local connection for Claude Code."
            } else {
                claudeHookListener = listener
            }
        } else if !wantsListener, let listener = claudeHookListener {
            listener.stop()
            claudeHookListener = nil
        }
        if !wantsListener {
            claudeHookHealth = ClaudeHookHealth()
            claudeHookNotReporting = false
        }
        if !learningEnabled {
            endGoogleSearchWatch()
        }
    }

    /// Merges the hook entry after the consent click. The sheet shows a failure to write.
    @discardableResult
    func connectClaudeCode() -> ClaudeCodeHookInstaller.Outcome {
        let outcome = claudeCodeHookInstaller.connect()
        os_log(.info, log: learningSourcesLog, "connect claude code: %{public}@", Self.logCode(outcome))
        switch outcome {
        case .done, .alreadyDone:
            claudeCodeHookConnected = true
            claudeHookStatusMessage = nil
            syncLearningSources()
        case .invalidJSON, .unexpectedShape, .ioFailure:
            break
        }
        return outcome
    }

    /// Stops listening even when the entry cannot be removed: a leftover hook does nothing,
    /// because `nc` fails to connect at once.
    func disconnectClaudeCode() {
        let outcome = claudeCodeHookInstaller.disconnect()
        os_log(.info, log: learningSourcesLog, "disconnect claude code: %{public}@", Self.logCode(outcome))
        claudeCodeHookConnected = false
        syncLearningSources()
        switch outcome {
        case .done, .alreadyDone:
            claudeHookStatusMessage = nil
        case .invalidJSON, .unexpectedShape, .ioFailure:
            claudeHookStatusMessage = "FreeFlow stopped listening but could not remove its entry from \(Self.claudeCodeSettingsDisplayPath). The leftover entry does nothing, and you can delete it by hand."
        }
    }

    /// Settings opened. Reads the file only if the user has connected.
    func refreshClaudeCodeHookStatus() {
        guard claudeCodeHookConnected else { return }
        switch claudeCodeHookInstaller.status() {
        case .connected:
            // Tries the listener again if it could not start before.
            syncLearningSources()
            if claudeHookListener != nil || !learningEnabled { claudeHookStatusMessage = nil }
        case .notConnected:
            claudeCodeHookConnected = false
            claudeHookStatusMessage = "FreeFlow's entry is no longer in \(Self.claudeCodeSettingsDisplayPath), so Claude Code is not connected."
            syncLearningSources()
        case .invalid:
            claudeHookStatusMessage = "\(Self.claudeCodeSettingsDisplayPath) is not valid settings JSON, so FreeFlow cannot tell whether its entry is there."
        case .unreadable:
            claudeHookStatusMessage = "FreeFlow could not read \(Self.claudeCodeSettingsDisplayPath)."
        }
    }

    private static func logCode(_ outcome: ClaudeCodeHookInstaller.Outcome) -> String {
        switch outcome {
        case .done: "done"
        case .alreadyDone: "alreadyDone"
        case .invalidJSON: "invalidJSON"
        case .unexpectedShape: "unexpectedShape"
        case .ioFailure: "ioFailure"
        }
    }

    // MARK: Pastes

    /// A paste a source can observe was dispatched. One that was skipped never gets here, so
    /// text that never landed cannot match a prompt, count for the health check or arm a watch.
    func noteDispatchedPaste(entryID: UUID, paste: LearningPaste, websiteDomain: String?) {
        guard learningEnabled else { return }
        dictationRecords.attachPaste(paste, id: entryID, now: Date())
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationRecordRing.lifetime + 1) { [weak self] in
            self?.dictationRecords.removeExpired(now: Date())
        }
        if paste.countsForHookHealth, claudeHookListener != nil {
            claudeHookHealth.notePaste(at: Date())
            DispatchQueue.main.asyncAfter(deadline: .now() + ClaudeHookHealth.window + 1) { [weak self] in
                self?.refreshClaudeHookHealth()
            }
        }
        if paste.destination == .chrome {
            armGoogleSearchWatch(entryID: entryID, paste: paste, websiteDomain: websiteDomain)
        }
    }

    private func refreshClaudeHookHealth() {
        let notReporting = claudeHookListener != nil && claudeHookHealth.isUnhealthy(now: Date())
        if notReporting != claudeHookNotReporting {
            claudeHookNotReporting = notReporting
        }
    }

    /// Undo AI edit (SentTextLearning.cancel), which also ends that dictation's watch.
    func cancelLearningCredit(entryID: UUID) {
        var store = learnedVocabulary
        let cancelled = SentTextLearning.cancel(entryID: entryID, records: &dictationRecords, store: &store)
        if googleSearchWatch?.entryID == entryID {
            endGoogleSearchWatch(keepsEvidence: false)
        }
        if cancelled {
            learnedVocabulary = store
        }
    }

    // MARK: Claude Code

    /// Any valid frame clears the health warning. A prompt is matched off main against the
    /// recent pastes into VS Code, and dropped at once unless it holds one.
    private func handleClaudeHookFrame(_ frame: HookPrompt.Frame) {
        guard learningEnabled, claudeHookListener != nil else { return }
        claudeHookHealth.note(frame)
        refreshClaudeHookHealth()
        guard case .prompt(let final) = frame else { return }
        let pastes = dictationRecords.pastes(into: .vsCode, now: Date())
        guard !pastes.isEmpty else {
            os_log(.info, log: learningSourcesLog, "hook prompt: no recent paste")
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let match = SentTextMatcher.matches(final, in: pastes)
            await self?.learnFromHookPrompt(final, match: match, candidates: pastes.count)
        }
    }

    @MainActor
    private func learnFromHookPrompt(_ final: String, match: SentTextMatcher.Match, candidates: Int) async {
        os_log(
            .info, log: learningSourcesLog, "hook prompt: %d of %d recent pastes matched, %d superseded",
            match.credited.count, candidates, match.superseded.count
        )
        guard learningEnabled else { return }
        for record in dictationRecords.claim(match, now: Date()) {
            await learnFromSentText(record: record, sighting: .hookPrompt, final: final)
        }
    }

    // MARK: Google search

    private func armGoogleSearchWatch(entryID: UUID, paste: LearningPaste, websiteDomain: String?) {
        guard learningEnabled, !IsSecureEventInputEnabled(),
              let application = NSWorkspace.shared.frontmostApplication,
              ContextTarget.isChrome(bundleIdentifier: application.bundleIdentifier),
              GoogleSearchTitle.domainMayArm(bundleIdentifier: application.bundleIdentifier, websiteDomain: websiteDomain) else {
            dictationRecords.clearPaste(id: entryID)
            return
        }
        endGoogleSearchWatch()
        let generation = googleSearchWatchGeneration
        let pid = application.processIdentifier
        let bundleIdentifier = application.bundleIdentifier
        let pressedEnter = paste.pressedEnter
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let focused = GoogleTitlePoller.focusedWindow(pid: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.learningEnabled, self.googleSearchWatchGeneration == generation, let focused,
                      GoogleSearchTitle.arms(
                          bundleIdentifier: bundleIdentifier, websiteDomain: websiteDomain, windowTitle: focused.title
                      ) else {
                    self.dictationRecords.clearPaste(id: entryID)
                    return
                }
                self.googleSearchWatch = GoogleSearchWatch(
                    entryID: entryID, initialTitle: focused.title, pressedEnter: pressedEnter, now: Date()
                )
                let poller = GoogleTitlePoller(window: focused.window)
                self.googleTitlePoller = poller
                poller.start(
                    onTitle: { [weak self] title in
                        DispatchQueue.main.async {
                            self?.handleGoogleTitle(title, generation: generation)
                        }
                    },
                    onClosed: { [weak self] in
                        DispatchQueue.main.async {
                            guard let self, self.googleSearchWatchGeneration == generation else { return }
                            self.endGoogleSearchWatch()
                        }
                    }
                )
            }
        }
    }

    /// Ends the watch and its poller. The paste it held for Signal B goes with them. What its
    /// first results sent counts as kept unless `keepsEvidence` is false. That write waits for
    /// the next main-thread turn: a dictation start ends the watch, and a store change re-ranks
    /// the keyterms that start is about to read.
    func endGoogleSearchWatch(keepsEvidence: Bool = true) {
        googleSearchWatchGeneration &+= 1
        googleTitlePoller?.stop()
        googleTitlePoller = nil
        if let watch = googleSearchWatch {
            dictationRecords.clearPaste(id: watch.entryID)
            if keepsEvidence, let kept = watch.keptSearch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.learningEnabled else { return }
                    var store = self.learnedVocabulary
                    SentTextLearning.applyKept(kept, to: &store, now: Date())
                    self.learnedVocabulary = store
                }
            }
        }
        googleSearchWatch = nil
    }

    private func handleGoogleTitle(_ title: String?, generation: Int) {
        guard googleSearchWatchGeneration == generation, learningEnabled, var watch = googleSearchWatch else { return }
        let now = Date()
        let event = watch.observe(title: title, now: now)
        googleSearchWatch = watch
        guard event != .none else { return }
        let record = dictationRecords.record(id: watch.entryID, now: now)
        switch GoogleSearchWatch.action(for: event, paste: record?.paste) {
        case .nothing:
            break
        case .end(let reason):
            os_log(.info, log: learningSourcesLog, "google watch ended: %{public}@", reason.rawValue)
            endGoogleSearchWatch(keepsEvidence: reason.keepsEvidence)
        case .learn(let sighting, let final):
            guard let record else { return }
            if case .nextResults = sighting {} else { _ = dictationRecords.markObserved(id: record.id) }
            Task { @MainActor [weak self] in
                await self?.learnFromSentText(record: record, sighting: sighting, final: final)
            }
        }
    }

    // MARK: Learning

    /// Runs SentTextLearning for one sighting: the learner off main, the store on main.
    @MainActor
    func learnFromSentText(record: DictationRecord, sighting: SentTextLearning.Sighting, final: String) async {
        guard learningEnabled, let paste = record.paste else { return }
        let confidences = record.confidences()
        let knowledge = learnerKnowledge()
        let judged: SentTextLearning.Verdict? = await Task.detached(priority: .utility) {
            // The word list loads once, off the main thread.
            guard let lexicon = LearningWordList.bundled else { return nil }
            return SentTextLearning.judge(
                sighting, paste: paste, final: final, knowledge: knowledge, lexicon: lexicon, confidences: confidences
            )
        }.value
        guard let verdict = judged else {
            os_log(.error, log: learningSourcesLog, "sent text: word list missing")
            return
        }
        // The switch may have been turned off, everything deleted or the credit cancelled while
        // the learner ran.
        let now = Date()
        guard learningEnabled, dictationRecords.record(id: record.id, now: now)?.paste != nil else { return }

        var store = learnedVocabulary
        let applied = SentTextLearning.apply(verdict, entryID: record.id, sentKeyterms: record.keyterms, to: &store, now: now)
        if applied.touchedStore {
            learnedVocabulary = store
        }
        if googleSearchWatch?.entryID == record.id {
            googleSearchWatch?.note(applied)
        }
        os_log(
            .info, log: learningSourcesLog,
            "sent text: %{public}@; %d new, %d rules, %d cleanup fixes",
            applied.code, applied.change.addedItemIDs.count, applied.change.addedRules.count, verdict.fixes.count
        )
        if applied.change.hasLearned {
            offerLearnedUndo(applied.change)
        }
    }
}
