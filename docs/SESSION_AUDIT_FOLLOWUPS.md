# Outfit / combat systems audit — status & follow-ups

Working document for the branch `claude/outfitter-systems-audit-6pi03w`. It
records what was implemented, what was confirmed against real data, and what is
deliberately left for later. Temporary — move the durable parts into the
per-topic reverse-engineering docs (`docs/reverse-engineering/*`) and delete
this once triaged.

Everything here is grounded in the shipped `Nova Data 1–6.rez` records and the
EV Nova Bible (`Nova Bible.txt`). No behavior was invented; where the Bible
specifies endpoints but not a curve (e.g. interference → sensor range), the
interpolation is called out as an engine reading, not a documented rule.

---

## ⚠️ Build / test caveat — resolved

The original merge landed with real, uncaught build breaks: a duplicate
`PersRes` struct (`MissionModels.swift` vs. `PersModels.swift`) and a duplicate
`pers`/`persons` accessor (`NovaModels.swift` vs. `PersModels.swift`) that only
`swift build` itself could catch — exactly what this section warned about
before merging. Both are fixed (the older, superseded declarations were
removed in favor of the fuller Phase-6 versions), along with a few smaller
knock-on issues (`PersEncounter` referencing `pers.personID` instead of
`pers.id`, an ambiguous-closure-argument compile error in `Spawner.swift`, and
a mis-ordered labeled argument in a test helper call).

**`swift build && swift test` now both pass clean** (283 tests, 0 failures).
Everything below this line was implemented in the follow-up pass and is
covered by new unit tests alongside the existing suite.

---

## What shipped

### Part 1 — Outfitter / modifier / license audit

All grounded in `oütf` Bible fields; see `docs/reverse-engineering/OUTFITTERS.md`
(status table updated).

| Mechanic | Status | Where |
|---|---|---|
| **Map outfit (ModType 16)** — scoped reveal, not whole-galaxy | ✅ | `NovaGame.mapRevealedSystems`, `PlayerState.chartedSystems`, `applyOutfitAcquisition` |
| Clean legal record (ModType 21) | ✅ | `PlayerState.applyOutfitAcquisition` |
| Mass-proportional price (Flags 0x0200) | ✅ | `PilotStore.effectiveCost` |
| Fixed-gun/turret slot enforcement (0x0001/0x0002) | ✅ | `PilotStore.canBuyOutfit` |
| Increase-maximum (ModType 27) | ✅ | `NovaGame.effectiveMaxInstallable` |
| Sell-anywhere tech bypass (0x0800) | ✅ | `NovaEconomy.outfitsSold` |
| OnPurchase / OnSell NCB (@301/@556) | ✅ | `PilotStore.runOutfitScript` |

### Part 2 — Combat / world systems (Phases 1–6)

| Phase | System | Status | Key files |
|---|---|---|---|
| 1 | Boarding capture-odds (crew/marines/strength) | ✅ engine + tested; UI already existed | `World.captureChance`, `ShipLoadout` (marines) |
| 2 | Contraband scanning & fines | ✅ engine/story/app | `Contraband.swift`, `ContrabandScan.swift`, `GameHost` scan wiring |
| 3 | Fighter bays (Guidance 99) | ✅ engine + tested | `World.updateFighterBays`, `FighterBaySpec` |
| 4 | Cloak / cloak-scanner / interference / murk | ✅ engine + app toggle | `World.stepCloak`/`canDetect`/`effectiveSensorRange` |
| 5 | ItemClass loot + escape-pod detection | ✅ engine/app | `PersModels`, `World.takePlunderOutfits`, `Spawner` |
| 6 | Full pêrs: hail quotes, link missions, grudges | ✅ engine/story/app | `PersEncounter.swift`, `World.playerPersGrudges` |

---

## Data offsets confirmed this session (reference)

Verified empirically against the shipped `.rez` records (put these into the
per-resource docs / `NovaAIModels` comments if not already there):

- `gövt.ScanMask` **@50** (`WB16`). Hierarchical faction mask; shares
  `mïsn.ScanMask@24`'s bit-space. Fed `0x8000`, sub-factions inherit it
  (Bureau `0x8008`, Civvies `0x8010`).
- `sÿst.Interference` **@108**, `sÿst.Murk` **@146** (both `0-100`; validated
  across 545 systems — interference max 80, murk max 50).
- `wëap` fighter bay: `Guidance@8 == 99`, `AmmoType@12` = fighter `shïp` id,
  `MaxAmmo@108` = fighters carried (Viper Bay 4, Thunderhead 3), `Reload@0` =
  launch interval.
- `oütf.ItemClass@1004`: stock data uses **only class 25** (one outfit) — the
  loot mechanic is intentionally rare in the base game.
- `përs` (400-byte record): `LinkSyst@0 Govt@2 AIType@4 Aggress@6 Coward@8
  ShipType@10 WeapType[4]@12 WeapCount[4]@20 AmmoLoad[4]@28 Credits@36(i32)
  ShieldMod@40 HailPict@42 CommQuote@44 HailQuote@46 LinkMission@48 Flags@50
  ActiveOn@52(NCB,255) GrantClass@308 GrantProb@310 GrantCount@312`. Confirmed
  against story characters (Terrapin, Jack Folstam, Dr Ralph). Note the on-disk
  order differs from the Bible's narrative order; the weapon arrays are 4-wide.

---

## Follow-ups — resolved this pass

All of section A (except one item genuinely blocked on an unrelated,
unimplemented system) and all of B, C, and E below are now implemented and
covered by new unit tests. Section D was left as-is — see its note.

### A. pêrs system — remaining polish
- ✅ **In-flight LinkMission dialog.** Hailing *or boarding* a named person now
  surfaces the same accept/decline panel the bar uses
  (`GameContainerView.flightMissionServices`/`flightMissionEngine`, backed by
  `AppGameServices`/`MissionSingleDialog`), paused like the hail dialog. On
  accept: `0x0100` deactivate-after reuses the not-yet-defeated spawn gate,
  `0x0800` leave-after sends the ship to `.departing` via
  `GameScene.sendPersonDeparting`. **Deferred:** `0x0040` (replace with a
  mission's SpecialShip) — genuinely blocked on `spawnMissionShips`, which
  `AppGameServices` already logs as "not yet wired" independent of this work;
  implementing it here would mean building that whole system too.
- ✅ **pêrs weapon customization.** `Spawner.applyPersonWeapons` layers
  `WeapType/WeapCount/AmmoLoad[4]` onto the spawned hull, merging into an
  existing mount of the same weapon or adding a new one; negative `WeapCount`
  removes that many stock copies (partial or full). `PersSpawnTests`.
- ✅ **HailPict in the comm dialog.** `HailDialogState.customPictID` (resolved
  from `PersEncounter.hail`'s `hailPictID`) overrides the default ship/planet
  portrait via `SpaceportGraphics.pict(_:)`.
- ✅ **HailQuote attack-context (flag 0x0010).** `GameScene.isEntityAttackingPlayer`
  feeds a new `attacking:` param through to `PersEncounter.hail`, which the
  `ok` gate was previously missing entirely (the flag was decoded but never
  actually consulted). `PersEncounterTests`.
- ✅ **`Aggress`/`Coward` AI tuning.** `AIBrain.personAggression` scales attack
  standoff distance (close/default/far); `personCoward` overrides the fixed
  25% warship-retreat shield threshold. Set by `Spawner` alongside the
  weapon/shield customization. `AIBehaviorTests`. **Deferred:**
  `showsDisasterInfo` (0x8000) — depends on the `öops` price-disaster
  simulation, which is entirely unimplemented (decoded-but-inert per
  `docs/reverse-engineering/ECONOMY.md` §5, predating this audit) — there's no
  disaster info to show yet regardless of this flag.

### B. Sensors / cloak — all resolved
- ✅ **Murk fog rendering.** `World.effectiveMurk(for:)` (systemMurk net of
  `Ship.murkModifier`, capped at 100, *not* floored at 0 per the Bible's
  negative-murk carve-out) drives a camera-parented fog veil
  (`GameScene.buildMurkFog`/`updateMurkFog`); murk `< 0` hides the starfield
  layers outright. `CloakTests`.
- ✅ **Area cloak (0x1000).** `Ship.areaCloakLevel`, recomputed each
  `stepCloak` from formation groupings (escort's `leaderID`, or its own id for
  a leader/lone ship) sharing the strongest area-cloaker's level.
  `effectiveCloakLevel`/`isEffectivelyCloaked` fold this in everywhere
  `isCloaked`/`cloakLevel` used to be read (detection, radar, sprite alpha).
  `CloakTests`.
- ✅ **Cloak scanner radar/screen reveal (0x0001/0x0002).** Radar blips drop a
  cloaked ship unless its own `cloakVisibleOnRadar` or the player's
  `cloakScannerFlags & 0x0001`; `GameScene.syncNPCs` fades sprite alpha by
  `effectiveCloakLevel` unless the player's `cloakScannerFlags & 0x0002`.
- ✅ **Interference on the player's own radar.** The ship-radar normalizer uses
  `world.effectiveSensorRange(radarRange, for: player)` instead of the fixed
  constant, so contacts drop off sooner as static thickens — same curve AI
  perception already used.
- ✅ **`gövt.InhJam1-4` + Seeker jam bits.** `WeaponSpec`/`Projectile` gained
  `turnsAwayIfJammed` (0x0010: a guided shot can lose lock on a target whose
  government's summed `InhJam1-4`, clamped 0-100%, rolls a per-second chance
  in `World.stepProjectiles`) and `confusedByInterference` (0x0008: steering
  turn-rate scales down by the same curve `effectiveSensorRange` uses).
  `CombatTests`.

### C. Boarding / escape pods — all resolved
- ✅ **Escape-pod survival.** There was no player-death handling at all
  (confirmed: no game-over UI, no death handler anywhere). `World` now reports
  `.playerDestroyed(hadEscapePod:)` once when armor hits zero (plus the same
  `.explosion` event an NPC death gets). The app's reaction (confirmed with
  the user): with a pod, rescued at the nearest inhabited port — ship, cargo,
  and every outfit lost, replaced with a stock hull, credits/legal
  record/missions carried over (`GameHost.rescueLandingSpot`/
  `applyEscapePodRescue`); without one, the explosion plays out and then it's
  back to the main menu (nothing autosaved, so the pilot resumes from their
  last landing/takeoff save). `CombatTests`.
- ✅ **NPC cargo holds (`düde.Booty`).** `DudeRes.bootyCommodities` exposes
  which of the 6 commodity types a dude class carries; `Spawner.rollDudeCargo`
  fills 30-80% of the spawned hull's cargo capacity, split across the carried
  types, at spawn time. `DudeCargoTests`.
- ✅ **pêrs boarding LinkMission** (flag 0x0200) — resolved by the same A1
  dialog wiring (`GameContainerView.offerBoardedPersonMission`).

### D. Modifiers still inert (low priority; unchanged — out of scope this pass)
- `densityScanner` (13), `IFF` (14) — radar/HUD rendering only (Bible marks both
  "ignored" mechanically; they're display features).
- `miningScoop` (31), `inertialDamper` (38), `deionize`/`ionCapacity` (39/40),
  `gravityResist` (41), `stellarResist` (42), `paint` (43),
  `reinforcementInhibitor` (44), `bomb`/`nonlethalBomb` (47/50),
  `iffScrambler` (48), `repairSystem` (49) — decoded enum cases, no consuming
  system yet. `hyperspaceDist` (23, no-jump-zone radius) likewise.
- Outfit `Flags 0x1000` (DispWeight-tier suppression) and `0x2000`
  (Ranks-section) — still unimplemented (see OUTFITTERS.md §3.6 / §9).
- Persistent-across-mission-swap outfit flag `0x0020` (distinct from the
  ship-trade `0x0004` which *is* handled).
- `pêrs.Flags` `0x1000`/`0x2000`/`0x4000` (don't offer the LinkMission to a
  wimpy/beefy-freighter/warship-flying player, by `AIType`) — decoded in the
  Bible, not yet read by `PersEncounter.offeredMission`.

### E. Fighter bays — resolved
- ✅ **Player launch/recall control.** `World.playerLaunchFighters()` scrambles
  every docked bay immediately (bypassing the ambient auto-launch's
  combat-gate/cooldown, since an explicit command shouldn't be throttled the
  way passive launches are); `playerRecallFighters()` sets `recallToCarrier` on
  every player fighter regardless of combat state. New `GameAction.launchFighters`
  (`f`)/`.recallFighters` (`g`), routed through `GameContainerView.handleDiscrete`
  → `GameScene.launchPlayerFighters`/`recallPlayerFighters`. A carrier's death
  orphaning its fighters was already handled (`updateFighterBays`); only the
  explicit command was missing.

---

## Testing status

`swift build && swift test`: **283 tests, 0 failures** (1 skipped, pre-existing).

New unit tests (pure logic, no app layer needed — they build synthetic
resources):

- Kit: `OutfitMechanicsTests`, `ContrabandTests`, `SystemFieldTests`,
  `PersTests` (+ full decode).
- Engine: `BoardingTests`, `FighterBayTests`, `CloakTests` (+ area cloak/murk),
  `CombatTests` (+ jam/interference/player-death), `AIBehaviorTests` (+
  Aggress/Coward), `PersSpawnTests` (new — weapon customization),
  `DudeCargoTests` (new — Booty cargo).
- Story: `OutfitAcquisitionTests`, `ContrabandScanTests`, `PersEncounterTests`
  (+ attack-context HailQuote gating).

Not covered by unit tests (need the app/SpriteKit layer, so verify by play):
the scan-fine HUD flow, boarding-loot grant, cloak keybind, hail-quote dialog,
HailPict rendering, the in-flight mission-offer panel, escape-pod rescue
end-to-end (death → menu → reload at the rescue port), murk fog visuals,
launch/recall fighter keybinds, and grudge persistence across jumps. These
weren't build-and-screenshot verified this session either — reason from the
diffs, and check them in the running app before shipping.
