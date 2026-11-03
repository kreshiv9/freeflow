import Foundation

enum HandsFreeAutoStopTests {
    static func run() {
        testDefaultAndStorage()
        testSilenceStopsOnlyHandsFree()
        testConfigurableTimeout()
        testMaximumDurationWarningFiresOnce()
        testMaximumDurationStopsWithoutWarning()
    }

    private static func testDefaultAndStorage() {
        let suite = "FreeFlowTests.HandsFreeAutoStop.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(HandsFreeAutoStop.silenceTimeoutStorageKey, "hands_free_silence_timeout_seconds")
        TestSupport.expectEqual(HandsFreeAutoStop.defaultSilenceTimeoutSeconds, 15)
        TestSupport.expectEqual(HandsFreeAutoStop.silenceTimeoutRange, 5...60)
        TestSupport.expectEqual(HandsFreeAutoStop.loadSilenceTimeoutSeconds(from: defaults), 15)
        TestSupport.expect(
            defaults.object(forKey: HandsFreeAutoStop.silenceTimeoutStorageKey) == nil,
            "Loading the default must not persist a choice"
        )

        defaults.set(30, forKey: HandsFreeAutoStop.silenceTimeoutStorageKey)
        let reloaded = UserDefaults(suiteName: suite)!
        TestSupport.expectEqual(HandsFreeAutoStop.loadSilenceTimeoutSeconds(from: reloaded), 30)
        TestSupport.expectEqual(reloaded.object(forKey: HandsFreeAutoStop.silenceTimeoutStorageKey) as? Int, 30)

        defaults.set(2, forKey: HandsFreeAutoStop.silenceTimeoutStorageKey)
        TestSupport.expectEqual(HandsFreeAutoStop.loadSilenceTimeoutSeconds(from: defaults), 5)
        defaults.set(999, forKey: HandsFreeAutoStop.silenceTimeoutStorageKey)
        TestSupport.expectEqual(HandsFreeAutoStop.loadSilenceTimeoutSeconds(from: defaults), 60)
        defaults.set("ten", forKey: HandsFreeAutoStop.silenceTimeoutStorageKey)
        TestSupport.expectEqual(HandsFreeAutoStop.loadSilenceTimeoutSeconds(from: defaults), 15)
        defaults.removeObject(forKey: HandsFreeAutoStop.silenceTimeoutStorageKey)
        TestSupport.expectEqual(HandsFreeAutoStop.loadSilenceTimeoutSeconds(from: defaults), 15)

        TestSupport.expectEqual(HandsFreeAutoStop.clamp(0), 5)
        TestSupport.expectEqual(HandsFreeAutoStop.clamp(61), 60)
        TestSupport.expectEqual(HandsFreeAutoStop.clamp(15), 15)
        TestSupport.expectEqual(HandsFreeAutoStop(silenceTimeoutSeconds: 1).silenceTimeoutMilliseconds, 5_000)
    }

    private static func testSilenceStopsOnlyHandsFree() {
        var monitor = HandsFreeAutoStop(silenceTimeoutSeconds: 15)
        TestSupport.expectEqual(
            monitor.evaluate(mode: .hold, elapsedMilliseconds: 60_000, silenceMilliseconds: 60_000),
            .continueRecording
        )
        TestSupport.expectEqual(
            monitor.evaluate(mode: .toggle, elapsedMilliseconds: 14_999, silenceMilliseconds: 14_999),
            .continueRecording
        )
        TestSupport.expectEqual(
            monitor.evaluate(mode: .toggle, elapsedMilliseconds: 15_000, silenceMilliseconds: 15_000),
            .stopForSilence
        )
        // Spoke recently.
        TestSupport.expectEqual(
            monitor.evaluate(mode: .toggle, elapsedMilliseconds: 30_000, silenceMilliseconds: 14_000),
            .continueRecording
        )
        // Minimum session length guard.
        TestSupport.expectEqual(
            monitor.evaluate(mode: .toggle, elapsedMilliseconds: 10_000, silenceMilliseconds: 15_000),
            .continueRecording
        )
    }

    private static func testConfigurableTimeout() {
        var short = HandsFreeAutoStop(silenceTimeoutSeconds: 5)
        TestSupport.expectEqual(
            short.evaluate(mode: .toggle, elapsedMilliseconds: 4_999, silenceMilliseconds: 4_999),
            .continueRecording
        )
        TestSupport.expectEqual(
            short.evaluate(mode: .toggle, elapsedMilliseconds: 5_000, silenceMilliseconds: 5_000),
            .stopForSilence
        )
        TestSupport.expectEqual(
            short.evaluate(mode: .hold, elapsedMilliseconds: 60_000, silenceMilliseconds: 60_000),
            .continueRecording
        )

        var long = HandsFreeAutoStop(silenceTimeoutSeconds: 60)
        TestSupport.expectEqual(
            long.evaluate(mode: .toggle, elapsedMilliseconds: 59_999, silenceMilliseconds: 59_999),
            .continueRecording
        )
        TestSupport.expectEqual(
            long.evaluate(mode: .toggle, elapsedMilliseconds: 60_000, silenceMilliseconds: 60_000),
            .stopForSilence
        )
    }

    private static func testMaximumDurationWarningFiresOnce() {
        TestSupport.expectEqual(HandsFreeAutoStop.warningMilliseconds, 1_140_000)
        TestSupport.expectEqual(HandsFreeAutoStop.maximumMilliseconds, 1_200_000)
        TestSupport.expectEqual(HandsFreeAutoStop.warningStatusText, "Dictation stops at 20 minutes")

        for mode in [RecordingTriggerMode.hold, .toggle] {
            var monitor = HandsFreeAutoStop(silenceTimeoutSeconds: 15)
            TestSupport.expectEqual(
                monitor.evaluate(mode: mode, elapsedMilliseconds: 1_139_999, silenceMilliseconds: 0),
                .continueRecording
            )
            TestSupport.expectEqual(
                monitor.evaluate(mode: mode, elapsedMilliseconds: 1_140_000, silenceMilliseconds: 0),
                .warn
            )
            TestSupport.expect(monitor.hasWarned, "The warning must be remembered for the rest of the recording")
            TestSupport.expectEqual(
                monitor.evaluate(mode: mode, elapsedMilliseconds: 1_140_250, silenceMilliseconds: 0),
                .continueRecording
            )
            TestSupport.expectEqual(
                monitor.evaluate(mode: mode, elapsedMilliseconds: 1_170_000, silenceMilliseconds: 0),
                .continueRecording
            )
            TestSupport.expectEqual(
                monitor.evaluate(mode: mode, elapsedMilliseconds: 1_200_000, silenceMilliseconds: 0),
                .stopAtMaximumDuration
            )
        }
    }

    private static func testMaximumDurationStopsWithoutWarning() {
        // A skipped warn tick never blocks the cap.
        var fresh = HandsFreeAutoStop(silenceTimeoutSeconds: 15)
        TestSupport.expectEqual(
            fresh.evaluate(mode: .hold, elapsedMilliseconds: 1_200_000, silenceMilliseconds: 0),
            .stopAtMaximumDuration
        )
        // The cap takes precedence over silence for a deterministic log reason.
        var silent = HandsFreeAutoStop(silenceTimeoutSeconds: 15)
        TestSupport.expectEqual(
            silent.evaluate(mode: .toggle, elapsedMilliseconds: 1_200_000, silenceMilliseconds: 1_200_000),
            .stopAtMaximumDuration
        )
    }
}
