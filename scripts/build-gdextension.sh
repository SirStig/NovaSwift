#!/usr/bin/env bash
# Build the NovaSwiftGodot GDExtension (the Swift ↔ Godot bridge) for the host
# platform and copy the resulting dynamic library into godot/bin/, where
# godot/NovaSwift.gdextension expects it.
#
# Requires a Swift toolchain (swift.org) on PATH. Works on Linux, macOS, and
# Windows (Git Bash / MSYS with the Swift toolchain). See docs/GODOT_LAYER.md.
#
#   scripts/build-gdextension.sh [debug|release]   (default: debug)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
BRIDGE_DIR="godot/bridge"
OUT_DIR="godot/bin"
mkdir -p "$OUT_DIR"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: no 'swift' on PATH. Install the Swift toolchain from https://swift.org/download/" >&2
  exit 1
fi

echo "→ swift version:"; swift --version | sed 's/^/    /'
echo "→ building NovaSwiftGodot ($CONFIG) in $BRIDGE_DIR …"
swift build --package-path "$BRIDGE_DIR" -c "$CONFIG"

BIN_PATH="$(swift build --package-path "$BRIDGE_DIR" -c "$CONFIG" --show-bin-path)"

# The product name is `NovaSwiftGodot`; SwiftPM names the dynamic library per OS.
copied=0
for f in \
  "$BIN_PATH/libNovaSwiftGodot.so" \
  "$BIN_PATH/libNovaSwiftGodot.dylib" \
  "$BIN_PATH/NovaSwiftGodot.dll" \
  "$BIN_PATH/libNovaSwiftGodot.dll"; do
  if [ -f "$f" ]; then
    base="$(basename "$f")"
    # Normalise Windows name to NovaSwiftGodot.dll (what the .gdextension lists).
    [ "$base" = "libNovaSwiftGodot.dll" ] && base="NovaSwiftGodot.dll"
    cp -f "$f" "$OUT_DIR/$base"
    echo "✓ copied $base → $OUT_DIR/"
    copied=1
  fi
done

if [ "$copied" -eq 0 ]; then
  echo "error: no NovaSwiftGodot dynamic library found in $BIN_PATH" >&2
  ls -la "$BIN_PATH" >&2 || true
  exit 1
fi

# The bridge links SwiftGodot as a dynamic library too (an @loader_path /
# $ORIGIN rpath entry, not a static link), so it has to sit next to
# libNovaSwiftGodot in godot/bin/ or the extension fails to dlopen at runtime.
for f in \
  "$BIN_PATH/libSwiftGodot.so" \
  "$BIN_PATH/libSwiftGodot.dylib" \
  "$BIN_PATH/SwiftGodot.dll" \
  "$BIN_PATH/libSwiftGodot.dll"; do
  if [ -f "$f" ]; then
    base="$(basename "$f")"
    [ "$base" = "libSwiftGodot.dll" ] && base="SwiftGodot.dll"
    cp -f "$f" "$OUT_DIR/$base"
    echo "✓ copied $base → $OUT_DIR/"
  fi
done

echo "Done. Open godot/ in Godot 4.2+ (or run the exported build) to play the slice."
