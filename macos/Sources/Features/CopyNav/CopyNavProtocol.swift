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
    /// With `sid`, the file must also be that session's (a pid can be reused).
    static func endpoint(pid: Int32, sid: String? = nil) -> ClarcEndpoint? {
        guard let (data, owner) = try? readOwned(readyPath(pid: pid)), owner == getuid(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tty = json["tty"] as? String else { return nil }
        guard let e = try? check(data: data, ownerUID: owner, myUID: getuid(), pid: pid, tty: tty) else { return nil }
        if let sid, e.sid != sid { return nil }
        return e
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
                  ForegroundJob.process(pid)?.isAg == true else { continue }
            return pid
        }
        return nil
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
            // The deadline covers the whole exchange, even a peer that keeps sending.
            guard Date() < deadline else { throw CopyNavError.timeout }
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

/// Process facts from in-process sysctl/libproc calls (no spawning).
enum ForegroundJob {
    struct Process {
        var pid: Int32
        var ppid: Int32
        var pgid: Int32
        var uid: uid_t
        var comm: String
        var stat: Int8 = Int8(SRUN)

        var isAg: Bool {
            uid == getuid() && comm == "ag" && stat != Int8(SSTOP) && stat != Int8(SZOMB)
        }
    }

    static func process(_ pid: Int32) -> Process? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return Process(info)
    }

    static func group(_ pgid: Int32) -> [Process] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += 8 * MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map(Process.init)
    }

    /// Path of `pid`'s stdin when it's a file or device (nil for pipes and sockets).
    static func stdinPath(_ pid: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, 0, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvip.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// True when `agPID` is a live `ag` of ours whose stdin is this tty, it belongs to
    /// the terminal's foreground process group, and no non-ancestor process in that group
    /// reads the terminal. Restored tabs can leave `login -> fish -> ag` sharing one
    /// foreground group and tty fd 0 while the parent shell waits on `ag` (Darwin hides
    /// wait channels from unprivileged callers, so requiring `ag` itself to hold tty fd 0
    /// rejects POSIX async `ag &` in non-job-control shells while excluding `ag`'s
    /// ancestors). `ag`'s backend adapters share its group on pipes; an external editor
    /// it runs (Ctrl+G) or any non-ancestor tty reader must get its keys untouched.
    static func isOnly(agPID: Int32, foregroundPGID: Int32, tty: String) -> Bool {
        guard let ag = process(agPID), ag.isAg, ag.pgid == foregroundPGID else { return false }
        let device = "/dev/" + ClarcReady.bareTTY(tty)
        return isOnly(
            agPID: agPID,
            foregroundPGID: foregroundPGID,
            group: group(foregroundPGID),
            lookup: process,
            readsTTY: { stdinPath($0) == device })
    }

    static func isOnly(
        agPID: Int32,
        foregroundPGID: Int32,
        group members: [Process],
        lookup: (Int32) -> Process? = { _ in nil },
        readsTTY: (Int32) -> Bool
    ) -> Bool {
        guard let ag = members.first(where: { $0.pid == agPID }) ?? lookup(agPID),
              ag.isAg,
              ag.pgid == foregroundPGID,
              readsTTY(agPID) else { return false }
        var byPID: [Int32: Process] = [:]
        byPID.reserveCapacity(members.count)
        for member in members { byPID[member.pid] = member }
        var ancestors: Set<Int32> = [agPID]
        var cur = ag.ppid
        for _ in 0..<64 where cur > 1 && ancestors.insert(cur).inserted {
            guard let parent = byPID[cur] ?? lookup(cur) else { break }
            cur = parent.ppid
        }
        return !members.contains { !ancestors.contains($0.pid) && readsTTY($0.pid) }
    }
}

extension ForegroundJob.Process {
    init(_ info: kinfo_proc) {
        var p = info.kp_proc
        pid = p.p_pid
        ppid = info.kp_eproc.e_ppid
        pgid = info.kp_eproc.e_pgid
        uid = info.kp_eproc.e_ucred.cr_uid
        stat = p.p_stat
        comm = withUnsafeBytes(of: &p.p_comm) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
    }
}

/// Which ⌘C/⌘X presses may go to `ag`'s composer instead of a Ghostty binding: an
/// unbound key, or ⌘C bound (performable) to the selection copy, which has nothing to
/// copy. Any other binding keeps the key; `all:`/`global:` copies act on other
/// surfaces too, so they always keep it.
enum ComposerKeyPolicy {
    static func yields(key: String, bound: Bool, performable: Bool, crossSurface: Bool, isCopyBinding: Bool) -> Bool {
        guard bound else { return true }
        return key == "c" && isCopyBinding && performable && !crossSurface
    }
}
