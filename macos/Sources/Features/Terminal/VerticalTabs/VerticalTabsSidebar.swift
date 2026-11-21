import AppKit
import SwiftUI

/// The vertical tab sidebar: filter, Pinned / Recents / Open sections, and a
/// draggable divider on its trailing edge.
struct VerticalTabsSidebar: View {
    @ObservedObject var store: VerticalTabsStore
    @ObservedObject var settings: VerticalTabsSettings
    @FocusState private var filterFocused: Bool
    @State private var dragStartWidth: CGFloat?
    @State private var hoveringDivider = false

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The terminal-colored backdrop behind this view comes from WindowTracker.
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .trailing) { divider }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            TextField("Filter", text: $store.filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($filterFocused)
                .onSubmit { store.host?.submitFilter() }
                .onExitCommand { store.host?.cancelFilter() }
                .help("Filter tabs by title or folder (⌥⌘F)")

            Menu {
                Picker("Row Height", selection: $settings.density) {
                    Text("Compact").tag(VerticalTabsSettings.Density.compact)
                    Text("Tall").tag(VerticalTabsSettings.Density.tall)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Row density")

            Button { store.host?.newTab() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onChange(of: store.filterFocusRequest) { _ in filterFocused = true }
    }

    // MARK: List

    private var selection: Binding<ObjectIdentifier?> {
        Binding(
            get: { (store.pinned + store.recents + store.open).first(where: \.isSelected)?.id },
            set: { id in if let id { store.host?.select(id) } }
        )
    }

    private var isFiltering: Bool {
        !store.filter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var list: some View {
        List(selection: selection) {
            if isFiltering {
                ForEach(store.filteredRows) { row($0) }
            } else {
                if !store.pinned.isEmpty {
                    Section {
                        ForEach(store.pinned) { row($0) }
                            .onMove { store.host?.movePinned(fromOffsets: $0, toOffset: $1) }
                    } header: {
                        Text("Pinned")
                    }
                }

                if store.hasRecents {
                    Section {
                        if !settings.recentsCollapsed {
                            ForEach(store.recents) { row($0) }
                        }
                    } header: {
                        Button {
                            settings.recentsCollapsed.toggle()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: settings.recentsCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                Text("Recents")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    ForEach(store.open) { row($0) }
                        .onMove { store.host?.moveOpen(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Open Tabs")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, settings.density == .tall ? 40 : 24)
    }

    private func row(_ row: VerticalTabRow) -> some View {
        VerticalTabRowView(row: row, store: store, density: settings.density)
            .tag(row.id)
            .contextMenu {
                Button(row.isPinned ? "Unpin Tab" : "Pin Tab") { store.host?.togglePin(row.id) }
                Button("Rename Tab…") { store.renamingID = row.id }
                Divider()
                Button("Close Tab") { store.host?.close(row.id) }
                Button("Close Other Tabs") { store.host?.closeOthers(row.id) }
            }
    }

    // MARK: Divider

    private var divider: some View {
        ZStack(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            Color.clear
                .frame(width: 6)
                .contentShape(Rectangle())
                .onHover { inside in
                    guard inside != hoveringDivider else { return }
                    hoveringDivider = inside
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .onDisappear {
                    if hoveringDivider {
                        hoveringDivider = false
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStartWidth ?? settings.width
                            dragStartWidth = start
                            VerticalTabsManager.shared.setLiveWidth(
                                start + value.translation.width,
                                in: store.host?.tabGroup?.selectedWindow)
                        }
                        .onEnded { value in
                            let start = dragStartWidth ?? settings.width
                            dragStartWidth = nil
                            VerticalTabsManager.shared.commitWidth(start + value.translation.width)
                        }
                )
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Row

private struct VerticalTabRowView: View {
    let row: VerticalTabRow
    @ObservedObject var store: VerticalTabsStore
    let density: VerticalTabsSettings.Density

    @State private var hovering = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        Group {
            switch density {
            case .compact: compact
            case .tall: tall
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay(MiddleClickCatcher { store.host?.close(row.id) })
        .help(row.folder.map { "\(row.title) — \($0)" } ?? row.title)
    }

    private var compact: some View {
        HStack(spacing: 6) {
            glyph
            title
            Spacer(minLength: 4)
            if row.bell { bell }
            if let folder = row.folder { FolderPill(folder: folder) }
            trailing
        }
    }

    private var tall: some View {
        HStack(alignment: .center, spacing: 6) {
            glyph
            VStack(alignment: .leading, spacing: 3) {
                title
                HStack(spacing: 5) {
                    if let folder = row.folder { FolderPill(folder: folder) }
                    if row.bell { bell }
                    if let age = row.age {
                        Text(age).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 4)
            closeOrShortcut
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var title: some View {
        if store.renamingID == row.id {
            TextField("Tab title", text: $renameText)
                .textFieldStyle(.plain)
                .focused($renameFocused)
                .onAppear {
                    renameText = store.host?.renameText(for: row.id) ?? row.title
                    renameFocused = true
                }
                .onSubmit { finishRename(commit: true) }
                .onExitCommand { finishRename(commit: false) }
                .onChange(of: renameFocused) { focused in
                    if !focused, store.renamingID == row.id { finishRename(commit: true) }
                }
        } else {
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .fontWeight(row.isSelected ? .semibold : .regular)
        }
    }

    private func finishRename(commit: Bool) {
        if commit { store.host?.rename(row.id, to: renameText) }
        store.renamingID = nil
        store.host?.focusTerminal()
    }

    private var glyph: some View {
        Group {
            switch row.platform {
            case .agy: Text("✦").foregroundStyle(Color(hue: 0.58, saturation: 0.55, brightness: 0.95))
            case .claude: Text("✳").foregroundStyle(Color(hue: 0.05, saturation: 0.6, brightness: 0.95))
            case .terminal: Image(systemName: "terminal").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .frame(width: 14)
    }

    private var bell: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: 9))
            .foregroundStyle(.orange)
    }

    @ViewBuilder
    private var trailing: some View {
        if hovering {
            closeButton
        } else {
            if let age = row.age {
                Text(age).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            shortcut
        }
    }

    @ViewBuilder
    private var closeOrShortcut: some View {
        if hovering { closeButton } else { shortcut }
    }

    @ViewBuilder
    private var shortcut: some View {
        if let n = row.shortcut {
            Text("⌘\(n)").font(.caption2).foregroundStyle(.tertiary)
                .frame(minWidth: 20, alignment: .trailing)
        }
    }

    private var closeButton: some View {
        Button { store.host?.close(row.id) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Close Tab")
    }
}

/// A short folder name on a subtle, deterministic tint.
private struct FolderPill: View {
    let folder: String

    var body: some View {
        let hue = VerticalTabs.hue(for: folder)
        Text(folder)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(Color(hue: hue, saturation: 0.35, brightness: 0.95))
            .background(
                Capsule().fill(Color(hue: hue, saturation: 0.5, brightness: 0.6).opacity(0.25))
            )
            .fixedSize()
    }
}

/// Catches middle clicks over a row without blocking anything else: hit testing
/// only claims the point while a middle-button event is being dispatched.
private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only the middle button; extra buttons (3, 4: back/forward) pass through.
            guard let event = NSApp.currentEvent, event.buttonNumber == 2 else { return nil }
            switch event.type {
            case .otherMouseDown, .otherMouseUp: return super.hitTest(point)
            default: return nil
            }
        }

        override func otherMouseDown(with event: NSEvent) {}

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2 else { return }
            action?()
        }
    }
}
