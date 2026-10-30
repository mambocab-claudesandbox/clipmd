#!/usr/bin/env bats
#
# macOS clipboard tests. These exercise the real NSPasteboard path via
# `clipmd clip` and the daemon's `run` trigger, using pbcopy/pbpaste and
# osascript to inspect the pasteboard. They skip automatically off macOS.
#
# Run with:  bats test/clipboard.bats
# (Install bats:  brew install bats-core)

load helper

setup_file() { build_clipmd; }
setup() { require_macos; setup_clipmd_env; }
teardown() { teardown_clipmd_env; }

@test "clip: plain-text clipboard becomes Markdown" {
  printf '%s' 'https://x.ticketsystem.com/ABC-123' | pbcopy
  run "$CLIPMD_BIN" clip
  [ "$status" -eq 0 ]
  run pbpaste
  [ "$output" = '[ABC-123](https://x.ticketsystem.com/ABC-123)' ]
}

@test "clip: writes rich HTML and RTF flavors too" {
  printf '%s' 'https://x.ticketsystem.com/ABC-123' | pbcopy
  "$CLIPMD_BIN" clip
  info="$(osascript -e 'clipboard info')"
  [[ "$info" == *RTF* ]]
  [[ "$info" == *HTML* ]]
}

@test "clip: the RTF flavor carries a real hyperlink" {
  printf '%s' 'https://x.ticketsystem.com/ABC-123' | pbcopy
  "$CLIPMD_BIN" clip
  rtf="$(pasteboard_rtf)"
  [[ "$rtf" == *HYPERLINK* ]]
  [[ "$rtf" == *'https://x.ticketsystem.com/ABC-123'* ]]
  [[ "$rtf" == *'ABC-123'* ]]
}

@test "clip: an unmatched URL is left unchanged in plain text" {
  printf '%s' 'https://example.com/zzz' | pbcopy
  "$CLIPMD_BIN" clip
  run pbpaste
  [ "$output" = 'https://example.com/zzz' ]
}

@test "clip: reports matched/total on stderr" {
  printf '%s' 'https://x.ticketsystem.com/ABC-123' | pbcopy
  run "$CLIPMD_BIN" clip
  [ "$status" -eq 0 ]
  [[ "$output" == *'1/1 URLs matched'* ]]
}

@test "run: a running daemon transforms the clipboard on demand" {
  start_daemon
  printf '%s' 'https://x.ticketsystem.com/ABC-9' | pbcopy
  run "$CLIPMD_BIN" run
  [ "$status" -eq 0 ]
  [[ "$output" == OK* ]]
  run pbpaste
  [ "$output" = '[ABC-9](https://x.ticketsystem.com/ABC-9)' ]
}

# NOTE: there is intentionally no bats test for the NSStatusItem menu click
# or the Carbon global hotkey here. Driving either requires an interactive
# GUI session — but they each have their own glue (the Swift menu target for
# the menu, Carbon userData for the hotkey) that the socket `run` path doesn't
# touch, so this suite would not catch a regression in those handlers.
