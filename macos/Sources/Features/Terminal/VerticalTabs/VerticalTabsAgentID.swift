import Darwin
import Foundation

/// Pure parsing behind the sidebar's Copy ID: agent session files and peer names.
extension VerticalTabs {
    /// An agent session from a discovery file, with the processes that may own a tab.
    struct AgentSession: Equatable {
        /// Processes that may sit on the tab's TTY.
        let pids: [Int32]
        let sessionId: String
        let peerId: String
        /// Executable names (`pbi_comm`) a live owner has; a reused PID won't.
        var processNames: Set<String> = []
        /// A socket the live session keeps, if its file names one.
        var socketPath: String?
        /// A host process that must still be alive, with one of `processNames`.
        var hostPID: Int32?
        /// When the discovery file was last written (seconds since 1970). A
        /// process started after that can't have written it: its PID was reused.
        var fileMtime: Double?

        /// Slack for the coarse start time and a write racing the spawn.
        static let startTimeSlack: Double = 2

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

    /// Reads a session's raw name from `cc-send`'s bridge registrations.
    typealias BridgeNameReader = (_ sessionId: String) -> String?

    /// `~/.local/state/cc-bridge/threads/<sessionId>`, where `cc-send` registers
    /// a conversation's peer name.
    static func bridgeThreadName(_ sessionId: String) -> String? {
        guard !sessionId.isEmpty, !sessionId.contains("/") else { return nil }
        let path = FileManager.default.homeDirectoryForCurrentUser.path
            + "/.local/state/cc-bridge/threads/" + sessionId
        return FileManager.default.contents(atPath: path).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// `peers.agyName` (`ag.go`): a bridge registration, else `DefaultName`.
    static func agyPeerName(id: String, cwd: String, bridgeName: BridgeNameReader) -> String {
        if let raw = bridgeName(id) {
            let name = peerSlug(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            if !name.isEmpty { return name }
        }
        return defaultPeerName(agent: "agy", id: id, cwd: cwd)
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func pid(_ value: Any?) -> Int32? {
        (value as? NSNumber).map(\.int32Value).flatMap { $0 > 0 ? $0 : nil }
    }

    /// `~/.claude/sessions/<pid>.json`: the peer name is `name`, else `cc-<id8>`.
    /// Mailbox daemons (`ccMailbox`) aren't interactive sessions.
    static func claudeSession(json data: Data) -> AgentSession? {
        guard let obj = json(data), obj["ccMailbox"] as? Bool != true, let pid = pid(obj["pid"]),
              let id = obj["sessionId"] as? String, !id.isEmpty else { return nil }
        let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .init(pids: [pid], sessionId: id,
                     peerId: name ?? defaultPeerName(agent: "claude", id: id, cwd: ""),
                     processNames: claudeProcessNames, socketPath: obj["messagingSocketPath"] as? String)
    }

    /// `/tmp/claude-clarc-<pid>.ready`, written by `ag` and Clarc-hosted Claude.
    static func clarcSession(
        json data: Data, bridgeName: BridgeNameReader = bridgeThreadName
    ) -> AgentSession? {
        guard let obj = json(data), let pid = pid(obj["pid"]),
              let id = obj["sessionId"] as? String, !id.isEmpty else { return nil }
        let agent = obj["agent"] as? String ?? "claude"
        let cwd = obj["cwd"] as? String ?? ""
        let peerId = agent == "agy"
            ? agyPeerName(id: id, cwd: cwd, bridgeName: bridgeName)
            : defaultPeerName(agent: agent, id: id, cwd: cwd)
        return .init(pids: [pid], sessionId: id, peerId: peerId,
                     processNames: agent == "agy" ? agyProcessNames : claudeProcessNames,
                     socketPath: obj["socket"] as? String)
    }

    /// `/tmp/ag-host-<pid>.json`: mirrored `ag` sessions without a `.ready` file.
    static func agHostSession(
        json data: Data, bridgeName: BridgeNameReader = bridgeThreadName
    ) -> AgentSession? {
        guard let obj = json(data), let id = obj["sessionId"] as? String, !id.isEmpty else { return nil }
        let clients = (obj["clients"] as? [Any] ?? []).compactMap { pid($0) }
        let pids = [pid(obj["client"])].compactMap { $0 } + clients
        guard !pids.isEmpty, let host = pid(obj["pid"]) else { return nil }
        return .init(pids: pids, sessionId: id,
                     peerId: agyPeerName(id: id, cwd: obj["cwd"] as? String ?? "", bridgeName: bridgeName),
                     processNames: agyProcessNames, socketPath: obj["socket"] as? String, hostPID: host)
    }

    static let claudeProcessNames: Set<String> = ["claude", "claude.exe", "node", "bun"]
    static let agyProcessNames: Set<String> = ["ag"]

    /// What Copy ID needs to know about a live process.
    struct ProcessSnapshot: Equatable {
        let name: String
        /// Controlling terminal device, if any.
        let tty: UInt32?
        /// Process start time (seconds since 1970).
        var startTime: Double?
    }

    /// A terminal to match: its TTY device and foreground process.
    struct TerminalKey: Equatable {
        let device: UInt32?
        let foregroundPID: Int32?
    }

    /// The session owning the first terminal (in order, focused split first) that
    /// any live candidate matches. A candidate matches a terminal when one of its
    /// PIDs is a live process with an expected name that is the terminal's
    /// foreground process (preferred) or on its TTY. Stale files (gone socket,
    /// dead host, reused PID, owner born after the file was written) never match.
    static func matchSession(
        terminals: [TerminalKey],
        candidates: [AgentSession],
        process: (Int32) -> ProcessSnapshot?,
        fileExists: (String) -> Bool
    ) -> AgentSession? {
        func owner(_ pid: Int32, of session: AgentSession) -> ProcessSnapshot? {
            guard let snapshot = process(pid), session.processNames.contains(snapshot.name) else { return nil }
            if let start = snapshot.startTime, let mtime = session.fileMtime,
               start > mtime + AgentSession.startTimeSlack { return nil }
            return snapshot
        }
        let live = candidates.filter { session in
            (session.socketPath.map(fileExists) ?? true)
                && (session.hostPID.map { owner($0, of: session) != nil } ?? true)
        }
        for terminal in terminals {
            let foreground = live.first { session in
                session.pids.contains { $0 == terminal.foregroundPID && owner($0, of: session) != nil }
            }
            if let foreground { return foreground }
            guard let device = terminal.device else { continue }
            let onTTY = live.first { session in
                session.pids.contains { owner($0, of: session)?.tty == device }
            }
            if let onTTY { return onTTY }
        }
        return nil
    }
}

/// Finds the agent session running in a terminal by controlling TTY: a tab's
/// foreground process is often `login`, with the agent a descendant on that TTY.
enum VerticalTabsAgentLookup {
    /// One surface's terminal: its TTY name and foreground process.
    struct Terminal {
        let ttyName: String?
        let foregroundPID: Int?
    }

    /// Terminals in priority order (focused split first).
    static func session(for terminals: [Terminal]) -> VerticalTabs.AgentSession? {
        let keys = terminals.map {
            VerticalTabs.TerminalKey(
                device: $0.ttyName.flatMap(device),
                foregroundPID: $0.foregroundPID.flatMap { Int32(exactly: $0) })
        }
        guard keys.contains(where: { $0.device != nil || $0.foregroundPID != nil }) else { return nil }
        return VerticalTabs.matchSession(
            terminals: keys, candidates: candidates(), process: process,
            fileExists: FileManager.default.fileExists(atPath:))
    }

    /// Claude's own session files first, so Claude tabs get their registered name.
    private static func candidates() -> [VerticalTabs.AgentSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return sessions(in: home + "/.claude/sessions", prefix: "", suffix: ".json") { VerticalTabs.claudeSession(json: $0) }
            + sessions(in: "/tmp", prefix: "claude-clarc-", suffix: ".ready") { VerticalTabs.clarcSession(json: $0) }
            + sessions(in: "/tmp", prefix: "ag-host-", suffix: ".json") { VerticalTabs.agHostSession(json: $0) }
    }

    private static func sessions(
        in dir: String, prefix: String, suffix: String, parse: (Data) -> VerticalTabs.AgentSession?
    ) -> [VerticalTabs.AgentSession] {
        files(in: dir, prefix: prefix, suffix: suffix).compactMap { file in
            guard var session = parse(file.data) else { return nil }
            session.fileMtime = file.mtime
            return session
        }
    }

    /// Regular files we own only: `/tmp` is shared, and a symlink or another
    /// user's file must not supply a session identity.
    private static func files(in dir: String, prefix: String, suffix: String) -> [(data: Data, mtime: Double?)] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }.compactMap { name in
            let path = dir + "/" + name
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let data = fm.contents(atPath: path) else { return nil }
            return (data, (attrs[.modificationDate] as? Date)?.timeIntervalSince1970)
        }
    }

    private static func device(_ ttyName: String) -> UInt32? {
        var info = stat()
        guard stat(ttyName, &info) == 0 else { return nil }
        return UInt32(bitPattern: info.st_rdev)
    }

    /// `nil` for a process that's gone (or not ours to inspect).
    private static func process(_ pid: Int32) -> VerticalTabs.ProcessSnapshot? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_comm) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) } ?? ""
        // NODEV (-1) means no controlling terminal.
        let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        return .init(name: name, tty: info.e_tdev == UInt32.max ? nil : info.e_tdev, startTime: start)
    }
}
