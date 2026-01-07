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

        // Set working directory if provided (expand ~ to home directory)
        if let directory, !directory.isEmpty {
            config.workingDirectory = NSString(string: directory).expandingTildeInPath
        }

        // Execute on main thread and return result
        var resultTerminal: ScriptableTerminal?

        let work = { [location, config] in
            // Determine if creating window or tab
            let isTab = location == FourCharCode(0x74616276) // 'tabv'

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

        let work = { () -> Bool in
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

        let work = { () -> Bool in
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

        var resultTerminal: ScriptableTerminal?

        let work = {
            MainActor.assumeIsolated {
                guard let surface = terminal.surfaceView?.surfaceModel else {
                    return
                }

                // Get terminal count before split
                let terminalsBefore = TerminalRegistry.shared.allTerminals

                // Perform the split action
                _ = surface.perform(action: "new_split:\(direction)")

                // Small delay to let the split complete, then find the new terminal
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let terminalsAfter = TerminalRegistry.shared.allTerminals
                    // Find the new terminal (one that wasn't in the before list)
                    let beforeIDs = Set(terminalsBefore.map { $0.id })
                    if let newTerminal = terminalsAfter.first(where: { !beforeIDs.contains($0.id) }) {
                        resultTerminal = newTerminal
                    }
                }
            }
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync {
                work()
            }
        }

        // Wait a bit for the async result
        Thread.sleep(forTimeInterval: 0.2)

        return resultTerminal
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

        var success = false
        let work = {
            success = MainActor.assumeIsolated {
                guard let surface = terminal.surfaceView?.surfaceModel else {
                    return false
                }
                return surface.perform(action: "clear_screen")
            }
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync {
                work()
            }
        }

        if !success {
            scriptErrorNumber = -1728
            scriptErrorString = "Could not clear terminal"
        }

        return nil
    }
}


