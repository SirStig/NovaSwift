# Charter

What this project is. Everything else in `docs/` serves this; if another doc
contradicts it, the other doc is wrong.

## The goal

**Recreate EV Nova as faithfully as possible — the same game, the same feel —
running natively on Apple platforms, driven entirely by the player's own
legally-owned game data.**

Not "a game like EV Nova." Not "inspired by." EV Nova, as Ambrosia Software and
ATMOS shipped it, reproduced. If you own the game, this port should play *your*
copy — your ships, your systems, your missions, your storyline —
indistinguishably from the original, with modern conveniences layered strictly on
top.

## Two non-negotiables

### Fidelity first

The measure of every feature is: does it match the original?

Same flight model, same combat, same economy, same mission logic, same AI
behaviour, same UI layout — reconstructed from the real data, not approximated.
Modern additions (higher resolution, touch controls, controllers,
quality-of-life) are opt-in and additive, and a pure Classic run must behave like
the original. When in doubt, do what the original does. "Close enough" is a bug.

### Bring your own data

The player supplies the game. We ship code; the player ships EV Nova.

No copyrighted game data is ever bundled in this repo or the app — not ships, not
sprites, not sounds, not mission text. Everything the player sees at runtime is
decoded from **their own** resource files (classic resource fork, `.ndat`, or
`BRGR .rez`) plus whatever community plug-ins they choose to install.

Nothing is hardcoded or mocked in the shipping game. If a value, name, price,
sprite or behaviour appears in play, it came from the player's data through
`NovaSwiftKit`. Placeholder data is allowed in dev tools and tests, never in the
play loop.

## What "done" looks like

A player installs the app, points it at their own EV Nova files, and can:

- Start a new pilot from any real starting scenario (`chär`), or load an existing
  one.
- Fly with the original's feel, fight NPCs that behave like the original's, and
  die with real consequences.
- Jump between systems, fuel-gated, and navigate the real galaxy map.
- Land, visit the real spaceport, trade and outfit and buy ships, and pay for
  repairs — against a persistent pilot.
- Take missions, watch the NCB control-bit state advance, receive `crön`
  background events, and play the real storylines to completion.
- Install plug-ins and total conversions and have them just work through the
  override chain.

All of it from their data. None of it faked.

## Built is not wired

Everything in the codebase is in exactly one of three states, tracked in
[STATUS.md](STATUS.md):

| State | Meaning |
|---|---|
| **Wired** | Built *and* driven by the running app. The player experiences it. |
| **Built, not wired** | The code exists and is tested, but the running game never calls it. |
| **Missing** | Not built, or only a UI shell. |

The distinction exists because it is easy to write a large, well-tested system
and never connect it — the mission runtime spent months in that state. A feature
that isn't wired does not exist for the player, so roadmap priority favours
wiring what's built over building more.

## Anti-goals

- Hardcoded game values, names, prices or sample data in the play loop.
- Describing a library feature as done when the app never calls it.
- Bundling any original game asset, even "just for testing."
- Modern redesigns that replace rather than sit beside the authentic experience.
- Gameplay shortcuts that diverge from the original to make it simpler — free or
  instant jumps, an immortal player, free repairs. These are bugs.

## Legal posture

An interoperability and preservation effort, in the spirit of OpenRA, OpenTTD and
devilutionX. Unaffiliated with and unendorsed by Ambrosia Software, ATMOS, or the
original authors. This project's code is open source; the game data is the
player's own. See the root [README](../README.md#legal).
