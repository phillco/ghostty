import Foundation
import Darwin

// `ag` semantic copy and message links: link parsing, `.ready` trust checks and the
// `resolveCopy` clarc-ipc exchange. AppKit-free so it runs in hostless tests.
// Design: ~/bin/docs/ghostty-ag-copy-nav.md.

/// By-reference copy target: a segment (optionally one block of it) or a whole turn.
struct CopyRef: Equatable {
    var pid: Int32
    var gen: String
    var seg: Int?
    var block: Int?
    var turn: Int?
}

/// A `ghostty-phil://msg` anchor.
struct MsgRef: Equatable {
    var pid: Int32?
    var gen: String?
    var seg: Int?
    var sid: String?
    var rec: String?
    var scroll: Bool
    /// The link as printed; the core matches anchors from it.
    var raw: String

    /// Copying the anchor's segment needs all three.
    var copyRef: CopyRef? {
        guard let pid, let gen, let seg else { return nil }
        return CopyRef(pid: pid, gen: gen, seg: seg)
    }
}

enum PhilLink: Equatable {
    case copy(CopyRef)
    case msg(MsgRef)

    /// Parses `<scheme>://copy?…` or `<scheme>://msg?…`. Copy links are by-reference only
    /// (`pid`, `gen`, and `seg` or `turn`): unverifiable inline `text=` payloads are not
    /// accepted, so terminal output can't write the clipboard by itself.
    static func parse(_ string: String, schemes: Set<String>) -> PhilLink? {
        guard let c = URLComponents(string: string),
              let scheme = c.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
        let items = c.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        func int(_ name: String) -> Int? { value(name).flatMap { Int($0) }.flatMap { $0 >= 0 ? $0 : nil } }
        let pid = value("pid").flatMap { Int32($0) }.flatMap { $0 > 0 ? $0 : nil }
        switch c.host?.lowercased() {
        case "copy":
            guard let pid, let gen = value("gen"), isHex(gen) else { return nil }
            let ref = CopyRef(pid: pid, gen: gen, seg: int("seg"), block: int("block"), turn: int("turn"))
            guard (ref.seg != nil) != (ref.turn != nil), ref.block == nil || ref.seg != nil else { return nil }
            return .copy(ref)
        case "msg":
            let gen = value("gen").flatMap { isHex($0) ? $0 : nil }
            return .msg(MsgRef(pid: pid, gen: gen, seg: int("seg"), sid: value("sid"), rec: value("rec"),
                               scroll: value("scroll") == "1", raw: string))
        default:
            return nil
        }
    }

    /// A `copy` or `msg` link in one of our schemes, valid or not. Malformed ones (such as
    /// inline `text=` copies) are claimed and refused rather than offered to other openers.
    static func isOurs(_ string: String, schemes: Set<String>) -> Bool {
        guard let c = URLComponents(string: string), let scheme = c.scheme?.lowercased(),
              schemes.contains(scheme) else { return false }
        return ["copy", "msg"].contains(c.host?.lowercased() ?? "")
    }

    enum Origin { case surfaceClick, externalOpen }

    /// Copy links write the clipboard, so only clicks inside a surface may run them;
    /// anything may navigate.
    func allowed(from origin: Origin) -> Bool {
        switch self {
        case .copy: return origin == .surfaceClick
        case .msg: return true
        }
    }

    static func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 32 && s.allSatisfy(\.isHexDigit)
    }
}

/// What the core hands over on an explicit rich copy (copy_nav.zig `Snapshot`). Rows are
/// relative to the anchor row; columns are inclusive.
struct SelectionSnapshot: Decodable, Equatable {
    struct Spanned: Decodable, Equatable {
        var uri: String
        var relRow: Int
    }

    var flavor: String
    var anchor: String
    var cols: Int
    var startRow: Int
    var startCol: Int
    var endRow: Int
    var endCol: Int
    var rowWraps: [Bool]
    var spanned: [Spanned]
    var selectedPlain: String

    static let mime = "application/vnd.ghostty-phil.copy-snapshot+json"

    var wantsMarkdownPlain: Bool { flavor == "markdown" }
}

struct ResolveResponse: Decodable, Equatable {
    var id: String
    var ok: Bool
    var markdown: String?
    var plain: String?
    var kind: String?
    var codeLang: String?
    var reason: String?
}

enum ResolveRequest {
    static func ref(id: String, _ ref: CopyRef) -> Data {
        var r: [String: Any] = ["id": id, "op": "resolveCopy", "mode": "ref", "gen": ref.gen]
        if let seg = ref.seg { r["seg"] = seg }
        if let block = ref.block { r["block"] = block }
        if let turn = ref.turn { r["turn"] = turn }
        return line(r)
    }

    /// Nil when the snapshot's anchor isn't a copyable msg link; `pid` is its process.
    static func selection(id: String, _ s: SelectionSnapshot, schemes: Set<String>) -> (pid: Int32, line: Data)? {
        guard case .msg(let anchor)? = PhilLink.parse(s.anchor, schemes: schemes),
              let ref = anchor.copyRef else { return nil }
        let spanned: [[String: Any]] = s.spanned.compactMap { span in
            guard case .msg(let m)? = PhilLink.parse(span.uri, schemes: schemes),
                  let seg = m.seg, let gen = m.gen, m.pid == nil || m.pid == ref.pid else { return nil }
            return ["seg": seg, "gen": gen, "relRow": span.relRow]
        }
        let r: [String: Any] = [
            "id": id, "op": "resolveCopy", "mode": "selection", "gen": ref.gen, "pid": Int(ref.pid),
            "startAnchor": ["seg": ref.seg ?? 0], "spannedAnchors": spanned, "cols": s.cols,
            "startRow": s.startRow, "startCol": s.startCol, "endRow": s.endRow, "endCol": s.endCol,
            "rowWraps": s.rowWraps, "selectedPlain": s.selectedPlain,
        ]
        return (ref.pid, line(r))
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}

enum CopyNavError: Error, Equatable {
    case notReady(String)
    case untrusted(String)
    case timeout
    case io(String)
    case rejected(String)
}

/// A verified `ag` clarc-ipc endpoint.
struct ClarcEndpoint: Equatable {
    var pid: Int32
    var socketPath: String
    var sid: String?
    var tty: String
}

enum ClarcReady {
    static var directory = "/tmp"

    static func readyPath(pid: Int32) -> String { "\(directory)/claude-clarc-\(pid).ready" }
    static func socketPath(pid: Int32) -> String { "\(directory)/claude-clarc-\(pid).sock" }

    /// Reads and checks `pid`'s `.ready`: ours, for that pid, on `tty`. The socket path is
    /// derived from the pid (never taken from the file) and must also be our socket.
    static func verify(pid: Int32, tty: String?) throws -> ClarcEndpoint {
        let path = readyPath(pid: pid)
        let (data, owner) = try readOwned(path)
        let endpoint = try check(data: data, ownerUID: owner, myUID: getuid(), pid: pid, tty: tty)
        var st = stat()
        guard lstat(endpoint.socketPath, &st) == 0 else { throw CopyNavError.notReady("no socket") }
        guard st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFSOCK else {
            throw CopyNavError.untrusted("socket owner or type")
        }
        return endpoint
    }

    /// The trust decision for `.ready` contents, separated for tests.
    static func check(data: Data, ownerUID: uid_t, myUID: uid_t, pid: Int32, tty: String?) throws -> ClarcEndpoint {
        guard ownerUID == myUID else { throw CopyNavError.untrusted("ready owner \(ownerUID)") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CopyNavError.notReady("unparsable ready")
        }
        guard (json["pid"] as? NSNumber)?.int32Value == pid else { throw CopyNavError.untrusted("pid mismatch") }
        guard let want = tty.map(bareTTY), !want.isEmpty,
              let have = (json["tty"] as? String).map(bareTTY), have == want else {
            throw CopyNavError.untrusted("tty mismatch")
        }
        let sid = (json["sid"] as? String) ?? (json["sessionId"] as? String)
        return ClarcEndpoint(pid: pid, socketPath: socketPath(pid: pid), sid: sid, tty: have)
    }

    /// `pid`'s endpoint if its `.ready` is ours, whatever its tty, for navigation (which
    /// only uses the tty to find the terminal).
    static func endpoint(pid: Int32) -> ClarcEndpoint? {
        guard let (data, owner) = try? readOwned(readyPath(pid: pid)), owner == getuid(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tty = json["tty"] as? String else { return nil }
        return try? check(data: data, ownerUID: owner, myUID: getuid(), pid: pid, tty: tty)
    }

    /// Our `ag` endpoints whose session is `sid`, for external navigation.
    static func endpoints(sid: String) -> [ClarcEndpoint] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return files.compactMap { name -> ClarcEndpoint? in
            guard name.hasPrefix("claude-clarc-"), name.hasSuffix(".ready"),
                  let pid = Int32(name.dropFirst(13).dropLast(6)),
                  let (data, owner) = try? readOwned("\(directory)/\(name)"),
                  owner == getuid(),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["pid"] as? NSNumber)?.int32Value == pid,
                  let tty = json["tty"] as? String,
                  (json["sid"] as? String ?? json["sessionId"] as? String) == sid else { return nil }
            return ClarcEndpoint(pid: pid, socketPath: socketPath(pid: pid), sid: sid, tty: bareTTY(tty))
        }
    }

    /// Pid of the live `ag` (agent "agy") whose `.ready` is ours and names `tty`.
    static func agPID(tty: String) -> Int32? {
        let want = bareTTY(tty)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in files where name.hasPrefix("claude-clarc-") && name.hasSuffix(".ready") {
            guard let pid = Int32(name.dropFirst(13).dropLast(6)),
                  let (data, owner) = try? readOwned("\(directory)/\(name)"), owner == getuid(),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["agent"] as? String == "agy",
                  (json["pid"] as? NSNumber)?.int32Value == pid,
                  (json["tty"] as? String).map(bareTTY) == want,
                  processOwned(pid) else { continue }
            return pid
        }
        return nil
    }

    /// Whether `pid` is a live process of ours (in-process sysctl, no spawn).
    static func processOwned(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_eproc.e_ucred.cr_uid == getuid()
    }

    static func bareTTY(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
    }

    /// Contents and owner of a regular file, from one open descriptor so they agree.
    private static func readOwned(_ path: String) throws -> (Data, uid_t) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CopyNavError.notReady("no ready file") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size < 1 << 20 else {
            throw CopyNavError.untrusted("ready file type")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = (try? handle.readToEnd()) ?? Data()
        return (data, st.st_uid)
    }
}

enum ClarcSocket {
    /// Sends one request line and returns the response line carrying `id`, skipping
    /// pushed lines such as clarc-ipc's initial `{"event":"state",…}`. Blocking; call off
    /// the main thread. Throws `.timeout` past `deadline`.
    static func request(path: String, line: Data, id: String, deadline: Date) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CopyNavError.io("socket") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw CopyNavError.io("path") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw CopyNavError.notReady("connect \(errno)") }
            try wait(fd, POLLOUT, deadline)
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { throw CopyNavError.notReady("connect \(err)") }
        }

        var sent = 0
        while sent < line.count {
            let n = line.withUnsafeBytes { write(fd, $0.baseAddress! + sent, line.count - sent) }
            if n > 0 { sent += n; continue }
            guard n < 0, errno == EAGAIN else { throw CopyNavError.io("write \(errno)") }
            try wait(fd, POLLOUT, deadline)
        }

        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            while let nl = pending.firstIndex(of: 0x0A) {
                let candidate = pending[pending.startIndex..<nl]
                pending = Data(pending[(nl + 1)...])
                if let obj = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any],
                   obj["id"] as? String == id {
                    return Data(candidate)
                }
            }
            guard pending.count < 16 << 20 else { throw CopyNavError.io("oversized line") }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { pending.append(contentsOf: chunk[0..<n]); continue }
            if n == 0 { throw CopyNavError.io("closed") }
            guard errno == EAGAIN else { throw CopyNavError.io("read \(errno)") }
            try wait(fd, POLLIN, deadline)
        }
    }

    private static func wait(_ fd: Int32, _ events: Int32, _ deadline: Date) throws {
        let ms = Int32((deadline.timeIntervalSinceNow * 1000).rounded(.up))
        guard ms > 0 else { throw CopyNavError.timeout }
        var p = pollfd(fd: fd, events: Int16(events), revents: 0)
        let r = poll(&p, 1, ms)
        if r == 0 { throw CopyNavError.timeout }
        guard r > 0 else { throw CopyNavError.io("poll \(errno)") }
    }
}

enum CopyResolver {
    /// Total budget for `.ready` checks plus the socket round trip.
    static let budget: TimeInterval = 0.060

    /// Verifies `pid`'s endpoint against `tty` and resolves `line`. Blocking.
    static func resolve(pid: Int32, tty: String?, line: Data, id: String,
                        deadline: Date = Date(timeIntervalSinceNow: budget)) throws -> ResolveResponse {
        let endpoint = try ClarcReady.verify(pid: pid, tty: tty)
        let data = try ClarcSocket.request(path: endpoint.socketPath, line: line, id: id, deadline: deadline)
        guard let response = try? JSONDecoder().decode(ResolveResponse.self, from: data) else {
            throw CopyNavError.io("bad response")
        }
        guard response.ok, let markdown = response.markdown, !markdown.isEmpty || response.plain?.isEmpty == false else {
            throw CopyNavError.rejected(response.reason ?? "empty")
        }
        return response
    }
}
