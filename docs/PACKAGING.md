# Packaging the Godot frontend (Steam Deck first)

Milestone 6. Config lives in `godot/export_presets.cfg` (presets **Linux**,
**Windows**, **macOS**), `godot/NovaSwift.gdextension` (`[libraries]` +
`[dependencies]`), `scripts/package-linux.sh`, `packaging/linux/`, and the
`scripts/package-{macos,linux}.sh` (plus the older `package-linux-docker.sh`), `scripts/package-windows.ps1`.

## What is (never) in the package

- Included: the Godot project (`.pck`), `libNovaSwiftGodot.so`, `libSwiftGodot.so`,
  the Swift runtime libs, launcher, `.desktop`, icon.
- Excluded by `exclude_filter`: `tests/`, `bridge/` (Swift sources), `.build/`,
  `export/`, `bin/` (libs travel via the gdextension, not the .pck), `data/`, `*.md`.
- **No EV Nova data, ever** (BYO-data). The player imports it with the in-game Data Setup wizard, which
  copies it into the **managed data folder** (outside the install dir, so updates and re-installs never touch it):

  | Platform | Managed folder |
  |---|---|
  | Linux / Steam Deck | `$XDG_DATA_HOME/NovaSwift/data`, i.e. `~/.local/share/NovaSwift/data` |
  | Windows | `%APPDATA%\NovaSwift\data` |
  | macOS | `~/Library/Application Support/NovaSwift/data` |

  (`Prefs.managed_data_dir()`; `NOVA_DATA_IMPORT_DIR` overrides it for tests.) Plug-ins found alongside the game are kept in
  `<managed>/Nova Plug-ins/`. Search order at startup (`godot/Prefs.gd`): `$NOVA_DATA_DIR`, the folder saved by the wizard,
  `<project>/../data/base` (dev), the managed folder, `user://data`, `~/.local/share/NovaSwift/data`. With nothing found the
  app shows only the wizard. The updater never touches any of these (docs/UPDATER.md).

## Linux runtime strategy: dynamic Swift runtime, `$ORIGIN` rpath

`-static-stdlib` was rejected: the bridge is a dynamic library that links
SwiftGodot (also dynamic); each would embed its own Swift runtime, duplicating
type metadata/conformances across two `.so` files (crashes, failing `as?`).
Instead `build-gdextension.sh` links with `-rpath $ORIGIN` on Linux and
`package-linux.sh` walks `ldd` and copies every non-glibc dependency
(`libswiftCore.so`, `libFoundation*.so`, `libdispatch.so`, `lib_FoundationICU.so`,
...) next to the executable. glibc/libstdc++/libgcc are never bundled.

glibc floor: build on Ubuntu 22.04 (glibc 2.35) — the container script uses `swift:6.3-jammy`.
SteamOS 3 is glibc 2.38+. The script fails if the highest `GLIBC_x` symbol
needed exceeds 2.38.

## Building packages (local only)

Nothing here needs CI. `.github/workflows/godot-linux-windows.yml` still exists but is **not
used** (we do not push tags or dispatch it); treat it as a reference only.

Godot export templates (4.7.2, ~1.3 GB download, SHA-512 published in
`godot-builds/releases/4.7.2-stable/SHA512-SUMS.txt`) are installed selectively into
`~/Library/Application Support/Godot/export_templates/4.7.2.stable/`: `macos.zip`, `linux_release.x86_64`
(+ `.arm64`), `windows_release_x86_64(.console).exe`, `version.txt`, `icudt_godot.dat` (~360 MB).
`macos.zip` was replaced by an arm64-only thin copy (the preset is arm64 and Godot then looks for
`godot_macos_release.arm64`; `scripts/package-macos.sh` does this automatically if it sees the
universal one). Debug templates are not installed, so use `--export-release`.

Note: `godot/project.godot` sets `textures/vram_compression/import_etc2_astc=true`; Godot refuses an
arm64 macOS export without it.

### macOS (arm64) - built and verified

    scripts/package-macos.sh            # -> godot/export/macos/NovaSwift-macos-arm64.zip

Builds the release bridge, exports the macOS preset, `libNovaSwiftGodot.dylib` + `libSwiftGodot.dylib`
land in `Contents/Frameworks` (the bridge's `@loader_path` rpath finds its sibling), ad-hoc signs with
library validation disabled, then runs the exported binary headless and checks the log. Not notarised.

### Linux x86_64 / Steam Deck - built on a Linux machine

Linux packages are built on a Linux x86_64 computer (the maintainer's, for v0.7.0-beta.2), not on the Mac. Docker, Colima and Lima
are no longer used on the Mac. With the Swift 6.x toolchain, Godot 4.7.2 and its Linux export templates installed:

    scripts/package-linux.sh            # -> godot/export/NovaSwift-linux-x86_64.tar.gz

`package-linux.sh` does everything in one go: builds the bridge, bundles the Swift runtime libs, exports the Linux preset,
checks `ldd` resolution and the glibc <= 2.38 ceiling, and tars the result. It was used to produce the beta.2 Linux archive,
which has been run on Linux hardware and a Steam Deck.

`scripts/package-linux-docker.sh` still exists (it builds the bridge inside `swift:6.3-jammy`, `linux/amd64`, glibc 2.35, and
exports on the host). It was the earlier Mac route; it is not part of the current workflow, and on a Linux host with Docker or
podman it is only an option if you want the glibc 2.35 floor of that image.

### Windows x86_64 - built on a Windows PC

The Swift bridge cannot be cross-compiled from macOS. On a Windows 10/11 x64 machine install: the Swift
6.x Windows toolchain from swift.org (it installs Visual Studio Build Tools + the Windows SDK), Git, and
Godot 4.7.2 plus its export templates. Then, in a clone of this repo:

    powershell -ExecutionPolicy Bypass -File scripts\package-windows.ps1 -Godot C:\path\to\godot.exe

It builds `NovaSwiftGodot.dll`/`SwiftGodot.dll`, exports the Windows preset, copies the Swift runtime
DLLs beside the exe, smoke-tests headless and writes `godot\export\NovaSwift-windows-x86_64.zip`.
This is how the v0.7.0-beta.2 Windows archive was built; the script works and the result has been played on a real Windows PC. The
Windows `.exe` + `.pck` can be exported from the Mac (`godot --headless --path godot --export-release
Windows ...`), but Godot aborts at the end because the DLLs are absent, so the script re-exports on Windows.
Users also need the VC++ redistributable.

### Release signing / auto-update

Archive layouts match the updater: Linux `NovaSwift/` root with `NovaSwift.sh` (exec), `NovaSwift.x86_64`,
`NovaSwift.pck` plus libs; Windows zip is flat (`NovaSwift.exe`, `NovaSwift.pck`, DLLs). `godot/updater/*` is
exported in the `.pck`. After building, sign and publish the manifest with
`scripts/release-sign.sh --version X.Y.Z --asset linux-x86_64=godot/export/NovaSwift-linux-x86_64.tar.gz --asset windows-x86_64=godot/export/NovaSwift-windows-x86_64.zip`
(see [UPDATER.md](UPDATER.md)). macOS archives are built with `COPYFILE_DISABLE=1`, so no `._*` files.

## Steam Deck setup

1. Desktop Mode: extract `NovaSwift-linux-x86_64.tar.gz` somewhere writable,
   e.g. `~/Games/NovaSwift/`.
2. Launch it. With no data yet the game shows the **Data Setup** wizard (controller friendly: A open, B up,
   Y use this folder). Copy your EV Nova folder or the Windows `.zip` onto the Deck first (USB/SD card under
   `/run/media/...`, or download to `~/Downloads`), then pick it in the wizard's *Browse…*; it is copied to
   `~/.local/share/NovaSwift/data` for you.
3. Steam -> Games -> **Add a Non-Steam Game** -> Browse -> select
   `NovaSwift.sh` (or `NovaSwift.x86_64`). No `steam_appid.txt` and no Steam
   API are needed; it runs fine outside Steam too.
4. Controller: in the game's Controller settings choose the **Gamepad**
   template (Steam Input then presents a plain XInput pad, which is what the
   Godot frontend binds; rebind in Settings -> Controls). Avoid
   "Keyboard + Mouse" templates. The Deck's trackpads then act as extra
   buttons only if you map them; not required.
5. Display: the Deck screen is 1280x800 (16:10). The project is 1280x720 base
   with `expand` stretch, so the extra height is used rather than letterboxed.
   Run fullscreen (Settings -> Video) in Game Mode.
6. Optional: copy `novaswift.desktop` to `~/.local/share/applications/` (edit
   `Exec`/`Icon` to absolute paths) for a menu entry.

Saves/settings: `~/.local/share/godot/app_userdata/NOVA Swift (Godot)/`.

## Bundled movie decoder: mini ffmpeg (original movies)

The original's bar race clips (and plug-in movies) are QuickTime `.mov` (the race clips are MPEG-4
Part 2); Godot can only play Ogg Theora, so the game converts them on first use into `user://movies/`
(JPEG frame sequence + WAV; see `docs/GODOT_LAYER.md`, "Original movies"). The packages **bundle** a
tiny decode-only ffmpeg (~3.3–3.7 MB) beside the executable, so nothing has to be installed:

    scripts/build-mini-ffmpeg.sh [macos|linux|windows]   # -> godot/bin/ffmpeg/<platform>/ (git-ignored)

- Pinned FFmpeg 7.1.1 source (sha256-checked), `--disable-everything` plus only the mov/avi demuxers,
  legacy QuickTime video/audio decoders (mpeg4, cinepak, svq1/3, qtrle, rpza, smc, h264/hevc, IMA4,
  MACE, QDM2, PCM, MP3, AAC, ALAC…), scale/fps filters, and the mjpeg/pcm/image2/wav outputs. No
  Theora encoder, so `Movies.gd` always uses its frame-sequence path.
- LGPL-2.1 (no `--enable-gpl`, no external libs); shipped as a separate program with
  `FFMPEG-LICENSE.txt` naming the exact source.
- linux/windows are built in the `swift:6.3-jammy` amd64 container (glibc 2.35 floor, deps = libc/libm;
  Windows via mingw-w64, deps = system DLLs only). macOS builds natively. ~7 min each under Rosetta.
- Every packaging script builds it if missing, bundles it, and fails if it can't (no silent
  movie-less package): `package-macos.sh`, `package-linux.sh` / `package-linux-docker.sh`, and
  `package-windows.ps1`, which runs the cross-build through **Docker Desktop** (Linux containers) the
  first time. No Docker on that PC: copy `godot/bin/ffmpeg/windows/` from a machine that built it.
  Each package also checks that the bundled binary actually runs.
- `.gitattributes` pins `*.sh` to LF so a Windows clone can still run the scripts in the container.
- Lookup order in `Movies.gd`: beside the executable → `res://bin/ffmpeg/<platform>/` (editor runs) →
  `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`. With none found, movies are skipped
  exactly as with the original's "QuickTime Movies" preference off.

## Status / caveats

- v0.7.0-beta.2 (2026-10-14) ships all three: macOS arm64 (built and ad-hoc signed locally), Linux x86_64 (built with
  `scripts/package-linux.sh` on a Linux machine) and Windows x86_64 (built with `scripts/package-windows.ps1` on a Windows PC).
  Each has been played on real hardware (Mac, Windows PC, Linux, Steam Deck). The release also carries a signed `update.json` + `.sig`.
- There is no GitHub CI for packaging; the workflow is manual-only and is not used.
- macOS preset: arm64 only, ad-hoc signed with library validation disabled; not notarised.
- Windows: users need the VC++ redistributable.
- The Steam Deck build has been played on a Deck; the `.desktop` file and the Steam shortcut route are not separately documented as tested.
