import AppKit
import Foundation
import Testing
@testable import Ghostty

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
        let data = Data(#"{"pid":17346,"cwd":"/Users/p/src/PopLab","sessionId":"ebc60ada-ff4b","agyPid":17347,"client":17179,"clients":[17180]}"#.utf8)
        let session = try #require(VerticalTabs.agHostSession(json: data, bridgeName: noBridge))
        #expect(session.pids == [17179, 17180, 17347, 17346])
        #expect(session.peerId == "agy-poplab-ebc6")
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
            #expect(settings.textSize == .small)
            #expect(settings.textSize.pointSize == 11)
            #expect(settings.showFolders)
            #expect(settings.showIdleTime)
            #expect(settings.showShortcuts)
            #expect(settings.showIcons)
            #expect(settings.showRecents)
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
