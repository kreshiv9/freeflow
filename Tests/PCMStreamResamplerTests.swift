import AVFAudio
import Foundation

/// Audio-quality and streaming guards for the capture resampler. Synthetic
/// in-memory signals only: no microphone, no files, no network.
enum PCMStreamResamplerTests {
    private typealias Configuration = (
        algorithm: PCMStreamResampler.Algorithm,
        quality: AVAudioQuality,
        name: String
    )

    /// The production default and the higher-fidelity option kept as a variant.
    private static let configurations: [Configuration] = [
        (.minimumPhase, .max, "minimumPhase/max"),
        (.mastering, .high, "mastering/high"),
    ]

    static func run() {
        for configuration in configurations {
            testOutputLengthIsExactAfterFinish(configuration)
            testPassbandTonesKeepTheirLevel(configuration)
            testOutOfBandTonesAreSuppressed(configuration)
            testChunkingDoesNotChangeOutput(configuration)
            testSmallOutputBuffersDrainEveryChunk(configuration)
            testHoldBackStaysBounded(configuration)
            testSilenceStaysZeroAndOverRangeSaturates(configuration)
            testMultichannelKeepsChannelZero(configuration)
            testMisuseThrowsOrEmitsNothing(configuration)
            testTrackerLevelsSurviveConversion(configuration)
        }
        testDefaultInitializerIsTheProductionConfiguration()
        testSmallChunksEmitNothingAtFirstThenFlushTheTail()
        testLegacyCaptureFormatPassesThroughBitExact()
        testLittleEndianDataAndFormatSummary()
        testSliceCopiesTapBuffers()
    }

    // MARK: Fixtures

    private static func format(_ rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    private static func tone(_ frequency: Double, amplitude: Double, seconds: Double, rate: Double = 48_000) -> [Float] {
        let count = Int(rate * seconds)
        let step = 2 * Double.pi * frequency / rate
        return (0..<count).map { Float(amplitude * sin(step * Double($0))) }
    }

    /// Seeded, platform-independent noise (64-bit LCG), RMS about 0.1.
    private static func noise(seconds: Double, rate: Double = 48_000, seed: UInt64 = 0x5EED) -> [Float] {
        var state = seed
        return (0..<Int(rate * seconds)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53)
            return Float((unit - 0.5) * 0.35)
        }
    }

    private static func buffer(_ samples: ArraySlice<Float>, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for (index, value) in samples.enumerated() {
            channel[index] = value
        }
        return buffer
    }

    private static func int16Format(_ rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
    }

    private static func int16Buffer(_ samples: ArraySlice<Int16>, rate: Double) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: int16Format(rate), frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.int16ChannelData![0]
        for (index, value) in samples.enumerated() {
            channel[index] = value
        }
        return buffer
    }

    private static func samples(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Per-channel Float32 samples, interleaved or not.
    private static func floatSamples(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
        let channels = buffer.floatChannelData!
        let interleaved = buffer.format.isInterleaved
        return (0..<Int(buffer.format.channelCount)).map { channel in
            (0..<Int(buffer.frameLength)).map { frame in
                interleaved ? channels[0][frame * buffer.stride + channel] : channels[channel][frame]
            }
        }
    }

    private static func setFloatSamples(_ samples: [[Float]], in buffer: AVAudioPCMBuffer) {
        let channels = buffer.floatChannelData!
        let interleaved = buffer.format.isInterleaved
        for (channel, values) in samples.enumerated() {
            for (frame, value) in values.enumerated() {
                if interleaved {
                    channels[0][frame * buffer.stride + channel] = value
                } else {
                    channels[channel][frame] = value
                }
            }
        }
    }

    private static func makeResampler(
        from inputFormat: AVAudioFormat,
        to rate: Double,
        _ configuration: Configuration,
        outputCapacityLimit: AVAudioFrameCount? = nil
    ) -> PCMStreamResampler {
        try! PCMStreamResampler(
            inputFormat: inputFormat,
            outputSampleRate: rate,
            algorithm: configuration.algorithm,
            quality: configuration.quality,
            outputCapacityLimit: outputCapacityLimit
        )
    }

    /// Streams `input` through a fresh resampler in the given chunk sizes
    /// (cycled), then flushes. `onChunk` sees (input frames fed, output frames emitted).
    private static func convert(
        _ input: [Float],
        from inputRate: Double = 48_000,
        to rate: Double,
        _ configuration: Configuration,
        chunkSizes: [Int] = [1_024],
        outputCapacityLimit: AVAudioFrameCount? = nil,
        onChunk: ((Int, Int) -> Void)? = nil
    ) -> [Int16] {
        stream(
            input,
            through: makeResampler(from: format(inputRate), to: rate, configuration, outputCapacityLimit: outputCapacityLimit),
            chunkSizes: chunkSizes,
            onChunk: onChunk
        )
    }

    /// `convert` through a caller-built resampler.
    private static func stream(
        _ input: [Float],
        through resampler: PCMStreamResampler,
        chunkSizes: [Int],
        onChunk: ((Int, Int) -> Void)? = nil
    ) -> [Int16] {
        var output: [Int16] = []
        var offset = 0
        var chunkIndex = 0
        while offset < input.count {
            let count = min(chunkSizes[chunkIndex % chunkSizes.count], input.count - offset)
            try! resampler.process(buffer(input[offset..<(offset + count)], format: resampler.inputFormat)) {
                output += samples($0)
            }
            offset += count
            chunkIndex += 1
            onChunk?(offset, output.count)
        }
        try! resampler.finish { output += samples($0) }
        return output
    }

    /// Amplitude (full scale = 1.0) of `frequency` over a 300 ms window that
    /// starts 100 ms in, skipping filter start-up. Any multiple of 10 Hz
    /// completes an integer number of cycles in the window.
    private static func amplitude(of frequency: Double, in output: [Int16], rate: Double) -> Double {
        let start = Int(rate * 0.1)
        let count = Int(rate * 0.3)
        TestSupport.expect(
            output.count >= start + count,
            "output too short: \(output.count) frames, need \(start + count)"
        )
        var real = 0.0
        var imaginary = 0.0
        let step = 2 * Double.pi * frequency / rate
        for index in 0..<count {
            let value = Double(output[start + index]) / 32_768
            real += value * cos(step * Double(index))
            imaginary += value * sin(step * Double(index))
        }
        return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(count)
    }

    private static func decibels(_ ratio: Double) -> Double {
        20 * log10(max(ratio, 1e-12))
    }

    private static func largestDifference(_ output: [Int16], _ reference: [Int16]) -> Int {
        var difference = 0
        for index in 0..<min(output.count, reference.count) {
            difference = max(difference, abs(Int(output[index]) - Int(reference[index])))
        }
        return difference
    }

    private static func aliasFrequency(_ frequency: Double, rate: Double) -> Double {
        let folded = frequency.truncatingRemainder(dividingBy: rate)
        return folded > rate / 2 ? rate - folded : folded
    }

    private static func expectResamplerError(
        _ expected: PCMStreamResampler.ResamplerError,
        _ message: String,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            TestSupport.expect(false, "\(message): expected \(expected), nothing was thrown")
        } catch let error as PCMStreamResampler.ResamplerError {
            TestSupport.expect(error == expected, "\(message): expected \(expected), got \(error)")
        } catch {
            TestSupport.expect(false, "\(message): expected \(expected), got \(error)")
        }
    }

    // MARK: Per-configuration tests

    private static func testOutputLengthIsExactAfterFinish(_ configuration: Configuration) {
        let name = configuration.name
        let input = noise(seconds: 1)
        let at16k = convert(input, to: 16_000, configuration, chunkSizes: [480, 37, 4_800]).count
        TestSupport.expect(at16k == 16_000, "\(name): 48 kHz -> 16 kHz gave \(at16k) frames, expected 16000")
        let at24k = convert(input, to: 24_000, configuration, chunkSizes: [480, 37, 4_800]).count
        TestSupport.expect(at24k == 24_000, "\(name): 48 kHz -> 24 kHz gave \(at24k) frames, expected 24000")

        let from44k = convert(noise(seconds: 1, rate: 44_100), from: 44_100, to: 16_000, configuration, chunkSizes: [441, 37, 4_410]).count
        TestSupport.expect(from44k == 16_000, "\(name): 44.1 kHz -> 16 kHz gave \(from44k) frames, expected 16000")

        let from16k = convert(noise(seconds: 1, rate: 16_000), from: 16_000, to: 16_000, configuration, chunkSizes: [160, 37, 1_600]).count
        TestSupport.expect(from16k == 16_000, "\(name): 16 kHz Float32 -> 16 kHz gave \(from16k) frames, expected 16000")

        let resampler = makeResampler(from: format(48_000), to: 16_000, configuration)
        TestSupport.expect(resampler.outputFormat == int16Format(16_000), "\(name): output must be Int16 16 kHz mono interleaved, got \(resampler.outputFormat)")
    }

    private static func testPassbandTonesKeepTheirLevel(_ configuration: Configuration) {
        for (rate, frequencies) in [(16_000.0, [300.0, 1_000, 3_000, 5_000, 7_000]), (24_000.0, [1_000.0, 5_000, 7_000, 10_000])] {
            for frequency in frequencies {
                let output = convert(tone(frequency, amplitude: 0.5, seconds: 0.5), to: rate, configuration)
                let gain = decibels(amplitude(of: frequency, in: output, rate: rate) / 0.5)
                TestSupport.expect(
                    abs(gain) <= 0.5,
                    "\(configuration.name): \(Int(frequency)) Hz at \(Int(rate)) Hz: gain \(gain) dB, expected within ±0.5 dB"
                )
            }
        }
    }

    private static func testOutOfBandTonesAreSuppressed(_ configuration: Configuration) {
        for (rate, frequencies) in [(16_000.0, [9_000.0, 10_000, 12_000, 20_000]), (24_000.0, [13_000.0, 15_000, 20_000])] {
            for frequency in frequencies {
                let output = convert(tone(frequency, amplitude: 0.5, seconds: 0.5), to: rate, configuration)
                let alias = aliasFrequency(frequency, rate: rate)
                let level = decibels(amplitude(of: alias, in: output, rate: rate) / 0.5)
                TestSupport.expect(
                    level <= -70,
                    "\(configuration.name): \(Int(frequency)) Hz folds to \(Int(alias)) Hz at \(Int(rate)) Hz with \(level) dB, expected <= -70 dB"
                )
            }
        }
    }

    /// B1 regression: a small buffer after a large one must not drop audio.
    private static func testChunkingDoesNotChangeOutput(_ configuration: Configuration) {
        let input = noise(seconds: 1)
        let reference = convert(input, to: 16_000, configuration, chunkSizes: [input.count])
        let patterns: [[Int]] = [
            [1], [37], [341], [480], [1_024], [4_800], [16_384],
            [4_800] + Array(repeating: 480, count: 10),
            [512, 470, 1_024, 4_800],
        ]
        for sizes in patterns {
            let chunked = convert(input, to: 16_000, configuration, chunkSizes: sizes)
            TestSupport.expect(
                chunked.count == reference.count,
                "\(configuration.name): chunks \(sizes.prefix(3)) gave \(chunked.count) frames, whole-signal gave \(reference.count)"
            )
            let maxDifference = largestDifference(chunked, reference)
            TestSupport.expect(
                maxDifference <= 1,
                "\(configuration.name): chunks \(sizes.prefix(3)): max difference \(maxDifference) LSB vs whole-signal conversion"
            )
        }
    }

    /// Drain-loop regression. Output buffers smaller than a chunk's output make
    /// the converter return .haveData with input left over; process and finish
    /// must keep draining, or the rest of the chunk (B1) or the tail (B2) is lost.
    private static func testSmallOutputBuffersDrainEveryChunk(_ configuration: Configuration) {
        let name = configuration.name
        let limit: AVAudioFrameCount = 7
        let input = noise(seconds: 1)
        let reference = convert(input, to: 16_000, configuration, chunkSizes: [input.count])
        var emittedBeforeFinish = 0
        var largestCall = 0
        let drained = convert(input, to: 16_000, configuration, chunkSizes: [4_800, 480, 37, 1_024], outputCapacityLimit: limit) { _, emitted in
            largestCall = max(largestCall, emitted - emittedBeforeFinish)
            emittedBeforeFinish = emitted
        }
        TestSupport.expect(
            largestCall > Int(limit),
            "\(name): no process call drained more than one \(limit)-frame output buffer (largest \(largestCall))"
        )
        TestSupport.expect(
            drained.count == reference.count,
            "\(name): \(limit)-frame output buffers gave \(drained.count) frames, whole-signal gave \(reference.count)"
        )
        let maxDifference = largestDifference(drained, reference)
        TestSupport.expect(
            maxDifference <= 1,
            "\(name): \(limit)-frame output buffers: max difference \(maxDifference) LSB vs whole-signal conversion"
        )
        if configuration.algorithm == .mastering {
            let tail = drained.count - emittedBeforeFinish
            TestSupport.expect(
                tail > Int(limit),
                "\(name): finish returned \(tail) frames, expected a tail longer than one \(limit)-frame output buffer"
            )
        }
    }

    /// Honoring the converter's request size keeps large capture buffers from
    /// parking audio inside the converter.
    private static func testHoldBackStaysBounded(_ configuration: Configuration) {
        let input = noise(seconds: 1)
        for (rate, chunkSize) in [(16_000.0, 4_800), (16_000.0, 16_384), (24_000.0, 4_800), (24_000.0, 12_288)] {
            let ratio = rate / 48_000
            let allowed = Int(rate * 0.025)
            var worst = 0
            _ = convert(input, to: rate, configuration, chunkSizes: [chunkSize]) { fed, emitted in
                worst = max(worst, Int(Double(fed) * ratio) - emitted)
            }
            TestSupport.expect(
                worst <= allowed,
                "\(configuration.name): \(Int(rate)) Hz, \(chunkSize)-frame chunks: \(worst) frames held back, allowed \(allowed)"
            )
        }
    }

    private static func testSilenceStaysZeroAndOverRangeSaturates(_ configuration: Configuration) {
        let silence = convert([Float](repeating: 0, count: 24_000), to: 16_000, configuration)
        TestSupport.expect(
            !silence.isEmpty && silence.allSatisfy { $0 == 0 },
            "\(configuration.name): digital silence must stay exactly zero (no dither)"
        )

        let output = convert(tone(100, amplitude: 1.25, seconds: 0.5), to: 16_000, configuration)
        var wrapped = 0
        for index in 0..<min(output.count, 8_000) {
            let expected = 1.25 * sin(2 * Double.pi * 100 * Double(index) / 16_000)
            if expected > 0.5 && output[index] < 0 { wrapped += 1 }
            if expected < -0.5 && output[index] > 0 { wrapped += 1 }
        }
        TestSupport.expect(wrapped == 0, "\(configuration.name): over-range input wrapped sign \(wrapped) times")
        TestSupport.expect(
            output.contains(Int16.max) && output.contains(Int16.min),
            "\(configuration.name): over-range input must clip at full scale"
        )
    }

    /// B11 regression: discrete multichannel input must not convert to silence.
    private static func testMultichannelKeepsChannelZero(_ configuration: Configuration) {
        let source = tone(1_000, amplitude: 0.5, seconds: 0.5)
        let expectedDBFS = AudioLevelMeter.dbfs(0.5 / Float(2).squareRoot())
        for channels in [AVAudioChannelCount(2), 3] {
            for interleaved in [false, true] {
                let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
                let inputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 48_000,
                    interleaved: interleaved,
                    channelLayout: layout
                )
                let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(source.count))!
                input.frameLength = AVAudioFrameCount(source.count)
                let channelCount = Int(channels)
                if interleaved {
                    let pointer = input.floatChannelData![0]
                    for index in 0..<source.count {
                        for channel in 0..<channelCount {
                            pointer[index * channelCount + channel] = channel == 0 ? source[index] : 0
                        }
                    }
                } else {
                    for channel in 0..<channelCount {
                        let pointer = input.floatChannelData![channel]
                        for index in 0..<source.count {
                            pointer[index] = channel == 0 ? source[index] : 0
                        }
                    }
                }

                let resampler = makeResampler(from: inputFormat, to: 16_000, configuration)
                var output: [Int16] = []
                try! resampler.process(input) { output += samples($0) }
                try! resampler.finish { output += samples($0) }
                let difference = AudioLevelMeter.dbfs(AudioLevelMeter.rms(int16Buffer(output[...], rate: 16_000))) - expectedDBFS
                TestSupport.expect(
                    abs(difference) <= 1,
                    "\(configuration.name): \(channels)-channel interleaved=\(interleaved) input gave mono \(difference) dB from channel 0"
                )
            }
        }
    }

    private static func testMisuseThrowsOrEmitsNothing(_ configuration: Configuration) {
        let name = configuration.name
        let resampler = makeResampler(from: format(48_000), to: 16_000, configuration)
        var emitted = 0

        let empty = AVAudioPCMBuffer(pcmFormat: resampler.inputFormat, frameCapacity: 16)!
        try! resampler.process(empty) { emitted += Int($0.frameLength) }
        TestSupport.expect(emitted == 0, "\(name): an empty input buffer must emit nothing, emitted \(emitted)")

        expectResamplerError(.formatMismatch, "\(name): a 44.1 kHz buffer into a 48 kHz resampler") {
            try resampler.process(buffer(tone(1_000, amplitude: 0.5, seconds: 0.01, rate: 44_100)[...], format: format(44_100))) { _ in }
        }

        try! resampler.process(buffer(tone(1_000, amplitude: 0.5, seconds: 0.1)[...], format: resampler.inputFormat)) { _ in }
        try! resampler.finish { _ in }
        expectResamplerError(.finished, "\(name): process after finish") {
            try resampler.process(buffer(tone(1_000, amplitude: 0.5, seconds: 0.01)[...], format: resampler.inputFormat)) { _ in }
        }

        emitted = 0
        do {
            try resampler.finish { emitted += Int($0.frameLength) }
        } catch {
            TestSupport.expect(false, "\(name): a second finish must not throw, got \(error)")
        }
        TestSupport.expect(emitted == 0, "\(name): a second finish must emit nothing, emitted \(emitted)")
    }

    /// The speech tracker reads the 16 kHz chunks, so its thresholds must see
    /// in-band speech at the input level and out-of-band energy removed.
    /// Only steady-state chunks (fully inside 100-900 ms) are compared.
    private static func testTrackerLevelsSurviveConversion(_ configuration: Configuration) {
        let cases: [(frequency: Double, amplitude: Double, keepsLevel: Bool)] = [
            (1_000, pow(10, -30.0 / 20) * 2.0.squareRoot(), true),
            (12_000, 0.5, false),
        ]
        for testCase in cases {
            let source = tone(testCase.frequency, amplitude: testCase.amplitude, seconds: 1)
            let inputDBFS = AudioLevelMeter.dbfs(AudioLevelMeter.rms(buffer(source[...], format: format(48_000))))
            let resampler = makeResampler(from: format(48_000), to: 16_000, configuration)
            var emittedFrames = 0
            var checkedChunks = 0
            var worst: Float = testCase.keepsLevel ? 0 : -.infinity
            var offset = 0
            while offset < source.count {
                let end = min(offset + 480, source.count)
                try! resampler.process(buffer(source[offset..<end], format: resampler.inputFormat)) { chunk in
                    let start = emittedFrames
                    emittedFrames += Int(chunk.frameLength)
                    guard start >= 1_600, emittedFrames <= 14_400 else { return }
                    checkedChunks += 1
                    let relative = AudioLevelMeter.dbfs(AudioLevelMeter.rms(chunk)) - inputDBFS
                    worst = testCase.keepsLevel ? max(worst, abs(relative)) : max(worst, relative)
                }
                offset = end
            }
            TestSupport.expect(checkedChunks > 0, "\(configuration.name): \(Int(testCase.frequency)) Hz produced no steady-state chunks")
            if testCase.keepsLevel {
                TestSupport.expect(
                    worst <= 0.2,
                    "\(configuration.name): 1 kHz at -30 dBFS chunk RMS moved \(worst) dB, expected within 0.2 dB"
                )
            } else {
                TestSupport.expect(
                    worst <= -70,
                    "\(configuration.name): 12 kHz chunk RMS at \(worst) dB relative to input, expected <= -70 dB"
                )
            }
        }
    }

    // MARK: Single-configuration tests

    /// AudioRecorder builds its resamplers with the default arguments, so the
    /// defaults must be MinimumPhase/max: the same samples as the explicit
    /// configuration, the 7 kHz band intact and nothing held back between
    /// 100 ms capture buffers.
    private static func testDefaultInitializerIsTheProductionConfiguration() {
        let production = configurations[0]
        let input = noise(seconds: 1)
        for rate in [16_000.0, 24_000] {
            let ratio = rate / 48_000
            var worstHoldBack = 0
            let defaultOutput = stream(
                input,
                through: try! PCMStreamResampler(inputFormat: format(48_000), outputSampleRate: rate),
                chunkSizes: [4_800]
            ) { fed, emitted in
                worstHoldBack = max(worstHoldBack, Int(Double(fed) * ratio) - emitted)
            }
            TestSupport.expect(
                defaultOutput == convert(input, to: rate, production, chunkSizes: [4_800]),
                "default initializer at \(Int(rate)) Hz must match \(production.name) bit-exactly"
            )
            TestSupport.expect(
                worstHoldBack == 0,
                "default initializer at \(Int(rate)) Hz held back \(worstHoldBack) frames after a 4800-frame chunk, expected 0"
            )
        }

        let output = stream(
            tone(7_000, amplitude: 0.5, seconds: 0.5),
            through: try! PCMStreamResampler(inputFormat: format(48_000), outputSampleRate: 16_000),
            chunkSizes: [4_800]
        )
        let gain = decibels(amplitude(of: 7_000, in: output, rate: 16_000) / 0.5)
        TestSupport.expect(abs(gain) <= 0.5, "default initializer: 7000 Hz at 16000 Hz: gain \(gain) dB, expected within ±0.5 dB")
    }

    /// B3 and B2 regressions. Mastering/high holds its first output frames, so
    /// early calls emit nothing (and must not throw) and finish returns the tail.
    /// MinimumPhase emits from the first call, so it cannot exercise this.
    private static func testSmallChunksEmitNothingAtFirstThenFlushTheTail() {
        let configuration = configurations[1]
        let input = noise(seconds: 1)
        let resampler = makeResampler(from: format(48_000), to: 16_000, configuration)
        var emittedBeforeFinish = 0
        var offset = 0
        var isFirstCall = true
        while offset < input.count {
            let end = min(offset + 160, input.count)
            var emittedThisCall = 0
            do {
                try resampler.process(buffer(input[offset..<end], format: resampler.inputFormat)) {
                    emittedThisCall += Int($0.frameLength)
                }
            } catch {
                TestSupport.expect(false, "\(configuration.name): a 160-frame chunk must not throw, got \(error)")
            }
            if isFirstCall {
                TestSupport.expect(
                    emittedThisCall == 0,
                    "\(configuration.name): the first 160-frame call should emit nothing (fixture), emitted \(emittedThisCall)"
                )
                isFirstCall = false
            }
            emittedBeforeFinish += emittedThisCall
            offset = end
        }
        var emittedByFinish = 0
        try! resampler.finish { emittedByFinish += Int($0.frameLength) }
        TestSupport.expect(
            emittedBeforeFinish < 16_000,
            "\(configuration.name): \(emittedBeforeFinish) frames before finish, expected a held-back tail"
        )
        TestSupport.expect(emittedByFinish > 0, "\(configuration.name): finish must return the held-back tail")
        TestSupport.expect(
            emittedBeforeFinish + emittedByFinish == 16_000,
            "\(configuration.name): \(emittedBeforeFinish) + \(emittedByFinish) frames, expected exactly 16000"
        )
    }

    /// The "16 kHz (previous)" capture format delivers 16 kHz Int16, which the
    /// default resampler must pass through unchanged, one chunk per buffer.
    private static func testLegacyCaptureFormatPassesThroughBitExact() {
        var state: UInt64 = 0xC0FFEE
        let input: [Int16] = (0..<16_000).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int16(Int(state >> 48) - 32_768)
        }
        let resampler = try! PCMStreamResampler(inputFormat: int16Format(16_000), outputSampleRate: 16_000)
        let chunkSizes = [160, 37, 1_600, 320]
        var output: [Int16] = []
        var offset = 0
        var chunkIndex = 0
        while offset < input.count {
            let count = min(chunkSizes[chunkIndex % chunkSizes.count], input.count - offset)
            var emits = 0
            try! resampler.process(int16Buffer(input[offset..<(offset + count)], rate: 16_000)) {
                emits += 1
                output += samples($0)
            }
            offset += count
            chunkIndex += 1
            TestSupport.expect(emits == 1, "legacy 16 kHz Int16: chunk \(chunkIndex) emitted \(emits) times, expected once")
            TestSupport.expect(output.count == offset, "legacy 16 kHz Int16: \(output.count) frames out after \(offset) in")
        }
        try! resampler.finish { output += samples($0) }
        TestSupport.expect(output.count == 16_000, "legacy 16 kHz Int16: \(output.count) frames, expected 16000")
        TestSupport.expect(output == input, "legacy 16 kHz Int16 must pass through bit-exact")
    }

    private static func testLittleEndianDataAndFormatSummary() {
        let data = PCMStreamResampler.littleEndianData(int16Buffer([1, -2, 0x1234][...], rate: 16_000))
        TestSupport.expectEqual([UInt8](data), [0x01, 0x00, 0xFE, 0xFF, 0x34, 0x12])
        TestSupport.expect(
            PCMStreamResampler.littleEndianData(int16Buffer([][...], rate: 16_000)).isEmpty,
            "a 0-frame buffer must give empty data"
        )
        TestSupport.expect(
            PCMStreamResampler.littleEndianData(buffer([0.5, -0.5][...], format: format(16_000))).isEmpty,
            "a non-Int16 buffer must give empty data"
        )

        let float48k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!
        TestSupport.expectEqual(PCMStreamResampler.formatSummary(float48k), "pcmFormatFloat32 48000Hz 1 ch interleaved=true")
        TestSupport.expectEqual(PCMStreamResampler.formatSummary(int16Format(16_000)), "pcmFormatInt16 16000Hz 1 ch interleaved=true")
    }

    /// The voice-processing tap reuses its buffers, so a full-length slice
    /// must own every channel's samples, interleaved or not.
    private static func testSliceCopiesTapBuffers() {
        let frames = 480
        let discrete3 = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!
        let formats: [(name: String, format: AVAudioFormat)] = [
            ("mono non-interleaved", format(48_000)),
            ("stereo interleaved", AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!),
            ("3-channel non-interleaved", AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: discrete3)),
        ]
        for (name, sourceFormat) in formats {
            let channelCount = Int(sourceFormat.channelCount)
            let expected: [[Float]] = (0..<channelCount).map { channel in
                (0..<frames).map { Float(channel + 1) * Float(sin(Double($0) * 0.1)) }
            }
            let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames))!
            source.frameLength = AVAudioFrameCount(frames)
            setFloatSamples(expected, in: source)

            let copy = PCMStreamResampler.slice(source, from: 0, count: source.frameLength)!
            TestSupport.expect(copy.format == sourceFormat, "\(name): the copy must keep the source format")
            TestSupport.expectEqual(copy.frameLength, AVAudioFrameCount(frames))
            TestSupport.expect(floatSamples(copy) == expected, "\(name): the copy must hold every channel's samples")

            let part = PCMStreamResampler.slice(source, from: 100, count: 50)!
            let expectedPart = expected.map { Array($0[100..<150]) }
            TestSupport.expectEqual(part.frameLength, 50)
            TestSupport.expect(floatSamples(part) == expectedPart, "\(name): a slice must hold source frames 100..<150")

            setFloatSamples(Array(repeating: Array(repeating: 9, count: frames), count: channelCount), in: source)
            TestSupport.expect(floatSamples(copy) == expected, "\(name): writes to the source must not reach the copy")
            TestSupport.expect(floatSamples(part) == expectedPart, "\(name): writes to the source must not reach the slice")
        }
    }
}
