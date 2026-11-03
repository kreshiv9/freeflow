import AVFAudio
import Foundation

/// The voice-processing first-second digital-zero check. Synthetic in-memory
/// buffers only: no engine, input node, device or microphone.
enum VoiceProcessingLivenessTests {
    static func run() {
        testInitialState()
        testOneSecondOfDigitalZeroFallsBackOnce()
        testOtherRatesAndSizes()
        testSignalMakesCaptureLive()
        testSignalBeforeLimitKeepsVoiceProcessing()
        testSilentVerdictIsFinal()
        testIgnoresEmptyAndInvalidInput()
        testChannelZeroSilenceDetection()
    }

    // MARK: Fixtures

    private static func monoBuffer(_ samples: [Float], rate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, value) in samples.enumerated() {
            buffer.floatChannelData![0][index] = value
        }
        return buffer
    }

    /// Interleaved Float32 stereo; channel 0 and channel 1 sample arrays.
    private static func interleavedStereoBuffer(channel0: [Float], channel1: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channel0.count))!
        buffer.frameLength = AVAudioFrameCount(channel0.count)
        let pointer = buffer.floatChannelData![0]
        for index in 0..<channel0.count {
            pointer[index * 2] = channel0[index]
            pointer[index * 2 + 1] = channel1[index]
        }
        return buffer
    }

    /// Non-interleaved Float32 with a discrete layout, like a voice-processing
    /// format with reference channels; the plain initializer returns nil for 3 channels.
    private static func discreteBuffer(_ channels: [[Float]]) -> AVAudioPCMBuffer {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels.count))!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
        buffer.frameLength = AVAudioFrameCount(channels[0].count)
        for (channel, samples) in channels.enumerated() {
            for (index, value) in samples.enumerated() {
                buffer.floatChannelData![channel][index] = value
            }
        }
        return buffer
    }

    private static func sine(_ frequency: Double = 440, amplitude: Double = 0.01, count: Int = 480, rate: Double = 48_000) -> [Float] {
        let step = 2 * Double.pi * frequency / rate
        return (0..<count).map { Float(amplitude * sin(step * Double($0))) }
    }

    /// Seeded, platform-independent noise (64-bit LCG).
    private static func noise(count: Int = 480, seed: UInt64 = 0x5EED) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53)
            return Float((unit - 0.5) * 0.35)
        }
    }

    /// The 1-based index of the silent buffer that returns `.silent`, or 0.
    private static func silentBufferThatFallsBack(frames: Int, rate: Double, limit: Int = 40) -> Int {
        var liveness = VoiceProcessingLiveness()
        for index in 1...limit where liveness.observe(frameCount: frames, sampleRate: rate, isSilent: true) == .silent {
            return index
        }
        return 0
    }

    // MARK: Tests

    private static func testInitialState() {
        let liveness = VoiceProcessingLiveness()
        TestSupport.expectEqual(liveness.state, .waiting)
        TestSupport.expectEqual(liveness.silentFrames, 0)
        TestSupport.expectEqual(VoiceProcessingLiveness.silenceLimitSeconds, 1)
    }

    /// Frames are counted: ten 0.1 s buffers sum to 0.9999999999999999 s,
    /// so summing seconds would wait for an eleventh buffer.
    private static func testOneSecondOfDigitalZeroFallsBackOnce() {
        var summedSeconds = 0.0
        for _ in 0..<10 {
            summedSeconds += 4_800.0 / 48_000.0
        }
        TestSupport.expect(summedSeconds < 1, "fixture: ten 0.1 s buffers sum to just under one second")

        var liveness = VoiceProcessingLiveness()
        for index in 1...9 {
            TestSupport.expectEqual(liveness.observe(frameCount: 4_800, sampleRate: 48_000, isSilent: true), nil)
            TestSupport.expectEqual(liveness.state, .waiting)
            TestSupport.expectEqual(liveness.silentFrames, index * 4_800)
        }
        TestSupport.expectEqual(liveness.observe(frameCount: 4_800, sampleRate: 48_000, isSilent: true), .silent)
        TestSupport.expectEqual(liveness.state, .silent)
        TestSupport.expectEqual(liveness.silentFrames, 48_000)
        for _ in 11...12 {
            TestSupport.expectEqual(liveness.observe(frameCount: 4_800, sampleRate: 48_000, isSilent: true), nil)
            TestSupport.expectEqual(liveness.state, .silent)
        }
    }

    private static func testOtherRatesAndSizes() {
        TestSupport.expectEqual(silentBufferThatFallsBack(frames: 4_410, rate: 44_100), 10)
        TestSupport.expectEqual(silentBufferThatFallsBack(frames: 16_000, rate: 48_000), 3)
        TestSupport.expectEqual(silentBufferThatFallsBack(frames: 4_800, rate: 16_000), 4)
    }

    private static func testSignalMakesCaptureLive() {
        var liveness = VoiceProcessingLiveness()
        TestSupport.expectEqual(liveness.observe(frameCount: 4_800, sampleRate: 48_000, isSilent: false), .live)
        TestSupport.expectEqual(liveness.state, .live)
        TestSupport.expectEqual(liveness.observe(frameCount: 4_800, sampleRate: 48_000, isSilent: false), nil)
        for _ in 0..<30 {
            TestSupport.expectEqual(liveness.observe(frameCount: 4_800, sampleRate: 48_000, isSilent: true), nil)
        }
        TestSupport.expectEqual(liveness.state, .live)
    }

    private static func testSignalBeforeLimitKeepsVoiceProcessing() {
        var liveness = VoiceProcessingLiveness()
        for _ in 0..<9 {
            TestSupport.expectEqual(liveness.observe(frameCount: 4_800, sampleRate: 48_000, isSilent: true), nil)
        }
        TestSupport.expectEqual(liveness.observe(frameCount: 4_800, sampleRate: 48_000, isSilent: false), .live)
        for _ in 0..<20 {
            TestSupport.expect(
                liveness.observe(frameCount: 4_800, sampleRate: 48_000, isSilent: true) != .silent,
                "silence after the first signal must never fall back"
            )
        }
        TestSupport.expectEqual(liveness.state, .live)
    }

    private static func testSilentVerdictIsFinal() {
        var liveness = VoiceProcessingLiveness()
        for _ in 0..<10 {
            _ = liveness.observe(frameCount: 4_800, sampleRate: 48_000, isSilent: true)
        }
        TestSupport.expectEqual(liveness.state, .silent)
        TestSupport.expectEqual(liveness.observe(frameCount: 4_800, sampleRate: 48_000, isSilent: false), nil)
        TestSupport.expectEqual(liveness.state, .silent)
    }

    private static func testIgnoresEmptyAndInvalidInput() {
        var liveness = VoiceProcessingLiveness()
        let ignored: [(frames: Int, rate: Double)] = [
            (0, 48_000),
            (-4_800, 48_000),
            (4_800, 0),
            (4_800, -48_000),
            (4_800, .nan),
            (4_800, .infinity),
        ]
        for input in ignored {
            for isSilent in [true, false] {
                TestSupport.expectEqual(liveness.observe(frameCount: input.frames, sampleRate: input.rate, isSilent: isSilent), nil)
                TestSupport.expectEqual(liveness.state, .waiting)
                TestSupport.expectEqual(liveness.silentFrames, 0)
            }
        }
        for _ in 1...9 {
            TestSupport.expectEqual(liveness.observe(frameCount: 4_800, sampleRate: 48_000, isSilent: true), nil)
        }
        TestSupport.expectEqual(liveness.observe(frameCount: 4_800, sampleRate: 48_000, isSilent: true), .silent)
    }

    private static func testChannelZeroSilenceDetection() {
        let zeros = [Float](repeating: 0, count: 480)
        var negativeZero = zeros
        negativeZero[240] = -0.0
        var tiny = zeros
        tiny[479] = .leastNonzeroMagnitude
        var nan = zeros
        nan[10] = .nan
        var stereoSignal = zeros
        stereoSignal[300] = 0.25

        let silentCases: [(String, AVAudioPCMBuffer)] = [
            ("all-zero mono", monoBuffer(zeros)),
            ("mono with -0.0", monoBuffer(negativeZero)),
            ("empty mono", monoBuffer([])),
            ("interleaved stereo with only channel 1 non-zero", interleavedStereoBuffer(channel0: zeros, channel1: [Float](repeating: 0.5, count: 480))),
            ("3-channel with only channels 1-2 non-zero", discreteBuffer([zeros, sine(), sine(1_000)])),
        ]
        for (name, buffer) in silentCases {
            TestSupport.expect(VoiceProcessingLiveness.isChannelZeroSilent(buffer), "\(name) must count as silent")
        }

        let int16Format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!
        let int16Zeros = AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: 480)!
        int16Zeros.frameLength = 480
        for index in 0..<480 {
            int16Zeros.int16ChannelData![0][index] = 0
        }

        let signalCases: [(String, AVAudioPCMBuffer)] = [
            ("mono with leastNonzeroMagnitude in the last frame", monoBuffer(tiny)),
            ("mono 440 Hz sine at -40 dBFS", monoBuffer(sine())),
            ("mono seeded noise", monoBuffer(noise())),
            ("mono with NaN", monoBuffer(nan)),
            ("interleaved stereo with one non-zero channel-0 sample", interleavedStereoBuffer(channel0: stereoSignal, channel1: zeros)),
            ("3-channel with a sine on channel 0", discreteBuffer([sine(), zeros, zeros])),
            ("all-zero Int16 (not Float32)", int16Zeros),
        ]
        for (name, buffer) in signalCases {
            TestSupport.expect(!VoiceProcessingLiveness.isChannelZeroSilent(buffer), "\(name) must count as signal")
        }
    }
}
