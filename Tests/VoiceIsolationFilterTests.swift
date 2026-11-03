import AVFAudio
import Foundation

/// Voice isolation preference and filter guards. The filter runs Apple's
/// AUSoundIsolation in an offline engine on synthetic in-memory signals only:
/// no microphone, no files, no network. Noise-removal quality is not asserted
/// (the model treats synthetic tones as noise); that is a manual check.
enum VoiceIsolationFilterTests {
    static func run() {
        testPreferenceDefaultsAndStorage()
        testPreferenceLabelsAndAvailability()
        testSupportedFormats()
        runFilterTests()
    }

    /// Three engines are built once and reset between cases to keep this fast.
    /// CI VMs and older systems may not run the model, so these skip there.
    private static func runFilterTests() {
        guard VoiceIsolationFilter.isAvailable,
              let dry = VoiceIsolationFilter(wetDryPercent: 0),
              let light = VoiceIsolationFilter(wetDryPercent: 70),
              let strong = VoiceIsolationFilter(wetDryPercent: 100) else {
            print("VoiceIsolationFilterTests: skipped filter tests (needs macOS 15 and Apple's AUSoundIsolation)")
            return
        }
        testEffectIsConfigured(dry, wetDryPercent: 0)
        testEffectIsConfigured(light, wetDryPercent: 70)
        testEffectIsConfigured(strong, wetDryPercent: 100)
        testDryPathIsLatencyAligned(dry)
        testOutputLengthEqualsInput(dry, name: "wet 0")
        testOutputLengthEqualsInput(light, name: "wet 70")
        testOutputLengthEqualsInput(strong, name: "wet 100")
        testShortRecordingIsReturnedByFinish(dry)
        testResetClearsCarryOver(dry, name: "wet 0")
        testResetClearsCarryOver(strong, name: "wet 100")
        testUnemittedInputIsTheRawRemainder(dry, name: "wet 0")
        testUnemittedInputIsTheRawRemainder(strong, name: "wet 100")
        testResetAfterAbandonedRunMatchesCleanRun(strong, name: "wet 100")
        testStrongOnHarmonicSignalStaysBounded(strong)
        testWetMixReachesTheModel(dry: dry, light: light, strong: strong)
        testMisuse(dry)
    }

    // MARK: Fixtures

    /// The native capture request: Float32 mono interleaved at 48 kHz.
    private static let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: true
    )!

    private static let chunkPattern = [480, 4_800, 37, 1_024]

    private static func tone(_ frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        let step = 2 * Double.pi * frequency / 48_000
        return (0..<frames).map { Float(amplitude * sin(step * Double($0))) }
    }

    /// Seeded, platform-independent noise (64-bit LCG), RMS about 0.1.
    private static func noise(frames: Int, seed: UInt64 = 0x5EED) -> [Float] {
        var state = seed
        return (0..<frames).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53)
            return Float((unit - 0.5) * 0.35)
        }
    }

    /// A voiced, speech-like probe: 140 Hz with 12 harmonics, a 3 Hz
    /// syllable envelope and a little seeded noise.
    private static func speechLike(frames: Int) -> [Float] {
        let voiced = (0..<frames).map { index -> Float in
            let time = Double(index) / 48_000
            let envelope = 0.5 + 0.5 * sin(2 * .pi * 3 * time)
            let harmonics = (1...12).reduce(0.0) { sum, harmonic in
                sum + sin(2 * .pi * 140 * Double(harmonic) * time + Double(harmonic)) / Double(harmonic)
            }
            return Float(0.12 * envelope * harmonics)
        }
        return zip(voiced, noise(frames: frames, seed: 99)).map { $0 + 0.15 * $1 }
    }

    private static func samples(of buffer: AVAudioPCMBuffer?) -> [Float] {
        guard let buffer else { return [] }
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private static func buffer(_ samples: ArraySlice<Float>, format: AVAudioFormat = captureFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for (index, value) in samples.enumerated() {
            channel[index] = value
        }
        return buffer
    }

    /// A buffer of `frames` frames in any format; its contents are never read.
    private static func blankBuffer(_ format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1))!
        buffer.frameLength = frames
        return buffer
    }

    /// Streams `samples` through the filter in the given chunk sizes (cycled),
    /// then optionally finishes. Also returns each emitted buffer's format.
    private static func stream(
        _ samples: [Float],
        through filter: VoiceIsolationFilter,
        chunkSizes: [Int],
        format: AVAudioFormat = captureFormat,
        finish: Bool = true
    ) -> (samples: [Float], formats: [AVAudioFormat]) {
        var output: [Float] = []
        var formats: [AVAudioFormat] = []
        let collect: (AVAudioPCMBuffer) -> Void = { chunk in
            formats.append(chunk.format)
            output += UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))
        }
        var offset = 0
        var chunkIndex = 0
        while offset < samples.count {
            let count = min(chunkSizes[chunkIndex % chunkSizes.count], samples.count - offset)
            try! filter.process(buffer(samples[offset..<(offset + count)], format: format), emit: collect)
            offset += count
            chunkIndex += 1
        }
        if finish {
            try! filter.finish(emit: collect)
        }
        return (output, formats)
    }

    private static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    private static func maxDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    private static func rmsDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0 }
        let sum = zip(lhs, rhs).reduce(0.0) { $0 + Double($1.0 - $1.1) * Double($1.0 - $1.1) }
        return Float((sum / Double(count)).squareRoot())
    }

    /// The effect reports the High Quality Voice model and the given wet mix.
    private static func expectConfigured(_ filter: VoiceIsolationFilter, wetDryPercent: Float, _ context: String) {
        guard #available(macOS 15, *) else { return }
        let model = filter.appliedSoundToIsolate
        TestSupport.expect(
            model == Int(kAUSoundIsolationSoundType_HighQualityVoice),
            "\(context): the effect must run the High Quality Voice model, got \(String(describing: model))"
        )
        let wet = filter.appliedWetDryPercent
        TestSupport.expect(
            wet == wetDryPercent,
            "\(context): the effect's wet/dry mix must be \(wetDryPercent)%, got \(String(describing: wet))"
        )
    }

    private static func expectFilterError(
        _ expected: VoiceIsolationFilter.FilterError,
        _ message: String,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            TestSupport.expect(false, "\(message): expected \(expected), nothing was thrown")
        } catch let error as VoiceIsolationFilter.FilterError {
            TestSupport.expect(error == expected, "\(message): expected \(expected), got \(error)")
        } catch {
            TestSupport.expect(false, "\(message): expected \(expected), got \(error)")
        }
    }

    // MARK: Preference

    private static func testPreferenceDefaultsAndStorage() {
        let suite = "FreeFlowTests.VoiceIsolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(VoiceIsolationPreference.defaultValue, .off)
        TestSupport.expectEqual(VoiceIsolationPreference.storageKey, "voice_isolation_mode")
        TestSupport.expectEqual(VoiceIsolationPreference.allCases, [.off, .light, .strong])
        TestSupport.expectEqual(VoiceIsolationPreference.allCases.map(\.rawValue), ["off", "light", "strong"])
        for mode in VoiceIsolationPreference.allCases {
            TestSupport.expectEqual(mode.id, mode.rawValue)
        }

        TestSupport.expectEqual(VoiceIsolationPreference.load(from: defaults), .off)
        TestSupport.expect(
            defaults.object(forKey: VoiceIsolationPreference.storageKey) == nil,
            "Loading the default must not persist a voice isolation mode"
        )

        defaults.set("medium", forKey: VoiceIsolationPreference.storageKey)
        TestSupport.expectEqual(VoiceIsolationPreference.load(from: defaults), .off)
        defaults.set(2, forKey: VoiceIsolationPreference.storageKey)
        TestSupport.expectEqual(VoiceIsolationPreference.load(from: defaults), .off)

        for mode in VoiceIsolationPreference.allCases {
            mode.save(to: defaults)
            let reloaded = UserDefaults(suiteName: suite)!
            TestSupport.expectEqual(reloaded.object(forKey: VoiceIsolationPreference.storageKey) as? String, mode.rawValue)
            TestSupport.expectEqual(VoiceIsolationPreference.load(from: reloaded), mode)
        }
    }

    private static func testPreferenceLabelsAndAvailability() {
        TestSupport.expectEqual(VoiceIsolationPreference.allCases.map(\.displayName), ["Off", "Light", "Strong"])
        TestSupport.expectEqual(VoiceIsolationPreference.allCases.map(\.wetDryPercent), [nil, 70, 100])
        TestSupport.expectEqual(
            VoiceIsolationPreference.caption,
            "Removes background noise with Apple's on-device Voice Isolation before transcription. Speech-to-text services recommend unprocessed audio in quiet rooms, so leave this Off unless you dictate somewhere noisy. Needs macOS 15 and a 48 kHz microphone (the built-in mic qualifies) and adds about 0.1 s to live text."
        )

        let systemReason = "Voice isolation isn't available on this Mac. It needs macOS 15 or later."
        TestSupport.expectEqual(
            VoiceIsolationPreference.unavailableReason(isSystemSupported: false, captureFormat: .native),
            systemReason
        )
        TestSupport.expectEqual(
            VoiceIsolationPreference.unavailableReason(isSystemSupported: false, captureFormat: .legacy16k),
            systemReason
        )
        TestSupport.expectEqual(
            VoiceIsolationPreference.unavailableReason(isSystemSupported: true, captureFormat: .legacy16k),
            "Voice isolation needs the Native rate recording format."
        )
        TestSupport.expectEqual(
            VoiceIsolationPreference.unavailableReason(isSystemSupported: true, captureFormat: .native),
            nil
        )

        // Recordings use Off whenever the picker is disabled.
        for mode in VoiceIsolationPreference.allCases {
            for isSystemSupported in [false, true] {
                for captureFormat in CaptureFormatPreference.allCases {
                    TestSupport.expectEqual(
                        mode.effective(isSystemSupported: isSystemSupported, captureFormat: captureFormat),
                        isSystemSupported && captureFormat == .native ? mode : .off
                    )
                }
            }
        }

        TestSupport.expectEqual(VoiceIsolationPreference.micModeDisplayName(rawValue: 0), "Standard")
        TestSupport.expectEqual(VoiceIsolationPreference.micModeDisplayName(rawValue: 1), "Wide Spectrum")
        TestSupport.expectEqual(VoiceIsolationPreference.micModeDisplayName(rawValue: 2), "Voice Isolation")
        TestSupport.expectEqual(VoiceIsolationPreference.micModeDisplayName(rawValue: 7), "Unknown")
    }

    /// Only 48 kHz mono Float32 runs through the filter; everything else bypasses.
    private static func testSupportedFormats() {
        TestSupport.expect(
            VoiceIsolationPreference.isSupported(sourceSampleRate: 48_000, channelCount: 1, isFloat32: true),
            "48 kHz mono Float32 must be supported"
        )
        let unsupported: [(rate: Double, channels: AVAudioChannelCount, isFloat32: Bool)] = [
            (44_100, 1, true),
            (16_000, 1, true),
            (24_000, 1, true),
            (96_000, 1, true),
            (48_000, 2, true),
            (48_000, 1, false),
            (16_000, 1, false),
        ]
        for format in unsupported {
            TestSupport.expect(
                !VoiceIsolationPreference.isSupported(
                    sourceSampleRate: format.rate,
                    channelCount: format.channels,
                    isFloat32: format.isFloat32
                ),
                "\(format.rate) Hz, \(format.channels) ch, float32=\(format.isFloat32) must not be supported"
            )
        }
    }

    // MARK: Filter

    /// The effect must run the High Quality Voice model at the requested wet
    /// mix from init on, and reset() between recordings must keep both.
    /// Runs before any other case has reset the filter.
    private static func testEffectIsConfigured(_ filter: VoiceIsolationFilter, wetDryPercent: Float) {
        let name = "wet \(Int(wetDryPercent))"
        expectConfigured(filter, wetDryPercent: wetDryPercent, "\(name), as built")
        // Unfinished, so reset() also drains the model.
        _ = stream(speechLike(frames: 4_800), through: filter, chunkSizes: [480], finish: false)
        filter.reset()
        expectConfigured(filter, wetDryPercent: wetDryPercent, "\(name), after reset")
        _ = stream(speechLike(frames: 4_800), through: filter, chunkSizes: [480])
        filter.reset()
        expectConfigured(filter, wetDryPercent: wetDryPercent, "\(name), after a finished run and reset")
    }

    /// At wet 0 the model passes the input through, so the output must equal
    /// the input sample for sample once the reported latency is dropped.
    private static func testDryPathIsLatencyAligned(_ filter: VoiceIsolationFilter) {
        filter.reset()
        TestSupport.expect(
            filter.latencyFrames >= 0 && filter.latencyFrames < 24_000,
            "latency must be under 0.5 s, got \(filter.latencyFrames) frames"
        )
        let input = noise(frames: 48_000)
        let result = stream(input, through: filter, chunkSizes: chunkPattern)
        TestSupport.expectEqual(result.samples.count, input.count)
        let difference = maxDifference(result.samples, input)
        TestSupport.expect(difference <= 1e-4, "wet 0 output must equal the input after latency compensation, max difference \(difference)")
        for format in result.formats {
            TestSupport.expect(format == captureFormat, "emitted buffers must keep the input format, got \(format)")
            TestSupport.expect(format.isInterleaved, "emitted buffers must keep the input's interleaving")
        }
    }

    private static func testOutputLengthEqualsInput(_ filter: VoiceIsolationFilter, name: String) {
        filter.reset()
        let input = noise(frames: 48_000, seed: 0xA11CE)
        let result = stream(input, through: filter, chunkSizes: chunkPattern)
        TestSupport.expect(
            result.samples.count == input.count,
            "\(name): total output must equal total input (\(input.count)), got \(result.samples.count)"
        )
        TestSupport.expect(result.samples.allSatisfy(\.isFinite), "\(name): output must be finite")

        var emitted = 0
        try! filter.finish { emitted += Int($0.frameLength) }
        TestSupport.expect(emitted == 0, "\(name): a second finish must emit nothing, emitted \(emitted)")
    }

    /// A recording shorter than the model delay is returned entirely by finish.
    private static func testShortRecordingIsReturnedByFinish(_ filter: VoiceIsolationFilter) {
        filter.reset()
        let input = noise(frames: 1_000, seed: 0xBEEF)
        let result = stream(input, through: filter, chunkSizes: [480])
        TestSupport.expectEqual(result.samples.count, input.count)
        let difference = maxDifference(result.samples, input)
        TestSupport.expect(difference <= 1e-4, "short wet 0 recording must come back unchanged, max difference \(difference)")
    }

    /// A cancelled recording's held audio must not reach the next recording.
    /// At wet 0 a missed reset shows as the old tone. Silence cannot reveal
    /// leftover model state; testResetAfterAbandonedRunMatchesCleanRun does.
    private static func testResetClearsCarryOver(_ filter: VoiceIsolationFilter, name: String) {
        filter.reset()
        _ = stream(tone(440, amplitude: 0.5, frames: 24_000), through: filter, chunkSizes: [480], finish: false)
        filter.reset()
        let result = stream([Float](repeating: 0, count: 24_000), through: filter, chunkSizes: [480])
        TestSupport.expectEqual(result.samples.count, 24_000)
        let level = peak(result.samples)
        TestSupport.expect(level <= 1e-4, "\(name): silence after reset must stay below -80 dBFS, peak \(level)")
    }

    /// A caller that gives up on the filter (after a render failure) gets back
    /// exactly the raw input not yet emitted: output plus that remainder is
    /// the whole input, with no gap and no repeats, also when a buffer larger
    /// than one render slice was partly emitted.
    private static func testUnemittedInputIsTheRawRemainder(_ filter: VoiceIsolationFilter, name: String) {
        let input = noise(frames: 30_000, seed: 0xD1CE)
        for chunkSizes in [[480], [10_000]] {
            let label = "\(name), \(chunkSizes[0])-frame buffers"
            filter.reset()
            let result = stream(input, through: filter, chunkSizes: chunkSizes, finish: false)
            let unemitted = filter.takeUnemittedInput()
            // Straight after the first take, before a second take or finish
            // could also end the run: the take alone must.
            expectFilterError(.finished, "\(label): process after a take") {
                try filter.process(buffer(tone(1_000, amplitude: 0.5, frames: 480)[...])) { _ in }
            }
            let remainder = samples(of: unemitted)
            TestSupport.expectEqual(remainder.count, filter.latencyFrames)
            TestSupport.expect(
                result.samples.count + remainder.count == input.count,
                "\(label): output plus the unemitted input must be the whole input"
            )
            TestSupport.expect(
                remainder == Array(input[result.samples.count...]),
                "\(label): the unemitted input must be the raw input that was not emitted"
            )
            if let unemitted {
                TestSupport.expect(unemitted.format == captureFormat, "\(label): unemitted input must keep the input format")
            }
            TestSupport.expect(filter.takeUnemittedInput() == nil, "\(label): a second take must return nothing")

            var emitted = 0
            try! filter.finish { emitted += Int($0.frameLength) }
            TestSupport.expect(emitted == 0, "\(label): finish after a take must emit nothing, emitted \(emitted)")
        }

        // A take with nothing held returns nil and must still end the run.
        filter.reset()
        TestSupport.expect(filter.takeUnemittedInput() == nil, "\(name): a take before any input must return nothing")
        expectFilterError(.finished, "\(name): process after an empty take") {
            try filter.process(buffer(tone(1_000, amplitude: 0.5, frames: 480)[...])) { _ in }
        }
    }

    /// A run that was never finished (a cancelled recording, or one abandoned
    /// after a filter error) must not change how the next recording is
    /// processed. Zeros in give zeros out whatever the model state, so this
    /// compares a speech-like probe against clean runs of the same probe.
    private static func testResetAfterAbandonedRunMatchesCleanRun(_ filter: VoiceIsolationFilter, name: String) {
        let probe = speechLike(frames: 24_000)
        // A finished run flushes whatever an earlier case left in the model.
        filter.reset()
        _ = stream(probe, through: filter, chunkSizes: chunkPattern)
        filter.reset()
        let reference = stream(probe, through: filter, chunkSizes: chunkPattern).samples
        filter.reset()
        let repeated = stream(probe, through: filter, chunkSizes: chunkPattern).samples
        let repeatDifference = maxDifference(reference, repeated)
        TestSupport.expect(repeatDifference <= 1e-6, "\(name): two clean runs must match, max difference \(repeatDifference)")

        let abandonedRuns: [(name: String, samples: [Float], takeUnemitted: Bool)] = [
            ("cancelled loud tone", tone(1_000, amplitude: 0.8, frames: 24_000), false),
            ("cancelled noise", noise(frames: 24_000, seed: 0xCA5CADE), false),
            ("abandoned noise", noise(frames: 24_000, seed: 0xAB4D0), true),
        ]
        for run in abandonedRuns {
            filter.reset()
            _ = stream(run.samples, through: filter, chunkSizes: [480], finish: false)
            if run.takeUnemitted {
                _ = filter.takeUnemittedInput()
            }
            filter.reset()
            let result = stream(probe, through: filter, chunkSizes: chunkPattern).samples
            TestSupport.expectEqual(result.count, probe.count)
            let difference = maxDifference(reference, result)
            TestSupport.expect(
                difference <= 1e-4,
                "\(name): a probe after a \(run.name) run and reset must match a clean run, max difference \(difference)"
            )
        }
    }

    /// No quality assertion: only that the model output is finite, bounded and complete.
    private static func testStrongOnHarmonicSignalStaysBounded(_ filter: VoiceIsolationFilter) {
        filter.reset()
        let hum = (0..<48_000).map { index -> Float in
            let time = Double(index) / 48_000
            return Float(0.2 * sin(2 * .pi * 150 * time) + 0.1 * sin(2 * .pi * 300 * time) + 0.05 * sin(2 * .pi * 450 * time))
        }
        let input = zip(hum, noise(frames: 48_000, seed: 7)).map { $0 + 0.1 * $1 }
        let result = stream(input, through: filter, chunkSizes: chunkPattern)
        TestSupport.expectEqual(result.samples.count, input.count)
        TestSupport.expect(result.samples.allSatisfy(\.isFinite), "wet 100 output must be finite")
        let level = peak(result.samples)
        TestSupport.expect(level <= 2.0, "wet 100 output peak must stay at or below 2.0, got \(level)")
    }

    /// The mix must reach the model: wet 0 returns the speech-like probe
    /// unchanged, wet 70 and 100 change it, and wet 70 stays closer to the
    /// input than wet 100. Only that the audio changes is asserted, never how
    /// well noise is removed.
    private static func testWetMixReachesTheModel(
        dry: VoiceIsolationFilter,
        light: VoiceIsolationFilter,
        strong: VoiceIsolationFilter
    ) {
        let probe = speechLike(frames: 24_000)
        var outputs: [[Float]] = []
        for (filter, wetDryPercent) in [(dry, Float(0)), (light, 70), (strong, 100)] {
            filter.reset()
            expectConfigured(filter, wetDryPercent: wetDryPercent, "wet \(Int(wetDryPercent)), after the other cases")
            let output = stream(probe, through: filter, chunkSizes: chunkPattern).samples
            TestSupport.expectEqual(output.count, probe.count)
            outputs.append(output)
        }
        let dryDifference = maxDifference(outputs[0], probe)
        TestSupport.expect(dryDifference <= 1e-4, "wet 0 must return the probe unchanged, max difference \(dryDifference)")
        let lightDifference = rmsDifference(outputs[1], probe)
        let strongDifference = rmsDifference(outputs[2], probe)
        TestSupport.expect(lightDifference > 1e-3, "wet 70 must change the probe, RMS difference \(lightDifference)")
        TestSupport.expect(strongDifference > 1e-3, "wet 100 must change the probe, RMS difference \(strongDifference)")
        TestSupport.expect(
            lightDifference < strongDifference,
            "wet 70 must stay closer to the input than wet 100, RMS difference \(lightDifference) vs \(strongDifference)"
        )
    }

    private static func testMisuse(_ filter: VoiceIsolationFilter) {
        filter.reset()
        var emitted = 0
        try! filter.finish { emitted += Int($0.frameLength) }
        TestSupport.expect(emitted == 0, "finish with no input must emit nothing, emitted \(emitted)")

        expectFilterError(.finished, "process after finish") {
            try filter.process(buffer(tone(1_000, amplitude: 0.5, frames: 480)[...])) { _ in }
        }

        filter.reset()
        try! filter.process(buffer(tone(1_000, amplitude: 0.5, frames: 480)[...])) { _ in }

        let unsupported: [(format: AVAudioFormat, name: String)] = [
            (AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: true)!, "16 kHz Float32"),
            (AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!, "48 kHz stereo"),
            (AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!, "48 kHz Int16"),
        ]
        for testCase in unsupported {
            emitted = 0
            expectFilterError(.unsupportedFormat, "a \(testCase.name) buffer") {
                try filter.process(blankBuffer(testCase.format, frames: 480)) { emitted += Int($0.frameLength) }
            }
            TestSupport.expect(emitted == 0, "a \(testCase.name) buffer must emit nothing, emitted \(emitted)")
        }

        emitted = 0
        do {
            try filter.process(blankBuffer(captureFormat, frames: 0)) { emitted += Int($0.frameLength) }
        } catch {
            TestSupport.expect(false, "an empty buffer must not throw, got \(error)")
        }
        TestSupport.expect(emitted == 0, "an empty buffer must emit nothing, emitted \(emitted)")
    }
}
