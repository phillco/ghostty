import AppKit
import SwiftUI

/// One row as the sidebar draws it.
struct VerticalTabRow: Identifiable, Equatable {
    let id: ObjectIdentifier
    let title: String
    let platform: VerticalTabs.Platform
    let folder: String?
    let bell: Bool
    let age: String?
    let shortcut: Int?
    let isSelected: Bool
    let isPinned: Bool
}

/// What the sidebar view renders and the actions it can take.
final class VerticalTabsStore: ObservableObject {
    @Published var pinned: [VerticalTabRow] = []
    @Published var recents: [VerticalTabRow] = []
    @Published var open: [VerticalTabRow] = []
    @Published var filter: String = ""
    @Published var renamingID: ObjectIdentifier?
    /// Bumped to move keyboard focus into the filter field.
    @Published var filterFocusRequest: Int = 0

    weak var host: VerticalTabsGroupHost?

    /// Rows matching the current filter, best first.
    var filteredRows: [VerticalTabRow] {
        guard let host else { return [] }
        let ids = VerticalTabs.filtered(host.sections, filter: filter).map(\.id)
        let all = Dictionary((pinned + recents + open).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { all[$0] }
    }
}

/// Owns the single live sidebar for one `NSWindowTabGroup`.
final class VerticalTabsGroupHost {
    private(set) weak var tabGroup: NSWindowTabGroup?
    private unowned let manager: VerticalTabsManager

    let store = VerticalTabsStore()
    private let hostingView: NSView
    private var widthConstraint: NSLayoutConstraint?
    private var windowsObservation: NSKeyValueObservation?
    private var refreshScheduled = false

    /// The latest snapshot, in tab group order.
    private(set) var tabs: [VerticalTabs.Tab] = []
    private(set) var sections = VerticalTabs.Sections()
    private var windowsByID: [ObjectIdentifier: TerminalWindow] = [:]

    init(tabGroup: NSWindowTabGroup, manager: VerticalTabsManager) {
        self.tabGroup = tabGroup
        self.manager = manager
        let view = NSHostingView(rootView: VerticalTabsSidebar(
            store: store,
            settings: manager.settings
        ))
        view.sizingOptions = []
        view.translatesAutoresizingMaskIntoConstraints = false
        hostingView = view
        store.host = self

        windowsObservation = tabGroup.observe(\.windows, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func tearDown() {
        windowsObservation?.invalidate()
        windowsObservation = nil
        hostingView.removeFromSuperview()
    }

    // MARK: Placement

    /// Moves the sidebar into `window`'s container (the selected tab).
    func attach(to window: TerminalWindow) {
        guard let container = window.terminalViewContainerForVerticalTabs else { return }
        guard hostingView.superview !== container else { return }
        hostingView.removeFromSuperview()
        container.addSubview(hostingView)
        let width = hostingView.widthAnchor.constraint(equalToConstant: manager.settings.width)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            width,
        ])
        widthConstraint = width
    }

    func setSidebarWidth(_ width: CGFloat) {
        widthConstraint?.constant = width
    }

    // MARK: Refresh

    /// Coalesces bursts of title/bell changes into one refresh.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        guard let tabGroup else { return }
        let windows = tabGroup.windows.compactMap { $0 as? TerminalWindow }
        let selected = tabGroup.selectedWindow

        if let selected = selected as? TerminalWindow, hostingView.window !== selected {
            attach(to: selected)
        }

        windowsByID = Dictionary(uniqueKeysWithValues: windows.map { (ObjectIdentifier($0), $0) })
        let width = manager.settings.width
        tabs = windows.map { window in
            let tracker = manager.tracker(for: window)
            tracker.syncBackdrop(in: window, width: width, color: window.preferredBackgroundColor)
            let controller = window.terminalController
            let parsed = VerticalTabs.parseTitle(window.title)
            let surfaces = controller.map { Array($0.surfaceTree) } ?? []
            let pwd = controller?.focusedSurface?.pwd ?? surfaces.first?.pwd
            return VerticalTabs.Tab(
                id: ObjectIdentifier(window),
                surfaceIDs: surfaces.map(\.id.uuidString),
                title: parsed.text.isEmpty ? window.title : parsed.text,
                folder: VerticalTabs.folderName(forPath: pwd),
                platform: parsed.platform,
                bell: controller?.bell ?? false,
                isSelected: window === selected,
                lastFocused: tracker.lastFocused,
                lastActive: tracker.lastActive ?? tracker.lastFocused,
                claimedPinKey: tracker.claimedPinKey
            )
        }

        updatePinKeys()

        let pins = manager.settings.pins.keys
        sections = VerticalTabs.sections(tabs: tabs, pins: pins)
        let now = Date()
        func rows(_ list: [VerticalTabs.Tab], pinned: Bool) -> [VerticalTabRow] {
            list.map { tab in
                VerticalTabRow(
                    id: tab.id,
                    title: tab.title,
                    platform: tab.platform,
                    folder: tab.folder,
                    bell: tab.bell,
                    age: tab.isSelected ? nil : VerticalTabs.ageText(since: tab.lastActive, now: now),
                    shortcut: sections.shortcutNumber(for: tab.id),
                    isSelected: tab.isSelected,
                    isPinned: pinned
                )
            }
        }
        let pinnedRows = rows(sections.pinned, pinned: true)
        let recentRows = rows(sections.recents, pinned: false)
        let openRows = rows(sections.open, pinned: false)
        if store.pinned != pinnedRows { store.pinned = pinnedRows }
        if store.recents != recentRows { store.recents = recentRows }
        if store.open != openRows { store.open = openRows }
    }

    /// Keeps pins attached to their tab: records which key each tab matched and
    /// re-keys a pin whose surface left the tab (closed split, split moved to a
    /// new tab) to a surface the tab still has.
    private func updatePinKeys() {
        var pins = manager.settings.pins
        for tab in tabs {
            guard let claimed = tab.claimedPinKey, pins.keys.contains(claimed),
                  !tab.surfaceIDs.contains(claimed), let replacement = tab.pinKey else { continue }
            pins.rekey(old: claimed, new: replacement)
        }
        if pins != manager.settings.pins { manager.settings.pins = pins }

        let matches = VerticalTabs.pinMatches(tabs: tabs, pins: pins.keys)
        let matched = Dictionary(matches.map { ($0.tab, $0.key) }, uniquingKeysWith: { a, _ in a })
        for index in tabs.indices {
            let key = matched[tabs[index].id]
            tabs[index].claimedPinKey = key
            if let window = windowsByID[tabs[index].id] {
                manager.tracker(for: window).claimedPinKey = key
            }
        }
        manager.settings.markSeen(matches.map(\.key))
    }

    func window(forShortcut number: Int) -> NSWindow? {
        guard let tab = sections.tab(forShortcut: number) else { return nil }
        return windowsByID[tab.id]
    }

    func isPinned(_ id: ObjectIdentifier) -> Bool {
        sections.pinned.contains { $0.id == id }
    }

    // MARK: Actions

    func select(_ id: ObjectIdentifier) {
        guard let window = windowsByID[id] else { return }
        // Switch after the current SwiftUI event so the sidebar isn't reparented mid-event.
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func togglePin(_ id: ObjectIdentifier) {
        refresh()
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        manager.settings.pins.toggle(tab, among: tabs)
        refresh()
        applyGroupOrder()
    }

    func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        manager.settings.pins.move(
            visible: sections.pinned, among: tabs, fromOffsets: source, toOffset: destination)
        refresh()
        applyGroupOrder()
    }

    func moveOpen(fromOffsets source: IndexSet, toOffset destination: Int) {
        let order = VerticalTabs.move(
            sections.open.map(\.id), in: tabs.map(\.id), fromOffsets: source, toOffset: destination)
        reorderTabGroup(to: order)
        refresh()
    }

    func close(_ id: ObjectIdentifier) {
        guard let controller = windowsByID[id]?.terminalController else { return }
        DispatchQueue.main.async { controller.closeTab(nil) }
    }

    func closeOthers(_ id: ObjectIdentifier) {
        guard let controller = windowsByID[id]?.terminalController else { return }
        DispatchQueue.main.async { controller.closeOtherTabs(nil) }
    }

    func newTab() {
        guard let controller = (tabGroup?.selectedWindow as? TerminalWindow)?.terminalController else { return }
        DispatchQueue.main.async { controller.newTab(nil) }
    }

    func renameText(for id: ObjectIdentifier) -> String {
        guard let window = windowsByID[id] else { return "" }
        return window.terminalController?.titleOverride ?? tabs.first { $0.id == id }?.title ?? window.title
    }

    func rename(_ id: ObjectIdentifier, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        windowsByID[id]?.terminalController?.titleOverride = trimmed.isEmpty ? nil : trimmed
        scheduleRefresh()
    }

    func focusFilter() {
        store.filterFocusRequest += 1
    }

    /// Enter in the filter: select the best match and clear the filter.
    func submitFilter() {
        let first = store.filteredRows.first
        store.filter = ""
        if let first {
            select(first.id)
        } else {
            focusTerminal()
        }
    }

    /// Esc in the filter: clear it and return focus to the terminal.
    func cancelFilter() {
        store.filter = ""
        focusTerminal()
    }

    func focusTerminal() {
        guard let window = tabGroup?.selectedWindow as? TerminalWindow,
              let surface = window.terminalController?.focusedSurface else { return }
        DispatchQueue.main.async {
            window.makeFirstResponder(surface)
        }
    }

    // MARK: Tab group order

    /// Keeps the real tab order Pinned-first so next/previous tab, AppleScript
    /// and horizontal mode agree with the sidebar.
    private func applyGroupOrder() {
        reorderTabGroup(to: VerticalTabs.groupOrder(tabs: tabs, pins: manager.settings.pins.keys))
    }

    private func reorderTabGroup(to order: [ObjectIdentifier]) {
        guard let tabGroup else { return }
        let desired = order.compactMap { windowsByID[$0] }
        guard desired.count == tabGroup.windows.count,
              tabGroup.windows.map(ObjectIdentifier.init) != order else { return }
        let selected = tabGroup.selectedWindow

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        // Chain each window directly after its predecessor; once every link holds,
        // the whole group is in `desired` order.
        for (index, window) in desired.enumerated() where index > 0 {
            let current = tabGroup.windows
            let previous = desired[index - 1]
            if let at = current.firstIndex(of: window), let before = current.firstIndex(of: previous),
               at == before + 1 { continue }
            tabGroup.removeWindow(window)
            previous.addTabbedWindowSafely(window, ordered: .above)
        }
        selected?.makeKeyAndOrderFront(nil)
        NSAnimationContext.endGrouping()

        (selected?.windowController as? TerminalController)?.relabelTabs()
    }
}
