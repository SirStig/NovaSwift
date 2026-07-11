# Project Charter — the one goal

> This is the **authoritative** statement of what this project is. Every other
> doc, roadmap item, and design decision serves this. If another doc contradicts
> this one, this one wins and the other doc is wrong — fix it.

## The goal, in one sentence

**Recreate the original EV Nova as faithfully as possible — the same game, the
same feel — running natively on Apple platforms, driven entirely by the
player's own legally-owned game data.**

Not "a game like EV Nova." Not "inspired by." **EV Nova**, as shipped by Ambrosia
Software / ATMOS, reproduced. If you own the game, this port should play *your*
copy — your ships, your systems, your missions, your storyline — indistinguishably
from the original, plus modern conveniences layered strictly on top.

## The two non-negotiable pillars

### 1. Fidelity first

The measure of every feature is: **does it match the original EV Nova?**

- Same flight model, same combat, same economy, same mission logic, same AI
  behavior, same UI layout — reconstructed from the real data, not approximated.
- Modern additions (higher resolution, touch controls, controllers,
  quality-of-life) are **opt-in and additive**. A pure "Classic" run must be
  reproducible and behave like the original.
- When in doubt, do what the original does. "Close enough" is a bug, not a
  feature.

### 2. Bring your own data (BYO-data)

The player supplies the game. **We ship code; the player ships EV Nova.**

- **No copyrighted game data is ever bundled** in this repo or the app. Not
  ships, not sprites, not sounds, not mission text — nothing from the original.
- Everything the player sees at runtime is decoded from **their own** resource
  files (classic resource fork / `.ndat` / `BRGR .rez`) plus community plug-ins
  they choose to install.
- **Nothing is hardcoded or mocked in the shipping game.** If a value, name,
  price, sprite, or behavior appears in play, it came from the player's data via
  `NovaSwiftKit`. Placeholder/sample data is allowed only in dev tools and tests,
  never in the play loop. (See "Anti-goals" — this one is currently violated in
  places; STATUS.md tracks where.)

## What "done" looks like

A player installs the app, points it at their own EV Nova files, and can:

- Start a **new pilot** from any real starting scenario (`chär`), or load an
  existing one.
- **Fly** their ship with the original's feel; **fight** NPCs that behave like
  the original's; **die**, with real consequences.
- **Jump** between systems, **fuel-gated** and consuming real fuel; navigate the
  real galaxy map.
- **Land**, visit the real spaceport, **trade / outfit / buy ships**, and pay for
  **repairs** — against a persistent pilot.
- Accept **missions** from the bar and BBS, watch the **NCB control-bit** state
  advance, receive `crön` background events, and **play through the real
  storylines** to completion.
- Install **plug-ins** and total conversions and have them Just Work via the
  override chain.

All of it from their data. None of it faked.

## The distinction that governs this project

Everything in the codebase is in exactly one of three states. We track this
honestly in [`STATUS.md`](STATUS.md), and we do not let docs blur the line:

| State | Meaning |
|---|---|
| **Wired** | Built *and* driven by the running app. The player experiences it. |
| **Built, not wired** | The code exists and is tested/exercised by the CLI or unit tests, but the running game never calls it. The player does **not** experience it. |
| **Missing** | Not built, or only a UI shell / "coming soon" placeholder. |

> **The project's central risk is confusing "built" with "wired."** We have
> written large systems (the mission/story runtime is the prime example) that are
> fully implemented and tested but *not connected to the live game*. A feature
> that isn't wired does not exist for the player. Roadmap priority is therefore
> weighted toward **wiring what's built** before building more.

## Anti-goals (things that violate the charter)

- ❌ Hardcoded game values, names, prices, or sample data in the play loop.
- ❌ Systems that are "done" in a library but never called by the app being
  described as done.
- ❌ Bundling any original game asset "just for testing."
- ❌ Modern redesigns that replace (rather than sit beside) the authentic
  experience.
- ❌ Gameplay shortcuts that diverge from the original "to make it simpler"
  (e.g. free/instant jumps, immortal player, free repairs) — these are bugs.

## Legal posture

Interoperability / preservation effort, in the spirit of OpenRA, OpenTTD, and
devilutionX. Unaffiliated with and unendorsed by Ambrosia Software, ATMOS, or
the original authors. This project's code is open source; the game data is the
player's own. See the root [`README.md`](../README.md#legal).
