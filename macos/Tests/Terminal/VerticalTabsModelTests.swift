import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Ghostty

// The walk fixture's native order [P1, P2, R3, O1, R1, O2, R4, R2, O3]: Pinned
// [P1, P2], Recents [R1, R2, R3, R4] (newest first), Open [O1, O2, O3].
private let (p1, p2, r3, o1, r1, o2, r4, r2, o3) = (0, 1, 2, 3, 4, 5, 6, 7, 8)

struct VerticalTabsModelTests {
    /// Distinct objects give us stable `ObjectIdentifier`s for fake tabs.
    private final class Token {}
    private let tokens = (0..<12).map { _ in Token() }

    private func tab(
        _ index: Int,
        title: String = "",
        folder: String? = nil,
        selected: Bool = false,
        left: TimeInterval? = nil,
        surfaces: [String]? = nil
    ) -> VerticalTabs.Tab {
        VerticalTabs.Tab(
            id: ObjectIdentifier(tokens[index]),
            surfaceIDs: surfaces ?? ["s\(index)"],
            title: title.isEmpty ? "tab \(index)" : title,
            folder: folder,
            isSelected: selected,
            lastLeft: left.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func ids(_ tabs: [VerticalTabs.Tab]) -> [ObjectIdentifier] { tabs.map(\.id) }
    private func id(_ index: Int) -> ObjectIdentifier { ObjectIdentifier(tokens[index]) }

    // MARK: Title parsing

    @Test(arguments: [
        ("✦ Reviewing Claude Audio Detection Proposal", "Reviewing Claude Audio Detection Proposal", VerticalTabs.Platform.agy),
        ("✳ Fix the build", "Fix the build", .claude),
        ("⠋ ✳ Fix the build", "Fix the build", .claude),
        ("⠹⠸ ✦ Working", "Working", .agy),
        ("\u{2800}plain", "plain", .terminal),
        ("🔔 ✳ Needs input", "Needs input", .claude),
        ("vim README.md", "vim README.md", .terminal),
        ("  ✳  spaced  ", "spaced", .claude),
        ("a ✳ in the middle", "a ✳ in the middle", .terminal),
        ("✧ Text Read", "Text Read", .agy),
        ("◐ Clarc-observer", "Clarc-observer", nil),
        ("◓ moon frame", "moon frame", nil),
        ("🔔 ◑ ambiguous", "ambiguous", nil),
        ("⠋ ◒ Busy Claude", "Busy Claude", .claude),
        ("◥ tri frame", "tri frame", .agy),
        ("◉ halo idle", "halo idle", .agy),
        ("⠂ Busy Claude", "Busy Claude", .claude),
        ("⠐⠂ Busy Claude", "Busy Claude", .claude),
        ("🔔 ⠋ Busy Claude", "Busy Claude", .claude),
        ("⠋ 🔔 ✧ Busy agy", "Busy agy", .agy),
        ("🔔 ◜ Needs input", "Needs input", .agy),
    ])
    func parsesTitles(raw: String, text: String, platform: VerticalTabs.Platform?) {
        let parsed = VerticalTabs.parseTitle(raw)
        #expect(parsed.text == text)
        #expect(parsed.platform == platform)
    }

    @Test func everyAgyGlyphIsAgy() {
        for glyph in VerticalTabs.agyGlyphs {
            #expect(VerticalTabs.parseTitle("\(glyph) t") == .init(text: "t", platform: .agy))
        }
        #expect(VerticalTabs.agyGlyphs.count == 22)
        #expect(VerticalTabs.agyGlyphs.isDisjoint(with: VerticalTabs.ambiguousSpinnerGlyphs))
    }

    @Test func ambiguousSpinnerKeepsLastPlatform() {
        func resolve(_ titles: [String]) -> [VerticalTabs.Platform] {
            var last: VerticalTabs.Platform?
            return titles.map { title in
                let resolved = VerticalTabs.resolvePlatform(VerticalTabs.parseTitle(title).platform, last: last)
                last = resolved.last
                return resolved.shown
            }
        }
        #expect(resolve(["✦ idle", "◐ busy", "◓ busy", "✦ idle"]) == [.agy, .agy, .agy, .agy])
        #expect(resolve(["✳ idle", "◐ busy", "⠋ busy", "◑ busy"]) == [.claude, .claude, .claude, .claude])
        // No history defaults to Claude; a plain title forgets the agent.
        #expect(resolve(["◐ busy"]) == [.claude])
        #expect(resolve(["✦ idle", "zsh", "◐ busy"]) == [.agy, .terminal, .claude])
    }

    @Test func pillText() {
        #expect(VerticalTabs.pillText("ghostty") == "ghostty")
        #expect(VerticalTabs.pillText("Clarc-observer") == "Clarc-obser…")
        #expect(VerticalTabs.pillText("Clarc-observer").count == 12)
        #expect(VerticalTabs.pillText("Clarc-observer", maxChars: 0) == "Clarc-observer")
        #expect(VerticalTabs.pillText("Clarc-observer", maxChars: 6) == "Clarc…")
        #expect(VerticalTabs.pillText("Clarc", maxChars: 6) == "Clarc")
    }

    // MARK: Copy ID

    @Test func defaultPeerNames() {
        let id = "85a92d14-377f-4112-9bb3-614db07e7b4f"
        #expect(VerticalTabs.defaultPeerName(agent: "agy", id: id, cwd: "/Users/p/src/ports/ghostty") == "agy-ghostty-85a9")
        #expect(VerticalTabs.defaultPeerName(agent: "agy", id: id, cwd: "/Users/p/My Repo!") == "agy-my-repo-85a9")
        #expect(VerticalTabs.defaultPeerName(agent: "agy", id: id, cwd: "/Users/p/ghostty.worktrees") == "agy-ghostty.worktrees-85a9")
        #expect(VerticalTabs.defaultPeerName(agent: "agy", id: id, cwd: "") == "agy-85a92d14")
        #expect(VerticalTabs.defaultPeerName(agent: "agy", id: id, cwd: "/") == "agy-85a92d14")
        #expect(VerticalTabs.defaultPeerName(agent: "claude", id: id, cwd: "/x") == "cc-85a92d14")
        let long = VerticalTabs.defaultPeerName(agent: "agy", id: id, cwd: "/" + String(repeating: "abcdefghij", count: 5))
        #expect(long == "agy-abcdefghijabcdefghijabcdefghija-85a9")
        #expect(long.count == 40)
    }

    @Test func peerSlug() {
        #expect(VerticalTabs.peerSlug("--Hello, World..") == "hello-world")
        #expect(VerticalTabs.peerSlug("a_b.c-d") == "a_b.c-d")
        #expect(VerticalTabs.peerSlug("Café") == "caf")
    }

    @Test func claudeSessionFile() throws {
        let named = Data(#"{"pid":79146,"sessionId":"edfb2ff9-6c83-43a8-894e-4922f5a75e20","name":"bin-97","cwd":"/x"}"#.utf8)
        let session = try #require(VerticalTabs.claudeSession(json: named))
        #expect(session.pids == [79146])
        #expect(session.copyText == "edfb2ff9-6c83-43a8-894e-4922f5a75e20 (bin-97)")

        let unnamed = Data(#"{"pid":5,"sessionId":"edfb2ff9-6c83-43a8-894e-4922f5a75e20"}"#.utf8)
        #expect(VerticalTabs.claudeSession(json: unnamed)?.peerId == "cc-edfb2ff9")
        #expect(VerticalTabs.claudeSession(json: Data(#"{"sessionId":"x"}"#.utf8)) == nil)
        #expect(VerticalTabs.claudeSession(json: Data("not json".utf8)) == nil)
        let mailbox = Data(#"{"pid":5,"sessionId":"edfb2ff9","name":"cc-mailbox","ccMailbox":true}"#.utf8)
        #expect(VerticalTabs.claudeSession(json: mailbox) == nil)
        let notMailbox = Data(#"{"pid":5,"sessionId":"edfb2ff9","ccMailbox":false}"#.utf8)
        #expect(VerticalTabs.claudeSession(json: notMailbox) != nil)
    }

    private let noBridge: VerticalTabs.BridgeNameReader = { _ in nil }

    @Test func clarcReadyFile() throws {
        let agy = Data(#"{"agent":"agy","cwd":"/Users/p/src/ports/ghostty","pid":17266,"sessionId":"85a92d14-377f-4112-9bb3-614db07e7b4f"}"#.utf8)
        let session = try #require(VerticalTabs.clarcSession(json: agy, bridgeName: noBridge))
        #expect(session.pids == [17266])
        #expect(session.copyText == "85a92d14-377f-4112-9bb3-614db07e7b4f (agy-ghostty-85a9)")

        let claude = Data(#"{"agent":"claude","cwd":"/x","pid":3,"sessionId":"edfb2ff9-6c83"}"#.utf8)
        #expect(VerticalTabs.clarcSession(json: claude, bridgeName: noBridge)?.peerId == "cc-edfb2ff9")
    }

    @Test func bridgeNameOverridesAgyDefault() throws {
        let id = "125baf20-845c-40f2-86fa-a71852410ef4"
        let bridge: VerticalTabs.BridgeNameReader = { $0 == id ? "Gemini Usage Cost & Caching\n" : nil }
        let ready = Data(#"{"agent":"agy","cwd":"/Users/p/bin","pid":17063,"sessionId":"\#(id)"}"#.utf8)
        let session = try #require(VerticalTabs.clarcSession(json: ready, bridgeName: bridge))
        #expect(session.copyText == "\(id) (gemini-usage-cost-caching)")

        let host = Data(#"{"pid":1,"client":2,"cwd":"/Users/p/bin","sessionId":"\#(id)"}"#.utf8)
        #expect(VerticalTabs.agHostSession(json: host, bridgeName: bridge)?.peerId == "gemini-usage-cost-caching")

        // Blank registrations fall back; Claude never consults the bridge.
        #expect(VerticalTabs.agyPeerName(id: id, cwd: "/Users/p/bin", bridgeName: { _ in " \n" }) == "agy-bin-125b")
        let claude = Data(#"{"agent":"claude","cwd":"/x","pid":3,"sessionId":"\#(id)"}"#.utf8)
        #expect(VerticalTabs.clarcSession(json: claude, bridgeName: bridge)?.peerId == "cc-125baf20")
    }

    @Test func agHostFile() throws {
        let data = Data(#"{"pid":17346,"cwd":"/Users/p/src/PopLab","sessionId":"ebc60ada-ff4b","agyPid":17347,"client":17179,"clients":[17180],"socket":"/tmp/h.sock"}"#.utf8)
        let session = try #require(VerticalTabs.agHostSession(json: data, bridgeName: noBridge))
        #expect(session.pids == [17179, 17180])
        #expect(session.hostPID == 17346)
        #expect(session.processNames == ["ag"])
        #expect(session.peerId == "agy-poplab-ebc6")
    }

    // MARK: Session matching

    private func session(_ pid: Int32, _ peer: String, names: Set<String> = ["ag"],
                         socket: String? = nil, host: Int32? = nil) -> VerticalTabs.AgentSession {
        .init(pids: [pid], sessionId: "s\(pid)", peerId: peer, processNames: names, socketPath: socket, hostPID: host)
    }

    private func match(
        _ terminals: [VerticalTabs.TerminalKey],
        _ candidates: [VerticalTabs.AgentSession],
        processes: [Int32: VerticalTabs.ProcessSnapshot],
        files: Set<String> = []
    ) -> String? {
        VerticalTabs.matchSession(
            terminals: terminals, candidates: candidates,
            process: { processes[$0] }, fileExists: files.contains)?.peerId
    }

    @Test func focusedSplitWinsOverCandidateOrder() {
        let claude = session(100, "bin-97", names: VerticalTabs.claudeProcessNames)
        let agy = session(200, "agy-ghostty-85a9")
        let processes: [Int32: VerticalTabs.ProcessSnapshot] = [
            100: .init(name: "claude.exe", tty: 9),
            200: .init(name: "ag", tty: 8),
        ]
        let agySplit = VerticalTabs.TerminalKey(device: 8, foregroundPID: 50)
        let claudeSplit = VerticalTabs.TerminalKey(device: 9, foregroundPID: 51)
        // Claude files are candidates first, but the focused (first) split decides.
        #expect(match([agySplit, claudeSplit], [claude, agy], processes: processes) == "agy-ghostty-85a9")
        #expect(match([claudeSplit, agySplit], [claude, agy], processes: processes) == "bin-97")
        // The foreground PID matches without a TTY.
        #expect(match([.init(device: nil, foregroundPID: 200)], [claude, agy], processes: processes) == "agy-ghostty-85a9")
        #expect(match([.init(device: 7, foregroundPID: 1)], [claude, agy], processes: processes) == nil)
        // Within one terminal, an exact foreground PID beats an earlier same-TTY candidate.
        let sameTTY: [Int32: VerticalTabs.ProcessSnapshot] = [
            100: .init(name: "claude.exe", tty: 8),
            200: .init(name: "ag", tty: 8),
        ]
        #expect(match([.init(device: 8, foregroundPID: 200)], [claude, agy], processes: sameTTY) == "agy-ghostty-85a9")
    }

    @Test func staleSessionsNeverMatch() {
        let term = VerticalTabs.TerminalKey(device: 8, foregroundPID: 300)
        // A dead agent's PID reused by a shell on this TTY.
        #expect(match([term], [session(300, "dead")], processes: [300: .init(name: "zsh", tty: 8)]) == nil)
        // A dead PID that no longer exists.
        #expect(match([term], [session(300, "dead")], processes: [:]) == nil)
        // A live process whose socket is gone.
        let ag: [Int32: VerticalTabs.ProcessSnapshot] = [300: .init(name: "ag", tty: 8), 400: .init(name: "ag", tty: nil)]
        #expect(match([term], [session(300, "a", socket: "/tmp/x.sock")], processes: ag) == nil)
        #expect(match([term], [session(300, "a", socket: "/tmp/x.sock")], processes: ag, files: ["/tmp/x.sock"]) == "a")
        // ag-host: the host must be alive and an ag process.
        #expect(match([term], [session(300, "h", host: 401)], processes: ag) == nil)
        #expect(match([term], [session(300, "h", host: 400)], processes: ag) == "h")
    }

    @Test func ownerBornAfterTheFileWasWrittenNeverMatches() {
        let term = VerticalTabs.TerminalKey(device: 8, foregroundPID: 300)
        var written = session(300, "a")
        written.fileMtime = 1_000
        func proc(started: Double?) -> [Int32: VerticalTabs.ProcessSnapshot] {
            [300: .init(name: "ag", tty: 8, startTime: started)]
        }
        // Born before the write (a prespawned spare), or within the slack: the writer.
        #expect(match([term], [written], processes: proc(started: 500)) == "a")
        #expect(match([term], [written], processes: proc(started: 1_002)) == "a")
        // Born after the write: a reused PID.
        #expect(match([term], [written], processes: proc(started: 1_002.5)) == nil)
        // Unknown times don't reject.
        #expect(match([term], [written], processes: proc(started: nil)) == "a")
        #expect(match([term], [session(300, "b")], processes: proc(started: 9_999)) == "b")
        // The ag-host process is checked too.
        var hosted = session(300, "h", host: 400)
        hosted.fileMtime = 1_000
        var processes = proc(started: 900)
        processes[400] = .init(name: "ag", tty: nil, startTime: 1_100)
        #expect(match([term], [hosted], processes: processes) == nil)
    }

    @Test func parsedSessionsCarryValidation() throws {
        let claude = try #require(VerticalTabs.claudeSession(json: Data(
            #"{"pid":5,"sessionId":"edfb2ff9","messagingSocketPath":"/tmp/cc-socks/5.sock"}"#.utf8)))
        #expect(claude.socketPath == "/tmp/cc-socks/5.sock")
        #expect(claude.processNames.contains("claude.exe"))
        let ready = try #require(VerticalTabs.clarcSession(json: Data(
            #"{"agent":"agy","pid":6,"sessionId":"125baf20","socket":"/tmp/c.sock"}"#.utf8), bridgeName: noBridge))
        #expect(ready.socketPath == "/tmp/c.sock")
        #expect(ready.processNames == ["ag"])
    }

    // MARK: Settings

    /// Runs `body` against an empty defaults suite, removed afterward.
    private func withFreshDefaults(_ body: (UserDefaults) -> Void) {
        let name = "VerticalTabsModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func settingsDefaults() {
        withFreshDefaults { defaults in
            let settings = VerticalTabsSettings(defaults: defaults)
            #expect(settings.density == .compact)
            #expect(settings.textSize == .medium)
            #expect(settings.fontSize == 14)
            #expect(settings.secondaryFontSize == 10.5)
            #expect(settings.config == .init())
            #expect(settings.showFolders)
            #expect(settings.showIdleTime)
            #expect(settings.showShortcuts)
            #expect(settings.showIcons)
            #expect(settings.showRecents)
        }
    }

    @MainActor @Test func widthLimitKeepsNaturalWidth() {
        func width(_ text: String, max: CGFloat) -> CGFloat {
            let view = VerticalTabsWidthLimit(max: max) { Text(text).lineLimit(1) }
            return NSHostingView(rootView: view).fittingSize.width
        }
        let natural = NSHostingView(rootView: Text("ghostty").lineLimit(1)).fittingSize.width
        #expect(width("ghostty", max: 96) == natural)
        #expect(width(String(repeating: "long-folder-name ", count: 10), max: 96) <= 96)
    }

    @Test func textSizePoints() {
        #expect(VerticalTabsSettings.TextSize.allCases.map(\.pointSize) == [12, 14, 16])
    }

    @Test func metricsScaleWithFontSize() {
        func metrics(_ size: CGFloat) -> VerticalTabsMetrics {
            VerticalTabsMetrics(fontSize: size, secondarySize: max(9, size - 3.5))
        }
        let sizes: [CGFloat] = [12, 14, 16, 18]
        let all = sizes.map(metrics)
        #expect(all.map(\.minRowHeight) == [23, 27, 30, 34])
        #expect(all.map(\.rowGap) == [2, 3, 3, 3])
        #expect(all.map(\.rowPadding) == [7, 8, 9, 10])
        #expect(all.map(\.itemSpacing) == [5, 6, 7, 8])
        #expect(all.map(\.spacerMin) == [3, 4, 4, 5])
        #expect(all.map(\.cornerRadius) == [6, 7, 8, 9])
        #expect(all.map(\.titleMinWidth) == [30, 35, 40, 45])
        #expect(all.map(\.pillHorizontalPadding) == [4, 5, 6, 7])
        #expect(all.map(\.pillVerticalPadding) == [1, 1, 2, 2])
        // With the rows' half gaps: ~0.55em above a header, ~0.2em below it.
        #expect(all.map { $0.headerTop + $0.rowGap / 2 } == [7, 8, 9, 10])
        #expect(all.map { $0.headerBottom + $0.rowGap / 2 } == [2, 3, 3, 4])
        // Tiny sizes keep a visible gap and pill padding.
        #expect(metrics(7).rowGap == 2)
        #expect(metrics(7).pillVerticalPadding == 1)
    }

    @Test func configPointSizes() {
        #expect(Ghostty.Config.pointSize(0, in: 8...32) == nil)
        #expect(Ghostty.Config.pointSize(-3, in: 8...32) == nil)
        #expect(Ghostty.Config.pointSize(.nan, in: 8...32) == nil)
        #expect(Ghostty.Config.pointSize(.infinity, in: 8...32) == nil)
        #expect(Ghostty.Config.pointSize(nil, in: 8...32) == nil)
        #expect(Ghostty.Config.pointSize(4, in: 8...32) == 8)
        #expect(Ghostty.Config.pointSize(14.5, in: 8...32) == 14.5)
        #expect(Ghostty.Config.pointSize(99, in: 8...32) == 32)
        #expect(Ghostty.Config.recentsDwell(.nan) == 1)
        #expect(Ghostty.Config.recentsDwell(-1) == 1)
        #expect(Ghostty.Config.recentsDwell(0) == 0)
        #expect(Ghostty.Config.recentsDwell(2.5) == 2.5)
        #expect(Ghostty.Config.recentsDwell(100) == 30)
        #expect(VerticalTabsSettings.ConfigValues() == .init(
            fontSize: nil, secondaryFontSize: nil, recentsLimit: 4, recentsDwell: 1, pillMaxChars: 12,
            activityIndicator: true))
        #expect(VerticalTabsSettings.pointLabel(14) == "14pt")
        #expect(VerticalTabsSettings.pointLabel(14.5) == "14.5pt")
    }

    @Test func configFontSizePrecedence() {
        withFreshDefaults { defaults in
            let settings = VerticalTabsSettings(defaults: defaults)
            settings.textSize = .large

            // Setting the key takes over from the menu.
            settings.applyConfig(.init(fontSize: 13))
            #expect(settings.textSizeChoice == nil)
            #expect(settings.fontSize == 13)
            #expect(settings.secondaryFontSize == 9.5)

            // The menu overrides it, and an unrelated reload keeps that choice.
            settings.textSizeChoice = .small
            #expect(settings.fontSize == 12)
            #expect(settings.textSize == .small)
            settings.applyConfig(.init(fontSize: 13, recentsLimit: 2))
            #expect(settings.fontSize == 12)

            // Choosing Config again, or changing the key, re-selects it.
            settings.textSizeChoice = nil
            #expect(settings.fontSize == 13)
            settings.textSizeChoice = .medium
            settings.applyConfig(.init(fontSize: 16, recentsLimit: 2))
            #expect(settings.textSizeChoice == nil)
            #expect(settings.fontSize == 16)

            // Removing the key falls back to the persisted menu size.
            settings.applyConfig(.init())
            #expect(settings.textSizeChoice == .medium)
            #expect(settings.fontSize == 14)
            #expect(VerticalTabsSettings(defaults: defaults).textSize == .medium)

            // A preset picked over a configured size survives a restart at that size,
            // but a different configured size takes over again.
            settings.applyConfig(.init(fontSize: 13))
            settings.textSizeChoice = .large
            let restarted = VerticalTabsSettings(defaults: defaults)
            restarted.applyConfig(.init(fontSize: 13))
            #expect(restarted.textSizeChoice == .large)
            #expect(restarted.fontSize == 16)
            let changed = VerticalTabsSettings(defaults: defaults)
            changed.applyConfig(.init(fontSize: 18))
            #expect(changed.textSizeChoice == nil)
            #expect(changed.fontSize == 18)
            settings.applyConfig(.init())
            settings.textSizeChoice = .medium

            // Config can't be chosen without a configured size.
            settings.textSizeChoice = nil
            #expect(settings.fontSize == 14)
        }
    }

    @Test func overrideClearedAtLaunchWithoutConfiguredSize() {
        withFreshDefaults { defaults in
            let first = VerticalTabsSettings(defaults: defaults)
            first.applyConfig(.init(fontSize: 13))
            first.textSizeChoice = .large

            // Launch with the key removed, then add the same size back.
            let second = VerticalTabsSettings(defaults: defaults)
            second.applyConfig(.init())
            second.applyConfig(.init(fontSize: 13))
            #expect(second.textSizeChoice == nil)
            #expect(second.fontSize == 13)
        }
    }

    @Test func reloadPicksUpTextSizeOverride() {
        withFreshDefaults { defaults in
            let running = VerticalTabsSettings(defaults: defaults)
            running.applyConfig(.init(fontSize: 13))
            #expect(running.textSizeChoice == nil)

            // Another process picks a preset over the same configured size, then clears it.
            let other = VerticalTabsSettings(defaults: defaults)
            other.applyConfig(.init(fontSize: 13))
            other.textSizeChoice = .large
            running.reloadFromDefaults()
            #expect(running.textSizeChoice == .large)
            #expect(running.fontSize == 16)

            other.textSizeChoice = nil
            running.reloadFromDefaults()
            #expect(running.textSizeChoice == nil)
            #expect(running.fontSize == 13)
        }
    }

    @Test func configSecondaryFontSize() {
        withFreshDefaults { defaults in
            let settings = VerticalTabsSettings(defaults: defaults)
            settings.textSize = .small
            #expect(settings.secondaryFontSize == 9)
            settings.applyConfig(.init(fontSize: 20, secondaryFontSize: 10))
            #expect(settings.fontSize == 20)
            #expect(settings.secondaryFontSize == 10)
            settings.applyConfig(.init(secondaryFontSize: 12))
            #expect(settings.fontSize == 12)
            #expect(settings.secondaryFontSize == 12)
        }
    }

    @Test func settingsPersist() {
        withFreshDefaults { defaults in
            let settings = VerticalTabsSettings(defaults: defaults)
            settings.textSize = .large
            settings.density = .tall
            settings.showFolders = false
            settings.showIdleTime = false
            settings.showShortcuts = false
            settings.showIcons = false
            settings.showRecents = false

            let reloaded = VerticalTabsSettings(defaults: defaults)
            #expect(reloaded.textSize == .large)
            #expect(reloaded.density == .tall)
            #expect(!reloaded.showFolders)
            #expect(!reloaded.showIdleTime)
            #expect(!reloaded.showShortcuts)
            #expect(!reloaded.showIcons)
            #expect(!reloaded.showRecents)
        }
    }

    @Test func settingsReloadFromDefaults() {
        withFreshDefaults { defaults in
            let settings = VerticalTabsSettings(defaults: defaults)
            var published = 0
            let cancellable = settings.objectWillChange.sink { published += 1 }
            defer { cancellable.cancel() }

            // Nothing changed: nothing published.
            settings.reloadFromDefaults()
            #expect(published == 0)

            // Another process (ghostty-test-mirror) writes our prefs.
            defaults.set(true, forKey: "VerticalTabsEnabled")
            defaults.set(300.0, forKey: "VerticalTabsWidth")
            defaults.set("tall", forKey: "VerticalTabsDensity")
            defaults.set("large", forKey: "VerticalTabsTextSize")
            defaults.set(false, forKey: "VerticalTabsShowFolders")
            defaults.set(false, forKey: "VerticalTabsShowRecents")
            defaults.set(true, forKey: "VerticalTabsRecentsCollapsed")
            defaults.set(["pin-a", "pin-b"], forKey: "VerticalTabsPins")
            settings.reloadFromDefaults()
            #expect(settings.enabled)
            #expect(settings.width == 300)
            #expect(settings.density == .tall)
            #expect(settings.textSize == .large)
            #expect(!settings.showFolders)
            #expect(settings.showIdleTime)
            #expect(!settings.showRecents)
            #expect(settings.recentsCollapsed)
            #expect(settings.pins.keys == ["pin-a", "pin-b"])

            // Reloading doesn't write back (or mark the new pins seen).
            #expect(defaults.dictionary(forKey: "VerticalTabsPinsSeen") == nil)
            // Later edits still persist.
            settings.width = 200
            #expect(defaults.double(forKey: "VerticalTabsWidth") == 200)
        }
    }

    @Test func folderNames() {
        #expect(VerticalTabs.folderName(forPath: "/Users/p/src/PopLab", home: "/Users/p") == "PopLab")
        #expect(VerticalTabs.folderName(forPath: "/Users/p/bin/", home: "/Users/p") == "bin")
        #expect(VerticalTabs.folderName(forPath: "/Users/p", home: "/Users/p") == "~")
        #expect(VerticalTabs.folderName(forPath: "file:///Users/p/src/ghostty", home: "/Users/p") == "ghostty")
        #expect(VerticalTabs.folderName(forPath: nil) == nil)
        #expect(VerticalTabs.folderName(forPath: "") == nil)
    }

    @Test func hueIsDeterministicAndInRange() {
        let hue = VerticalTabs.hue(for: "PopLab")
        #expect(hue == VerticalTabs.hue(for: "PopLab"))
        #expect(hue >= 0 && hue < 1)
        #expect(hue != VerticalTabs.hue(for: "ghostty"))
    }

    @Test func ageText() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(VerticalTabs.ageText(since: nil, now: now) == nil)
        #expect(VerticalTabs.ageText(since: now.addingTimeInterval(-30), now: now) == "now")
        #expect(VerticalTabs.ageText(since: now.addingTimeInterval(-150), now: now) == "2m")
        #expect(VerticalTabs.ageText(since: now.addingTimeInterval(-3 * 3600 - 5), now: now) == "3h")
        #expect(VerticalTabs.ageText(since: now.addingTimeInterval(-2 * 86_400), now: now) == "2d")
    }

    // MARK: Pins

    @Test func pinAppendsToEndAndUnpinRemoves() {
        let tabs = (0..<4).map { tab($0) }
        var pins = VerticalTabs.Pins()
        pins.pin(tabs[2], among: tabs)
        pins.pin(tabs[0], among: tabs)
        #expect(pins.keys == ["s2", "s0"])

        // Pinning twice is a no-op.
        pins.pin(tabs[2], among: tabs)
        #expect(pins.keys == ["s2", "s0"])

        pins.toggle(tabs[2], among: tabs)
        #expect(pins.keys == ["s0"])
        #expect(!pins.isPinned(tabs[2], among: tabs))
        #expect(pins.isPinned(tabs[0], among: tabs))
    }

    @Test func pinnedReorderKeepsHiddenPinsInPlace() {
        let tabs = (0..<3).map { tab($0) }
        // "gone" belongs to a tab in another window or not yet restored.
        var pins = VerticalTabs.Pins(keys: ["s0", "gone", "s1", "s2"])
        let visible = VerticalTabs.sections(tabs: tabs, pins: pins.keys).pinned
        pins.move(visible: visible, among: tabs, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(pins.keys == ["s2", "gone", "s0", "s1"])
    }

    @Test func pinFollowsItsTabWhenASplitMovesToANewTab() {
        // Tab 0 has surfaces A and B and is pinned by A. A then moves to a new tab 1.
        var old = tab(0, surfaces: ["B"])
        old.claimedPinKey = "A"
        let moved = tab(1, surfaces: ["A"])
        let matches = VerticalTabs.pinMatches(tabs: [old, moved], pins: ["A"])
        #expect(matches.map(\.tab) == [id(0)])

        var pins = VerticalTabs.Pins(keys: ["A"])
        pins.rekey(old: "A", new: "B")
        #expect(pins.keys == ["B"])
        #expect(VerticalTabs.sections(tabs: [old, moved], pins: pins.keys).pinned.map(\.id) == [id(0)])
    }

    @Test func pinMatchesAnySurfaceAfterRestore() {
        let restored = tab(0, surfaces: ["B", "A"])
        #expect(VerticalTabs.sections(tabs: [restored], pins: ["A"]).pinned.map(\.id) == [id(0)])
    }

    // MARK: Sections

    @Test func sectionsNeverDuplicateTabs() {
        let tabs = [
            tab(0, left: 50),
            tab(1, left: 90),
            tab(2, selected: true, left: 100),
            tab(3, left: 80),
            tab(4),
            tab(5, left: 70),
            tab(6, left: 60),
            tab(7, left: 10),
        ]
        let sections = VerticalTabs.sections(tabs: tabs, pins: ["s1", "s7"], recentsLimit: 3)

        #expect(ids(sections.pinned) == [id(1), id(7)])
        // Most recently left first, skipping pinned; the selected tab keeps its place.
        #expect(ids(sections.recents) == [id(2), id(3), id(5)])
        #expect(ids(sections.open) == [id(0), id(4), id(6)])

        let all = ids(sections.pinned + sections.recents + sections.open)
        #expect(all.count == tabs.count)
        #expect(Set(all).count == tabs.count)
    }

    @Test func collapsedRecentsKeepTabsInOpen() {
        let tabs = [
            tab(0, left: 10),
            tab(1, selected: true, left: 20),
            tab(2, left: 30),
            tab(3),
        ]
        let collapsed = VerticalTabs.sections(tabs: tabs, pins: ["s3"], recentsLimit: 0)
        #expect(collapsed.recents.isEmpty)
        #expect(ids(collapsed.open) == [id(0), id(1), id(2)])
        #expect(ids(collapsed.numbered) == [id(3), id(0), id(1), id(2)])
        // The collapsed header stays available because there are recent tabs.
        #expect(VerticalTabs.hasRecentCandidates(tabs: tabs, pins: ["s3"]))
        #expect(!VerticalTabs.hasRecentCandidates(tabs: [tab(0, selected: true)], pins: []))
    }

    @Test func previousAndNextFollowSidebarOrder() {
        // Pinned [3], Recents [1, 2], Open [0, 4]; tab 2 (a Recent) is selected.
        let tabs = [tab(0), tab(1, left: 30), tab(2, selected: true, left: 20), tab(3), tab(4)]
        let sections = VerticalTabs.sections(tabs: tabs, pins: ["s3"], recentsLimit: 3, keepInRecents: [id(2)])
        #expect(ids(sections.visual) == [id(3), id(1), id(2), id(0), id(4)])
        #expect(sections.tab(for: .next)?.id == id(0))
        #expect(sections.tab(for: .previous)?.id == id(1))

        func step(_ selected: Int, _ shortcut: VerticalTabs.Shortcut) -> ObjectIdentifier? {
            var copy = sections
            for keyPath in [\VerticalTabs.Sections.pinned, \.recents, \.open] {
                copy[keyPath: keyPath] = copy[keyPath: keyPath].map { tab in
                    var tab = tab
                    tab.isSelected = tab.id == id(selected)
                    return tab
                }
            }
            return copy.tab(for: shortcut)?.id
        }
        // Pinned → Recents and Recents → Open, both ways, wrapping at the ends.
        #expect(step(3, .next) == id(1))
        #expect(step(1, .previous) == id(3))
        #expect(step(4, .next) == id(3))
        #expect(step(3, .previous) == id(4))
        // Nothing selected: the first row.
        #expect(step(11, .next) == id(3))
        // Numbers still skip Recents.
        #expect(sections.tab(for: .number(2))?.id == id(0))
        #expect(sections.tab(for: .last)?.id == id(4))
    }

    @Test func previousAndNextWithRecentsCollapsedOrHidden() {
        // Collapsed and hidden Recents both build sections with no Recents rows.
        let tabs = [tab(0, left: 10), tab(1, selected: true, left: 20), tab(2, left: 30), tab(3)]
        let sections = VerticalTabs.sections(tabs: tabs, pins: ["s3"], recentsLimit: 0)
        #expect(sections.recents.isEmpty)
        #expect(ids(sections.visual) == ids(sections.numbered))
        #expect(ids(sections.visual) == [id(3), id(0), id(1), id(2)])
        #expect(sections.tab(for: .next)?.id == id(2))
        #expect(sections.tab(for: .previous)?.id == id(0))
        #expect(VerticalTabs.Sections().tab(for: .next) == nil)
    }

    @Test func selectingStaysInSection() {
        // Tab 1 was selected from Recents, tab 2 from Open (never left).
        let fromRecents = [tab(0, left: 30), tab(1, selected: true, left: 20), tab(2)]
        let a = VerticalTabs.sections(tabs: fromRecents, pins: [])
        #expect(ids(a.recents) == [id(0), id(1)])
        #expect(ids(a.open) == [id(2)])

        let fromOpen = [tab(0, left: 30), tab(1, left: 20), tab(2, selected: true)]
        let b = VerticalTabs.sections(tabs: fromOpen, pins: [])
        #expect(ids(b.recents) == [id(0), id(1)])
        #expect(ids(b.open) == [id(2)])
    }

    @Test func oldestRecentSelectedFromOpenStaysInRecents() {
        // Recents 1–4 full; Open tab 0 is selected, then the 4th Recent is clicked,
        // which stamps tab 0 as just left.
        let tabs = [
            tab(0, left: 100),
            tab(1, left: 40), tab(2, left: 30), tab(3, left: 20),
            tab(4, selected: true, left: 10),
            tab(5),
        ]
        let without = VerticalTabs.sections(tabs: tabs, pins: [])
        #expect(ids(without.recents) == [id(0), id(1), id(2), id(3)])

        let kept = VerticalTabs.sections(tabs: tabs, pins: [], keepInRecents: [id(4)])
        #expect(ids(kept.recents) == [id(0), id(1), id(2), id(4)])
        #expect(ids(kept.open) == [id(3), id(5)])
        // Already within the limit: no change; ineligible (never left): ignored.
        #expect(VerticalTabs.sections(tabs: tabs, pins: [], keepInRecents: [id(1)]) == without)
        #expect(VerticalTabs.sections(tabs: tabs, pins: [], keepInRecents: [id(5)]) == without)
        #expect(VerticalTabs.sections(tabs: tabs, pins: [], recentsLimit: 0, keepInRecents: [id(4)]).recents.isEmpty)
    }

    @Test func walkKeepsEveryRecentItPassedThrough() {
        // Recents [0, 1, 2, 3] are full; 4 and 5 were Recents older than all of
        // them, kept because a quick walk selected them from Recents.
        let tabs = [
            tab(0, left: 100), tab(1, left: 90), tab(2, left: 80), tab(3, left: 70),
            tab(4, left: 20), tab(5, selected: true, left: 10), tab(6),
        ]
        let walk = VerticalTabs.sections(tabs: tabs, pins: [], keepInRecents: [id(4), id(5)])
        // The oldest others yield; Recents stays in recency order.
        #expect(ids(walk.recents) == [id(0), id(1), id(4), id(5)])
        #expect(ids(walk.open) == [id(2), id(3), id(6)])
        // Without the walk's earlier tab, it drops back to Open: the bounce this prevents.
        let single = VerticalTabs.sections(tabs: tabs, pins: [], keepInRecents: [id(5)])
        #expect(ids(single.recents) == [id(0), id(1), id(2), id(5)])
    }

    // MARK: Walking Recents

    /// Mirrors `VerticalTabsManager.windowDidBecomeMain` and `settleWalk` on a
    /// fake group, so successive switches (not one snapshot) can be checked.
    private struct Group {
        let ids: [ObjectIdentifier]
        let dwell: TimeInterval = 1
        var now = Date(timeIntervalSince1970: 1000)
        var lastLeft: [Int: Date]
        var lastEntered: [Int: Date] = [:]
        var selected: Int
        var kept: Set<ObjectIdentifier> = []
        var settleGeneration = 0
        var pendingSettle: (tab: Int, entered: Date, generation: Int)?

        init(ids: [ObjectIdentifier], selected: Int) {
            self.ids = ids
            self.selected = selected
            let at = { Date(timeIntervalSince1970: $0) }
            lastLeft = [r1: at(400), r2: at(300), r3: at(200), r4: at(100)]
            // No `lastEntered` for the start tab: it has dwelled.
            if sections.recents.contains(where: { $0.id == ids[selected] }) { kept = [ids[selected]] }
        }

        var sections: VerticalTabs.Sections {
            let tabs = ids.indices.map { index in
                VerticalTabs.Tab(
                    id: ids[index], surfaceIDs: ["s\(index)"], title: "\(index)",
                    isSelected: index == selected, lastLeft: lastLeft[index])
            }
            return VerticalTabs.sections(tabs: tabs, pins: ["s0", "s1"], keepInRecents: kept)
        }

        mutating func wait(_ seconds: TimeInterval) {
            now += seconds
            guard let pending = pendingSettle, now.timeIntervalSince(pending.entered) >= dwell else { return }
            pendingSettle = nil
            guard pending.tab == selected, pending.generation == settleGeneration,
                  lastEntered[selected] == pending.entered else { return }
            kept = kept.contains(ids[selected]) ? [ids[selected]] : []
        }

        mutating func select(_ index: Int, directional: Bool) {
            let dwelled = lastEntered[selected].map { now.timeIntervalSince($0) >= dwell } ?? true
            let leaving: VerticalTabs.Leaving = index == selected ? .same : .tab(dwelled: dwelled)
            let update = VerticalTabs.recentsUpdate(
                selecting: ids[index], leaving: leaving, directional: directional,
                sections: sections, kept: kept)
            if update.stampLeft { lastLeft[selected] = now }
            if leaving != .same { lastEntered[index] = now }
            selected = index
            kept = update.kept
            if directional { settleGeneration += 1 }
            if update.settle { pendingSettle = (index, now, settleGeneration) }
        }

        /// One `previous_tab`/`next_tab`; returns the tab it selected.
        mutating func step(_ shortcut: VerticalTabs.Shortcut, directional: Bool = true) -> Int {
            let target = ids.firstIndex(of: sections.tab(for: shortcut)!.id)!
            select(target, directional: directional)
            return target
        }

        /// `count` steps `pause` apart.
        mutating func walk(_ shortcut: VerticalTabs.Shortcut, _ count: Int, pause: TimeInterval,
                           directional: Bool = true) -> [Int] {
            (0..<count).map { _ in
                wait(pause)
                return step(shortcut, directional: directional)
            }
        }
    }

    private func group(selected: Int) -> Group { Group(ids: (0..<9).map(id), selected: selected) }

    @Test(arguments: [0.2, 1.2])
    func previousWalkFromFirstOpenVisitsEveryRow(pause: TimeInterval) {
        var g = group(selected: o1)
        let before = g.sections
        #expect(ids(before.visual) == [p1, p2, r1, r2, r3, r4, o1, o2, o3].map(id))
        let walk = g.walk(.previous, 9, pause: pause)
        // No skipped R3, no early return to O1; a full lap ends where it began.
        #expect(walk == [r4, r3, r2, r1, p2, p1, o3, o2, o1])
        g.wait(pause)
        #expect(ids(g.sections.visual) == ids(before.visual))
    }

    @Test(arguments: [0.2, 1.2])
    func previousWalkFromMiddleRecentLeavesRecents(pause: TimeInterval) {
        var g = group(selected: r2)
        let walk = g.walk(.previous, 9, pause: pause)
        // No R1 ↔ R2 bounce.
        #expect(walk == [r1, p2, p1, o3, o2, o1, r4, r3, r2])
    }

    @Test(arguments: [0.2, 1.2])
    func nextWalkVisitsEveryRow(pause: TimeInterval) {
        var g = group(selected: o1)
        #expect(g.walk(.next, 9, pause: pause) == [o2, o3, p1, p2, r1, r2, r3, r4, o1])
        var h = group(selected: r2)
        #expect(h.walk(.next, 9, pause: pause) == [r3, r4, o1, o2, o3, p1, p2, r1, r2])
    }

    @Test func walkWithoutDirectionalMarkingSkipsRows() {
        // What the walk did before it was marked directional: O1 promotes and R3 drops out.
        var g = group(selected: o1)
        #expect(g.walk(.previous, 3, pause: 1.2, directional: false) == [r4, r2, r1])
    }

    @Test func slowWalkAfterQuickClicksHoldsRows() {
        // Quick clicks O1 → R4 → R3 keep both and leave a settle pending.
        var g = group(selected: o1)
        g.lastEntered[o1] = g.now
        g.select(r4, directional: false)
        g.wait(0.2)
        g.select(r3, directional: false)
        #expect(g.pendingSettle != nil)
        #expect(g.kept == [id(r4), id(r3)])
        let rows = ids(g.sections.visual)
        // Walking on within the dwell, then slowly: nothing settles or reorders.
        g.wait(0.2)
        #expect(g.step(.previous) == r2)
        #expect(g.walk(.previous, 8, pause: 1.5) == [r1, p2, p1, o3, o2, o1, r4, r3])
        g.wait(2)
        #expect(g.kept == [id(r4), id(r3)])
        #expect(ids(g.sections.visual) == rows)
    }

    @Test func sameWindowBecomingMainKeepsKeptRecents() {
        var g = group(selected: o1)
        g.kept = [id(r3), id(r4)]
        let entered = g.lastEntered[o1]
        g.select(o1, directional: false)
        #expect(g.kept == [id(r3), id(r4)])
        #expect(g.lastEntered[o1] == entered)
        #expect(g.lastLeft[o1] == nil)
    }

    @Test func clickAfterDwellStillPromotes() {
        var g = group(selected: o1)
        g.wait(1.2)
        g.select(o2, directional: false)
        // O1 becomes the newest Recent; the oldest, R4, returns to Open.
        #expect(ids(g.sections.recents) == [o1, r1, r2, r3].map(id))
        #expect(ids(g.sections.open) == [o2, r4, o3].map(id))

        // A tab reached by a walk and used, then left by a click, is promoted too.
        var h = group(selected: o1)
        _ = h.walk(.previous, 2, pause: 0.2)
        #expect(h.selected == r3)
        h.wait(1.2)
        h.select(o2, directional: false)
        #expect(ids(h.sections.recents).first == id(r3))
        // A quick click promotes nothing.
        var q = group(selected: o1)
        _ = q.step(.previous)
        q.wait(0.2)
        q.select(o3, directional: false)
        #expect(ids(q.sections.recents) == [r1, r2, r3, r4].map(id))
    }

    @Test func pinnedFollowPinOrderNotTabOrder() {
        let tabs = (0..<3).map { tab($0) }
        let sections = VerticalTabs.sections(tabs: tabs, pins: ["s2", "s0"])
        #expect(ids(sections.pinned) == [id(2), id(0)])
    }

    @Test func shortcutsSkipRecents() {
        let tabs = [
            tab(0),
            tab(1, left: 10),
            tab(2, selected: true),
            tab(3),
            tab(4),
        ]
        let sections = VerticalTabs.sections(tabs: tabs, pins: ["s4"], recentsLimit: 3)
        #expect(ids(sections.recents) == [id(1)])

        #expect(sections.tab(for: .number(1))?.id == id(4))
        #expect(sections.tab(for: .number(2))?.id == id(0))
        #expect(sections.tab(for: .number(3))?.id == id(2))
        #expect(sections.tab(for: .number(4))?.id == id(3))
        // Past the end selects the last numbered tab.
        #expect(sections.tab(for: .number(9))?.id == id(3))
        #expect(sections.tab(for: .number(0)) == nil)

        #expect(sections.shortcutNumber(for: id(4)) == 1)
        #expect(sections.shortcutNumber(for: id(1)) == nil)
        #expect(sections.shortcutNumber(for: id(3)) == 4)
    }

    @Test func shortcutsMatchGhosttyDefaultsWithCmd9AsLastTab() {
        // Ghostty binds Cmd+1..8 to goto_tab:1..8 and Cmd+9 to last_tab.
        let tabs = (0..<12).map { tab($0) }
        let sections = VerticalTabs.sections(tabs: tabs, pins: ["s11"])
        // numbered: 11, 0, 1, ..., 10
        #expect(sections.shortcutNumber(for: id(11)) == 1)
        #expect(sections.shortcutNumber(for: id(6)) == 8)
        #expect(sections.shortcutNumber(for: id(7)) == nil)
        #expect(sections.shortcutNumber(for: id(10)) == 9)
        #expect(sections.tab(for: .last)?.id == id(10))
        #expect(sections.tab(for: .number(8))?.id == id(6))

        // With exactly nine rows, the ninth row is both goto_tab:9 and last_tab.
        let nine = VerticalTabs.sections(tabs: Array(tabs.prefix(9)), pins: [])
        #expect(nine.shortcutNumber(for: id(8)) == 9)
        #expect(nine.tab(for: .last)?.id == id(8))

        // Fewer than nine: no 9 label, last_tab still picks the last row.
        let three = VerticalTabs.sections(tabs: Array(tabs.prefix(3)), pins: [])
        #expect(three.shortcutNumber(for: id(2)) == 3)
        #expect(three.tab(for: .last)?.id == id(2))
    }

    @Test func pinnedFirstOrderRepairsDriftedNativeOrder() {
        // A new tab opened next to pinned P1 lands between the pinned tabs.
        let p1 = tab(0), new = tab(1), p2 = tab(2), open = tab(3)
        let drifted = [p1, new, p2, open]
        #expect(VerticalTabs.pinnedFirstOrder(tabs: drifted, pins: ["s0", "s2"]) == [id(0), id(2), id(1), id(3)])

        // Already pinned-first (in pin order): nothing to do.
        #expect(VerticalTabs.pinnedFirstOrder(tabs: [p1, p2, new, open], pins: ["s0", "s2"]) == nil)
        #expect(VerticalTabs.pinnedFirstOrder(tabs: drifted, pins: []) == nil)

        // Pin order wins over native order among pinned tabs.
        #expect(VerticalTabs.pinnedFirstOrder(tabs: [p1, p2, new], pins: ["s2", "s0"]) == [id(2), id(0), id(1)])
    }

    @Test func groupOrderPutsPinnedFirst() {
        let tabs = (0..<5).map { tab($0) }
        let order = VerticalTabs.groupOrder(tabs: tabs, pins: ["s3", "s1"])
        #expect(order == [id(3), id(1), id(0), id(2), id(4)])
    }

    @Test func movingASubsetKeepsOtherSlots() {
        let order = ["p", "a", "r", "b", "c"]
        let moved = VerticalTabs.move(["a", "b", "c"], in: order, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(moved == ["p", "c", "r", "a", "b"])
    }

    // MARK: Filter

    @Test func filterMatchesTitleAndFolder() {
        let tabs = [
            tab(0, title: "Reviewing Claude Audio Detection Proposal", folder: "PopLab"),
            tab(1, title: "zsh", folder: "ghostty"),
            tab(2, title: "Deploy notes", folder: "bin"),
        ]
        let sections = VerticalTabs.sections(tabs: tabs, pins: [])

        #expect(ids(VerticalTabs.filtered(sections, filter: "audio")) == [id(0)])
        #expect(ids(VerticalTabs.filtered(sections, filter: "GHOST")) == [id(1)])
        #expect(ids(VerticalTabs.filtered(sections, filter: "poplab review")) == [id(0)])
        #expect(VerticalTabs.filtered(sections, filter: "nomatch").isEmpty)
        #expect(VerticalTabs.filtered(sections, filter: "  ").count == 3)
    }

    @Test func substringMatchesRankAheadOfFuzzy() {
        let tabs = [
            tab(0, title: "build and test", folder: "x"),  // fuzzy "bat"
            tab(1, title: "combat log", folder: "y"),      // substring "bat"
        ]
        let sections = VerticalTabs.sections(tabs: tabs, pins: [])
        #expect(ids(VerticalTabs.filtered(sections, filter: "bat")) == [id(1), id(0)])
    }
}
