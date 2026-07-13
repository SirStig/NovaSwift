# Status — what actually works right now

This is the honest map of where NovaSwift stands: what a player really
experiences, what's written but not yet plugged in, and what's still missing. We
keep it honest by following the code — from the running app (`app/NovaSwift/`)
into the libraries (`Sources/`) — rather than trusting that a system works just
because the library compiles. The three words we use, straight from
[`CHARTER.md`](CHARTER.md):

- **Wired** — the app actually drives it. The player feels it in the game.
- **Built, not wired** — the code is there and tested, but nothing in the play
  loop calls it. As far as the player is concerned, it isn't in the game.
- **Missing** — not built, or just a UI shell / "coming soon" placeholder.

*Last walked through: 2026-07-12.*

## Where things stand

The short version: **the game is a lot more complete than it used to be.** Most
of what older versions of this doc filed under "built but not wired" is now
genuinely wired, and the app builds and tests green.

The big one is the **story and mission system, which now runs end to end.** You
can pick up a mission at the bar, fly it, and finish it — cargo, courier,
passenger, delivery, bounty, escort, all of it. Mission ships actually spawn
into the world around you, and when you destroy, disable, or board them the
campaign notices and moves on. The galaxy clock ticks forward every time you
land or jump, so daily events and news fire on schedule. The universe can even
change out from under you — systems appear and vanish, planets get destroyed —
the way the original's storylines rewrite the map.

On top of that, the game finally has **stakes and a real economy.** You can
*die* now (escape pod if you've got one, otherwise game over), repairs and fuel
both cost credits, outfits are priced by mass and limited by your ship's gun and
turret slots, and shooting up the wrong government dings your record. Named
captains from the `përs` table roam the galaxy, and there's an in-game Story Map
the original never had.

And most recently, a batch of quality-of-life systems came online: **hiring and
managing escorts, gambling on the races at the bar, and creating and juggling
multiple pilots** all work now. The tables below reflect all of this.

## The one thing that still feels off: how ships fly and spawn

Here's the catch. EV Nova's AI and spawning logic were **never open-sourced**,
so unlike the rest of the port there was no original code to work from. The
steering, the combat decisions, the way traffic fills a system — all of it
(`AIBrain.swift`, `Spawner.swift`, the flight code) is **rebuilt from the game's
data tables and hours of watching how the original behaves.** It's close, and it
covers what the Bible documents (see [`AI.md`](AI.md) and
[`AI_GROUND_TRUTH.md`](AI_GROUND_TRUTH.md)) — but three spots still don't quite
*feel* like the real thing:

| Area | What's off | Where |
|---|---|---|
| **Spawn cadence / density** | Ambient population is a trickle heuristic (`spawnInterval` toward `sÿst.AvgShips`) "in the same spirit as" the original, not its exact algorithm. Single ships are now the maintained backbone and fleets a capped, varied accent (`maxConcurrentFleets`, single-only fill target) — fixing "all fleets, barely any lone ships" — but the exact arrival rhythm/mix is still hand-tuned. | `Spawner.swift` ambient/fleet cadence |
| **Flight handling** | AI ships now fly the **driftless (inertialess) model** by default (`FlightTuning.aiInertialess = .all`), reproducing EV Nova's precise NPC flight and removing the momentum overshoot, wrong-direction turn drift, and constant escort micro-correction. Residual hand-tuned heuristics remain but the biggest wobble source is gone. | `AIBrain.swift` steering, `Ship.fliesInertialess`, `FlightTuning` |
| **Combat/behavior edge cases** | One mission `ShipBehav` case falls through to normal AI; brainless ships drift; some engagement transitions approximate undocumented timing. | `AIBrain.swift`, `World.swift` |

This is the honest soft spot. **Most of the game plays close to the original;
the way ships fly and show up is where you can still tell it's a
reconstruction** — because for that one piece, there was nothing to copy from.
Everything else in this doc holds up well by comparison.

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
| **Ionization** | Weapon `wëap.Ionization` charges `Ship.ionCharge`; past `IonizeMax` the ship can't move or fire; the flight HUD status panel shows a purple ION bar (labelled "IONIZED" at the threshold) whenever the player carries a charge | `World.swift` (physics), `GameHUD.swift` / `GameScene.updateHUD` (indicator) |
| **Demand Tribute / planetary domination** | The "Demand Tribute" hail-dialog button calls `GameScene.demandTribute` → `World.demandTribute` (combat-rating gate, `DefenseDude` waves, `stellarDominated` event); each wave posts a HUD line and a surrender runs `StoryEngine.dominateStellar` (fires `OnDominate`, persists `dominatedStellars`, starts daily `payDailyTribute` income). Full demand → waves → surrender → tribute loop is playable | `GameContainerView.swift` (`demandPlanetTribute`, `handleStellarDominated`), `GameScene.swift`, `Domination.swift` — see [reverse-engineering/DOMINATION.md](reverse-engineering/DOMINATION.md) |
| **Rank-gated purchases (`ränk.Contribute`)** | `ItemLocking.contributedBits` folds ship + outfit **and** active-rank + active-crön `Contribute` (mirroring `StoryEngine.activeContributeBits`), so a purchase gated on a rank the pilot holds unlocks in the shipyard/outfitter — the Bible's headline use | `Spaceport/ItemLocking.swift` |
| **Freighter random cargo (`flët.Flags` 0x0001)** | `Spawner.spawnFleet` rolls random standard-commodity cargo into a fleet's freighters (InherentAI ≤ 2), so boarding a convoy hauler yields loot | `Spawner.swift` (`rollRandomFreighterCargo`) |
| **Combat odds / armor-disable AI** | `AIBrain.power(_:)` drives odds-based flee/press; disabled-hulk transition on armor loss (NPC-only; the player-death path above owns the player) | `AIBrain.swift`, `World.swift` |
| **Government legal-record penalties** | `Diplomacy.recordKill`/`.recordDisable` are called from `World.swift`'s combat-resolution disable/kill transitions, applying real `KillPenalty`/`DisabPenalty`; combat rating accrues in real play | `World.swift`, `Diplomacy.swift` |
| **Target-lock + HUD + radar** | Real `selectNearestTarget`/`cycleTarget` with HUD brackets; live ship state, real planet/NPC blips with hostility color; authentic status bar from `ïntf` | `GameScene.swift`, `AuthenticHUDView.swift` |
| **Galaxy map + fuel-gated jumps** | Real `sÿst` coords/links, BFS course plotting; `jumpAlongRoute()` calls `consumeJumpFuel()` gated by `canAfford(hops:)` | `NavigationModel.swift`, `GameContainerView.swift` |
| **Spaceport economy** | Trade / Outfitter / Shipyard use real prices against a persistent credit/cargo/outfit balance; mission-gated items genuinely locked; **outfit mass-proportional pricing** (`effectiveCost`) and **gun/turret slot limits** (`freeGunSlots`/`freeTurretSlots`) enforced on buy/sell; can't-sell/consumed-on-purchase flags honored | `SpaceportScreens.swift`, `PilotStore.swift`, `ItemLocking.swift`, `ShipLoadout.swift` |
| **Fleet spawn-eligibility + reinforcements** | `Spawner.isFleetEligible` filters ambient fleets by `flët.LinkSyst` bands; `Spawner.updateReinforcements` summons `sÿst.ReinfFleet` when a govt's ships are outmatched (`gövt.MaxOdds`) | `Spawner.swift` |
| **`përs` named captains** | The `përs` system places named NPCs with hail quotes, link-missions, and grudges into the live world | `World.swift`, `GameScene.swift`, `GameContainerView.swift` |
| **Escort hire / upgrade / sell / release** | The Bar's "Hire Escort" button opens `HireEscortView` → `PilotStore.hireEscort` (charges the up-front fee, registers a `.hired` ship in the persistent `escortWing`); upgrade/sell/release are the in-flight `EscortsView` command window → `PilotStore.upgradeEscort`/`sellEscort` + `releaseEscort`; recurring daily fees are billed by `StoryEngine.payDailyEscortFees` in the day-clock, surfaced via the `escortDailyFeeCharged` HUD notice | `Spaceport/HireEscortView.swift`, `Game/EscortsView.swift`, `Game/PilotStore.swift`, `Story/StoryEngine.swift`, `Story/AppGameServices.swift` |
| **Gambling (GRN holovid races)** | The Bar's "Gamble" button opens `GamblingView`; a bet debits `pilot.credits`, a random winner is drawn, the GRN race clip plays, and a win pays a 3× payout (port's own multiplier) — all persisted via `pilot.save()` | `Story/GamblingView.swift`, `Spaceport/SpaceportScreens.swift` |
| **New-Pilot creation + multi-pilot roster** | Both menus' "New Pilot" opens `NewPilotView` → `AppModel.createPilot` → `PilotRoster.create` (real `chär`-scenario roll, becomes the selected pilot); "Open Pilot" browses the multi-pilot roster and `enterShip()` resumes the *selected* save | `Pilots/NewPilotView.swift`, `App/AppModel.swift`, `Pilots/PilotRoster.swift`, `Launcher/*MainMenuView.swift` |
| **Fleet `appearOn` NCB gate** | `Spawner.fleetAppearOnAllowed` reads `flët.AppearOn` and defers to `world.fleetSpawnEligible`; the spawner is live (`GameScene` builds it and calls `.populate(world)`), so ambient fleets are gated on their control-bit test in real play | `Spawner.swift`, `GameScene.swift` |
| **In-game Story Map** | The in-game menu opens a live, pannable/zoomable graph of every reconstructed campaign, resolved against the current pilot — an addition the original never had | `Game/GameMenuView.swift` ("Story Map"), `Story/StorylineMapView.swift`, `StorylineBrowserView.swift` |
| **Plug-in store** | In-app catalog browse + download/install via `NovaSwiftPluginStore` | `Launcher/PluginsView.swift` → `Store/PluginStoreView.swift` |
| **Pilot save history** | `PilotArchive` backups + `PilotRoster` history; "Load Earlier Save" restores a prior snapshot | `PilotListView.swift` |
| **Main menu + data layer** | Authentic PICT/rlëD assets; full resource-fork/`.ndat`/`.rez` parsing, plug-in override chain, typed decoders, sprite decode | `AuthenticMainMenuView.swift`, `NovaSwiftKit` |

## Built, not wired 🟡 (the code's there, but nothing calls it yet)

This list keeps shrinking — most of what used to live here is wired now. Here's
what's still waiting to be plugged in:

| System | What's built | Why the player never sees it |
|---|---|---|
| **Junk cargo & `öops` price disasters** | `JunkModels.swift` (`JunkRes`) / `OopsModels.swift` (`OopsRes`) decode correctly | No app caller of `junk()`/`junks()`/`oops()`/`oopses()` — no junk-trade UI, no price-disaster daily roll. Now **designed** (a concrete implementation plan): [reverse-engineering/JUNK_OOPS_DESIGN.md](reverse-engineering/JUNK_OOPS_DESIGN.md), building on [ECONOMY.md](reverse-engineering/ECONOMY.md). Not yet wired. |
| **Classic pilot save format** | `PilotSave`, `CombatRating` classic-archive encode | The app persists `PlayerState` as native JSON instead (`.evpilot` via `JSONEncoder`); the classic-archive *encode* path is unused (backup/restore mechanics are used). |

## Not there yet ❌ (missing, or just a placeholder)

| Gap | Detail |
|---|---|
| **AI / spawning / flight fidelity** | Really a quality gap more than a missing feature — see "how ships fly and spawn" above. Because it's rebuilt from data, the traffic rhythm, flight smoothness, and some combat transitions don't match the original exactly yet. |
| **Junk-trade / öops UI** | The decoders exist and the wiring is now **designed** ([JUNK_OOPS_DESIGN.md](reverse-engineering/JUNK_OOPS_DESIGN.md)), but no trade UI / daily price-disaster roll is implemented yet. |

## So what's next?

Our rule (from [`CHARTER.md`](CHARTER.md)) is simple: **if the player can't feel
it, it isn't done.** Now that the story, missions, mission ships, stakes, and
economy all run, here's where the effort is best spent, roughly in order:

1. **Make ships fly and spawn like the real game.** This is the biggest thing
   standing between us and "it feels like EV Nova" — tighten how traffic arrives
   and smooth out the flight so the hiccups go away. It's polish on something
   that already works, not a new feature. See [`AI.md`](AI.md).
2. **Junk & öops trading.** The last economy corner — now **designed**
   ([JUNK_OOPS_DESIGN.md](reverse-engineering/JUNK_OOPS_DESIGN.md)); it needs the
   implementation (öops price disasters first, then junk trading). This is the
   biggest remaining not-wired feature.
3. ~~**Finish Demand Tribute.**~~ **Done (2026-07-12)** — the hail-dialog button
   drives the real engine end-to-end; see the Wired table + DOMINATION.md.
4. ~~**Loose ends** (rank-based shop unlocks, drop `startNewPilot()`, ion-charge
   HUD, per-mission objective log).~~ **Done (2026-07-12)** — all four landed;
   see the Wired table and MissionInfoView's objective line.

See [`ROADMAP.md`](ROADMAP.md) for the full plan in order.
