import AVFAudio
import Foundation

/// Synthetic in-memory buffers only.
enum AudioLevelMeterTests {
    static func run() {
        testFloatSine()
        testInt16FullScaleSquare()
        testNonInterleavedStereoAveragesEveryChannel()
        testEmptyBuffer()
        testDecibels()
    }

    private static func testFloatSine() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        let channel = buffer.floatChannelData![0]
        for index in 0..<4_800 {
            channel[index] = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(index) / 48_000))
        }
        TestSupport.expectApproximatelyEqual(Double(AudioLevelMeter.rms(buffer)), 0.3536, accuracy: 1e-3)
    }

    private static func testInt16FullScaleSquare() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        let channel = buffer.int16ChannelData![0]
        for index in 0..<1_600 {
            channel[index] = (index / 8).isMultiple(of: 2) ? Int16.max : Int16.min
        }
        TestSupport.expectApproximatelyEqual(Double(AudioLevelMeter.rms(buffer)), 1.0, accuracy: 1e-3)
    }

    /// The meter averages every sample of every channel, so a silent second
    /// channel halves the mean square.
    private static func testNonInterleavedStereoAveragesEveryChannel() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        for index in 0..<4_800 {
            left[index] = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(index) / 48_000))
            right[index] = 0
        }
        TestSupport.expectApproximatelyEqual(Double(AudioLevelMeter.rms(buffer)), 0.25, accuracy: 1e-3)
    }

    private static func testEmptyBuffer() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
        buffer.frameLength = 0
        TestSupport.expectEqual(AudioLevelMeter.rms(buffer), 0)
    }

    private static func testDecibels() {
        TestSupport.expectApproximatelyEqual(Double(AudioLevelMeter.dbfs(0.002)), -53.98, accuracy: 0.01)
        TestSupport.expectApproximatelyEqual(Double(AudioLevelMeter.dbfs(1)), 0, accuracy: 1e-6)
        TestSupport.expectApproximatelyEqual(Double(AudioLevelMeter.dbfs(0)), -180, accuracy: 1e-3)
    }
}
