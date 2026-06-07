#!/usr/bin/env bats
#
# Portable tests for clipmd's transformation behavior (pipes + daemon). These
# run on any platform; they do not touch the OS clipboard.

load helper

setup_file() { build_clipmd; }
setup() { setup_clipmd_env; }
teardown() { teardown_clipmd_env; }

@test "markdown: matched ticket URL becomes a link" {
  run bash -c "printf '%s' 'https://x.ticketsystem.com/ABC-123' | '$CLIPMD_BIN'"
  [ "$status" -eq 0 ]
  [ "$output" = '[ABC-123](https://x.ticketsystem.com/ABC-123)' ]
}

@test "markdown: github rule with multiple captures" {
  run bash -c "printf '%s' 'see https://github.com/ziglang/zig/pull/42.' | '$CLIPMD_BIN'"
  [ "$status" -eq 0 ]
  [ "$output" = 'see [ziglang/zig#42](https://github.com/ziglang/zig/pull/42).' ]
}

@test "markdown: unmatched URL is left untouched" {
  run bash -c "printf '%s' 'https://example.com/nope' | '$CLIPMD_BIN'"
  [ "$status" -eq 0 ]
  [ "$output" = 'https://example.com/nope' ]
}

@test "html: matched URL becomes a hyperlink" {
  run bash -c "printf '%s' 'https://x.ticketsystem.com/ABC-123' | '$CLIPMD_BIN' -f html"
  [ "$status" -eq 0 ]
  [ "$output" = '<a href="https://x.ticketsystem.com/ABC-123">ABC-123</a>' ]
}

@test "rtf: output is an RTF doc with a HYPERLINK field" {
  run bash -c "printf '%s' 'https://x.ticketsystem.com/ABC-123' | '$CLIPMD_BIN' -f rtf"
  [ "$status" -eq 0 ]
  [[ "$output" == '{\rtf1'* ]]
  [[ "$output" == *'HYPERLINK "https://x.ticketsystem.com/ABC-123"'* ]]
  [[ "$output" == *'ABC-123'* ]]
}

@test "daemon: transform a pipe through the running daemon" {
  start_daemon
  run bash -c "printf '%s' 'https://x.ticketsystem.com/ABC-1' | '$CLIPMD_BIN' send"
  [ "$status" -eq 0 ]
  [ "$output" = '[ABC-1](https://x.ticketsystem.com/ABC-1)' ]
}

@test "daemon: hot-reloads config when the file changes" {
  [[ "$(uname)" =~ ^(Linux|Darwin)$ ]] || skip "file watcher is Linux/macOS only"
  start_daemon

  # Baseline: the initial rule yields a bare id.
  run bash -c "printf '%s' 'https://x.ticketsystem.com/ABC-1' | '$CLIPMD_BIN' send"
  [ "$output" = '[ABC-1](https://x.ticketsystem.com/ABC-1)' ]

  # Edit the config (new display template). The daemon should pick it up
  # via the directory watcher, with no restart.
  cat > "$CLIPMD_CONFIG" <<'EOF'
.{ .rules = .{ .{ .match = "*.ticketsystem.com/{id}", .display = "T-{id}" } } }
EOF

  local ok=0 out
  for _ in $(seq 1 50); do
    out="$(printf '%s' 'https://x.ticketsystem.com/ABC-1' | "$CLIPMD_BIN" send)"
    if [ "$out" = '[T-ABC-1](https://x.ticketsystem.com/ABC-1)' ]; then ok=1; break; fi
    sleep 0.1
  done
  [ "$ok" -eq 1 ]
}

@test "daemon: a broken config edit is ignored (keeps serving)" {
  [[ "$(uname)" =~ ^(Linux|Darwin)$ ]] || skip "file watcher is Linux/macOS only"
  start_daemon

  # Write invalid ZON; the daemon must keep using the previous good config.
  printf 'this is not valid zon\n' > "$CLIPMD_CONFIG"
  sleep 0.5
  run bash -c "printf '%s' 'https://x.ticketsystem.com/ABC-1' | '$CLIPMD_BIN' send"
  [ "$status" -eq 0 ]
  [ "$output" = '[ABC-1](https://x.ticketsystem.com/ABC-1)' ]
}

@test "config: malformed hotkey fails hard at startup" {
  printf '.{ .hotkey = "cmd+nope" }\n' > "$CLIPMD_CONFIG"
  run bash -c "printf x | '$CLIPMD_BIN'"
  [ "$status" -eq 1 ]
  [[ "$output" == *InvalidHotkey* ]]
}

@test "config: invalid ZON fails hard" {
  printf 'this is not zon\n' > "$CLIPMD_CONFIG"
  run bash -c "printf x | '$CLIPMD_BIN'"
  [ "$status" -eq 1 ]
  [[ "$output" == *ParseZon* ]]
}

@test "config: unknown field fails hard" {
  printf '.{ .hotky = "cmd+m" }\n' > "$CLIPMD_CONFIG"
  run bash -c "printf x | '$CLIPMD_BIN'"
  [ "$status" -eq 1 ]
  [[ "$output" == *ParseZon* ]]
}

@test "config show lists rules and the hotkey" {
  run "$CLIPMD_BIN" config show
  [ "$status" -eq 0 ]
  [[ "$output" == *'*.ticketsystem.com/{id} => {id}'* ]]
  [[ "$output" == *'hotkey: cmd+shift+m'* ]]
}
