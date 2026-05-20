import AppKit

extension TerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabID: String?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        init(
            focusedSurface: String?,
            surfaceTree: SplitTree<ViewType>,
            effectiveFullscreenMode: FullscreenMode?,
            tabID: String? = nil,
            tabColor: TerminalTabColor?,
            titleOverride: String?,
        ) {
            self.focusedSurface = focusedSurface
            self.surfaceTree = surfaceTree
            self.effectiveFullscreenMode = effectiveFullscreenMode
            self.tabID = tabID
            self.tabColor = tabColor
            self.titleOverride = titleOverride
        }
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: TerminalController) {
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabID: (controller.window as? TerminalWindow)?.tabID.uuidString,
            tabColor: (controller.window as? TerminalWindow)?.tabColor,
            titleOverride: controller.titleOverride,
        )
    }
}
