import AVFAudio
import Foundation

/// The voice-processing capture's pure pieces: the start-time format check
/// and its content-free error labels. Never creates a
/// VoiceProcessingCapture, engine, input node, device or microphone.
enum VoiceProcessingCaptureTests {
    static func run() {
        testUsableInputFormatsPass()
        testHardwareFormatFailureCarriesHardwareFormat()
        testInputNodeOutputFailureCarriesNodeFormat()
        testErrorLabelsAndStatus()
    }

    private typealias Capture = VoiceProcessingCapture

    private static func label(hardware: Capture.FormatShape, inputNodeOutput: Capture.FormatShape) -> String? {
        Capture.inputFormatError(hardware: hardware, inputNodeOutput: inputNodeOutput)?.logLabel
    }

    private static func testUsableInputFormatsPass() {
        TestSupport.expectEqual(label(hardware: (1, 48_000), inputNodeOutput: (1, 48_000)), nil)
        TestSupport.expectEqual(label(hardware: (3, 48_000), inputNodeOutput: (1, 44_100)), nil)
        TestSupport.expectEqual(label(hardware: (9, 24_000), inputNodeOutput: (9, 24_000)), nil)
    }

    private static func testHardwareFormatFailureCarriesHardwareFormat() {
        TestSupport.expectEqual(label(hardware: (0, 48_000), inputNodeOutput: (1, 48_000)), "noInput channels=0 rate=48000.0")
        TestSupport.expectEqual(label(hardware: (1, 0), inputNodeOutput: (1, 48_000)), "noInput channels=1 rate=0.0")
        TestSupport.expectEqual(label(hardware: (1, .nan), inputNodeOutput: (1, 48_000)), "noInput channels=1 rate=nan")
        // Both unusable: the hardware format is reported first.
        TestSupport.expectEqual(label(hardware: (0, 0), inputNodeOutput: (0, 0)), "noInput channels=0 rate=0.0")
    }

    /// A valid hardware format must not hide an unusable voice-processed
    /// format: the error names the node format that failed.
    private static func testInputNodeOutputFailureCarriesNodeFormat() {
        TestSupport.expectEqual(
            label(hardware: (3, 48_000), inputNodeOutput: (0, 48_000)),
            "noInputNodeOutput channels=0 rate=48000.0"
        )
        TestSupport.expectEqual(
            label(hardware: (1, 48_000), inputNodeOutput: (1, 0)),
            "noInputNodeOutput channels=1 rate=0.0"
        )
        TestSupport.expectEqual(
            label(hardware: (1, 48_000), inputNodeOutput: (0, 0)),
            "noInputNodeOutput channels=0 rate=0.0"
        )
        TestSupport.expectEqual(
            label(hardware: (1, 48_000), inputNodeOutput: (1, -48_000)),
            "noInputNodeOutput channels=1 rate=-48000.0"
        )
    }

    /// Labels appear in logs: steps, channel counts and rates only.
    private static func testErrorLabelsAndStatus() {
        let cases: [(Capture.CaptureError, String, OSStatus)] = [
            (.unsupportedOS, "unsupportedOS", 0),
            (.noInput(channels: 0, sampleRate: 48_000), "noInput channels=0 rate=48000.0", 0),
            (.noInputNodeOutput(channels: 0, sampleRate: 48_000), "noInputNodeOutput channels=0 rate=48000.0", 0),
            (.noOutput(channels: 2, sampleRate: 0), "noOutput channels=2 rate=0.0", 0),
            (.invalidClientFormat, "invalidClientFormat", 0),
            (.failed(.enableVoiceProcessing, -10_849), "enableVoiceProcessing", -10_849),
            (.failed(.startEngine, -10_875), "startEngine", -10_875),
        ]
        for (error, expectedLabel, expectedStatus) in cases {
            TestSupport.expectEqual(error.logLabel, expectedLabel)
            TestSupport.expectEqual(error.status, expectedStatus)
        }
    }
}
