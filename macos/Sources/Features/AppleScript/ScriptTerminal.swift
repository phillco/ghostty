import AppKit

/// AppleScript-facing wrapper around a live Ghostty terminal surface.
///
/// This class is intentionally ObjC-visible because Cocoa scripting resolves
/// AppleScript objects through Objective-C runtime names/selectors, not Swift
/// protocol conformance.
///
/// Mapping from `Ghostty.sdef`:
/// - `class terminal` -> this class (`@objc(GhosttyAppleScriptTerminal)`).
/// - `property id` -> `@objc(id)` getter below.
/// - `property title` -> `@objc(title)` getter below.
/// - `property working directory` -> `@objc(workingDirectory)` getter below.
/// - `property variables` -> `@objc(sessionVariables)` getter below.
///
/// We keep only a weak reference to the underlying `SurfaceView` so this
/// wrapper never extends the terminal's lifetime.
@MainActor
@objc(GhosttyScriptTerminal)
final class ScriptTerminal: NSObject {
    /// Weak reference to the underlying surface. Package-visible so that
    /// other AppleScript command handlers (e.g. `ScriptSplitCommand`) can
    /// access the live surface without exposing it to ObjC/AppleScript.
    weak var surfaceView: Ghostty.SurfaceView?

    init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
    }

    /// Exposed as the AppleScript `id` property.
    ///
    /// This is a stable UUID string for the life of a surface and is also used
    /// by `NSUniqueIDSpecifier` to re-identify a terminal object in scripts.
    @objc(id)
    var stableID: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return surfaceView?.id.uuidString ?? ""
    }

    /// Exposed as the AppleScript `title` property.
    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return surfaceView?.title ?? ""
    }

    /// Exposed as the AppleScript `working directory` property.
    ///
    /// The `sdef` uses a spaced name, but Cocoa scripting maps that to the
    /// camel-cased selector name `workingDirectory`.
    @objc(workingDirectory)
    var workingDirectory: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return surfaceView?.pwd ?? ""
    }

    /// Exposed as the AppleScript `variables` property.
    @objc(sessionVariables)
    var sessionVariables: NSDictionary {
        guard NSApp.isAppleScriptEnabled else { return [:] }
        guard let surface = surfaceView?.surfaceModel else { return [:] }
        return surface.sessionVariables as NSDictionary
    }

    func sessionVariable(name: String) -> String? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let surface = surfaceView?.surfaceModel else { return nil }
        return surface.sessionVariable(name: name)
    }

    func setSessionVariable(name: String, value: String) -> Bool {
        guard NSApp.isAppleScriptEnabled else { return false }
        guard let surface = surfaceView?.surfaceModel else { return false }
        return surface.setSessionVariable(name: name, value: value)
    }

    /// Exposed as the AppleScript `tab color` property.
    @objc(tabColor)
    var tabColor: FourCharCode {
        get {
            guard NSApp.isAppleScriptEnabled else { return TerminalTabColor.none.appleScriptCode }
            guard let terminalWindow = surfaceView?.window as? TerminalWindow else {
                return TerminalTabColor.none.appleScriptCode
            }
            return terminalWindow.tabColor.appleScriptCode
        }
        set {
            guard NSApp.isAppleScriptEnabled else { return }
            guard let tabColor = TerminalTabColor(appleScriptCode: newValue) else { return }
            guard let terminalWindow = surfaceView?.window as? TerminalWindow else { return }
            terminalWindow.tabColor = tabColor
        }
    }

    /// Used by command handling (`perform action ... on <terminal>`).
    func perform(action: String) -> Bool {
        guard NSApp.isAppleScriptEnabled else { return false }
        if performSessionVariableAction(action) { return true }
        guard let surfaceModel = surfaceView?.surfaceModel else { return false }
        return surfaceModel.perform(action: action)
    }

    private func performSessionVariableAction(_ action: String) -> Bool {
        let prefix = "set_session_variable:"
        guard action.hasPrefix(prefix) else { return false }
        let payload = action.dropFirst(prefix.count)
        guard let separator = payload.firstIndex(of: "=") else { return false }

        let name = String(payload[..<separator])
        guard !name.isEmpty else { return false }
        let valueStart = payload.index(after: separator)
        let value = String(payload[valueStart...])
        return setSessionVariable(name: name, value: value)
    }

    /// Handler for `split <terminal> direction <dir>`.
    @objc(handleSplitCommand:)
    func handleSplit(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let directionCode = command.evaluatedArguments?["direction"] as? UInt32 else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing or unknown split direction."
            return nil
        }

        guard let direction = ScriptSplitDirection(code: directionCode)?.splitDirection else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing or unknown split direction."
            return nil
        }

        let baseConfig: Ghostty.SurfaceConfiguration?
        if let scriptRecord = command.evaluatedArguments?["configuration"] as? NSDictionary {
            do {
                baseConfig = try Ghostty.SurfaceConfiguration(scriptRecord: scriptRecord)
            } catch {
                command.scriptErrorNumber = errAECoercionFail
                command.scriptErrorString = error.localizedDescription
                return nil
            }
        } else {
            baseConfig = nil
        }

        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is not in a splittable window."
            return nil
        }

        guard let newView = controller.newSplit(
            at: surfaceView,
            direction: direction,
            baseConfig: baseConfig
        ) else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Failed to create split."
            return nil
        }

        return ScriptTerminal(surfaceView: newView)
    }

    /// Handler for `set split percentage <terminal> percentage <n>`.
    @objc(handleSetSplitPercentageCommand:)
    func handleSetSplitPercentage(_ command: NSScriptCommand) -> NSNumber? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let percentage = command.evaluatedArguments?["percentage"] as? Double else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing split percentage."
            return nil
        }

        guard percentage > 0, percentage < 100 else {
            command.scriptErrorNumber = errAECoercionFail
            command.scriptErrorString = "Split percentage must be greater than 0 and less than 100."
            return nil
        }

        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is not in a splittable window."
            return nil
        }

        guard controller.setSplitPercentage(containing: surfaceView, to: percentage) else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal must be part of a split."
            return nil
        }

        return NSNumber(value: true)
    }

    /// Handler for `rotate split <terminal>`.
    @objc(handleRotateSplitCommand:)
    func handleRotateSplit(_ command: NSScriptCommand) -> NSNumber? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is not in a splittable window."
            return nil
        }

        guard controller.rotateSplit(containing: surfaceView) else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal must be part of a split."
            return nil
        }

        return NSNumber(value: true)
    }

    /// Handler for `set split layout <terminal> layout <rows|columns>`.
    @objc(handleSetSplitLayoutCommand:)
    func handleSetSplitLayout(_ command: NSScriptCommand) -> NSNumber? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let layoutCode = command.evaluatedArguments?["layout"] as? UInt32,
              let layout = ScriptSplitLayout(code: layoutCode) else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing or unknown split layout."
            return nil
        }

        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is not in a splittable window."
            return nil
        }

        guard controller.setSplitLayout(containing: surfaceView, to: layout.splitDirection) else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal must be part of a split."
            return nil
        }

        return NSNumber(value: true)
    }

    /// Handler for `equalize split <terminal>`.
    @objc(handleEqualizeSplitCommand:)
    func handleEqualizeSplit(_ command: NSScriptCommand) -> NSNumber? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is not in a splittable window."
            return nil
        }

        guard controller.equalizeSplit(containing: surfaceView) else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal must be part of a split."
            return nil
        }

        return NSNumber(value: true)
    }

    /// Handler for `promote to separate tab <terminal>`.
    @objc(handlePromoteToSeparateTabCommand:)
    func handlePromoteToSeparateTab(_ command: NSScriptCommand) -> Any? {
        handlePromote(command, destination: .separateTab)
    }

    /// Handler for `promote to new window <terminal>`.
    @objc(handlePromoteToNewWindowCommand:)
    func handlePromoteToNewWindow(_ command: NSScriptCommand) -> Any? {
        handlePromote(command, destination: .newWindow)
    }

    private func handlePromote(
        _ command: NSScriptCommand,
        destination: ScriptPromotionDestination
    ) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        switch destination {
        case .newWindow:
            guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
                command.scriptErrorNumber = errAEEventFailed
                command.scriptErrorString = "Terminal is not in a movable window."
                return nil
            }

            guard controller.promoteSurfaceToNewWindow(surfaceView) != nil else {
                command.scriptErrorNumber = errAEEventFailed
                command.scriptErrorString = "Terminal must be part of a split or in a multi-tab window to move it into a new window."
                return nil
            }

        case .separateTab:
            guard let controller = surfaceView.window?.windowController as? TerminalController else {
                command.scriptErrorNumber = errAEEventFailed
                command.scriptErrorString = "Terminal is not in a standard tabbed window."
                return nil
            }

            guard controller.promoteSurfaceToNewTab(surfaceView) != nil else {
                command.scriptErrorNumber = errAEEventFailed
                command.scriptErrorString = "Terminal must be part of a split in a tab-capable window to move it into a separate tab."
                return nil
            }
        }

        return ScriptTerminal(surfaceView: surfaceView)
    }

    /// Handler for `focus <terminal>`.
    @objc(handleFocusCommand:)
    func handleFocus(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is not in a window."
            return nil
        }

        controller.focusSurface(surfaceView)
        return nil
    }

    /// Handler for `close <terminal>`.
    @objc(handleCloseCommand:)
    func handleClose(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let surfaceView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal surface is no longer available."
            return nil
        }

        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is not in a window."
            return nil
        }

        controller.closeSurface(surfaceView, withConfirmation: false)
        return nil
    }

    /// Provides Cocoa scripting with a canonical "path" back to this object.
    ///
    /// Without an object specifier, returned terminal objects can't be reliably
    /// referenced in follow-up script statements because AppleScript cannot
    /// express where the object came from (`application.terminals[id]`).
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let appClassDescription = NSApplication.shared.classDescription as? NSScriptClassDescription else {
            return nil
        }

        return NSUniqueIDSpecifier(
            containerClassDescription: appClassDescription,
            containerSpecifier: nil,
            key: "terminals",
            uniqueID: stableID
        )
    }
}

/// Converts four-character codes from the `split direction` enumeration in `Ghostty.sdef`
/// to `SplitTree.NewDirection` values.
enum ScriptSplitDirection {
    case right
    case left
    case down
    case up

    init?(code: UInt32) {
        switch code {
        case "GSrt".fourCharCode: self = .right
        case "GSlf".fourCharCode: self = .left
        case "GSdn".fourCharCode: self = .down
        case "GSup".fourCharCode: self = .up
        default: return nil
        }
    }

    var splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection {
        switch self {
        case .right: .right
        case .left: .left
        case .down: .down
        case .up: .up
        }
    }
}

/// Converts four-character codes from the `split layout` enumeration in `Ghostty.sdef`
/// to `SplitTree.Direction` values.
enum ScriptSplitLayout {
    case columns
    case rows

    init?(code: UInt32) {
        switch code {
        case "GCol".fourCharCode: self = .columns
        case "GRow".fourCharCode: self = .rows
        default: return nil
        }
    }

    var splitDirection: SplitTree<Ghostty.SurfaceView>.Direction {
        switch self {
        case .columns: .horizontal
        case .rows: .vertical
        }
    }
}
