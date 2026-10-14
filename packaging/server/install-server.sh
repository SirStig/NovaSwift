#!/usr/bin/env bash
# NovaSwift Dedicated Server: one-line installer for Linux (x86_64 and arm64).
#
#   curl -fsSL https://raw.githubusercontent.com/SirStig/NovaSwift/main/packaging/server/install-server.sh | sudo bash
#
# What it does: downloads the right release for this CPU, installs it to /opt/novaswift-server, creates a
# `novaswift` system user, installs a systemd service that starts at boot and always restarts, opens the game
# ports in ufw when ufw is active, and prints the admin panel address and password.
# Re-running it upgrades the program and keeps your settings, plug-ins and admin password.
#
# Options (after `bash -s --`):  --version X.Y.Z   --dir PATH   --admin-local   --no-firewall   --uninstall
# Env: NOVASWIFT_SERVER_URL=<url or file path of a .tar.gz>  to install a specific archive (testing, offline).
set -euo pipefail

REPO="SirStig/NovaSwift"
DIR="/opt/novaswift-server"
USER_NAME="novaswift"
SERVICE="novaswift-server"
VERSION=""
ADMIN_LOCAL=0
FIREWALL=1
UNINSTALL=0

say()  { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --dir) DIR="${2:?--dir needs a value}"; shift 2 ;;
    --admin-local) ADMIN_LOCAL=1; shift ;;
    --no-firewall) FIREWALL=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

[ "$(uname -s)" = "Linux" ] || die "this installer is for Linux. See https://sirstig.github.io/NovaSwift/dedicated-server.html for other systems."
if [ "$(id -u)" -ne 0 ]; then
  die "please run it as root:  curl -fsSL <url> | sudo bash"
fi

if [ "$UNINSTALL" = 1 ]; then
  say "Removing the service (your data in $DIR/data is kept; delete $DIR to remove it too)."
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE.service"
  systemctl daemon-reload 2>/dev/null || true
  rm -f "$DIR/NovaSwiftServer"
  exit 0
fi

case "$(uname -m)" in
  x86_64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "unsupported CPU $(uname -m) (x86_64 and arm64 are supported)" ;;
esac
ASSET="NovaSwiftServer-linux-$ARCH.tar.gz"

command -v systemctl >/dev/null || die "systemd is required. Without it, unpack the archive by hand and run ./NovaSwiftServer (see the guide)."
command -v curl >/dev/null || die "curl is required (apt install curl)."

# Runtime libraries the server links against (HTTPS for the plug-in catalog).
need_pkgs=""
if ! ldconfig -p 2>/dev/null | grep -q 'libcurl\.so\.4'; then need_pkgs="$need_pkgs libcurl4"; fi
if ! ldconfig -p 2>/dev/null | grep -q 'libxml2\.so\.2'; then need_pkgs="$need_pkgs libxml2"; fi
[ -d /etc/ssl/certs ] || need_pkgs="$need_pkgs ca-certificates"
if [ -n "$need_pkgs" ]; then
  say "Installing:$need_pkgs"
  if command -v apt-get >/dev/null; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $need_pkgs
  elif command -v dnf >/dev/null; then dnf install -y -q libcurl libxml2 ca-certificates
  elif command -v yum >/dev/null; then yum install -y -q libcurl libxml2 ca-certificates
  elif command -v pacman >/dev/null; then pacman -Sy --noconfirm curl libxml2 ca-certificates
  else die "please install libcurl and libxml2 with your package manager, then run this again."; fi
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ -n "${NOVASWIFT_SERVER_URL:-}" ]; then
  SRC="$NOVASWIFT_SERVER_URL"
else
  say "Looking up the latest server release..."
  if [ -n "$VERSION" ]; then
    SRC="https://github.com/$REPO/releases/download/server-v${VERSION#v}/$ASSET"
  else
    API="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30")" || die "couldn't reach GitHub. Check this machine's internet connection."
    SRC="$(printf '%s' "$API" | grep -o "\"browser_download_url\": *\"[^\"]*/server-v[^\"]*/$ASSET\"" | head -1 | sed 's/.*: *"//; s/"$//')"
    [ -n "$SRC" ] || die "no server release with $ASSET was found yet. Check https://github.com/$REPO/releases"
  fi
fi
say "Downloading $SRC"
case "$SRC" in
  http*) curl -fL --progress-bar -o "$TMP/server.tar.gz" "$SRC" || die "download failed." ;;
  *) cp "$SRC" "$TMP/server.tar.gz" ;;
esac
tar -xzf "$TMP/server.tar.gz" -C "$TMP"
BIN="$(find "$TMP" -type f -name NovaSwiftServer | head -1)"
[ -n "$BIN" ] || die "the archive didn't contain NovaSwiftServer."

if ! id "$USER_NAME" >/dev/null 2>&1; then
  say "Creating the '$USER_NAME' user"
  useradd --system --home-dir "$DIR" --shell /usr/sbin/nologin "$USER_NAME" 2>/dev/null || useradd -r -d "$DIR" -s /sbin/nologin "$USER_NAME"
fi
UPGRADE=0; [ -f "$DIR/data/server.cfg" ] && UPGRADE=1
mkdir -p "$DIR/data"
systemctl stop "$SERVICE" 2>/dev/null || true
install -m 0755 "$BIN" "$DIR/NovaSwiftServer"
for f in uninstall.sh README.txt; do
  src="$(find "$TMP" -type f -name "$f" | head -1)"; [ -n "$src" ] && install -m 0755 "$src" "$DIR/$f" || true
done
chown -R "$USER_NAME":"$USER_NAME" "$DIR"

PASSWORD=""
if [ "$UPGRADE" = 0 ]; then
  say "Creating the configuration and admin password"
  PASSWORD="$(sudo -u "$USER_NAME" "$DIR/NovaSwiftServer" --data "$DIR/data" --reset-admin-password 2>&1 | sed -n 's/^New admin password: //p')"
  if [ "$ADMIN_LOCAL" = 1 ] && [ -f "$DIR/data/server.cfg" ]; then sed -i 's/^bind = .*/bind = 127.0.0.1/' "$DIR/data/server.cfg"; fi
fi

cat > "/etc/systemd/system/$SERVICE.service" <<UNIT
[Unit]
Description=NovaSwift Dedicated Server
After=network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
WorkingDirectory=$DIR
ExecStart=$DIR/NovaSwiftServer --data $DIR/data --no-browser --no-stdin
Restart=always
RestartSec=5
Environment=NOVASWIFT_SUPERVISED=1
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=$DIR

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now "$SERVICE" >/dev/null

if [ "$FIREWALL" = 1 ] && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  say "Opening UDP 53735-53736 in ufw"
  ufw allow 53735:53736/udp >/dev/null
fi

sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then
  journalctl -u "$SERVICE" -n 20 --no-pager || true
  die "the service didn't start. See the log above (journalctl -u $SERVICE)."
fi

IP="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "============================================================"
echo "  NovaSwift Dedicated Server is running."
echo
echo "  Players join at : ${IP:-server-address}   (UDP 53735)"
echo "  Admin panel     : http://localhost:53737   (through an SSH tunnel, see below)"
if [ -n "$PASSWORD" ]; then
echo "  Admin password  : $PASSWORD     (shown only now, write it down)"
else
echo "  Admin password  : unchanged (forgot it?  sudo -u $USER_NAME $DIR/NovaSwiftServer --data $DIR/data --reset-admin-password)"
fi
echo
echo "  From your own computer:  ssh -L 53737:localhost:53737 <you>@${IP:-server}"
echo "  then open http://localhost:53737 and finish the setup wizard."
echo
echo "  Open UDP 53735-53736 in your cloud provider's firewall too."
echo "  Logs: journalctl -u $SERVICE -f        Remove: $DIR/uninstall.sh"
echo "============================================================"
