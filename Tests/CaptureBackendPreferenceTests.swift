import Foundation

/// Storage, labels and the start-time gate for the experimental capture
/// backend. Pure: no engine, device or microphone; synthetic device UIDs only.
enum CaptureBackendPreferenceTests {
    static func run() {
        testDefaultAndStorage()
        testLabels()
        testReasonLabelsAndMessages()
        testStandardNeverResolvesToVoiceProcessing()
        testVoiceProcessingResolvesWhenAllowed()
        testFallbackReasonsAndPrecedence()
        testUnavailableReason()
        testDefaultInputSelection()
    }

    private typealias Resolution = CaptureBackendPreference.Resolution

    private static func testDefaultAndStorage() {
        let suite = "FreeFlowTests.CaptureBackend.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(CaptureBackendPreference.defaultValue, .standard)
        TestSupport.expectEqual(CaptureBackendPreference.storageKey, "capture_backend")
        TestSupport.expectEqual(CaptureBackendPreference.allCases, [.standard, .appleVoiceProcessing])
        TestSupport.expectEqual(CaptureBackendPreference.allCases.map(\.rawValue), ["standard", "appleVoiceProcessing"])
        for backend in CaptureBackendPreference.allCases {
            TestSupport.expectEqual(backend.id, backend.rawValue)
        }

        TestSupport.expectEqual(CaptureBackendPreference.load(from: defaults), .standard)
        TestSupport.expect(
            defaults.object(forKey: CaptureBackendPreference.storageKey) == nil,
            "Loading the default must not persist a capture backend"
        )

        let invalidValues: [Any] = ["invalid", "voiceProcessing", "", 1, true]
        for value in invalidValues {
            defaults.set(value, forKey: CaptureBackendPreference.storageKey)
            TestSupport.expectEqual(CaptureBackendPreference.load(from: defaults), .standard)
        }

        for backend in CaptureBackendPreference.allCases {
            backend.save(to: defaults)
            let reloaded = UserDefaults(suiteName: suite)!
            TestSupport.expectEqual(reloaded.object(forKey: CaptureBackendPreference.storageKey) as? String, backend.rawValue)
            TestSupport.expectEqual(CaptureBackendPreference.load(from: reloaded), backend)
        }
    }

    private static func testLabels() {
        TestSupport.expectEqual(
            CaptureBackendPreference.allCases.map(\.displayName),
            ["Standard (recommended)", "Apple voice processing (experimental)"]
        )
        TestSupport.expectEqual(
            CaptureBackendPreference.caption,
            "Apple voice processing turns on the macOS Mic Mode menu for this app while you record (Control Center > Mic Mode > Voice Isolation). That system mode is separate from the Voice isolation setting above; leave that Off while you use Mic Mode Voice Isolation, since running both can clip the start of words. Experimental: it may lower other apps' volume while you dictate, works only with the System Default microphone and the Native rate format, and switches back to Standard automatically if it fails."
        )
    }

    /// Raw values appear in logs and messages in the UI; both are content-free.
    private static func testReasonLabelsAndMessages() {
        let reasons: [CaptureBackendPreference.FallbackReason] = [
            .requiresMacOS14,
            .requiresNativeFormat,
            .requiresDefaultMicrophone,
        ]
        TestSupport.expectEqual(
            reasons.map(\.rawValue),
            ["requiresMacOS14", "requiresNativeFormat", "requiresDefaultMicrophone"]
        )
        TestSupport.expectEqual(
            reasons.map(\.message),
            [
                "Apple voice processing needs macOS 14 or later.",
                "Apple voice processing needs the Native rate recording format.",
                "Apple voice processing works only with the System Default microphone.",
            ]
        )
    }

    private static func testStandardNeverResolvesToVoiceProcessing() {
        for osSupportsDucking in [false, true] {
            for isDefaultInputSelected in [false, true] {
                for captureFormat in CaptureFormatPreference.allCases {
                    TestSupport.expectEqual(
                        CaptureBackendPreference.resolve(
                            preference: .standard,
                            osSupportsDucking: osSupportsDucking,
                            isDefaultInputSelected: isDefaultInputSelected,
                            captureFormat: captureFormat
                        ),
                        Resolution(backend: .standard, reason: nil)
                    )
                }
            }
        }
    }

    private static func testVoiceProcessingResolvesWhenAllowed() {
        TestSupport.expectEqual(
            resolveVoiceProcessing(osSupportsDucking: true, isDefaultInputSelected: true, captureFormat: .native),
            Resolution(backend: .appleVoiceProcessing, reason: nil)
        )
    }

    private static func testFallbackReasonsAndPrecedence() {
        TestSupport.expectEqual(
            resolveVoiceProcessing(osSupportsDucking: false, isDefaultInputSelected: true, captureFormat: .native),
            Resolution(backend: .standard, reason: .requiresMacOS14)
        )
        TestSupport.expectEqual(
            resolveVoiceProcessing(osSupportsDucking: true, isDefaultInputSelected: true, captureFormat: .legacy16k),
            Resolution(backend: .standard, reason: .requiresNativeFormat)
        )
        TestSupport.expectEqual(
            resolveVoiceProcessing(osSupportsDucking: true, isDefaultInputSelected: false, captureFormat: .native),
            Resolution(backend: .standard, reason: .requiresDefaultMicrophone)
        )

        // OS first, then format, then microphone.
        TestSupport.expectEqual(
            resolveVoiceProcessing(osSupportsDucking: false, isDefaultInputSelected: false, captureFormat: .legacy16k),
            Resolution(backend: .standard, reason: .requiresMacOS14)
        )
        TestSupport.expectEqual(
            resolveVoiceProcessing(osSupportsDucking: true, isDefaultInputSelected: false, captureFormat: .legacy16k),
            Resolution(backend: .standard, reason: .requiresNativeFormat)
        )
    }

    /// The Settings picker is disabled only for OS and format; the microphone
    /// is checked at each start instead.
    private static func testUnavailableReason() {
        TestSupport.expectEqual(
            CaptureBackendPreference.unavailableReason(osSupportsDucking: true, captureFormat: .native),
            nil
        )
        TestSupport.expectEqual(
            CaptureBackendPreference.unavailableReason(osSupportsDucking: false, captureFormat: .native),
            .requiresMacOS14
        )
        TestSupport.expectEqual(
            CaptureBackendPreference.unavailableReason(osSupportsDucking: true, captureFormat: .legacy16k),
            .requiresNativeFormat
        )
        for osSupportsDucking in [false, true] {
            for captureFormat in CaptureFormatPreference.allCases {
                TestSupport.expect(
                    CaptureBackendPreference.unavailableReason(
                        osSupportsDucking: osSupportsDucking,
                        captureFormat: captureFormat
                    ) != .requiresDefaultMicrophone,
                    "The picker must never be disabled for the microphone"
                )
            }
        }
    }

    private static func testDefaultInputSelection() {
        for selected in [nil, "", "default"] as [String?] {
            for defaultUID in [nil, "Synthetic-Mic-A"] as [String?] {
                TestSupport.expect(
                    CaptureBackendPreference.isDefaultInputSelected(selectedDeviceUID: selected, defaultDeviceUID: defaultUID),
                    "System Default (\(String(describing: selected))) must count as the default input"
                )
            }
        }
        TestSupport.expect(
            CaptureBackendPreference.isDefaultInputSelected(selectedDeviceUID: "Synthetic-Mic-A", defaultDeviceUID: "Synthetic-Mic-A"),
            "The selected mic that is the current default must count as the default input"
        )
        TestSupport.expect(
            !CaptureBackendPreference.isDefaultInputSelected(selectedDeviceUID: "Synthetic-Mic-A", defaultDeviceUID: "Synthetic-Mic-B"),
            "A selected mic other than the default must not count as the default input"
        )
        TestSupport.expect(
            !CaptureBackendPreference.isDefaultInputSelected(selectedDeviceUID: "Synthetic-Mic-A", defaultDeviceUID: nil),
            "A selected mic with no default input must not count as the default input"
        )
        TestSupport.expect(
            !CaptureBackendPreference.isDefaultInputSelected(selectedDeviceUID: "synthetic-mic-a", defaultDeviceUID: "Synthetic-Mic-A"),
            "Device UIDs must match exactly"
        )
    }

    private static func resolveVoiceProcessing(
        osSupportsDucking: Bool,
        isDefaultInputSelected: Bool,
        captureFormat: CaptureFormatPreference
    ) -> Resolution {
        CaptureBackendPreference.resolve(
            preference: .appleVoiceProcessing,
            osSupportsDucking: osSupportsDucking,
            isDefaultInputSelected: isDefaultInputSelected,
            captureFormat: captureFormat
        )
    }
}
