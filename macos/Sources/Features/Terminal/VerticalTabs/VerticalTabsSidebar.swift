import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

            viewOptions

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

    private var viewOptions: some View {
        Menu {
            Picker("Row Height", selection: $settings.density) {
                Text("Compact").tag(VerticalTabsSettings.Density.compact)
                Text("Tall").tag(VerticalTabsSettings.Density.tall)
            }
            .pickerStyle(.inline)

            Picker("Text Size", selection: $settings.textSizeChoice) {
                if let size = settings.config.fontSize {
                    Text("Config (\(VerticalTabsSettings.pointLabel(size)))")
                        .tag(VerticalTabsSettings.TextSize?.none)
                }
                Text("Small").tag(VerticalTabsSettings.TextSize?.some(.small))
                Text("Medium").tag(VerticalTabsSettings.TextSize?.some(.medium))
                Text("Large").tag(VerticalTabsSettings.TextSize?.some(.large))
            }
            .pickerStyle(.inline)

            Divider()

            Toggle("Project Labels", isOn: $settings.showFolders)
            Toggle("Idle Time", isOn: $settings.showIdleTime)
            Toggle("Shortcuts", isOn: $settings.showShortcuts)
            Toggle("Icons", isOn: $settings.showIcons)
            Toggle("Recents", isOn: $settings.showRecents)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("View Options")
    }

    // MARK: List

    private var isFiltering: Bool {
        !store.filter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A plain stack rather than `List`: `NSTableView` animates selection and
    /// redraws its highlight when the sidebar moves between tab windows.
    private var list: some View {
        ScrollViewReader { proxy in
            stack
                // Keyboard and filter selection can land offscreen; follow it.
                .onChange(of: selectedID) { id in
                    if let id { proxy.scrollTo(id) }
                }
        }
    }

    private var selectedID: ObjectIdentifier? {
        (store.pinned + store.recents + store.open).first(where: \.isSelected)?.id
    }

    private var stack: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if isFiltering {
                    rows(store.filteredRows, section: nil, move: nil)
                } else {
                    if !store.pinned.isEmpty {
                        sectionHeader { Text("Pinned") }
                        rows(store.pinned, section: \.pinned) { store.host?.movePinned(fromOffsets: $0, toOffset: $1) }
                    }

                    if store.hasRecents {
                        sectionHeader { recentsHeader }
                        if !settings.recentsCollapsed {
                            rows(store.recents, section: nil, move: nil)
                        }
                    }

                    sectionHeader { Text("Open Tabs") }
                    rows(store.open, section: \.open) { store.host?.moveOpen(fromOffsets: $0, toOffset: $1) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        // Row and section changes land in one frame, never animated.
        .transaction { $0.animation = nil }
    }

    private func sectionHeader<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        label()
            .font(.system(size: max(10, settings.secondaryFontSize), weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, metrics.rowPadding)
            .padding(.top, metrics.headerTop)
            .padding(.bottom, metrics.headerBottom)
    }

    private var recentsHeader: some View {
        Button {
            settings.recentsCollapsed.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: settings.recentsCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: max(8, settings.secondaryFontSize - 3), weight: .bold))
                Text("Recents")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var metrics: VerticalTabsMetrics {
        VerticalTabsMetrics(fontSize: settings.fontSize, secondarySize: settings.secondaryFontSize)
    }

    private var rowStyle: VerticalTabRowStyle {
        VerticalTabRowStyle(
            density: settings.density,
            metrics: metrics,
            pillMaxChars: settings.config.pillMaxChars,
            pillMaxWidth: settings.width * 0.4,
            showFolders: settings.showFolders,
            showIdleTime: settings.showIdleTime,
            showShortcuts: settings.showShortcuts,
            showIcons: settings.showIcons)
    }

    /// - Parameters:
    ///   - section: the store's rows for this section, read again when a drop lands.
    ///   - move: reorders this section (`onMove` offsets); nil when it can't be reordered.
    @ViewBuilder
    private func rows(
        _ rows: [VerticalTabRow],
        section: KeyPath<VerticalTabsStore, [VerticalTabRow]>?,
        move: ((IndexSet, Int) -> Void)?
    ) -> some View {
        ForEach(rows) { row in
            let view = self.row(row).id(row.id)
            if let section, let move {
                view
                    .onDrag {
                        let payload = VerticalTabsDrop.marker + UUID().uuidString
                        store.draggingID = row.id
                        store.dragPayload = payload
                        return NSItemProvider(object: payload as NSString)
                    }
                    .onDrop(of: [.text], delegate: VerticalTabsDrop(
                        target: row.id, section: section, store: store, move: move))
            } else {
                view
            }
        }
    }

    private func row(_ row: VerticalTabRow) -> some View {
        VerticalTabRowView(row: row, store: store, style: rowStyle)
            .contextMenu {
                Button(row.isPinned ? "Unpin Tab" : "Pin Tab") { store.host?.togglePin(row.id) }
                Button("Rename Tab…") { store.renamingID = row.id }
                Divider()
                Button("Copy Title") { store.host?.copyTitle(row.id) }
                Button("Copy ID") { store.host?.copyID(row.id) }
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

/// Sidebar spacing in proportion to the text, like CSS `em`s, so every text
/// size gets the same rhythm.
struct VerticalTabsMetrics: Equatable {
    let fontSize: CGFloat
    let secondarySize: CGFloat

    var minRowHeight: CGFloat { (fontSize * 1.9).rounded() }
    /// Space between rows. Each row pads half of it, so the gap (and the drop
    /// indicator drawn in it) stays inside a row's drop target.
    var rowGap: CGFloat { max(2, (fontSize * 0.18).rounded()) }
    var rowPadding: CGFloat { (fontSize * 0.55).rounded() }
    var itemSpacing: CGFloat { (fontSize * 0.42).rounded() }
    var spacerMin: CGFloat { max(3, (fontSize * 0.28).rounded()) }
    var cornerRadius: CGFloat { (fontSize * 0.48).rounded() }
    /// About three characters and an ellipsis.
    var titleMinWidth: CGFloat { (fontSize * 2.5).rounded() }
    var pillHorizontalPadding: CGFloat { (secondarySize * 0.48).rounded() }
    var pillVerticalPadding: CGFloat { max(1, (secondarySize * 0.14).rounded()) }
    /// A section header's own padding; with the neighboring rows' half gaps the
    /// header sits ~0.55em below the previous section and ~0.2em above its rows.
    var headerTop: CGFloat { max(2, (fontSize * 0.55).rounded() - rowGap / 2) }
    var headerBottom: CGFloat { max(1, (fontSize * 0.2).rounded() - rowGap / 2) }
}

/// How rows draw, from the View Options menu.
private struct VerticalTabRowStyle: Equatable {
    let density: VerticalTabsSettings.Density
    let metrics: VerticalTabsMetrics
    var fontSize: CGFloat { metrics.fontSize }
    var secondarySize: CGFloat { metrics.secondarySize }
    let pillMaxChars: Int
    /// Keeps most of the row for the title at any font size or cap.
    let pillMaxWidth: CGFloat
    let showFolders: Bool
    let showIdleTime: Bool
    let showShortcuts: Bool
    let showIcons: Bool

}

private struct VerticalTabRowView: View {
    let row: VerticalTabRow
    @ObservedObject var store: VerticalTabsStore
    let style: VerticalTabRowStyle

    @State private var hovering = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    private var folder: String? { style.showFolders ? row.folder : nil }
    private var age: String? { style.showIdleTime ? row.age : nil }
    private var shortcutNumber: Int? { style.showShortcuts ? row.shortcut : nil }

    var body: some View {
        Group {
            switch style.density {
            case .compact: compact
            case .tall: tall
            }
        }
        .padding(.horizontal, style.metrics.rowPadding)
        .frame(maxWidth: .infinity, minHeight: style.metrics.minRowHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: style.metrics.cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(row.isSelected ? 0.11 : hovering ? 0.05 : 0))
        )
        .overlay(alignment: dropAfter ? .bottom : .top) { dropIndicator }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard store.renamingID != row.id else { return }
            store.host?.select(row.id)
        }
        // One button per row for VoiceOver and Full Keyboard Access (List gave us this).
        .accessibilityElement(children: store.renamingID == row.id ? .contain : .combine)
        .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.host?.select(row.id) }
        .accessibilityAction(named: "Close Tab") { store.host?.close(row.id) }
        .overlay(MiddleClickCatcher { store.host?.close(row.id) })
        .help(tooltip)
        // The gap between rows belongs to their drag and drop targets (outside
        // hover, clicks and middle-click close), so dropping on the indicator
        // line never lands outside a row.
        .padding(.vertical, style.metrics.rowGap / 2)
        .contentShape(Rectangle())
    }

    /// Everything a narrow row may hide.
    private var tooltip: String {
        let main = row.folder.map { "\(row.title) — \($0)" } ?? row.title
        return age.map { "\(main) · \($0)" } ?? main
    }

    private var dropAfter: Bool { store.dropTarget?.after ?? false }

    @ViewBuilder
    private var dropIndicator: some View {
        if store.dropTarget?.id == row.id {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                // Into the row's half of the gap, inside its own drop target.
                .offset(y: (dropAfter ? 1 : -1) * style.metrics.rowGap / 2)
                .allowsHitTesting(false)
        }
    }

    /// Drops the pill, then the age, before the title shrinks below
    /// `titleMinWidth` (the tooltip keeps both), and the icon last, so a row
    /// fits even the narrowest sidebar at the largest text size.
    @ViewBuilder
    private var compact: some View {
        if store.renamingID == row.id {
            // One editor (a hover can't swap branches and reset the draft),
            // with the row to itself; Return and Esc finish it.
            HStack(spacing: style.metrics.itemSpacing) {
                if style.showIcons { glyph }
                title(minWidth: 0).layoutPriority(1)
            }
        } else {
            fittingCompact
        }
    }

    private var fittingCompact: some View {
        let keep = style.metrics.titleMinWidth
        // Room for a letter and an ellipsis before the icon goes.
        let glimpse = style.fontSize
        return ViewThatFits(in: .horizontal) {
            if folder != nil { compactRow(pill: true, age: true, titleMin: keep, measured: keep) }
            compactRow(pill: false, age: true, titleMin: keep, measured: keep)
            compactRow(pill: false, age: false, titleMin: 0, measured: glimpse)
            if style.showIcons { compactRow(pill: false, age: false, titleMin: 0, measured: 0, icon: false) }
        }
    }

    /// - Parameters:
    ///   - titleMin: the title never gets less.
    ///   - measured: the title width `ViewThatFits` checks for, so a long
    ///     title doesn't rule out a fallback that fits it truncated.
    private func compactRow(
        pill: Bool, age showAge: Bool, titleMin: CGFloat, measured: CGFloat, icon: Bool = true
    ) -> some View {
        HStack(spacing: style.metrics.itemSpacing) {
            if icon, style.showIcons { glyph }
            title(minWidth: titleMin, measuredWidth: measured)
            Spacer(minLength: style.metrics.spacerMin)
            if row.bell { bell }
            if pill, let folder { FolderPill(folder: folder, style: style) }
            trailing(age: showAge)
        }
    }

    private var tall: some View {
        HStack(alignment: .center, spacing: style.metrics.itemSpacing) {
            if style.showIcons { glyph }
            VStack(alignment: .leading, spacing: 2) {
                title(minWidth: 0)
                if folder != nil || row.bell || age != nil {
                    HStack(spacing: style.metrics.itemSpacing) {
                        if let folder { FolderPill(folder: folder, style: style) }
                        if row.bell { bell }
                        if let age { ageText(age) }
                    }
                }
            }
            Spacer(minLength: style.metrics.spacerMin)
            closeOrShortcut
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    /// - Parameter measuredWidth: the ideal width `ViewThatFits` measures; nil for the text's own.
    private func title(minWidth: CGFloat, measuredWidth: CGFloat? = nil) -> some View {
        if store.renamingID == row.id {
            TextField("Tab title", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: style.fontSize))
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
                .font(.system(size: style.fontSize, weight: row.isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: minWidth, idealWidth: measuredWidth, alignment: .leading)
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
        .font(.system(size: style.secondarySize))
        .frame(width: style.fontSize + 1)
    }

    private var bell: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: style.secondarySize - 1))
            .foregroundStyle(.orange)
    }

    private func ageText(_ age: String) -> some View {
        Text(age)
            .font(.system(size: style.secondarySize))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
    }

    @ViewBuilder
    private func trailing(age showAge: Bool) -> some View {
        if hovering {
            closeButton
        } else {
            if showAge, let age { ageText(age) }
            shortcut
        }
    }

    @ViewBuilder
    private var closeOrShortcut: some View {
        if hovering { closeButton } else { shortcut }
    }

    @ViewBuilder
    private var shortcut: some View {
        if let n = shortcutNumber {
            Text("⌘\(n)")
                .font(.system(size: style.secondarySize))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .fixedSize()
        }
    }

    private var closeButton: some View {
        Button { store.host?.close(row.id) } label: {
            Image(systemName: "xmark")
                .font(.system(size: style.secondarySize - 1, weight: .semibold))
                .frame(width: max(16, style.secondarySize + 5), height: max(14, style.secondarySize + 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Close Tab")
    }
}

/// A short folder name on a subtle, deterministic tint.
private struct FolderPill: View {
    let folder: String
    let style: VerticalTabRowStyle

    var body: some View {
        let hue = VerticalTabs.hue(for: folder)
        // Natural width up to `pillMaxWidth`, ahead of the title; past that it
        // truncates (the row's tooltip has the full folder).
        VerticalTabsWidthLimit(max: style.pillMaxWidth) {
            Text(VerticalTabs.pillText(folder, maxChars: style.pillMaxChars))
                .font(.system(size: style.secondarySize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, style.metrics.pillHorizontalPadding)
                .padding(.vertical, style.metrics.pillVerticalPadding)
                .foregroundStyle(Color(hue: hue, saturation: 0.35, brightness: 0.95))
                .background(
                    Capsule().fill(Color(hue: hue, saturation: 0.5, brightness: 0.6).opacity(0.25))
                )
        }
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }
}

/// Sizes its one subview to its natural width, but never wider than `max`.
/// (`frame(maxWidth:)` would reserve the whole `max` once it gets priority.)
struct VerticalTabsWidthLimit: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? .infinity, max)
        return subviews.first?.sizeThatFits(.init(width: width, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: .init(bounds.size))
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

/// Drag-to-reorder within one section. The dragged row's ID lives in the
/// store; the pasteboard carries a per-drag token, so a cancelled drag's
/// stale ID can't turn a later text drop into a reorder.
private struct VerticalTabsDrop: DropDelegate {
    static let marker = "ghostty-vertical-tab:"

    let target: ObjectIdentifier
    /// The section's rows, in order, as the store has them now.
    let section: KeyPath<VerticalTabsStore, [VerticalTabRow]>
    let store: VerticalTabsStore
    let move: (IndexSet, Int) -> Void

    private var offsets: (from: Int, to: Int)? {
        store.draggingID.flatMap { Self.offsets(moving: $0, onto: target, in: store[keyPath: section]) }
    }

    private static func offsets(
        moving source: ObjectIdentifier, onto target: ObjectIdentifier, in rows: [VerticalTabRow]
    ) -> (from: Int, to: Int)? {
        guard let from = rows.firstIndex(where: { $0.id == source }),
              let to = rows.firstIndex(where: { $0.id == target }) else { return nil }
        return (from, to)
    }

    func validateDrop(info: DropInfo) -> Bool { offsets != nil }

    func dropEntered(info: DropInfo) {
        guard let offsets, offsets.from != offsets.to else { return }
        let next = VerticalTabsStore.DropTarget(id: target, after: offsets.from < offsets.to)
        if store.dropTarget != next { store.dropTarget = next }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: offsets == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        if store.dropTarget?.id == target { store.dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let source = store.draggingID
        let expected = store.dragPayload
        store.dropTarget = nil
        store.draggingID = nil
        store.dragPayload = nil
        guard let source, source != target, let expected,
              let provider = info.itemProviders(for: [.text]).first else { return false }
        let (store, section, target, move) = (store, section, target, move)
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard (object as? NSString) as String? == expected else { return }
            DispatchQueue.main.async {
                // Tabs may have closed or moved while the payload loaded: use
                // current offsets, and drop the move if either row left.
                guard let offsets = Self.offsets(moving: source, onto: target, in: store[keyPath: section]),
                      offsets.from != offsets.to else { return }
                // `onMove` semantics: insert before the destination offset.
                move(IndexSet(integer: offsets.from), offsets.from < offsets.to ? offsets.to + 1 : offsets.to)
            }
        }
        return true
    }
}
