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
    private var ageTimer: Timer?
    private var recentsCollapsedCancellable: AnyCancellable?
    private var started = false

    var isEnabled: Bool { settings.enabled }

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

        // Collapsing Recents moves its tabs back into Open (and renumbers them).
        recentsCollapsedCancellable = settings.$recentsCollapsed
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshAll() } }

        if isEnabled { applyEnabled() }
    }

    func toggle() {
        settings.enabled.toggle()
        applyEnabled()
    }

    private func applyEnabled() {
        for window in terminalWindows {
            window.terminalViewContainerForVerticalTabs?.leadingInset = leadingInset(for: window)
            syncTabBar(of: window)
        }

        if isEnabled {
            ageTimer?.invalidate()
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refreshAll() }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            ageTimer = timer
            refreshAll()
        } else {
            ageTimer?.invalidate()
            ageTimer = nil
            hosts.values.forEach { $0.tearDown() }
            hosts = [:]
            trackers.values.forEach { $0.removeBackdrop() }
            trackers = [:]

            // The filter or rename field may have had focus; give it back to the terminal.
            for window in terminalWindows where !(window.firstResponder is Ghostty.SurfaceView) {
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

    /// `goto_tab:N` / `last_tab` in vertical mode: Pinned then Open, skipping Recents.
    func window(for shortcut: VerticalTabs.Shortcut, in tabGroup: NSWindowTabGroup) -> NSWindow? {
        guard isEnabled else { return nil }
        let host = host(for: tabGroup)
        host.refresh()
        return host.window(for: shortcut)
    }

    // MARK: Windows

    private var terminalWindows: [TerminalWindow] {
        NSApp.windows.compactMap { $0 as? TerminalWindow }
    }

    private func windowDidBecomeMain(_ window: TerminalWindow) {
        guard isEnabled, window.tabbingMode != .disallowed, let tabGroup = window.tabGroup else { return }
        tracker(for: window).lastFocused = Date()
        tracker(for: window).lastActive = Date()
        syncTabBar(of: window)
        let inset = leadingInset(for: window)
        if window.terminalViewContainerForVerticalTabs?.leadingInset != inset {
            window.terminalViewContainerForVerticalTabs?.leadingInset = inset
        }
        let host = host(for: tabGroup)
        host.attach(to: window)
        host.refresh()
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
        trackers[key] = tracker
        return tracker
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
    var lastFocused: Date?
    var lastActive: Date?
    /// The pin key this tab matched on the last refresh.
    var claimedPinKey: String?

    private var titleObservation: NSKeyValueObservation?
    private var bellCancellable: AnyCancellable?

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

    init(window: TerminalWindow, onChange: @escaping () -> Void) {
        titleObservation = window.observe(\.title, options: [.new]) { [weak self] _, _ in
            // Spinner frames change the raw title often; record activity and let
            // the throttled refresh decide whether anything visible changed.
            self?.lastActive = Date()
            onChange()
        }
        bellCancellable = window.terminalController?.$bell
            .removeDuplicates()
            .dropFirst()
            .sink { _ in onChange() }
    }
}

// MARK: - Container access

extension TerminalWindow {
    var terminalViewContainerForVerticalTabs: TerminalViewContainer? {
        contentView as? TerminalViewContainer
    }
}
