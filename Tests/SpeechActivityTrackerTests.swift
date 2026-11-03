enum SpeechActivityTrackerTests {
    static func run() {
        testPureSilence()
        testSteadyNoiseIsNotSpeech()
        testShortWordCountsAsSpeech()
        testIsolatedTransientsDoNotCount()
        testLongSpeechWithPauses()
        testSpeechAfterLongSilentLeadIn()
        testQuietSpeakerAboveQuietRoom()
        testSpeechFromFirstBufferIsNotMaskedByItsOwnFloor()
        testDigitalSilenceDoesNotSeedTheFloor()
        testNoiseStepIsAbsorbedByTheWindow()
        testSilenceSinceLastSpeechAccounting()
        testResetClearsState()
        testInvalidSamplesAreTolerated()
    }

    /// Feeds synthetic RMS values in fixed-size buffers. Sums of 20.0 are
    /// exact in Double, so durations can be compared with expectEqual.
    private static func feed(
        _ tracker: inout SpeechActivityTracker,
        rms: Float,
        milliseconds: Double,
        bufferMilliseconds: Double = 20
    ) {
        var remaining = milliseconds
        while remaining > 0 {
            tracker.track(rms: rms, durationMilliseconds: bufferMilliseconds)
            remaining -= bufferMilliseconds
        }
    }

    private static func testPureSilence() {
        var tracker = SpeechActivityTracker()
        feed(&tracker, rms: 0, milliseconds: 2000)
        TestSupport.expect(!tracker.hasSpeech, "Digital silence must not count as speech")
        TestSupport.expectEqual(tracker.speechMilliseconds, 0)
        TestSupport.expectEqual(tracker.totalMilliseconds, 2000)
        TestSupport.expectEqual(tracker.peakRMS, 0)
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, 2000)
        TestSupport.expectEqual(tracker.noiseFloorRMS, nil)
        TestSupport.expectEqual(tracker.speechThresholdRMS, SpeechActivityTracker.absoluteFloorRMS)
    }

    private static func testSteadyNoiseIsNotSpeech() {
        var fan = SpeechActivityTracker()
        feed(&fan, rms: 0.006, milliseconds: 3000)
        TestSupport.expect(!fan.hasSpeech, "A steady fan must not count as speech")
        TestSupport.expectEqual(fan.speechMilliseconds, 0)
        TestSupport.expect(fan.peakRMS >= SpeechActivityTracker.absoluteFloorRMS, "Fan is above the absolute floor")
        TestSupport.expectEqual(fan.noiseFloorRMS, 0.006)

        var quietRoom = SpeechActivityTracker()
        for index in 0..<150 {
            quietRoom.track(rms: index.isMultiple(of: 2) ? 0.0036 : 0.0044, durationMilliseconds: 20)
        }
        TestSupport.expect(!quietRoom.hasSpeech, "Fluctuating room tone must not count as speech")
        TestSupport.expectEqual(quietRoom.speechMilliseconds, 0)
        TestSupport.expect(quietRoom.peakRMS >= SpeechActivityTracker.absoluteFloorRMS, "Room tone is above the absolute floor")
        TestSupport.expectEqual(quietRoom.noiseFloorRMS, 0.0036)

        var loudFan = SpeechActivityTracker()
        for index in 0..<150 {
            loudFan.track(rms: index.isMultiple(of: 2) ? 0.009 : 0.011, durationMilliseconds: 20)
        }
        TestSupport.expect(!loudFan.hasSpeech, "A loud fan under the threshold cap must not count as speech")
        TestSupport.expectEqual(loudFan.speechMilliseconds, 0)
        TestSupport.expect(loudFan.peakRMS >= SpeechActivityTracker.absoluteFloorRMS, "Loud fan is above the absolute floor")
        TestSupport.expectEqual(loudFan.noiseFloorRMS, 0.009)
    }

    private static func testShortWordCountsAsSpeech() {
        var tracker = SpeechActivityTracker()
        feed(&tracker, rms: 0.001, milliseconds: 400)
        feed(&tracker, rms: 0.05, milliseconds: 300)
        feed(&tracker, rms: 0.001, milliseconds: 300)
        TestSupport.expect(tracker.hasSpeech, "A short word at normal level must count as speech")
        TestSupport.expectEqual(tracker.speechMilliseconds, 300)
        TestSupport.expectEqual(tracker.peakRMS, 0.05)
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, 300)
        TestSupport.expectEqual(tracker.totalMilliseconds, 1000)
    }

    private static func testIsolatedTransientsDoNotCount() {
        var tracker = SpeechActivityTracker()
        feed(&tracker, rms: 0.001, milliseconds: 400)
        feed(&tracker, rms: 0.2, milliseconds: 60)
        feed(&tracker, rms: 0.001, milliseconds: 500)
        TestSupport.expect(!tracker.hasSpeech, "A 60 ms transient is not speech")
        TestSupport.expectEqual(tracker.speechMilliseconds, 0)
        TestSupport.expectEqual(tracker.peakRMS, 0.2)
        TestSupport.expectEqual(tracker.totalMilliseconds, 960)
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, 960)

        for _ in 0..<12 {
            feed(&tracker, rms: 0.2, milliseconds: 20)
            feed(&tracker, rms: 0.001, milliseconds: 180)
        }
        TestSupport.expect(!tracker.hasSpeech, "Repeated clicks must not accumulate into speech")
        TestSupport.expectEqual(tracker.speechMilliseconds, 0)
    }

    private static func testLongSpeechWithPauses() {
        var tracker = SpeechActivityTracker()
        feed(&tracker, rms: 0.002, milliseconds: 200)
        for _ in 0..<5 {
            feed(&tracker, rms: 0.03, milliseconds: 400)
            feed(&tracker, rms: 0.002, milliseconds: 300)
        }
        TestSupport.expect(tracker.hasSpeech, "Phrases separated by pauses count as speech")
        TestSupport.expectEqual(tracker.speechMilliseconds, 2000)
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, 300)
    }

    private static func testSpeechAfterLongSilentLeadIn() {
        var tracker = SpeechActivityTracker()
        feed(&tracker, rms: 0.0015, milliseconds: 10_000)
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, 10_000)
        TestSupport.expect(!tracker.hasSpeech, "A quiet lead-in is not speech")

        feed(&tracker, rms: 0.02, milliseconds: 500)
        TestSupport.expect(tracker.hasSpeech, "Speech after a long quiet lead-in must still be detected")
        TestSupport.expectEqual(tracker.speechMilliseconds, 500)
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, 0)
    }

    private static func testQuietSpeakerAboveQuietRoom() {
        var tracker = SpeechActivityTracker()
        feed(&tracker, rms: 0.001, milliseconds: 500)
        feed(&tracker, rms: 0.008, milliseconds: 400)
        TestSupport.expect(tracker.hasSpeech, "Quiet speech above a quiet room must count as speech")
    }

    private static func testSpeechFromFirstBufferIsNotMaskedByItsOwnFloor() {
        var tracker = SpeechActivityTracker()
        feed(&tracker, rms: 0.03, milliseconds: 300)
        TestSupport.expect(tracker.hasSpeech, "Speech present from the first buffer must not mask itself")
        TestSupport.expectEqual(tracker.speechMilliseconds, 300)
        TestSupport.expectEqual(tracker.noiseFloorRMS, 0.03)
        TestSupport.expectEqual(
            tracker.speechThresholdRMS,
            SpeechActivityTracker.maximumNoiseFloorRMS * SpeechActivityTracker.noiseFloorRatio
        )
    }

    private static func testDigitalSilenceDoesNotSeedTheFloor() {
        var tracker = SpeechActivityTracker()
        feed(&tracker, rms: 0, milliseconds: 100)
        feed(&tracker, rms: 0.007, milliseconds: 2000)
        TestSupport.expect(!tracker.hasSpeech, "Noise after a digital-silence warm-up must not count as speech")
        TestSupport.expectEqual(tracker.speechMilliseconds, 0)
        TestSupport.expectEqual(tracker.noiseFloorRMS, 0.007)
        TestSupport.expectEqual(tracker.totalMilliseconds, 2100)
    }

    private static func testNoiseStepIsAbsorbedByTheWindow() {
        var tracker = SpeechActivityTracker()
        feed(&tracker, rms: 0.001, milliseconds: 100)
        feed(&tracker, rms: 0.006, milliseconds: 500)
        // Documented safe-direction false positive: the step is louder than the
        // floor the quiet lead-in established, so it is counted at first.
        TestSupport.expect(tracker.hasSpeech, "A noise step is initially counted as speech")

        feed(&tracker, rms: 0.006, milliseconds: 11_500)
        TestSupport.expect(tracker.speechMilliseconds <= 1500, "Counting stops once the quiet buffers age out of the window")
        TestSupport.expect(tracker.silenceMillisecondsSinceLastSpeech >= 10_000, "Steady noise after the step is silence")
    }

    private static func testSilenceSinceLastSpeechAccounting() {
        var tracker = SpeechActivityTracker()
        feed(&tracker, rms: 0.001, milliseconds: 300)
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, 300)
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, tracker.totalMilliseconds)

        feed(&tracker, rms: 0.05, milliseconds: 200)
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, 0)

        var expectedSilence: Double = 0
        for _ in 0..<75 {
            tracker.track(rms: 0.001, durationMilliseconds: 20)
            expectedSilence += 20
            TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, expectedSilence)
        }
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, 1500)
        TestSupport.expectEqual(tracker.totalMilliseconds, 2000)

        tracker.track(rms: 0.2, durationMilliseconds: 20)
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, 1520)
        feed(&tracker, rms: 0.001, milliseconds: 180)
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, 1700)

        feed(&tracker, rms: 0.05, milliseconds: 200)
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, 0)
    }

    private static func testResetClearsState() {
        var tracker = SpeechActivityTracker()
        feed(&tracker, rms: 0.001, milliseconds: 200)
        feed(&tracker, rms: 0.05, milliseconds: 300)
        TestSupport.expect(tracker.hasSpeech, "Fixture must contain speech before reset")

        tracker.reset()
        TestSupport.expectEqual(tracker, SpeechActivityTracker())
        TestSupport.expect(!tracker.hasSpeech, "Reset must clear speech")
        TestSupport.expectEqual(tracker.totalMilliseconds, 0)
        TestSupport.expectEqual(tracker.peakRMS, 0)
        TestSupport.expectEqual(tracker.silenceMillisecondsSinceLastSpeech, 0)
        TestSupport.expectEqual(tracker.noiseFloorRMS, nil)

        feed(&tracker, rms: 0.05, milliseconds: 300)
        TestSupport.expect(tracker.hasSpeech, "A reset tracker must detect speech again")
    }

    private static func testInvalidSamplesAreTolerated() {
        var tracker = SpeechActivityTracker()
        feed(&tracker, rms: 0.001, milliseconds: 100)
        let before = tracker

        tracker.track(rms: 0.5, durationMilliseconds: 0)
        tracker.track(rms: 0.5, durationMilliseconds: -5)
        tracker.track(rms: 0.5, durationMilliseconds: .nan)
        tracker.track(rms: 0.5, durationMilliseconds: .infinity)
        TestSupport.expectEqual(tracker, before)

        tracker.track(rms: .nan, durationMilliseconds: 20)
        tracker.track(rms: -1, durationMilliseconds: 20)
        tracker.track(rms: .infinity, durationMilliseconds: 20)
        TestSupport.expectEqual(tracker.totalMilliseconds, 160)
        TestSupport.expectEqual(tracker.peakRMS, before.peakRMS)
        TestSupport.expect(!tracker.hasSpeech, "Invalid levels never count as speech")
    }
}
