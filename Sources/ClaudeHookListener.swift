import Darwin
import Foundation
import os.log

private let hookListenerLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "ClaudeHookListener")

/// Collects one connection's bytes up to `maxBytes`. A frame ends when the sender closes.
struct HookFrameBuffer {
    static let maxBytes = 256 * 1024

    private var bytes = Data()

    /// False once the input is over the cap; what came before is dropped unparsed.
    mutating func append(_ chunk: Data) -> Bool {
        guard bytes.count + chunk.count <= Self.maxBytes else {
            bytes = Data()
            return false
        }
        bytes.append(chunk)
        return true
    }

    func finish() -> HookPrompt.Frame {
        HookPrompt.frame(from: bytes)
    }
}

/// The local Unix socket the Claude Code hook writes to. The socket sits in a 0700 directory
/// with mode 0600, and a peer of another user is closed before anything is read. Frames stay in
/// memory: oversized and malformed ones are dropped, and the rest go to `onFrame` on the
/// listener's queue. Logs carry errno and counts only, never frame contents.
final class ClaudeHookListener {
    enum StartFailure: Equatable {
        /// `learn` is a symlink, another user's, or could not be created or secured.
        case unsafeDirectory
        case pathTooLong
        /// Something other than a socket is at the socket path.
        case pathOccupied
        case socketError(errno: Int32)
    }

    static let frameDeadline: TimeInterval = 3
    static let maxConnections = 8

    private final class Connection {
        let source: DispatchSourceRead
        var buffer = HookFrameBuffer()

        init(source: DispatchSourceRead) {
            self.source = source
        }
    }

    private let socketURL: URL
    private let peerAllowed: (Int32) -> Bool
    private let frameDeadline: TimeInterval
    private let onFrame: (HookPrompt.Frame) -> Void
    private let queue = DispatchQueue(label: "com.zachlatta.freeflow.claude-hook-listener")

    // Every property below is guarded by `queue`.
    private var listenSource: DispatchSourceRead?
    private var connections: [UInt64: Connection] = [:]
    private var nextConnectionID: UInt64 = 0

    init(
        socketURL: URL,
        peerAllowed: @escaping (Int32) -> Bool = ClaudeHookListener.sameUser,
        frameDeadline: TimeInterval = ClaudeHookListener.frameDeadline,
        onFrame: @escaping (HookPrompt.Frame) -> Void
    ) {
        self.socketURL = socketURL
        self.peerAllowed = peerAllowed
        self.frameDeadline = frameDeadline
        self.onFrame = onFrame
    }

    deinit {
        // No other reference exists here, so the queue is not needed.
        stopLocked()
    }

    /// `<support>/<appName>/learn/hook.sock`: FreeFlow and FreeFlow Dev differ.
    static func socketURL(applicationSupport: URL, appName: String) -> URL {
        applicationSupport
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("learn", isDirectory: true)
            .appendingPathComponent("hook.sock")
    }

    /// The peer runs as this user.
    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// Nil once listening. A second start while listening does nothing.
    func start() -> StartFailure? {
        queue.sync { startLocked() }
    }

    /// Closes the listener and every connection and removes the socket file. Not from `onFrame`.
    /// It waits on the queue that parses frames, which takes linear time (HookPrompt.userText).
    func stop() {
        queue.sync { stopLocked() }
    }

    private func startLocked() -> StartFailure? {
        guard listenSource == nil else { return nil }
        var address = sockaddr_un()
        let path = Array(socketURL.path.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return .pathTooLong }
        guard preparedDirectory() else { return .unsafeDirectory }

        var existing = stat()
        if lstat(socketURL.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK else { return .pathOccupied }
            Darwin.unlink(socketURL.path)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .socketError(errno: errno) }
        func fail() -> StartFailure {
            let failure = StartFailure.socketError(errno: errno)
            Darwin.close(fd)
            Darwin.unlink(socketURL.path)
            return failure
        }
        guard configure(fd) else { return fail() }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(socketURL.path, 0o600) == 0, Darwin.listen(fd, Int32(Self.maxConnections)) == 0 else {
            return fail()
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPending(on: fd)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        listenSource = source
        source.resume()
        return nil
    }

    private func stopLocked() {
        guard let source = listenSource else { return }
        listenSource = nil
        source.cancel()
        for connection in connections.values { connection.source.cancel() }
        connections.removeAll()
        Darwin.unlink(socketURL.path)
    }

    /// Creates `learn` with mode 0700. An existing one must be a real directory of this user,
    /// and is narrowed to 0700.
    private func preparedDirectory() -> Bool {
        let directory = socketURL.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true
        )) != nil else { return false }
        if Darwin.mkdir(directory.path, 0o700) != 0, errno != EEXIST { return false }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return false }
        return chmod(directory.path, 0o700) == 0
    }

    private func configure(_ fd: Int32) -> Bool {
        fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0
    }

    private func acceptPending(on listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR { continue }
                return
            }
            guard peerAllowed(fd) else {
                os_log(.info, log: hookListenerLog, "closed a connection: peer not allowed")
                Darwin.close(fd)
                continue
            }
            guard connections.count < Self.maxConnections, configure(fd) else {
                os_log(.info, log: hookListenerLog, "closed a connection: %d already open", connections.count)
                Darwin.close(fd)
                continue
            }
            admit(fd)
        }
    }

    private func admit(_ fd: Int32) {
        let id = nextConnectionID
        nextConnectionID &+= 1
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable(connection: id, fd: fd)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        connections[id] = Connection(source: source)
        source.resume()
        // A silent peer is closed; a finished connection is already gone by then.
        queue.asyncAfter(deadline: .now() + frameDeadline) { [weak self] in
            self?.drop(connection: id)
        }
    }

    private func drop(connection id: UInt64) {
        connections.removeValue(forKey: id)?.source.cancel()
    }

    private func readAvailable(connection id: UInt64, fd: Int32) {
        guard let connection = connections[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                guard connection.buffer.append(Data(chunk[0..<count])) else {
                    os_log(.info, log: hookListenerLog, "dropped a frame over %d bytes", HookFrameBuffer.maxBytes)
                    drop(connection: id)
                    return
                }
            } else if count == 0 {
                let frame = connection.buffer.finish()
                drop(connection: id)
                if frame != .malformed { onFrame(frame) }
                return
            } else {
                if errno == EINTR { continue }
                if errno != EAGAIN {
                    os_log(.info, log: hookListenerLog, "read failed: errno %d", errno)
                    drop(connection: id)
                }
                return
            }
        }
    }
}
