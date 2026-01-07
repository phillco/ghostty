# AppleScript Support

This document describes the native AppleScript support for Ghostty on macOS, enabling programmatic control of terminals without UI scripting.

## Overview

Ghostty exposes a Cocoa Scripting interface that provides complete feature parity with the existing App Intents (Shortcuts) support. This allows automation workflows, integration with other apps like Raycast/Alfred, and traditional AppleScript-based scripting.

## Architecture

The implementation wraps existing Ghostty infrastructure rather than creating parallel code paths:

```
AppleScript (OSA)
       │
       ▼
┌─────────────────────┐
│  NSScriptCommand    │  ← ScriptCommands.swift
│  subclasses         │
└─────────────────────┘
       │
       ▼
┌─────────────────────┐
│  TerminalRegistry   │  ← TerminalRegistry.swift
│  ScriptableTerminal │     (enumeration + object specifiers)
└─────────────────────┘
       │
       ▼
┌─────────────────────┐
│  Existing APIs      │
│  - TerminalController.newWindow/newTab
│  - Surface.sendText()
│  - Surface.perform(action:)
│  - BaseTerminalController.focusSurface()
│  - BaseTerminalController.closeSurface()
└─────────────────────┘
```

### Key Design Decisions

1. **Reuses App Intents patterns**: Terminal enumeration logic mirrors `TerminalQuery.all` from App Intents
2. **ID-based commands for focus/close**: Avoids AppleScript routing issues with direct object parameters
3. **MainActor isolation**: All surface/controller access wrapped in `MainActor.assumeIsolated` blocks
4. **Non-blocking thread handling**: Commands dispatch to main thread synchronously when needed

## Files

### Created

| File | Purpose |
|------|---------|
| `macos/Ghostty.sdef` | AppleScript dictionary (SDEF XML) |
| `macos/Sources/Features/Scripting/TerminalRegistry.swift` | `ScriptableTerminal` class, `TerminalRegistry` singleton, `NSApplication` extension |
| `macos/Sources/Features/Scripting/ScriptCommands.swift` | `NSScriptCommand` subclasses for all commands |

### Modified

| File | Change |
|------|--------|
| `macos/Ghostty-Info.plist` | Added `NSAppleScriptEnabled` and `OSAScriptingDefinition` keys |
| `macos/Ghostty.xcodeproj/project.pbxproj` | Added `Ghostty.sdef` to Resources build phase |

## SDEF Structure

The scripting dictionary (`Ghostty.sdef`) defines:

### Standard Suite (`????`)
- `quit` command (standard)
- `application` class with `name`, `version` properties and `terminals` element
- `terminal` class with properties: `id`, `title`, `working directory`, `contents`, `kind`
- Enumerations: `terminal kind` (normal/quick), `terminal location` (window/tab)

### Ghostty Suite (`Ghst`)
- `new terminal` - creates window/tab with optional command/directory
- `send text` - sends text to a terminal
- `focus terminal` - focuses terminal by ID
- `close terminal` - closes terminal by ID
- `open quick terminal` - opens the quick/dropdown terminal
- `perform action` - executes any keybind action
- `invoke command` - executes command palette action (alias for perform)

## Command Implementations

### NewTerminalCommand
Creates terminals via `TerminalController.newWindow()` or `TerminalController.newTab()`. Supports:
- `location` parameter: `window` (default) or `tab`
- `command` parameter: wraps in `initialInput` with `; exit\n`
- `directory` parameter: sets `workingDirectory` in config

### SendTextCommand
Sends text via `Surface.sendText()`. AppleScript users append `& return` for Enter key.

### FocusCommand / CloseTerminalCommand
Accept terminal ID string, look up via `TerminalRegistry.shared.terminal(withIDString:)`, then call existing controller methods.

### QuickTerminalCommand
Calls `AppDelegate.quickController.animateIn()` and returns the quick terminal.

### PerformActionCommand / InvokeCommandCommand
Execute arbitrary keybind actions via `Surface.perform(action:)`. Supports all actions available in config, e.g., `new_split:right`, `copy:clipboard`, `toggle_fullscreen`.

## App Intents Parity

| App Intent | AppleScript Command |
|------------|---------------------|
| `NewTerminalIntent` | `new terminal` |
| `InputIntent` | `send text` |
| `GetTerminalDetailsIntent` | terminal properties |
| `FocusTerminalIntent` | `focus terminal` |
| `CloseTerminalIntent` | `close terminal` |
| `QuickTerminalIntent` | `open quick terminal` |
| `KeybindIntent` | `perform action` |
| `CommandPaletteIntent` | `invoke command` |

## Testing

### Basic validation
```bash
# Verify SDEF loads correctly
sdef /path/to/Ghostty.app

# Test basic query
osascript -e 'tell application "Ghostty" to get terminals'

# Test property access
osascript -e 'tell application "Ghostty" to get title of terminal 1'
```

### Command tests
```bash
# Create terminal with command
osascript -e 'tell application "Ghostty" to new terminal command "htop"'

# Send text
osascript -e 'tell application "Ghostty" to send text "echo hello" & return to terminal 1'

# Perform keybind action
osascript -e 'tell application "Ghostty" to perform action "new_split:right" in terminal 1'

# Open quick terminal
osascript -e 'tell application "Ghostty" to open quick terminal'
```

## Example Scripts

### Open project in new terminal
```applescript
tell application "Ghostty"
    new terminal directory "/path/to/project" command "nvim ."
end tell
```

### Split and run parallel tasks
```applescript
tell application "Ghostty"
    set t to new terminal
    perform action "new_split:right" in t
    send text "npm run watch" & return to terminal 1
    send text "npm run server" & return to terminal 2
end tell
```

### Focus from another app
```applescript
tell application "Ghostty"
    set termID to id of terminal 1
    focus terminal id termID
end tell
```

## Known Limitations

1. `focus terminal` and `close terminal` require UUID string rather than terminal object reference (AppleScript routing limitation)
2. `perform action` returns `false` for actions that have no effect (e.g., `copy:clipboard` with no selection)
3. `contents` property may be empty if screen contents aren't cached

## AI Disclosure

This implementation was written primarily by Claude Code (Anthropic) with human oversight and testing on macOS.
