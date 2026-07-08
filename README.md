# EV Nova — Apple Platforms Port (unofficial)

A non-commercial, fan project to recreate **EV Nova** (Escape Velocity Nova,
originally by Ambrosia Software / ATMOS) as faithfully as possible as a native
app for modern **iOS, iPadOS, and macOS** — playing the player's own game data
and the community plug-in ecosystem.

> **The one goal:** reproduce the original EV Nova, the same game and the same
> feel, driven entirely by the **player's own legally-owned data**. We ship
> code; you bring EV Nova. Read the authoritative
> **[Project Charter](docs/CHARTER.md)** first — it governs everything else.

This repo contains **only** open reimplementation code and tooling. It contains
**no copyrighted game data**. See [Legal](#legal).

---

## Status

We have a **real, connected vertical slice** running on real game data: fly with
the original flight model, fight AI ships spawned from the real fleet tables,
navigate the real galaxy map, jump between systems, land, and trade / outfit /
buy ships in the spaceport against a persistent pilot.

**Not yet wired for the player:** the mission/story runtime (built as a library,
not yet connected to the live game), fuel-gated travel, player death/stakes, and
pilot management. The honest, verified breakdown of what's **wired vs. built-but-
not-wired vs. missing** lives in **[docs/STATUS.md](docs/STATUS.md)** — start
there to understand the real state.

Foundation in place: `EVNovaKit` reads classic resource forks / `.ndat` and the
modern `BRGR .rez` container and decodes `rlëD`/`PICT` art (verified on a full
owned copy — 288+ ships, 545 systems, 411 planets). `EVNovaEngine` runs the live
flight/combat/AI sim. `EVNovaStory` implements the mission/NCB engine (wiring
pending). Native Swift + Metal/SpriteKit; engine decision is final — see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

```bash
swift build && swift test                    # build the core + run tests
scripts/fetch-plugins.sh                     # grab free community plug-ins (test data)
# With your own EV Nova data in data/base/:
.build/debug/evnova-extract types   "data/base/Nova Files/Nova Data 1.rez"
.build/debug/evnova-extract sprites "data/base/Nova Files/Nova Ships 1.rez" out/
```

## Goals

See the **[Charter](docs/CHARTER.md)** for the full statement. In short:

- **Fidelity first** — match the original EV Nova's flight, combat, economy,
  missions, AI, and UI, reconstructed from the real data. Modern additions
  (resolution, touch, controllers, QoL) are opt-in and additive.
- **Bring your own data** — nothing copyrighted is bundled; everything at runtime
  is decoded from the player's own files. Nothing hardcoded or mocked in the
  shipping game.
- **Native Apple app** — Metal-backed, touch-first on iPhone/iPad, keyboard/mouse
  + controller on macOS. Runs the base game and arbitrary plug-ins / total
  conversions.

## Repository layout

```
docs/               Charter, status, architecture, data-format reference, roadmap
Sources/
  EVNovaKit/        Data layer — resource parsing, typed decoders, sprite/PICT decode
  EVNovaEngine/     Live simulation — flight, combat, AI, spawning, diplomacy
  EVNovaStory/      Mission/story runtime — mïsn/crön/NCB engine (wiring in progress)
  evnova-extract/   CLI inspector/harness (drives the libraries end-to-end)
Tests/              Unit tests for each library target
app/EVNova/         The multiplatform SwiftUI/SpriteKit app (the game itself)
  App/ Game/ Spaceport/ Pilots/ Story/ Launcher/ Input/ Audio/ UI/ Data/
app/EVNova.xcodeproj
assets/             This project's own art (icon, placeholders) — no game data
scripts/            Setup / fetch / build helpers
data/base/          ⬅ YOU place your legally-owned EV Nova data here (git-ignored)
data/plugins/       Community plug-ins & total conversions (git-ignored)
data/converted/     Extractor output (git-ignored)
third_party/        Vendored open-source deps (fetched by scripts, not committed)
```

(`engine/` and `tools/` are legacy empty placeholders from an earlier layout and
will be removed; the real code is the Swift package above.)

## Getting started

> Requires macOS with Xcode command-line tools.

```bash
scripts/setup.sh          # fetch open-source dependencies into third_party/
# Place your EV Nova data files into data/base/  (see docs/GET_THE_DATA.md)
scripts/fetch-plugins.sh  # (optional) download freely-distributable community plug-ins
swift build && swift test
```

Detailed data steps live in [docs/GET_THE_DATA.md](docs/GET_THE_DATA.md). Open
`app/EVNova.xcodeproj` in Xcode to build and run the app.

## Documentation

- **[docs/CHARTER.md](docs/CHARTER.md)** — the authoritative goal (read first).
- **[docs/STATUS.md](docs/STATUS.md)** — verified wired-vs-built-vs-missing map.
- **[docs/ROADMAP.md](docs/ROADMAP.md)** — sequenced plan, wiring-first.
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — engine decision & layers.
- **[docs/DATA_FORMAT.md](docs/DATA_FORMAT.md)** — resource formats & type codes.
- Subsystem deep-dives: [AI](docs/AI.md), [ship system](docs/SHIP_SYSTEM.md),
  [missions & story](docs/MISSIONS.md),
  [mobile & plug-ins](docs/MOBILE_AND_PLUGINS.md),
  [modernization](docs/MODERNIZATION.md),
  [editor scope](docs/EDITOR_AND_PLUGINS_SCOPE.md).

## Legal

EV Nova and its game data are **copyrighted**. This project does **not** and
**will not** redistribute the base game's data files. To use this port you must
supply your own legally-obtained copy of EV Nova.

- **Base game data** → you must own EV Nova; the repo helps you *extract* from
  your own copy. It is never bundled here.
- **Community plug-ins / total conversions** → freely distributed by their
  authors; the fetch script only pulls ones offered for free download, and
  their own licenses/readmes apply.
- **This project's code** → open source (see [LICENSE](LICENSE)).

This is an interoperability / preservation effort in the spirit of engine
reimplementations like OpenRA, OpenTTD, and devilutionX. It is unaffiliated
with and unendorsed by Ambrosia Software, ATMOS, or the original authors.
