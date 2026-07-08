# Roadmap — faithful full port

**Goal:** reproduce EV Nova as closely as possible on a modern engine for
iOS / iPadOS / macOS — driven entirely by the player's own game data. See the
authoritative **[CHARTER.md](CHARTER.md)** for the full statement, and
**[STATUS.md](STATUS.md)** for the verified wired-vs-built-vs-missing map that
this roadmap is sequenced from.

**Sequencing principle:** per the charter, *a feature that isn't wired does not
exist for the player.* So we prioritize **wiring what's already built** and
**closing stakes gaps** over building new systems. Labels below:
✅ **wired** · 🟡 **built, not wired** · ❌ **missing/shell**.

---

## Foundation — wired ✅

- ✅ **Data layer** (`EVNovaKit`): classic fork / `.ndat` / `BRGR .rez`; plug-in
  override chain; typed decoders (shïp/oütf/wëap/sÿst/spöb/spïn/shän/…); `rlëD`
  + `PICT` decode. Reads the full real game.
- ✅ **Plug-in library**: discover/classify/enable-disable; bundled catalog + import.
- ✅ **Engine** (`EVNovaEngine`): Newtonian flight, combat, projectiles/beams,
  shield/armor damage, NPC spawning from real `düde`/`flët`, AI brains,
  government standings & diplomacy — all driven live via `GameSession.makeWorld`.
- ✅ **App shell + vertical slice**: multiplatform app; authentic main menu; live
  flight/combat; HUD + radar from real state; galaxy map + hyperjump; landing;
  spaceport Trade/Outfit/Shipyard against a persistent JSON pilot.

---

## Now — the wiring pass (highest leverage)

These are the systems that make it *EV Nova the game*. Most of the code exists;
the work is **connecting it to the live loop**.

### P0 — Wire the mission/story runtime 🟡→✅ *(biggest single gap)*
The `EVNovaStory` runtime (`StoryEngine`, `NCBSet`, mission lifecycle, `crön`
events, ranks/salary) is fully built and tested but the app never runs it — only
a read-only guide does. To wire it:
- Implement an **app-side `GameServices` conformer** (the missing plug) that lets
  the engine offer missions, show `dësc` text, spawn special ships, play sound,
  swap hulls. Today only the CLI's `LoggingGameServices` conforms.
- Instantiate `StoryEngine` in the live session (`AppModel`/`GameScene`) and
  advance it on the galaxy clock and on game events (jumps, landings, kills).
- Build the **mission BBS + bar mission UI** in the spaceport (frame asset 8505
  exists) and a real in-game **Mission Log** (replace the "coming soon" alert).
- Persist mission/NCB state through the pilot save (see P2).

### P1 — Close the stakes gaps ❌ *(small, glaring, fast)*
- **Fuel-gated travel**: call the existing `consumeJumpFuel()`; make jumps cost
  real fuel and be impossible without it. Make the "N JUMPS" readout real.
- **Player death / game-over**: handle player destruction the engine already
  defers to the app; add death, consequences, and respawn/reload.
- **Paid repairs**: landing should not free-heal; repair shields/armor for
  credits in the spaceport.
- **Targeting**: target-lock so the player can select and fire on a contact.

### P2 — Pilot management ❌/🟡
- Real **New Pilot** (wire `startNewPilot()` reset+reroll via `PilotFactory`,
  which is built but unused), **multi-pilot** selection, and **Save/Load UI**
  (replace stubs). Decide save format: keep native JSON `PlayerState` or move to
  the built-but-unwired `PilotArchive`/`PilotSave` classic-style path.

### P3 — Authentic UI fidelity pass
- Full rebindable **keybindings** matching EV Nova; mouse used as the original
  does; controller + touch parity. → `docs/CONTROLS.md` *(to be written)*.
- macOS title-bar/safe-area correctness; authentic landing/mission art from the
  player's `PICT`s; remove the orphaned hardcoded-sample story guide UI.

---

## Later — depth & polish

- **Combat/AI depth** (`docs/AI.md`, `docs/SHIP_SYSTEM.md`): hailing/bribing/
  boarding, distress calls & reinforcements, disabling/plundering, `përs` named
  captains (note: `PersRes` is currently parsed but has **zero consumers** —
  wiring it is part of this), ion/heat/cloak sim, `bööm` explosion art,
  per-weapon `snd `.
- **Audio**: `snd ` SFX + music coverage; `STR#`/`dësc` text everywhere.
- **Full options**: every EV Nova setting + difficulty; modern graphics/audio/
  accessibility layered on (opt-in, per charter).
- **Plug-ins & tooling**: load-order/override UI; in-app resource editor
  (Mission Computer / ResForge-class) + pilot editing — requires a new **write
  path** in `EVNovaKit` (serializers + per-type encoders). Scoped in
  `docs/EDITOR_AND_PLUGINS_SCOPE.md`.

---

## Cross-cutting

- Fidelity checks against original behavior; golden-data tests.
- **No hardcoded/mocked data in the play loop** (charter anti-goal) — audit and
  remove any placeholder data that leaks into shipping screens.
- Performance (atlasing, culling); drop to Metal where SpriteKit limits.
- Base game data is always **user-supplied**; only original code + our own art
  ship in the repo.
