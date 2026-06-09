#!/usr/bin/env bash
# Shared helpers for the clipmd bats test suites.

# Repo root is the parent of this file's directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIPMD_BIN="${CLIPMD_BIN:-$REPO_ROOT/zig-out/bin/clipmd}"

# Build the binary once if it isn't present. Call from setup_file().
build_clipmd() {
  if [[ ! -x "$CLIPMD_BIN" ]]; then
    ( cd "$REPO_ROOT" && zig build ) || return 1
  fi
}

# Skip the current test unless we're on macOS with a usable pasteboard.
require_macos() {
  [[ "$(uname)" == "Darwin" ]] || skip "macOS-only (clipboard via NSPasteboard)"
  command -v pbcopy  >/dev/null || skip "pbcopy not available"
  command -v pbpaste >/dev/null || skip "pbpaste not available"
}

# Create a temp dir with a known config, and point clipmd at it via env.
setup_clipmd_env() {
  TMP="$(mktemp -d)"
  export CLIPMD_CONFIG="$TMP/config.zon"
  export CLIPMD_SOCK="$TMP/clipmd.sock"
  cat > "$CLIPMD_CONFIG" <<'EOF'
.{
    .hotkey = "cmd+shift+m",
    .rules = .{
        .{ .match = "*.ticketsystem.com/{id}", .display = "{id}" },
        .{ .match = "github.com/{owner}/{repo}/pull/{n}", .display = "{owner}/{repo}#{n}" },
    },
}
EOF
}

teardown_clipmd_env() {
  # Stop any daemon we started and remove the temp dir. Always succeed, even
  # when the test was skipped before setup ran.
  if [[ -n "${CLIPMD_DAEMON_PID:-}" ]]; then
    kill "$CLIPMD_DAEMON_PID" 2>/dev/null || true
    wait "$CLIPMD_DAEMON_PID" 2>/dev/null || true
    CLIPMD_DAEMON_PID=""
  fi
  if [[ -n "${TMP:-}" ]]; then
    rm -rf "$TMP"
  fi
  return 0
}

# Start the daemon in the background and wait until its socket answers PING.
start_daemon() {
  CLIPMD_DAEMON_LOG="${TMP}/daemon.log"
  "$CLIPMD_BIN" daemon >"$CLIPMD_DAEMON_LOG" 2>&1 &
  CLIPMD_DAEMON_PID=$!
  # The socket comes up before the macOS file watcher is attached. Wait
  # until the daemon prints its "ready" line so hot-reload tests don't race
  # the watcher setup.
  for _ in $(seq 1 50); do
    if [[ -S "$CLIPMD_SOCK" ]] && grep -q 'clipmd daemon ready' "$CLIPMD_DAEMON_LOG" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Decode the macOS pasteboard's RTF flavor to raw text (macOS only).
pasteboard_rtf() {
  osascript -e 'the clipboard as «class RTF »' \
    | perl -ne 'print pack("H*", $1) if /«data RTF ([0-9A-Fa-f]+)»/'
}
