import Darwin
import Foundation

/// Pure parsing behind the sidebar's Copy ID: agent session files and peer names.
extension VerticalTabs {
    /// An agent session from a discovery file, with the processes that may own a tab.
    struct AgentSession: Equatable {
        let pids: [Int32]
        let sessionId: String
        let peerId: String

        /// What Copy ID puts on the pasteboard.
        var copyText: String { "\(sessionId) (\(peerId))" }
    }

    /// `peers.Slug` (`~/bin/go/agentlib/peers/peers.go`): lowercase, runs outside
    /// `[a-z0-9._-]` become `-`, trimmed of `-`/`.`, at most 40 characters.
    static func peerSlug(_ string: String) -> String {
        var out = ""
        var inRun = false
        for scalar in string.lowercased().unicodeScalars {
            let safe = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || "._-".unicodeScalars.contains(scalar)
            if safe {
                out.unicodeScalars.append(scalar)
                inRun = false
            } else if !inRun {
                out.append("-")
                inRun = true
            }
        }
        out = trimDashDot(out)
        if out.count > 40 { out = trimDashDot(String(out.prefix(40)), leading: false) }
        return out
    }

    private static func trimDashDot(_ string: String, leading: Bool = true) -> String {
        var s = Substring(string)
        while let last = s.last, last == "-" || last == "." { s.removeLast() }
        while leading, let first = s.first, first == "-" || first == "." { s.removeFirst() }
        return String(s)
    }

    /// `peers.DefaultName`: `agy-<cwd folder>-<id4>` (or `agy-<id8>`), `cc-<id8>`.
    static func defaultPeerName(agent: String, id: String, cwd: String) -> String {
        let prefix = ["agy": "agy", "codex": "codex", "claude": "cc"][agent] ?? peerSlug(agent)
        if agent == "agy", id.count >= 4, !cwd.isEmpty, cwd != "/" {
            let base = peerSlug((cwd as NSString).lastPathComponent)
            if !base.isEmpty {
                var name = peerSlug(prefix + "-" + base)
                if name.count > 35 { name = trimDashDot(String(name.prefix(35)), leading: false) }
                return name + "-" + id.prefix(4)
            }
        }
        return prefix + "-" + id.prefix(8)
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func pid(_ value: Any?) -> Int32? {
        (value as? NSNumber).map(\.int32Value).flatMap { $0 > 0 ? $0 : nil }
    }

    /// `~/.claude/sessions/<pid>.json`: the peer name is `name`, else `cc-<id8>`.
    static func claudeSession(json data: Data) -> AgentSession? {
        guard let obj = json(data), let pid = pid(obj["pid"]),
              let id = obj["sessionId"] as? String, !id.isEmpty else { return nil }
        let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .init(pids: [pid], sessionId: id,
                     peerId: name ?? defaultPeerName(agent: "claude", id: id, cwd: ""))
    }

    /// `/tmp/claude-clarc-<pid>.ready`, written by `ag` and Clarc-hosted Claude.
    static func clarcSession(json data: Data) -> AgentSession? {
        guard let obj = json(data), let pid = pid(obj["pid"]),
              let id = obj["sessionId"] as? String, !id.isEmpty else { return nil }
        let agent = obj["agent"] as? String ?? "claude"
        return .init(pids: [pid], sessionId: id,
                     peerId: defaultPeerName(agent: agent, id: id, cwd: obj["cwd"] as? String ?? ""))
    }

    /// `/tmp/ag-host-<pid>.json`: mirrored `ag` sessions without a `.ready` file.
    static func agHostSession(json data: Data) -> AgentSession? {
        guard let obj = json(data), let id = obj["sessionId"] as? String, !id.isEmpty else { return nil }
        let clients = (obj["clients"] as? [Any] ?? []).compactMap { pid($0) }
        let pids = [pid(obj["client"])].compactMap { $0 } + clients
            + [pid(obj["agyPid"]), pid(obj["pid"])].compactMap { $0 }
        guard !pids.isEmpty else { return nil }
        return .init(pids: pids, sessionId: id,
                     peerId: defaultPeerName(agent: "agy", id: id, cwd: obj["cwd"] as? String ?? ""))
    }
}

/// Finds the agent session running in a terminal by controlling TTY: a tab's
/// foreground process is often `login`, with the agent a descendant on that TTY.
enum VerticalTabsAgentLookup {
    /// One surface's terminal: its TTY device and foreground process.
    struct Terminal {
        let ttyName: String?
        let foregroundPID: Int?
    }

    static func session(for terminals: [Terminal]) -> VerticalTabs.AgentSession? {
        let devices = Set(terminals.compactMap { $0.ttyName.flatMap(device) })
        let foreground = Set(terminals.compactMap { $0.foregroundPID.flatMap { Int32(exactly: $0) } })
        guard !devices.isEmpty || !foreground.isEmpty else { return nil }
        return candidates().first { session in
            session.pids.contains { pid in
                foreground.contains(pid) || controllingTTY(of: pid).map(devices.contains) == true
            }
        }
    }

    /// Claude's own session files first, so Claude tabs get their registered name.
    private static func candidates() -> [VerticalTabs.AgentSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return files(in: home + "/.claude/sessions", prefix: "", suffix: ".json")
            .compactMap(VerticalTabs.claudeSession)
            + files(in: "/tmp", prefix: "claude-clarc-", suffix: ".ready").compactMap(VerticalTabs.clarcSession)
            + files(in: "/tmp", prefix: "ag-host-", suffix: ".json").compactMap(VerticalTabs.agHostSession)
    }

    private static func files(in dir: String, prefix: String, suffix: String) -> [Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
            .compactMap { FileManager.default.contents(atPath: dir + "/" + $0) }
    }

    private static func device(_ ttyName: String) -> UInt32? {
        var info = stat()
        guard stat(ttyName, &info) == 0 else { return nil }
        return UInt32(bitPattern: info.st_rdev)
    }

    private static func controllingTTY(of pid: Int32) -> UInt32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // NODEV (-1) means no controlling terminal.
        return info.e_tdev == UInt32.max ? nil : info.e_tdev
    }
}
