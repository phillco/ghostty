set shell := ["zsh", "-lc"]

app_bundle := "zig-out/Ghostty.app"
install_app := env_var_or_default("GHOSTTY_INSTALL_APP", home_directory() + "/Applications/Ghostty.app")

default:
  @just --list

build:
  zig build

install: build
  mkdir -p "$(dirname '{{install_app}}')"
  rm -rf "{{install_app}}"
  ditto "{{app_bundle}}" "{{install_app}}"
