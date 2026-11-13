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
CUSTOM_MACOS_TEMPLATE="${CUSTOM_MACOS_TEMPLATE:-godot/export_templates/macos_template.app}"
PRESETS_BAK=""
restore_presets() {
  if [ -n "${PRESETS_BAK:-}" ] && [ -f "$PRESETS_BAK" ]; then
    mv -f "$PRESETS_BAK" godot/export_presets.cfg
    PRESETS_BAK=""
  fi
}
trap restore_presets EXIT
if [ -d "$CUSTOM_MACOS_TEMPLATE" ]; then
  echo "→ using thin custom macOS template: $CUSTOM_MACOS_TEMPLATE"
  PRESETS_BAK="$(mktemp)"
  cp godot/export_presets.cfg "$PRESETS_BAK"
  python3 - "$CUSTOM_MACOS_TEMPLATE" <<'PY'
import pathlib, re, sys
tpl = pathlib.Path(sys.argv[1]).resolve().as_posix()
cfg = pathlib.Path("godot/export_presets.cfg")
text = cfg.read_text()
text2, n = re.subn(
    r'(?m)^(\[preset\.2\.options\][\s\S]*?)^custom_template/release=.*$',
    r'\1custom_template/release="' + tpl + '"',
    text, count=1)
if n != 1:
    raise SystemExit("failed to patch macOS custom_template/release in export_presets.cfg")
cfg.write_text(text2)
PY
fi
"$GODOT" --headless --path godot --export-release macOS "$PWD/$OUT/NovaSwift.zip" 2>&1 | grep -E "ERROR" && exit 1 || true
restore_presets
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

# Strip debug symbols from the GDExtension dylibs (keep the Godot host as exported).
echo "→ stripping Frameworks dylibs"
for dylib in "$APP/Contents/Frameworks/"*.dylib; do
  [ -f "$dylib" ] || continue
  strip -x "$dylib" 2>/dev/null || true
  codesign --force --sign - "$dylib"   # strip breaks the dylib's own signature: re-sign it before sealing the app
done
# Re-seal after strip (ffmpeg was already signed above).
codesign --force --sign - --preserve-metadata=entitlements,flags,runtime "$APP"
codesign --verify --deep --strict "$APP"

echo "→ headless smoke test (extension must load)"
LOG="$(NOVA_DATA_DIR="${NOVA_DATA_DIR:-$PWD/data/base}" "$APP/Contents/MacOS/"* --headless --quit-after 120 2>&1 || true)"
echo "$LOG" | head -8
echo "$LOG" | grep -qE "SCRIPT ERROR|Can't open dynamic library|Parse Error" && { echo "error: smoke test failed" >&2; exit 1; }
echo "$LOG" | grep -q "loaded data" || echo "warn: no 'loaded data' line (is NOVA_DATA_DIR set to real data?)"

echo "→ package component sizes"
du -h "$APP/Contents/MacOS/"* "$APP/Contents/Frameworks/"*.dylib "$APP/Contents/Resources/"*.pck 2>/dev/null | sort -hr | head -20 || true

ditto -c -k --keepParent "$APP" "$OUT/NovaSwift-macos-arm64.zip"
echo "✓ $OUT/NovaSwift-macos-arm64.zip ($(du -h "$OUT/NovaSwift-macos-arm64.zip" | cut -f1)); app $(du -sh "$APP" | cut -f1)"
