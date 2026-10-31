# Fork validation

This fork was replayed onto upstream `9bfa8ee9a1d73f99208c1f056c4e4b5783402ead`
(2026-10-31, version 1.4.1-dev). It requires Zig **0.17.0**. Ordinary fork commits
were replayed individually; the upstream merge was omitted. The previous main is
retained at `backup/main-before-upstream-20261031`. The previously uncommitted
Close Tabs to the Left feature was preserved as a separate commit.

## Ghostty Phil application identity

The fork builds as `Ghostty Phil.app`, with bundle ID `io.phillip.ghostty-phil`
(`io.phillip.ghostty-phil.debug` for Debug). Its install destination is
`~/Applications/Ghostty Phil.app`. Product/module names are separate: the Swift
module and Xcode scheme remain `Ghostty` for compatibility with nibs and tests.

Native preferences, saved state, Dock defaults, icon notifications, selection
pasteboard and pane drag identities are separate from stock Ghostty. The fork
continues reading the shared `~/.config/ghostty` configuration; its macOS
Application Support directory uses the fork identity. Upstream update checks are
disabled so they cannot install a stock release over the fork. Translation catalog
filenames retain the upstream domain.

## Promotion bindings

The macOS fork defaults are Cmd-P for a background tab and Cmd-Shift-P for a
foreground tab. Cmd-Shift-P therefore replaces upstream's command-palette default.
User configuration can override these defaults; `promotion.conf` is a standalone
example and is not installed into the live configuration.

| Config action | Destination | Selection |
| --- | --- | --- |
| `move_split_to_new_tab` | New native tab | Focus destination |
| `move_split_to_new_tab_background` | New native tab | Keep selected tab |
| `move_split_to_new_window` | New window | Focus destination |
| `move_split_to_new_window_background` | New window | Keep current window |

All four actions require a genuine split pane. Tab actions reject unsupported
window/fullscreen states, and background tab promotion rejects minimized parents.
`performable:` bindings pass through when promotion cannot be performed. Existing
menu/AppleScript promotion of an entire tab to a window remains available.

Promotion attaches an empty native tab before reparenting the live terminal,
preserving its surface identity and process. It retains the configured new-tab
position. Background destinations skip foreground presentation, application
activation, and initial SwiftUI focus. App-owned promotion undo resolves both
source and destination by their surviving pane identities, including after a tab
close is undone with a replacement controller. Native closing is deferred to retain the Tahoe crash workaround from PR #9512.

## Automated checks

Heavy builds run on `bedroom-mini`, using a dedicated workspace under
`~/src/buildbox/ghostty-rebase-20261031`. Its guard polls every five seconds, stops
only its own process group if combined dedicated Zig caches exceed 6 GiB or disk
free space falls below 8 GiB, and prunes only its own object cache between stages.
Shared caches and the global Xcode selection are not changed. The guard and stage
logs remain in that workspace.

```sh
just build-core -Dxcframework-target=native
zig build test-lib-vt -Dtest-filter='StringMap accessibility ranges'
zig build test -Demit-macos-app=false -Demit-xcframework=false \
  -Dtest-filter=input.Binding -Dtest-filter=apprt.action \
  -Dtest-filter='scroll-to-bottom paste defaults' \
  -Dtest-filter='embedded key event preserves viewport' \
  -Dtest-filter='macOS split promotion shortcuts' -Dtest-filter=input.command
python3 test/fork/standalone-swift.py -j 4
```

The standalone runner compiles actual split-tree, tab-color, input-event and undo
sources without a Ghostty app host. It copies tests into a temporary Swift package,
uses the actual C header, and extracts the unchanged production modifier conversion
into a minimal namespace. This validates those source components, not the complete
AppKit application. Compile the app separately using `macos/build.nu` or the
matching clean-environment Xcode invocation. Xcode still registered these temporary
app bundles despite `REGISTER_APP_WITH_LAUNCH_SERVICES=NO`; validation explicitly
unregistered only those bundle paths afterward. Do not rely on that setting to
prevent registration.

**Do not run `macos/build.nu --action test` or `xcodebuild test` during active use.**
The regular GhosttyTests target launches Ghostty via TEST_HOST even when
GhosttyUITests is skipped. No app-host tests, installation, GUI application launch,
live configuration edits, or interactive desktop checks are part of this run.

| Preserved feature | Automated evidence | Native acceptance still needed |
| --- | --- | --- |
| AX selection read/write | Byte/pin round trips, wrapped/reversed and Unicode selections, bounds/clamping | Selection setters through accessibility tools |
| AX wrapped-line bounds | Swift compilation and source review | Actual screen coordinates, CJK/emoji/combining text |
| Tracked cursor coordinates | Zig compilation and source review | Resize/reflow, alternate screen, scrollback caret |
| Hover split focus | Swift compilation and guards reviewed | Enter/move, drag suppression, palette/inactive windows |
| AppleScript tab colors | All ten code round trips and scripting dictionary alignment | Enabled/disabled scripting and per-tab colors |
| Menu/AppleScript promotion | Dictionary syntax and app compilation | Process/UUID continuity and correct target pane |
| Paste/synthetic-key scrolling | Config default/no-paste and C-to-core propagation; real NSEvent marker fixtures | Real paste, ordinary keys, dictation Return viewport |
| Close Tabs to the Left | Preserved original changes and app compilation | Correct neighbors/context tab, process confirmation, undo order |
| Foreground/background promotion | Parser, ABI, default shortcuts, split identity/layout and undo bookkeeping | Native selection, first responder, fullscreen and undo/redo |

The inherited AX frame helper counts UTF-16 units as display columns. Core Unicode
selection tests do not establish correct on-screen bounds for wide/grapheme cells.
That remains an explicit UI acceptance limit.

## Recorded results (2026-10-31)

Validated source revision: `ecb85f9f43cca90c4eb3`. The laptop's ordinary zsh and Fish
`zig` commands now resolve Homebrew Zig 0.17.0; `ZIG` overrides remain optional.

| Check | Result |
| --- | --- |
| Pure upstream native core and unsigned app baseline | Passed before replay |
| AX replay native core | Passed |
| Final native core | 260/260 build steps passed |
| Focused Zig binding, ABI, command, config and event suites | 184/184 tests passed |
| VT accessibility mapping suite, including shared supporting tests | 73/73 tests passed |
| Hostless Swift split, color/dictionary, NSEvent and undo suites | 75/75 tests passed across five suites |
| Final unsigned arm64 Debug app compile | Passed; application not executed |
| SwiftLint, Zig formatting, C header syntax, dictionary XML, Python Ruff | Passed |

The selected modern Xcode lacked Metal tools. The core and Zig tests used an
already-installed Xcode 16.4 / SDK 15.5 through per-process `DEVELOPER_DIR`; app and
hostless Swift compilation used Xcode 27.2 / SDK 27.2. Global Xcode selection
was not changed. Temporary app LaunchServices registrations were removed explicitly.

The standalone tests exposed an inherited expiry-record cleanup exclusivity crash.
The fix retains expiry records until collection mutation finishes and makes expiry
callbacks idempotent. A regression test clears redo history and reuses the manager.
The suite also verifies repeated undo/redo keeps the remaining redo history and
executes deferred mutations in FIFO order without registering duplicate inverses.

The dedicated Zig cache peaked at 2.64 GiB and finished at 2.59 GiB, below its
6 GiB limit. Free space never fell below the 8 GiB reserve (minimum sampled:
19.23 GiB); no pruning was necessary. The complete job workspace finished at
4.22 GiB. Snapshot provenance, stage exits and telemetry are preserved in
[validation-20261031.json](validation-20261031.json).

Stage logs, source manifests and cache/disk telemetry are under
`~/src/buildbox/ghostty-rebase-20261031/logs` on the mini. No app-host/UI tests were run.

## Native acceptance when authorized

- Promote horizontal, vertical, nested and zoomed panes. Check exact surface UUID,
  terminal output/process continuity, remaining layout and configured tab position.
- Cmd-P keeps the selected tab and gives its surviving pane the first responder;
  Cmd-Shift-P selects the destination. Check after queued callbacks settle, with
  existing tabs and with the app inactive. Test both new-window actions too.
- Lone panes, unsupported fullscreen, hidden-titlebar tabs and minimized background
  parents must remain unchanged. A rejected native tab attachment must leave the
  original terminal view attached and its process running.
- Undo/redo promotion; two promotions, undo twice, redo twice; undo immediately;
  close the destination, undo close, then undo promotion; close the source, undo
  close, undo promotion, then redo promotion. Repeat with a source containing
  multiple surviving panes and after allowing the old source controller to release.
  Check pane identity, visible ownership and absence of duplicate/blank tabs throughout.
- Exercise existing menu/context/AppleScript promotion, tab colors, hover focus,
  AX text selection/bounds/caret, paste viewport preservation, and left-tab closing.
