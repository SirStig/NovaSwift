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

# Curated free plug-ins / total conversions. Add more from
# https://andrews05.github.io/evstuff/ or https://download.escape-velocity.games/
PLUGINS=(
  "The_Frozen_Heart.zip"       # Martin Turner — classic adventure TC
  "Femme_Fatale.zip"           # Martin Turner — sequel TC
  "Polycon_EV.zip"             # AnubisTTP — full total conversion
  "EV_Override_for_Nova.zip"   # EV Override ported onto the Nova engine
  "EV_Classic_for_Nova.zip"    # EV Classic ported onto the Nova engine
  "Shields.zip"                # small gameplay plug-in (quick parser fixture)
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

echo
echo "Downloaded plug-ins into $DEST/ (git-ignored)."
echo "Inspect one:  .build/debug/evnova-extract types \"$DEST/The Frozen Heart/Nova Files/E3 Data.rez\""
