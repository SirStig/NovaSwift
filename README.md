# EV Nova — Apple Platforms Port (unofficial)

A non-commercial, fan project to bring **EV Nova** (Escape Velocity Nova,
originally by Ambrosia Software / ATMOS) to modern **iOS, iPadOS, and macOS** as
a native app — with full support for the game's data and the community
plug-in ecosystem.

This repo contains **only** open reimplementation code and tooling. It contains
**no copyrighted game data**. See [Legal](#legal) below.

---

## Status

🟢 **M1 + M2 (rlëD) complete — we read real game data *and* render its art.**
`EVNovaKit` reads both classic resource forks / `.ndat` and the modern `BRGR`
`.rez` container, and decodes `rlëD` sprites to RGBA/PNG. Verified end-to-end on
a full owned copy of EV Nova (288+ ships, 545 systems, 411 planets) and its ship
sprites (36-frame rotations decode pixel-perfect). Engine foundation: native
Swift + Metal/SpriteKit. Next: `PICT`/`rlë8`, typed resource bodies, then a
SpriteKit fly-a-ship demo. See [`docs/ROADMAP.md`](docs/ROADMAP.md).

```bash
swift build && swift test                    # build the core + run tests
scripts/fetch-plugins.sh                      # grab free community plug-ins (test data)
# With your own EV Nova data in data/base/:
.build/debug/evnova-extract types   "data/base/Nova Files/Nova Data 1.rez"
.build/debug/evnova-extract sprites "data/base/Nova Files/Nova Ships 1.rez" out/
```

## Goals

- Native Apple app (Metal-backed) that runs the original EV Nova and arbitrary
  plug-ins / total conversions.
- Faithful implementation of the classic-Mac **resource-fork** data format the
  game uses (ships, outfits, weapons, missions, systems, sprites, sounds …).
- A reusable **asset-extraction pipeline**: original data → open formats
  (PNG / JSON / audio) that the runtime consumes.
- Touch-first UI for iPhone/iPad; keyboard/mouse + controller on macOS.

## Repository layout

```
docs/                Design notes, data-format reference, roadmap
tools/extractor/     Converts EV Nova resource data → open formats (PNG/JSON/audio)
engine/              The game runtime (engine choice TBD — see docs/ARCHITECTURE.md)
apps/ios/            iOS/iPadOS app target
apps/macos/          macOS app target
third_party/         Vendored open-source deps (fetched by scripts, not committed)
scripts/             Setup / fetch / build helper scripts
data/base/           ⬅ YOU place your legally-owned EV Nova data here (git-ignored)
data/plugins/        Community plug-ins & total conversions (git-ignored)
data/converted/      Extractor output (git-ignored)
```

## Getting started

> Requires macOS with Xcode command-line tools.

```bash
scripts/setup.sh          # fetch open-source dependencies into third_party/
# Place your EV Nova data files into data/base/  (see docs/GET_THE_DATA.md)
scripts/fetch-plugins.sh  # (optional) download freely-distributable community plug-ins
```

Detailed steps live in [`docs/GET_THE_DATA.md`](docs/GET_THE_DATA.md).

## Legal

EV Nova and its game data are **copyrighted**. This project does **not** and
**will not** redistribute the base game's data files. To use this port you must
supply your own legally-obtained copy of EV Nova.

- **Base game data** → you must own EV Nova; the repo helps you *extract* from
  your own copy. It is never bundled here.
- **Community plug-ins / total conversions** → freely distributed by their
  authors; the fetch script only pulls ones offered for free download, and
  their own licenses/readmes apply.
- **This project's code** → open source (see [`LICENSE`](LICENSE)).

This is an interoperability / preservation effort in the spirit of engine
reimplementations like OpenRA, OpenTTD, and devilutionX. It is unaffiliated
with and unendorsed by Ambrosia Software, ATMOS, or the original authors.
