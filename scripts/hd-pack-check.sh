#!/usr/bin/env bash
# Check an HD pack's live 3D hulls the way the game draws them (godot/tests/hd_pack_check.gd): every
# model loads, faces outward, and is lit to match its classic sprite; writes a report and contact
# sheets (3D over classic). Needs a GPU and a display: Godot opens a small window while it runs.
#
#   scripts/hd-pack-check.sh <pack.nsx | folder holding packs or plug-ins> [out dir]
#
# NOVA_DATA_DIR overrides the base game data (default data/base). Run from the repo root.
set -uo pipefail
REPO="$PWD"
DATA="${NOVA_DATA_DIR:-$REPO/data/base}"
[ $# -ge 1 ] || { echo "usage: $0 <pack.nsx | folder> [out dir]" >&2; exit 2; }
SRC="$1"
OUT="${2:-$REPO/hd-pack-check}"
[ -e "$SRC" ] || { echo "no such pack: $SRC" >&2; exit 2; }
[ -d "$DATA" ] || { echo "no game data at $DATA (set NOVA_DATA_DIR)" >&2; exit 2; }
command -v godot >/dev/null || { echo "godot not on PATH" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hd-pack-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/plugins" "$WORK/home" "$WORK/pilots" "$OUT"
# A real copy (pack discovery doesn't follow symlinks); an APFS clone where the system has one.
cp -cR "$SRC" "$WORK/plugins/" 2>/dev/null || cp -R "$SRC" "$WORK/plugins/"

NOVA_DATA_DIR="$DATA" NOVA_PLUGINS_DIR="$WORK/plugins" NOVA_PLUGIN_HOME="$WORK/home" \
NOVA_PLUGIN_STATE="$WORK/home/plugins-state.json" NOVA_PLUGIN_OFFLINE=1 NOVA_PILOTS_DIR="$WORK/pilots" \
NOVA_HDCHECK_OUT="$OUT" \
  godot --path godot --resolution 320x240 -s res://tests/hd_pack_check.gd 2>&1 \
  | grep -E '^(ok   |WARN |FAIL |HDCHECK|sheet |[0-9]+ ship types|built in)'
exit "${PIPESTATUS[0]}"
