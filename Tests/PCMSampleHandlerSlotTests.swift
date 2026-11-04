import Foundation

/// Synthetic handlers and empty Data only. The capture queue loads the
/// handler once per chunk, so loading must never deepen the call it makes.
enum PCMSampleHandlerSlotTests {
    static func run() {
        testRepeatedLoadsKeepCallDepthConstant()
        testLatestStoredHandlerIsCalled()
        testStoringNilClearsHandler()
    }

    /// Regression: an OSAllocatedUnfairLock<closure> slot wrapped the handler
    /// in two more thunks per read, which overflowed the capture-queue stack.
    private static func testRepeatedLoadsKeepCallDepthConstant() {
        let slot = PCMSampleHandlerSlot()
        var depth = 0
        slot.store { _ in depth = Thread.callStackReturnAddresses.count }

        slot.load()?(Data())
        let baseline = depth
        TestSupport.expect(baseline > 0, "Handler must run after one load")

        var latest = slot.load()
        for _ in 1..<20_000 {
            latest = slot.load()
        }
        latest?(Data())
        TestSupport.expect(
            depth <= baseline + 2,
            "Handler ran \(depth) frames deep after 20,000 loads, \(baseline) after one"
        )
    }

    private static func testLatestStoredHandlerIsCalled() {
        let slot = PCMSampleHandlerSlot()
        var calls: [String] = []
        slot.store { _ in calls.append("first") }
        slot.store { data in calls.append("second:\(data.count)") }

        slot.load()?(Data([0x01, 0x00]))
        TestSupport.expectEqual(calls, ["second:2"])
    }

    private static func testStoringNilClearsHandler() {
        let slot = PCMSampleHandlerSlot()
        TestSupport.expect(slot.load() == nil, "A new slot must start empty")

        var calls = 0
        slot.store { _ in calls += 1 }
        slot.store(nil)
        TestSupport.expect(slot.load() == nil, "Storing nil must clear the handler")
        slot.load()?(Data())
        TestSupport.expectEqual(calls, 0)
    }
}
