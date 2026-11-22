import AppKit
import Combine
import SwiftUI

/// Hosts the vertical tab sidebar.
///
/// `NSWindowTabGroup` stays the tab model: every tab is still a `TerminalWindow`,
/// so tab history, goto/move tab, AppleScript and splits keep working. In vertical
/// mode the native tab bar accessory is hidden and every terminal container gets the
/// same leading inset, so switching tabs never resizes a PTY. Each tab group owns one
/// live sidebar, which moves into whichever window of the group is selected.
final class VerticalTabsManager: NSObject {
    static let shared = VerticalTabsManager()

    let settings = VerticalTabsSettings.shared

    private var hosts: [ObjectIdentifier: VerticalTabsGroupHost] = [:]
    private var trackers: [ObjectIdentifier: WindowTracker] = [:]
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var ageTimer: Timer?
    private var recentsCancellable: AnyCancellable?
    private var started = false

    // MARK: agentd state

    /// What `agentd` last reported; empty while it isn't running.
    private(set) var agentSnapshot = VerticalTabs.Agent.Snapshot()
    private var agentClient: VerticalTabsAgentClient?
    /// A one-shot refresh for when an active turn's elapsed age next changes.
    private var agentTickTimer: Timer?
    /// The visibly focused split, and since when; see `evaluateAck`.
    private var ackFocus: VerticalTabs.Agent.Focus?
    /// Acks sent per reply (`ackToken`), so refreshes never resend early.
    private var ackSent: [String: VerticalTabs.Agent.AckAttempt] = [:]
    private var ackTimer: Timer?

    var isEnabled: Bool { settings.enabled }

    /// How long a tab must stay selected before leaving it puts it in Recents.
    private var recentsDwell: TimeInterval { settings.config.recentsDwell }

    /// The leading inset a terminal container should use right now. Windows that
    /// can't tab (hidden titlebar) never get a sidebar, so they get no gutter.
    func leadingInset(for window: NSWindow) -> CGFloat {
        isEnabled && window.tabbingMode != .disallowed ? settings.width : 0
    }

    // MARK: Lifecycle

    /// Call once at launch, after the main menu loads.
    func start() {
        guard !started else { return }
        started = true

        installMenuItems()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let window = n.object as? TerminalWindow else { return }
            self?.windowDidBecomeMain(window)
        })
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let window = n.object as? TerminalWindow else { return }
            self?.trackers[ObjectIdentifier(window)] = nil
            DispatchQueue.main.async { self?.refreshAll() }
        })
        // Restored or background windows may never become main; give their
        // groups a sidebar once they finish loading.
        observers.append(center.addObserver(
            forName: TerminalWindow.terminalDidAwake, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { self?.refreshAll() }
        })

        // A sibling tab doesn't lay out at the new size until it's selected, so
        // its PTY resize (and the agent's full redraw) would land on screen.
        observers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let window = n.object as? TerminalWindow else { return }
            self?.syncSiblingFrames(of: window)
        })

        // `vertical-tabs-*` keys live-reload with the rest of the config.
        observers.append(center.addObserver(
            forName: .ghosttyConfigDidChange, object: nil, queue: .main
        ) { [weak self] n in
            // Surface-scoped changes carry an object; only the app config counts.
            guard n.object == nil,
                  let config = n.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config
            else { return }
            self?.applyConfig(config)
        })
        if let config = (NSApp.delegate as? AppDelegate)?.ghostty.config { applyConfig(config) }

        // Acknowledging a reply needs to know which split is visibly focused.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.evaluateAck()
            })
        }

        // `ghostty-test-mirror` rewrites our prefs while we run, then posts this.
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Self.reloadPrefsNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadPrefs()
        })

        // Collapsing or hiding Recents moves its tabs back into Open (and renumbers them).
        recentsCancellable = settings.$recentsCollapsed.combineLatest(settings.$showRecents)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshAll() } }

        if isEnabled { applyEnabled() }
    }

    private func applyConfig(_ config: Ghostty.Config) {
        let old = settings.config
        settings.applyConfig(.init(config))
        // Fonts redraw through `settings`; Recents' size changes the sections.
        if settings.config.recentsLimit != old.recentsLimit { refreshAll() }
        // A walk in progress settles on the new dwell, not the one it started with.
        if settings.config.recentsDwell != old.recentsDwell {
            for host in hosts.values {
                guard let window = host.lastSelectedWindow,
                      let entered = trackers[ObjectIdentifier(window)]?.lastEntered else { continue }
                settleWalk(in: host, on: window, enteredAt: entered)
            }
        }
    }

    /// Posted (distributed) by tools that write our `VerticalTabs*` defaults.
    static let reloadPrefsNotification = Notification.Name(
        "\(Bundle.main.bundleIdentifier ?? "io.phillip.ghostty-phil").vertical-tabs.reload-prefs")

    func reloadPrefs() {
        settings.reloadFromDefaults()
        applyEnabled()
    }

    func toggle() {
        settings.enabled.toggle()
        applyEnabled()
    }

    private func applyEnabled() {
        hosts.values.forEach { $0.setSidebarWidth(settings.width) }
        for window in terminalWindows {
            window.terminalViewContainerForVerticalTabs?.leadingInset = leadingInset(for: window)
            syncTabBar(of: window)
        }
        layOutBackgroundTabs()

        if isEnabled {
            ageTimer?.invalidate()
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refreshAll() }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            ageTimer = timer
            startAgentClient()
            refreshAll()
        } else {
            ageTimer?.invalidate()
            ageTimer = nil
            stopAgentClient()
            // The filter or rename field may have focus; the terminal gets it back.
            // Other controls (a Find field) keep theirs.
            let sidebarFocused = terminalWindows.filter { window in
                hosts.values.contains { $0.contains(window.firstResponder) }
            }
            hosts.values.forEach { $0.tearDown() }
            hosts = [:]
            trackers.values.forEach { $0.removeBackdrop() }
            trackers = [:]
            for window in sidebarFocused {
                if let surface = window.terminalController?.focusedSurface {
                    window.makeFirstResponder(surface)
                }
            }
        }
    }

    // MARK: Hooks called from terminal windows

    /// Hides or restores AppKit's native tab bar accessory for this window.
    func syncTabBar(of window: TerminalWindow) {
        for controller in window.titlebarAccessoryViewControllers where window.isTabBar(controller) {
            if controller.isHidden != isEnabled { controller.isHidden = isEnabled }
        }
    }

    /// Selects a goto_tab target in vertical mode: numbers address Pinned then
    /// Open, skipping Recents; previous/next step through the sidebar's rows.
    /// Returns false when vertical tabs don't handle it (native order applies).
    func select(_ shortcut: VerticalTabs.Shortcut, in tabGroup: NSWindowTabGroup) -> Bool {
        guard isEnabled else { return false }
        let host = host(for: tabGroup)
        host.refresh()
        guard let target = host.window(for: shortcut) else { return false }
        let directional = shortcut == .previous || shortcut == .next
        let id = ObjectIdentifier(target)
        // Marked before the switch: `windowDidBecomeMain` may run inside it.
        if directional { host.directionalTarget = id }
        target.makeKeyAndOrderFront(nil)
        // A refused switch (or one notifying later) must not mark a later one.
        if directional {
            DispatchQueue.main.async { [weak host] in
                if host?.directionalTarget == id { host?.directionalTarget = nil }
            }
        }
        return true
    }

    // MARK: Windows

    private var terminalWindows: [TerminalWindow] {
        NSApp.windows.compactMap { $0 as? TerminalWindow }
    }

    private func windowDidBecomeMain(_ window: TerminalWindow) {
        guard isEnabled, window.tabbingMode != .disallowed, let tabGroup = window.tabGroup else { return }
        let host = host(for: tabGroup)
        let now = Date()
        let id = ObjectIdentifier(window)
        let directional = host.directionalTarget == id
        host.directionalTarget = nil

        let leaving: VerticalTabs.Leaving
        if let previous = host.lastSelectedWindow, previous.tabGroup === tabGroup {
            let entered = tracker(for: previous).lastEntered
            leaving = previous === window
                ? .same : .tab(dwelled: entered.map { now.timeIntervalSince($0) >= recentsDwell } ?? true)
        } else {
            leaving = .nothing
        }
        let update = VerticalTabs.recentsUpdate(
            selecting: id, leaving: leaving, directional: directional,
            sections: host.sections, kept: host.keptRecents)
        if update.stampLeft, let previous = host.lastSelectedWindow { tracker(for: previous).lastLeft = now }
        // Any departure seeds an age once, so a quiet tab only ever stepped
        // past still shows one; later step-pasts leave it be.
        if case .tab = leaving, let previous = host.lastSelectedWindow {
            let tracker = tracker(for: previous)
            if tracker.firstLeft == nil { tracker.firstLeft = now }
        }
        if leaving != .same { tracker(for: window).lastEntered = now }
        host.lastSelectedWindow = window
        host.keptRecents = update.kept
        // A walk's rows hold still: no earlier settle may reshuffle them mid-walk.
        if directional { host.settleGeneration += 1 }
        if update.settle { settleWalk(in: host, on: window, enteredAt: now) }
        // No `lastActive` stamp: a glance or a walk past a tab isn't activity.
        syncTabBar(of: window)
        let inset = leadingInset(for: window)
        if window.terminalViewContainerForVerticalTabs?.leadingInset != inset {
            window.terminalViewContainerForVerticalTabs?.leadingInset = inset
        }
        // Rows first, then the move: the sidebar's first frame in this window
        // already shows this tab selected.
        host.refresh()
    }

    /// Once a quick walk rests on `window` for the dwell time, only it stays
    /// kept in Recents (if it was selected from there); the rest settle back.
    /// `entered` ties the check to this visit: an A→B→A walk's first timer
    /// must not settle the second, shorter visit to A. The deadline counts from
    /// `entered`, so rescheduling after a dwell change keeps the visit's start,
    /// and a callback fires only once the current dwell has passed. A
    /// directional step bumps `settleGeneration`, cancelling pending callbacks.
    private func settleWalk(in host: VerticalTabsGroupHost, on window: TerminalWindow, enteredAt entered: Date) {
        let delay = max(0, recentsDwell - Date().timeIntervalSince(entered))
        let generation = host.settleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak host, weak window] in
            // A callback from before a dwell increase is early; the rescheduled one settles.
            guard let self, let host, let window, host.lastSelectedWindow === window,
                  host.settleGeneration == generation,
                  self.trackers[ObjectIdentifier(window)]?.lastEntered == entered,
                  Date().timeIntervalSince(entered) >= self.recentsDwell - 0.01 else { return }
            let id = ObjectIdentifier(window)
            let settled: Set<ObjectIdentifier> = host.keptRecents.contains(id) ? [id] : []
            guard settled != host.keptRecents else { return }
            host.keptRecents = settled
            host.refresh()
        }
    }

    /// Lays out tabs that aren't on screen, one per runloop turn, so their
    /// surfaces resize (and their PTYs get SIGWINCH) now rather than when
    /// they're next selected.
    private func layOutBackgroundTabs() {
        let hidden = terminalWindows.filter { window in
            guard let group = window.tabGroup else { return false }
            return group.selectedWindow !== window
        }
        for window in hidden {
            DispatchQueue.main.async { [weak window] in
                guard let window, window.tabGroup?.selectedWindow !== window else { return }
                window.contentView?.layoutSubtreeIfNeeded()
            }
        }
    }

    /// After a live resize, gives the window's sibling tabs its frame (AppKit
    /// otherwise applies it on selection) and lays them out in the background.
    private func syncSiblingFrames(of window: TerminalWindow) {
        guard window.styleMask.contains(.fullScreen) == false,
              let siblings = window.tabGroup?.windows, siblings.count > 1 else { return }
        let frame = window.frame
        for sibling in siblings where sibling !== window {
            DispatchQueue.main.async { [weak sibling, weak window] in
                guard let sibling, let window, sibling.tabGroup === window.tabGroup,
                      sibling.tabGroup?.selectedWindow !== sibling else { return }
                if sibling.frame != frame { sibling.setFrame(frame, display: false) }
                sibling.contentView?.layoutSubtreeIfNeeded()
            }
        }
    }

    private func host(for tabGroup: NSWindowTabGroup) -> VerticalTabsGroupHost {
        let key = ObjectIdentifier(tabGroup)
        if let host = hosts[key], host.tabGroup === tabGroup { return host }
        let host = VerticalTabsGroupHost(tabGroup: tabGroup, manager: self)
        hosts[key] = host
        return host
    }

    func refreshAll() {
        guard isEnabled else { return }

        // Make sure every group with a visible window has a host.
        for window in terminalWindows where window.tabbingMode != .disallowed {
            guard let tabGroup = window.tabGroup, tabGroup.selectedWindow === window else { continue }
            _ = host(for: tabGroup)
        }

        for (key, host) in hosts {
            if host.tabGroup?.windows.isEmpty ?? true {
                host.tearDown()
                hosts[key] = nil
            } else {
                host.refresh()
            }
        }
    }

    func tracker(for window: TerminalWindow) -> WindowTracker {
        let key = ObjectIdentifier(window)
        if let tracker = trackers[key] { return tracker }
        let tracker = WindowTracker(window: window) { [weak self, weak window] in
            guard let self, let group = window?.tabGroup else { return }
            self.hosts[ObjectIdentifier(group)]?.scheduleRefresh()
        }
        // Moving focus between splits changes which reply is being read.
        tracker.focusObservation = window.observe(\.firstResponder, options: []) { [weak self] _, _ in
            DispatchQueue.main.async { self?.evaluateAck() }
        }
        trackers[key] = tracker
        return tracker
    }

    // MARK: agentd

    private func startAgentClient() {
        guard agentClient == nil else { return }
        let client = VerticalTabsAgentClient { [weak self] snapshot in
            self?.agentDidUpdate(snapshot)
        }
        agentClient = client
        client.start()
    }

    private func stopAgentClient() {
        agentClient?.stop()
        agentClient = nil
        agentTickTimer?.invalidate()
        agentTickTimer = nil
        ackTimer?.invalidate()
        ackTimer = nil
        agentDidUpdate(.init())
    }

    private func agentDidUpdate(_ snapshot: VerticalTabs.Agent.Snapshot) {
        guard snapshot != agentSnapshot else { return }
        agentSnapshot = snapshot
        // A new connection may need a reply acknowledged again.
        if snapshot.isEmpty { ackSent = [:] }
        refreshAll()
        evaluateAck()
    }

    /// Refreshes once `delay` passes, unless an earlier refresh is already due.
    /// Each refresh asks again, so ticks run only while a turn is visible.
    func scheduleAgentTick(after delay: TimeInterval) {
        let due = Date().addingTimeInterval(delay)
        if let timer = agentTickTimer, timer.isValid, timer.fireDate <= due { return }
        agentTickTimer?.invalidate()
        let timer = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            self?.agentTickTimer = nil
            self?.refreshAll()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        agentTickTimer = timer
    }

    /// The focused split of the key window's selected tab, while the app is
    /// active and the split is on screen (not hidden by a zoom).
    private var visiblyFocusedSurface: Ghostty.SurfaceView? {
        guard NSApp.isActive, let window = NSApp.keyWindow as? TerminalWindow,
              window.isVisible, window.tabGroup.map({ $0.selectedWindow === window }) ?? true,
              let surface = window.terminalController?.focusedSurface,
              surface.window === window else { return nil }
        return surface
    }

    private func evaluateAckLater(at date: Date) {
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in self?.evaluateAck() }
        RunLoop.main.add(timer, forMode: .common)
        ackTimer = timer
    }

    /// Acknowledges the unread reply in the visibly focused split once it has
    /// been focused for the Recents dwell: a step past a tab keeps its dot.
    /// Unfocused splits, background tabs and an inactive app never ack.
    func evaluateAck() {
        ackTimer?.invalidate()
        ackTimer = nil
        guard let client = agentClient else { return }
        let now = Date()
        let surface = visiblyFocusedSurface
        let id = surface?.id.uuidString
        if id != ackFocus?.surfaceID { ackFocus = id.map { .init(surfaceID: $0, since: now) } }
        guard let surface, !agentSnapshot.isEmpty else { return }
        let session = agentSnapshot.session(for: VerticalTabsGroupHost.agentTerminal(surface))
        switch VerticalTabs.Agent.ackDecision(
            focus: ackFocus, session: session, now: now, dwell: recentsDwell, sent: ackSent) {
        case .none:
            break
        case .wait(let until):
            evaluateAckLater(at: until)
        case .send(let key, let replyId):
            let token = VerticalTabs.Agent.ackToken(key: key, replyId: replyId)
            ackSent[token] = .init(count: (ackSent[token]?.count ?? 0) + 1, last: now)
            client.ackReply(key: key, replyId: replyId)
            // Still unread later (a failed save)? Check again then.
            evaluateAckLater(at: now.addingTimeInterval(VerticalTabs.Agent.ackRetryAfter))
        }
    }

    // MARK: Width

    /// Live width while dragging the divider: only the visible window resizes.
    func setLiveWidth(_ width: CGFloat, in window: NSWindow?) {
        let width = VerticalTabsSettings.clamp(width)
        hosts.values.forEach { $0.setSidebarWidth(width) }
        if let window = window as? TerminalWindow {
            window.terminalViewContainerForVerticalTabs?.leadingInset = width
            tracker(for: window).syncBackdrop(in: window, width: width, color: window.preferredBackgroundColor)
        }
    }

    /// Commits a width: persists it and applies it to every terminal window.
    func commitWidth(_ width: CGFloat) {
        settings.width = VerticalTabsSettings.clamp(width)
        hosts.values.forEach { $0.setSidebarWidth(settings.width) }
        for window in terminalWindows {
            window.terminalViewContainerForVerticalTabs?.leadingInset = leadingInset(for: window)
        }
        refreshAll()
        layOutBackgroundTabs()
    }

    // MARK: Menu

    private static let menuTag = 0x7674_6162 // "vtab"

    private func installMenuItems() {
        guard let viewMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu,
              !viewMenu.items.contains(where: { $0.tag == Self.menuTag }) else { return }

        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            item.tag = Self.menuTag
            return item
        }

        let separator = NSMenuItem.separator()
        separator.tag = Self.menuTag
        viewMenu.addItem(separator)
        viewMenu.addItem(item("Show Vertical Tabs", #selector(toggleVerticalTabs(_:)), "s", [.control, .command]))
        viewMenu.addItem(item("Pin Tab", #selector(togglePinTab(_:)), "p", [.option, .command]))
        viewMenu.addItem(item("Filter Tabs", #selector(focusTabFilter(_:)), "f", [.option, .command]))
        viewMenu.addItem(item("Tall Tab Rows", #selector(toggleDensity(_:)), "", []))
    }

    private var mainTerminalWindow: TerminalWindow? {
        (NSApp.mainWindow ?? NSApp.keyWindow) as? TerminalWindow
    }

    @objc func toggleVerticalTabs(_ sender: Any?) {
        toggle()
    }

    @objc func togglePinTab(_ sender: Any?) {
        guard isEnabled, let window = mainTerminalWindow, let tabGroup = window.tabGroup else { return }
        host(for: tabGroup).togglePin(ObjectIdentifier(window))
    }

    @objc func focusTabFilter(_ sender: Any?) {
        guard isEnabled, let window = mainTerminalWindow, let tabGroup = window.tabGroup else { return }
        let host = host(for: tabGroup)
        host.attach(to: window)
        host.focusFilter()
    }

    @objc func toggleDensity(_ sender: Any?) {
        settings.density = settings.density == .compact ? .tall : .compact
    }
}

extension VerticalTabsManager: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleVerticalTabs(_:)):
            item.title = isEnabled ? "Hide Vertical Tabs" : "Show Vertical Tabs"
            return true

        case #selector(togglePinTab(_:)):
            guard isEnabled, let window = mainTerminalWindow, let tabGroup = window.tabGroup else {
                item.title = "Pin Tab"
                return false
            }
            let pinned = host(for: tabGroup).isPinned(ObjectIdentifier(window))
            item.title = pinned ? "Unpin Tab" : "Pin Tab"
            return true

        case #selector(focusTabFilter(_:)):
            return isEnabled && mainTerminalWindow != nil

        case #selector(toggleDensity(_:)):
            item.state = settings.density == .tall ? .on : .off
            return isEnabled

        default:
            return true
        }
    }
}

// MARK: - Window tracking

/// Per-window bookkeeping: focus and activity times plus cheap observers that
/// schedule a (throttled) sidebar refresh.
final class WindowTracker {
    /// When another tab in the group was selected over this one; ranks Recents.
    var lastLeft: Date?
    /// When this tab was last selected; see `VerticalTabsManager.recentsDwell`.
    var lastEntered: Date?
    /// Last real title change or bell. Focus deliberately doesn't count.
    var lastActive: Date?
    /// The first time any switch left this tab, even a walk past it.
    var firstLeft: Date?
    /// Drives the idle age: activity, else when this tab was last left.
    var shownActive: Date? { lastActive ?? lastLeft ?? firstLeft }
    /// The pin key this tab matched on the last refresh.
    var claimedPinKey: String?
    /// The agent platform seen last, kept across ambiguous spinner frames.
    var lastPlatform: VerticalTabs.Platform?
    /// Watches split focus for acknowledging agent replies.
    var focusObservation: NSKeyValueObservation?

    private var titleObservation: NSKeyValueObservation?
    private var bellCancellable: AnyCancellable?
    private var ringCancellable: AnyCancellable?

    /// A plain layer-backed view filling the sidebar inset. Inactive tabs show it
    /// in place of the live sidebar, so a tab switch never flashes the window
    /// background before the sidebar moves in.
    private var backdrop: NSView?
    private var backdropWidth: NSLayoutConstraint?

    func syncBackdrop(in window: TerminalWindow, width: CGFloat, color: NSColor?) {
        guard let container = window.terminalViewContainerForVerticalTabs else { return }
        let view: NSView
        if let backdrop, backdrop.superview === container {
            view = backdrop
        } else {
            backdrop?.removeFromSuperview()
            view = NSView()
            view.wantsLayer = true
            view.translatesAutoresizingMaskIntoConstraints = false
            // Bottom-most, so neither the terminal nor the live sidebar is covered.
            container.addSubview(view, positioned: .below, relativeTo: nil)
            let widthConstraint = view.widthAnchor.constraint(equalToConstant: width)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                widthConstraint,
            ])
            backdrop = view
            backdropWidth = widthConstraint
        }
        if backdropWidth?.constant != width { backdropWidth?.constant = width }
        let cgColor = (color ?? window.backgroundColor)?.cgColor
        if view.layer?.backgroundColor != cgColor { view.layer?.backgroundColor = cgColor }
    }

    func removeBackdrop() {
        backdrop?.removeFromSuperview()
        backdrop = nil
        backdropWidth = nil
    }

    convenience init(window: TerminalWindow, onChange: @escaping () -> Void) {
        // Each ring, not the badge: the badge stays set across repeat rings.
        let rings = NotificationCenter.default.publisher(for: .ghosttyBellDidRing)
            .filter { [weak window] in
                // The split tree, not `surface.window`: a split hidden by zoom
                // is detached from the window but still rings.
                guard let surface = $0.object as? Ghostty.SurfaceView,
                      let tree = window?.terminalController?.surfaceTree else { return false }
                return tree.contains { $0 === surface }
            }
            .map { _ in () }
            .eraseToAnyPublisher()
        self.init(
            window: window,
            bell: window.terminalController?.$bell.eraseToAnyPublisher(),
            rings: rings,
            onChange: onChange)
    }

    /// - Parameters:
    ///   - bell: The tab's bell badge; changes only refresh the sidebar.
    ///   - rings: One event per bell ring in this tab; each is activity.
    init(
        window: NSWindow,
        bell: AnyPublisher<Bool, Never>?,
        rings: AnyPublisher<Void, Never>?,
        onChange: @escaping () -> Void
    ) {
        titleObservation = window.observe(\.title, options: [.old, .new]) { [weak self] _, change in
            // KVO fires on every assignment, even an unchanged one.
            guard VerticalTabs.titleChangeIsActivity(from: change.oldValue, to: change.newValue) else { return }
            // Spinner frames change the raw title often; record activity and let
            // the throttled refresh decide whether anything visible changed.
            self?.lastActive = Date()
            onChange()
        }
        bellCancellable = bell?
            .removeDuplicates()
            .dropFirst()
            .sink { _ in onChange() }
        // Focusing the tab clears the badge; only a ring is activity.
        ringCancellable = rings?.sink { [weak self] in
            self?.lastActive = Date()
            onChange()
        }
    }
}

// MARK: - Container access

extension TerminalWindow {
    var terminalViewContainerForVerticalTabs: TerminalViewContainer? {
        contentView as? TerminalViewContainer
    }
}
