#!/usr/bin/env bash
# Build the Linux x86_64 / Steam Deck package from a Mac (or any host) with a
# container runtime. Output: godot/export/NovaSwift-linux-x86_64.tar.gz
#
#   scripts/package-linux-docker.sh [--no-export-on-host]
#
# Three stages:
#   1. IN CONTAINER (swift:6.3-jammy, linux/amd64, glibc 2.35): build the Swift
#      bridge + bundle the Swift runtime libs into godot/bin   (package-linux.sh --libs-only)
#   2. ON THE HOST: `godot --export-release Linux` produces the .pck + Linux
#      template binary (Godot exports Linux from macOS; only the .so needs Linux).
#      With --no-export-on-host this happens in the container instead, which then
#      needs Godot + templates installed there (not set up by this script).
#   3. IN CONTAINER: assemble, ldd/glibc(<=2.38) verification, tar.gz
#      (package-linux.sh --skip-build --skip-export)
#
# Speed: on Apple Silicon the amd64 image runs under emulation. Colima with
# `--vm-type vz --vz-rosetta` (Rosetta) is ~2-4x faster than qemu; first build
# still takes several minutes (SwiftGodot is large). SwiftPM caches persist in
# .swiftpm-cache/ and the Linux build dir in godot/bridge/.build-linux/ (both git-ignored).
#
# Needs: docker or podman; host Godot 4.7.2 with Linux export templates
# (~/Library/Application Support/Godot/export_templates/4.7.2.stable/linux_release.x86_64).
set -euo pipefail
cd "$(dirname "$0")/.."
export COPYFILE_DISABLE=1   # no ._* AppleDouble files in archives

IMAGE="${SWIFT_IMAGE:-swift:6.3-jammy}"
GODOT="${GODOT:-godot}"
HOST_EXPORT=1
[ "${1:-}" = "--no-export-on-host" ] && HOST_EXPORT=0

RT=""
for c in docker podman; do
  if command -v "$c" >/dev/null 2>&1 && "$c" info >/dev/null 2>&1; then RT="$c"; break; fi
done
if [ -z "$RT" ]; then
  cat >&2 <<'MSG'
error: no working container runtime (docker/podman) found.

Install one on macOS (Apple Silicon), e.g. Colima with Rosetta:
    brew install colima docker
    colima start --vm-type vz --vz-rosetta --cpu 4 --memory 8
Alternative (qemu, slower; needs the guest agents):
    brew install colima docker lima-additional-guestagents
    colima start --arch x86_64 --cpu 4 --memory 8
Then re-run this script.
MSG
  exit 1
fi
echo "→ runtime: $RT   image: $IMAGE (linux/amd64)"

mkdir -p .swiftpm-cache/cache .swiftpm-cache/swiftpm godot/export
run() {
  "$RT" run --rm --platform linux/amd64 \
    -v "$PWD":/work -w /work \
    -v "$PWD/.swiftpm-cache/cache":/root/.cache \
    -v "$PWD/.swiftpm-cache/swiftpm":/root/.swiftpm \
    -e BUILD_SCRATCH=.build-linux \
    "$IMAGE" bash -lc "$1"
}
PREP='command -v patchelf >/dev/null && command -v objdump >/dev/null || (apt-get update -qq && apt-get install -y -qq binutils patchelf >/dev/null)'

# Stale macOS libs must not leak into the Linux export (gdextension picks by platform,
# but keep godot/bin tidy): only .so files are produced here.
echo "→ [1/3] build bridge + collect runtime libs (container)"
run "$PREP && scripts/package-linux.sh --libs-only"

if [ "$HOST_EXPORT" -eq 1 ]; then
  echo "→ [2/3] export Linux preset (host Godot)"
  command -v "$GODOT" >/dev/null || { echo "error: godot not on PATH (set GODOT=)" >&2; exit 1; }
  rm -rf godot/export/linux; mkdir -p godot/export/linux
  "$GODOT" --headless --path godot --import >/dev/null 2>&1 || true
  "$GODOT" --headless --path godot --export-release "Linux" "$PWD/godot/export/linux/NovaSwift.x86_64" 2>&1 \
    | grep -E "ERROR|error" || true
  [ -f godot/export/linux/NovaSwift.x86_64 ] || { echo "error: Linux export failed (templates installed?)" >&2; exit 1; }
  chmod +x godot/export/linux/NovaSwift.x86_64
  echo "→ [3/3] assemble + verify (container)"
  run "$PREP && scripts/package-linux.sh --skip-build --skip-export"
else
  echo "→ [2-3/3] export + assemble in container"
  run "$PREP && scripts/package-linux.sh --skip-build"
fi
ls -lh godot/export/NovaSwift-linux-x86_64.tar.gz
echo "Next (release): scripts/release-sign.sh --version X.Y.Z --asset linux-x86_64=godot/export/NovaSwift-linux-x86_64.tar.gz [--asset windows-x86_64=...]   (docs/UPDATER.md)"
