#!/usr/bin/env bash
# Build thin Godot 4.7.2 *release export templates* with unused engine modules
# disabled. NovaSwift's Godot frontend is 2D + GL Compatibility only; the stock
# template still ships 3D/Jolt/XR/etc. and is ~70–100 MB of the package.
#
# Output (git-ignored):
#   godot/export_templates/linux_release.x86_64
#   godot/export_templates/windows_release_x86_64.exe
#   godot/export_templates/macos_template.app  (then zip as needed)
#
# package-linux.sh / package-windows.ps1 / package-macos.sh pick these up when
# present; otherwise they keep using the official templates. Layout and updater
# contract stay identical — only the host binary gets smaller.
#
#   scripts/build-godot-template.sh [linux|windows|macos|all]
#
# Needs: git, python3, scons, a C++ toolchain matching the target. First run
# clones Godot 4.7.2-stable into .godot-src/ (git-ignored, ~1 GB).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${GODOT_TEMPLATE_VERSION:-4.7.2-stable}"
SRC="${GODOT_SRC:-$PWD/.godot-src}"
OUT="$PWD/godot/export_templates"
TARGET="${1:-all}"

# Modules NovaSwift does not use. Keep 2D, text servers, GL Compatibility,
# navigation-lite pieces Godot may still reference, and regular expression /
# JSON / etc. that GDScript needs. When unsure, leave a module ON.
DISABLE_MODULES=(
  module_csg_enabled=no
  module_gridmap_enabled=no
  module_gltf_enabled=no
  module_lightmapper_rd_enabled=no
  module_raycast_enabled=no
  module_webrtc_enabled=no
  module_websocket_enabled=no
  module_multiplayer_enabled=no
  module_openxr_enabled=no
  module_camera_enabled=no
  module_mobile_vr_enabled=no
  module_xr_enabled=no
  module_godot_physics_3d_enabled=no
  module_jolt_physics_enabled=no
  module_basis_universal_enabled=no
  module_bcd_enabled=no
  module_cvtt_enabled=no
  module_tga_enabled=no
  module_ktx_enabled=no
  module_vhacd_enabled=no
  module_fbx_enabled=no
  module_obj_enabled=no
)

common_scons=(
  production=yes
  optimize=size
  debug_symbols=no
  tests=no
  "${DISABLE_MODULES[@]}"
)

need_scons() {
  command -v scons >/dev/null || { echo "error: scons is required to build Godot templates" >&2; exit 1; }
}

ensure_src() {
  if [ ! -d "$SRC/.git" ]; then
    echo "→ cloning Godot $VERSION into $SRC"
    git clone --depth 1 --branch "$VERSION" https://github.com/godotengine/godot.git "$SRC"
  else
    echo "→ using existing Godot sources in $SRC"
    git -C "$SRC" fetch --depth 1 origin "refs/tags/$VERSION:refs/tags/$VERSION" 2>/dev/null || true
    git -C "$SRC" checkout -f "$VERSION"
  fi
}

build_linux() {
  need_scons; ensure_src
  mkdir -p "$OUT"
  echo "→ building linux x86_64 release template (optimize=size, modules trimmed)"
  ( cd "$SRC" && scons -j"$(nproc)" platform=linuxbsd target=template_release arch=x86_64 "${common_scons[@]}" )
  BIN="$(find "$SRC/bin" -maxdepth 1 -type f -name 'godot.linuxbsd.template_release.x86_64*' | head -1)"
  [ -n "$BIN" ] || { echo "error: linux template binary not found in $SRC/bin" >&2; exit 1; }
  strip --strip-unneeded "$BIN" 2>/dev/null || true
  cp -f "$BIN" "$OUT/linux_release.x86_64"
  chmod +x "$OUT/linux_release.x86_64"
  echo "✓ $OUT/linux_release.x86_64 ($(du -h "$OUT/linux_release.x86_64" | cut -f1))"
}

build_windows() {
  need_scons; ensure_src
  mkdir -p "$OUT"
  echo "→ building windows x86_64 release template"
  ( cd "$SRC" && scons -j"$(nproc)" platform=windows target=template_release arch=x86_64 "${common_scons[@]}" )
  BIN="$(find "$SRC/bin" -maxdepth 1 -type f -name 'godot.windows.template_release.x86_64*' | head -1)"
  [ -n "$BIN" ] || { echo "error: windows template binary not found in $SRC/bin" >&2; exit 1; }
  cp -f "$BIN" "$OUT/windows_release_x86_64.exe"
  echo "✓ $OUT/windows_release_x86_64.exe ($(du -h "$OUT/windows_release_x86_64.exe" | cut -f1))"
}

build_macos() {
  need_scons; ensure_src
  mkdir -p "$OUT"
  echo "→ building macOS arm64 release template"
  ( cd "$SRC" && scons -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" platform=macos target=template_release arch=arm64 "${common_scons[@]}" )
  BIN="$(find "$SRC/bin" -maxdepth 1 -type f -name 'godot.macos.template_release*' | head -1)"
  [ -n "$BIN" ] || { echo "error: macOS template binary not found in $SRC/bin" >&2; exit 1; }
  # Godot expects an .app-shaped template for macOS exports; wrap the binary.
  APP="$OUT/macos_template.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  cp -f "$BIN" "$APP/Contents/MacOS/godot_macos_release.arm64"
  chmod +x "$APP/Contents/MacOS/godot_macos_release.arm64"
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>godot_macos_release.arm64</string>
  <key>CFBundleIdentifier</key><string>com.novaswift.godot-template</string>
  <key>CFBundleName</key><string>Godot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  echo "✓ $APP"
}

case "$TARGET" in
  linux) build_linux ;;
  windows) build_windows ;;
  macos) build_macos ;;
  all)
    build_linux
    # windows/macos builds need their host toolchains; skip quietly when absent.
    if command -v x86_64-w64-mingw32-g++ >/dev/null 2>&1 || [ "$(uname -s)" = "Windows_NT" ]; then
      build_windows || echo "warn: windows template build failed (continuing)"
    else
      echo "skip windows template (no mingw / Windows host)"
    fi
    if [ "$(uname -s)" = "Darwin" ]; then
      build_macos || echo "warn: macOS template build failed (continuing)"
    else
      echo "skip macOS template (not on Darwin)"
    fi
    ;;
  *) echo "usage: $0 [linux|windows|macos|all]" >&2; exit 2 ;;
esac

echo "Done. Packaging scripts use these automatically when the files exist."
echo "Stock official templates remain the fallback (no extra download for players)."
