import Foundation

/// Pure, AppKit-free logic behind the vertical tab sidebar. Everything here is
/// unit tested; the AppKit glue lives in `VerticalTabsManager`.
enum VerticalTabs {
    /// The number of rows shown in the Recents section.
    static let recentsLimit = 4

    /// Which agent produced a title, detected from its leading glyph.
    enum Platform: Equatable {
        case agy      // ✦
        case claude   // ✳
        case terminal
    }

    /// A tab title with spinner and agent glyph prefixes removed.
    struct ParsedTitle: Equatable {
        let text: String
        let platform: Platform
    }

    /// Strips leading whitespace, Braille spinner characters (U+2800–U+28FF),
    /// Ghostty's bell prefix and a leading `✦`/`✳` glyph from a tab title.
    static func parseTitle(_ raw: String) -> ParsedTitle {
        var scalars = Substring(raw).unicodeScalars[...]
        var platform: Platform = .terminal

        func dropNoise() {
            while let first = scalars.first {
                if first.properties.isWhitespace || (0x2800...0x28FF).contains(first.value) ||
                    first == "\u{FE0F}" {
                    scalars.removeFirst()
                } else if first == "🔔" {
                    scalars.removeFirst()
                } else {
                    break
                }
            }
        }

        dropNoise()
        if let first = scalars.first {
            if first == "✦" {
                platform = .agy
                scalars.removeFirst()
            } else if first == "✳" {
                platform = .claude
                scalars.removeFirst()
            }
        }
        dropNoise()

        let text = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(text: text, platform: platform)
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
        var lastFocused: Date?
        /// Last focus or title change; drives the idle age.
        var lastActive: Date?
        /// The pin key this tab matched last time, if any. A claimed key keeps
        /// matching this tab even after its surface moves to another tab (split
        /// promoted to a new tab); the manager then re-keys the pin.
        var claimedPinKey: String?

        /// The key a new pin for this tab is stored under.
        var pinKey: String? { surfaceIDs.first }
    }

    struct Sections: Equatable {
        var pinned: [Tab] = []
        var recents: [Tab] = []
        var open: [Tab] = []

        /// The rows `Cmd+1..9` address: Pinned then Open, skipping Recents.
        var numbered: [Tab] { pinned + open }

        /// The 1-based shortcut number for a tab, if it has one (1...9).
        func shortcutNumber(for id: ObjectIdentifier) -> Int? {
            guard let index = numbered.prefix(9).firstIndex(where: { $0.id == id }) else { return nil }
            return index + 1
        }

        /// The tab `goto_tab:n` (1-based) selects. Indices past the end pick the last
        /// numbered tab, matching Ghostty's horizontal behavior.
        func tab(forShortcut n: Int) -> Tab? {
            guard n >= 1 else { return nil }
            let list = numbered
            guard !list.isEmpty else { return nil }
            return list[min(n - 1, list.count - 1)]
        }
    }

    /// Splits tabs into Pinned / Recents / Open so no tab appears twice.
    ///
    /// - Pinned follows `pins` order.
    /// - Recents are the most recently focused unpinned tabs, excluding the selected tab.
    /// - Open keeps tab group order for everything else.
    static func sections(tabs: [Tab], pins: [String], recentsLimit: Int = recentsLimit) -> Sections {
        var result = Sections()
        var used = Set<ObjectIdentifier>()

        for match in pinMatches(tabs: tabs, pins: pins) {
            guard let tab = tabs.first(where: { $0.id == match.tab }) else { continue }
            result.pinned.append(tab)
            used.insert(tab.id)
        }

        if recentsLimit > 0 {
            result.recents = tabs
                .filter { !used.contains($0.id) && !$0.isSelected && $0.lastFocused != nil }
                .sorted { $0.lastFocused! > $1.lastFocused! }
                .prefix(recentsLimit)
                .map { $0 }
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

    /// The tab group order that matches the sidebar: Pinned first, then every
    /// other tab in its existing relative order.
    static func groupOrder(tabs: [Tab], pins: [String]) -> [ObjectIdentifier] {
        let pinned = sections(tabs: tabs, pins: pins, recentsLimit: 0).pinned.map(\.id)
        let pinnedSet = Set(pinned)
        return pinned + tabs.map(\.id).filter { !pinnedSet.contains($0) }
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
