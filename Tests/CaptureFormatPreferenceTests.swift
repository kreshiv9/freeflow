import AVFAudio
import Foundation

enum CaptureFormatPreferenceTests {
    static func run() {
        testDefaultAndStorage()
        testLabels()
        testNativeAudioSettings()
        testLegacyAudioSettings()
    }

    private static let sampleRateConverterKeys = [
        AVSampleRateConverterAlgorithmKey,
        AVSampleRateConverterAudioQualityKey,
    ]

    private static func testDefaultAndStorage() {
        let suite = "FreeFlowTests.CaptureFormat.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(CaptureFormatPreference.defaultValue, .native)
        TestSupport.expectEqual(CaptureFormatPreference.storageKey, "capture_format")
        TestSupport.expectEqual(CaptureFormatPreference.allCases, [.native, .legacy16k])
        TestSupport.expectEqual(CaptureFormatPreference.allCases.map(\.rawValue), ["native", "legacy16k"])
        for format in CaptureFormatPreference.allCases {
            TestSupport.expectEqual(format.id, format.rawValue)
        }

        TestSupport.expectEqual(CaptureFormatPreference.load(from: defaults), .native)
        TestSupport.expect(
            defaults.object(forKey: CaptureFormatPreference.storageKey) == nil,
            "Loading the default must not persist a capture format"
        )

        defaults.set("invalid", forKey: CaptureFormatPreference.storageKey)
        TestSupport.expectEqual(CaptureFormatPreference.load(from: defaults), .native)
        defaults.set(2, forKey: CaptureFormatPreference.storageKey)
        TestSupport.expectEqual(CaptureFormatPreference.load(from: defaults), .native)

        for format in CaptureFormatPreference.allCases {
            format.save(to: defaults)
            let reloaded = UserDefaults(suiteName: suite)!
            TestSupport.expectEqual(reloaded.object(forKey: CaptureFormatPreference.storageKey) as? String, format.rawValue)
            TestSupport.expectEqual(CaptureFormatPreference.load(from: reloaded), format)
        }
    }

    private static func testLabels() {
        TestSupport.expectEqual(
            CaptureFormatPreference.allCases.map(\.displayName),
            ["Native rate (recommended)", "16 kHz (previous)"]
        )
        TestSupport.expectEqual(
            CaptureFormatPreference.caption,
            "Native rate records at your microphone's own rate (48 kHz on a MacBook mic) and converts to 16 kHz with a high-quality filter. 16 kHz (previous) lets macOS do that conversion, as earlier versions did. Both save a 16 kHz recording and stream 16 kHz to Deepgram."
        )
    }

    /// No sample rate: the capture output delivers the device's own rate.
    private static func testNativeAudioSettings() {
        let settings = CaptureFormatPreference.native.audioSettings()
        TestSupport.expect(settings[AVSampleRateKey] == nil, "Native capture must not request a sample rate")
        TestSupport.expectEqual(settings[AVFormatIDKey] as? AudioFormatID, kAudioFormatLinearPCM)
        TestSupport.expectEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        TestSupport.expectEqual(settings[AVLinearPCMBitDepthKey] as? Int, 32)
        TestSupport.expectEqual(settings[AVLinearPCMIsFloatKey] as? Bool, true)
        TestSupport.expectEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
        TestSupport.expectEqual(settings[AVLinearPCMIsNonInterleaved] as? Bool, false)
        for key in sampleRateConverterKeys {
            TestSupport.expect(settings[key] == nil, "Native capture must not set \(key)")
        }
    }

    /// Pins the request earlier versions made, so the A/B stays a true "previous".
    private static func testLegacyAudioSettings() {
        let settings = CaptureFormatPreference.legacy16k.audioSettings()
        TestSupport.expectEqual(settings[AVSampleRateKey] as? Double, 16_000)
        TestSupport.expectEqual(settings[AVFormatIDKey] as? AudioFormatID, kAudioFormatLinearPCM)
        TestSupport.expectEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        TestSupport.expectEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        TestSupport.expectEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
        TestSupport.expectEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
        TestSupport.expectEqual(settings[AVLinearPCMIsNonInterleaved] as? Bool, false)
        TestSupport.expectEqual(
            Set(settings.keys),
            Set(CaptureFormatPreference.native.audioSettings().keys).union([AVSampleRateKey])
        )
        for key in sampleRateConverterKeys {
            TestSupport.expect(settings[key] == nil, "Legacy capture must not set \(key)")
        }
    }
}
