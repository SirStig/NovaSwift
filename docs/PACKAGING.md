# Packaging the Godot frontend (Steam Deck first)

Milestone 6. Config lives in `godot/export_presets.cfg` (presets **Linux**,
**Windows**, **macOS**), `godot/NovaSwift.gdextension` (`[libraries]` +
`[dependencies]`), `scripts/package-linux.sh`, `packaging/linux/`, and the
`package-*` jobs in `.github/workflows/godot-linux-windows.yml`.

## What is (never) in the package

- Included: the Godot project (`.pck`), `libNovaSwiftGodot.so`, `libSwiftGodot.so`,
  the Swift runtime libs, launcher, `.desktop`, icon.
- Excluded by `exclude_filter`: `tests/`, `bridge/` (Swift sources), `.build/`,
  `export/`, `bin/` (libs travel via the gdextension, not the .pck), `data/`, `*.md`.
- **No EV Nova data, ever** (BYO-data). The game finds it at runtime — search
  order in `godot/Prefs.gd`: `$NOVA_DATA_DIR`, the folder saved from the in-game
  "Game Data" screen, `<project>/../data/base`, `user://data`,
  `~/.local/share/NovaSwift/data`.

## Linux runtime strategy: dynamic Swift runtime, `$ORIGIN` rpath

`-static-stdlib` was rejected: the bridge is a dynamic library that links
SwiftGodot (also dynamic); each would embed its own Swift runtime, duplicating
type metadata/conformances across two `.so` files (crashes, failing `as?`).
Instead `build-gdextension.sh` links with `-rpath $ORIGIN` on Linux and
`package-linux.sh` walks `ldd` and copies every non-glibc dependency
(`libswiftCore.so`, `libFoundation*.so`, `libdispatch.so`, `lib_FoundationICU.so`,
...) next to the executable. glibc/libstdc++/libgcc are never bundled.

glibc floor: build on Ubuntu 22.04 (glibc 2.35) — CI uses `swift:6.3-jammy`.
SteamOS 3 is glibc 2.38+. The script fails if the highest `GLIBC_x` symbol
needed exceeds 2.38.

## Building a Linux package

CI: push a `v*` tag, or Actions -> "Godot layer" -> Run workflow (package = on).
Artifacts: `NovaSwift-linux-x86_64` (tar.gz), `NovaSwift-windows-x86_64` (zip,
best effort). On a tag they are attached to a draft GitHub release.

Locally on Linux (needs Swift 6.3, Godot 4.7.2 and its export templates in
`~/.local/share/godot/export_templates/4.7.2.stable/`):

    scripts/package-linux.sh            # -> godot/export/NovaSwift-linux-x86_64.tar.gz

Export templates are a ~1.3 GB download (`Godot_v4.7.2-stable_export_templates.tpz`);
CI unpacks only the Linux/Windows templates. The Godot version is pinned in the
workflow `env` (`GODOT_VERSION`); project floor is 4.6, we ship 4.7.x.

## Steam Deck setup

1. Desktop Mode: extract `NovaSwift-linux-x86_64.tar.gz` somewhere writable,
   e.g. `~/Games/NovaSwift/`.
2. Put your own EV Nova data (the `Nova Files` / `Nova Plug-ins` folders, or
   whatever the game's "Game Data" screen accepts) in
   `~/.local/share/NovaSwift/data` — or pick the folder from the in-game picker.
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

## Optional runtime dependency: ffmpeg (original movies)

The original's bar race clips (and plug-in movies) are QuickTime `.mov`; Godot can only play Ogg
Theora, so the game converts them on first use with `ffmpeg` into `user://movies/` (see
`docs/GODOT_LAYER.md`, "Original movies"). ffmpeg is **not bundled** and **not required**: without it
the movies are skipped, as with the original's "QuickTime Movies" preference off, and everything else
(including race betting's result) works. Install it to get the clips:

- Linux / Steam Deck: `sudo pacman -S ffmpeg` (SteamOS: unlock the read-only rootfs first with
  `sudo steamos-readonly disable`, and note SteamOS updates may remove it), or a static build placed on
  `PATH` (e.g. `~/.local/bin/ffmpeg`; the game also checks `/usr/local/bin` and `/usr/bin`).
- Windows: put `ffmpeg.exe` on `PATH`. macOS: `brew install ffmpeg` (found in `/opt/homebrew/bin`).
- If the ffmpeg lacks the `libtheora` encoder the game falls back to a JPEG frame sequence cache, so
  any ffmpeg works.

## Status / caveats

- Verified locally (macOS): export_presets.cfg parses and Godot 4.7.2 reaches the
  template check. Everything else (Linux bridge build, runtime bundling, export,
  smoke test) has **not been run**; verify it locally on Linux before relying on it.
  The CI workflow exists but is not used to verify builds.
- macOS preset: arm64 only, ad-hoc signed with library validation disabled; the
  bridge dylib must be arm64. Not notarised.
- Windows: Swift runtime DLLs copied from the toolchain; users need the VC++
  redistributable. Unproven toolchain, hence continue-on-error.
- The `.desktop` and Steam shortcut are not tested on a Deck.
