#!/usr/bin/env bash
# Vendor the open-source reference implementations we study (as executable specs)
# into third_party/. None are linked at runtime; EVNovaKit reimplements in Swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TP="third_party"
mkdir -p "$TP"

clone() { # repo_url  dir
  local url="$1" dir="$TP/$2"
  if [ -d "$dir/.git" ]; then
    echo "✓ $2 already present"
  else
    echo "→ cloning $2 …"
    git clone --depth 1 -q "$url" "$dir"
  fi
}

clone https://github.com/andrews05/ResForge.git            ResForge       # Swift resource-fork/PICT/snd (spec)
clone https://github.com/TheDiamondProject/Graphite.git     Graphite       # C++ rleD/QuickDraw (spec)
clone https://github.com/mattsoulanille/NovaJS.git          NovaJS         # TS novaparse: every type's field layout
clone https://github.com/vasi/evnova-utils.git              evnova-utils   # Perl: field-semantics cross-check

echo
echo "Done. References in $TP/ (git-ignored)."
echo "Next: scripts/fetch-plugins.sh to download free community plug-ins as test data."
