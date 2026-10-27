import Foundation

@main
struct FreeFlowTests {
    static func main() async {
        AppContextServiceTests.run()
        await LLMAPITransportTests.run()
        TemperatureCapabilityCacheTests.run()
        ModelConfigurationTests.run()
        RecordingCaptureTimingTests.run()
        SpeechActivityTrackerTests.run()
        PipelineStageTimingsTests.run()
        RecordingTimerPreferenceTests.run()
        SilenceGatePreferenceTests.run()
        AIAppRawTranscriptPreferenceTests.run()
        CleanupLevelTests.run()
        DictationStyleTests.run()
        DictionaryCorrectionsTests.run()
        SnippetExpansionTests.run()
        CursorFormattingTests.run()
        OriginalFieldInsertionPreferenceTests.run()
        ShortcutCoreTests.run()
        SemanticVersionTests.run()
        LLMCooldownManagerTests.run()
        PostProcessingServiceTests.run()
        TranscriptionErrorPresentationCoreTests.run()
        TranscriptTextCoreTests.run()
        AppTextInsertionCoreTests.run()
        AppTextInsertionDispatchTests.run()
        await TextContextCoreTests.run()
        await TranscriptionServiceTests.run()
        await APIConfigurationDraftTests.run()
        print("FreeFlowTests passed")
    }
}
