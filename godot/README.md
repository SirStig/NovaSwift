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
  Main.tscn / Main.gd    the vertical slice (flyable ship + starfield)
  icon.svg               app icon
  bin/                   built bridge libraries land here (git-ignored)
  bridge/                the Swift ↔ Godot bridge (its own SPM package)
    Package.swift
    Sources/NovaSwiftGodot/
      NovaSwiftGodot.swift   GDExtension entry point
      NovaWorld.swift        Godot node wrapping the engine's World
```

## Build & run

Requires a [Swift toolchain](https://swift.org/download/) and
[Godot 4.2+](https://godotengine.org/download).

```bash
# 1 · build the native bridge into godot/bin/
scripts/build-gdextension.sh          # from the repo root (debug; add 'release' for release)

# 2 · open this folder in Godot 4.2+ and press Play (F5),
#     or run headless-less from the CLI:
godot --path godot
```

The slice builds a **data-free demo world** — a ship you fly with real Newtonian
momentum plus a ring of drifting hulls — so it runs with no EV Nova data.

Controls: **arrows / WASD** fly (you swing the nose and keep drifting — that's
the engine's real physics), **Shift** afterburner, **Space** fire primary.

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

The Swift core was audited as cross-platform-clean and the bridge is written
against the engine's real API, but it has **not yet been compiled on a Swift
toolchain** (the authoring environment had none). Expect to shake out a few
SwiftGodot/toolchain details on first build; CI
(`.github/workflows/godot-linux-windows.yml`) tracks the core's Linux/Windows
compilation and the bridge build.
