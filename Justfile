set shell := ["zsh", "-lc"]

app_bundle := "zig-out/Ghostty.app"
install_app := env_var_or_default("GHOSTTY_INSTALL_APP", home_directory() + "/Applications/Ghostty.app")

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

install:
    if [ "$(uname -s)" = "Darwin" ]; then \
        just macos-build Release; \
        if [ -d "macos/build/Release/Ghostty.app" ]; then \
            app="macos/build/Release/Ghostty.app"; \
        elif [ -d "macos/macos/build/Release/Ghostty.app" ]; then \
            app="macos/macos/build/Release/Ghostty.app"; \
        else \
            echo "Ghostty.app not found for Release build" >&2; \
            exit 1; \
        fi; \
        mkdir -p "$(dirname '{{install_app}}')"; \
        rm -rf "{{install_app}}"; \
        ditto "$app" "{{install_app}}"; \
    else \
        just build-release; \
        mkdir -p "$(dirname '{{install_app}}')"; \
        rm -rf "{{install_app}}"; \
        ditto "{{app_bundle}}" "{{install_app}}"; \
    fi

# Core Zig workflows.
run-zig *args:
    zig build run -- {{args}}

build-zig *args:
    zig build {{args}}

build-release *args:
    zig build --release=fast {{args}}

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
