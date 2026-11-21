import Foundation

/// Pure, AppKit-free logic behind the vertical tab sidebar. Everything here is
/// unit tested; the AppKit glue lives in `VerticalTabsManager`.
enum VerticalTabs {
    /// The default number of rows in Recents (`vertical-tabs-recents-limit`).
    static let recentsLimit = 4

    /// Which agent produced a title, detected from its leading glyph.
    enum Platform: Equatable {
        case agy      // ✦ and the other `ag` title glyphs
        case claude   // ✳
        case terminal
    }

    /// A tab title with spinner and agent glyph prefixes removed.
    struct ParsedTitle: Equatable {
        let text: String
        /// `nil` when only an ambiguous spinner glyph was present.
        let platform: Platform?
    }

    /// Leading glyphs only `ag` puts in titles: its preset idle glyphs and
    /// spinner frames (`~/bin/go/ag/config.go` `titlePresets`), minus the moon
    /// frames, which Claude Code also uses.
    static let agyGlyphs: Set<Unicode.Scalar> = [
        "✦", "✧", "◜", "◝", "◞", "◟", "◠", "◡",
        "◴", "◷", "◶", "◵", "◉", "◌", "◎", "◈", "◇", "◆", "◢", "◣", "◤", "◥",
    ]

    /// Spinner frames both `ag` (moon preset) and Claude Code use.
    static let ambiguousSpinnerGlyphs: Set<Unicode.Scalar> = ["◐", "◑", "◒", "◓"]

    /// Strips leading whitespace, spinner characters, Ghostty's bell prefix and
    /// a leading agent glyph from a tab title.
    ///
    /// The platform is `nil` for an ambiguous moon spinner (`◐◑◒◓`); see
    /// `resolvePlatform`. Claude Code shows `✳` when idle and a Braille spinner
    /// while busy, so a non-blank Braille prefix without an `ag` glyph is Claude.
    static func parseTitle(_ raw: String) -> ParsedTitle {
        var scalars = Substring(raw).unicodeScalars[...]
        var platform: Platform? = .terminal
        var sawBraille = false

        func dropNoise() {
            while let first = scalars.first {
                if (0x2801...0x28FF).contains(first.value) {
                    sawBraille = true
                    scalars.removeFirst()
                } else if first.properties.isWhitespace || first == "\u{2800}" ||
                    first == "\u{FE0F}" || first == "🔔" {
                    scalars.removeFirst()
                } else {
                    break
                }
            }
        }

        dropNoise()
        if let first = scalars.first {
            if agyGlyphs.contains(first) {
                platform = .agy
                scalars.removeFirst()
            } else if first == "✳" {
                platform = .claude
                scalars.removeFirst()
            } else if ambiguousSpinnerGlyphs.contains(first) {
                platform = nil
                scalars.removeFirst()
            }
        }
        dropNoise()
        if platform != .agy, platform != .claude, sawBraille { platform = .claude }

        let text = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(text: text, platform: platform)
    }

    /// The platform to show for a parsed title, and the agent platform to
    /// remember for the next title. An ambiguous spinner keeps the remembered
    /// platform (Claude if none), so busy tabs don't flip icons; a plain title
    /// (back at the shell) forgets it.
    static func resolvePlatform(
        _ parsed: Platform?, last: Platform?
    ) -> (shown: Platform, last: Platform?) {
        switch parsed {
        case nil: return (last ?? .claude, last)
        case .terminal?: return (.terminal, nil)
        case let platform?: return (platform, platform)
        }
    }

    /// A folder name shortened for its pill, so long repo names don't starve the title.
    /// `maxChars` 0 means no character limit.
    static func pillText(_ folder: String, maxChars: Int = 12) -> String {
        guard maxChars > 0, folder.count > maxChars else { return folder }
        return String(folder.prefix(maxChars - 1)) + "…"
    }

    /// The short folder name shown in a row's pill: the last path component,
    /// or `~` for the home directory.
    static func folderName(forPath path: String?, home: String = NSHomeDirectory()) -> String? {
        guard var path, !path.isEmpty else { return nil }
        if let url = URL(string: path), url.scheme == "file" { path = url.path }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == home { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// A deterministic hue in 0..<1 for a folder name (FNV-1a; Swift's
    /// `hashValue` is randomized per launch).
    static func hue(for folder: String) -> Double {
        var hash: UInt32 = 2_166_136_261
        for byte in folder.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Double(hash % 360) / 360
    }

    /// Compact relative age: `now` under a minute, then `2m`, `3h`, `4d`.
    static func ageText(since date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }

    // MARK: Tabs and sections

    /// A snapshot of one tab, in tab group order.
    struct Tab: Equatable, Identifiable {
        /// Session-local identity (the window).
        let id: ObjectIdentifier
        /// Surface UUIDs in this tab. A pin matches a tab when its key is one of these.
        var surfaceIDs: [String]
        var title: String
        var folder: String?
        var platform: Platform = .terminal
        var bell: Bool = false
        var isSelected: Bool = false
        /// When another tab in the group was last selected over this one.
        var lastLeft: Date?
        /// Last focus or title change; drives the idle age.
        var lastActive: Date?
        /// The pin key this tab matched last time, if any. A claimed key keeps
        /// matching this tab even after its surface moves to another tab (split
        /// promoted to a new tab); the manager then re-keys the pin.
        var claimedPinKey: String?

        /// The key a new pin for this tab is stored under.
        var pinKey: String? { surfaceIDs.first }
    }

    /// A goto_tab target: `goto_tab:N`, `last_tab`, `previous_tab` or `next_tab`.
    enum Shortcut: Equatable {
        case number(Int)
        case last
        case previous
        case next
    }

    struct Sections: Equatable {
        var pinned: [Tab] = []
        var recents: [Tab] = []
        var open: [Tab] = []

        /// The rows `Cmd+1..9` address: Pinned then Open, skipping Recents.
        var numbered: [Tab] { pinned + open }

        /// Every row in sidebar order; previous/next tab step through it.
        var visual: [Tab] { pinned + recents + open }

        /// The shortcut label for a tab, following Ghostty's default bindings:
        /// `Cmd+1..8` are `goto_tab:1..8` and `Cmd+9` is `last_tab`. So the first
        /// eight numbered rows show 1–8, and the last numbered row shows 9 once
        /// there are at least nine.
        func shortcutNumber(for id: ObjectIdentifier) -> Int? {
            let list = numbered
            guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
            if index < 8 { return index + 1 }
            if index == list.count - 1 { return 9 }
            return nil
        }

        /// The tab a goto_tab shortcut selects. Numbers past the end pick the last
        /// numbered tab, matching Ghostty's horizontal behavior. Previous/next
        /// wrap around the sidebar's visual order.
        func tab(for shortcut: Shortcut) -> Tab? {
            switch shortcut {
            case .last:
                return numbered.last
            case .number(let n):
                let list = numbered
                guard n >= 1, !list.isEmpty else { return nil }
                return list[min(n - 1, list.count - 1)]
            case .previous, .next:
                let list = visual
                guard let index = list.firstIndex(where: \.isSelected) else { return list.first }
                let step = shortcut == .next ? 1 : -1
                return list[(index + step + list.count) % list.count]
            }
        }
    }

    /// Splits tabs into Pinned / Recents / Open so no tab appears twice.
    ///
    /// - Pinned follows `pins` order.
    /// - Recents are the unpinned tabs most recently switched away from. Ranking
    ///   by when a tab was left, not focused, keeps a tab selected from Recents
    ///   in Recents and one selected from Open in Open.
    /// - Open keeps tab group order for everything else.
    /// - `keepInRecents`: tabs selected from Recents (during one previous/next
    ///   walk, several) stay there even when tabs just left push them past
    ///   `recentsLimit`; the oldest other Recents yield.
    static func sections(
        tabs: [Tab], pins: [String], recentsLimit: Int = recentsLimit, keepInRecents: Set<ObjectIdentifier> = []
    ) -> Sections {
        var result = Sections()
        var used = Set<ObjectIdentifier>()

        for match in pinMatches(tabs: tabs, pins: pins) {
            guard let tab = tabs.first(where: { $0.id == match.tab }) else { continue }
            result.pinned.append(tab)
            used.insert(tab.id)
        }

        if recentsLimit > 0 {
            let eligible = tabs
                .filter { !used.contains($0.id) && $0.lastLeft != nil }
                .sorted { $0.lastLeft! > $1.lastLeft! }
            var recents = Array(eligible.prefix(recentsLimit))
            // Past the limit means Recents is full and `kept` is older than all of it.
            for kept in eligible where keepInRecents.contains(kept.id) && !recents.contains(where: { $0.id == kept.id }) {
                guard let slot = recents.lastIndex(where: { !keepInRecents.contains($0.id) }) else { break }
                recents[slot] = kept
            }
            result.recents = recents.sorted { $0.lastLeft! > $1.lastLeft! }
            used.formUnion(result.recents.map(\.id))
        }

        result.open = tabs.filter { !used.contains($0.id) }
        return result
    }

    /// Matches pin keys to tabs, in pin order. A tab that claimed a key wins over
    /// a tab that merely contains that surface; each tab matches at most one pin.
    static func pinMatches(tabs: [Tab], pins: [String]) -> [(key: String, tab: ObjectIdentifier)] {
        var used = Set<ObjectIdentifier>()
        var result: [(key: String, tab: ObjectIdentifier)] = []
        for key in pins {
            let claimed = tabs.first { $0.claimedPinKey == key }
            let containing = tabs.first {
                ($0.claimedPinKey == nil || !pins.contains($0.claimedPinKey!)) && $0.surfaceIDs.contains(key)
            }
            guard let tab = claimed ?? containing, !used.contains(tab.id) else { continue }
            used.insert(tab.id)
            result.append((key, tab.id))
        }
        return result
    }

    /// Whether any tab could appear in Recents. With Recents collapsed, `sections`
    /// is called with `recentsLimit: 0` so those tabs stay visible in Open, and
    /// this keeps the collapsed header available for re-expanding.
    static func hasRecentCandidates(tabs: [Tab], pins: [String]) -> Bool {
        !sections(tabs: tabs, pins: pins, recentsLimit: 1).recents.isEmpty
    }

    /// The tab group order that matches the sidebar: Pinned first, then every
    /// other tab in its existing relative order.
    static func groupOrder(tabs: [Tab], pins: [String]) -> [ObjectIdentifier] {
        let pinned = sections(tabs: tabs, pins: pins, recentsLimit: 0).pinned.map(\.id)
        let pinnedSet = Set(pinned)
        return pinned + tabs.map(\.id).filter { !pinnedSet.contains($0) }
    }

    /// The tab group order to restore when the native order no longer puts
    /// pinned tabs first (a new tab opened next to a pinned one, a merge, a
    /// restore), or nil when it already matches.
    static func pinnedFirstOrder(tabs: [Tab], pins: [String]) -> [ObjectIdentifier]? {
        let order = groupOrder(tabs: tabs, pins: pins)
        return order == tabs.map(\.id) ? nil : order
    }

    // MARK: Pins

    /// Ordered, persisted pin keys (surface UUIDs).
    struct Pins: Equatable, Codable {
        var keys: [String] = []

        /// The pin key that belongs to `tab`, considering every visible tab.
        func key(for tab: Tab, among tabs: [Tab]) -> String? {
            VerticalTabs.pinMatches(tabs: tabs, pins: keys).first { $0.tab == tab.id }?.key
        }

        func isPinned(_ tab: Tab, among tabs: [Tab]) -> Bool {
            key(for: tab, among: tabs) != nil
        }

        /// Pins append to the end of the Pinned list.
        mutating func pin(_ tab: Tab, among tabs: [Tab]) {
            guard !isPinned(tab, among: tabs), let key = tab.pinKey else { return }
            keys.removeAll { $0 == key }
            keys.append(key)
        }

        mutating func unpin(_ tab: Tab, among tabs: [Tab]) {
            guard let key = key(for: tab, among: tabs) else { return }
            keys.removeAll { $0 == key }
        }

        mutating func toggle(_ tab: Tab, among tabs: [Tab]) {
            if isPinned(tab, among: tabs) { unpin(tab, among: tabs) } else { pin(tab, among: tabs) }
        }

        /// Moves pinned rows using `onMove` offsets over the visible pinned list.
        /// Pins for tabs that aren't visible (other windows, not yet restored) keep
        /// their positions relative to each other.
        mutating func move(visible: [Tab], among tabs: [Tab], fromOffsets source: IndexSet, toOffset destination: Int) {
            var visibleKeys = visible.compactMap { key(for: $0, among: tabs) }
            guard visibleKeys.count == visible.count else { return }
            let slots = visibleKeys.compactMap { keys.firstIndex(of: $0) }.sorted()
            visibleKeys.move(fromOffsets: source, toOffset: destination)
            for (slot, key) in zip(slots, visibleKeys) { keys[slot] = key }
        }

        /// If a pinned tab's key surface closed but the tab lives on (splits),
        /// re-key the pin to a surface that still exists.
        mutating func rekey(old: String, new: String) {
            guard let index = keys.firstIndex(of: old), !keys.contains(new) else { return }
            keys[index] = new
        }
    }

    /// Reorders `subset` (a subsequence of `order`, e.g. the Open rows) with
    /// `onMove` offsets, leaving every other element in its slot.
    static func move<ID: Hashable>(
        _ subset: [ID], in order: [ID], fromOffsets source: IndexSet, toOffset destination: Int
    ) -> [ID] {
        let members = Set(subset)
        let current = order.filter(members.contains)
        guard current.count == subset.count else { return order }
        var moved = subset
        moved.move(fromOffsets: source, toOffset: destination)
        var iterator = moved.makeIterator()
        return order.map { members.contains($0) ? iterator.next()! : $0 }
    }

    // MARK: Filter

    /// Case-insensitive match of every whitespace-separated term, each either a
    /// substring or an in-order subsequence of the title or folder.
    static func matches(_ tab: Tab, filter: String) -> Bool {
        let terms = filter.lowercased().split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystacks = [tab.title.lowercased(), tab.folder?.lowercased() ?? ""]
        return terms.allSatisfy { term in
            haystacks.contains { $0.contains(term) || isSubsequence(term, of: $0) }
        }
    }

    /// Filtered rows in display order. Substring matches rank ahead of fuzzy ones.
    static func filtered(_ sections: Sections, filter: String) -> [Tab] {
        let all = sections.pinned + sections.recents + sections.open
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        let matching = all.filter { matches($0, filter: trimmed) }
        let needle = trimmed.lowercased()
        let exact = matching.filter {
            $0.title.lowercased().contains(needle) || ($0.folder?.lowercased().contains(needle) ?? false)
        }
        let exactIDs = Set(exact.map(\.id))
        return exact + matching.filter { !exactIDs.contains($0.id) }
    }

    private static func isSubsequence<S: StringProtocol>(_ needle: S, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        outer: for c in needle {
            while let h = it.next() {
                if h == c { continue outer }
            }
            return false
        }
        return true
    }
}
