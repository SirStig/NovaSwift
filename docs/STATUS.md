# Status — the built-vs-wired connection map

> **Source of truth for what actually works.** Verified by tracing the running
> app (`app/NovaSwift/`) into the libraries (`Sources/`), not by reading library
> code in isolation. Definitions come from [`CHARTER.md`](CHARTER.md):
>
> - **Wired** — the running app drives it; the player experiences it.
> - **Built, not wired** — code exists and is tested, but the app never calls it
>   in the play loop. The player does **not** experience it.
> - **Missing** — not built, or a UI shell / "coming soon" placeholder only.
>
> Last verified: 2026-07-12 (audit of `main` tracing app call sites into the
> engine/story libraries). This pass folds in the large mission/story,
> mission-ship, stakes, and economy wiring that landed since the 2026-07-09
> audit — most of what earlier revisions of this doc listed as "built, not
> wired" is now **wired**.

## The headline

> **2026-07-12 — story/mission system wired end-to-end.** The gaps earlier
> revisions of this document described are largely CLOSED. The app builds and
> tests pass (0 assertion failures). Now live:
> **missions complete** — `GameContainerView.handleStoryLanding` calls
> `engine.playerLanded` on every dock, so cargo/courier/passenger/delivery
> missions finish, pay out, and show completion text (`playerLanded` previously
> had zero call sites); **mission-ship combat loop closed** — active missions'
> `ShipSyst`-matching special ships spawn into the live `World`
> (`spawnActiveMissionShips` from `syncNav` → `GameScene.spawnMissionShips`) and
> the `.missionShipGoalReached` WorldEvent (formerly `default:break`) feeds
> `engine.missionShipDestroyed/Disabled/Boarded` back via a new
> `GameScene.onMissionShipGoalReached` closure; **the campaign clock advances**
> and `advanceGameDay` now routes crön effects/news through the flight services;
> **`AppGameServices` effects are real** (container-set callbacks for
> ship-swap/move/leave-stellar/spawn/destroy-stellar; `storyText`/`showNews` now
> render as a `NovaDialog`); **galaxy-mutation layer added** — decoded
> `sÿst.Visibility`@150 + `spöb.OnDestroy`@582/`OnRegen`@837, engine fires spöb
> hooks on Y/U and persists `destroyedStellars`, `GalaxyMapView` hides
> story-invisible systems, destroyed stellars drop out of flight/landing;
> **engine reward fidelity fixed** — PayVal all 5 ranges (was a raw
> `credits += pay` bug), CompReward −½-on-fail/−5×-on-abort, C/E/H outfit
> semantics, cargo ±50%/type-1000 random, crön iterative flags. A same-session
> follow-up also closed the `ShipSyst` −1/−2/−5 selectors
> (`ActiveMission.acceptSystemID` + `missionShipSystemMatches`) and made
> in-flight ship swap rebuild the flight host in place (`rebuildFlightHost`).
> Remaining low-value polish: destroyed planets show as absent (no
> wreck/asteroid variant yet), and news has no per-station local/independent
> precedence.

**Beyond the story wiring above,** the same span also added the *stakes* and
*economy* pieces that the older tables listed as missing: the player can now
**die** (escape-pod rescue or game-over), **repairs and fuel recharge cost
credits**, **outfit mass-proportional pricing** and **gun/turret slot limits**
are enforced, **government legal-record penalties** accrue in combat, and the
`përs` named-captain system and an **in-game Story Map** are live. The tables
below reflect this current state and supersede all earlier revisions.

## Biggest gap vs. the original game: AI / spawning / flight fidelity ⚠️

EV Nova's AI and spawning logic were **never open-sourced.** Everything in
`AIBrain.swift`, `Spawner.swift`, and the flight/steering code is a
**reconstruction from the game's data tables and observed behavior**, not a
port of original logic — there is no source to copy off. It is close and covers
the documented Bible behavior (see [`AI.md`](AI.md) and
[`AI_GROUND_TRUTH.md`](AI_GROUND_TRUTH.md)), but three areas are the known weak
points where it still doesn't *feel* exactly like the original:

| Area | What's off | Where |
|---|---|---|
| **Spawn cadence / density** | Ambient population is a trickle heuristic (`spawnInterval` toward `sÿst.AvgShips`) "in the same spirit as" the original, not its exact algorithm. Traffic can feel slightly too sparse or too even — it doesn't reproduce the original's exact arrival rhythm and mix. | `Spawner.swift` ambient/fleet cadence |
| **Flight handling** | Hand-tuned turn/thrust heuristics ("thrust when roughly pointed the right way", turn-limit lifts through hard turns, escort heading-hold hacks) produce occasional wobble/overshoot "hiccups" a from-source AI wouldn't. | `AIBrain.swift` steering primitives |
| **Combat/behavior edge cases** | One mission `ShipBehav` case falls through to normal AI; brainless ships drift; some engagement transitions approximate undocumented timing. | `AIBrain.swift`, `World.swift` |

Treat this as the top fidelity backlog: **most core gameplay is replicated
well; AI/spawning/flight naturalness is where the port is still visibly a
reconstruction.** Everything else in this doc is comparatively close to the
original.

## Wired ✅ (the player experiences this today)

| System | How it's wired | Key seam |
|---|---|---|
| **Flight sim** | `GameScene.update` drives `World.step` on the player's real hull+outfit stats | `GameScene.swift`, `World.swift` |
| **NPC spawning + AI + combat** | `GameSession.makeWorld` wires Galaxy → Diplomacy → Spawner → AIBrain → Combat; NPCs spawn from real `düde`/`flët`, fight, take real damage (fidelity caveats above) | `GameSession.swift`, `Spawner.swift`, `AIBrain.swift` |
| **Mission/story day-clock + crons** | `StoryEngine.advanceDays()` (runs `evaluateCrons()`, `payDailySalaries`, `payDailyTribute`) is called from `advanceGameDay()` on landing, gate/hypergate transit, and every hyperjump; crön effects/news route through the flight services; state persists via `model.pilot.state` | `GameContainerView.swift` `advanceGameDay()`; `StoryEngine.swift` |
| **Mission offer / accept / decline / complete** | `MissionBoardView` runs a real `StoryEngine` (via `AppGameServices`, a real `GameServices` conformer); `handleStoryLanding` calls `engine.playerLanded` on every dock so delivery/courier/passenger/cargo missions finish, pay out (all 5 PayVal ranges), and show completion text | `Story/MissionBoardView.swift`, `Story/AppGameServices.swift`, `GameContainerView.swift` |
| **Mission ships + `ShipBehav`** | `AppGameServices.spawnMissionShips` → `World.spawnMissionShips`; active missions' `ShipSyst`-matching ships spawn into the live world (including the −1/−2/−5 selectors), obey `AIBrain.behaviorOverride`, and emit goal-reached (`missionShipDisabled/Boarded/Destroyed`) back to the engine with an autosave | `GameScene.spawnMissionShips`, `GameContainerView.swift` (`spawnActiveMissionShips`, `missionShipSystemMatches`), `World.swift` |
| **Story side-effects** | `changePlayerShip` (hull swap, rebuilt in place via `rebuildFlightHost`), `movePlayer`, `setStellarDestroyed`, `leaveStellar` (takeoff) are real container-set callbacks; `showStoryText`/`showNews` render as a `NovaDialog` | `Story/AppGameServices.swift`, `GameContainerView.swift` — *caveat: news has no local/independent precedence yet; destroyed planets render as absent* |
| **Galaxy mutation** | Decoded `sÿst.Visibility` + `spöb.OnDestroy`/`OnRegen`; the engine fires spöb hooks on Y/U ops and persists `destroyedStellars`; `GalaxyMapView` hides story-invisible systems and destroyed stellars drop out of flight/landing | `GalaxyMapView.swift`, engine spöb-hook path — *caveat: destroyed planets show as absent, no wreck/asteroid variant yet* |
| **Player death / game-over** | `Ship.isAlive` uses `armor <= 0`; player death emits `.playerDestroyed(hadEscapePod:)` → escape-pod rescue at nearest port (+save) or a 2.2s explosion → main menu (resume from last autosave) | `World.swift`, `GameScene.swift` `onPlayerDestroyed`, `GameContainerView.swift` `applyEscapePodRescue` |
| **Paid repairs** | `repairOnLanding` bills ~2cr/hull point (partial repair if underfunded), free only when `repairIsFree` (govt/rank comp) — no more free full heal | `GameContainerView.swift` `repairOnLanding` |
| **Paid fuel recharge** | Jumps never refuel and landing does not top off fuel; refuel is the paid spaceport "Recharge" service (`rechargeShip`/`rechargeCost`), free only via `rechargeIsFree` | `SpaceportView.swift` `rechargeShip()` |
| **Ionization** | Weapon `wëap.Ionization` charges `Ship.ionCharge`; past `IonizeMax` the ship can't move or fire | `World.swift` — real physics, **still no HUD indicator** for the player's own charge |
| **Combat odds / armor-disable AI** | `AIBrain.power(_:)` drives odds-based flee/press; disabled-hulk transition on armor loss (NPC-only; the player-death path above owns the player) | `AIBrain.swift`, `World.swift` |
| **Government legal-record penalties** | `Diplomacy.recordKill`/`.recordDisable` are called from `World.swift`'s combat-resolution disable/kill transitions, applying real `KillPenalty`/`DisabPenalty`; combat rating accrues in real play | `World.swift`, `Diplomacy.swift` |
| **Target-lock + HUD + radar** | Real `selectNearestTarget`/`cycleTarget` with HUD brackets; live ship state, real planet/NPC blips with hostility color; authentic status bar from `ïntf` | `GameScene.swift`, `AuthenticHUDView.swift` |
| **Galaxy map + fuel-gated jumps** | Real `sÿst` coords/links, BFS course plotting; `jumpAlongRoute()` calls `consumeJumpFuel()` gated by `canAfford(hops:)` | `NavigationModel.swift`, `GameContainerView.swift` |
| **Spaceport economy** | Trade / Outfitter / Shipyard use real prices against a persistent credit/cargo/outfit balance; mission-gated items genuinely locked; **outfit mass-proportional pricing** (`effectiveCost`) and **gun/turret slot limits** (`freeGunSlots`/`freeTurretSlots`) enforced on buy/sell; can't-sell/consumed-on-purchase flags honored | `SpaceportScreens.swift`, `PilotStore.swift`, `ItemLocking.swift`, `ShipLoadout.swift` |
| **Fleet spawn-eligibility + reinforcements** | `Spawner.isFleetEligible` filters ambient fleets by `flët.LinkSyst` bands; `Spawner.updateReinforcements` summons `sÿst.ReinfFleet` when a govt's ships are outmatched (`gövt.MaxOdds`) | `Spawner.swift` |
| **`përs` named captains** | The `përs` system places named NPCs with hail quotes, link-missions, and grudges into the live world | `World.swift`, `GameScene.swift`, `GameContainerView.swift` |
| **In-game Story Map** | The in-game menu opens a live, pannable/zoomable graph of every reconstructed campaign, resolved against the current pilot — an addition the original never had | `Game/GameMenuView.swift` ("Story Map"), `Story/StorylineMapView.swift`, `StorylineBrowserView.swift` |
| **Plug-in store** | In-app catalog browse + download/install via `NovaSwiftPluginStore` | `Launcher/PluginsView.swift` → `Store/PluginStoreView.swift` |
| **Pilot save history** | `PilotArchive` backups + `PilotRoster` history; "Load Earlier Save" restores a prior snapshot | `PilotListView.swift` |
| **Main menu + data layer** | Authentic PICT/rlëD assets; full resource-fork/`.ndat`/`.rez` parsing, plug-in override chain, typed decoders, sprite decode | `AuthenticMainMenuView.swift`, `NovaSwiftKit` |

## Built, not wired 🟡 (exists + tested, but the app never runs it)

Much shorter than the previous audit — most of it got wired. What remains:

| System | What's built | Why the player never sees it |
|---|---|---|
| **Demand Tribute / planetary domination — app trigger** | The whole engine is done and tested: `World.demandTribute` (combat-rating gate, `DefenseDude` waves via `updateStellarDefenses`, `stellarDominated` event), `spöb` Tribute/DefenseDude/DefCount decode, `PlayerState.dominatedStellars` persistence, and `StoryEngine.payDailyTribute()` (auto daily income in `advanceDays`). Covered by `DominationTests` + a headless proof (`novaswift-extract tribute`). See [reverse-engineering/DOMINATION.md](reverse-engineering/DOMINATION.md). | **The only missing piece is the app-side trigger.** The in-game "Demand Tribute" button (`GameContainerView.demandPlanetTribute`) is a **cosmetic stub** — it sets the world hostile and posts a refusal line, but never calls `World.demandTribute`, spawns no defenders, dominates nothing, pays no tribute. Wiring that one call (plus HUD text for the tribute events and `StoryEngine.dominateStellar` on conquest) makes the built engine live. **In progress.** |
| **Escort hire / upgrade / sell** | `PilotStore.hireEscort`/`.upgradeEscort`/`.sellEscort`/`.escortAvailableToday` (decoded `ShipRes` fields + tested transaction logic) | The Bar's "Hire Escort" button (`SpaceportScreens.swift`) is rendered `enabled: false` with an empty action — no data binding to `PilotStore`. See [reverse-engineering/ESCORTS.md](reverse-engineering/ESCORTS.md). |
| **Junk cargo & `öops` price disasters** | `JunkModels.swift` (`JunkRes`) / `OopsModels.swift` (`OopsRes`) decode correctly | No app caller of `junk()`/`junks()`/`oops()`/`oopses()` — no junk-trade UI, no price-disaster daily roll. Both features are still undesigned, not just unwired. See [reverse-engineering/ECONOMY.md](reverse-engineering/ECONOMY.md). |
| **Fleet flavor fields** | `FleetRes.appearOn`/`.freightersHaveRandomCargo` (decoded) | No call site gates ambient fleets on `appearOn`'s NCB test, and there's no random-freighter-cargo boarding hook. (`hailQuote` *is* used via the `përs` path.) See [reverse-engineering/FLEETS.md](reverse-engineering/FLEETS.md). |
| **Rank-gated purchases (`ränk.Contribute`)** | `RankRes.contribute` is decoded; `StoryEngine.activeContributeBits()` folds active-rank `Contribute` into *mission/cron* availability | The spaceport purchase gate (`ItemLocking.contributedBits`) folds in only *ship* + *outfit* `contribute`, not active-rank `Contribute` — so a purchase gated on a rank the pilot holds still isn't unlocked in the shop, though the Bible calls this out as the headline use. |
| **Classic pilot save format** | `PilotSave`, `CombatRating` classic-archive encode | The app persists `PlayerState` as native JSON instead; the classic-archive *encode* path is unused (backup/restore mechanics are used). |
| **Pilot creation** | `PilotFactory` builds a pilot from a `chär` scenario | Used by CLI + tests; `AppModel.startNewPilot()` exists but has zero app call sites. |

## Missing / shells ❌ (not built, or placeholder only)

| Gap | Detail |
|---|---|
| **AI / spawning / flight fidelity** | The biggest quality gap, not a missing feature — see the ⚠️ section above. Reconstructed-from-data, so spawn cadence, flight smoothness, and some behavior transitions don't yet match the original exactly. |
| **New Pilot / multi-pilot UI** | `startNewPilot()` (reset+reroll) is still never called; save history/restore works, but there's no multi-pilot selection UI — the main-menu save buttons resume one save. |
| **In-game Mission Log** | The Story Map covers campaign overview, but a per-mission active-objective log panel isn't a dedicated screen yet. |
| **Ionization HUD indicator** | The ion physics is live but nothing on screen shows the player their own charge building toward immobilization. |
| **Junk-trade / öops UI** | See built-not-wired — the decoders exist but the features are undesigned. |

## Priority implication

Per [`CHARTER.md`](CHARTER.md), **a feature that isn't wired does not exist for
the player.** With the mission/story runtime, mission ships, stakes, and
economy now wired, the highest-leverage work has shifted:

1. **AI / spawning / flight fidelity** — the top remaining gap between this
   port and the original. Tighten `Spawner` cadence toward the real arrival
   rhythm and smooth `AIBrain` steering to kill the flight hiccups. This is
   quality-of-reconstruction work, not new features. See [`AI.md`](AI.md).
2. **Finish Demand Tribute / domination** — replace the cosmetic
   `demandPlanetTribute` stub with a real `World.demandTribute` call + event
   HUD text + `StoryEngine.dominateStellar` on conquest. The engine is done;
   this is the last app hookup. **In progress.**
3. **Wire the last economy/escort backends** — bind escort hire/upgrade/sell
   into a real Bar panel; design + wire junk/`öops` trading.
4. **Pilot management** — real New Pilot reset and a multi-pilot selection UI.

See [`ROADMAP.md`](ROADMAP.md) for the sequenced plan.
