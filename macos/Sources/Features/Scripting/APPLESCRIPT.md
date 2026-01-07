# AppleScript Support for Ghostty

Native AppleScript support for Ghostty on macOS, providing programmatic terminal control for automation workflows, editor integrations, and third-party app interoperability.

## Motivation

### The Problem

macOS users frequently need to programmatically control Ghostty from external tools—window managers, launchers (Alfred/Raycast), editor plugins, URL handlers, and automation scripts. Currently, this is difficult or impossible.

The most common workaround, `open -n -a Ghostty`, creates a **new app instance** rather than a new window in the existing instance. This is intentional macOS LaunchServices behavior, but it results in multiple Dock icons and process proliferation ([#6053](https://github.com/ghostty-org/ghostty/discussions/6053), [#3563](https://github.com/ghostty-org/ghostty/discussions/3563)).

### User Frustrations

These issues appear repeatedly across GitHub discussions:

- **Window manager integration** (AeroSpace, skhd, yabai): Users binding `open -n -a Ghostty` get "20 Dock icons" instead of new windows in a single instance ([#6053](https://github.com/ghostty-org/ghostty/discussions/6053))

- **Launcher integration** (Alfred, Raycast): Users want to open a terminal, cd to a directory, and run a command—workflows that "just work" with iTerm2's AppleScript support ([#3563](https://github.com/ghostty-org/ghostty/discussions/3563))

- **URL/protocol handlers** (`ssh://`, `x-man-page://`): "Not currently possible to launch Ghostty and make it run a specified command" without hacks ([#3021](https://github.com/ghostty-org/ghostty/discussions/3021))

- **Editor integrations** (vim-dispatch, VS Code tasks): Need to target specific terminals, send commands, read output

- **Scripting API requests**: The umbrella discussion [#2353](https://github.com/ghostty-org/ghostty/discussions/2353) explicitly calls for platform-native IPC like AppleScript on macOS

### Why Not App Intents (Shortcuts)?

Ghostty already has App Intents support, but this doesn't solve the integration problem:

1. **User setup required**: Users must manually create a Shortcut in the Shortcuts app before other tools can use it

2. **Indirect invocation**: Other apps must call `shortcuts run "My Shortcut"` or use URL schemes—adding friction and indirection

3. **No direct API**: Third-party apps cannot directly send Apple Events to Ghostty; they must go through Shortcuts as an intermediary

4. **Rough edges**: The App Intents implementation has had issues (e.g., "New Terminal" opening two windows when Ghostty wasn't running, [#8669](https://github.com/ghostty-org/ghostty/issues/8669))

In contrast, AppleScript allows direct control:
```applescript
-- Direct: works immediately, no setup required
tell application "Ghostty" to new terminal command "htop" directory "/tmp"

-- vs. Shortcuts: requires user to create shortcut first
do shell script "shortcuts run 'My Ghostty Shortcut'"
```

### Current Workarounds (and Why They're Insufficient)

Users resort to **UI scripting**—activating Ghostty and simulating keystrokes via System Events:

```applescript
-- Brittle: depends on focus, keybindings, accessibility permissions
tell application "Ghostty" to activate
tell application "System Events"
    keystroke "n" using command down  -- hope this opens a new window
    keystroke "cd /tmp && htop"
    keystroke return
end tell
```

This approach:
- Requires Accessibility permissions
- Breaks if keybindings change
- Cannot target specific windows/tabs
- Steals focus
- Is fundamentally unreliable

Tools like Alfred, Keyboard Maestro, Hammerspoon, and BetterTouchTool all use variations of this hack ([Alfred forum](https://www.alfredforum.com/topic/23562-alfredghostty-script-v010/), [GitHub](https://github.com/zeitlings/alfred-ghostty-script)).

## Solution: Native AppleScript Support

This implementation adds a proper AppleScript dictionary (SDEF) exposing Ghostty's terminal control capabilities directly.

### What This Enables

**Direct integration without user setup:**
```applescript
tell application "Ghostty"
    new terminal command "ssh server.example.com" directory "~"
end tell
```

**Window manager integration (AeroSpace, skhd):**
```bash
# Single instance, new window—no Dock icon proliferation
osascript -e 'tell application "Ghostty" to new terminal'
```

**Terminal automation:**
```applescript
tell application "Ghostty"
    set t to new terminal
    get id of t  -- Store UUID for later reference
    send text "echo hello" to t
end tell
```

### Security Considerations

This feature does not introduce new security risks:

1. **macOS permission prompts**: AppleScript automation requires explicit user approval. Users see "App X wants to control Ghostty" and must grant permission.

2. **Parity with existing features**: App Intents (Shortcuts) already allows the same operations. AppleScript is simply a more direct interface.

3. **Standard macOS pattern**: Terminal.app and iTerm2 both expose AppleScript dictionaries for terminal control. This is expected behavior for macOS terminal emulators.

## Implementation

### Architecture

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
│  ScriptableTerminal │
└─────────────────────┘
       │
       ▼
┌─────────────────────┐
│  Existing APIs      │
│  - TerminalController.newWindow/newTab
│  - Surface.sendText()
│  - Surface.perform(action:)
│  - BaseTerminalController.focusSurface()
└─────────────────────┘
```

### Files Created

| File | Purpose |
|------|---------|
| `macos/Ghostty.sdef` | AppleScript dictionary (SDEF XML) |
| `macos/Sources/Features/Scripting/TerminalRegistry.swift` | Terminal enumeration, ScriptableTerminal wrapper |
| `macos/Sources/Features/Scripting/ScriptCommands.swift` | NSScriptCommand implementations |

### Files Modified

| File | Change |
|------|--------|
| `macos/Ghostty-Info.plist` | Added `NSAppleScriptEnabled` and `OSAScriptingDefinition` |
| `macos/Ghostty.xcodeproj/project.pbxproj` | Added SDEF to Resources build phase |

## API Reference

### Terminal Properties

Each terminal has the following read-only properties:

| Property | Type | Description |
|----------|------|-------------|
| `id` | text | Unique identifier (UUID string) |
| `title` | text | Terminal title (usually current directory or running command) |
| `working directory` | text | Current working directory path |
| `contents` | text | Current screen contents (visible text) |
| `kind` | terminal kind | Either `normal` or `quick` |

```applescript
tell application "Ghostty"
    get terminals                       -- list all terminals
    get id of terminal 1                -- UUID string
    get title of terminal 1             -- window/tab title
    get working directory of terminal 1 -- current pwd
    get contents of terminal 1          -- screen text
    get kind of terminal 1              -- normal or quick
end tell
```

### Terminal References

**Terminal indices are positional** - like array indices, they shift when terminals close:

```applescript
tell application "Ghostty"
    -- Immediate operations: use indices
    send text "ls" to terminal 1
    focus in terminal 2

    -- Persistent references: use UUIDs
    set t to new terminal
    set terminalID to id of t

    -- Later, even if other terminals closed:
    set t to terminal 1 whose id is terminalID
    send text "found you!" to t
end tell
```

**When to use each:**
- **Indices** (`terminal 1`, `terminal 2`): For immediate operations on currently open terminals
- **UUIDs** (`id` property): For persistent references when terminals might close or reorder between operations

### Terminal Creation

```applescript
tell application "Ghostty"
    new terminal                                -- new window
    new terminal location tab                   -- new tab
    new terminal command "htop"                 -- with command
    new terminal directory "/tmp"               -- with working directory
    new terminal command "htop" with wait       -- keep open after command exits
    open quick terminal                         -- dropdown terminal
end tell
```

### Terminal Control

```applescript
tell application "Ghostty"
    send text "ls -la" to terminal 1
    focus in terminal 1
    close in terminal 1
    split direction right in terminal 1
    split direction down in terminal 1
    clear screen in terminal 1
end tell
```

### Keybind Actions

Execute any Ghostty keybind action via `perform action`:

```applescript
tell application "Ghostty"
    perform action "next_tab" in terminal 1
    perform action "previous_tab" in terminal 1
    perform action "goto_tab:1" in terminal 1
    perform action "toggle_fullscreen" in terminal 1
    perform action "copy:clipboard" in terminal 1
    perform action "paste:clipboard" in terminal 1
end tell
```

## App Intents Parity

This implementation provides complete feature parity with Shortcuts:

| App Intent | AppleScript Command |
|------------|---------------------|
| `NewTerminalIntent` | `new terminal` |
| `InputIntent` | `send text` |
| `GetTerminalDetailsIntent` | terminal properties |
| `FocusTerminalIntent` | `focus` |
| `CloseTerminalIntent` | `close` |
| `QuickTerminalIntent` | `open quick terminal` |
| `KeybindIntent` | `perform action` |
| `CommandPaletteIntent` | `invoke command` |

## Prior Art

[PR #9249](https://github.com/ghostty-org/ghostty/pull/9249) implements basic AppleScript support with `create window` and `create tab` commands. This implementation extends that work with complete App Intents parity:

| Feature | PR #9249 | This Implementation |
|---------|----------|---------------------|
| Create window/tab | ✓ | ✓ |
| Command parameter | ✓ | ✓ |
| Directory parameter | ✗ | ✓ |
| `wait` after command | ✓ | ✓ |
| Query terminals | ✗ | ✓ |
| Terminal properties | ✗ | ✓ |
| send text | ✗ | ✓ |
| focus/close terminal | ✗ | ✓ |
| open quick terminal | ✗ | ✓ |
| perform action (keybinds) | ✗ | ✓ |
| Returns terminal object | ✗ | ✓ |

## Testing

All commands tested on macOS 15.2 (Darwin 25.2.0) with Xcode 16.2.

## Known Limitations

1. **`perform action` returns error** for actions that have no effect (e.g., `copy:clipboard` with no selection)

2. **`contents` property** may return empty if screen contents aren't cached

## AI Disclosure

This implementation was written primarily by Claude Code (Anthropic) with human oversight and testing on macOS.
