# Local Fork Specification

This file is the contract for behavior that this local Ghostty fork keeps on
top of `ghostty-org/ghostty`. Read it before upstream merges, conflict
resolution, and merge validation.

The specification is based on the committed fork delta, not on uncommitted
work in a checkout. Refresh that delta with:

```sh
git log --reverse --no-merges --oneline refs/remotes/upstream/main..HEAD
git diff --stat refs/remotes/upstream/main...HEAD
```

If upstream replaces one of these behaviors, verify that it is equivalent for
the local automation before removing the fork code or this requirement.

## Why This Fork Exists

This fork treats the terminal as an operating surface for local automation, not
only as pixels and keyboard input. A Ghostty tab or split can represent a
specific work session that a voice tool, a script, or an agent helper needs to
find again, inspect, focus, reshape, or annotate.

That work becomes fragile when it depends on UI order, tab titles, raw screen
coordinates, blind keystrokes, or a terminal session remembering state that the
macOS app cannot see. The fork adds narrow bridges where local automation needs
real terminal state:

- Accessibility for text, selection, cursor location, range geometry, and
  identifiers visible to macOS automation clients.
- AppleScript for user-level app operations such as split layout, promotion,
  tab colors, and session-variable reads.
- The embedded C API where the macOS app needs state owned by the Zig terminal
  core.
- Standard terminal escape handling where a process inside a terminal is the
  best source of session metadata.

The fork is not meant to turn Ghostty into a separate product or a broad window
manager. Prefer upstream behavior when it satisfies the same local automation
need. Keep local additions small enough to review during an upstream merge and
concrete enough to verify after one.

## Design Philosophy

- Expose state instead of making automation guess. Stable IDs, cursor
  positions, selection ranges, and session variables are more reliable than
  titles, ordering, screenshots, or timing assumptions.
- Put each control at the layer that owns it. Text interaction belongs in the
  accessibility surface, app operations belong in AppleScript or menus, core
  terminal state crosses the embedded API, and shell-originated metadata can
  use terminal protocols.
- Keep automation behavior close to normal user behavior. Split commands act
  on the nearest relevant split, promotion moves panes into ordinary tabs or
  windows, and context-menu link actions represent an explicit right-click
  intent.
- Preserve native Ghostty ergonomics. The added interfaces should make dense
  macOS terminal work easier without disrupting ordinary keyboard, mouse, tab,
  and split workflows.
- Prefer narrow contracts that can be tested after a merge. When a feature
  needs both a core hook and a macOS affordance, keep the public names and
  verification path visible in this file.

## Fork Goals

The fork exists to make the macOS app easier to drive from automation while
keeping local builds practical. The expected fork-only behavior falls into six
groups:

1. A richer macOS accessibility text surface for reading, selecting, and
   identifying terminal content.
2. AppleScript and menu controls for terminal splits, split promotion, tab
   colors, and dense tab navigation.
3. Stable identifiers for surfaces and native AppKit tabs.
4. iTerm2-style per-terminal session variables exposed through core, C API,
   accessibility, and AppleScript.
5. Link actions in the macOS terminal context menu.
6. A `Justfile` with local build, test, install, and formatting wrappers.

## Required Behavior

### Accessibility Text Surface

Each macOS terminal surface must stay useful as an accessibility text area.

The motivation is to let local tools work with terminal text as text. Reading a
selection, writing a selection range, and getting a range rectangle are less
brittle than replaying mouse coordinates or treating terminal output as a
screenshot. Correct wrapped-line geometry and cursor reporting matter because
terminal text is laid out on a grid while AppKit automation expects text ranges.

- `Ghostty.SurfaceView` is an accessibility element with `.textArea` role and
  surface identifier `ghostty-surface:<surface UUID>`.
- Accessibility clients can read terminal text, selected text, selected text
  range, line ranges, range text, visible character range, and bounds for a
  text range.
- Selection ranges are writable through accessibility. Setting
  `AXSelectedTextRange` updates the terminal selection. Setting selected text
  inserts text into the terminal and clears the terminal selection.
- Bounds for accessibility text ranges must account for wrapped grid lines and
  return screen-space rectangles. This is used by tools that need to place UI
  around terminal text.
- A zero-length selected range should follow the terminal cursor when no text
  is selected.

The supporting embedded API must keep these C shapes and entrypoints:

- `ghostty_selection_range_s`
- `ghostty_cursor_position_s`
- `ghostty_surface_selection_range`
- `ghostty_surface_set_selection_range`
- `ghostty_surface_cursor_position`

`ghostty_surface_selection_range` and
`ghostty_surface_set_selection_range` use UTF-8 byte offsets into flattened
screen text. The macOS accessibility layer converts those offsets to the UTF-16
ranges required by AppKit.

### Surface And Tab Identity

Automation must be able to identify a pane and a native tab separately.

The motivation is to avoid treating titles or visual order as identity. Surface
identity is needed for a specific pane. Native tab identity is needed for the
AppKit container around one or more panes, including after a tab is restored or
closed and reopened through undo.

- A surface uses the existing surface UUID in
  `ghostty-surface:<surface UUID>` for its accessibility identifier.
- A native AppKit tab has its own `TerminalWindow.tabID` UUID. It must not reuse
  a surface UUID because one tab can contain multiple split surfaces.
- Native tab buttons get accessibility identifiers in the form
  `ghostty-tab:<tab UUID>` when tabs are relabeled.
- A tab ID survives window state restoration and undo-close restoration.

### Focus And Tab Colors

The macOS fork keeps local split focus and tab color affordances.

The motivation is dense split and tab work. Focus-on-hover makes pointer-guided
split work need fewer explicit focus clicks when the user enables that mode.
Scriptable tab colors let external automation keep the visible tab state in
sync with the workflow it is managing.

- With `focus-follows-mouse = true`, moving the pointer over a non-focused
  split in the key terminal window focuses that split when no mouse button is
  down and the command palette is not open.
- AppleScript exposes a read-write terminal `tab color` property for the tab
  containing that terminal.
- The AppleScript `tab color` enumeration must include `none`, `blue`,
  `purple`, `pink`, `red`, `orange`, `yellow`, `green`, `teal`, and
  `graphite`.
- `TerminalTabColor` keeps the FourCharCode conversion used by the scripting
  dictionary.

### Split Automation And Promotion

Automation and the macOS menus must be able to reshape split panes.

The motivation is that a split layout is part of the working state, not just a
one-time mouse arrangement. Scripts and voice-driven workflows should be able
to move a focused terminal into a useful shape without building a separate
window manager on top of Ghostty. The operations stay scoped to the target
terminal and its containing split.

- AppleScript terminals can create splits with a direction and optional surface
  configuration.
- AppleScript terminals support `set split percentage`, `rotate split`,
  `set split layout`, and `equalize split` for the nearest split containing the
  target terminal.
- AppleScript terminals support `promote to separate tab` and
  `promote to new window`.
- Promoting a pane from a split moves that pane into a new native tab or a new
  window. Promoting a single-pane tab to a new window is allowed when it is part
  of a multi-tab window.
- The macOS Split menu and terminal context menu expose `Move Split to New Tab`
  and `Move Split to New Window` where the move is valid.
- The terminal context menu includes split rotation. Its title says whether the
  target layout will become rows or columns when the split direction is known.

The split-tree helpers and tests are part of this contract. Keep coverage for
resizing the focused pane, changing its layout, rotating it, equalizing it, and
querying its current layout direction.

### Session Variables

Each terminal stores and reports iTerm2-style per-session variables.

The motivation is to let a process inside the terminal attach semantic metadata
to its own terminal session. For example, a Codex session ID should be readable
by macOS automation without scraping prompt text, parsing a tab title, or
maintaining a second mapping outside Ghostty.

- OSC 1337 `SetUserVar` decodes a base64 value and stores it on the terminal.
- OSC 1337 `ReportVariable` decodes the requested variable name and reports the
  stored value back with the correct terminator.
- Variable storage is per terminal, not app-global.
- The embedded C API exposes set/get/enumeration entrypoints:
  `ghostty_surface_session_variable_set`,
  `ghostty_surface_session_variable_get`,
  `ghostty_surface_session_variable_count`, and
  `ghostty_surface_session_variable_at`.
- The macOS surface model exposes variables to Swift.
- AppleScript exposes terminal `variables` and accepts
  `perform action "set_session_variable:NAME=VALUE" on <terminal>`.
- Accessibility exposes `AXGhosttySessionVariables` and
  `AXGhosttyCodexSessionID`. `AXGhosttyCodexSessionID` reads
  `user.codexSessionId`.

### Context Menu Link Actions

Explicit right-click link actions must not depend on hover modifiers.

The motivation is that a context menu is already an explicit action on the item
under the pointer. Requiring the link-hover modifier again makes ordinary link
open and copy operations harder and hides existing link recognition from the
macOS menu surface.

- The macOS terminal context menu shows `Open Link` and `Copy Link` when the
  cursor is on a regex-detected link or OSC 8 hyperlink.
- The menu actions open or copy the link at the current cursor location while
  ignoring the configured link hover modifier requirement.
- The embedded C API keeps `ghostty_surface_has_link_at_cursor`,
  `ghostty_surface_open_link_at_cursor`, and
  `ghostty_surface_copy_link_at_cursor`.

### Local Workflow Commands

Keep the root `Justfile` for local operator workflows.

The motivation is frequent fork validation. Local build, release, test,
formatting, launch, and install commands should have short stable names so
merge work does not drift into one-off command variants.

- Top-level `just build`, `just run`, and `just install` choose useful macOS
  behavior when run on Darwin.
- `just build-core` builds with `-Demit-macos-app=false`.
- `just build-release` builds optimized output.
- `just test`, `just test-filter`, `just macos-build`, `just macos-test`, and
  `just macos-run` remain available.
- Formatting and check wrappers remain available for Zig, Swift, and other
  formatted files.
- `just install` defaults to `~/Applications/Ghostty.app` and honors
  `GHOSTTY_INSTALL_APP`.

## Main Source Anchors

| Area | Main files |
| --- | --- |
| Embedded C API | `include/ghostty.h`, `src/Surface.zig`, `src/apprt/embedded.zig` |
| Accessibility and context menus | `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` |
| AppleScript dictionary | `macos/Ghostty.sdef`, `macos/Sources/Features/AppleScript/AppDelegate+AppleScript.swift`, `macos/Sources/Features/AppleScript/ScriptTerminal.swift` |
| Split promotion and layout | `macos/Sources/App/macOS/MainMenu.xib`, `macos/Sources/Features/Terminal/BaseTerminalController.swift`, `macos/Sources/Features/Terminal/TerminalController.swift`, `macos/Sources/Features/Splits/SplitTree.swift` |
| Tab ID and tab color state | `macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift`, `macos/Sources/Features/Terminal/TerminalRestorable.swift`, `macos/Sources/Features/Terminal/TerminalRestorableState+InteralState.swift`, `macos/Sources/Features/Terminal/TerminalTabColor.swift` |
| Session variables | `macos/Sources/Ghostty/Ghostty.Surface.swift`, `src/terminal/Terminal.zig`, `src/terminal/osc.zig`, `src/terminal/osc/parsers/iterm2.zig`, `src/terminal/stream.zig`, `src/terminal/stream_terminal.zig`, `src/termio/stream_handler.zig` |
| Split tests | `macos/Tests/Splits/SplitTreeTests.swift` |
| Local commands | `Justfile` |

## Merge Verification

Start upstream fetches with an explicit destination ref. The local Git config
prunes fetched refs, so this form avoids deleting a temporary upstream ref
during the fetch:

```sh
git fetch --no-prune https://github.com/ghostty-org/ghostty.git \
  +refs/heads/main:refs/remotes/upstream/main
```

Before resolving conflicts, read the fork delta and this file. After resolving
conflicts, run at least:

```sh
git diff --check
git diff --cached --check
rg -n '^(<<<<<<<|=======|>>>>>>>)' macos include src
xmllint --noout macos/Ghostty.sdef
just build-core -Dversion-string=0.0.0-local-fork-verify
just build-release -Dversion-string=0.0.0-local-fork-verify
```

`rg` returns exit code 1 when it finds no conflict markers. That is the expected
clean result.

Run `just macos-test` when merge work touches AppleScript, split-tree behavior,
terminal restoration, or macOS surface behavior. For narrower Zig checks around
session variables, the current test names include:

```sh
zig build test -Dtest-filter="set and get session variables"
zig build test -Dtest-filter="OSC: 1337: test SetUserVar"
zig build test -Dtest-filter="OSC: 1337: test ReportVariable"
```

Manual checks are still useful for user-facing macOS behavior:

- Ask the scripting dictionary for terminal variables, tab color, and split
  commands after `macos/Ghostty.sdef` conflicts.
- Inspect surface and tab accessibility identifiers after AppKit tab or surface
  conflicts.
- Verify `AXSelectedTextRange` write behavior and bounds-for-range behavior with
  the automation client that depends on them.
- Right-click a detected link without holding the link hover modifier and check
  both `Open Link` and `Copy Link`.

## Merge Traps

These regressions have already appeared during upstream merges:

- Upstream imports the shared `String` from `src/main_c.zig`. If a merge
  reintroduces a second `String` definition in `src/apprt/embedded.zig`, keep
  the shared type and have copied strings return `.fromSlice(copy)`.
- Restoration state moved behind `TerminalRestorableState.InternalState`.
  Preserve `tabID` through that state wrapper as well as through undo-close
  state.
- `macos/Ghostty.sdef` and `ScriptTerminal.swift` are additive conflict
  hotspots. Keep the fork's `variables`, `tab color`, split layout, and
  promotion surfaces when also accepting new upstream terminal properties.

## Seed History

This file was seeded from these fork-only commits on top of the current
upstream branch:

| Commit | Purpose |
| --- | --- |
| `b86dc89e` | Accessibility selection setters and selection/cursor C API |
| `970fadac` | Accessibility bounds for wrapped lines |
| `4bb2dba7` | Cursor position reporting from the tracked cursor pin |
| `fae37608` | Focus-on-hover split behavior, AppleScript tab color, first local `Justfile` |
| `1c4ac388` | Expanded local `Justfile` workflows |
| `bca3edae` | Split promotion and related macOS automation/menu support |
| `93b22330` | Accessibility helper merge repair |
| `78d83fd9` | Surface accessibility identifiers |
| `dbcb667d` | AppleScript split percentage control |
| `b1c10fc4` | AppleScript split layout, rotation, and equalize controls |
| `8b3f2175` | Context-menu rotation label for rows versus columns |
| `521db7b1` | iTerm2 session variables across core, C API, macOS, AX, and AppleScript |
| `f836d4bb` | Stable native tab identifiers |
| `35a68a0c` | Context-menu link actions |

Update the required behavior above whenever this seed history stops describing
the intentional fork delta.
