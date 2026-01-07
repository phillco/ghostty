import AppKit
import Foundation

// MARK: - New Terminal Command

/// AppleScript command: new terminal [location window/tab] [command "..."] [directory "..."]
@objc(NewTerminalCommand)
class NewTerminalCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Get the Ghostty app instance
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            scriptErrorNumber = -1728
            scriptErrorString = "Ghostty is not available"
            return nil
        }
        let ghostty = appDelegate.ghostty

        // Parse parameters
        let location = evaluatedArguments?["location"] as? FourCharCode
        let commandText = evaluatedArguments?["command"] as? String
        let directory = evaluatedArguments?["directory"] as? String
        let wait = evaluatedArguments?["wait"] as? Bool ?? false

        // Build configuration
        var config = Ghostty.SurfaceConfiguration()

        // Set command if provided (as initial input so shell scripts run first)
        if let commandText, !commandText.isEmpty {
            config.initialInput = "\(commandText); exit\n"
            config.waitAfterCommand = wait
        }

        // Set working directory if provided
        if let directory, !directory.isEmpty {
            config.workingDirectory = directory
        }

        // Execute on main thread and return result
        var resultTerminal: ScriptableTerminal?

        let work = { [location, config] in
            // Determine if creating window or tab
            let isTab = location == FourCharCode(0x74616276) // 'tabv'

            if isTab {
                // Create new tab
                if let controller = TerminalController.newTab(
                    ghostty,
                    from: nil,
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
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync {
                work()
            }
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

        // Send the text - must be on main actor
        var success = false
        if Thread.isMainThread {
            success = MainActor.assumeIsolated {
                guard let surface = terminal.surfaceView?.surfaceModel else {
                    return false
                }
                surface.sendText(text)
                return true
            }
        } else {
            DispatchQueue.main.sync {
                success = MainActor.assumeIsolated {
                    guard let surface = terminal.surfaceView?.surfaceModel else {
                        return false
                    }
                    surface.sendText(text)
                    return true
                }
            }
        }

        if !success {
            scriptErrorNumber = -1728
            scriptErrorString = "Terminal not found or no longer exists"
        }

        return nil
    }
}

// MARK: - Focus Command

/// AppleScript command: focus terminal id "UUID"
@objc(FocusCommand)
class FocusCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Get the terminal ID
        guard let terminalID = evaluatedArguments?["terminalID"] as? String else {
            scriptErrorNumber = -1701
            scriptErrorString = "Missing terminal ID"
            return nil
        }

        let work = { () -> Bool in
            // Find terminal by ID
            guard let terminal = MainActor.assumeIsolated({
                TerminalRegistry.shared.terminal(withIDString: terminalID)
            }) else {
                return false
            }

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

        var success = false
        if Thread.isMainThread {
            success = work()
        } else {
            DispatchQueue.main.sync {
                success = work()
            }
        }

        if !success {
            scriptErrorNumber = -1728
            scriptErrorString = "Terminal not found or no longer exists"
        }

        return nil
    }
}

// MARK: - Close Terminal Command

/// AppleScript command: close terminal id "UUID"
@objc(CloseTerminalCommand)
class CloseTerminalCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Get the terminal ID
        guard let terminalID = evaluatedArguments?["terminalID"] as? String else {
            scriptErrorNumber = -1701
            scriptErrorString = "Missing terminal ID"
            return nil
        }

        let work = { () -> Bool in
            // Find terminal by ID
            guard let terminal = MainActor.assumeIsolated({
                TerminalRegistry.shared.terminal(withIDString: terminalID)
            }) else {
                return false
            }

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

        var success = false
        if Thread.isMainThread {
            success = work()
        } else {
            DispatchQueue.main.sync {
                success = work()
            }
        }

        if !success {
            scriptErrorNumber = -1728
            scriptErrorString = "Terminal not found or no longer exists"
        }

        return nil
    }
}

// MARK: - Quick Terminal Command

/// AppleScript command: open quick terminal
@objc(QuickTerminalCommand)
class QuickTerminalCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        var resultTerminal: ScriptableTerminal?

        let work = {
            guard let delegate = NSApp.delegate as? AppDelegate else {
                return
            }

            // Open the quick terminal
            let controller = delegate.quickController
            controller.animateIn()

            // Get the terminal from the quick controller
            if let view = controller.surfaceTree.root?.leftmostLeaf() {
                resultTerminal = ScriptableTerminal(view)
            }

            // Activate the app
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync {
                work()
            }
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

        var result = false
        let work = {
            result = MainActor.assumeIsolated {
                guard let surface = terminal.surfaceView?.surfaceModel else {
                    return false
                }
                return surface.perform(action: action)
            }
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync {
                work()
            }
        }

        if !result {
            scriptErrorNumber = -1728
            scriptErrorString = "Action could not be performed"
        }

        return result
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

        var result = false
        let work = {
            result = MainActor.assumeIsolated {
                guard let surface = terminal.surfaceView?.surfaceModel else {
                    return false
                }
                // Command palette actions use the same perform mechanism as keybinds
                return surface.perform(action: action)
            }
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync {
                work()
            }
        }

        if !result {
            scriptErrorNumber = -1728
            scriptErrorString = "Command could not be invoked"
        }

        return result
    }
}
