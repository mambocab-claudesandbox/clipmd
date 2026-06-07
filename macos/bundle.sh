#!/usr/bin/env bash
#
# Build clipmd and package it as a macOS .app bundle that launches the
# menu-bar daemon. Run this on macOS (it needs the Xcode command-line tools so
# Zig can link AppKit/Carbon/Foundation).
#
# Usage:
#   macos/bundle.sh [-Doptimize=ReleaseFast]
#
# Result:
#   zig-out/clipmd.app   — double-click or `open zig-out/clipmd.app`
#
# The same binary inside the bundle is a normal CLI; symlink it onto your PATH
# to use the pipe/daemon commands from a terminal:
#   ln -s "$PWD/zig-out/clipmd.app/Contents/MacOS/clipmd" /usr/local/bin/clipmd

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Building clipmd (native macOS)"
zig build "$@"

APP="zig-out/clipmd.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp macos/Info.plist "$APP/Contents/Info.plist"
cp zig-out/bin/clipmd "$APP/Contents/MacOS/clipmd"

# The bundle's main executable must launch the daemon (menu bar + hotkey).
cat > "$APP/Contents/MacOS/clipmd-launcher" <<'LAUNCH'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/clipmd" daemon
LAUNCH
chmod +x "$APP/Contents/MacOS/clipmd-launcher"

# Point the bundle at the launcher.
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable clipmd-launcher" "$APP/Contents/Info.plist"

# Ad-hoc code signature so Gatekeeper/TCC treats it as a stable identity.
if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc signing"
  codesign --force --deep --sign - "$APP" || echo "   (codesign failed; you can still run it locally)"
fi

echo "==> Done: $APP"
echo "    Launch with:  open $APP"
echo "    Or run the daemon directly:  zig-out/bin/clipmd daemon"
