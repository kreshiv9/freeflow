import Foundation

enum PipelineStageTimingsTests {
    private static let base: CFAbsoluteTime = 700_000_000

    static func run() {
        testBuildsStagesFromMarks()
        testMissingMarksLeaveStagesNil()
        testSummaryLineFormatsMillisecondsAndSeconds()
        testSummaryLineOmitsMissingStages()
        testJSONRoundTrip()
        testHistoryItemRoundTripsWithAndWithoutTimings()
        testPasteGateSamplesMarkBeforeActionAndReportsAfter()
        testPasteGateReportsSkippedPasteOnce()
    }

    private static func testBuildsStagesFromMarks() {
        let marks = PipelineStageTimings.Marks(
            stopRequested: base,
            audioReady: base + 0.040,
            transcriptionStarted: base + 0.045,
            transcriptionFinished: base + 0.865,
            transcriptionSource: "realtime",
            contextStarted: base + 0.865,
            contextFinished: base + 0.865,
            cleanupStarted: base + 0.870,
            cleanupFinished: base + 1.480,
            pasteFired: base + 1.515
        )
        TestSupport.expectEqual(
            marks.timings,
            PipelineStageTimings(
                audioFinalizeMilliseconds: 40,
                transcriptionMilliseconds: 820,
                transcriptionSource: "realtime",
                contextWaitMilliseconds: 0,
                cleanupMilliseconds: 610,
                pasteDispatchMilliseconds: 35,
                totalMilliseconds: 1515
            )
        )

        // Sub-millisecond deltas round to the nearest millisecond.
        TestSupport.expectEqual(PipelineStageTimings.milliseconds(from: base, to: base + 0.0004), 0)
        TestSupport.expectEqual(PipelineStageTimings.milliseconds(from: base, to: base + 0.0006), 1)

        // A backwards wall clock clamps to zero instead of going negative.
        let backwards = PipelineStageTimings.Marks(stopRequested: base + 0.5, audioReady: base)
        TestSupport.expectEqual(backwards.timings.audioFinalizeMilliseconds, 0)
    }

    private static func testMissingMarksLeaveStagesNil() {
        TestSupport.expectEqual(PipelineStageTimings.Marks().timings, PipelineStageTimings())
        TestSupport.expectEqual(PipelineStageTimings.Marks().timings.summaryLine, "")

        let audioOnly = PipelineStageTimings.Marks(stopRequested: base, audioReady: base + 0.04).timings
        TestSupport.expectEqual(audioOnly, PipelineStageTimings(audioFinalizeMilliseconds: 40))

        var noPaste = PipelineStageTimings.Marks(stopRequested: base, audioReady: base + 0.04)
        noPaste.cleanupStarted = base + 0.5
        noPaste.cleanupFinished = base + 0.9
        TestSupport.expectEqual(noPaste.timings.cleanupMilliseconds, 400)
        TestSupport.expectEqual(noPaste.timings.pasteDispatchMilliseconds, nil)
        TestSupport.expectEqual(noPaste.timings.totalMilliseconds, nil)

        var unfinishedTranscription = PipelineStageTimings.Marks(stopRequested: base, audioReady: base + 0.04)
        unfinishedTranscription.transcriptionStarted = base + 0.05
        TestSupport.expectEqual(unfinishedTranscription.timings.transcriptionMilliseconds, nil)
        TestSupport.expectEqual(unfinishedTranscription.timings.transcriptionSource, nil)
    }

    private static func testSummaryLineFormatsMillisecondsAndSeconds() {
        let timings = PipelineStageTimings(
            audioFinalizeMilliseconds: 40,
            transcriptionMilliseconds: 820,
            contextWaitMilliseconds: 0,
            cleanupMilliseconds: 610,
            pasteDispatchMilliseconds: 35,
            totalMilliseconds: 1500
        )
        TestSupport.expectEqual(
            timings.summaryLine,
            "audio 40 ms · transcription 820 ms · context 0 ms · cleanup 610 ms · paste 35 ms · total 1.5 s"
        )

        var sourced = timings
        sourced.transcriptionSource = "realtime"
        TestSupport.expectEqual(
            sourced.summaryLine,
            "audio 40 ms · transcription 820 ms (realtime) · context 0 ms · cleanup 610 ms · paste 35 ms · total 1.5 s"
        )

        TestSupport.expectEqual(PipelineStageTimings.deepgramTranscriptionSource, "deepgram")
        sourced.transcriptionSource = "deepgram"
        TestSupport.expectEqual(
            sourced.summaryLine,
            "audio 40 ms · transcription 820 ms (deepgram) · context 0 ms · cleanup 610 ms · paste 35 ms · total 1.5 s"
        )

        TestSupport.expectEqual(PipelineStageTimings.formatted(milliseconds: 0), "0 ms")
        TestSupport.expectEqual(PipelineStageTimings.formatted(milliseconds: 999), "999 ms")
        TestSupport.expectEqual(PipelineStageTimings.formatted(milliseconds: 1000), "1.0 s")
        TestSupport.expectEqual(PipelineStageTimings.formatted(milliseconds: 1250), "1.3 s")
        TestSupport.expectEqual(PipelineStageTimings.formatted(milliseconds: 12345), "12.3 s")
        TestSupport.expectEqual(PipelineStageTimings.formatted(milliseconds: 60000), "60.0 s")
    }

    private static func testSummaryLineOmitsMissingStages() {
        TestSupport.expectEqual(
            PipelineStageTimings(transcriptionMilliseconds: 820, totalMilliseconds: 820).summaryLine,
            "transcription 820 ms · total 820 ms"
        )
        TestSupport.expectEqual(PipelineStageTimings(audioFinalizeMilliseconds: 40).summaryLine, "audio 40 ms")
        TestSupport.expectEqual(PipelineStageTimings().summaryLine, "")
    }

    private static func testJSONRoundTrip() {
        let timings = PipelineStageTimings(
            audioFinalizeMilliseconds: 40,
            transcriptionMilliseconds: 820,
            transcriptionSource: "file",
            contextWaitMilliseconds: 12,
            cleanupMilliseconds: 610,
            pasteDispatchMilliseconds: 35,
            totalMilliseconds: 1517
        )
        guard let json = timings.jsonString else {
            fatalError("Expected stage timings to encode as JSON")
        }
        TestSupport.expect(json.contains("\"transcriptionMilliseconds\":820"), "JSON must carry the stage value")
        TestSupport.expect(json.contains("\"transcriptionSource\":\"file\""), "JSON must carry the source")
        TestSupport.expectEqual(PipelineStageTimings(jsonString: json), timings)

        TestSupport.expectEqual(PipelineStageTimings(jsonString: "{}"), PipelineStageTimings())
        TestSupport.expectEqual(
            PipelineStageTimings(jsonString: "{\"transcriptionMilliseconds\":820}"),
            PipelineStageTimings(transcriptionMilliseconds: 820)
        )
        TestSupport.expectEqual(PipelineStageTimings(jsonString: "not json"), nil)
    }

    private static func testHistoryItemRoundTripsWithAndWithoutTimings() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let item = PipelineHistoryItem(
            timestamp: timestamp,
            rawTranscript: "synthetic raw transcript",
            postProcessedTranscript: "synthetic cleaned transcript",
            postProcessingPrompt: nil,
            contextSummary: "synthetic context",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "synthetic status",
            debugStatus: "Done",
            customVocabulary: ""
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        guard let encodedWithoutTimings = try? encoder.encode(item),
              let decoded = try? decoder.decode(PipelineHistoryItem.self, from: encodedWithoutTimings) else {
            fatalError("History item without timings must round-trip")
        }
        TestSupport.expectEqual(decoded.stageTimings, nil)
        TestSupport.expectEqual(decoded.id, item.id)
        TestSupport.expectEqual(decoded.rawTranscript, item.rawTranscript)
        TestSupport.expectEqual(decoded.postProcessedTranscript, item.postProcessedTranscript)
        TestSupport.expectEqual(decoded.contextSummary, item.contextSummary)
        TestSupport.expectEqual(decoded.postProcessingStatus, item.postProcessingStatus)
        TestSupport.expectEqual(decoded.debugStatus, item.debugStatus)
        TestSupport.expectEqual(decoded.intent, .dictation)
        // Old rows have no key at all, which is the path a nil value exercises.
        let jsonWithoutTimings = String(decoding: encodedWithoutTimings, as: UTF8.self)
        TestSupport.expect(!jsonWithoutTimings.contains("stageTimings"), "nil timings must be omitted")

        let timings = PipelineStageTimings(
            audioFinalizeMilliseconds: 40,
            transcriptionMilliseconds: 820,
            transcriptionSource: "realtime",
            contextWaitMilliseconds: 0,
            cleanupMilliseconds: 610,
            pasteDispatchMilliseconds: 35,
            totalMilliseconds: 1515
        )
        let timedItem = PipelineHistoryItem(
            timestamp: timestamp,
            rawTranscript: "synthetic raw transcript",
            postProcessedTranscript: "synthetic cleaned transcript",
            postProcessingPrompt: nil,
            contextSummary: "synthetic context",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "synthetic status",
            debugStatus: "Done",
            customVocabulary: "",
            stageTimings: timings
        )
        guard let encodedWithTimings = try? encoder.encode(timedItem),
              let decodedTimed = try? decoder.decode(PipelineHistoryItem.self, from: encodedWithTimings) else {
            fatalError("History item with timings must round-trip")
        }
        TestSupport.expectEqual(decodedTimed.stageTimings, timings)
    }

    /// The paste-fired mark must be sampled when the gate opens, and the
    /// handler's bookkeeping must run only after the gated action has dispatched
    /// the paste, so the store write never sits ahead of the keystroke and the
    /// recorded mark excludes it.
    private static func testPasteGateSamplesMarkBeforeActionAndReportsAfter() {
        var clock = base
        var events: [String] = []
        var reported: [CFAbsoluteTime?] = []
        let gate = PipelineStageTimings.PasteGate(now: { clock })
        gate.schedule { firedAt in
            events.append("handler")
            reported.append(firedAt)
        }
        let gated = gate.wrappingScheduledPaste {
            // The paste itself advances the clock; the mark must predate it.
            clock += 0.014
            events.append("action")
        }
        TestSupport.expect(events.isEmpty, "Wrapping must not run the action or handler until the gate opens")

        gated()
        TestSupport.expectEqual(events, ["action", "handler"])
        TestSupport.expectEqual(reported, [base])

        // Wrapping consumed the handler, so later gated actions run bare.
        var bareRuns = 0
        let bare = gate.wrappingScheduledPaste { bareRuns += 1 }
        bare()
        TestSupport.expectEqual(bareRuns, 1)
        TestSupport.expectEqual(reported, [base])

        // The mark feeds the paste and total stages like any other mark.
        var marks = PipelineStageTimings.Marks(stopRequested: base - 1.0)
        marks.cleanupFinished = base - 0.035
        marks.pasteFired = reported.first ?? nil
        TestSupport.expectEqual(marks.timings.pasteDispatchMilliseconds, 35)
        TestSupport.expectEqual(marks.timings.totalMilliseconds, 1000)
    }

    /// A gated action that returns without pasting or inserting reports that
    /// itself; the handler then receives nil exactly once so the paste and
    /// total stages stay empty, and the gate's own post-action report is
    /// ignored.
    private static func testPasteGateReportsSkippedPasteOnce() {
        var reported: [CFAbsoluteTime?] = []
        let gate = PipelineStageTimings.PasteGate(now: { base })
        gate.schedule { reported.append($0) }
        let skipped = gate.wrappingScheduledPaste {
            gate.report(dispatched: false)
            gate.report(dispatched: true)
        }
        skipped()
        TestSupport.expectEqual(reported, [nil])

        // Outside a gated action nothing is armed, so reports are no-ops.
        gate.report(dispatched: false)
        gate.report(dispatched: true)
        TestSupport.expectEqual(reported, [nil])

        var marks = PipelineStageTimings.Marks(stopRequested: base - 1.0)
        marks.cleanupFinished = base - 0.035
        marks.pasteFired = reported.first ?? nil
        TestSupport.expectEqual(marks.timings.pasteDispatchMilliseconds, nil)
        TestSupport.expectEqual(marks.timings.totalMilliseconds, nil)
    }
}
