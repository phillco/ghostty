# Scriptable message search validation

Validated on 2026-11-02, compiled source `a54ac5c0fe94b4527495a4d6d679cdc040667dee`.
Toolchain: Zig 0.17.0, Xcode 27.2 / macOS SDK 27.2, arm64 Debug.

## Behavior

Search navigation queues requests until results establish the newest match.
Both directions initially select that match; subsequent requests retain their
order and wait for complete results before wrapping. Changing the needle or
ending the search discards queued navigation. Teardown also frees unconsumed
needle messages.

The read-only AppleScript terminal property `scrollback text` returns the entire
primary screen, including history and active rows. It joins soft-wrapped lines,
preserves whitespace, and continues reading the primary screen while the
alternate screen is active. It respects the `macos-applescript` configuration.
The C API `ghostty_surface_read_scrollback` uses the existing screen formatter;
callers release its result with `ghostty_surface_free_text`.

## Automated checks

```sh
zig build test -j4 -Demit-macos-app=false -Demit-xcframework=false \
  -Dtest-filter='pending navigation' -Dtest-filter='select prev' \
  -Dtest-filter='feed after complete discovers prepended' \
  -Dtest-filter='embedded scrollback text' --summary all
zig build -j4 -Demit-macos-app=false -Dxcframework-target=native --summary all
```

- Focused tests: **88/88 passed**, 104/104 build steps.
- Native core: **260/260 build steps passed**.
- macOS Debug application: build passed, with coverage disabled.
- Zig formatting, strict SwiftLint, C header syntax, dictionary XML, and
  whitespace checks passed. Independent source review found no remaining bugs.
- Signed the isolated test bundle and its nested code with Developer ID;
  installed deep/strict signature verification passed. CLI version, exported
  scrollback symbol, and compiled-source checksums passed.

Navigation tests cover more than 10,000 history rows, both directions, scrolling,
early application before completion, FIFO requests, restored history, needle
replacement, empty searches, and thread teardown. Fixtures cross actual page
boundaries because the active search snapshots whole pages. Scrollback tests
cover history, soft wrapping, alternate-screen isolation, and selection state.

## Runtime limits

The isolated test application launched in the background with scripting enabled,
initial windows disabled, and restoration disabled. Passive inspection confirmed
it remained inactive with zero windows. Existing applications retained their
binary checksums and process identities.

There was no existing test terminal. AppleScript terminal reads/actions and the
requested approximately 10,000-line `osascript` fetch timing were therefore
skipped. End-to-end scripting latency and rendered search behavior remain
unverified. No app-host or UI test targets were run.
