#!/usr/bin/env bash
# Stop and remove the NovaSwift Dedicated Server service. Your settings and plug-ins in data/ are kept.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
systemctl disable --now novaswift-server 2>/dev/null || true
rm -f /etc/systemd/system/novaswift-server.service
systemctl daemon-reload 2>/dev/null || true
echo "Service removed. Delete $DIR to remove the program and its data."
