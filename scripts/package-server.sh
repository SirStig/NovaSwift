#!/usr/bin/env bash
# Build the NovaSwift Dedicated Server release archives into dist/server/:
#   NovaSwiftServer-linux-x86_64.tar.gz   (container: swift:6.3-jammy, --platform linux/amd64)
#   NovaSwiftServer-linux-arm64.tar.gz    (container: swift:6.3-jammy, --platform linux/arm64)
#   NovaSwiftServer-macos-arm64.zip       (host, Apple Silicon)
# Windows is built on a Windows PC with scripts/package-server.ps1.
#
#   scripts/package-server.sh [linux-x86_64] [linux-arm64] [macos]      (default: all three)
#
# Linux builds need Docker (Colima is fine). The amd64 build on Apple Silicon runs under emulation: allow ~15 min
# the first time. SwiftPM caches live in .build-server-<arch>/ (git-ignored via .build-*/).
# Then publish a GitHub release tagged  server-v<version>  (the version in Sources/NovaSwiftServerCore/GameServer.swift,
# ServerVersion.current) and attach the archives. Releases are not created by this script.
# Then sign them (the server only self-updates from signed releases):
#   scripts/release-sign.sh --server --version <ver> --asset linux-x86_64=dist/server/NovaSwiftServer-linux-x86_64.tar.gz ...
# and attach server-update.json + server-update.json.sig to the same release.
set -euo pipefail
cd "$(dirname "$0")/.."
export COPYFILE_DISABLE=1   # no ._* AppleDouble files
# macOS bsdtar also stores extended attributes (com.apple.provenance, quarantine...) in the archive; GNU tar on the
# users' side then prints "Ignoring unknown extended header keyword LIBARCHIVE.xattr..." warnings. Leave them out.
TAR_FLAGS=()
tar --no-xattrs -cf /dev/null /dev/null 2>/dev/null && TAR_FLAGS+=(--no-xattrs)
tar --no-mac-metadata -cf /dev/null /dev/null 2>/dev/null && TAR_FLAGS+=(--no-mac-metadata)
OUT="dist/server"
IMAGE="${SWIFT_IMAGE:-swift:6.3-jammy}"
VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/NovaSwiftServerCore/GameServer.swift | head -1)"
TARGETS=("$@"); [ ${#TARGETS[@]} -eq 0 ] && TARGETS=(linux-x86_64 linux-arm64 macos)
mkdir -p "$OUT"

stage() {  # stage <dir> <binary> <extra files...>
  local d="$1" bin="$2"; shift 2
  rm -rf "$d"; mkdir -p "$d"
  cp "$bin" "$d/NovaSwiftServer"; chmod +x "$d/NovaSwiftServer"
  cp packaging/server/README.txt "$d/"
  for f in "$@"; do cp "$f" "$d/"; done
}

linux() {
  local arch="$1" platform
  case "$arch" in x86_64) platform=linux/amd64 ;; arm64) platform=linux/arm64 ;; esac
  command -v docker >/dev/null || { echo "docker is required for Linux builds" >&2; exit 1; }
  echo "==> Linux $arch ($platform) in $IMAGE"
  docker run --rm --platform "$platform" -v "$PWD":/src -w /src "$IMAGE" bash -c "
    set -e
    swift build -c release --product novaswift-server --static-swift-stdlib --scratch-path /src/.build-server-$arch
    cp /src/.build-server-$arch/release/novaswift-server /src/.build-server-$arch/NovaSwiftServer
    strip /src/.build-server-$arch/NovaSwiftServer || true"
  local d="$OUT/stage-linux-$arch"
  stage "$d" ".build-server-$arch/NovaSwiftServer" packaging/server/install-server.sh packaging/server/uninstall.sh packaging/server/docker-compose.yml packaging/server/Dockerfile
  command -v xattr >/dev/null && xattr -rc "$d" 2>/dev/null || true
  tar "${TAR_FLAGS[@]}" -C "$d" -czf "$OUT/NovaSwiftServer-linux-$arch.tar.gz" .
  rm -rf "$d"
  echo "    -> $OUT/NovaSwiftServer-linux-$arch.tar.gz ($(du -h "$OUT/NovaSwiftServer-linux-$arch.tar.gz" | cut -f1))"
}

macos() {
  echo "==> macOS arm64 (host)"
  swift build -c release --product novaswift-server --scratch-path .build-server-macos
  local d="$OUT/stage-macos"
  stage "$d" .build-server-macos/release/novaswift-server "packaging/server/macos/Start Server.command" packaging/server/macos/com.novaswift.server.plist
  command -v xattr >/dev/null && xattr -rc "$d" 2>/dev/null || true
  (cd "$d" && zip -qrX "../NovaSwiftServer-macos-arm64.zip" .)   # -X: no extra file attributes
  rm -rf "$d"
  echo "    -> $OUT/NovaSwiftServer-macos-arm64.zip"
}

for t in "${TARGETS[@]}"; do
  case "$t" in
    linux-x86_64) linux x86_64 ;;
    linux-arm64) linux arm64 ;;
    macos) macos ;;
    *) echo "unknown target $t" >&2; exit 2 ;;
  esac
done
echo "Done (server $VERSION). Windows: run scripts/package-server.ps1 on a Windows PC."
