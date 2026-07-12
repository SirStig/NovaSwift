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

- ✅ **Data layer** (`NovaSwiftKit`): classic fork / `.ndat` / `BRGR .rez`; plug-in
  override chain; typed decoders (shïp/oütf/wëap/sÿst/spöb/spïn/shän/…); `rlëD`
  + `PICT` decode. Reads the full real game.
- ✅ **Plug-in library + store**: discover/classify/enable-disable; bundled
  catalog + import; in-app `NovaSwiftPluginStore` browse/download/install UI.
- ✅ **Engine** (`NovaSwiftEngine`): Newtonian flight, combat, projectiles/beams,
  shield/armor damage, ionization (charge/dissipate/disable-firing/disable-
  movement), odds-based AI decisions, NPC spawning from real `düde`/`flët`,
  government standings & diplomacy — all driven live via `GameSession.makeWorld`.
- ✅ **App shell + vertical slice**: multiplatform app; authentic main menu;
  live flight/combat with real target-lock; HUD + radar from real state;
  galaxy map + fuel-gated hyperjump; landing; spaceport Trade/Outfit/Shipyard
  (with mission-gated item locking) against a persistent JSON pilot with
  save-history restore.

---

## Where we are now

A lot has come together since the last time this roadmap was written — most of
the "it's built, we just need to hook it up" work is done and playable. Here's
what's live today (see [STATUS.md](STATUS.md) for the wiring details):

- ✅ **Mission/story runtime wired end-to-end** — galaxy-day clock advances on
  landing/gate/hyperjump (`advanceGameDay`), crons/news fire, missions complete
  and pay out (`playerLanded`), mission ships spawn and report
  disable/board/destroy, and `AppGameServices` callbacks
  (`spawnMissionShips`/`changePlayerShip`/`movePlayer`/`setStellarDestroyed`/
  `leaveStellar`/`showNews`) are real, not stubs.
- ✅ **Stakes** — player death + escape-pod/game-over, **paid repairs**, and
  **paid fuel recharge** (landing no longer free-heals). Fuel-gated jumps and
  target-lock were already done.
- ✅ **Economy fidelity** — outfit mass-proportional pricing (`effectiveCost`),
  gun/turret slot limits (`freeGunSlots`/`freeTurretSlots`), and government
  legal-record penalties (`recordKill`/`recordDisable` in the combat loop).
- ✅ **`përs` named captains** and an **in-game Story Map**.

The remaining work, in priority order:

### P0 — AI / spawning / flight fidelity ⚠️ *(the top gap now)*
This is the biggest remaining delta between the port and the original, and it
is **quality-of-reconstruction, not a missing feature**. EV Nova's AI/spawning
was never open-sourced, so ours is rebuilt from data + observed behavior.
- **Spawn cadence/density** (`Spawner.swift`) — the ambient trickle toward
  `sÿst.AvgShips` is a heuristic; tune it toward the original's real arrival
  rhythm and ship mix so traffic stops feeling too sparse/even.
- **Flight smoothness** (`AIBrain.swift`) — kill the wobble/overshoot hiccups
  in the hand-tuned turn/thrust steering; make NPC flight read as natural as
  the original's.
- **Behavior edge cases** — implement the mission `ShipBehav` case that falls
  through to normal AI; tighten engagement/disengagement transitions.
See [`AI.md`](AI.md)'s fidelity-status section for the full list.

### P1 — Demand Tribute / planetary domination ✅ *(done 2026-07-12)*
The engine (complete and tested — `World.demandTribute`, defense waves,
`stellarDominated`, `PlayerState.dominatedStellars`, `payDailyTribute`) is now
driven from the app: the "Demand Tribute" hail button
(`GameContainerView.demandPlanetTribute`) calls
`GameScene.demandTribute` → `World.demandTribute`, the outcome drives the dialog
reply, `stellarDefendersLaunched`/`stellarDominated` events post HUD text, and a
surrender runs `StoryEngine.dominateStellar` (OnDominate + daily tribute). The
demand → waves → surrender → tribute loop is playable end-to-end. See
[reverse-engineering/DOMINATION.md](reverse-engineering/DOMINATION.md).

### P2 — Wire the last built-not-wired backends 🟡
- ✅ **Escort hire/upgrade/sell/release** — *now wired* (Bar `HireEscortView` +
  in-flight `EscortsView` command window → `PilotStore`; recurring daily fees in
  the day-clock). No longer a gap. (ESCORTS.md)
- **Junk / `öops` trading** — `junk()`/`oops()` decode but have no caller and
  no UI. Now **designed**
  ([JUNK_OOPS_DESIGN.md](reverse-engineering/JUNK_OOPS_DESIGN.md)); implement
  öops price disasters first, then junk trading. (ECONOMY.md)
- ✅ **`freightersHaveRandomCargo`** — *now wired*: `Spawner.spawnFleet` rolls
  random standard-commodity cargo into a fleet's freighters (InherentAI ≤ 2) via
  `rollRandomFreighterCargo`. (FLEETS.md)
- ✅ **Rank-gated purchases** — *now wired*: `ItemLocking.contributedBits` folds
  active-rank **and** active-crön `Contribute` into the spaceport purchase gate
  (mirrors `StoryEngine.activeContributeBits`).
- ✅ **In-game Mission Log** — *now wired*: `MissionInfoView` shows a live
  per-mission objective line (ship-kill progress + the active travel/return leg)
  from a new `MissionSummary.objective`.

### P3 — Pilot management 🟡 *(mostly done)*
- ✅ **New Pilot + multi-pilot roster** — *now wired*: `NewPilotView` →
  `AppModel.createPilot` → `PilotRoster.create`, plus an "Open Pilot" picker and
  `enterShip()` resuming the selected save. ✅ Cleanup done: the orphaned
  `AppModel.startNewPilot()` (superseded, zero callers) was deleted.
- Decide save format: keep native JSON `PlayerState` (current) or move to the
  built-but-unwired `PilotSave`/`CombatRating` classic-style encode path.

### P4 — Authentic UI fidelity pass
- Full rebindable **keybindings** matching EV Nova; mouse used as the original
  does; controller + touch parity. → `docs/CONTROLS.md` *(to be written)*.
- ✅ **Ionization HUD indicator** — *now wired*: the flight HUD status panel
  shows a purple ION bar (labelled "IONIZED" at the threshold) driven from
  `Ship.ionCharge`/`isIonized` via `GameScene.updateHUD`.
- macOS title-bar/safe-area correctness; authentic landing/mission art from the
  player's `PICT`s.

---

## Later — depth & polish

- **Combat/AI depth** (`docs/AI.md`, `docs/SHIP_SYSTEM.md`): deeper
  hailing/bribing/boarding, distress calls & reinforcements, plundering,
  guided-weapon lock-tone/lock-loss nuance, `bööm` explosion art, per-weapon
  `snd `. (`përs` named captains — hail quotes, link-missions, grudges — are
  now wired; remaining `përs` depth is the bribe/board nuance above.)
- **Audio**: `snd ` SFX + music coverage; `STR#`/`dësc` text everywhere.
- **Full options**: every EV Nova setting + difficulty; modern graphics/audio/
  accessibility layered on (opt-in, per charter).
- **Plug-in tooling**: load-order/override UI polish; in-app resource editor
  (Mission Computer / ResForge-class) + pilot editing — requires a new **write
  path** in `NovaSwiftKit` (serializers + per-type encoders). Scoped in
  `docs/EDITOR_AND_PLUGINS_SCOPE.md`.

---

## Cross-cutting

- Fidelity checks against original behavior; golden-data tests.
- **No hardcoded/mocked data in the play loop** (charter anti-goal) — audit and
  remove any placeholder data that leaks into shipping screens (the Mission
  BBS placeholder and the orphaned story-guide sample data are the current
  known offenders).
- Performance (atlasing, culling); drop to Metal where SpriteKit limits.
- Base game data is always **user-supplied**; only original code + our own art
  ship in the repo.
