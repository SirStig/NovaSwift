#!/usr/bin/env bash
# Run a NOVA Swift dedicated multiplayer server (headless, no window).
#   scripts/run-dedicated-server.sh [--port N] [--name "..."] [--password X] [--max-players N]
#                                   [--rules safe|full] [--config server.cfg] [--data DIR] [--no-lan] [--no-stdin]
# Looks for a packaged game next to this script (../NovaSwift, ../NovaSwift.x86_64, ../NovaSwift.exe) first,
# then falls back to `godot --path godot` from a source checkout (GODOT=/path/to/godot overrides the binary).
# Needs your EV Nova data (NOVA_DATA_DIR, --data, or the folder the game imported). Forward UDP <port>
# (default 53735) on your router for internet play. Console commands on stdin: help, status, players, kick,
# ban, say, rules, quit.
#
#   --public   print a ready-to-paste servers.json entry (and the pull-request link) for the public directory
#   --upnp     ask your router (UPnP) to forward the port; --region/--owner/--contact/--description/--address
#              fill the printed entry
#   --check [--port N] [--address HOST]
#              do not start a server: diagnose whether friends can reach UDP N (default 53735): local firewall,
#              your public address, CGNAT, and a live status query (see "Host a public server in 5 minutes")
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

if [[ "${1:-}" == "--check" ]]; then
  shift
  port=53735; addr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) port="$2"; shift 2 ;;
      --address) addr="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  qport=$(( port == 53735 ? 53736 : port + 1 ))
  echo "NovaSwift reachability check for UDP $port (status pings: UDP $qport)"
  pub=""
  if command -v curl >/dev/null; then pub="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"; fi
  [[ -n "$pub" ]] && echo "- Your public address looks like: $pub" || echo "- Couldn't detect your public address (offline? search \"what is my IP\")."
  lanip="$( (ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}') || true)"
  [[ -n "$lanip" ]] && echo "- This machine's local address: $lanip (forward UDP $port and $qport to it)"
  if [[ "$pub" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
    echo "! $pub is in the carrier-grade NAT range: port forwarding cannot work on this connection. Use Tailscale/ZeroTier, or a VPS."
  fi
  if command -v ufw >/dev/null; then echo "- Linux firewall: run  sudo ufw allow $port/udp && sudo ufw allow $qport/udp  if ufw is active."; fi
  target="${addr:-$pub}"
  if [[ -z "$target" ]]; then echo "Nothing to query. Pass --address HOST."; exit 1; fi
  if ! command -v python3 >/dev/null; then echo "python3 not found: skipping the live query."; exit 0; fi
  echo "- Sending a status query to $target:$qport (start the server first, in another terminal)..."
  if python3 - "$target" "$qport" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
try:
    s.sendto(b"NSQ1", (sys.argv[1], int(sys.argv[2])))
    data, _ = s.recvfrom(2048)
    sys.exit(0 if data.startswith(b"NSB1") else 2)
except Exception:
    sys.exit(1)
PY
  then echo "OK: the server answered. Friends can join $target:$port."
  else
    echo "No answer. Possible reasons: the server isn't running; the router isn't forwarding UDP $port and $qport (many routers can't loop back to their own public address, so test from another network or ask a friend); a firewall; or CGNAT."
    echo "Router can't forward? Options: --upnp (if your router supports it), Tailscale (everyone joins your 100.x address, no forwarding), or a cheap VPS."
    exit 1
  fi
  exit 0
fi

for cand in "$root/NovaSwift" "$root/NovaSwift.x86_64" "$root/NOVA Swift.x86_64" "$root/NovaSwift.exe" "$here/NovaSwift.x86_64" "$here/NovaSwift"; do
  if [[ -x "$cand" ]]; then
    exec "$cand" --headless -- --server "$@"
  fi
done

godot_bin="${GODOT:-$(command -v godot || command -v godot4 || true)}"
if [[ -z "$godot_bin" ]]; then
  echo "No packaged NovaSwift executable and no 'godot' on PATH. Set GODOT=/path/to/godot." >&2
  exit 1
fi
exec "$godot_bin" --headless --path "$root/godot" -- --server "$@"
