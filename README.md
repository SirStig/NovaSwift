# NovaSwift

![NovaSwift](docs/branding/logo-banner.png)

**EV Nova, rebuilt in Swift — so the 2002 classic runs natively on your Mac,
iPad, and iPhone.** Unofficial, unaffiliated, bring-your-own-data. See
[Legal](#legal).

---

EV Nova (Ambrosia Software / ATMOS, 2002) is one of the deepest space
trading-and-combat games ever made — and it's stranded. The original is
PowerPC/Carbon code that won't launch on Apple Silicon, never had a mobile
release, and the one serious open-source revival went dormant in 2023.

NovaSwift rebuilds the whole game — resource parser, flight and combat sim, AI,
mission engine, economy, UI — from scratch in Swift on Metal/SpriteKit. It's not
a wrapper and not an emulator: it reads your *own* EV Nova data files and
reproduces the game faithfully, with touch controls in your pocket and room to
go further than 2002 ever allowed.

## Screenshots

Running on iPhone 17 Pro (iOS):

| Main menu | Flight | Galaxy map |
|---|---|---|
| ![Main menu](docs/branding/screenshots/main-menu.png) | ![Flight HUD](docs/branding/screenshots/flight-hud.png) | ![Galaxy map](docs/branding/screenshots/galaxy-map.png) |

## What works today

A real, playable game — not a tech demo. On your own data you can:

- **Fly and fight** — the original Newtonian flight model, AI ships spawned from
  the real fleet tables, ionization, target-lock, and combat-odds decisions.
- **Explore and trade** — plot courses across the real galaxy map and burn real
  fuel on jumps, then land to trade, outfit, and buy ships against a persistent
  pilot — with mass-based outfit pricing, slot limits, and paid repairs & refuel
  (no more free heal on landing).
- **Play the campaign** — take and *complete* missions; the galaxy-day clock
  ticks as you fly, so background events and news fire, mission ships spawn and
  fight, and storylines actually progress.
- **Lose** — run your armor to zero and you eject in an escape pod, or it's game
  over. Wreck the wrong government's ships and your record follows you.
- **Live in the world** — meet `përs` named captains with their own quotes and
  grudges, hire escorts (they draw a daily wage) and upgrade/sell/dismiss them,
  and gamble on the holovid races — all against real credits.

The honest gap is **fidelity, not features.** EV Nova's AI and ship-spawning
were never open-sourced, so ours is reconstructed from the data and observed
behavior. It covers the documented behavior well, but flight smoothness and
traffic rhythm don't yet *feel* exactly like the original — that's the top of
the backlog. A couple of finished systems also still need their last hookup
(Demand Tribute, junk trading). Full breakdown in
**[docs/STATUS.md](docs/STATUS.md)** — the real source of truth.

## Things the original never had

Because it's our code now, NovaSwift already does a few things the 2002 game
couldn't:

- **A live Story Map** — a pannable, zoomable graph of every campaign in your
  data, resolved against *your* pilot's actual progress.
- **Multiple pilots, side by side** — roll up new pilots from any starting
  scenario in your data and switch between them; every save is backed up
  automatically.
- **An in-app plug-in store** — browse and install community plug-ins and total
  conversions without ever leaving the game.
- **A native, touch-first app** — real iPhone and iPad builds, plus
  keyboard/mouse (and planned controller) support on macOS.
- **A built-in debug suite** — AI state and path visualization, a live
  game-state editor, and a performance stress test.

## Where it's headed

Fidelity comes first: a pure **Classic** run stays reproducible and behaves
exactly like the original. Everything modern is an **opt-in layer on top**, never
a replacement. On the roadmap — the seams already exist, nothing has shipped:

- **Enhanced AI** — smarter evasion, coordinated fleets, ammo conservation,
  behind the same `AIBrain.think` seam the base AI uses.
- **HD art & richer audio** — higher-resolution sprites and sound packs, layered
  over the originals.
- **Controllers & QoL** — full gamepad support, remappable controls, and
  presentation modes (Classic / Enhanced / Nova Swift).

The plans live in **[docs/MODERNIZATION.md](docs/MODERNIZATION.md)** and
**[docs/ROADMAP.md](docs/ROADMAP.md)**.

## The one rule: you bring the game

We ship code; you supply the data. EV Nova's content is still owned by ATMOS, so
**this repo contains zero copyrighted game data and never will.** `NovaSwiftKit`
reads your own legally-owned copy at runtime — classic resource forks, `.ndat`,
or the modern `BRGR .rez` container — the same bring-your-own-data model as
OpenMW and OpenRA. The full reasoning is in
**[docs/CHARTER.md](docs/CHARTER.md)**, which governs every decision in the repo.

## Built with AI

NovaSwift is developed with heavy AI assistance — most of the engine, the UI,
and the reverse-engineering of EV Nova's resource formats were built
collaboratively with Claude Code. Every change is still checked against the real
game's behavior; fidelity-first applies no matter who (or what) wrote the line.

Fittingly, AI is also a subject *inside* the game: NPCs run on a real behavior
engine reconstructed from EV Nova's own `düde`/`flët` decision tables, not
hardcoded scripts. See [docs/AI.md](docs/AI.md).

## Getting started

> Requires macOS with Xcode command-line tools.

```bash
scripts/setup.sh          # fetch open-source dependencies
# Place your EV Nova data into data/base/  (see docs/GET_THE_DATA.md)
scripts/fetch-plugins.sh  # (optional) free community plug-ins
swift build && swift test
```

Open `app/NovaSwift.xcodeproj` in Xcode to build and run the app. Data steps are
in [docs/GET_THE_DATA.md](docs/GET_THE_DATA.md).

## Repository layout

```
docs/                  Charter, status, roadmap, architecture, data-format reference
Sources/
  NovaSwiftKit/          Data layer — resource parsing, typed decoders, sprite/PICT decode
  NovaSwiftEngine/       Live sim — flight, combat, AI, spawning, diplomacy
  NovaSwiftStory/        Mission/story runtime — mïsn/crön/NCB engine
  NovaSwiftPluginStore/  Plug-in catalog + download/install pipeline
  novaswift-extract/     CLI inspector/harness that drives the libraries end-to-end
Tests/                 Unit tests per library
app/NovaSwift/           The multiplatform SwiftUI/SpriteKit app (the game itself)
data/base/             ⬅ your legally-owned EV Nova data goes here (git-ignored)
```

## Documentation

- **[Charter](docs/CHARTER.md)** — the authoritative goal (read first).
- **[Status](docs/STATUS.md)** — what actually works right now.
- **[Roadmap](docs/ROADMAP.md)** — what's next, in order.
- **[Modernization](docs/MODERNIZATION.md)** — the opt-in enhancement layer.
- **[Architecture](docs/ARCHITECTURE.md)** · **[Data format](docs/DATA_FORMAT.md)** — how it's built.
- Deep dives: [AI](docs/AI.md), [ship system](docs/SHIP_SYSTEM.md),
  [missions & story](docs/MISSIONS.md),
  [mobile & plug-ins](docs/MOBILE_AND_PLUGINS.md).

## Legal

EV Nova and its data are **copyrighted**, and this project never redistributes
them — you supply your own legally-obtained copy.

- **Base game data** → you must own EV Nova; the tools only extract from *your*
  copy. It is never bundled here.
- **Community plug-ins** → freely distributed by their authors; the fetch script
  and in-app store pull only free downloads, under their own licenses.
- **This project's code** → open source (see [LICENSE](LICENSE)).

An interoperability / preservation effort in the spirit of OpenRA, OpenTTD, and
devilutionX. Unaffiliated with and unendorsed by Ambrosia Software, ATMOS, or
the original authors.
