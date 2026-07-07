#!/usr/bin/env bash
# Download freely-distributed EV Nova community plug-ins & total conversions into
# data/plugins/. These double as real test fixtures for the parser.
#
# Source: andrews05's "EV Stuff" repo (https://andrews05.github.io/evstuff/).
# The site's files are stored in Git LFS; GitHub Pages serves only the LFS
# pointer, so we pull the real bytes from GitHub's LFS media endpoint.
#
# ⚠ These are fan works that still require you to own EV Nova to *play*. You may
#   freely download and use them; *redistributing* one inside a shipped app is a
#   per-author permission question — check each mod's readme.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="data/plugins"
mkdir -p "$DEST"

BASE="https://media.githubusercontent.com/media/andrews05/evstuff/master/plugins"

# The full free catalog hosted on andrews05's "EV Stuff" (all free downloads).
# Total conversions + gameplay plug-ins. Add more from
# https://download.escape-velocity.games/ or the Internet Archive collection.
PLUGINS=(
  # --- Total conversions / large scenarios ---
  "The_Frozen_Heart.zip"          # Martin Turner — classic adventure TC
  "Femme_Fatale.zip"              # Martin Turner — sequel TC
  "Polycon_EV.zip"                # AnubisTTP — full total conversion
  "EV_Override_for_Nova.zip"      # EV Override ported onto the Nova engine
  "EV_Classic_for_Nova.zip"       # EV Classic ported onto the Nova engine
  "rEV_1.1.zip"                   # remastered EV Classic scenario
  "Cold_Fusion_for_Nova_1.0.1.zip"
  # --- Gameplay / QoL plug-ins ---
  "Shields.zip"
  "Collision_Damage.zip"
  "Dodge_That.zip"
  "EVO_Extras.zip"
  "EVO_Facelift_1.0.7.zip"
)

fetch() { # filename
  local f="$1" out="$DEST/$1"
  if [ -f "$out" ]; then echo "✓ $f already downloaded"; return; fi
  echo "→ $f"
  if ! curl -fSL --retry 2 --max-time 300 -o "$out" "$BASE/$f"; then
    echo "  ✗ failed: $f (skipping)"; rm -f "$out"; return
  fi
  # LFS misconfig would leave a tiny pointer file; guard against it.
  if [ "$(wc -c < "$out")" -lt 1000 ]; then
    echo "  ✗ $f looks like an LFS pointer, not the real file — removing"; rm -f "$out"; return
  fi
  ( cd "$DEST" && unzip -oq "$f" ) && echo "  ✓ unzipped"
}

for p in "${PLUGINS[@]}"; do fetch "$p"; done

# --- Larger total conversions hosted on the community download server ---
# (Not on the andrews05 LFS host; fetched directly.)
EV_DL="https://download.escape-velocity.games"
fetch_url() { # url  filename  subfolder
  local url="$1" f="$2" sub="$3" out="$DEST/$2"
  if [ -d "$DEST/$sub" ]; then echo "✓ $sub already installed"; return; fi
  echo "→ $f"
  if ! curl -fSL --retry 2 --max-time 600 -o "$out" "$url"; then
    echo "  ✗ failed: $f (skipping)"; rm -f "$out"; return
  fi
  mkdir -p "$DEST/$sub"
  ( cd "$DEST/$sub" && unzip -oq "../$f" ) && echo "  ✓ unzipped into $sub/"
}

# ARPIA2 — Pace's acclaimed total conversion (new galaxy, govs, branching story).
fetch_url "$EV_DL/ARPIA2.zip" "ARPIA2.zip" "ARPIA2"

echo
echo "Downloaded plug-ins into $DEST/ (git-ignored)."
echo "Inspect one:  .build/debug/evnova-extract types \"$DEST/The Frozen Heart/Nova Files/E3 Data.rez\""
