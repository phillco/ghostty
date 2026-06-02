import SwiftUI
import GhosttyKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Ghostty.SurfaceView)

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }

    /// The custom tab overview state.
    var tabOverviewIsShowing: Bool { get set }

    /// The update overlay should be visible.
    var updateOverlayIsVisible: Bool { get }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)?

    /// The most recently focused surface, equal to `focusedSurface` when it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            ZStack {
                VStack(spacing: 0) {
                    // If we're running in debug mode we show a warning so that users
                    // know that performance will be degraded.
                    if Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
                        DebugBuildWarningView()
                    }

                    TerminalSplitTreeView(
                        tree: viewModel.surfaceTree,
                        action: { delegate?.performSplitAction($0) })
                        .environmentObject(ghostty)
                        .ghosttyLastFocusedSurface(lastFocusedSurface)
                        .focused($focused)
                        .onAppear { self.focused = true }
                        .onChange(of: focusedSurface) { newValue in
                            // We want to keep track of our last focused surface so even if
                            // we lose focus we keep this set to the last non-nil value.
                            if newValue != nil {
                                lastFocusedSurface = .init(newValue)
                                self.delegate?.focusedSurfaceDidChange(to: newValue)
                            }
                        }
                        .onChange(of: pwdURL) { newValue in
                            self.delegate?.pwdDidChange(to: newValue)
                        }
                        .onChange(of: cellSize) { newValue in
                            guard let size = newValue else { return }
                            self.delegate?.cellSizeDidChange(to: size)
                        }
                        .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                               idealHeight: lastFocusedSurface?.value?.initialSize?.height)
                }
                // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
                .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == .hidden ? .top : [])

                if let surfaceView = lastFocusedSurface?.value {
                    TerminalCommandPaletteView(
                        surfaceView: surfaceView,
                        isPresented: $viewModel.commandPaletteIsShowing,
                        ghosttyConfig: ghostty.config,
                        updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                        self.delegate?.performAction(action, on: surfaceView)
                    }
                }

                if let surfaceView = lastFocusedSurface?.value,
                   let controller = viewModel as? TerminalController {
                    TerminalTabOverviewView(
                        controller: controller,
                        sourceSurface: surfaceView,
                        isPresented: $viewModel.tabOverviewIsShowing
                    )
                }

                // Show update information above all else.
                if viewModel.updateOverlayIsVisible {
                    UpdateOverlay()
                }
            }
            .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
        }
    }
}

private struct TerminalTabOverviewItem: Identifiable {
    let id: UUID
    let title: String
    let workingDirectory: String?
    let shortcut: String?
    let snapshot: NSImage?
    let selected: Bool
    let focus: () -> Void
}

private struct TerminalTabOverviewView: View {
    let controller: TerminalController
    let sourceSurface: Ghostty.SurfaceView
    @Binding var isPresented: Bool

    @State private var items: [TerminalTabOverviewItem] = []
    @State private var selectedIndex: Int = 0
    private let thumbnailRefresh = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    var body: some View {
        ZStack {
            if isPresented {
                Color.black.opacity(0.58)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }

                ScrollView {
                    Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                        ForEach(Array(stride(from: 0, to: items.count, by: 3)), id: \.self) { rowStart in
                            GridRow {
                                ForEach(rowStart..<min(rowStart + 3, items.count), id: \.self) { index in
                                    tabCard(at: index)
                                }
                            }
                        }
                    }
                    .padding(32)
                }
                .background(.black.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.12))
                )
                .padding(24)
                .onAppear {
                    reloadItems()
                }
                .onChange(of: isPresented) { shown in
                    if shown {
                        reloadItems()
                    } else {
                        restoreSurfaceFocus()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: Ghostty.Notification.ghosttyTabOverviewMove, object: controller)) { notification in
                    guard let amount = notification.userInfo?["amount"] as? Int else { return }
                    moveSelection(by: amount)
                }
                .onReceive(NotificationCenter.default.publisher(for: Ghostty.Notification.ghosttyTabOverviewSelect, object: controller)) { notification in
                    guard let index = notification.userInfo?["index"] as? Int else { return }
                    guard items.indices.contains(index) else { return }
                    selectedIndex = index
                }
                .onReceive(NotificationCenter.default.publisher(for: Ghostty.Notification.ghosttyTabOverviewActivate, object: controller)) { _ in
                    activateSelection()
                }
                .onReceive(thumbnailRefresh) { _ in
                    reloadItems(preservingSelection: true)
                }
            }
        }
    }

    @ViewBuilder
    private func tabCard(at index: Int) -> some View {
        let item = items[index]
        TabCard(item: item, selected: index == selectedIndex)
            .onTapGesture { activate(index) }
            .onHover { hovering in
                guard hovering else { return }
                selectedIndex = index
            }
    }

    private func reloadItems(preservingSelection: Bool = false) {
        let selectedID = preservingSelection && items.indices.contains(selectedIndex)
            ? items[selectedIndex].id
            : nil
        let selectedWindow = controller.window?.tabGroup?.selectedWindow ?? controller.window
        let windows = controller.window?.tabGroup?.windows ?? controller.window.map { [$0] } ?? []
        items = windows.enumerated().compactMap { index, window -> TerminalTabOverviewItem? in
            guard let terminalWindow = window as? TerminalWindow,
                  let tabController = terminalWindow.windowController as? TerminalController
            else {
                return nil
            }

            let surface = tabController.focusedSurface ?? tabController.surfaceTree.first
            let title = tabController.titleOverride?.isEmpty == false
                ? tabController.titleOverride!
                : (terminalWindow.title.isEmpty ? "Untitled" : terminalWindow.title)
            let shortcut: String? = switch index {
            case 0...8: String(index + 1)
            case 9: "0"
            default: nil
            }
            let snapshot = if terminalWindow === controller.window {
                // The overview lives in the active tab's content view. Taking
                // a screenshot of that view here would recursively draw the
                // overview back into its own thumbnail.
                surface?.asImage
            } else {
                terminalWindow.contentView?.screenshot() ?? surface?.asImage
            }

            return TerminalTabOverviewItem(
                id: terminalWindow.tabID,
                title: title,
                workingDirectory: surface?.pwd?.abbreviatedPath,
                shortcut: shortcut,
                snapshot: snapshot,
                selected: terminalWindow === selectedWindow,
                focus: { [weak terminalWindow, weak surface] in
                    terminalWindow?.makeKeyAndOrderFront(nil)
                    if let surface {
                        Ghostty.moveFocus(to: surface)
                    }
                }
            )
        }

        if let selectedID,
           let refreshedIndex = items.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = refreshedIndex
        } else {
            selectedIndex = items.firstIndex(where: \.selected) ?? 0
        }
    }

    private func moveSelection(by amount: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + amount), items.count - 1)
    }

    private func activateSelection() {
        activate(selectedIndex)
    }

    private func activate(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        isPresented = false
        DispatchQueue.main.async {
            item.focus()
        }
    }

    private func dismiss() {
        isPresented = false
    }

    private func restoreSurfaceFocus() {
        DispatchQueue.main.async {
            sourceSurface.window?.makeFirstResponder(sourceSurface)
        }
    }

    private struct TabCard: View {
        let item: TerminalTabOverviewItem
        let selected: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    preview
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1.65, contentMode: .fit)
                        .clipped()
                    if let shortcut = item.shortcut {
                        Text(shortcut)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(selected ? .black : .white)
                            .frame(width: 24, height: 22)
                            .background(selected ? Color.yellow : Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(10)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let workingDirectory = item.workingDirectory {
                        Text(workingDirectory)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
            }
            .background(.black.opacity(selected ? 0.62 : 0.44))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? .yellow : .white.opacity(0.12), lineWidth: selected ? 3 : 1)
            )
        }

        @ViewBuilder
        private var preview: some View {
            if let snapshot = item.snapshot {
                Image(nsImage: snapshot)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.24))
            } else {
                Rectangle()
                    .fill(.white.opacity(0.06))
            }
        }
    }
}

private struct UpdateOverlay: View {
    var body: some View {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            VStack {
                Spacer()

                HStack {
                    Spacer()
                    UpdatePill(model: appDelegate.updateViewModel)
                        .padding(.bottom, 9)
                        .padding(.trailing, 9)
                }
            }
        }
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Ghostty! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Ghostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Ghostty are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
