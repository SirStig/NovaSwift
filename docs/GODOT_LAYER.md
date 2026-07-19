# Godot Layer — Linux / Windows support

Status: **In progress (started 2026-07-19)** — foundation + runnable vertical
slice landed on branch `claude/godot-layer-linux-windows`.

> The authoritative platform decision for Apple targets is
> [ARCHITECTURE.md](ARCHITECTURE.md) (native Swift + SpriteKit). This document
> is the *complementary* decision for **desktop Linux and Windows**, which
> SpriteKit cannot reach. It does not replace the Apple frontend; it adds a
> second, cross-platform frontend on top of the same Swift core.

## The problem

NOVA Swift is split into two halves:

| Half | Platforms | Status |
|---|---|---|
| **Core** — `NovaSwiftKit`, `NovaSwiftEngine`, `NovaSwiftStory`, `NovaSwiftNet` | portable Swift | builds on any Swift toolchain |
| **Frontend** — `app/NovaSwift/` (SwiftUI + SpriteKit) | Apple only | macOS / iPadOS / iOS |

The simulation, data layer, and story runtime are plain Swift with almost no
Apple-framework coupling (an audit found exactly **one** unconditional
`import CoreGraphics`, in `ColorModels.swift`, needing only `CGPoint` — now
guarded). The Apple-only part is the *frontend*: SwiftUI for UI and SpriteKit
for rendering. Those two frameworks are what pin the game to Apple hardware.

To reach **Linux and Windows** we need a cross-platform host for windowing,
rendering, input, and audio — the exact job SpriteKit does today on Apple.

## Decision: Godot 4 host + SwiftGodot GDExtension bridge

We add a **second frontend** built on **Godot 4** and bridge it to the existing
Swift engine with a **[SwiftGodot](https://github.com/migueldeicaza/SwiftGodot)
GDExtension**. The simulation stays in Swift; Godot owns the screen.

```
┌──────────────────────────────────────────────────────────────┐
│  godot/  — Godot 4 project (GDScript + scenes)                │
│    Windowing · rendering · input · audio · UI                │
│    Linux · Windows · macOS  (one project, all three)         │
├──────────────────────────────────────────────────────────────┤
│  NovaSwift.gdextension  → loads the native bridge library    │
├──────────────────────────────────────────────────────────────┤
│  godot/bridge/  (own SPM package, builds a .so/.dll/.dylib)  │
│    SwiftGodot bridge: `NovaWorld` node + value marshalling.  │
│    Exposes the engine to GDScript as @Callable methods.      │
├───────────────────────────────┬──────────────────────────────┤
│  NovaSwiftEngine (Swift)      │  NovaSwiftKit (Swift)        │
│    the same simulation the    │    the same data layer the   │
│    Apple app runs             │    Apple app runs            │
└───────────────────────────────┴──────────────────────────────┘
```

### Why this over the alternatives

| Option | Verdict |
|---|---|
| **SwiftGodot GDExtension** (chosen) | ✅ Reuses the entire ~76-file Swift core unchanged. Godot handles Linux/Windows/macOS windowing, rendering, input, audio, and UI for free. One binary per platform + one shared Godot project. Swift ↔ Godot is a maintained, macro-driven binding. |
| **C-ABI core + full GDScript reimplementation** | ❌ Thinner bridge, but the whole UI/render layer is rewritten in GDScript and every engine value crosses a hand-rolled C boundary. More new code, more drift from the Swift source of truth. |
| **Full GDScript/Godot rewrite** | ❌ Discards the Swift engine that already reproduces EV Nova faithfully. Two engines to keep in sync forever. Non-starter. |

### Why Godot (not SDL/raylib/a custom loop)

Godot gives us a scene graph, a UI toolkit (`Control` nodes), input mapping,
audio, a text renderer, and export templates for all three desktop OSes in one
package — most of what `app/NovaSwift/` gets from SwiftUI+SpriteKit, but
cross-platform. A raw SDL loop would mean rebuilding all of that by hand.

## What "the bridge" is

`godot/bridge/` is its **own** Swift package (it depends on the root NovaSwift
package by path, so the Apple app's `swift build`/`swift test` never see
SwiftGodot). It compiles to a **dynamic library** (`.so` on Linux, `.dll` on
Windows, `.dylib` on macOS) that Godot loads through
`godot/NovaSwift.gdextension`. It depends on `NovaSwiftEngine` (which pulls in
`NovaSwiftKit`) and exposes one Godot-visible class:

### `NovaWorld` (extends `Node2D`)

A thin, allocation-light wrapper around the engine's `World`. GDScript calls it
every frame. Its surface (see `godot/bridge/Sources/NovaSwiftGodot/NovaWorld.swift`):

- **World setup**
  - `make_demo_world()` — builds a bare physics `World` with a synthetic player
    ship and a few drifting NPCs. **Runs with no EV Nova data**, so the slice is
    playable out of the box and the bridge is provable end-to-end.
  - `load_game(base_dir) -> bool` — discovers + merges the player's own EV Nova
    data via `GameLibrary` (BYO-data, same as the Apple app).
  - `make_world(system_id) -> bool` — after `load_game`, populates a real system
    through `GameSession.makeWorld` (NPCs from the `düde`/`flët` spawn table).
- **Input** — `set_intent(turn_left, turn_right, thrust, reverse, afterburner,
  fire_primary, fire_secondary)` maps a frame of Godot input onto the engine's
  `ControlIntent`.
- **Tick** — `step(dt)` advances the simulation exactly as the Apple app and the
  headless `novaswift-extract ai` harness do.
- **Readback** (for rendering, packed to avoid per-entity Variant churn)
  - `player_position() -> Vector2`, `player_angle() -> float`,
    `player_velocity() -> Vector2`, `player_shield_fraction() -> float`,
    `player_armor_fraction() -> float`, `player_is_alive() -> bool`
  - `ship_count() -> int` and `ship_transforms() -> PackedFloat32Array`
    (`[x, y, angle, kind]` per live ship, player first) so GDScript can draw all
    ships from one array.
  - `drain_events() -> PackedStringArray` — one string per `WorldEvent` this
    step (weaponFired, shipDestroyed, …) for sound/FX hooks.

The bridge is **stateless glue**: no game logic lives here. Anything the bridge
does that isn't marshalling is a bug — new behavior belongs in the engine, where
the Apple app gets it too.

## Vertical slice (what runs today)

`godot/` is a minimal but real Godot project:

- `Main.tscn` / `Main.gd` — instantiates a `NovaWorld`, calls `make_demo_world()`,
  reads keyboard input each frame into `set_intent`, calls `step(delta)`, and
  draws a parallax starfield plus every ship from `ship_transforms()`.
- Arrow keys / WASD fly the ship with the engine's real Newtonian momentum — you
  swing the nose and keep drifting, exactly like the Apple build, because it *is*
  the same `World.step`.

This proves the full loop — **Godot input → Swift `ControlIntent` → `World.step`
→ Swift readback → Godot rendering** — works on Linux and Windows. It is not the
finished game; it is the foundation the real UI is built on next.

## Cross-platform status of the core

An audit of `NovaSwiftKit` + `NovaSwiftEngine` (the two libraries the bridge
needs) found the core almost entirely portable:

- ✅ `NovaSwiftEngine` — no Apple-framework imports at all. Pure Swift +
  Foundation + Dispatch (all available on Linux/Windows).
- ✅ `NovaSwiftKit/SpriteSheet+Image.swift` — already `#if
  canImport(CoreGraphics)`-guarded; the CGImage helpers simply compile out
  off-Apple (Godot decodes sprites its own way).
- ✅ `NovaSwiftKit/ColorModels.swift` — **fixed here**: was an unconditional
  `import CoreGraphics` for `CGPoint`; now imports Foundation (which provides
  `CGPoint` on Linux/Windows) with CoreGraphics guarded.

CI (below) is the mechanism that finds anything the audit missed: the first full
Linux/Windows compile of the core may surface further platform edges (a
`Data(contentsOf:)` mode, a threading primitive) to guard. Those fixes belong in
the core with `#if` guards so the Apple build is untouched.

## Build & CI

- `scripts/build-gdextension.sh` — builds the `NovaSwiftGodot` dynamic library
  for the host platform and copies it into `godot/bin/`.
- `.github/workflows/godot-linux-windows.yml` — compiles the core + bridge on
  Linux and Windows using the official Swift toolchain, so regressions in
  cross-platform compilation are caught on every push.

Godot **export templates** turn `godot/` + the platform library into shippable
`.x86_64` (Linux) and `.exe` (Windows) builds; wiring the export presets into CD
is a follow-up once the frontend is fleshed out.

## Milestones

1. **Foundation + slice** (this change) — bridge target, `NovaWorld`, demo world,
   flyable slice, build script, CI. ✅
2. **Real data path** — sprite upload from `NovaSwiftKit` decode into Godot
   textures; render real ships/planets from the player's data via `make_world`.
3. **HUD & flight** — radar, status bar, target lock, weapons firing/FX, sound
   from `drain_events`.
4. **Screens** — galaxy map, landing, spaceport (trade/outfit/shipyard), pilot
   save/load — GDScript `Control` UI over the same engine/story calls the Apple
   app makes.
5. **Story runtime** — bring `NovaSwiftStory` across for missions/crons/NCB.
6. **Packaging** — Godot export presets + CD for Linux/Windows artifacts.

## Non-goals

- Not replacing the Apple frontend. `app/NovaSwift/` stays the shipping build for
  macOS/iPadOS/iOS; this is a parallel desktop frontend.
- Not forking the engine. The Swift core is the single source of truth; the Godot
  layer only renders and drives it.
- Still BYO-data. The Godot build reads the player's own EV Nova data exactly
  like every other NOVA Swift build; no game content is bundled.
