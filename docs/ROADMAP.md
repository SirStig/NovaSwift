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
- ✅ **Plug-in library + store**: discover/classify/enable-disable; bundled
  catalog + import; in-app `EVNovaPluginStore` browse/download/install UI.
- ✅ **Engine** (`EVNovaEngine`): Newtonian flight, combat, projectiles/beams,
  shield/armor damage, ionization (charge/dissipate/disable-firing/disable-
  movement), odds-based AI decisions, NPC spawning from real `düde`/`flët`,
  government standings & diplomacy — all driven live via `GameSession.makeWorld`.
- ✅ **App shell + vertical slice**: multiplatform app; authentic main menu;
  live flight/combat with real target-lock; HUD + radar from real state;
  galaxy map + fuel-gated hyperjump; landing; spaceport Trade/Outfit/Shipyard
  (with mission-gated item locking) against a persistent JSON pilot with
  save-history restore.

---

## Now — the wiring pass (highest leverage)

These are the systems that make it *EV Nova the game*. Most of the code exists;
the work is **connecting it to the live loop**.

### P0 — Wire the mission/story runtime 🟡→✅ *(narrower now — mission offer/accept/decline is done)*
**Update:** `app/EVNova/Story/AppGameServices.swift` (a real `GameServices`
conformer) and a real `StoryEngine` instance (instantiated per-landing in
`MissionBoardView.swift`, embedded in both the Mission BBS and Bar screens)
now make mission offer/accept/decline genuinely live, persisting to the pilot
save. What's left:
- **Wire the galaxy-day clock**: nothing in `app/` calls
  `StoryEngine.advanceOneDay()`/`.advanceDays()`/`.evaluateCrons()`, so the
  day never advances during play and `crön` events (news, dated story beats)
  never fire regardless of how many missions get taken. Call these from the
  live session on jumps/landings/time-passing events, same as the CLI already
  does.
- **Flesh out `AppGameServices`'s remaining stub methods** — `spawnMissionShips`,
  `changePlayerShip`, `movePlayer`, `setStellarDestroyed`, and `leaveStellar`
  currently only log and no-op; `showNews` logs instead of surfacing a news
  dialog. `presentMissionOffer`/`showStoryText`/`playSound` are already wired.
- Build a real in-game **Mission Log** (replace the "coming soon" alert in
  `GameMenuView`).

### P1 — Close the remaining stakes gaps ❌ *(narrower now — fuel and targeting are done)*
- **Player death / game-over**: nothing checks the player's armor reaching
  zero (the NPC disable path is explicitly gated `!ship.isPlayer`); add death,
  consequences, and respawn/reload.
- **Paid repairs**: landing/rebuild still resets shields/armor/fuel to full
  for free; charge credits for repair in the spaceport instead. (Uncommitted,
  separate WIP is adding an in-flight paid *ally-assistance* fuel/repair
  transfer — a nice-to-have on top of, not a substitute for, spaceport repair
  economics.)
- ~~Fuel-gated travel~~ — done: `consumeJumpFuel()` is now called from
  `NavigationModel.jumpAlongRoute()`, gated on the ship's real tank.
- ~~Targeting~~ — done: real target-lock (`selectNearestTarget`/
  `cycleTarget`) with HUD brackets is wired and live.

### P2 — Pilot management 🟡 *(save/restore now works; creation flow still doesn't)*
- Real **New Pilot**: wire `startNewPilot()` reset+reroll via `PilotFactory`,
  which is built but still has zero call sites.
- **Multi-pilot selection UI**: save-history restore (`PilotArchive` backups
  via "Load Earlier Save") now works, but there's still no way to manage more
  than one active pilot slot from the main menu.
- Decide save format: keep native JSON `PlayerState` or move to the built-but-
  unwired `PilotSave`/`CombatRating` classic-style encode path.

### P3 — Finish wiring this pass's new decoder/behavior code 🟡→✅ *(new)*
A same-day implementation pass added real, tested Swift for several
`docs/reverse-engineering/*.md`-documented gaps (new `GovtRes`/`FleetRes`/
`OutfRes`/`SystRes`/`ShipRes`/`CronRes`/`RankRes`/`MissionRes` fields, new
`JunkRes`/`OopsRes` models), but per those docs' own "Implementation status"
notes, most of it has no live caller yet. Concrete, scoped wiring tasks:
- **Call `Diplomacy.recordKill`/`.recordDisable`/`.recordBoard`/
  `.recordSmuggling`** from `World.swift`'s combat-resolution code (its
  `.shipDisabled`/`.shipDestroyed` transitions and per-hit path), replacing
  the current dead-field `gov.shootPenalty` docking. (GOVERNMENT.md)
- **Fold `RankRes.contribute` into `ItemLocking.contributedBits`**
  (`app/EVNova/Spaceport/ItemLocking.swift`) the same way
  `StoryEngine.activeContributeBits()` already does, so a rank-gated
  *purchase* — the Bible's own headline example for `Contribute`/`Require` —
  works in the spaceport UI, not just mission/cron availability. (GOVERNMENT.md)
- **Wire `PilotStore`'s escort hire/upgrade/sell functions
  (`hireEscort`/`upgradeEscort`/`sellEscort`/`escortAvailableToday`) to a new
  UI** — bind them into `EscortsView.swift`, which is currently a fully
  authentic but fully static/disabled panel with zero data binding.
  (ESCORTS.md)
- **Have `PilotStore.buyOutfit`/`sellOutfit` call `OutfRes.effectiveCost`**
  instead of the flat `Cost`, so `Flags 0x0200` (mass-proportional price)
  outfits charge/refund correctly. (OUTFITTERS.md)
- **Consult `Loadout`'s `freeGunSlots`/`freeTurretSlots` in
  `PilotStore.canBuyOutfit`**, so the shop stops allowing more gun/turret
  outfits than the hull has mounts for. (OUTFITTERS.md)
- **Call `junk()`/`junks()`/`oops()`/`oopses()` from somewhere** — a junk-trade
  UI (a `jünk`-driven sibling of the Trade Center) and an `öops` price-disaster
  daily roll are both fully undesigned today, not just unwired; scope a
  feature before wiring one. (ECONOMY.md)
- **Read `FleetRes.appearOn`/`.hailQuote`/`.freightersHaveRandomCargo`
  somewhere** — gate ambient fleet spawns on `appearOn`'s NCB test (mirroring
  how `Spawner.isFleetEligible` already reads `LinkSyst`), surface
  `hailQuote` as arrival flavor text, and hook `freightersHaveRandomCargo`
  into a boarding mechanic once one exists. (FLEETS.md)

### P4 — Authentic UI fidelity pass
- Full rebindable **keybindings** matching EV Nova; mouse used as the original
  does; controller + touch parity. → `docs/CONTROLS.md` *(to be written)*.
- **Ionization HUD indicator** — the physics is live (`Ship.ionCharge`/
  `isIonized`) but nothing on screen shows the player their own charge state.
- macOS title-bar/safe-area correctness; authentic landing/mission art from the
  player's `PICT`s; remove the orphaned hardcoded-sample story guide UI.

---

## Later — depth & polish

- **Combat/AI depth** (`docs/AI.md`, `docs/SHIP_SYSTEM.md`): hailing/bribing/
  boarding, distress calls & reinforcements, plundering, `përs` named
  captains (note: `PersRes` is currently parsed but has **zero consumers** —
  wiring it is part of this), guided-weapon lock-tone/lock-loss nuance,
  `bööm` explosion art, per-weapon `snd `.
- **Audio**: `snd ` SFX + music coverage; `STR#`/`dësc` text everywhere.
- **Full options**: every EV Nova setting + difficulty; modern graphics/audio/
  accessibility layered on (opt-in, per charter).
- **Plug-in tooling**: load-order/override UI polish; in-app resource editor
  (Mission Computer / ResForge-class) + pilot editing — requires a new **write
  path** in `EVNovaKit` (serializers + per-type encoders). Scoped in
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
