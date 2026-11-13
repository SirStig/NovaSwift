#!/usr/bin/env bash
# NovaSwift Dedicated Server: one-line installer for Linux (x86_64 and arm64).
#
#   curl -fsSL https://raw.githubusercontent.com/SirStig/NovaSwift/main/packaging/server/install-server.sh | sudo bash
#
# What it does: downloads the right release for this CPU (refusing it unless its signature checks out), installs it
# to /opt/novaswift-server, creates a no-login `novaswiftd` system user, installs a sandboxed systemd service that starts
# at boot and always restarts, opens the game ports in ufw when ufw is active, and prints the admin password.
# The admin panel listens on 127.0.0.1 only (reach it through an SSH tunnel). Re-running the installer upgrades the
# program and keeps your settings, plug-ins and admin password.
#
# Options (after `bash -s --`):  --version X.Y.Z   --dir PATH   --admin-public   --no-firewall   --uninstall
#   --admin-public    listen for the admin panel on all addresses (plain HTTP!). Not recommended on the internet.
#   --allow-unsigned  install an archive whose signature can't be checked (an old release, a local file). Root runs it.
#   --allow-downgrade install a release older than the one already installed (older releases may have known problems).
# Env: NOVASWIFT_SERVER_URL=<url or file path of a .tar.gz>  to install a specific archive (testing, offline).
set -euo pipefail

REPO="SirStig/NovaSwift"
DIR="/opt/novaswift-server"
USER_NAME="${NOVASWIFT_SERVER_USER:-novaswiftd}"   # dedicated no-login service account
SERVICE="novaswift-server"
VERSION=""
ADMIN_PUBLIC=0
FIREWALL=1
UNINSTALL=0
ALLOW_UNSIGNED="${NOVASWIFT_ALLOW_UNSIGNED:-0}"
ALLOW_DOWNGRADE=0

say()  { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --dir) DIR="${2:?--dir needs a value}"; shift 2 ;;
    --admin-local) shift ;;                       # old flag: this is the default now
    --admin-public) ADMIN_PUBLIC=1; shift ;;
    --no-firewall) FIREWALL=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --allow-unsigned) ALLOW_UNSIGNED=1; shift ;;
    --allow-downgrade) ALLOW_DOWNGRADE=1; shift ;;
    -h|--help) awk 'NR > 1 && /^set -euo/ {exit} NR > 1' "$0"; exit 0 ;;
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
# Verify the release: server-update.json (+ .sig) is signed with the NovaSwift release key; it names the archive's
# SHA-256. This script runs as root, so anything that can't be verified (no openssl, no signature file, an archive that
# isn't a GitHub release) stops the install unless --allow-unsigned (or NOVASWIFT_ALLOW_UNSIGNED=1) says otherwise.
verify_release() {
  if [ "$ALLOW_UNSIGNED" = 1 ]; then
    say "WARNING: --allow-unsigned: installing $SRC without checking its signature."
    return 0
  fi
  command -v openssl >/dev/null || die "openssl is needed to check the release signature (install it, e.g. apt install openssl). To install without the check, re-run with --allow-unsigned."
  case "$SRC" in
    https://github.com/*/releases/download/*) ;;
    *) die "$SRC isn't a GitHub release, so its signature can't be checked. Re-run with --allow-unsigned only if you trust this file." ;;
  esac
  base="${SRC%/*}"
  if ! curl -fsSL -o "$TMP/server-update.json" "$base/server-update.json" 2>/dev/null \
     || ! curl -fsSL -o "$TMP/server-update.json.sig" "$base/server-update.json.sig" 2>/dev/null; then
    die "this release has no signature file (releases from before signing existed). Re-run with --allow-unsigned to install it anyway, or pick a newer --version."
  fi
  cat > "$TMP/pub.pem" <<'PEM'
-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsxd+RqoocTHT5QSLrR3b
7shSVvFq+dTNEBG3i1TLDZi88nLHOFzjkH6SEwQzXO8+7Gw1mdda62tONrsTTBGR
aGHxsyqN1ZhgCsDPfSU3ZP9vF40qNIUT9U+UZqyDz3zaewzCGjKqKaWffdGfMaIM
7G/hqUmktETckYuq+DxB9OTkqLHHnet5Tty/1x7Ks346CIDc2t+k6yMJ1WjKfGfz
ummEQCJ5vxGR7QLdjRA3jkahOsdcCmaVC+mbEYtm8dq7elOc+5/G9zKuQwubYa99
FQBEOJ+6OHHvV8A4XlWRSkbHGlibeatNKAHI0gUDKBcIFv0A+Iu+8hUtNWeiy8uR
N0S6ANpnI0mm3J0MvikqgYhaW0ITJNB2PJXc+/aSgiMVcoOsh2pqH226dwkXqPAD
Te4xG05ElJc9nUxJrVjCV+weqx2tureZoLGaJcXbZjfpu7upAGDezIaavozMJzPG
20tC82X0LkE4ePkD1e6eOBsv9fVkxRzNvXAujLPg/furmsuBsGzRXPVKzmNUuAk5
Sa9OKQkFyrry+EPHfbsJulsA5bo1YRTDVctgdf3iaCUowYtJQ6mBDPs+0cGl33eB
x0PUhioQ/sZlrBFjpsrdKew7aOJtFbF+uQeBiHJ4OZK+DQwVWAoPA7+atejV6Szq
6wJxmz2+XgbZTiNvvv8j3L8CAwEAAQ==
-----END PUBLIC KEY-----
PEM
  openssl dgst -sha256 -verify "$TMP/pub.pem" -signature "$TMP/server-update.json.sig" "$TMP/server-update.json" >/dev/null 2>&1 \
    || die "the release signature is NOT valid. Refusing to install."
  want="$(awk -v k="\"linux-$ARCH\":" '$1==k {f=1} f && /"sha256"/ {gsub(/[",]/, "", $2); print $2; exit}' "$TMP/server-update.json")"
  have="$(openssl dgst -sha256 "$TMP/server.tar.gz" | awk '{print $NF}')"
  [ -n "$want" ] && [ "$want" = "$have" ] || die "the download doesn't match the signed checksum. Refusing to install."
  # The signed manifest names its version: it must be the release that was asked for.
  SIGNED_VERSION="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$TMP/server-update.json" | tail -1)"
  [ -n "$SIGNED_VERSION" ] || die "the signed release file has no version. Refusing to install."
  if [ -n "$VERSION" ] && [ "$SIGNED_VERSION" != "${VERSION#v}" ]; then
    die "you asked for $VERSION but the signed release file is for $SIGNED_VERSION. Refusing to install."
  fi
  say "Signature and checksum verified (version $SIGNED_VERSION)."
}

# ver_lt A B: is version A older than B? Numbers compare as numbers; 1.0.0-beta.1 is older than 1.0.0.
ver_lt() {
  local a_core="${1%%-*}" b_core="${2%%-*}" a_pre="" b_pre=""
  [ "$1" != "$a_core" ] && a_pre="${1#*-}"
  [ "$2" != "$b_core" ] && b_pre="${2#*-}"
  if [ "$a_core" != "$b_core" ]; then
    [ "$(printf '%s\n%s\n' "$a_core" "$b_core" | sort -V | head -1)" = "$a_core" ]; return
  fi
  [ "$a_pre" = "$b_pre" ] && return 1
  [ -z "$a_pre" ] && return 1      # a final release is newer than its pre-releases
  [ -z "$b_pre" ] && return 0
  [ "$(printf '%s\n%s\n' "$a_pre" "$b_pre" | sort -V | head -1)" = "$a_pre" ]
}

SIGNED_VERSION=""
verify_release
# Don't silently roll an existing install back to an older (possibly vulnerable) release.
if [ -n "$SIGNED_VERSION" ] && [ -x "$DIR/NovaSwiftServer" ]; then
  INSTALLED="$("$DIR/NovaSwiftServer" --version 2>/dev/null | sed -n 's/^NovaSwift Dedicated Server \([^ ]*\).*/\1/p' | head -1)" || INSTALLED=""
  if [ -n "$INSTALLED" ] && ver_lt "$SIGNED_VERSION" "$INSTALLED"; then
    [ "$ALLOW_DOWNGRADE" = 1 ] || die "version $INSTALLED is installed and $SIGNED_VERSION is older. Older releases may have known security problems; re-run with --allow-downgrade if you really want it."
    say "WARNING: --allow-downgrade: replacing $INSTALLED with the older $SIGNED_VERSION."
  fi
fi
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
# The program and scripts belong to root (a compromised service can't rewrite them); only data/ is the service's.
install -o root -g root -m 0755 "$BIN" "$DIR/NovaSwiftServer"
for f in uninstall.sh README.txt docker-compose.yml Dockerfile install-server.sh; do
  src="$(find "$TMP" -type f -name "$f" | head -1)"; [ -n "$src" ] && install -o root -g root -m 0755 "$src" "$DIR/$f" || true
done
# Sidecar Swift runtime libs (present only if a release ships a dynamic-stdlib build).
PAYLOAD_DIR="$(dirname "$BIN")"
shopt -s nullglob
for so in "$PAYLOAD_DIR"/*.so "$PAYLOAD_DIR"/*.so.*; do
  [ -f "$so" ] || continue
  install -o root -g root -m 0755 "$so" "$DIR/$(basename "$so")"
done
shopt -u nullglob
chown root:root "$DIR"; chmod 755 "$DIR"
chown -R "$USER_NAME":"$USER_NAME" "$DIR/data"; chmod 700 "$DIR/data"

PASSWORD=""
if [ "$UPGRADE" = 0 ]; then
  say "Creating the configuration and admin password"
  as_user() { if command -v runuser >/dev/null 2>&1; then runuser -u "$USER_NAME" -- "$@"; else sudo -u "$USER_NAME" "$@"; fi; }
  PASSWORD="$(as_user "$DIR/NovaSwiftServer" --data "$DIR/data" --reset-admin-password 2>&1 | sed -n 's/^New admin password: //p')"
fi
# The admin panel is for the owner only: 127.0.0.1 (SSH tunnel) unless --admin-public. Applied on upgrades too, so an old
# install that listened on every address is closed.
if [ -f "$DIR/data/server.cfg" ]; then
  if [ "$ADMIN_PUBLIC" = 1 ]; then
    say "WARNING: the admin panel will listen on all addresses over plain HTTP (--admin-public)."
    sed -i 's/^bind = .*/bind = 0.0.0.0/' "$DIR/data/server.cfg"
  elif grep -q '^bind = 0\.0\.0\.0' "$DIR/data/server.cfg"; then
    say "Closing the admin panel to the network (it now listens on 127.0.0.1 only; use an SSH tunnel)."
    sed -i 's/^bind = .*/bind = 127.0.0.1/' "$DIR/data/server.cfg"
  fi
  chown "$USER_NAME":"$USER_NAME" "$DIR/data/server.cfg"; chmod 600 "$DIR/data/server.cfg"
fi

cat > "/etc/systemd/system/$SERVICE.service" <<UNIT
[Unit]
Description=NovaSwift Dedicated Server
Documentation=https://github.com/$REPO/blob/main/docs/SECURITY.md
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
User=$USER_NAME
Group=$USER_NAME
WorkingDirectory=$DIR/data
ExecStart=$DIR/NovaSwiftServer --data $DIR/data --no-browser --no-stdin
Restart=always
RestartSec=5
Environment=NOVASWIFT_SUPERVISED=1
LimitNOFILE=4096
LimitCORE=0
# libdispatch asks for a thread priority per QoS class; without this allowance the unprivileged service logs
# "Failed to set thread priority for worker thread ... errno=13" (EACCES). RLIMIT_NICE lets it set them without CAP_SYS_NICE.
LimitNICE=40
TasksMax=256
UMask=0077
# Sandbox: no new privileges or capabilities, a read-only system, a private /tmp and no devices, only IP + local sockets.
NoNewPrivileges=true
CapabilityBoundingSet=
AmbientCapabilities=
ProtectSystem=strict
ReadWritePaths=$DIR/data
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
ProcSubset=pid
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged
SystemCallErrorNumber=EPERM

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
echo "  Admin panel     : http://localhost:53737   (this server only; through an SSH tunnel, see below)"
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
echo "  Upgrade: run the installer command again (the sandbox keeps the program file read-only)."
echo "============================================================"
