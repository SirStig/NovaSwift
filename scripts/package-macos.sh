#!/usr/bin/env bash
# Build + export + verify the macOS (arm64) Godot app, ad-hoc signed.
#   scripts/package-macos.sh [--skip-build]
# Output: godot/export/macos/NovaSwift-macos-arm64.zip (+ unpacked app/ for testing)
# Needs: Swift (Xcode), Godot 4.7.2 + macOS export template. No EV Nova data is included.
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
TPL="$HOME/Library/Application Support/Godot/export_templates/4.7.2.stable"
OUT=godot/export/macos

[ "${1:-}" = "--skip-build" ] || scripts/build-gdextension.sh release

# The official macos.zip only ships a universal binary, but our preset is arm64 and Godot then
# looks for godot_macos_release.arm64. Thin the template once (idempotent).
if unzip -l "$TPL/macos.zip" | grep -q "godot_macos_release.universal"; then
  echo "→ thinning macOS export template to arm64"
  W="$(mktemp -d)"; ( cd "$W" && unzip -q "$TPL/macos.zip" && cd macos_template.app/Contents/MacOS &&
    for k in release debug; do lipo -thin arm64 godot_macos_$k.universal -output godot_macos_$k.arm64; rm godot_macos_$k.universal; done &&
    cd "$W" && zip -qr macos_arm64.zip macos_template.app )
  cp "$W/macos_arm64.zip" "$TPL/macos.zip"; rm -rf "$W"
fi

rm -rf "$OUT"; mkdir -p "$OUT/app"
"$GODOT" --headless --path godot --import >/dev/null 2>&1 || true
"$GODOT" --headless --path godot --export-release macOS "$PWD/$OUT/NovaSwift.zip" 2>&1 | grep -E "ERROR" && exit 1 || true
ditto -x -k "$OUT/NovaSwift.zip" "$OUT/app"
APP="$(ls -d "$OUT"/app/*.app)"
# Godot embeds dylibs in Contents/Frameworks and signs the bundle ad hoc itself (entitlements from the
# preset). Do NOT re-sign with a custom entitlement set: that hung the app at startup.
# Bundled decode-only ffmpeg for the original movies (scripts/build-mini-ffmpeg.sh macos), beside the
# executable where Movies.gd looks first. Adding it breaks the bundle seal, so re-seal ad hoc while
# PRESERVING Godot's entitlements/flags (a custom entitlement set is what hung the app before).
[ -x godot/bin/ffmpeg/macos/ffmpeg ] || scripts/build-mini-ffmpeg.sh macos
cp godot/bin/ffmpeg/macos/ffmpeg "$APP/Contents/MacOS/ffmpeg"
cp godot/bin/ffmpeg/macos/LICENSE.txt "$APP/Contents/Resources/FFMPEG-LICENSE.txt"
codesign --force --sign - "$APP/Contents/MacOS/ffmpeg"
codesign --force --sign - --preserve-metadata=entitlements,flags,runtime "$APP"
codesign --verify --deep --strict "$APP"
for l in libNovaSwiftGodot libSwiftGodot; do [ -f "$APP/Contents/Frameworks/$l.dylib" ] || { echo "error: $l.dylib not embedded" >&2; exit 1; }; done

echo "→ headless smoke test (extension must load)"
LOG="$(NOVA_DATA_DIR="${NOVA_DATA_DIR:-$PWD/data/base}" "$APP/Contents/MacOS/"* --headless --quit-after 120 2>&1 || true)"
echo "$LOG" | head -8
echo "$LOG" | grep -qE "SCRIPT ERROR|Can't open dynamic library|Parse Error" && { echo "error: smoke test failed" >&2; exit 1; }
echo "$LOG" | grep -q "loaded data" || echo "warn: no 'loaded data' line (is NOVA_DATA_DIR set to real data?)"

ditto -c -k --keepParent "$APP" "$OUT/NovaSwift-macos-arm64.zip"
echo "✓ $OUT/NovaSwift-macos-arm64.zip ($(du -h "$OUT/NovaSwift-macos-arm64.zip" | cut -f1)); app $(du -sh "$APP" | cut -f1)"
