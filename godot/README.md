# NOVA Swift — Godot desktop frontend (Linux / Windows / macOS)

This directory is the cross-platform desktop frontend for NOVA Swift. It hosts
the game in **Godot 4** and drives the existing Swift engine through a
**SwiftGodot GDExtension**. It's the path to Linux and Windows, which the Apple
SwiftUI/SpriteKit app (`app/NovaSwift/`) can't reach.

Full design: [`../docs/GODOT_LAYER.md`](../docs/GODOT_LAYER.md).

## Layout

```
godot/
  project.godot          Godot 4 project
  NovaSwift.gdextension  loads the native bridge library per platform
  Main.tscn / Main.gd    the flight frontend (ships, shots, beams, rocks, HUD)
  icon.svg               app icon
  bin/                   built bridge libraries land here (git-ignored)
  bridge/                the Swift ↔ Godot bridge (its own SPM package)
    Package.swift
    Sources/NovaSwiftGodot/
      NovaSwiftGodot.swift   GDExtension entry point
      NovaWorld.swift        Godot node wrapping the engine's World
```

## Build & run

Requires a [Swift toolchain](https://swift.org/download/) (6.3) and
[Godot 4.6+](https://godotengine.org/download) — developed against 4.7. The
floor tracks the Godot release SwiftGodot's pinned revision binds to; see the
version matrix in [`../docs/GODOT_LAYER.md`](../docs/GODOT_LAYER.md).

```bash
# 1 · build the native bridge into godot/bin/
scripts/build-gdextension.sh          # from the repo root (debug; add 'release' for release)

# 2 · open this folder in Godot 4.2+ and press Play (F5),
#     or run headless-less from the CLI:
godot --path godot
```

### Two modes (chosen automatically)

- **Real data** — point it at your own EV Nova data and it renders **actual hull
  and planet sprites** in a real system:
  ```bash
  NOVA_DATA_DIR=/path/to/your/EVNova/data godot --path godot
  ```
  If `NOVA_DATA_DIR` is unset it also checks the repo's git-ignored `data/base/`.
- **Demo** — with no data found, it builds a **data-free demo world** (a ship you
  fly plus a ring of drifting hulls, drawn as primitives). Always runs.

Controls: **arrows / WASD** fly (you swing the nose and keep drifting — that's
the engine's real physics), **Shift** afterburner, **Space** fire primary,
**Ctrl** fire secondary, **Tab** target nearest hostile, **Backspace** clear
target, **Q**/**E** cycle secondary weapon, **L** land / launch. Docked:
**up**/**down** pick a commodity row, **B** buy a ton, **S** sell a ton.

## What this proves

The slice exercises the whole loop on Linux/Windows/macOS:

```
Godot input → Swift ControlIntent → World.step → Swift readback → Godot render
```

`World.step` here is the *same* simulation the Apple app runs. From this
foundation the real frontend (sprites from the player's data, HUD, galaxy map,
spaceport, story) is built up in GDScript over the same engine calls — see the
milestones in [`../docs/GODOT_LAYER.md`](../docs/GODOT_LAYER.md).

## Note on the current status

Confirmed on-toolchain 2026-07-18: the bridge builds clean with
`scripts/build-gdextension.sh` (Swift 6.3) and a headless `godot --path godot`
run loads real EV Nova data, builds a system, and steps the simulation with no
errors, on macOS. Linux/Windows are not yet verified locally — CI
(`.github/workflows/godot-linux-windows.yml`) tracks the core's Linux/Windows
compilation and the bridge build there.

Until recently that CI could never have gone green: `NovaSwiftKit`'s decoded-
sprite cache used LZFSE through `NSData.compressed(using:)`, an Apple-only
Foundation facility, so every Linux and Windows job died before the bridge was
even reached. That's fixed (`Sources/NovaSwiftKit/SpriteDiskCache.swift` now
tags each record with its codec and stores raw off Apple) and the workflow is
back on push/PR. The first green Linux run is what will actually confirm the
core compiles off Apple end to end — the LZFSE failure masked everything
downstream of it, so more platform edges may surface behind it.
