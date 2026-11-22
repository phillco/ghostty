import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import Ghostty

/// `agentd` integration: wire parsing, split matching, aggregation, the age
/// slot, reply acknowledgement and the socket client.
struct VerticalTabsAgentTests {
    typealias Agent = VerticalTabs.Agent

    private func frame(_ json: String) throws -> Agent.Frame {
        try #require(Agent.Frame.decode(Data(json.utf8)))
    }

    private static let stage1Snapshot = """
    {"type":"snapshot","v":1,"seq":1,"host":"laptop","sessions":[{"key":"claude://laptop/default/a",\
    "provider":"claude","host":"laptop","account":"default","nativeId":"a","peerName":"cc-a","cwd":"/x",\
    "projectKey":"~/x","title":"Fix","status":"working","awaitingKind":"","turnSinceMs":1795364000000,\
    "lastPromptMs":null,"lastReplyMs":1795363800000,"lastReplyId":"r1","unread":false}],\
    "attachments":[{"sessionKey":"claude://laptop/default/a","frontend":"cli","pids":[123],"ttys":["ttys004"]}],\
    "userState":{"ackedReplyId":{}}}
    """

    // MARK: Parsing

    @Test func parsesStage1SnapshotWithoutNoteOrJobs() throws {
        var state = Agent.Snapshot()
        #expect(state.apply(try frame(Self.stage1Snapshot)))
        let session = try #require(state.sessions["claude://laptop/default/a"])
        #expect(session.status == .working)
        #expect(session.turnSinceMs == 1_795_364_000_000)
        #expect(session.lastPromptMs == nil)
        #expect(session.lastReplyId == "r1")
        #expect(session.nativeId == "a" && session.peerName == "cc-a")
        #expect(session.note == nil)
        #expect(session.childJobs.isEmpty)
        #expect(state.attachments.first?.ttys == ["ttys004"])
    }

    @Test func parsesStage2NoteAndChildJobs() throws {
        let json = """
        {"type":"snapshot","v":1,"seq":2,"sessions":[{"key":"k","status":"idle","unread":true,\
        "note":{"state":"waiting","text":"Codex reviewing","progress":"1/3","icon":"⏳","updatedAtMs":5,"stale":false},\
        "childJobs":[{"name":"agentd-stage2","agent":"claude","status":"running","startedAtMs":7}]}],"attachments":[]}
        """
        var state = Agent.Snapshot()
        state.apply(try frame(json))
        let session = try #require(state.sessions["k"])
        #expect(session.note == Agent.Note(
            state: "waiting", text: "Codex reviewing", progress: "1/3", icon: "⏳", updatedAtMs: 5, stale: false))
        #expect(session.childJobs == [Agent.ChildJob(
            name: "agentd-stage2", agent: "claude", status: "running", startedAtMs: 7)])
    }

    @Test func decodesHasNewActivityDefaultingToFalse() throws {
        var state = Agent.Snapshot()
        state.apply(try frame(#"""
        {"type":"snapshot","sessions":[{"key":"a","status":"working","hasNewActivity":true},\#
        {"key":"b","status":"idle"},{"key":"c","status":"idle","hasNewActivity":null}]}
        """#))
        #expect(state.sessions["a"]?.hasNewActivity == true)
        #expect(state.sessions["b"]?.hasNewActivity == false)
        #expect(state.sessions["c"]?.hasNewActivity == false)
    }

    @Test func unknownStatusAndMissingFieldsDecodeLeniently() throws {
        var state = Agent.Snapshot()
        state.apply(try frame(#"{"type":"snapshot","sessions":[{"key":"k","status":"napping"}]}"#))
        #expect(state.sessions["k"]?.status == .unknown)
        #expect(state.attachments.isEmpty)
        #expect(Agent.Frame.decode(Data("not json".utf8)) == nil)
    }

    @Test func deltasUpsertRemoveAndReplaceAttachments() throws {
        var state = Agent.Snapshot()
        state.apply(try frame(Self.stage1Snapshot))
        // No attachments key: they stay.
        #expect(state.apply(try frame(
            #"{"type":"delta","seq":2,"sessionsUpsert":[{"key":"claude://laptop/default/a","status":"idle"}]}"#)))
        #expect(state.sessions["claude://laptop/default/a"]?.status == .idle)
        #expect(state.attachments.count == 1)
        // `[]` replaces them all.
        #expect(state.apply(try frame(#"{"type":"delta","seq":3,"attachments":[]}"#)))
        #expect(state.attachments.isEmpty)
        #expect(state.apply(try frame(#"{"type":"delta","seq":4,"sessionsRemove":["claude://laptop/default/a"]}"#)))
        #expect(state.isEmpty)
    }

    @Test func unchangedDeltaReportsNoChange() throws {
        var state = Agent.Snapshot()
        state.apply(try frame(Self.stage1Snapshot))
        #expect(!state.apply(try frame(Self.stage1Snapshot)))
        #expect(!state.apply(try frame(#"{"type":"ack","id":"x","ok":true}"#)))
    }

    @Test func ackReplyLineIsOneJSONLine() throws {
        let line = Agent.ackReplyLine(id: "1", key: "k", replyId: "r")
        #expect(line.last == 0x0A)
        let object = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: String])
        #expect(object == ["type": "ackReply", "id": "1", "key": "k", "replyId": "r"])
    }

    // MARK: Matching

    @Test(arguments: [
        ("/dev/ttys004", "ttys004"), ("ttys004", "ttys004"), ("s004", "ttys004"),
        ("", nil), ("??", nil),
    ] as [(String, String?)])
    func normalizesTTYs(raw: String, expected: String?) {
        #expect(Agent.normalizeTTY(raw) == expected)
    }

    private let surfaceA = "8D2E0C6A-0000-4000-8000-00000000000A"

    private var matchingState: Agent.Snapshot {
        .init(
            sessions: [.init(key: "bySurface"), .init(key: "byPID"), .init(key: "byTTY")],
            attachments: [
                .init(sessionKey: "byTTY", pids: [999], ttys: ["ttys004"]),
                .init(sessionKey: "byPID", pids: [123], ttys: []),
                .init(sessionKey: "bySurface", surfaceId: surfaceA.lowercased(), pids: [555]),
                .init(sessionKey: "gone", surfaceId: "X", pids: [1], ttys: ["ttys009"]),
            ])
    }

    @Test func matchPrefersSurfaceThenPIDThenTTY() {
        let state = matchingState
        let all = Agent.Snapshot.Terminal(surfaceID: surfaceA, pids: [123], tty: "/dev/ttys004")
        #expect(state.session(for: all)?.key == "bySurface")
        let pidAndTTY = Agent.Snapshot.Terminal(surfaceID: "other", pids: [123], tty: "/dev/ttys004")
        #expect(state.session(for: pidAndTTY)?.key == "byPID")
        let ttyOnly = Agent.Snapshot.Terminal(surfaceID: "other", pids: [42], tty: "/dev/ttys004")
        #expect(state.session(for: ttyOnly)?.key == "byTTY")
        #expect(state.session(for: .init(surfaceID: "other", pids: [42], tty: "ttys001")) == nil)
    }

    @Test func attachmentsForUnknownSessionsNeverMatch() {
        let state = matchingState
        #expect(state.session(for: .init(surfaceID: "X", pids: [1], tty: "ttys009")) == nil)
        #expect(state.bySurfaceID["X"] == nil)
    }

    // MARK: Aggregation

    private func session(
        _ key: String, _ status: Agent.Status, unread: Bool = false, turn: Int64? = nil,
        prompt: Int64? = nil, reply: Int64? = nil, note: Agent.Note? = nil, jobs: [Agent.ChildJob] = []
    ) -> Agent.Session {
        .init(key: key, status: status, turnSinceMs: turn, lastPromptMs: prompt, lastReplyMs: reply,
              lastReplyId: reply.map { "r\($0)" } ?? "", unread: unread, note: note, childJobs: jobs)
    }

    @Test(arguments: [
        ([Agent.Status.idle, .working, .awaiting], Agent.Display.awaiting),
        ([.idle, .working], .working),
        ([.working, .unknown], .working),
        ([.interrupted, .idle], .idle),
    ])
    func aggregatesByPriority(statuses: [Agent.Status], expected: Agent.Display) throws {
        let sessions = statuses.enumerated().map { session("s\($0.offset)", $0.element) }
        #expect(try #require(Agent.summary(of: sessions)).display == expected)
    }

    @Test func unreadOutranksIdleButNotWorking() throws {
        let unread = session("u", .idle, unread: true)
        #expect(try #require(Agent.summary(of: [session("i", .idle), unread])).display == .unread)
        #expect(try #require(Agent.summary(of: [unread, session("w", .working)])).display == .working)
    }

    @Test func edgeBarIsIndependentOfWorkingAndAwaiting() throws {
        // A split still working beside one with an unread reply: dot and bar both.
        let both = try #require(Agent.summary(of: [session("w", .working), session("u", .idle, unread: true)]))
        #expect(both.display == .working)
        #expect(both.edge == .unread)
        var awaiting = session("a", .awaiting)
        awaiting.hasNewActivity = true
        let asking = try #require(Agent.summary(of: [awaiting]))
        #expect(asking.display == .awaiting)
        #expect(asking.edge == .activity)
        // Unread outranks activity; neither leaves no bar.
        #expect(try #require(Agent.summary(of: [awaiting, session("u", .idle, unread: true)])).edge == .unread)
        #expect(try #require(Agent.summary(of: [session("i", .idle)])).edge == nil)
    }

    @Test func activityIndicatorConfigHidesOnlyTheDimBar() {
        #expect(Agent.EdgeMark.shown(.activity, activityIndicator: true) == .activity)
        #expect(Agent.EdgeMark.shown(.activity, activityIndicator: false) == nil)
        #expect(Agent.EdgeMark.shown(.unread, activityIndicator: false) == .unread)
        #expect(Agent.EdgeMark.shown(nil, activityIndicator: true) == nil)
        #expect(VerticalTabsAgentBadges.EdgeBar.opacity(.unread) == 1)
        #expect(VerticalTabsAgentBadges.EdgeBar.opacity(.activity) == 0.4)
    }

    @Test func activityIndicatorConfigKeyDefaultsOnAndLiveReloads() throws {
        let config = try TemporaryConfig("")
        #expect(config.verticalTabsActivityIndicator)
        #expect(VerticalTabsSettings.ConfigValues(config).activityIndicator)
        try config.reload("vertical-tabs-activity-indicator = false")
        #expect(!config.verticalTabsActivityIndicator)
        #expect(!VerticalTabsSettings.ConfigValues(config).activityIndicator)
    }

    @Test func allUnknownDegradesToNoSummary() {
        #expect(Agent.summary(of: [session("a", .unknown), session("b", .unknown)]) == nil)
        #expect(Agent.summary(of: []) == nil)
    }

    @Test func tiesGoToTheFocusedSplit() throws {
        let summary = try #require(Agent.summary(of: [session("focused", .working), session("other", .working)]))
        #expect(summary.primaryKey == "focused")
    }

    @Test func noteAndJobsFeedTheBadgeAndTooltip() throws {
        let note = Agent.Note(state: "needs-you", text: "Pick a plan", progress: "2/3")
        let jobs = [Agent.ChildJob(name: "a"), .init(name: "b", agent: "codex", status: "finishing"),
                    .init(name: "old", status: "done")]
        let summary = try #require(Agent.summary(of: [session("k", .idle, note: note, jobs: jobs)]))
        #expect(summary.badge == .init(kind: .attention, progress: "2/3", jobs: 2))
        #expect(summary.badge.text == "2/3 ⚙2")
        #expect(summary.details == ["needs-you: Pick a plan (2/3)", "⚙ a — running", "⚙ b [codex] — finishing"])
    }

    @Test func staleNotesAreHidden() throws {
        let note = Agent.Note(state: "blocked", text: "old", stale: true)
        let summary = try #require(Agent.summary(of: [session("k", .idle, note: note)]))
        #expect(summary.badge.isEmpty)
        #expect(summary.details.isEmpty)
    }

    @Test(arguments: [
        ("needs-you", Agent.BadgeKind.attention), ("blocked", .attention), ("done", .done),
        ("waiting", .waiting), ("active", .active),
    ])
    func noteStatesMapToBadges(state: String, kind: Agent.BadgeKind) {
        #expect(Agent.badgeKind(noteState: state) == kind)
    }

    @Test func aSiblingsRequestOutranksTheFocusedSplitsActiveNote() throws {
        let focused = session("f", .idle, note: .init(state: "active", text: "Refactoring"))
        let sibling = session("s", .idle, note: .init(state: "needs-you", text: "Pick a plan"))
        let summary = try #require(Agent.summary(of: [focused, sibling]))
        #expect(summary.badge.kind == .attention)
        #expect(summary.details == ["active: Refactoring", "needs-you: Pick a plan"])
        // Equal rank: the focused split's note.
        let other = session("o", .idle, note: .init(state: "needs-you", text: "Other", progress: "1/2"))
        #expect(try #require(Agent.summary(of: [sibling, other])).badge.progress == nil)
    }

    @Test func activeNoteAloneDrawsNoBadge() throws {
        let summary = try #require(Agent.summary(of: [session("k", .idle, note: .init(state: "active", text: "x"))]))
        #expect(summary.badge.isEmpty)
        #expect(summary.details == ["active: x"])
    }

    // MARK: Age slot

    private let now = Date(timeIntervalSince1970: 1_795_364_100)
    private func ms(_ secondsAgo: Double) -> Int64 { Int64((now.timeIntervalSince1970 - secondsAgo) * 1000) }

    @Test(arguments: [(28.0, "28s"), (0, "0s"), (125, "2m"), (3700, "1h"), (90_000, "1d")])
    func elapsedText(secondsAgo: Double, expected: String) {
        #expect(Agent.elapsedText(since: now.addingTimeInterval(-secondsAgo), now: now) == expected)
    }

    @Test func nextTickFollowsTheShownUnit() {
        #expect(abs(Agent.nextElapsedTick(since: now.addingTimeInterval(-28.25), now: now) - 0.75) < 0.001)
        #expect(abs(Agent.nextElapsedTick(since: now.addingTimeInterval(-125), now: now) - 55) < 0.001)
        #expect(abs(Agent.nextElapsedTick(since: now.addingTimeInterval(-3700), now: now) - 3500) < 0.001)
    }

    @Test func workingShowsElapsedSinceTheTurnBegan() {
        let summary = Agent.summary(of: [session("k", .working, turn: ms(28), reply: ms(5000))])
        let fallback = now.addingTimeInterval(-7200)
        #expect(Agent.ageText(summary: summary, fallback: fallback, isSelected: false, now: now) == "28s")
        // Also while selected: how long it has been running.
        #expect(Agent.ageText(summary: summary, fallback: fallback, isSelected: true, now: now) == "28s")
    }

    @Test func activeTurnWithoutStartShowsNoAge() {
        let summary = Agent.summary(of: [session("k", .awaiting)])
        #expect(Agent.ageText(summary: summary, fallback: now, isSelected: false, now: now) == nil)
    }

    @Test func idleShowsTheLatestPromptOrReply() {
        let summary = Agent.summary(of: [session("k", .idle, prompt: ms(600), reply: ms(180))])
        let fallback = now.addingTimeInterval(-7200)
        #expect(Agent.ageText(summary: summary, fallback: fallback, isSelected: false, now: now) == "3m")
        #expect(Agent.ageText(summary: summary, fallback: fallback, isSelected: true, now: now) == nil)
    }

    @Test func idleWithoutTimesAndPlainShellsUseGhosttysAge() {
        let fallback = now.addingTimeInterval(-7200)
        let idle = Agent.summary(of: [session("k", .interrupted)])
        #expect(Agent.ageText(summary: idle, fallback: fallback, isSelected: false, now: now) == "2h")
        #expect(Agent.ageText(summary: nil, fallback: fallback, isSelected: false, now: now) == "2h")
        #expect(Agent.ageText(summary: nil, fallback: fallback, isSelected: true, now: now) == nil)
    }

    @Test func agentStatusNeverReordersRecents() {
        final class Token {}
        let tokens = [Token(), Token()]
        let left = Date(timeIntervalSince1970: 100)
        let older = VerticalTabs.Tab(id: ObjectIdentifier(tokens[0]), surfaceIDs: ["a"], title: "a",
                                     lastLeft: left, agent: Agent.summary(of: [session("k", .awaiting)]))
        let newer = VerticalTabs.Tab(id: ObjectIdentifier(tokens[1]), surfaceIDs: ["b"], title: "b",
                                     lastLeft: left.addingTimeInterval(10))
        let recents = VerticalTabs.sections(tabs: [older, newer], pins: []).recents.map(\.id)
        #expect(recents == [newer.id, older.id])
    }

    // MARK: Acknowledging replies

    private let dwell: TimeInterval = 3

    @Test func noAckBeforeTheDwell() {
        let focus = Agent.Focus(surfaceID: "s", since: now.addingTimeInterval(-1))
        let unread = session("k", .idle, unread: true, reply: 1)
        #expect(Agent.ackDecision(focus: focus, session: unread, now: now, dwell: dwell, sent: [:])
            == .wait(until: now.addingTimeInterval(2)))
    }

    @Test func acksOnceAfterTheDwell() {
        let focus = Agent.Focus(surfaceID: "s", since: now.addingTimeInterval(-3))
        let unread = session("k", .idle, unread: true, reply: 1)
        #expect(Agent.ackDecision(focus: focus, session: unread, now: now, dwell: dwell, sent: [:])
            == .send(key: "k", replyId: "r1"))
        let sent = [Agent.ackToken(key: "k", replyId: "r1"): Agent.AckAttempt(count: 1, last: now)]
        #expect(Agent.ackDecision(focus: focus, session: unread, now: now, dwell: dwell, sent: sent)
            == .wait(until: now.addingTimeInterval(Agent.ackRetryAfter)))
    }

    @Test func aReplyStillUnreadIsRetriedAFewTimes() {
        let focus = Agent.Focus(surfaceID: "s", since: now.addingTimeInterval(-60))
        let unread = session("k", .idle, unread: true, reply: 1)
        let token = Agent.ackToken(key: "k", replyId: "r1")
        let later = now.addingTimeInterval(Agent.ackRetryAfter)
        let once = [token: Agent.AckAttempt(count: 1, last: now)]
        #expect(Agent.ackDecision(focus: focus, session: unread, now: later, dwell: dwell, sent: once)
            == .send(key: "k", replyId: "r1"))
        let exhausted = [token: Agent.AckAttempt(count: Agent.ackMaxAttempts, last: now)]
        #expect(Agent.ackDecision(focus: focus, session: unread, now: later, dwell: dwell, sent: exhausted) == .none)
        // Acknowledged (no longer unread): nothing more to send.
        let read = session("k", .idle, unread: false, reply: 1)
        #expect(Agent.ackDecision(focus: focus, session: read, now: later, dwell: dwell, sent: once) == .none)
    }

    @Test func aNewReplyWhileFocusedAcksImmediately() {
        let focus = Agent.Focus(surfaceID: "s", since: now.addingTimeInterval(-60))
        let sent = [Agent.ackToken(key: "k", replyId: "r1"): Agent.AckAttempt(count: 1, last: now)]
        let newer = session("k", .idle, unread: true, reply: 2)
        #expect(Agent.ackDecision(focus: focus, session: newer, now: now, dwell: dwell, sent: sent)
            == .send(key: "k", replyId: "r2"))
    }

    @Test func nothingToAckWithoutFocusOrUnread() {
        let focus = Agent.Focus(surfaceID: "s", since: now.addingTimeInterval(-60))
        let unread = session("k", .idle, unread: true, reply: 1)
        // No visibly focused split: background tab, unfocused window or inactive app.
        #expect(Agent.ackDecision(focus: nil, session: unread, now: now, dwell: dwell, sent: [:]) == .none)
        // The focused split has no session (its neighbor's unread stays).
        #expect(Agent.ackDecision(focus: focus, session: nil, now: now, dwell: dwell, sent: [:]) == .none)
        let read = session("k", .idle, unread: false, reply: 1)
        #expect(Agent.ackDecision(focus: focus, session: read, now: now, dwell: dwell, sent: [:]) == .none)
        let noReply = session("k", .idle, unread: true)
        #expect(Agent.ackDecision(focus: focus, session: noReply, now: now, dwell: dwell, sent: [:]) == .none)
    }

    @Test func explicitSelectionAcksAtOnceButSteppingWaitsTheDwell() {
        let unread = session("k", .idle, unread: true, reply: 1)
        // Just focused: a click or Cmd+N sends now; previous/next waits.
        let focus = Agent.Focus(surfaceID: "s", since: now)
        let explicit = Agent.ackDwell(enteredDirectionally: false, recentsDwell: dwell)
        let stepped = Agent.ackDwell(enteredDirectionally: true, recentsDwell: dwell)
        #expect(explicit == 0)
        #expect(stepped == dwell)
        #expect(Agent.ackDecision(focus: focus, session: unread, now: now, dwell: explicit, sent: [:])
            == .send(key: "k", replyId: "r1"))
        #expect(Agent.ackDecision(focus: focus, session: unread, now: now, dwell: stepped, sent: [:])
            == .wait(until: now.addingTimeInterval(dwell)))
    }

    @Test func optimisticReadsClearOnlyTheAckedReply() {
        let state = Agent.Snapshot(sessions: [
            session("a", .idle, unread: true, reply: 1),
            session("b", .working, unread: true, reply: 2),
        ])
        let token = Agent.ackToken(key: "a", replyId: "r1")
        let shown = state.markingRead([token])
        #expect(shown.sessions["a"]?.unread == false)
        #expect(shown.sessions["b"]?.unread == true)
        #expect(state.isUnread(token: token))
        #expect(!shown.isUnread(token: token))
        // A newer reply isn't covered by the old ack.
        let newer = Agent.Snapshot(sessions: [session("a", .idle, unread: true, reply: 3)])
        #expect(newer.markingRead([token]).sessions["a"]?.unread == true)
        #expect(!newer.isUnread(token: token))
    }

    // MARK: Narrow rows

    @MainActor
    @Test(arguments: [(CGFloat(12), CGFloat(24)), (14, 12), (24, 10), (9, 9)])
    func statusDotsFitTheGutterAtAnyFontSizes(title: CGFloat, secondary: CGFloat) {
        let metrics = VerticalTabsMetrics(fontSize: title, secondarySize: secondary)
        for status in [Agent.Display.awaiting, .working, .unread] {
            let width = NSHostingView(rootView: VerticalTabsAgentBadges.StatusDot(
                status: status, metrics: metrics)).fittingSize.width
            #expect(width < metrics.rowPadding)
        }
    }

    @MainActor
    @Test(arguments: [CGFloat(9), 14, 24])
    func edgeBarSitsInTheSidebarGutter(fontSize: CGFloat) {
        let metrics = VerticalTabsMetrics(fontSize: fontSize, secondarySize: fontSize - 2)
        let bar = VerticalTabsAgentBadges.EdgeBar(edge: .unread, metrics: metrics)
        #expect(NSHostingView(rootView: bar).fittingSize.width == VerticalTabsAgentBadges.EdgeBar.width)
        // Left of the row, inside the sidebar's gutter.
        #expect(VerticalTabsAgentBadges.EdgeBar.offset < 0)
        #expect(-VerticalTabsAgentBadges.EdgeBar.offset <= VerticalTabsMetrics.sidebarGutter)
    }

    @MainActor
    @Test(arguments: [CGFloat(14), 16])
    func badgeFallbacksShrinkAndStayCompact(fontSize: CGFloat) {
        let metrics = VerticalTabsMetrics(fontSize: fontSize, secondarySize: fontSize - 2)
        let badge = Agent.Badge(kind: .waiting, progress: "2/3", jobs: 2)
        func width(_ detail: VerticalTabsAgentBadges.Detail) -> CGFloat {
            NSHostingView(rootView: VerticalTabsAgentBadges.BadgeView(
                badge: badge, detail: detail, metrics: metrics)).fittingSize.width
        }
        let full = width(.full)
        let glyph = width(.glyph)
        #expect(glyph < full)
        // The glyph alone is about one character, so it fits beside `titleMinWidth`.
        #expect(glyph <= fontSize * 1.5)
        // Status dots sit in the row's leading padding, costing the title nothing.
        for status in [Agent.Display.awaiting, .working, .unread] {
            let dot = NSHostingView(rootView: VerticalTabsAgentBadges.StatusDot(
                status: status, metrics: metrics)).fittingSize
            #expect(dot.width < metrics.rowPadding)
        }
    }
}

// MARK: - Socket client

/// A real Unix socket server feeding the client.
@MainActor
struct VerticalTabsAgentClientTests {
    private final class Server {
        let path: String
        let listener: Int32
        var client: Int32 = -1

        init() throws {
            path = NSTemporaryDirectory() + "agentd-test-\(UUID().uuidString.prefix(8)).sock"
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(bound == 0)
            try #require(listen(listener, 4) == 0)
        }

        /// Gives up after a few seconds, so a regression fails instead of hanging.
        func accept() {
            var fds = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&fds, 1, 5000) == 1 else { return }
            client = Darwin.accept(listener, nil, nil)
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }

        func send(_ text: String) {
            _ = Array(text.utf8).withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
        }

        func readLine() -> String? {
            var out = [UInt8]()
            var byte: UInt8 = 0
            while Darwin.read(client, &byte, 1) == 1 {
                if byte == 0x0A { return String(bytes: out, encoding: .utf8) }
                out.append(byte)
            }
            return nil
        }

        func dropClient() {
            Darwin.close(client)
            client = -1
        }

        deinit {
            if client >= 0 { Darwin.close(client) }
            Darwin.close(listener)
            unlink(path)
        }
    }

    private final class Updates {
        var all: [VerticalTabs.Agent.Snapshot] = []
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test func streamsPartialLinesAndClearsOnDisconnect() async throws {
        let server = try Server()
        let updates = Updates()
        let client = VerticalTabsAgentClient(socketPath: server.path) { updates.all.append($0) }
        client.start()
        defer { client.stop() }
        await Task.detached { server.accept() }.value
        try #require(server.client >= 0)

        // One snapshot split across writes, then a delta in the same write as
        // the snapshot's tail.
        server.send(#"{"type":"snapshot","sessions":[{"key":"k","status":"wor"#)
        try? await Task.sleep(nanoseconds: 50_000_000)
        server.send(#"king","lastReplyId":"r1","unread":true}],"attachments":[]}"# + "\n"
            + #"{"type":"delta","sessionsUpsert":[{"key":"k","status":"idle","lastReplyId":"r1","unread":true}]}"#
            + "\n")
        await waitFor { updates.all.last?.sessions["k"]?.status == .idle }
        #expect(updates.all.last?.sessions["k"]?.status == .idle)
        // Coalesced: never more updates than frames.
        #expect(updates.all.count <= 2)

        client.ackReply(key: "k", replyId: "r1")
        let line = await Task.detached { server.readLine() }.value
        let ack = try #require(line.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]
        })
        #expect(ack["type"] == "ackReply" && ack["key"] == "k" && ack["replyId"] == "r1")

        server.dropClient()
        await waitFor { updates.all.last?.isEmpty == true }
        #expect(updates.all.last?.isEmpty == true)
    }

    @Test func missingSocketStaysSilentAndEmpty() async {
        let updates = Updates()
        let client = VerticalTabsAgentClient(socketPath: "/nonexistent/agentd.sock") { updates.all.append($0) }
        client.start()
        try? await Task.sleep(nanoseconds: 700_000_000)
        client.stop()
        #expect(updates.all.isEmpty)
        // Acks while disconnected are dropped, not queued.
        client.ackReply(key: "k", replyId: "r")
    }
}
