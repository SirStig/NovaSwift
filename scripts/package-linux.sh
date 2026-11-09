#!/usr/bin/env bash
# Build a self-contained Linux x86_64 (Steam Deck / SteamOS 3) package:
#   1. build the NovaSwiftGodot bridge (release)         [scripts/build-gdextension.sh]
#   2. collect the Swift runtime libs it needs into godot/bin/ (dynamic runtime,
#      $ORIGIN rpath) so a machine WITHOUT Swift can dlopen it
#   3. headless Godot export with the "Linux" preset
#   4. copy the runtime libs beside the executable, verify nothing is unresolved
#   5. tar.gz  ->  godot/export/NovaSwift-linux-x86_64.tar.gz
#
# Run it on an OLD-ENOUGH glibc (CI uses swift:6.3-jammy = glibc 2.35; SteamOS 3
# ships 2.38+). Building on a newer distro silently raises the glibc floor.
# No EV Nova data is ever included (BYO-data).
#
#   scripts/package-linux.sh [--godot /path/to/godot] [--skip-build] [--skip-export] [--libs-only]
#
# Normally driven from a Mac by scripts/package-linux-docker.sh, which runs
# --libs-only in a container, exports the .pck/binary with the host Godot, then
# runs --skip-build --skip-export in the container to assemble + verify.
#
# Why a dynamic Swift runtime and not -static-stdlib: SwiftGodot is itself a
# dynamic library that libNovaSwiftGodot.so links, and both would embed their own
# copy of the Swift runtime/metadata (duplicate type metadata and protocol
# conformance tables across two .so files is a known source of crashes and
# `as?` failures). One shared libswiftCore.so beside the libs is the safe layout.
set -euo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT:-godot}"
SKIP_BUILD=0
SKIP_EXPORT=0
LIBS_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --godot) GODOT="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-export) SKIP_EXPORT=1; shift ;;
    --libs-only) LIBS_ONLY=1; shift ;;   # stop after step 2 (used by package-linux-docker.sh)
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = "Linux" ] || { echo "error: run on Linux (CI container or a Linux box)" >&2; exit 1; }

BIN=godot/bin
OUT=godot/export/linux
ARCHIVE=godot/export/NovaSwift-linux-x86_64.tar.gz

# --- 1. bridge ---------------------------------------------------------------
if [ "$SKIP_BUILD" -eq 0 ]; then
  scripts/build-gdextension.sh release
fi
for f in libNovaSwiftGodot.so libSwiftGodot.so; do
  [ -f "$BIN/$f" ] || { echo "error: $BIN/$f missing (build first)" >&2; exit 1; }
done

# --- 2. Swift runtime closure ------------------------------------------------
# System libs every SteamOS/glibc box has; never bundle these (bundling libc or
# libstdc++ breaks more than it fixes).
is_system_lib() {
  case "$(basename "$1")" in
    linux-vdso.so*|ld-linux*|libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|\
    libutil.so*|libgcc_s.so*|libstdc++.so*|libresolv.so*|libnsl.so*) return 0 ;;
  esac
  return 1
}

# Resolve every transitive dependency of the bridge libs with ldd and copy the
# non-system ones next to them.
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/usr/lib/swift/linux"
collect() {
  local lib="$1" dep path
  while read -r dep _ path _; do
    case "$dep" in linux-vdso*|ld-linux*) continue ;; esac
    if [ "$path" = "not" ]; then echo "error: unresolved $dep for $lib" >&2; exit 1; fi
    [ -f "$path" ] || continue
    is_system_lib "$path" && continue
    [ -f "$BIN/$(basename "$path")" ] && continue
    cp -L "$path" "$BIN/"
    echo "  + $(basename "$path")"
    collect "$BIN/$(basename "$path")"
  done < <(LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:$BIN" ldd "$lib" 2>/dev/null | sed 's/^[[:space:]]*//')
}
echo "→ bundling Swift runtime libs into $BIN/"
collect "$BIN/libNovaSwiftGodot.so"
collect "$BIN/libSwiftGodot.so"

# Every shipped .so must find its siblings via $ORIGIN (RUNPATH/RPATH).
for so in "$BIN"/*.so*; do
  if ! readelf -d "$so" 2>/dev/null | grep -Eq "(RUNPATH|RPATH).*\\\$ORIGIN"; then
    if command -v patchelf >/dev/null 2>&1; then
      patchelf --set-rpath '$ORIGIN' "$so"
    else
      echo "warn: $(basename "$so") has no \$ORIGIN rpath and patchelf is absent" >&2
    fi
  fi
done

# Drop debug symbols from bridge + Swift runtime. Godot's export binary is already
# stripped; these .so files were shipping unstripped and dominated archive size.
echo "→ stripping shipped shared libraries"
if command -v strip >/dev/null 2>&1; then
  for so in "$BIN"/*.so*; do
    strip --strip-unneeded "$so" 2>/dev/null || strip -S "$so" 2>/dev/null || true
  done
fi

if [ "$LIBS_ONLY" -eq 1 ]; then
  echo "✓ Linux libs ready in $BIN (export + assemble: rerun with --skip-build --skip-export after exporting)"
  exit 0
fi

# --- 3. Godot export ---------------------------------------------------------
# Prefer a maintained thin custom template when present (scripts/build-godot-template.sh).
CUSTOM_LINUX_TEMPLATE="${CUSTOM_LINUX_TEMPLATE:-godot/export_templates/linux_release.x86_64}"
PRESETS_BAK=""
restore_presets() {
  if [ -n "${PRESETS_BAK:-}" ] && [ -f "$PRESETS_BAK" ]; then
    mv -f "$PRESETS_BAK" godot/export_presets.cfg
    PRESETS_BAK=""
  fi
}
trap restore_presets EXIT
if [ "$SKIP_EXPORT" -eq 0 ]; then
  command -v "$GODOT" >/dev/null 2>&1 || [ -x "$GODOT" ] || { echo "error: godot not found ($GODOT)" >&2; exit 1; }
  rm -rf "$OUT"; mkdir -p "$OUT"
  echo "→ importing project (first run builds .godot/)"
  "$GODOT" --headless --path godot --import >/dev/null 2>&1 || true   # import exits noisily on a clean tree
  if [ -x "$CUSTOM_LINUX_TEMPLATE" ]; then
    echo "→ using thin custom Linux template: $CUSTOM_LINUX_TEMPLATE"
    PRESETS_BAK="$(mktemp)"
    cp godot/export_presets.cfg "$PRESETS_BAK"
    python3 - "$CUSTOM_LINUX_TEMPLATE" <<'PY'
import pathlib, re, sys
tpl = pathlib.Path(sys.argv[1]).resolve().as_posix()
cfg = pathlib.Path("godot/export_presets.cfg")
text = cfg.read_text()
text2, n = re.subn(
    r'(?m)^(\[preset\.0\.options\][\s\S]*?)^custom_template/release=.*$',
    r'\1custom_template/release="' + tpl + '"',
    text, count=1)
if n != 1:
    raise SystemExit("failed to patch Linux custom_template/release in export_presets.cfg")
cfg.write_text(text2)
PY
  fi
  echo "→ exporting 'Linux' preset"
  "$GODOT" --headless --path godot --export-release "Linux" "$PWD/$OUT/NovaSwift.x86_64"
  [ -x "$OUT/NovaSwift.x86_64" ] || { echo "error: export produced no executable" >&2; exit 1; }
  restore_presets
fi

# --- 4. assemble -------------------------------------------------------------
echo "→ assembling $OUT"
cp -f "$BIN"/*.so* "$OUT/"
# Re-strip after copy in case anything was refreshed by the export step.
if command -v strip >/dev/null 2>&1; then
  for so in "$OUT"/*.so*; do
    strip --strip-unneeded "$so" 2>/dev/null || strip -S "$so" 2>/dev/null || true
  done
  strip --strip-unneeded "$OUT/NovaSwift.x86_64" 2>/dev/null || true
fi
install -m 755 packaging/linux/NovaSwift.sh "$OUT/NovaSwift.sh"
install -m 644 packaging/linux/novaswift.desktop "$OUT/novaswift.desktop"
cp -f godot/icon.png "$OUT/novaswift.png"
# Bundled decode-only ffmpeg for the original movies (scripts/build-mini-ffmpeg.sh linux).
[ -x godot/bin/ffmpeg/linux/ffmpeg ] || scripts/build-mini-ffmpeg.sh linux
install -m 755 godot/bin/ffmpeg/linux/ffmpeg "$OUT/ffmpeg"
install -m 644 godot/bin/ffmpeg/linux/LICENSE.txt "$OUT/FFMPEG-LICENSE.txt"
"$OUT/ffmpeg" -hide_banner -encoders | grep -q " mjpeg " || { echo "error: bundled ffmpeg does not run" >&2; exit 1; }
cat > "$OUT/README.txt" <<'TXT'
NOVA Swift — Linux / Steam Deck build
Run ./NovaSwift.sh (or add it to Steam as a Non-Steam Game).
This package contains NO game data. Put your own EV Nova data (the "Nova Files"
and "Nova Plug-ins" folders) in ~/.local/share/NovaSwift/data, or pick the
folder from the in-game "Game Data" screen.
See docs/PACKAGING.md in the source tree for Steam Deck setup.
TXT

# Verify: with a clean environment every library must resolve inside OUT or the system.
echo "→ verifying dependency resolution"
bad=0
for so in "$OUT"/*.so* $( [ -f "$OUT/ffmpeg" ] && echo "$OUT/ffmpeg" ); do
  if env -i PATH="$PATH" ldd "$so" | grep -q "not found"; then
    echo "error: unresolved dependencies in $(basename "$so"):" >&2
    env -i PATH="$PATH" ldd "$so" | grep "not found" >&2; bad=1
  fi
done
# glibc floor report (SteamOS 3 = 2.38+; fail if we need newer than 2.38).
maxglibc="$(objdump -T "$OUT"/*.so* "$OUT/NovaSwift.x86_64" $( [ -f "$OUT/ffmpeg" ] && echo "$OUT/ffmpeg" ) 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1 || true)"
echo "  highest GLIBC symbol required: ${maxglibc:-unknown}"
if [ -n "${maxglibc:-}" ] && [ "$(printf '%s\n2.38\n' "$maxglibc" | sort -V | tail -1)" != "2.38" ]; then
  echo "error: needs glibc $maxglibc > 2.38 (SteamOS 3) — build on an older distro" >&2; bad=1
fi
[ "$bad" -eq 0 ] || exit 1
# Size report (helps catch regressions before signing a release).
echo "→ package component sizes"
du -h "$OUT"/NovaSwift.x86_64 "$OUT"/libSwiftGodot.so "$OUT"/libNovaSwiftGodot.so "$OUT"/lib_FoundationICU.so* "$OUT"/ffmpeg "$OUT"/NovaSwift.pck 2>/dev/null | sort -hr || true
so_total="$(du -cb "$OUT"/*.so* 2>/dev/null | tail -1 | awk '{print $1}')"
echo "  all .so total: $(( so_total / 1024 / 1024 )) MB"

mkdir -p "$(dirname "$ARCHIVE")"
# No macOS metadata in the archive: COPYFILE_DISABLE drops ._* files; --no-xattrs/--no-mac-metadata (bsdtar) drop the
# extended attributes (com.apple.provenance...) that GNU tar warns about on the player's machine.
export COPYFILE_DISABLE=1
TAR_FLAGS=()
tar --no-xattrs -cf /dev/null /dev/null 2>/dev/null && TAR_FLAGS+=(--no-xattrs)
tar --no-mac-metadata -cf /dev/null /dev/null 2>/dev/null && TAR_FLAGS+=(--no-mac-metadata)
tar "${TAR_FLAGS[@]}" -C godot/export -czf "$ARCHIVE" --transform 's,^linux,NovaSwift,' linux
echo "✓ $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
