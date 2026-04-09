default:
    @just --list

# Top-level convenience wrappers.
run *args:
    if [ "$(uname -s)" = "Darwin" ] && [ -z "{{args}}" ]; then \
        just macos-build && just macos-run; \
    else \
        just run-zig {{args}}; \
    fi

build *args:
    if [ "$(uname -s)" = "Darwin" ] && [ -z "{{args}}" ]; then \
        just macos-build; \
    else \
        just build-zig {{args}}; \
    fi

# Core Zig workflows.
run-zig *args:
    zig build run -- {{args}}

build-zig *args:
    zig build {{args}}

build-core *args:
    zig build -Demit-macos-app=false {{args}}

test *args:
    zig build test {{args}}

test-filter filter *args:
    zig build test -Dtest-filter={{quote(filter)}} {{args}}

# Formatting and linting.
fmt-zig:
    zig fmt .

fmt-swift:
    swiftlint lint --strict --fix

fmt-other:
    prettier -w .

fmt:
    just fmt-zig
    just fmt-swift
    just fmt-other

check-zig:
    zig fmt --check .

check-swift:
    swiftlint lint --strict

check-other:
    prettier --check .

check:
    just check-zig
    just check-swift
    just check-other

# macOS app workflows mirror macos/build.nu so they don't require Nushell.
macos-build configuration="Debug" scheme="Ghostty":
    env -i HOME="${HOME}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        xcodebuild \
        -project macos/Ghostty.xcodeproj \
        -scheme {{scheme}} \
        -configuration {{configuration}} \
        "SYMROOT=build" \
        build

macos-test configuration="Debug" scheme="Ghostty":
    env -i HOME="${HOME}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        xcodebuild \
        -project macos/Ghostty.xcodeproj \
        -scheme {{scheme}} \
        -configuration {{configuration}} \
        "SYMROOT=build" \
        -skip-testing GhosttyUITests \
        test

macos-run configuration="Debug":
    app=""
    if [ -d "macos/build/{{configuration}}/Ghostty.app" ]; then \
        app="macos/build/{{configuration}}/Ghostty.app"; \
    elif [ -d "macos/macos/build/{{configuration}}/Ghostty.app" ]; then \
        app="macos/macos/build/{{configuration}}/Ghostty.app"; \
    else \
        echo "Ghostty.app not found for configuration {{configuration}}" >&2; \
        exit 1; \
    fi; \
    open -g "$app"

clean:
    rm -rf zig-out .zig-cache macos/build macos/GhosttyKit.xcframework
