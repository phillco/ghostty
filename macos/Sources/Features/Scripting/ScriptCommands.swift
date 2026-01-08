import AppKit
import Foundation

// MARK: - New Terminal Command

/// AppleScript command: new terminal [location window/tab] [command "..."] [directory "..."]
@objc(NewTerminalCommand)
class NewTerminalCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Parse parameters before suspending (evaluatedArguments must be accessed synchronously)
        let location = evaluatedArguments?["location"] as? FourCharCode
        let commandText = evaluatedArguments?["command"] as? String
        let directory = evaluatedArguments?["directory"] as? String
        let wait = evaluatedArguments?["wait"] as? Bool ?? false

        // Suspend the script command for async execution
        suspendExecution()

        Task { @MainActor in
            let result = await performAsync(
                location: location,
                commandText: commandText,
                directory: directory,
                wait: wait
            )
            self.resumeExecution(withResult: result)
        }

        return nil
    }

    @MainActor
    private func performAsync(
        location: FourCharCode?,
        commandText: String?,
        directory: String?,
        wait: Bool
    ) async -> ScriptableTerminal? {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            scriptErrorNumber = -1728
            scriptErrorString = "Ghostty is not available"
            return nil
        }
        let ghostty = appDelegate.ghostty

        // Build configuration
        var config = Ghostty.SurfaceConfiguration()

        // Set command if provided (as initial input so shell scripts run first)
        if let commandText, !commandText.isEmpty {
            // Only append "; exit" if wait is false (default behavior)
            // If wait is true, let the command run interactively
            if wait {
                config.initialInput = "\(commandText)\n"
                config.waitAfterCommand = true
            } else {
                config.initialInput = "\(commandText); exit\n"
                config.waitAfterCommand = false
            }
        }

        // Set working directory if provided (expand ~ to home directory)
        if let directory, !directory.isEmpty {
            config.workingDirectory = NSString(string: directory).expandingTildeInPath
        }

        // Determine if creating window or tab
        let isTab = location == FourCharCode(0x74616276) // 'tabv'

        var resultTerminal: ScriptableTerminal?

        if isTab {
            // Create new tab using preferredParent (same pattern as App Intents)
            if let controller = TerminalController.newTab(
                ghostty,
                from: TerminalController.preferredParent?.window,
                withBaseConfig: config
            ) {
                if let view = controller.surfaceTree.root?.leftmostLeaf() {
                    resultTerminal = ScriptableTerminal(view)
                }
            }
        } else {
            // Create new window (default)
            let controller = TerminalController.newWindow(
                ghostty,
                withBaseConfig: config,
                withParent: nil
            )
            if let view = controller.surfaceTree.root?.leftmostLeaf() {
                resultTerminal = ScriptableTerminal(view)
            }
        }

        // Activate the app
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        return resultTerminal
    }
}

// MARK: - Send Text Command

/// AppleScript command: send text "..." to terminal X
@objc(SendTextCommand)
class SendTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Get the text to send
        guard let text = directParameter as? String else {
            scriptErrorNumber = -1701
            scriptErrorString = "Missing text to send"
            return nil
        }

        // Get the target terminal
        guard let terminal = evaluatedArguments?["terminal"] as? ScriptableTerminal else {
            scriptErrorNumber = -1701
            scriptErrorString = "Missing target terminal"
            return nil
        }

        suspendExecution()

        Task { @MainActor in
            let success = await performAsync(text: text, terminal: terminal)
            if !success {
                self.scriptErrorNumber = -1728
                self.scriptErrorString = "Terminal not found or no longer exists"
            }
            self.resumeExecution(withResult: nil)
        }

        return nil
    }

    @MainActor
    private func performAsync(text: String, terminal: ScriptableTerminal) async -> Bool {
        guard let surface = terminal.surfaceView?.surfaceModel else {
            return false
        }
        surface.sendText(text)
        return true
    }
}

// MARK: - Focus Command

/// AppleScript command: focus in terminal 1
@objc(FocusCommand)
class FocusCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Get the terminal to focus
        guard let terminal = evaluatedArguments?["terminal"] as? ScriptableTerminal else {
            scriptErrorNumber = -1701
            scriptErrorString = "Missing terminal to focus"
            return nil
        }

        suspendExecution()

        Task { @MainActor in
            let success = await performAsync(terminal: terminal)
            if !success {
                self.scriptErrorNumber = -1728
                self.scriptErrorString = "Terminal not found or no longer exists"
            }
            self.resumeExecution(withResult: nil)
        }

        return nil
    }

    @MainActor
    private func performAsync(terminal: ScriptableTerminal) async -> Bool {
        guard let surfaceView = terminal.surfaceView else {
            return false
        }
        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            return false
        }

        // Focus the surface within the controller
        controller.focusSurface(surfaceView)

        // Bring the window to front
        surfaceView.window?.makeKeyAndOrderFront(nil)

        // Activate the app
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        return true
    }
}

// MARK: - Close Terminal Command

/// AppleScript command: close in terminal 1
@objc(CloseTerminalCommand)
class CloseTerminalCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Get the terminal to close
        guard let terminal = evaluatedArguments?["terminal"] as? ScriptableTerminal else {
            scriptErrorNumber = -1701
            scriptErrorString = "Missing terminal to close"
            return nil
        }

        suspendExecution()

        Task { @MainActor in
            let success = await performAsync(terminal: terminal)
            if !success {
                self.scriptErrorNumber = -1728
                self.scriptErrorString = "Terminal not found or no longer exists"
            }
            self.resumeExecution(withResult: nil)
        }

        return nil
    }

    @MainActor
    private func performAsync(terminal: ScriptableTerminal) async -> Bool {
        guard let surfaceView = terminal.surfaceView else {
            return false
        }
        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            return false
        }

        // Close without confirmation (AppleScript operations should be non-interactive)
        controller.closeSurface(surfaceView, withConfirmation: false)
        return true
    }
}

// MARK: - Quick Terminal Command

/// AppleScript command: open quick terminal
@objc(QuickTerminalCommand)
class QuickTerminalCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            let result = await performAsync()
            self.resumeExecution(withResult: result)
        }

        return nil
    }

    @MainActor
    private func performAsync() async -> ScriptableTerminal? {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            return nil
        }

        // Open the quick terminal
        let controller = delegate.quickController
        controller.animateIn()

        // Get the terminal from the quick controller
        var resultTerminal: ScriptableTerminal?
        if let view = controller.surfaceTree.root?.leftmostLeaf() {
            resultTerminal = ScriptableTerminal(view)
        }

        // Activate the app
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        return resultTerminal
    }
}

// MARK: - Perform Action Command

/// AppleScript command: perform action "action" in terminal X
@objc(PerformActionCommand)
class PerformActionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Get the action to perform
        guard let action = directParameter as? String else {
            scriptErrorNumber = -1701
            scriptErrorString = "Missing action to perform"
            return false
        }

        // Get the target terminal
        guard let terminal = evaluatedArguments?["terminal"] as? ScriptableTerminal else {
            scriptErrorNumber = -1701
            scriptErrorString = "Missing target terminal"
            return false
        }

        suspendExecution()

        Task { @MainActor in
            let result = await performAsync(action: action, terminal: terminal)
            if !result {
                self.scriptErrorNumber = -1728
                self.scriptErrorString = "Action could not be performed"
            }
            self.resumeExecution(withResult: result)
        }

        return nil
    }

    @MainActor
    private func performAsync(action: String, terminal: ScriptableTerminal) async -> Bool {
        guard let surface = terminal.surfaceView?.surfaceModel else {
            return false
        }
        return surface.perform(action: action)
    }
}

// MARK: - Invoke Command Command

/// AppleScript command: invoke command "action" in terminal X
@objc(InvokeCommandCommand)
class InvokeCommandCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Get the command action to invoke
        guard let action = directParameter as? String else {
            scriptErrorNumber = -1701
            scriptErrorString = "Missing command to invoke"
            return false
        }

        // Get the target terminal
        guard let terminal = evaluatedArguments?["terminal"] as? ScriptableTerminal else {
            scriptErrorNumber = -1701
            scriptErrorString = "Missing target terminal"
            return false
        }

        suspendExecution()

        Task { @MainActor in
            let result = await performAsync(action: action, terminal: terminal)
            if !result {
                self.scriptErrorNumber = -1728
                self.scriptErrorString = "Command could not be invoked"
            }
            self.resumeExecution(withResult: result)
        }

        return nil
    }

    @MainActor
    private func performAsync(action: String, terminal: ScriptableTerminal) async -> Bool {
        guard let surface = terminal.surfaceView?.surfaceModel else {
            return false
        }
        // Command palette actions use the same perform mechanism as keybinds
        return surface.perform(action: action)
    }
}

// MARK: - Split Command

/// AppleScript command: split direction right in terminal 1
@objc(SplitCommand)
class SplitCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Get the terminal to split
        guard let terminal = evaluatedArguments?["terminal"] as? ScriptableTerminal else {
            scriptErrorNumber = -1701
            scriptErrorString = "Missing terminal to split"
            return nil
        }

        // Get the direction
        guard let directionCode = evaluatedArguments?["direction"] as? FourCharCode else {
            scriptErrorNumber = -1701
            scriptErrorString = "Missing split direction"
            return nil
        }

        // Map direction code to action string
        let direction: String
        switch directionCode {
        case FourCharCode(0x72676874): // 'rght'
            direction = "right"
        case FourCharCode(0x646F776E): // 'down'
            direction = "down"
        case FourCharCode(0x6C656674): // 'left'
            direction = "left"
        case FourCharCode(0x75707764): // 'upwd'
            direction = "up"
        default:
            direction = "right"
        }

        suspendExecution()

        Task { @MainActor in
            let result = await performAsync(terminal: terminal, direction: direction)
            self.resumeExecution(withResult: result)
        }

        return nil
    }

    @MainActor
    private func performAsync(terminal: ScriptableTerminal, direction: String) async -> ScriptableTerminal? {
        guard let surface = terminal.surfaceView?.surfaceModel else {
            return nil
        }

        // Get terminal count before split
        let terminalsBefore = TerminalRegistry.shared.allTerminals

        // Perform the split action
        _ = surface.perform(action: "new_split:\(direction)")

        // Wait a bit for the split to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Find the new terminal (one that wasn't in the before list)
        let terminalsAfter = TerminalRegistry.shared.allTerminals
        let beforeIDs = Set(terminalsBefore.map { $0.id })
        return terminalsAfter.first(where: { !beforeIDs.contains($0.id) })
    }
}

// MARK: - Clear Command

/// AppleScript command: clear screen in terminal 1
@objc(ClearCommand)
class ClearCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Get the terminal to clear
        guard let terminal = evaluatedArguments?["terminal"] as? ScriptableTerminal else {
            scriptErrorNumber = -1701
            scriptErrorString = "Missing terminal to clear"
            return nil
        }

        suspendExecution()

        Task { @MainActor in
            let success = await performAsync(terminal: terminal)
            if !success {
                self.scriptErrorNumber = -1728
                self.scriptErrorString = "Could not clear terminal"
            }
            self.resumeExecution(withResult: nil)
        }

        return nil
    }

    @MainActor
    private func performAsync(terminal: ScriptableTerminal) async -> Bool {
        guard let surface = terminal.surfaceView?.surfaceModel else {
            return false
        }
        return surface.perform(action: "clear_screen")
    }
}
