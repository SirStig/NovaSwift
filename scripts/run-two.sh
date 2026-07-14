#!/usr/bin/env bash
# Build NovaSwift once and launch TWO copies on this Mac so you can test local
# multiplayer against yourself (host in one, jump to the same system in the other,
# chat, see each other). The second copy runs with NOVASWIFT_INSTANCE=2 so it
# keeps its OWN pilot saves (see AppInstance.swift) while both share the game data
# you've already imported.
#
# Usage:  scripts/run-two.sh
#
# The two windows land on top of each other — drag one aside. Quit both when done.
# Each instance discovers the other over local Wi-Fi/Bonjour (MultipeerTransport),
# so the machine's network must be up; no Game Center or internet needed.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="build/run-two"
APP="$DERIVED/Build/Products/Debug/NovaSwift.app"
BIN="$APP/Contents/MacOS/NovaSwift"

echo "→ Building NovaSwift (Debug, macOS)…"
xcodebuild \
  -project app/NovaSwift.xcodeproj \
  -scheme NovaSwift \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

if [ ! -x "$BIN" ]; then
  echo "✗ Build succeeded but binary not found at:" >&2
  echo "  $BIN" >&2
  exit 1
fi

echo "→ Launching instance 1 (primary store)…"
"$BIN" >/tmp/novaswift-1.log 2>&1 &
PID1=$!

# Small stagger so the two don't race to grab the same window position/first frame.
# (No shell `sleep` dependency beyond this convenience.)
sleep 1

echo "→ Launching instance 2 (NOVASWIFT_INSTANCE=2, isolated saves)…"
NOVASWIFT_INSTANCE=2 "$BIN" >/tmp/novaswift-2.log 2>&1 &
PID2=$!

echo
echo "✓ Two instances running (pids $PID1, $PID2)."
echo "  Instance 2 uses a separate pilot roster (Application Support/NovaSwift-2)."
echo "  Logs: /tmp/novaswift-1.log  /tmp/novaswift-2.log"
echo
echo "  In each: start/resume a pilot → in-game menu ▸ Host Local Co-op."
echo "  They auto-discover on the local network; put both in the SAME system to"
echo "  fly together, or open chat from the bubble button."
echo
echo "  Press Ctrl-C here to quit BOTH instances."

trap 'echo; echo "→ Quitting both…"; kill "$PID1" "$PID2" 2>/dev/null || true' INT TERM
wait
