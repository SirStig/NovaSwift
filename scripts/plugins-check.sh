#!/usr/bin/env bash
# Run godot/tests/plugins_load_selfcheck.gd over every plug-in in data/plugins and print a PASS/FAIL table.
#
# Each scenario is staged in a scratch folder (symlinks only -- nothing under data/ is modified, the user's real
# Godot pilots / prefs / ~/Library/Application Support/NovaSwift are never touched) and loaded two ways:
#   1. the shared Swift code the Apple app uses:  novaswift-extract merged-counts   (per-type resource counts)
#   2. Godot headless through the bridge, like the Plugins screen:  NovaPlugins + reload
# then the Godot run must reproduce the counts exactly and play a pilot (take off, render, land, services,
# galaxy map, jump) without SCRIPT ERROR / bridge errors / missing graphics or sounds.
#
#   scripts/plugins-check.sh                 all scenarios
#   scripts/plugins-check.sh "Femme Fatale"  scenarios whose name contains the text
#   PLUGCHECK_ALL=1 ...                      run the full pilot flow for every start scenario (slow)
#   PLUGCHECK_NOFLOW=1 ...                   load + parity + asset checks only
#   PLUGCHECK_KEEP=1 ...                     keep the scratch folder
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
DATA="${NOVA_DATA_DIR:-$REPO/data/base}"
PLUG="$REPO/data/plugins"
WORK="${PLUGCHECK_WORK:-${TMPDIR:-/tmp}/novaswift-plugcheck}"
FILTER="${1:-}"
EXTRACT="$REPO/.build/debug/novaswift-extract"

command -v godot >/dev/null || { echo "godot not on PATH" >&2; exit 2; }
[ -x "$EXTRACT" ] || swift build --product novaswift-extract >/dev/null 2>&1
[ -d "$PLUG" ] || { echo "no $PLUG" >&2; exit 2; }

rm -rf "$WORK"; mkdir -p "$WORK/src" "$WORK/logs"

# Shields ships zipped: unpack to scratch (data/ stays untouched).
if [ -f "$PLUG/Shields.zip" ]; then
  mkdir -p "$WORK/unz"; unzip -q -o "$PLUG/Shields.zip" -d "$WORK/unz"
fi

# link_tree SRC DST : mirror a folder with real directories and symlinked files (so isDirectory is true and
# loose media files -- mp3, mov -- sit where the plug-in put them).
link_tree() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  local f
  while IFS= read -r -d '' f; do
    local rel="${f#"$src"/}"
    if [ -d "$f" ]; then mkdir -p "$dst/$rel"; else mkdir -p "$(dirname "$dst/$rel")"; ln -s "$f" "$dst/$rel"; fi
  done < <(find "$src" -mindepth 1 ! -name '.DS_Store' -print0)
}

# "TC<-Plug-in" puts Plug-in's resource files into the total conversion's own Plug-Ins folder (the .nplay layout).
stage_entry() {   # stage_entry <name relative to data/plugins, or unz/...> <plugdir>
  local name="$1" dest="$2" src
  if [[ "$name" == *"<-"* ]]; then
    local tc="${name%%<-*}" rest="${name#*<-}" extra
    stage_entry "$tc" "$dest"
    mkdir -p "$dest/$(basename "$tc")/Plug-Ins"
    while [ -n "$rest" ]; do
      extra="${rest%%<-*}"; [[ "$rest" == *"<-"* ]] && rest="${rest#*<-}" || rest=""
      while IFS= read -r -d '' f; do ln -sf "$f" "$dest/$(basename "$tc")/Plug-Ins/$(basename "$f")"; done \
        < <(find "$PLUG/$extra" -maxdepth 1 -type f \( -name '*.rez' -o -name '*.ndat' \) -print0)
    done
    return
  fi
  case "$name" in
    unz/*) src="$WORK/$name" ;;
    *)     src="$PLUG/$name" ;;
  esac
  if [ -d "$src" ]; then link_tree "$src" "$dest/$(basename "$name")"
  else ln -s "$src" "$dest/$(basename "$name")"; fi
}

# name | entries (+ separated) | enable ids (comma, manual order; empty = original rule + first TC)
#      | per-TC add-ons "<TC id>=<id>[,<id>...]" (installed plug-ins put on the conversion's own list, NOT staged
#        into its Plug-Ins folder: the shared TCAddOns list both apps persist)
SCENARIOS=(
  "BASE (no plug-in)||"
  "ARPIA2|ARPIA2|"
  "Cold Fusion for Nova 1.0.1|Cold Fusion for Nova 1.0.1|"
  "Collision Damage|Collision Damage.rez|"
  "Dodge That|Dodge That.rez|"
  "EV Classic for Nova (TC)|EV Classic for Nova|"
  "EV Override for Nova (TC)|EV Override for Nova|"
  "EVO Extras: with Facelift|EVO Extras|EVO Extras/For use with EVO Facelift"
  "EVO Extras: without Facelift|EVO Extras|EVO Extras/For use without EVO Facelift"
  "EVO Facelift 1.0.7|EVO Facelift 1.0.7|"
  "EV Override + Facelift (TC plug-ins)|EV Override for Nova<-EVO Facelift 1.0.7|"
  "EV Override + Facelift + Extras|EV Override for Nova<-EVO Facelift 1.0.7<-EVO Extras/For use with EVO Facelift|"
  "EV Override + Facelift (per-TC list)|EV Override for Nova+EVO Facelift 1.0.7||EV Override for Nova=EVO Facelift 1.0.7"
  "EV Override + Facelift + Extras (per-TC list)|EV Override for Nova+EVO Facelift 1.0.7+EVO Extras||EV Override for Nova=EVO Facelift 1.0.7,EVO Extras/For use with EVO Facelift"
  "EV Override, global plug-ins not on its list|EV Override for Nova+EVO Facelift 1.0.7|"
  "Femme Fatale (TC)|Femme Fatale|"
  "Polycon EV (TC)|Polycon EV|"
  "Preambles & Walkthrough|Preambles & Walkthrough|"
  "The Frozen Heart (TC)|The Frozen Heart|"
  "rEV 1.1|rEV 1.1|"
  "rEV 1.1 + Optionals|rEV 1.1|rEV 1.1,rEV 1.1/Optionals"
  "Shields|unz/Shields|"
  "Shields + ARPIA2|unz/Shields+ARPIA2|"
)

IMPORT_SRC_DIR="$PLUG"
rows=(); fails=0
for sc in "${SCENARIOS[@]}"; do
  IFS='|' read -r name entries enable tcadd <<<"$sc"
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then continue; fi
  slug="$(echo "$name" | tr -c 'A-Za-z0-9\n' '_')"
  sd="$WORK/stage/$slug"; mkdir -p "$sd/plugins" "$sd/home" "$sd/pilots" "$sd/user"
  if [ -n "$entries" ]; then
    IFS='+' read -ra ents <<<"$entries"
    for e in "${ents[@]}"; do stage_entry "$e" "$sd/plugins"; done
  fi
  # 1. reference: the shared Swift merge Apple uses
  ref="$sd/ref.json"
  ref_args=("$DATA" "$sd/plugins"); [ -n "$enable" ] && ref_args+=("$enable")
  tcids=""; [ -n "$tcadd" ] && tcids="${tcadd#*=}"
  NOVASWIFT_TC_ADDONS="$tcids" "$EXTRACT" merged-counts "${ref_args[@]}" >"$ref" 2>"$sd/ref.err" || echo '{}' >"$ref"
  # media reference: every dësc movie / TC font and whether the shared Swift resolution finds the file
  media="$sd/media.json"
  NOVASWIFT_TC_ADDONS="$tcids" "$EXTRACT" desc-movies "${ref_args[@]}" >"$media" 2>"$sd/media.err" || echo '{}' >"$media"
  # 2. Godot
  log="$WORK/logs/$slug.log"
  NOVA_DATA_DIR="$DATA" NOVA_PLUGINS_DIR="$sd/plugins" NOVA_PLUGIN_HOME="$sd/home" \
  NOVA_PLUGIN_STATE="$sd/home/plugins-state.json" NOVA_PLUGIN_OFFLINE=1 NOVA_PILOTS_DIR="$sd/pilots" \
  NOVA_PLUGCHECK_NAME="$name" NOVA_PLUGCHECK_WORK="$sd/user" NOVA_PLUGCHECK_ENABLE="$enable" NOVA_PLUGCHECK_REF="$ref" \
  NOVA_PLUGCHECK_TCADDONS="$tcadd" NOVA_PLUGCHECK_MEDIA="$media" \
  NOVA_PLUGCHECK_ALL="${PLUGCHECK_ALL:-0}" NOVA_PLUGCHECK_NOFLOW="${PLUGCHECK_NOFLOW:-0}" \
    godot --headless --path godot -s res://tests/plugins_load_selfcheck.gd >"$log" 2>&1
  rc=$?
  grep -E "SCRIPT ERROR|Parse Error|Compile Error|^ERROR:|^WARNING:|bridge error" "$log" | grep -v "ObjectDB instance" | sort -u >"$sd/errors.txt"
  # engine/UI noise that also appears with no plug-in (the BASE run, first in the table) is not the plug-in's
  if [ -f "$WORK/base-errors.txt" ]; then errs=$(comm -23 "$sd/errors.txt" "$WORK/base-errors.txt" | wc -l | tr -d ' ')
  else errs=0; cp "$sd/errors.txt" "$WORK/base-errors.txt"; fi
  [ "$errs" != 0 ] && comm -23 "$sd/errors.txt" "$WORK/base-errors.txt" | head -5 | sed 's/^/     ! /' 
  res=$(grep -E "^RESULT\|" "$log" | tail -1)
  verdict="FAIL"
  if [ "$rc" = 0 ] && [ "$errs" = 0 ] && [[ "$res" == *"|PASS|"* ]]; then verdict="PASS"; fi
  [ "$verdict" = FAIL ] && fails=$((fails+1))
  nfail=$(grep -c "^  FAIL" "$log" | tr -d ' ')
  total=$(python3 -c "import json,sys;print(json.load(open('$ref')).get('total','?'))" 2>/dev/null)
  rows+=("$(printf '%-34s %-5s resources=%-7s check-failures=%-3s log-errors=%-3s' "$name" "$verdict" "$total" "$nfail" "$errs")")
  echo ">> $name: $verdict  (log $log)"
done

# ---- phase 2: install through the bridge's Import (zip / loose .rez), as the Plugins screen does ----------------
# zip or file | scenario whose merged counts it must reproduce ("-" = none) | bundle ids to enable (manual)
IMPORTS=(
  "ARPIA2.zip|ARPIA2|"
  "Cold_Fusion_for_Nova_1.0.1.zip|Cold Fusion for Nova 1.0.1|"
  "Collision_Damage.zip|Collision Damage|"
  "Collision Damage.rez|Collision Damage|"
  "Dodge_That.zip|Dodge That|"
  "Dodge That.rez|Dodge That|"
  "EV_Classic_for_Nova.zip|EV Classic for Nova (TC)|"
  "EV_Override_for_Nova.zip|EV Override for Nova (TC)|"
  "EVO_Extras.zip|-|"
  "EVO_Facelift_1.0.7.zip|EVO Facelift 1.0.7|"
  "Femme_Fatale.zip|Femme Fatale (TC)|"
  "Polycon_EV.zip|Polycon EV (TC)|"
  "The_Frozen_Heart.zip|The Frozen Heart (TC)|"
  "rEV_1.1.zip|rEV 1.1|"
  "Shields.zip|Shields|"
)
for im in "${IMPORTS[@]}"; do
  IFS='|' read -r file refname enable <<<"$im"
  name="import: $file"
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then continue; fi
  slug="imp_$(echo "$file" | tr -c 'A-Za-z0-9\n' '_')"
  sd="$WORK/stage/$slug"; mkdir -p "$sd/plugins" "$sd/home" "$sd/pilots" "$sd/user"
  refslug="$(echo "$refname" | tr -c 'A-Za-z0-9\n' '_')"
  ref="$WORK/stage/$refslug/ref.json"; [ -f "$ref" ] || ref=""
  log="$WORK/logs/$slug.log"
  NOVA_DATA_DIR="$DATA" NOVA_PLUGINS_DIR="$sd/plugins" NOVA_PLUGIN_HOME="$sd/home" \
  NOVA_PLUGIN_STATE="$sd/home/plugins-state.json" NOVA_PLUGIN_OFFLINE=1 NOVA_PILOTS_DIR="$sd/pilots" \
  NOVA_PLUGCHECK_NAME="$name" NOVA_PLUGCHECK_WORK="$sd/user" NOVA_PLUGCHECK_ENABLE="$enable" NOVA_PLUGCHECK_REF="$ref" \
  NOVA_PLUGCHECK_IMPORT="$IMPORT_SRC_DIR/$file" NOVA_PLUGCHECK_NOFLOW=1 \
    godot --headless --path godot -s res://tests/plugins_load_selfcheck.gd >"$log" 2>&1
  rc=$?
  res=$(grep -E "^RESULT\|" "$log" | tail -1)
  verdict="FAIL"; [ "$rc" = 0 ] && [[ "$res" == *"|PASS|"* ]] && verdict="PASS"
  [ "$verdict" = FAIL ] && fails=$((fails+1))
  nfail=$(grep -c "^  FAIL" "$log" | tr -d ' ')
  rows+=("$(printf '%-34s %-5s parity-ref=%-26s check-failures=%-3s' "$name" "$verdict" "${refname}" "$nfail")")
  echo ">> $name: $verdict  (log $log)"
done

echo
echo "================ plug-in load table ================"
printf '%s\n' "${rows[@]}"
echo "failures: $fails"
[ -z "${PLUGCHECK_KEEP:-}" ] && [ "$fails" = 0 ] && rm -rf "$WORK/stage"
exit $((fails > 0))
