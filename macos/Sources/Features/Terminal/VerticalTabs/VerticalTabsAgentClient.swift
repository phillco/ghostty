import Darwin
import Foundation

/// Streams `agentd`'s NDJSON `snapshot`/`delta` frames from its Unix socket
/// and hands the main thread a fresh `Snapshot` whenever it changes.
///
/// All socket work runs on one private serial queue with a non-blocking fd,
/// so nothing here blocks the UI. With no daemon (missing socket, refused,
/// disconnected) the snapshot is empty and the sidebar shows what it did
/// before `agentd`; reconnects back off from 0.5s to 5s, silently.
final class VerticalTabsAgentClient {
    /// `GHOSTTY_AGENTD_SOCKET`, else `~/.local/state/agentd.sock`.
    static var defaultSocketPath: String {
        if let path = ProcessInfo.processInfo.environment["GHOSTTY_AGENTD_SOCKET"], !path.isEmpty { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/.local/state/agentd.sock"
    }

    static let minBackoff: TimeInterval = 0.5
    static let maxBackoff: TimeInterval = 5
    /// A line longer than this drops the connection (a broken peer, not a snapshot).
    static let maxLineBytes = 32 << 20

    let socketPath: String
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.vertical-tabs.agentd", qos: .utility)
    /// Called on the main queue with the latest snapshot, coalesced.
    private let onUpdate: (VerticalTabs.Agent.Snapshot) -> Void

    // Queue-confined state.
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var state = VerticalTabs.Agent.Snapshot()
    private var published = VerticalTabs.Agent.Snapshot()
    /// The snapshot waiting for the main queue; guarded by `mailboxLock`.
    private var mailbox: VerticalTabs.Agent.Snapshot?
    private let mailboxLock = NSLock()
    private var backoff = minBackoff
    private var running = false
    private var reconnectScheduled = false

    init(socketPath: String = VerticalTabsAgentClient.defaultSocketPath,
         onUpdate: @escaping (VerticalTabs.Agent.Snapshot) -> Void) {
        self.socketPath = socketPath
        self.onUpdate = onUpdate
    }

    deinit {
        // `stop()` cancels the source, which closes the fd.
        readSource?.cancel()
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            backoff = Self.minBackoff
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            disconnect()
        }
    }

    /// Best effort: dropped when disconnected or the socket buffer is full.
    func ackReply(key: String, replyId: String) {
        queue.async { [self] in
            guard fd >= 0 else { return }
            let line = VerticalTabs.Agent.ackReplyLine(id: UUID().uuidString, key: key, replyId: replyId)
            _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
    }

    // MARK: Connection (queue only)

    private func connect() {
        guard running, fd < 0 else { return }
        let sock = Self.openSocket(path: socketPath)
        guard sock >= 0 else { return scheduleReconnect() }
        fd = sock
        buffer.removeAll(keepingCapacity: true)
        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(sock) }
        readSource = source
        source.resume()
    }

    /// A connected, non-blocking socket, or -1. Connecting to a local Unix
    /// socket completes (or fails) immediately.
    static func openSocket(path: String) -> Int32 {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return -1 }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return -1 }
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(sock)
            return -1
        }
        _ = fcntl(sock, F_SETFL, fcntl(sock, F_GETFL) | O_NONBLOCK)
        return sock
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        var changed = false
        while fd >= 0 {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                changed = consumeLines() || changed
                if buffer.count > Self.maxLineBytes { return lost() }
            } else if n < 0, errno == EAGAIN || errno == EINTR {
                break
            } else {
                // EOF or a real error.
                if changed { publish() }
                return lost()
            }
        }
        if changed { publish() }
    }

    /// Applies every complete line; a partial line stays buffered.
    private func consumeLines() -> Bool {
        var changed = false
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            start = buffer.index(after: newline)
            guard !line.isEmpty, let frame = VerticalTabs.Agent.Frame.decode(Data(line)) else { continue }
            if frame.type == "snapshot" { backoff = Self.minBackoff }
            changed = state.apply(frame) || changed
        }
        if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        return changed
    }

    private func lost() {
        disconnect()
        scheduleReconnect()
    }

    private func disconnect() {
        readSource?.cancel()
        readSource = nil
        fd = -1
        buffer.removeAll()
        if !state.isEmpty || !state.attachments.isEmpty {
            state = .init()
            publish()
        }
    }

    private func scheduleReconnect() {
        guard running, !reconnectScheduled else { return }
        reconnectScheduled = true
        let delay = backoff
        backoff = min(Self.maxBackoff, backoff * 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            reconnectScheduled = false
            connect()
        }
    }

    /// Coalesces: at most one main-queue hop in flight, carrying the latest
    /// state, and only when it differs from the last one published.
    private func publish() {
        guard state != published else { return }
        published = state
        mailboxLock.lock()
        let hop = mailbox == nil
        mailbox = state
        mailboxLock.unlock()
        guard hop else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            mailboxLock.lock()
            let snapshot = mailbox
            mailbox = nil
            mailboxLock.unlock()
            if let snapshot { onUpdate(snapshot) }
        }
    }
}
