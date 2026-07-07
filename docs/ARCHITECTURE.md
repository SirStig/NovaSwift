# Architecture & Engine Decision

Status: **Decided (2026-07-07)** — revisit only if a milestone invalidates it.

## Target

Native **iOS / iPadOS / macOS** app that runs EV Nova + arbitrary plug-ins and
total conversions. Touch-first on iPhone/iPad; keyboard + mouse + game
controller on macOS.

## Decision: native Swift + Metal (via SpriteKit), BYO-data

We build a clean native Apple codebase rather than forking the existing C++
engine.

### Options considered

| Option | Verdict |
|---|---|
| **Fork Kestrel** (C++20, MIT, has a Metal renderer) | ❌ macOS-desktop only, **no iOS target, no touch/UIKit host, no mobile lifecycle**, and dormant since Oct 2023. Reviving dormant C++20 *and* writing the entire iOS host layer is more work than a native codebase — and Lua-content-driven, so not data-compatible with Nova plug-ins without KDL retooling. |
| **NovaJS in WKWebView** (TS, MIT) | ❌ Fastest "it runs," but WebGL-in-WKWebView perf/input/audio penalties on iOS, App-Store scrutiny of web-wrapper games, drags in a Bazel/TS + multiplayer-server stack. Great as a *reference*, not the shipping engine. |
| **Native Swift + Metal (SpriteKit)** | ✅ First-class iOS/iPadOS/macOS from day one, touch + controller, App-Store-friendly, single codebase. We own the code. Decoders build cleanly in Swift (ResForge proves it). |

### Consequence

More engine work than adopting Kestrel — we reimplement the simulation
ourselves — but every line targets Apple platforms natively and there is no
dormant-codebase-revival tax.

## Layers

```
┌──────────────────────────────────────────────────────────────┐
│  apps/  (SwiftUI shells)                                       │
│    iOS/iPadOS  ·  macOS      → host a SpriteKit scene,          │
│                                per-platform input adapters      │
├──────────────────────────────────────────────────────────────┤
│  EVNovaEngine   (Swift)                                         │
│    deterministic simulation: Newtonian flight, AI, weapons,     │
│    missions, economy, galaxy/jump, save games                   │
│    rendering via SpriteKit (sprites, HUD, starfield) over Metal │
├──────────────────────────────────────────────────────────────┤
│  EVNovaKit      (Swift package — the reusable core)            │
│    ResourceFork  parse resource-fork / .ndat container          │
│    NovaTypes     decode shïp wëap oütf mïsn spöb sÿst gövt …     │
│    Graphics      rlëD / rlë8 / PICT  → CGImage / texture         │
│    Audio         snd  → PCM / CoreAudio                          │
│    PluginChain   layer plug-ins over base by (type,id) override  │
├──────────────────────────────────────────────────────────────┤
│  data/ (git-ignored)   base game (user-supplied) + plug-ins     │
└──────────────────────────────────────────────────────────────┘
```

`tools/extractor/` (`evnova-extract` CLI) is a thin front-end over `EVNovaKit`
that converts a data set into an open **asset pack** (JSON + PNG + audio) for
build-time bake or offline inspection. The app can also import on-device using
the same `EVNovaKit` code.

## Data flow

```
data/base/*.ndat  ─┐
data/plugins/*   ─┼─► EVNovaKit.PluginChain ─► resolved resource table
                   │        (base first, plug-ins override by type+id)
                   └─► Graphics/Audio decoders ─► textures / audio
                                    │
                                    ▼
                         EVNovaEngine runtime model ─► SpriteKit scene
```

## Reference implementations (studied, MIT — vendored under `third_party/`)

- **ResForge** (Swift) — resource-fork / Rez / PICT / `snd` decoding to model in Swift.
- **Graphite** (C++17) — reference for the `rlëD` RLE decoder and QuickDraw types.
- **novaparse** in **NovaJS** (TS) — reference for every Nova resource-type field layout.
- **evnova-utils** (Perl) — cross-check for field semantics.

We do not link these at runtime; we reimplement in Swift and use them as
executable specifications.

## Rendering: why SpriteKit first

SpriteKit is Apple-native, Metal-backed, cross-platform (iOS+macOS), and gives
us sprite nodes, texture atlases, a scene graph, and a physics/step loop for
free — ideal for a top-down 2D sprite game. We keep the simulation independent
of SpriteKit (engine computes state; SpriteKit only draws) so we can drop to raw
Metal for the starfield / shader effects later without touching game logic.
