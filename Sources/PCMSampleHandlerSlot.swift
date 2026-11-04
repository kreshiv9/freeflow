import Foundation

/// Thread-safe storage for the recorder's PCM16 samples handler, set and
/// cleared on main while the sample-buffer queue loads it once per chunk.
/// A plain stored property behind an NSLock on purpose: an
/// `OSAllocatedUnfairLock<((Data) -> Void)?>` reabstracts the closure through
/// its `inout State` and writes it back on every `withLock`, so each read
/// wrapped the handler in two more thunks until calling it overflowed the
/// capture queue's stack during long dictations.
final class PCMSampleHandlerSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Data) -> Void)?

    func load() -> ((Data) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    func store(_ newHandler: ((Data) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        handler = newHandler
    }
}
