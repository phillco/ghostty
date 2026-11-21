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
        focused: TimeInterval? = nil,
        surfaces: [String]? = nil
    ) -> VerticalTabs.Tab {
        VerticalTabs.Tab(
            id: ObjectIdentifier(tokens[index]),
            surfaceIDs: surfaces ?? ["s\(index)"],
            title: title.isEmpty ? "tab \(index)" : title,
            folder: folder,
            isSelected: selected,
            lastFocused: focused.map { Date(timeIntervalSince1970: $0) }
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
    ])
    func parsesTitles(raw: String, text: String, platform: VerticalTabs.Platform) {
        let parsed = VerticalTabs.parseTitle(raw)
        #expect(parsed.text == text)
        #expect(parsed.platform == platform)
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
            tab(0, focused: 50),
            tab(1, focused: 90),
            tab(2, selected: true, focused: 100),
            tab(3, focused: 80),
            tab(4),
            tab(5, focused: 70),
            tab(6, focused: 60),
            tab(7, focused: 10),
        ]
        let sections = VerticalTabs.sections(tabs: tabs, pins: ["s1", "s7"], recentsLimit: 3)

        #expect(ids(sections.pinned) == [id(1), id(7)])
        // Most recent first, skipping pinned and the selected tab.
        #expect(ids(sections.recents) == [id(3), id(5), id(6)])
        #expect(ids(sections.open) == [id(0), id(2), id(4)])

        let all = ids(sections.pinned + sections.recents + sections.open)
        #expect(all.count == tabs.count)
        #expect(Set(all).count == tabs.count)
    }

    @Test func collapsedRecentsKeepTabsInOpen() {
        let tabs = [
            tab(0, focused: 10),
            tab(1, selected: true, focused: 20),
            tab(2, focused: 30),
            tab(3),
        ]
        let collapsed = VerticalTabs.sections(tabs: tabs, pins: ["s3"], recentsLimit: 0)
        #expect(collapsed.recents.isEmpty)
        #expect(ids(collapsed.open) == [id(0), id(1), id(2)])
        #expect(ids(collapsed.numbered) == [id(3), id(0), id(1), id(2)])
        // The collapsed header stays available because there are recent tabs.
        #expect(VerticalTabs.hasRecentCandidates(tabs: tabs, pins: ["s3"]))
        #expect(!VerticalTabs.hasRecentCandidates(tabs: [tab(0, selected: true, focused: 5)], pins: []))
    }

    @Test func pinnedFollowPinOrderNotTabOrder() {
        let tabs = (0..<3).map { tab($0) }
        let sections = VerticalTabs.sections(tabs: tabs, pins: ["s2", "s0"])
        #expect(ids(sections.pinned) == [id(2), id(0)])
    }

    @Test func shortcutsSkipRecents() {
        let tabs = [
            tab(0),
            tab(1, focused: 10),
            tab(2, selected: true, focused: 20),
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
