# EV Nova — Apple Platforms Port (unofficial)

**Escape Velocity Nova**, rebuilt from scratch in native Swift, so it can run
properly on a modern Mac, iPad, or iPhone.

## What this is

EV Nova (Ambrosia Software / ATMOS, 2002) is a 2D space trading, combat, and
mission game with one of the deepest campaigns and plug-in ecosystems ever
built for a niche Mac title. The original binary is PowerPC/Carbon-era code —
it doesn't run natively on Apple Silicon, has no iOS build, and the one
serious open-source revival effort (Kestrel, C++) is desktop-only and has been
dormant since 2023.

So this project reimplements the whole thing: the resource-file parser, the
flight and combat sim, the AI, the mission/story engine, the economy, the UI —
all of it, from the ground up in Swift, targeting Metal/SpriteKit so it runs
natively on iOS, iPadOS, and macOS. Not a wrapper, not an emulator — a genuine
port that reads the *original game's data files* and reproduces the original
game as faithfully as possible, with modern platform support layered on top.

**The one rule that shapes everything else:** we ship code, you bring the
game. EV Nova was commercial shareware and its data is still owned by ATMOS —
this repo contains zero copyrighted game content, and never will. Instead,
`EVNovaKit` reads your own legally-owned copy of the game at runtime (classic
resource forks, `.ndat`, or the modern `BRGR .rez` container) the same way
projects like OpenMW or OpenRA work: engine and tooling are open source, data
is bring-your-own. The full reasoning lives in **[docs/CHARTER.md](docs/CHARTER.md)**
— read that first, it governs every other decision in this repo.

## Status — what actually works right now

This is a real, playable vertical slice, not a tech demo. On your own game
data you can today:

- Fly with the original Newtonian flight model, fight AI ships spawned from
  the real fleet tables, and get hit with real ionization, combat-odds AI
  decision-making, and target-lock.
- Navigate the real galaxy map, plot a course, and jump between systems —
  jumps now cost real fuel, gated by the ship's actual tank.
- Land, and trade / outfit / buy ships in the spaceport against a persistent
  pilot save, with mission-gated item availability (an outfit you haven't
  unlocked yet is genuinely locked, not just hidden).
- Browse and install community plug-ins from an in-app store.

The part that's still missing is the part that makes it *feel like a
finished game*: the mission/story campaign isn't driving play yet (there's a
Mission BBS button and window, but it's a placeholder — the underlying
`StoryEngine` runs only under the CLI and tests, not in the app), and there's
no way to actually lose — no player death, no game over, no paid repairs. See
**[docs/STATUS.md](docs/STATUS.md)** for the full, honestly-audited
wired-vs-built-vs-missing breakdown — that document, not this README, is the
source of truth for what's real.

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
  (resolution, touch, controllers, QoL) are opt-in and additive, never a
  substitute for the real thing.
- **Bring your own data** — nothing copyrighted is bundled; everything at
  runtime is decoded from the player's own files. Nothing hardcoded or mocked
  in the shipping game.
- **Native Apple app** — Metal-backed, touch-first on iPhone/iPad, keyboard/
  mouse + controller on macOS. Runs the base game and arbitrary plug-ins /
  total conversions.

## Repository layout

```
docs/                   Charter, status, architecture, data-format reference, roadmap
Sources/
  EVNovaKit/            Data layer — resource parsing, typed decoders, sprite/PICT decode
  EVNovaEngine/         Live simulation — flight, combat, AI, spawning, diplomacy
  EVNovaStory/          Mission/story runtime — mïsn/crön/NCB engine (wiring in progress)
  EVNovaPluginStore/    Plug-in catalog metadata + download/install pipeline
  evnova-extract/       CLI inspector/harness (drives the libraries end-to-end)
Tests/                  Unit tests for each library target
app/EVNova/             The multiplatform SwiftUI/SpriteKit app (the game itself)
  App/ Game/ Spaceport/ Pilots/ Story/ Store/ Launcher/ Input/ Audio/ UI/ Data/
app/EVNova.xcodeproj
assets/                 This project's own art (icon, placeholders) — no game data
scripts/                Setup / fetch / build helpers
data/base/              ⬅ YOU place your legally-owned EV Nova data here (git-ignored)
data/plugins/           Community plug-ins & total conversions (git-ignored)
data/converted/         Extractor output (git-ignored)
third_party/            Vendored open-source deps (fetched by scripts, not committed)
```

(`engine/` and `tools/` are legacy empty placeholders from an earlier layout
and will be removed; the real code is the Swift package above.)

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
**will not** redistribute the base game's data files. To use this port you
must supply your own legally-obtained copy of EV Nova.

- **Base game data** → you must own EV Nova; the repo helps you *extract*
  from your own copy. It is never bundled here.
- **Community plug-ins / total conversions** → freely distributed by their
  authors; the fetch script and in-app store only pull ones offered for free
  download, and their own licenses/readmes apply.
- **This project's code** → open source (see [LICENSE](LICENSE)).

This is an interoperability / preservation effort in the spirit of engine
reimplementations like OpenRA, OpenTTD, and devilutionX. It is unaffiliated
with and unendorsed by Ambrosia Software, ATMOS, or the original authors.
