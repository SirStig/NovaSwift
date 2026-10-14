#!/usr/bin/env bash
# Build the tiny, decode-only ffmpeg the Godot frontend bundles to play the original's
# QuickTime movies (Race 1-4.mov = MPEG-4 Part 2 in .mov) and plug-in movies / ".mov" music.
#
#   scripts/build-mini-ffmpeg.sh [macos|linux|windows]     (default: the host platform)
#
# Output: godot/bin/ffmpeg/<platform>/ffmpeg[.exe] + LICENSE.txt  (git-ignored; godot/bin/*
# is excluded from every export preset, the packaging scripts copy it beside the executable).
#
# Everything is disabled except what godot/Movies.gd's "frames" path needs:
#   mov demuxer -> legacy QuickTime / MPEG video + audio decoders -> fps/scale ->
#   mjpeg -> image2 (JPEG frame sequence)   and   pcm_s16le -> wav (audio track).
# No Theora encoder: Movies.gd falls back to the frame cache automatically.
#
# LGPL-2.1 build (no --enable-gpl / --enable-nonfree, no external libs). It ships as a
# separate executable, never linked into the game; LICENSE.txt names the exact source.
#
# linux / windows build inside a linux/amd64 container (same runtime as
# package-linux-docker.sh): linux on glibc 2.35 (Steam Deck floor), windows via mingw-w64.
set -euo pipefail
cd "$(dirname "$0")/.."

FF_VER="7.1.1"
FF_SHA256="733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1"
FF_URL="https://ffmpeg.org/releases/ffmpeg-$FF_VER.tar.xz"

host_plat() {
  case "$(uname -s)" in Darwin) echo macos ;; Linux) echo linux ;; *) echo windows ;; esac
}
PLAT="${1:-$(host_plat)}"
case "$PLAT" in macos|linux|windows) ;; *) echo "usage: $0 [macos|linux|windows]" >&2; exit 2 ;; esac

OUT="godot/bin/ffmpeg/$PLAT"
WORK=".ffmpeg-build"          # git-ignored source + object cache
mkdir -p "$WORK" "$OUT"

# --- linux / windows from a non-Linux host: re-run this script in a container ------
if [ "$PLAT" != "macos" ] && [ "$(uname -s)" != "Linux" ]; then
  RT=""
  for c in docker podman; do
    if command -v "$c" >/dev/null 2>&1 && "$c" info >/dev/null 2>&1; then RT="$c"; break; fi
  done
  [ -n "$RT" ] || { echo "error: $PLAT needs docker/podman (see scripts/package-linux-docker.sh)" >&2; exit 1; }
  exec "$RT" run --rm --platform linux/amd64 -v "$PWD":/work -w /work "${SWIFT_IMAGE:-swift:6.3-jammy}" \
    bash -lc "scripts/build-mini-ffmpeg.sh $PLAT"
fi

# --- source ----------------------------------------------------------------------
TARBALL="$WORK/ffmpeg-$FF_VER.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "→ downloading $FF_URL"
  curl -fL --retry 3 -o "$TARBALL.part" "$FF_URL"
  mv "$TARBALL.part" "$TARBALL"
fi
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
got="$(sha "$TARBALL")"
[ "$got" = "$FF_SHA256" ] || { echo "error: $TARBALL sha256 $got != $FF_SHA256" >&2; exit 1; }

SRC="$WORK/src-$PLAT"
rm -rf "$SRC"; mkdir -p "$SRC"
tar -xJf "$TARBALL" -C "$SRC" --strip-components=1

# --- configure ---------------------------------------------------------------------
# Video: every codec a classic-Mac / early-2000s QuickTime file realistically carries, plus
# H.264/HEVC for modern plug-in movies (7.1.1 h264 also needs hevc to link: h2645_sei.o).
DECODERS="mpeg4,h263,h264,hevc,mpeg1video,mpeg2video,mjpeg,cinepak,svq1,svq3,qtrle,rpza,smc,rawvideo,png,gif,msrle,msvideo1,indeo3"
# Audio: QuickTime IMA4 / MACE / QDesign / PCM variants, MP3, AAC, ALAC.
DECODERS="$DECODERS,adpcm_ima_qt,adpcm_ima_wav,adpcm_ms,mace3,mace6,qdm2,qdmc,mp1,mp2,mp3,aac,alac,pcm_s8,pcm_u8,pcm_s16be,pcm_s16le,pcm_s24be,pcm_s24le,pcm_s32be,pcm_f32be,pcm_alaw,pcm_mulaw"

ARGS=(
  --disable-everything --disable-autodetect --disable-network --disable-doc
  --disable-ffplay --disable-ffprobe --disable-avdevice --disable-postproc
  --disable-debug --enable-small --enable-static --disable-shared
  --enable-ffmpeg --enable-avcodec --enable-avformat --enable-avfilter --enable-swscale --enable-swresample
  --enable-protocol=file,pipe
  --enable-demuxer=mov,avi,mp3,wav,aiff
  --enable-parser=mpeg4video,h264,mpegaudio,aac,mjpeg,png
  --enable-bsf=null
  --enable-decoder="$DECODERS"
  --enable-encoder=mjpeg,pcm_s16le
  --enable-muxer=image2,wav,null
  --enable-filter=scale,fps,format,null,anull,aresample,aformat,copy,acopy,setsar
  --disable-x86asm
)
case "$PLAT" in
  macos)
    ARGS+=(--extra-cflags=-mmacosx-version-min=12.0 --extra-ldflags=-mmacosx-version-min=12.0) ;;
  linux)
    ARGS+=(--cc=clang --extra-ldflags=-static-libgcc) ;;   # the swift image ships clang, not gcc
  windows)
    if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
      apt-get update -qq && apt-get install -y -qq mingw-w64 make xz-utils >/dev/null
    fi
    ARGS+=(--target-os=mingw32 --arch=x86_64 --cross-prefix=x86_64-w64-mingw32- --enable-cross-compile --host-cc=clang
           --extra-ldflags=-static) ;;
esac
if [ "$PLAT" = "linux" ] && ! command -v make >/dev/null; then
  apt-get update -qq && apt-get install -y -qq make xz-utils >/dev/null
fi

echo "→ configuring ffmpeg $FF_VER for $PLAT"
( cd "$SRC" && ./configure "${ARGS[@]}" >../configure-$PLAT.log 2>&1 ) \
  || { echo "error: configure failed (see $WORK/configure-$PLAT.log)" >&2; tail -20 "$WORK/configure-$PLAT.log" >&2; exit 1; }

EXE="ffmpeg"; [ "$PLAT" = "windows" ] && EXE="ffmpeg.exe"   # also the make target name
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
echo "→ building (-j$JOBS)"
make -C "$SRC" -j"$JOBS" "$EXE" >"$WORK/make-$PLAT.log" 2>&1 \
  || { echo "error: build failed (see $WORK/make-$PLAT.log)" >&2; tail -30 "$WORK/make-$PLAT.log" >&2; exit 1; }

rm -f "$OUT/ffmpeg" "$OUT/ffmpeg.exe"
cp "$SRC/$EXE" "$OUT/$EXE"
case "$PLAT" in
  macos)   strip -x "$OUT/$EXE"; codesign --force --sign - "$OUT/$EXE" ;;
  linux)   strip "$OUT/$EXE" ;;
  windows) x86_64-w64-mingw32-strip "$OUT/$EXE" ;;
esac

cat > "$OUT/LICENSE.txt" <<TXT
This folder's $EXE is FFmpeg $FF_VER (https://ffmpeg.org), licensed under the
GNU Lesser General Public License v2.1 or later. It is an unmodified, decode-only
build, run by NOVA Swift as a separate program to convert QuickTime movies.

Source: $FF_URL  (sha256 $FF_SHA256)
Build script (exact configure flags): scripts/build-mini-ffmpeg.sh in the NOVA Swift
source repository. LGPL text: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html
TXT

echo "✓ $OUT/$EXE ($(du -h "$OUT/$EXE" | cut -f1))"
