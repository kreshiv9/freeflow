import Darwin
import Foundation

/// The hook's frame buffer and a real AF_UNIX socket in a short temporary path, with invented
/// frames and an injected peer check. No hook and no real settings file are involved.
enum ClaudeHookListenerTests {
    static func run() {
        testFrameBuffer()
        testDeliversFrameFromSameUser()
        testWrongUserIsClosedUnread()
        testOversizedFrameIsDropped()
        testMalformedFrameDeliversNothing()
        testWorstCaseFrameDoesNotHoldUpStop()
        testSilentPeerIsClosedByDeadline()
        testConnectionLimit()
        testFilesystemModes()
        testRefusesUnsafePaths()
        testStaleSocketIsReplaced()
        testStopClosesEverything()
    }

    // MARK: Fixtures

    private static let waitSeconds = 20

    /// Frames in arrival order, safe to read after `stop()` or a semaphore wait.
    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [HookPrompt.Frame] = []
        let arrived = DispatchSemaphore(value: 0)

        func append(_ frame: HookPrompt.Frame) {
            lock.lock()
            stored.append(frame)
            lock.unlock()
            arrived.signal()
        }

        var frames: [HookPrompt.Frame] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// A short temporary base: a socket path must fit in sun_path.
    private static func withSupportDirectory(_ body: (URL) -> Void) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ffh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        body(directory)
    }

    private static func socketURL(_ support: URL) -> URL {
        ClaudeHookListener.socketURL(applicationSupport: support, appName: "Test")
    }

    /// A blocking client that never raises SIGPIPE and gives up on a read after `waitSeconds`.
    private static func connect(to url: URL) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: waitSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// Writes all it can, as `nc` does, then signals the end of its input. A peer may close first.
    private static func send(_ data: Data, on fd: Int32) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 {
                    if written < 0, errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
        Darwin.shutdown(fd, SHUT_WR)
    }

    /// Blocks until the listener closes this connection. True when it did.
    private static func waitForClose(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 { return true }
            if count < 0, errno == EINTR { continue }
            return count < 0 && errno == ECONNRESET
        }
    }

    private static func promptFrame(totalBytes: Int) -> Data {
        let prefix = #"{"prompt":"#, suffix = "\"}"
        let filler = String(repeating: "a", count: totalBytes - prefix.utf8.count - suffix.utf8.count - 1)
        return Data((prefix + "\"" + filler + suffix).utf8)
    }

    // MARK: Tests

    private static func testFrameBuffer() {
        var buffer = HookFrameBuffer()
        TestSupport.expect(buffer.append(Data(#"{"prompt":"#.utf8)), "Under the cap")
        TestSupport.expect(buffer.append(Data(#""synthetic words"}"#.utf8)), "Under the cap")
        TestSupport.expectEqual(buffer.finish(), .prompt("synthetic words"))

        var exact = HookFrameBuffer()
        TestSupport.expect(exact.append(promptFrame(totalBytes: HookFrameBuffer.maxBytes)), "Exactly the cap fits")
        if case .prompt = exact.finish() {} else {
            TestSupport.expect(false, "Exactly the cap parses")
        }
        var over = HookFrameBuffer()
        TestSupport.expect(!over.append(promptFrame(totalBytes: HookFrameBuffer.maxBytes + 1)), "One byte over is refused")
        TestSupport.expectEqual(over.finish(), .malformed)
        TestSupport.expectEqual(HookFrameBuffer.maxBytes, 256 * 1024)
    }

    private static func testDeliversFrameFromSameUser() {
        withSupportDirectory { support in
            let box = FrameBox()
            let listener = ClaudeHookListener(socketURL: socketURL(support), onFrame: box.append)
            TestSupport.expectEqual(listener.start(), nil)
            defer { listener.stop() }
            guard let fd = connect(to: socketURL(support)) else {
                TestSupport.expect(false, "A client connects")
                return
            }
            defer { Darwin.close(fd) }
            send(Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"<ide_selection>x</ide_selection>\nsynthetic words","cwd":"/synthetic"}"#.utf8), on: fd)
            TestSupport.expectEqual(box.arrived.wait(timeout: .now() + .seconds(waitSeconds)), .success)
            TestSupport.expectEqual(box.frames, [.prompt("synthetic words")])
            TestSupport.expect(waitForClose(fd), "The connection closes after its frame")

            guard let slash = connect(to: socketURL(support)) else {
                TestSupport.expect(false, "A second client connects")
                return
            }
            defer { Darwin.close(slash) }
            send(Data(#"{"prompt":"/compact"}"#.utf8), on: slash)
            TestSupport.expectEqual(box.arrived.wait(timeout: .now() + .seconds(waitSeconds)), .success)
            TestSupport.expectEqual(box.frames, [.prompt("synthetic words"), .skipped])
        }
    }

    private static func testWrongUserIsClosedUnread() {
        withSupportDirectory { support in
            let box = FrameBox()
            let listener = ClaudeHookListener(socketURL: socketURL(support), peerAllowed: { _ in false }, onFrame: box.append)
            TestSupport.expectEqual(listener.start(), nil)
            guard let fd = connect(to: socketURL(support)) else {
                TestSupport.expect(false, "A client connects")
                return
            }
            defer { Darwin.close(fd) }
            send(Data(#"{"prompt":"synthetic words"}"#.utf8), on: fd)
            TestSupport.expect(waitForClose(fd), "A peer of another user is closed")
            listener.stop()
            TestSupport.expectEqual(box.frames, [])
        }
    }

    private static func testOversizedFrameIsDropped() {
        withSupportDirectory { support in
            let box = FrameBox()
            let listener = ClaudeHookListener(socketURL: socketURL(support), onFrame: box.append)
            TestSupport.expectEqual(listener.start(), nil)
            defer { listener.stop() }
            guard let over = connect(to: socketURL(support)) else {
                TestSupport.expect(false, "A client connects")
                return
            }
            defer { Darwin.close(over) }
            send(promptFrame(totalBytes: HookFrameBuffer.maxBytes + 1), on: over)
            TestSupport.expect(waitForClose(over), "An oversized frame closes the connection")
            TestSupport.expectEqual(box.frames, [])

            guard let exact = connect(to: socketURL(support)) else {
                TestSupport.expect(false, "A client connects")
                return
            }
            defer { Darwin.close(exact) }
            send(promptFrame(totalBytes: HookFrameBuffer.maxBytes), on: exact)
            TestSupport.expectEqual(box.arrived.wait(timeout: .now() + .seconds(waitSeconds)), .success)
            TestSupport.expectEqual(box.frames.count, 1)
            if case .prompt = box.frames.first {} else {
                TestSupport.expect(false, "Exactly the cap is parsed")
            }
        }
    }

    private static func testMalformedFrameDeliversNothing() {
        withSupportDirectory { support in
            let box = FrameBox()
            let listener = ClaudeHookListener(socketURL: socketURL(support), onFrame: box.append)
            TestSupport.expectEqual(listener.start(), nil)
            guard let fd = connect(to: socketURL(support)) else {
                TestSupport.expect(false, "A client connects")
                return
            }
            defer { Darwin.close(fd) }
            send(Data("{not json".utf8), on: fd)
            TestSupport.expect(waitForClose(fd), "A malformed frame closes the connection")
            listener.stop()
            TestSupport.expectEqual(box.frames, [])
        }
    }

    /// stop() waits on the listener's queue, which parses untrusted frames, on the main thread.
    private static func testWorstCaseFrameDoesNotHoldUpStop() {
        withSupportDirectory { support in
            let box = FrameBox()
            let listener = ClaudeHookListener(socketURL: socketURL(support), onFrame: box.append)
            TestSupport.expectEqual(listener.start(), nil)
            guard let fd = connect(to: socketURL(support)) else {
                TestSupport.expect(false, "A client connects")
                return
            }
            defer { Darwin.close(fd) }
            let prefix = #"{"prompt":""#, suffix = "\"}", piece = "<browser x "
            let room = HookFrameBuffer.maxBytes - prefix.utf8.count - suffix.utf8.count
            send(Data((prefix + String(repeating: piece, count: room / piece.utf8.count) + suffix).utf8), on: fd)
            // The parse is done within seconds, and stop() waits for nothing longer.
            TestSupport.expectEqual(box.arrived.wait(timeout: .now() + .seconds(5)), .success)
            let stopping = Date()
            listener.stop()
            TestSupport.expect(Date().timeIntervalSince(stopping) < 5, "stop() returns at once")
            TestSupport.expectEqual(box.frames.count, 1)
        }
    }

    private static func testSilentPeerIsClosedByDeadline() {
        withSupportDirectory { support in
            let box = FrameBox()
            let listener = ClaudeHookListener(socketURL: socketURL(support), frameDeadline: 0.05, onFrame: box.append)
            TestSupport.expectEqual(listener.start(), nil)
            guard let fd = connect(to: socketURL(support)) else {
                TestSupport.expect(false, "A client connects")
                return
            }
            defer { Darwin.close(fd) }
            TestSupport.expect(waitForClose(fd), "A silent peer is closed by the deadline")
            listener.stop()
            TestSupport.expectEqual(box.frames, [])
        }
    }

    private static func testConnectionLimit() {
        withSupportDirectory { support in
            let box = FrameBox()
            let listener = ClaudeHookListener(socketURL: socketURL(support), frameDeadline: 120, onFrame: box.append)
            TestSupport.expectEqual(listener.start(), nil)
            defer { listener.stop() }
            var clients: [Int32] = []
            defer { clients.forEach { Darwin.close($0) } }
            // The clients connect one at a time in case the backlog is momentarily full. Every
            // earlier client stays open, so the last is over the limit whatever the timing.
            func connectRetrying() -> Int32? {
                for _ in 0..<500 {
                    if let fd = connect(to: socketURL(support)) { return fd }
                    usleep(10_000)
                }
                return nil
            }
            for _ in 0..<ClaudeHookListener.maxConnections {
                guard let fd = connectRetrying() else {
                    TestSupport.expect(false, "A client within the limit connects")
                    return
                }
                clients.append(fd)
            }
            guard let extra = connectRetrying() else {
                TestSupport.expect(false, "One more client reaches the listener")
                return
            }
            clients.append(extra)
            TestSupport.expect(waitForClose(extra), "The connection over the limit is closed")
        }
    }

    private static func mode(of url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    private static func testFilesystemModes() {
        withSupportDirectory { support in
            let listener = ClaudeHookListener(socketURL: socketURL(support), onFrame: { _ in })
            TestSupport.expectEqual(listener.start(), nil)
            TestSupport.expectEqual(mode(of: socketURL(support).deletingLastPathComponent()), 0o700)
            TestSupport.expectEqual(mode(of: socketURL(support)), 0o600)
            listener.stop()
        }
        // A directory that already exists is narrowed.
        withSupportDirectory { support in
            let directory = socketURL(support).deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            chmod(directory.path, 0o755)
            let listener = ClaudeHookListener(socketURL: socketURL(support), onFrame: { _ in })
            TestSupport.expectEqual(listener.start(), nil)
            TestSupport.expectEqual(mode(of: directory), 0o700)
            TestSupport.expectEqual(mode(of: socketURL(support)), 0o600)
            listener.stop()
        }
    }

    private static func testRefusesUnsafePaths() {
        // A symlink in place of the directory.
        withSupportDirectory { support in
            let real = support.appendingPathComponent("real", isDirectory: true)
            let directory = socketURL(support).deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(
                at: directory.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.createSymbolicLink(at: directory, withDestinationURL: real)
            let listener = ClaudeHookListener(socketURL: socketURL(support), onFrame: { _ in })
            TestSupport.expectEqual(listener.start(), .unsafeDirectory)
            TestSupport.expectEqual(try? FileManager.default.contentsOfDirectory(atPath: real.path), [])
        }
        // A regular file at the socket path is not replaced.
        withSupportDirectory { support in
            let url = socketURL(support)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("synthetic".utf8).write(to: url)
            let listener = ClaudeHookListener(socketURL: url, onFrame: { _ in })
            TestSupport.expectEqual(listener.start(), .pathOccupied)
            TestSupport.expectEqual(try? Data(contentsOf: url), Data("synthetic".utf8))
        }
        // A path that does not fit in sun_path.
        withSupportDirectory { support in
            let long = ClaudeHookListener.socketURL(applicationSupport: support, appName: String(repeating: "x", count: 120))
            let listener = ClaudeHookListener(socketURL: long, onFrame: { _ in })
            TestSupport.expectEqual(listener.start(), .pathTooLong)
            TestSupport.expect(!FileManager.default.fileExists(atPath: long.deletingLastPathComponent().path), "Nothing is created")
        }
    }

    private static func testStaleSocketIsReplaced() {
        withSupportDirectory { support in
            let url = socketURL(support)
            // A socket left behind: bound and closed without an unlink.
            let first = ClaudeHookListener(socketURL: url, onFrame: { _ in })
            TestSupport.expectEqual(first.start(), nil)
            let kept = url.appendingPathExtension("kept")
            rename(url.path, kept.path)
            first.stop()
            rename(kept.path, url.path)
            TestSupport.expect(FileManager.default.fileExists(atPath: url.path), "The stale socket file is there")

            let box = FrameBox()
            let listener = ClaudeHookListener(socketURL: url, onFrame: box.append)
            TestSupport.expectEqual(listener.start(), nil)
            defer { listener.stop() }
            guard let fd = connect(to: url) else {
                TestSupport.expect(false, "A client reaches the new socket")
                return
            }
            defer { Darwin.close(fd) }
            send(Data(#"{"prompt":"synthetic words"}"#.utf8), on: fd)
            TestSupport.expectEqual(box.arrived.wait(timeout: .now() + .seconds(waitSeconds)), .success)
        }
    }

    /// W12: the kill switch closes the socket.
    private static func testStopClosesEverything() {
        withSupportDirectory { support in
            let url = socketURL(support)
            let box = FrameBox()
            let listener = ClaudeHookListener(socketURL: url, frameDeadline: 120, onFrame: box.append)
            TestSupport.expectEqual(listener.start(), nil)
            guard let open = connect(to: url) else {
                TestSupport.expect(false, "A client connects")
                return
            }
            defer { Darwin.close(open) }
            // Accepted yet or still in the backlog, the client is closed either way.
            listener.stop()
            TestSupport.expect(waitForClose(open), "An open connection is closed")
            TestSupport.expect(!FileManager.default.fileExists(atPath: url.path), "The socket file is gone")
            TestSupport.expectEqual(connect(to: url), nil)
            TestSupport.expectEqual(box.frames, [])
            // It can listen again after a stop.
            TestSupport.expectEqual(listener.start(), nil)
            TestSupport.expect(FileManager.default.fileExists(atPath: url.path), "The socket file is back")
            listener.stop()
        }
    }
}
