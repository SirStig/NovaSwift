# NovaSwift

![NovaSwift](docs/branding/logo-banner.png)

A native Swift/Metal port of **EV Nova**, rebuilt from scratch so it can
finally run properly on a modern Mac, iPad, or iPhone. Unofficial and
unaffiliated with the original publisher — see [Legal](#legal).

## What this is

EV Nova (Ambrosia Software / ATMOS, 2002) is a 2D space trading, combat, and
mission game with one of the deepest campaigns and plug-in ecosystems ever
built for a niche Mac title. The original binary is PowerPC/Carbon-era code —
it doesn't run natively on Apple Silicon, has no iOS build, and the one
serious open-source revival effort (Kestrel, C++) is desktop-only and has
been dormant since 2023. If you want to play EV Nova on the hardware most of
us actually carry around, there's currently no good way to do it.

So this project reimplements the whole thing: the resource-file parser, the
flight and combat sim, the AI, the mission/story engine, the economy, the
UI — all of it, from the ground up in Swift, targeting Metal/SpriteKit so it
runs natively on iOS, iPadOS, and macOS. Not a wrapper, not an emulator — a
genuine port that reads the *original game's data files* and reproduces the
original game as faithfully as possible.

## Why this project exists

Two reasons, in order of priority.

**First, and mainly: get the real game onto iPhone and iPad.** EV Nova has
never had a mobile release, and the original app won't run on anything Apple
ships today. A native Swift/Metal rewrite is the only way to get the actual
game — same ships, same missions, same economy — running with touch
controls on a phone in your pocket, not just kept alive in an emulator on a
desktop.

**Second: once it's native code we control, we can go further than the 2002
original ever could.** The original engine is a fixed, closed target — it
can't get smarter, prettier, or more capable no matter how much anyone wants
it to. A from-scratch native rewrite *can*: better-than-original AI
opponents, higher-resolution art, richer effects and audio, controller
support, bigger displays — all as **opt-in layers on top of a faithful
base**, never a replacement for it. See
[docs/MODERNIZATION.md](docs/MODERNIZATION.md) for the concrete plan (AI
tuning knobs, HD art/audio "enhancement packs" over the existing plug-in
override chain, etc.) — none of it has shipped yet, but the seams for it
already exist in the engine.

Fidelity to the original always comes first, though — see the next section.
A pure "Classic" run must stay reproducible and behave exactly like the
original; enhancements are additive, never a substitute for the real thing.

**The one rule that shapes everything else:** we ship code, you bring the
game. EV Nova was commercial shareware and its data is still owned by ATMOS —
this repo contains zero copyrighted game content, and never will. Instead,
`NovaSwiftKit` reads your own legally-owned copy of the game at runtime (classic
resource forks, `.ndat`, or the modern `BRGR .rez` container) the same way
projects like OpenMW or OpenRA work: engine and tooling are open source, data
is bring-your-own. The full reasoning lives in
**[docs/CHARTER.md](docs/CHARTER.md)** — read that first, it governs every
other decision in this repo.

## How AI fits into this project

AI shows up here in two completely different ways — worth being upfront
about both.

**This codebase is built with heavy AI assistance.** Most of the engine,
UI, and reverse-engineering work in this repo has been developed
collaboratively with Claude Code as a coding partner — reconstructing
resource-file layouts from a decompiled original, writing and testing the
Swift engine code, and building out the SwiftUI/SpriteKit app. That's a
practical necessity: faithfully re-deriving an entire commercial game engine
from its original data formats, byte-for-byte, is a huge reverse-engineering
and implementation effort for a small team, and AI pair-programming is what
makes tackling it at this scope realistic. Every change still gets reviewed
against the real game's behavior — the [Charter](docs/CHARTER.md)'s
fidelity-first rule applies regardless of who (or what) wrote the code.

**Separately, AI is also a subject *inside* the game itself.** NPC ships
run on a real behavior engine (`AIBrain.swift`) reconstructed from the
original's actual decision tables — combat odds, flee/press thresholds,
target selection, formation and fleet behavior all come from the real `düde`
and `flët` data, not hardcoded scripts. See
[docs/AI.md](docs/AI.md) and [docs/AI_GROUND_TRUTH.md](docs/AI_GROUND_TRUTH.md)
for how that was reverse-engineered and verified. Beyond matching the
original faithfully, an **opt-in "Enhanced AI" mode** is planned (see
[docs/MODERNIZATION.md](docs/MODERNIZATION.md)) — smarter, more
human-feeling opponents (better evasion, coordinated fleets, ammo
conservation) layered behind the same `AIBrain.think` seam, off by default,
never replacing the classic behavior a fidelity-first run depends on.

## Status — what actually works right now

This is a real, playable vertical slice, not a tech demo. On your own game
data you can today:

- Fly with the original Newtonian flight model, fight AI ships spawned from
  the real fleet tables, and get hit with real ionization, combat-odds AI
  decision-making, and target-lock.
- Navigate the real galaxy map, plot a course, and jump between systems —
  jumps cost real fuel, gated by the ship's actual tank.
- Land, and trade / outfit / buy ships in the spaceport against a persistent
  pilot save, with mission-gated item availability (an outfit you haven't
  unlocked yet is genuinely locked, not just hidden).
- Accept missions from the bar and Mission Computer — offer/accept/decline
  is real and persists to your save.
- Browse and install community plug-ins from an in-app store.
- Pop open an in-game **debug suite** (AI state/path visualization, a
  live game-state editor, a performance stress test) while developing.

The part that's still missing is the part that makes it *feel like a
finished game*: the galaxy's day-clock never advances during play, so `crön`
background events (news, dated story beats) never fire — only the slice of
the story reachable through a single landing's mission list actually runs.
There's also no way to actually lose yet — no player death, no game over, no
paid repairs. (The in-game menu does have a **Story Map** — a
pannable/zoomable graph of every reconstructed campaign, resolved live
against your pilot: what's available now, what each step unlocks, and
exactly what's gating anything still locked.)

See **[docs/STATUS.md](docs/STATUS.md)** for the full, honestly-audited
wired-vs-built-vs-missing breakdown — that document, not this README, is the
source of truth for what's real today.

```bash
swift build && swift test                    # build the core + run tests
scripts/fetch-plugins.sh                     # grab free community plug-ins (test data)
# With your own EV Nova data in data/base/:
.build/debug/novaswift-extract types   "data/base/Nova Files/Nova Data 1.rez"
.build/debug/novaswift-extract sprites "data/base/Nova Files/Nova Ships 1.rez" out/
```

## Goals

See the **[Charter](docs/CHARTER.md)** for the full statement. In short:

- **Fidelity first** — match the original EV Nova's flight, combat, economy,
  missions, AI, and UI, reconstructed from the real data. Modern additions
  (resolution, touch, controllers, AI tuning, QoL) are opt-in and additive,
  never a substitute for the real thing.
- **Bring your own data** — nothing copyrighted is bundled; everything at
  runtime is decoded from the player's own files. Nothing hardcoded or
  mocked in the shipping game.
- **Native Apple app** — Metal-backed, touch-first on iPhone/iPad, keyboard/
  mouse + controller on macOS. Runs the base game and arbitrary plug-ins /
  total conversions.

## Repository layout

```
docs/                   Charter, status, architecture, data-format reference, roadmap
Sources/
  NovaSwiftKit/            Data layer — resource parsing, typed decoders, sprite/PICT decode
  NovaSwiftEngine/         Live simulation — flight, combat, AI, spawning, diplomacy
  NovaSwiftStory/          Mission/story runtime — mïsn/crön/NCB engine (wiring in progress)
  NovaSwiftPluginStore/    Plug-in catalog metadata + download/install pipeline
  novaswift-extract/       CLI inspector/harness (drives the libraries end-to-end)
Tests/                  Unit tests for each library target
app/NovaSwift/             The multiplatform SwiftUI/SpriteKit app (the game itself)
  App/ Game/ Spaceport/ Pilots/ Story/ Store/ Launcher/ Input/ Audio/ UI/ Debug/ Data/
app/NovaSwift.xcodeproj
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
`app/NovaSwift.xcodeproj` in Xcode to build and run the app.

## Documentation

- **[docs/CHARTER.md](docs/CHARTER.md)** — the authoritative goal (read first).
- **[docs/STATUS.md](docs/STATUS.md)** — verified wired-vs-built-vs-missing map.
- **[docs/ROADMAP.md](docs/ROADMAP.md)** — sequenced plan, wiring-first.
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — engine decision & layers.
- **[docs/MODERNIZATION.md](docs/MODERNIZATION.md)** — the opt-in enhancement
  layer: smarter AI, HD art/audio packs, everything beyond the original.
- **[docs/DATA_FORMAT.md](docs/DATA_FORMAT.md)** — resource formats & type codes.
- Subsystem deep-dives: [AI](docs/AI.md), [ship system](docs/SHIP_SYSTEM.md),
  [missions & story](docs/MISSIONS.md),
  [mobile & plug-ins](docs/MOBILE_AND_PLUGINS.md),
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
