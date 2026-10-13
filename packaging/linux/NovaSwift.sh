#!/bin/sh
# Launcher for the Linux / Steam Deck build. Needs no steam_appid and no Steam.
# The Swift runtime libs next to the executable are found through $ORIGIN rpath;
# this only makes the working directory deterministic (Steam launches Non-Steam
# games from odd cwds) and passes arguments through.
here="$(dirname "$(readlink -f "$0")")"
cd "$here" || exit 1
exec "$here/NovaSwift.x86_64" "$@"
