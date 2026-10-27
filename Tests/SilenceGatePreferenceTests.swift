import Foundation

enum SilenceGatePreferenceTests {
    static func run() {
        testDefaultAndStorage()
        testStopTimeDecision()
        testSkippedRowStatuses()
    }

    private static func testDefaultAndStorage() {
        let suite = "FreeFlowTests.SilenceGate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expect(SilenceGatePreference.defaultEnabled, "The silence gate must default to on")
        TestSupport.expectEqual(SilenceGatePreference.storageKey, "silence_gate_enabled")
        TestSupport.expect(SilenceGatePreference.load(from: defaults), "A missing preference must keep the gate on")
        TestSupport.expect(defaults.object(forKey: SilenceGatePreference.storageKey) == nil, "Loading the default must not persist a choice")

        for enabled in [true, false] {
            defaults.set(enabled, forKey: SilenceGatePreference.storageKey)
            let reloaded = UserDefaults(suiteName: suite)!
            TestSupport.expectEqual(SilenceGatePreference.load(from: reloaded), enabled)
            TestSupport.expectEqual(reloaded.object(forKey: SilenceGatePreference.storageKey) as? Bool, enabled)
        }

        defaults.set("invalid", forKey: SilenceGatePreference.storageKey)
        TestSupport.expect(SilenceGatePreference.load(from: defaults), "An invalid saved value must default to on")

        defaults.removeObject(forKey: SilenceGatePreference.storageKey)
        TestSupport.expect(SilenceGatePreference.load(from: defaults), "Removing a saved choice must restore on")
    }

    /// Synthetic RMS fixtures: a quiet room never counts as speech, a spoken
    /// word always does. The gate may only skip the provider for the former.
    private static func testStopTimeDecision() {
        var silent = SpeechActivityTracker()
        for _ in 0..<50 { silent.track(rms: 0.0005, durationMilliseconds: 20) }
        TestSupport.expect(!silent.hasSpeech, "Fixture: a quiet room must not count as speech")

        var spoken = SpeechActivityTracker()
        for _ in 0..<10 { spoken.track(rms: 0.0005, durationMilliseconds: 20) }
        for _ in 0..<20 { spoken.track(rms: 0.05, durationMilliseconds: 20) }
        TestSupport.expect(spoken.hasSpeech, "Fixture: a spoken word must count as speech")

        TestSupport.expect(
            SilenceGatePreference.shouldSkipTranscription(enabled: true, speechActivity: silent),
            "The gate skips the provider when it is on and no speech was heard"
        )
        TestSupport.expect(
            !SilenceGatePreference.shouldSkipTranscription(enabled: true, speechActivity: spoken),
            "Speech is always transcribed"
        )
        TestSupport.expect(
            !SilenceGatePreference.shouldSkipTranscription(enabled: false, speechActivity: silent),
            "With the gate off, silent audio still goes to the provider"
        )
        TestSupport.expect(
            !SilenceGatePreference.shouldSkipTranscription(enabled: false, speechActivity: spoken),
            "With the gate off, speech still goes to the provider"
        )
    }

    /// The Run Log keys its "Transcription skipped" wording on the stored
    /// processing status, so the strings are pinned here. The stop path that
    /// writes them needs live capture and is covered by the manual test.
    private static func testSkippedRowStatuses() {
        TestSupport.expectEqual(SilenceGatePreference.skippedStatusText, "No speech detected")
        TestSupport.expectEqual(SilenceGatePreference.skippedProcessingStatus, "Skipped: no speech detected")
        TestSupport.expect(
            !SilenceGatePreference.skippedProcessingStatus.hasPrefix("Error:"),
            "A gated dictation must not render as an error row"
        )
    }
}
