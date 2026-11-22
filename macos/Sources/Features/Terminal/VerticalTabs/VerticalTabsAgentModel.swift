import Foundation

/// Pure logic behind the sidebar's live agent status from `agentd`
/// (`~/src/agentic/agentd`): its NDJSON wire format, matching splits to
/// sessions, per-tab aggregation, the age slot and when to acknowledge a
/// reply. The socket lives in `VerticalTabsAgentClient`.
extension VerticalTabs {
    enum Agent {}
}

// MARK: - Wire format

extension VerticalTabs.Agent {
    /// A session's status as `agentd` reports it. Unknown strings decode as `.unknown`.
    enum Status: String, Equatable {
        case working, awaiting, idle, interrupted, unknown
    }

    /// A freeform status an agent sets on its session (`agentd` stage 2).
    struct Note: Decodable, Equatable {
        /// "active" | "waiting" | "needs-you" | "blocked" | "done"
        var state: String
        var text: String
        var progress: String?
        var icon: String?
        var updatedAtMs: Int64?
        var stale: Bool?

        init(state: String, text: String = "", progress: String? = nil, icon: String? = nil,
             updatedAtMs: Int64? = nil, stale: Bool? = nil) {
            self.state = state
            self.text = text
            self.progress = progress
            self.icon = icon
            self.updatedAtMs = updatedAtMs
            self.stale = stale
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            progress = try c.decodeIfPresent(String.self, forKey: .progress).flatMap { $0.isEmpty ? nil : $0 }
            icon = try c.decodeIfPresent(String.self, forKey: .icon).flatMap { $0.isEmpty ? nil : $0 }
            updatedAtMs = try c.decodeIfPresent(Int64.self, forKey: .updatedAtMs)
            stale = try c.decodeIfPresent(Bool.self, forKey: .stale)
        }

        private enum CodingKeys: String, CodingKey {
            case state, text, progress, icon, updatedAtMs, stale
        }
    }

    /// A background job a session started (`agent-job`).
    struct ChildJob: Decodable, Equatable {
        var name: String
        var agent: String?
        /// "running" | "finishing" | "blocked"
        var status: String
        var startedAtMs: Int64?

        init(name: String, agent: String? = nil, status: String = "running", startedAtMs: Int64? = nil) {
            self.name = name
            self.agent = agent
            self.status = status
            self.startedAtMs = startedAtMs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            agent = try c.decodeIfPresent(String.self, forKey: .agent)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            startedAtMs = try c.decodeIfPresent(Int64.self, forKey: .startedAtMs)
        }

        private enum CodingKeys: String, CodingKey {
            case name, agent, status, startedAtMs
        }
    }

    /// One conversation (`agentd` `model.go` `Session`). Only `key` is required,
    /// so older and newer daemons both decode.
    struct Session: Decodable, Equatable {
        var key: String
        var provider: String = ""
        var nativeId: String = ""
        var peerName: String = ""
        var title: String = ""
        var status: Status = .unknown
        var awaitingKind: String = ""
        var turnSinceMs: Int64?
        var lastPromptMs: Int64?
        var lastReplyMs: Int64?
        var lastReplyId: String = ""
        var unread: Bool = false
        var note: Note?
        var childJobs: [ChildJob] = []

        init(
            key: String, status: Status = .unknown, awaitingKind: String = "",
            turnSinceMs: Int64? = nil, lastPromptMs: Int64? = nil, lastReplyMs: Int64? = nil,
            lastReplyId: String = "", unread: Bool = false, note: Note? = nil, childJobs: [ChildJob] = [],
            provider: String = "", peerName: String = "", title: String = ""
        ) {
            self.key = key
            self.status = status
            self.awaitingKind = awaitingKind
            self.turnSinceMs = turnSinceMs
            self.lastPromptMs = lastPromptMs
            self.lastReplyMs = lastReplyMs
            self.lastReplyId = lastReplyId
            self.unread = unread
            self.note = note
            self.childJobs = childJobs
            self.provider = provider
            self.peerName = peerName
            self.title = title
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
            nativeId = try c.decodeIfPresent(String.self, forKey: .nativeId) ?? ""
            peerName = try c.decodeIfPresent(String.self, forKey: .peerName) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            status = try (c.decodeIfPresent(String.self, forKey: .status)).flatMap(Status.init(rawValue:)) ?? .unknown
            awaitingKind = try c.decodeIfPresent(String.self, forKey: .awaitingKind) ?? ""
            turnSinceMs = try c.decodeIfPresent(Int64.self, forKey: .turnSinceMs)
            lastPromptMs = try c.decodeIfPresent(Int64.self, forKey: .lastPromptMs)
            lastReplyMs = try c.decodeIfPresent(Int64.self, forKey: .lastReplyMs)
            lastReplyId = try c.decodeIfPresent(String.self, forKey: .lastReplyId) ?? ""
            unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
            note = try c.decodeIfPresent(Note.self, forKey: .note)
            childJobs = try c.decodeIfPresent([ChildJob].self, forKey: .childJobs) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case key, provider, nativeId, peerName, title, status, awaitingKind, turnSinceMs, lastPromptMs
            case lastReplyMs, lastReplyId, unread, note, childJobs
        }
    }

    /// One terminal frontend showing a session (`agentd` `Attachment`).
    struct Attachment: Decodable, Equatable {
        var sessionKey: String
        var frontend: String = ""
        var surfaceId: String?
        var pids: [Int32] = []
        var ttys: [String] = []

        init(sessionKey: String, surfaceId: String? = nil, pids: [Int32] = [], ttys: [String] = []) {
            self.sessionKey = sessionKey
            self.surfaceId = surfaceId
            self.pids = pids
            self.ttys = ttys
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionKey = try c.decode(String.self, forKey: .sessionKey)
            frontend = try c.decodeIfPresent(String.self, forKey: .frontend) ?? ""
            surfaceId = try c.decodeIfPresent(String.self, forKey: .surfaceId).flatMap { $0.isEmpty ? nil : $0 }
            pids = try c.decodeIfPresent([Int32].self, forKey: .pids) ?? []
            ttys = try c.decodeIfPresent([String].self, forKey: .ttys) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case sessionKey, frontend, surfaceId, pids, ttys
        }
    }

    /// One server line: a `snapshot`, a `delta`, or something we skip.
    struct Frame: Decodable {
        var type: String
        var sessions: [Session]?
        var attachments: [Attachment]?
        var sessionsUpsert: [Session]?
        var sessionsRemove: [String]?

        static func decode(_ line: Data) -> Frame? {
            try? JSONDecoder().decode(Frame.self, from: line)
        }
    }

    /// `{"type":"ackReply",...}` as one NDJSON line, newline included.
    static func ackReplyLine(id: String, key: String, replyId: String) -> Data {
        let object = ["type": "ackReply", "id": id, "key": key, "replyId": replyId]
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// `ttys004` for `/dev/ttys004` or `ttys004` (as `agentd`'s `normTTY`); nil for none.
    static func normalizeTTY(_ tty: String?) -> String? {
        guard var tty = tty?.trimmingCharacters(in: .whitespaces), !tty.isEmpty else { return nil }
        if tty.hasPrefix("/dev/") { tty.removeFirst(5) }
        if tty.hasPrefix("s"), !tty.hasPrefix("tty"), tty.dropFirst().allSatisfy(\.isNumber) { tty = "tty" + tty }
        return tty.isEmpty || tty == "??" ? nil : tty
    }
}

// MARK: - State

extension VerticalTabs.Agent {
    /// Everything `agentd` told us, with lookup indexes for matching splits.
    /// Value-typed so the client hands the main actor immutable copies.
    struct Snapshot: Equatable {
        private(set) var sessions: [String: Session] = [:]
        private(set) var attachments: [Attachment] = []
        private(set) var bySurfaceID: [String: String] = [:]
        private(set) var byPID: [Int32: String] = [:]
        private(set) var byTTY: [String: String] = [:]

        var isEmpty: Bool { sessions.isEmpty }

        init(sessions: [Session] = [], attachments: [Attachment] = []) {
            self.sessions = Dictionary(sessions.map { ($0.key, $0) }, uniquingKeysWith: { _, b in b })
            self.attachments = attachments
            reindex()
        }

        /// Applies one frame; returns whether anything changed.
        @discardableResult
        mutating func apply(_ frame: Frame) -> Bool {
            let before = self
            switch frame.type {
            case "snapshot":
                sessions = Dictionary((frame.sessions ?? []).map { ($0.key, $0) }, uniquingKeysWith: { _, b in b })
                attachments = frame.attachments ?? []
            case "delta":
                for session in frame.sessionsUpsert ?? [] { sessions[session.key] = session }
                for key in frame.sessionsRemove ?? [] { sessions[key] = nil }
                // Present means the full list, `[]` included.
                if let attachments = frame.attachments { self.attachments = attachments }
            default:
                return false
            }
            reindex()
            return self != before
        }

        /// First attachment wins each index slot, like agentd's sorted order.
        private mutating func reindex() {
            bySurfaceID = [:]
            byPID = [:]
            byTTY = [:]
            for attachment in attachments where sessions[attachment.sessionKey] != nil {
                let key = attachment.sessionKey
                if let surface = attachment.surfaceId?.uppercased(), bySurfaceID[surface] == nil {
                    bySurfaceID[surface] = key
                }
                for pid in attachment.pids where pid > 0 && byPID[pid] == nil { byPID[pid] = key }
                for tty in attachment.ttys {
                    if let tty = VerticalTabs.Agent.normalizeTTY(tty), byTTY[tty] == nil { byTTY[tty] = key }
                }
            }
        }

        /// One split to match: its surface UUID, candidate PIDs (foreground
        /// first) and controlling TTY.
        struct Terminal: Equatable {
            var surfaceID: String
            var pids: [Int32] = []
            var tty: String?
        }

        /// The session shown in a split: surface ID, then PID, then TTY.
        func session(for terminal: Terminal) -> Session? {
            if let key = bySurfaceID[terminal.surfaceID.uppercased()], let session = sessions[key] { return session }
            for pid in terminal.pids {
                if let key = byPID[pid], let session = sessions[key] { return session }
            }
            if let tty = VerticalTabs.Agent.normalizeTTY(terminal.tty), let key = byTTY[tty], let session = sessions[key] {
                return session
            }
            return nil
        }
    }
}

// MARK: - Tab summary

extension VerticalTabs.Agent {
    /// What a row shows, highest priority first.
    enum Display: Int, Comparable {
        case idle = 0, unread, working, awaiting

        static func < (a: Display, b: Display) -> Bool { a.rawValue < b.rawValue }

        /// `nil` for `unknown`: it never overrides a known state.
        init?(_ session: Session) {
            switch session.status {
            case .awaiting: self = .awaiting
            case .working: self = .working
            case .idle, .interrupted: self = session.unread ? .unread : .idle
            case .unknown: return nil
            }
        }
    }

    /// A compact badge after the title.
    enum BadgeKind: Equatable {
        case attention   // needs-you, blocked
        case done
        case waiting
        case active
    }

    struct Badge: Equatable {
        var kind: BadgeKind?
        /// The note's own glyph, which replaces the kind's.
        var icon: String?
        /// Note progress (`1/3`), else nil.
        var progress: String?
        /// Active child jobs.
        var jobs: Int = 0

        /// An `active` note draws nothing on its own; the tooltip has its text.
        var isEmpty: Bool { (kind == nil || kind == .active) && icon == nil && progress == nil && jobs == 0 }

        /// `⚙2`, `1/3`, or both.
        var text: String? {
            let parts = [progress, jobs > 0 ? "⚙\(jobs)" : nil].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// A tab's agent state, aggregated over its matched splits.
    struct Summary: Equatable {
        var display: Display
        var awaitingKind: String
        /// The age slot's anchor and whether it counts an active turn.
        var turnSince: Date?
        var inactiveSince: Date?
        var badge: Badge
        /// Full note and job details for the tooltip.
        var details: [String]
        /// The highest-priority split's session.
        var primaryKey: String
    }

    static func date(ms: Int64?) -> Date? {
        ms.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    static func badgeKind(noteState: String) -> BadgeKind? {
        switch noteState {
        case "needs-you", "blocked": return .attention
        case "done": return .done
        case "waiting": return .waiting
        case "active": return .active
        default: return nil
        }
    }

    static let activeJobStatuses: Set<String> = ["running", "finishing", "blocked"]

    /// Aggregates `sessions` (matched splits, focused first; duplicates
    /// allowed). `awaiting` > `working` > `unread` > `idle`, ties to the
    /// earlier split; `unknown` is ignored, and all-unknown is `nil`.
    static func summary(of sessions: [Session]) -> Summary? {
        var seen = Set<String>()
        let unique = sessions.filter { seen.insert($0.key).inserted }
        var best: (session: Session, display: Display)?
        for session in unique {
            guard let display = Display(session) else { continue }
            if best == nil || display > best!.display { best = (session, display) }
        }
        guard let (primary, display) = best else { return nil }

        let note = unique.lazy.compactMap { session -> Note? in
            guard let note = session.note, note.stale != true else { return nil }
            return note
        }.first { badgeKind(noteState: $0.state) != nil || $0.progress != nil }
            ?? primary.note.flatMap { $0.stale == true ? nil : $0 }
        let jobs = unique.flatMap(\.childJobs).filter { activeJobStatuses.contains($0.status) }

        var details: [String] = []
        if let note {
            var line = note.icon.map { "\($0) " } ?? ""
            line += note.state
            if !note.text.isEmpty { line += ": \(note.text)" }
            if let progress = note.progress { line += " (\(progress))" }
            details.append(line)
        }
        for job in jobs {
            details.append("⚙ \(job.name)" + (job.agent.map { " [\($0)]" } ?? "") + " — \(job.status)")
        }

        let inactive = [primary.lastPromptMs, primary.lastReplyMs].compactMap { $0 }.max()
        return Summary(
            display: display,
            awaitingKind: primary.awaitingKind,
            turnSince: display >= .working ? date(ms: primary.turnSinceMs) : nil,
            inactiveSince: display >= .working ? nil : date(ms: inactive),
            badge: Badge(
                kind: note.flatMap { badgeKind(noteState: $0.state) },
                icon: note?.icon,
                progress: note?.progress,
                jobs: jobs.count),
            details: details,
            primaryKey: primary.key)
    }

    /// Elapsed time for an active turn: `28s`, `2m`, `1h`, `3d`.
    static func elapsedText(since date: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }

    /// Seconds until `elapsedText` next changes: each second under a minute,
    /// then at each minute (or hour) boundary.
    static func nextElapsedTick(since date: Date, now: Date) -> TimeInterval {
        let elapsed = max(0, now.timeIntervalSince(date))
        let unit: TimeInterval = elapsed < 60 ? 1 : elapsed < 3600 ? 60 : 3600
        let next = (elapsed / unit).rounded(.down) * unit + unit
        return max(0.05, next - elapsed)
    }

    /// The age slot. Working/awaiting: elapsed since the turn began (none
    /// without `turnSinceMs`). Idle: since the last prompt or reply, else
    /// `fallback` (Ghostty's own `shownActive`). No summary: `fallback`.
    /// A selected tab shows only an active turn's elapsed time.
    static func ageText(summary: Summary?, fallback: Date?, isSelected: Bool, now: Date) -> String? {
        guard let summary else { return isSelected ? nil : VerticalTabs.ageText(since: fallback, now: now) }
        if summary.display >= .working {
            return summary.turnSince.map { elapsedText(since: $0, now: now) }
        }
        return isSelected ? nil : VerticalTabs.ageText(since: summary.inactiveSince ?? fallback, now: now)
    }
}

// MARK: - Acknowledging replies

extension VerticalTabs.Agent {
    /// The split that is visibly focused: the focused split of the selected
    /// tab of the key window, while the app is active.
    struct Focus: Equatable {
        var surfaceID: String
        /// When this split became visibly focused.
        var since: Date
    }

    enum AckDecision: Equatable {
        case none
        /// Check again at this time (the dwell hasn't passed yet).
        case wait(until: Date)
        case send(key: String, replyId: String)
    }

    /// Acks sent for one reply. agentd answers a failed save with `ok:false`
    /// and the reply stays unread, so a reply still unread `ackRetryAfter`
    /// later is sent again, at most `ackMaxAttempts` times.
    struct AckAttempt: Equatable {
        var count: Int
        var last: Date
    }

    static let ackRetryAfter: TimeInterval = 5
    static let ackMaxAttempts = 3

    /// Whether to acknowledge the reply shown in the visibly focused split.
    /// Only an unread reply, only after the split has been focused for
    /// `dwell` (stepping past a tab keeps its dot), and each reply once unless
    /// it stays unread (bounded retries). A reply arriving after the dwell
    /// sends right away.
    static func ackDecision(
        focus: Focus?, session: Session?, now: Date, dwell: TimeInterval, sent: [String: AckAttempt]
    ) -> AckDecision {
        guard let focus, let session, session.unread, !session.lastReplyId.isEmpty else { return .none }
        var due = focus.since.addingTimeInterval(dwell)
        if let attempt = sent[ackToken(key: session.key, replyId: session.lastReplyId)] {
            guard attempt.count < ackMaxAttempts else { return .none }
            due = max(due, attempt.last.addingTimeInterval(ackRetryAfter))
        }
        if now < due { return .wait(until: due) }
        return .send(key: session.key, replyId: session.lastReplyId)
    }

    static func ackToken(key: String, replyId: String) -> String { key + "\u{0}" + replyId }
}
