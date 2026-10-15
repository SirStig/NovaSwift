#!/bin/sh
# Launcher for the Linux / Steam Deck build. Needs no steam_appid and no Steam.
# The Swift runtime libs next to the executable are found through $ORIGIN rpath;
# this only makes the working directory deterministic (Steam launches Non-Steam
# games from odd cwds) and passes arguments through.
here="$(dirname "$(readlink -f "$0")")"
cd "$here" || exit 1

# Desktop entry with absolute paths. A .desktop file cannot point next to itself
# portably: the shipped one relied on %k, which only a desktop launcher expands,
# so adding it to Steam ("Add a Non-Steam Game") produced a shortcut that did
# nothing. Rewrite it here, in the game folder and in ~/.local/share/applications
# (which is also what Steam's Non-Steam Game list reads), whenever the install
# path changes. Best effort: never blocks the game from starting.
write_desktop() {
  # Exec quoting (desktop entry spec): " ` $ \ need a backslash, which the string
  # escape layer then doubles; % is a field code, so %%.
  esc=$(printf '%s' "$here" | sed -e 's/\\/\\\\\\\\/g' -e 's/["`$]/\\\\&/g' -e 's/%/%%/g')
  pesc=$(printf '%s' "$here" | sed 's/\\/\\\\/g')   # Path=/Icon= are plain strings: \ only
  entry="[Desktop Entry]
Type=Application
Name=NOVA Swift
Comment=EV Nova engine port (bring your own EV Nova data)
Exec=\"$esc/NovaSwift.sh\"
Path=$pesc
Icon=$pesc/novaswift.png
Terminal=false
Categories=Game;"
  for f in "$here/novaswift.desktop" "${XDG_DATA_HOME:-$HOME/.local/share}/applications/novaswift.desktop"; do
    [ "$(cat "$f" 2>/dev/null)" = "$entry" ] && continue
    mkdir -p "$(dirname "$f")" 2>/dev/null && printf '%s\n' "$entry" > "$f" 2>/dev/null && chmod 755 "$f" 2>/dev/null
  done
}
write_desktop || true

exec "$here/NovaSwift.x86_64" "$@"
