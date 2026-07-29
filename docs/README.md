# NOVA Swift documentation

Start here. Everything in this folder is one of four kinds of document, and
knowing which kind you're reading tells you how much to trust it.

| Kind | What it means |
|---|---|
| **Reference** | How something works today. Follows the code; if it disagrees with the code, the doc is wrong. |
| **Ground truth** | What the *original* EV Nova does, quoted from ATMOS's own Nova Bible and verified against real game data. Doesn't change. |
| **Plan** | What we intend to build. Aspirational by definition. |
| **Charter** | Why the project exists and what it refuses to do. Everything else serves it. |

## Where to start

**New to the project?** Read the [root README](../README.md), then
[CHARTER.md](CHARTER.md) — one page on what this is and isn't.

**Want to know if something works?** [STATUS.md](STATUS.md). It's the single
place that answers "can a player actually do this today?" Individual docs do not
carry their own status.

**Want to work on something?** [ROADMAP.md](ROADMAP.md) for what's next, then
[ARCHITECTURE.md](ARCHITECTURE.md) for how the code is laid out.

**Trying to get the game running?** [GET_THE_DATA.md](GET_THE_DATA.md).

## The documents

### Direction

- **[CHARTER.md](CHARTER.md)** — the goal, the two non-negotiables (fidelity
  first, bring-your-own-data), and the anti-goals.
- **[STATUS.md](STATUS.md)** — what works today, what's built but unreachable,
  and what's genuinely missing.
- **[ROADMAP.md](ROADMAP.md)** — what's next, in priority order.

### How the port is built

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — module layout and the engine
  decision (native Swift + SpriteKit/Metal, BYO-data).
- **[DATA_FORMAT.md](DATA_FORMAT.md)** — the container formats, resource types,
  and RLE sprite encoding. What `NovaSwiftKit` parses.
- **[GET_THE_DATA.md](GET_THE_DATA.md)** — how a player supplies their own copy
  of EV Nova.

### Game systems

- **[AI.md](AI.md)** — NPC AI: dispositions, combat decisions, spawning.
- **[MISSIONS.md](MISSIONS.md)** — the story runtime: `mïsn`/`crön` scripting
  and the NCB control-bit engine.
- **[SHIP_SYSTEM.md](SHIP_SYSTEM.md)** — hull + outfits resolved into the ship
  you actually fly.

### Platforms & features

- **[CONTROLS.md](CONTROLS.md)** — gamepad and touch input.
- **[TVOS.md](TVOS.md)** — Apple TV.
- **[ICLOUD_SYNC.md](ICLOUD_SYNC.md)** — syncing imported game data across
  devices.
- **[MULTIPLAYER.md](MULTIPLAYER.md)** — host-authoritative co-op.
- **[GODOT_LAYER.md](GODOT_LAYER.md)** — the parallel Linux/Windows frontend.

### Plans not yet built

- **[MODERNIZATION.md](MODERNIZATION.md)** — opt-in enhancements layered over a
  faithful base.
- **[MOBILE_AND_PLUGINS.md](MOBILE_AND_PLUGINS.md)** — launcher and plug-in
  management design.
- **[EDITOR_AND_PLUGINS_SCOPE.md](EDITOR_AND_PLUGINS_SCOPE.md)** — in-app
  resource and save editing, and the write path it depends on.

### Ground truth

**[reverse-engineering/](reverse-engineering/README.md)** — how the *original*
game's rules work, per resource, reconstructed from the Nova Bible and real
game data. The `.rez` files only hold static data; these docs recover the rules
that act on it.

## Conventions

- **The code is the authority.** Reference docs describe what the code does. When
  they drift, fix the doc.
- **Status lives in one place.** Only [STATUS.md](STATUS.md) says whether
  something is finished. This keeps six documents from disagreeing about the
  same feature.
- **No dates in prose.** Git records when things happened. Docs describe how
  things *are*.
- **Say when something is a guess.** Where the Bible specifies an endpoint but
  not a curve, the interpolation is called out as our reading, not a documented
  rule.
