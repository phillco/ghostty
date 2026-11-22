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
    var isSelected: Bool
    let isPinned: Bool
    /// `agentd` status; nil for plain shells or without the daemon.
    var status: VerticalTabs.Agent.Display?
    var awaitingKind: String = ""
    var badge = VerticalTabs.Agent.Badge()
    /// Note and child job lines for the tooltip.
    var details: [String] = []
}

/// What the sidebar view renders and the actions it can take.
final class VerticalTabsStore: ObservableObject {
    @Published var pinned: [VerticalTabRow] = []
    @Published var recents: [VerticalTabRow] = []
    @Published var open: [VerticalTabRow] = []
    @Published var filter: String = ""
    /// Show the Recents header (possibly collapsed) even when it has no rows.
    @Published var hasRecents: Bool = false
    @Published var renamingID: ObjectIdentifier?
    /// Bumped to move keyboard focus into the filter field.
    @Published var filterFocusRequest: Int = 0
    /// The row being dragged to reorder, and where it would land. A cancelled
    /// drag leaves them set; `dragPayload` proves a drop is that drag.
    var draggingID: ObjectIdentifier?
    var dragPayload: String?
    @Published var dropTarget: DropTarget?

    struct DropTarget: Equatable {
        let id: ObjectIdentifier
        /// Lands after the target row rather than before it.
        let after: Bool
    }

    weak var host: VerticalTabsGroupHost?

    /// Rows matching the current filter, best first.
    var filteredRows: [VerticalTabRow] {
        guard let host else { return [] }
        let ids = VerticalTabs.filtered(host.sections, filter: filter).map(\.id)
        let all = Dictionary((pinned + recents + open).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { all[$0] }
    }

    /// Moves the selection highlight now, before the window switch catches up.
    func markSelected(_ id: ObjectIdentifier) {
        func mark(_ rows: [VerticalTabRow]) -> [VerticalTabRow] {
            rows.map { row in
                var row = row
                row.isSelected = row.id == id
                return row
            }
        }
        let (p, r, o) = (mark(pinned), mark(recents), mark(open))
        if p != pinned { pinned = p }
        if r != recents { recents = r }
        if o != open { open = o }
    }
}

/// Owns the single live sidebar for one `NSWindowTabGroup`.
final class VerticalTabsGroupHost {
    private(set) weak var tabGroup: NSWindowTabGroup?
    private unowned let manager: VerticalTabsManager

    let store = VerticalTabsStore()
    private let hostingView: NSView
    /// Owned by the hosting view itself, so it survives reparenting: create once.
    private let widthConstraint: NSLayoutConstraint
    private var windowsObservation: NSKeyValueObservation?
    private var refreshScheduled = false
    /// Set while we reorder the tab group, so the windows KVO doesn't re-enter.
    private var isReordering = false

    /// The latest snapshot, in tab group order.
    private(set) var tabs: [VerticalTabs.Tab] = []
    private(set) var sections = VerticalTabs.Sections()
    private var windowsByID: [ObjectIdentifier: TerminalWindow] = [:]
    /// The tab selected last, so the next selection can stamp when it was left.
    weak var lastSelectedWindow: TerminalWindow?
    /// The selected tab, when it was selected from Recents: it stays in Recents.
    /// After quick clicks, every tab passed through from Recents, so Recents
    /// holds still until the selection settles. Previous/next leave it alone.
    var keptRecents: Set<ObjectIdentifier> = []
    /// The tab a previous/next step is switching to; its selection leaves
    /// Recents untouched. Cleared once any tab becomes main.
    var directionalTarget: ObjectIdentifier?
    /// Bumped by directional steps so pending walk-settle callbacks no-op.
    var settleGeneration = 0
    /// A tab clicked in the sidebar that AppKit hasn't selected yet. Refreshes
    /// in between keep showing it selected, so the highlight never bounces back.
    private var pendingSelection: ObjectIdentifier?
    /// Seconds until a visible active turn's elapsed age changes; nil for none.
    private(set) var nextAgentTick: TimeInterval?

    init(tabGroup: NSWindowTabGroup, manager: VerticalTabsManager) {
        self.tabGroup = tabGroup
        self.manager = manager
        lastSelectedWindow = tabGroup.selectedWindow as? TerminalWindow
        // Selected since before we tracked it: the first switch away still counts.
        if let selected = lastSelectedWindow { manager.tracker(for: selected).lastEntered = .distantPast }
        let view = NSHostingView(rootView: VerticalTabsSidebar(
            store: store,
            settings: manager.settings
        ))
        view.sizingOptions = []
        view.translatesAutoresizingMaskIntoConstraints = false
        hostingView = view
        widthConstraint = view.widthAnchor.constraint(equalToConstant: manager.settings.width)
        widthConstraint.isActive = true
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

    /// Moves the sidebar into `window`'s container (the selected tab), laid out
    /// before the next frame so it never shows a stale or unsized sidebar.
    func attach(to window: TerminalWindow) {
        guard let container = window.terminalViewContainerForVerticalTabs else { return }
        guard hostingView.superview !== container else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        hostingView.removeFromSuperview()
        container.addSubview(hostingView)
        widthConstraint.constant = manager.settings.width
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
    }

    /// Whether `responder` is in the sidebar (a field editor sits inside its field).
    func contains(_ responder: NSResponder?) -> Bool {
        (responder as? NSView)?.isDescendant(of: hostingView) ?? false
    }

    func setSidebarWidth(_ width: CGFloat) {
        widthConstraint.constant = width
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

    /// - Parameter enforceOrder: restore the pinned-first native order if it
    ///   drifted. The follow-up refresh after a reorder passes false so a reorder
    ///   AppKit refuses can't recurse.
    func refresh(enforceOrder: Bool = true) {
        guard let tabGroup else { return }
        let windows = tabGroup.windows.compactMap { $0 as? TerminalWindow }
        let selectedWindow = tabGroup.selectedWindow
        if let pending = pendingSelection, !windows.contains(where: { ObjectIdentifier($0) == pending }) {
            pendingSelection = nil
        }
        let selectedID = pendingSelection ?? selectedWindow.map(ObjectIdentifier.init)

        windowsByID = Dictionary(uniqueKeysWithValues: windows.map { (ObjectIdentifier($0), $0) })
        let width = manager.settings.width
        let agents = manager.agentSnapshot
        tabs = windows.map { window in
            let tracker = manager.tracker(for: window)
            tracker.syncBackdrop(in: window, width: width, color: window.preferredBackgroundColor)
            let controller = window.terminalController
            let parsed = VerticalTabs.parseTitle(window.title)
            let platform = VerticalTabs.resolvePlatform(parsed.platform, last: tracker.lastPlatform)
            tracker.lastPlatform = platform.last
            let surfaces = controller.map { Array($0.surfaceTree) } ?? []
            let pwd = controller?.focusedSurface?.pwd ?? surfaces.first?.pwd
            var agent: VerticalTabs.Agent.Summary?
            if !agents.isEmpty, let controller {
                let sessions = Self.orderedSurfaces(controller).compactMap {
                    agents.session(for: Self.agentTerminal($0))
                }
                agent = VerticalTabs.Agent.summary(of: sessions)
            }
            return VerticalTabs.Tab(
                id: ObjectIdentifier(window),
                surfaceIDs: surfaces.map(\.id.uuidString),
                title: parsed.text.isEmpty ? window.title : parsed.text,
                folder: VerticalTabs.folderName(forPath: pwd),
                platform: platform.shown,
                bell: controller?.bell ?? false,
                isSelected: ObjectIdentifier(window) == selectedID,
                lastLeft: tracker.lastLeft,
                lastActive: tracker.shownActive,
                claimedPinKey: tracker.claimedPinKey,
                agent: agent
            )
        }

        updatePinKeys()

        let pins = manager.settings.pins.keys
        if enforceOrder, !isReordering, let order = VerticalTabs.pinnedFirstOrder(tabs: tabs, pins: pins) {
            reorderTabGroup(to: order)
            refresh(enforceOrder: false)
            return
        }
        // Collapsed or hidden Recents must not hide tabs: they stay in Open instead.
        let settings = manager.settings
        let limit = settings.config.recentsLimit
        let recentsOff = settings.recentsCollapsed || !settings.showRecents
        sections = VerticalTabs.sections(
            tabs: tabs, pins: pins, recentsLimit: recentsOff ? 0 : limit,
            keepInRecents: keptRecents)
        let hasRecents = settings.showRecents && limit > 0
            && VerticalTabs.hasRecentCandidates(tabs: tabs, pins: pins)
        if store.hasRecents != hasRecents { store.hasRecents = hasRecents }
        let now = Date()
        var nextTick: TimeInterval?
        func rows(_ list: [VerticalTabs.Tab], pinned: Bool) -> [VerticalTabRow] {
            list.map { tab in
                if let since = tab.agent?.turnSince {
                    let tick = VerticalTabs.Agent.nextElapsedTick(since: since, now: now)
                    nextTick = min(nextTick ?? tick, tick)
                }
                return VerticalTabRow(
                    id: tab.id,
                    title: tab.title,
                    platform: tab.platform,
                    folder: tab.folder,
                    bell: tab.bell,
                    age: VerticalTabs.Agent.ageText(
                        summary: tab.agent, fallback: tab.lastActive, isSelected: tab.isSelected, now: now),
                    shortcut: sections.shortcutNumber(for: tab.id),
                    isSelected: tab.isSelected,
                    isPinned: pinned,
                    status: tab.agent?.display,
                    awaitingKind: tab.agent?.awaitingKind ?? "",
                    badge: tab.agent?.badge ?? .init(),
                    details: tab.agent?.details ?? []
                )
            }
        }
        let pinnedRows = rows(sections.pinned, pinned: true)
        let recentRows = rows(sections.recents, pinned: false)
        let openRows = rows(sections.open, pinned: false)
        if store.pinned != pinnedRows { store.pinned = pinnedRows }
        if store.recents != recentRows { store.recents = recentRows }
        if store.open != openRows { store.open = openRows }
        nextAgentTick = nextTick
        if let nextTick { manager.scheduleAgentTick(after: nextTick) }

        // Rows first: the sidebar's first frame in a newly selected tab is current.
        if pendingSelection == nil, let selected = selectedWindow as? TerminalWindow,
           hostingView.window !== selected {
            attach(to: selected)
        }
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

    func window(for shortcut: VerticalTabs.Shortcut) -> NSWindow? {
        guard let tab = sections.tab(for: shortcut) else { return nil }
        return windowsByID[tab.id]
    }

    func isPinned(_ id: ObjectIdentifier) -> Bool {
        sections.pinned.contains { $0.id == id }
    }

    // MARK: Actions

    func select(_ id: ObjectIdentifier) {
        guard let window = windowsByID[id] else { return }
        if !store.filter.isEmpty { store.filter = "" }
        // Highlight now; switch after the current SwiftUI event so the sidebar
        // isn't reparented mid-event, then hand keyboard focus to the terminal.
        store.markSelected(id)
        pendingSelection = id
        DispatchQueue.main.async { [weak self] in
            self?.pendingSelection = nil
            window.makeKeyAndOrderFront(nil)
            if let surface = window.terminalController?.focusedSurface {
                window.makeFirstResponder(surface)
            }
            // Also covers a switch AppKit refused or that posted no notification.
            self?.refresh()
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

    func copyTitle(_ id: ObjectIdentifier) {
        guard let title = tabs.first(where: { $0.id == id })?.title else { return }
        copyToPasteboard(title)
    }

    /// A tab's splits, focused first, then the rest of the tree in order.
    static func orderedSurfaces(_ controller: BaseTerminalController) -> [Ghostty.SurfaceView] {
        let focused = controller.focusedSurface
        return [focused].compactMap { $0 } + controller.surfaceTree.filter { $0 !== focused }
    }

    /// What `agentd` matching needs from a split. Main thread only, like
    /// every sidebar refresh.
    static func agentTerminal(_ surface: Ghostty.SurfaceView) -> VerticalTabs.Agent.Snapshot.Terminal {
        MainActor.assumeIsolated {
            let pid = surface.surfaceModel?.foregroundPID.flatMap { Int32(exactly: $0) }
            return .init(
                surfaceID: surface.id.uuidString,
                pids: pid.map { [$0] } ?? [],
                tty: surface.surfaceModel?.ttyName)
        }
    }

    /// `<sessionId> (<peerId>)` for the agent session in this tab (from
    /// `agentd` when it knows one), else the focused surface's UUID.
    @MainActor
    func copyID(_ id: ObjectIdentifier) {
        guard let controller = windowsByID[id]?.terminalController else { return }
        let surfaces = Self.orderedSurfaces(controller)
        let agents = manager.agentSnapshot
        if let session = surfaces.lazy.compactMap({ agents.session(for: Self.agentTerminal($0)) }).first,
           !session.nativeId.isEmpty, !session.peerName.isEmpty {
            copyToPasteboard("\(session.nativeId) (\(session.peerName))")
            return
        }
        let terminals = surfaces.map {
            VerticalTabsAgentLookup.Terminal(
                ttyName: $0.surfaceModel?.ttyName, foregroundPID: $0.surfaceModel?.foregroundPID)
        }
        if let session = VerticalTabsAgentLookup.session(for: terminals) {
            copyToPasteboard(session.copyText)
        } else if let surface = surfaces.first {
            copyToPasteboard(surface.id.uuidString)
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
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
        let wasKey = selected?.isKeyWindow ?? false
        isReordering = true
        defer { isReordering = false }

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
        if let selected {
            tabGroup.selectedWindow = selected
            if wasKey { selected.makeKeyAndOrderFront(nil) }
        }
        NSAnimationContext.endGrouping()

        (selected?.windowController as? TerminalController)?.relabelTabs()
    }
}
