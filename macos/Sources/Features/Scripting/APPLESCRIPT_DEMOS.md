# AppleScript Examples for Ghostty

Minimal examples demonstrating Ghostty's AppleScript capabilities. Run these in Script Editor or via `osascript`.

## Terminal References and Properties

**Terminal indices are positional** - they shift when terminals close. Use UUIDs for persistent references.

```applescript
tell application "Ghostty"
    -- Create a terminal and keep a reference
    set t to new terminal

    -- Get its UUID for persistent reference
    set terminalID to id of t
    -- Result example: "4996F198-CF1B-4257-91CE-C324EA858309"

    -- Get properties
    get title of t
    get working directory of t
    get contents of t
    get kind of t

    -- Later, even if other terminals closed, find by UUID
    set t to terminal 1 whose id is terminalID
    send text "found you!" to t
end tell
```

**When to use:**
- **Indices** (`terminal 1`): Immediate operations on current terminals
- **UUIDs** (`id` property): Persistent references across terminal lifecycle

## Creating Terminals

```applescript
tell application "Ghostty"
    -- New window
    new terminal

    -- New tab
    new terminal location tab

    -- With command
    new terminal command "htop"

    -- With directory
    new terminal directory "/tmp"

    -- Keep open after command exits
    new terminal command "echo Done!" with wait

    -- Quick terminal (dropdown)
    open quick terminal
end tell
```

## Sending Text

```applescript
tell application "Ghostty"
    -- Send text without executing
    send text "echo Hello World" to terminal 1

    -- Send Enter key to execute
    perform action "text:\\x0d" in terminal 1
end tell
```

**Important:** Some applications (like Claude Code) require a delay between sending text and sending Enter:

```applescript
-- Send text
send text "your prompt" to terminal 1

-- Wait for UI to update
delay 0.5

-- Then send Enter
perform action "text:\\x0d" in terminal 1
```

Or use separate osascript commands:

```bash
osascript -e 'tell application "Ghostty" to send text "your prompt" to terminal 1'
sleep 1
osascript -e 'tell application "Ghostty" to perform action "text:\\x0d" in terminal 1'
```

## Terminal Control

```applescript
tell application "Ghostty"
    -- Focus (brings window to front)
    focus in terminal 1

    -- Close
    close in terminal 2

    -- Split (4 directions)
    split direction right in terminal 1
    split direction down in terminal 1
    split direction left in terminal 1
    split direction up in terminal 1

    -- Clear screen
    clear screen in terminal 1
end tell
```

## Tab Navigation

```applescript
tell application "Ghostty"
    -- Create some tabs first
    new terminal location tab
    new terminal location tab

    -- Navigate
    perform action "next_tab" in terminal 1
    perform action "previous_tab" in terminal 1
    perform action "goto_tab:1" in terminal 1
end tell
```

## Keybind Actions

Any Ghostty keybind action can be invoked via `perform action`:

```applescript
tell application "Ghostty"
    perform action "toggle_fullscreen" in terminal 1
    perform action "copy:clipboard" in terminal 1
    perform action "paste:clipboard" in terminal 1
    perform action "increase_font_size:1" in terminal 1
    perform action "reset_font_size" in terminal 1
    perform action "scroll_to_top" in terminal 1
    perform action "scroll_to_bottom" in terminal 1
end tell
```

## Window Manager Integration

For use with skhd, yabai, or AeroSpace:

```bash
# In your skhd config - opens new terminal without spawning new app instance
alt - return : osascript -e 'tell application "Ghostty" to new terminal'

# Open new tab
alt + shift - return : osascript -e 'tell application "Ghostty" to new terminal location tab'

# Quick terminal toggle
alt - space : osascript -e 'tell application "Ghostty" to open quick terminal'
```
