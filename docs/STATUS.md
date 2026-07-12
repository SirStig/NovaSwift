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
> Last verified: 2026-07-09 (audit of `main` through commit `b3e0ce2`, plus a
> same-day decoder/wiring implementation pass documented across
> `docs/reverse-engineering/GOVERNMENT.md`, `FLEETS.md`, `ECONOMY.md`,
> `OUTFITTERS.md`, `ESCORTS.md`, and `EVENTS.md`'s "Implementation status"
> sections, and in-flight uncommitted work called out explicitly below).

## The headline

> **2026-07-12 — story/mission system wired end-to-end.** The gaps this
> document describes below (in the pre-2026-07-12 tables) are largely CLOSED.
> The app builds and 124 tests pass (0 assertion failures). Now live:
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
> semantics, cargo ±50%/type-1000 random, crön iterative flags (116 story
> tests). Follow-ups: ShipSyst −1/−2/−5 selectors unresolved, in-flight
> hull-swap/relocate lean on the takeoff rebuild for full visuals, destroyed
> planets show as absent (no wreck/asteroid variant yet), news has no
> per-station local/independent precedence. A combined-run `swift test` SIGBUS
> at teardown exists in `NovaSwiftEngineTests` (every suite passes in isolation;
> a runner artifact in the concurrent domination work's new tests, not the story
> wiring). The tables below predate this and are being superseded.

We have a **real, connected vertical slice** — flight, combat/AI, navigation,
and the spaceport economy all run on the player's real data, and since the
last audit the game has gained real stakes on the *travel* side: jumps now
cost fuel, target-lock is real, and combat has live ionization and odds-based
AI decisions. The mission/story picture is also better than the previous
audit tracked: `AppGameServices` (a real `GameServices` conformer) and a real
`StoryEngine` instance now back the Mission BBS and Bar screens — mission
offer/accept/decline is genuinely live and persists to the pilot save. What's
still missing is the *campaign clock*: nothing in the app ever calls
`StoryEngine.advanceOneDay()`/`advanceDays()`/`evaluateCrons()`, so the
galaxy-day never advances during play and `crön` background events (news,
scripted story beats, reinforcement-adjacent triggers) never fire for a real
player — only the subset of the story that's reachable through a single
landing's mission list actually runs.

A second, separate theme surfaced in this same pass: a batch of new resource
decoder fields (`GovtRes`/`FleetRes`/`OutfRes`/`SystRes`/`ShipRes`/`CronRes`/
`RankRes`/`MissionRes` gained real fields; `JunkRes`/`OopsRes` are new) came
with real behavior code in `Diplomacy.swift`, `Spawner.swift`,
`ShipLoadout.swift`, and `PilotStore.swift` — but per every one of the six
`docs/reverse-engineering/*.md` docs that tracked it, **most of that new code
is correct, tested, compiling Swift with zero player-visible effect yet**,
because nothing calls it from a live gameplay path. This is the same
"built, not wired" category the story module has been in for a while, now
also true of pieces of government/legal-record tracking, fleet flavor text,
the entire escort hire/upgrade/sell backend, and outfit mass-proportional
pricing/slot-limit enforcement — see the new rows below. The two exceptions
that *are* live: `Spawner`'s new `LinkSyst`/reinforcement-fleet logic
(`Spawner.swift` is already in the running spawn loop) and outfit
mass-proportional mass plus the can't-sell/consumed-on-purchase flags
(`PilotStore`/`ShipLoadout.swift` are already in the running spaceport).

Player-facing gaps otherwise remain what they were: you can fly, fight,
trade, jump (and run dry on fuel), and now take/complete a mission offered at
your current landing — but you still can't lose your ship, pay for repairs,
or see the galaxy's background story/news events play out over time.

## Wired ✅ (the player experiences this today)

| System | How it's wired | Key seam |
|---|---|---|
| **Flight sim** | `GameScene.update` drives `World.step` on the player's real hull+outfit stats | `GameScene.swift:243`, `World.swift:325` |
| **NPC spawning + AI + combat** | `GameSession.makeWorld` wires Galaxy → Diplomacy → Spawner → AIBrain → Combat; NPCs spawn from real `düde`/`flët`, fight, take real damage | `GameSession.swift:41` |
| **Ionization** | Weapon `wëap.Ionization` charges `Ship.ionCharge` in live `World.step`; past `IonizeMax` the ship can't move (`controllable = !isIonized`) or fire (`cantFireWhileIonized`) | `World.swift:330-333,542` — real physics, but **no HUD indicator** yet, so the player can't see their own ion charge building |
| **Combat odds / armor-disable AI** | `AIBrain.power(_:)` drives odds-based flee/press decisions from live `combatStrength`/`shieldFraction`; disabled-hulk transition on armor loss | `AIBrain.swift:169`, `World.swift:684` — **NPC-only**: the disable path is explicitly gated `!ship.isPlayer`, so the player ship can never be disabled this way (ties to the player-death gap below) |
| **Target-lock** | Real `selectNearestTarget`/`selectNearestHostile`/`cycleTarget`/`clearTarget`, with an authentic HUD target readout and on-screen lock brackets | `GameScene.swift:533-560`, `AuthenticHUDView.swift:61` |
| **HUD + radar** | Live ship state (shield/armor/fuel/cargo/heading), real planet + NPC blips with real hostility color; authentic status bar from `ïntf` + backdrop PICT | `GameScene.swift:543`, `AuthenticHUDView.swift` |
| **Galaxy map + navigation + fuel-gated jumps** | Real `sÿst` coords/links, BFS course plotting; `jumpAlongRoute()` calls `consumeJumpFuel()` gated by `canAfford(hops:)` against the ship's real tank — jumps are no longer free or instant | `NavigationModel.swift:90-91`, `GameContainerView.swift:413` |
| **Landing** | Range/speed-gated `attemptLand()` → `SpaceportView` | `GameScene.swift:58,298` |
| **Spaceport economy + mission-gated item locking** | Trade / Outfitter / Shipyard use real prices and mutate a persistent credit/cargo/outfit balance saved to disk; outfits/ships the pilot hasn't unlocked (via `oütf.contribute`/`require`/`availBits`) are genuinely locked, not just hidden. Outfit mass-proportional mass (`Flags 0x0400`) is folded into the ship's used-mass total, and can't-sell (`0x0008`)/consumed-on-purchase (`0x0010`) outfit flags are enforced on every buy/sell | `SpaceportScreens.swift`, `PilotStore.swift:105`, `ItemLocking.swift`, `ShipLoadout.swift` (`Galaxy.loadout`) |
| **Mission offers at the Bar & Mission Computer** | `MissionBoardView` instantiates a real `StoryEngine` per landing (via `AppGameServices`, a real `GameServices` conformer) and lists real, control-bit-gated `mïsn` offers; accept/decline mutates and persists `PlayerState`. Campaign-clock advancement (crons, news, dated story beats) is **not** part of this — see the Built-not-wired row below | `app/NovaSwift/Story/MissionBoardView.swift`, `app/NovaSwift/Story/AppGameServices.swift`, embedded from `SpaceportView.swift`/`SpaceportScreens.swift` |
| **Fleet spawn-eligibility + reinforcements** | `Spawner.isFleetEligible` filters ambient fleet spawns by `flët.LinkSyst`'s five bands; `Spawner.updateReinforcements` summons a system's `sÿst.ReinfFleet` when that government's ships are under fire and outmatched (`gövt.MaxOdds`) — both live because `Spawner` already runs inside `GameSession.makeWorld`'s spawn loop | `Sources/NovaSwiftEngine/Spawner.swift` |
| **Plug-in store** | In-app catalog browsing + download/install via `NovaSwiftPluginStore` (new library, backed by ZIPFoundation) | `Launcher/PluginsView.swift:28` → `Store/PluginStoreView.swift` |
| **Pilot save history** | `PilotArchive` backups + `PilotRoster` history; "Load Earlier Save" restores a prior snapshot | `PilotListView.swift:85-94` |
| **Main menu** | Real PICT/rlëD assets at authentic `cölr` coordinates | `AuthenticMainMenuView.swift:32` |
| **Data layer** | Resource-fork/`.ndat`/`.rez` parsing, plug-in override chain, typed decoders, sprite decoding — reads the full real game | `NovaSwiftKit` (`NovaGame` used across the app) |

## Built, not wired 🟡 (exists + tested, but the app never runs it)

**This is still the project's biggest gap.**

| System | What's built | Why the player never sees it |
|---|---|---|
| **Mission/story day-advancement & crons** | `StoryEngine.advanceOneDay()`/`.advanceDays()`/`.evaluateCrons()` — the full `crön` activate→hold→start→end lifecycle, `Contribute`/`Require` gating, and `announceNews(for:)` local/independent news resolution, all correct per `docs/reverse-engineering/EVENTS.md` | **Correction from the previous audit: mission offer/accept/decline is now wired (see the Wired table above) — it was this narrower piece that's still unwired.** Nothing in `app/` calls `advanceOneDay`/`advanceDays`/`evaluateCrons`, so the galaxy-clock day never advances during play; crons (and everything gated on them — news, dated story beats) never fire for a real player regardless of how many missions get taken. |
| **`GameServices` seam — non-mission callbacks** | `AppGameServices` (`app/NovaSwift/Story/AppGameServices.swift`) is a real conformer, and `presentMissionOffer`/`showStoryText`/`playSound` are genuinely wired through `MissionBoardView`. But `spawnMissionShips`, `changePlayerShip`, `movePlayer`, `setStellarDestroyed`, and `leaveStellar` only `Log.story.notice(...)` and no-op; `showNews` is a logging stub with no news UI behind it | Any mission or cron that tries to spawn escort ships, swap the player's hull, relocate the player, blow up a stellar, or show background news silently does nothing beyond a console log line. |
| **Government legal-record penalties & combat rating** | `Diplomacy.recordKill`/`.recordDisable`/`.recordBoard`/`.recordSmuggling` apply the correct `KillPenalty`/`DisabPenalty`/`BoardPenalty`/`SmugPenalty` fields (`Diplomacy.swift`); `Diplomacy.isCriminal` reads each govt's real `crimeTolerance` | `World.swift`'s live combat-resolution code still docks legal record from the Bible-dead `gov.shootPenalty` on every hit, and its `.shipDisabled`/`.shipDestroyed` transitions never call the new `record*` methods. Combat rating still never increments during real play. See `docs/reverse-engineering/GOVERNMENT.md`. |
| **Rank-gated purchases (`ränk.Contribute`)** | `RankRes.contribute`/`MissionRes.require` are decoded; `StoryEngine.activeContributeBits()` folds rank `Contribute` into mission availability | `app/NovaSwift/Spaceport/ItemLocking.swift`'s purchase-gate (`ship.require`/`outfit.require`) doesn't fold in active-rank `Contribute` the way `StoryEngine` does — a rank-gated *purchase*, the Bible's own headline example for this field, still isn't achievable in the spaceport UI, only mission/cron availability sees it. |
| **Escort hire/upgrade/sell backend** | `ShipRes.hireRandom`/`.escortCategory`/`.escortUpgradesTo`/`.escortUpgradeCost`/`.escortSellValue` (decoded) plus real, tested `PilotStore.hireEscort`/`.upgradeEscort`/`.sellEscort`/`.escortAvailableToday` transaction logic | Zero call sites anywhere in `app/NovaSwift/` outside their own declarations. `EscortsView.swift` was rebuilt to authentically match the real DLOG/DITL #1022 panel, but every control is disabled and "No escorts hired." is hardcoded — no data binding to `PilotStore` at all. See `docs/reverse-engineering/ESCORTS.md`. |
| **Outfit mass-proportional pricing & gun/turret slot limits** | `OutfRes.effectiveCost(shipMass:)` (correct mass-scaled price math) and `Loadout.usedGunSlots`/`.usedTurretSlots`/`.freeGunSlots`/`.freeTurretSlots` (correct slot accounting), both in `ShipLoadout.swift` | `PilotStore.buyOutfit`/`.sellOutfit` still charge/refund the flat `Cost` instead of calling `effectiveCost`, so every mass-scaled-price outfit in real data is mis-priced; `PilotStore.canBuyOutfit` never reads `freeGunSlots`/`freeTurretSlots`, so a player can buy more gun/turret outfits than the hull has mounts for. See `docs/reverse-engineering/OUTFITTERS.md`. |
| **Junk cargo & `öops` price disasters** | `JunkModels.swift` (`JunkRes`)/`OopsModels.swift` (`OopsRes`) — both new, decoding correctly against the byte layouts `docs/reverse-engineering/ECONOMY.md` documents | Nothing outside `NovaSwiftKit` calls `junk()`/`junks()`/`oops()`/`oopses()` — no junk trading UI, no price-disaster simulation. |
| **Fleet flavor fields** | `FleetRes.appearOn`/`.hailQuote`/`.freightersHaveRandomCargo` (decoded) | No call site evaluates `appearOn` against an NCB test, no arrival-text event reads `hailQuote`, and there's no boarding mechanic for `freightersHaveRandomCargo` to attach to. (Contrast with `flët.LinkSyst` and `sÿst`'s reinforcement fields, which *are* wired — see the Wired table.) See `docs/reverse-engineering/FLEETS.md`. |
| **Pilot save format** | `PilotSave`, `CombatRating` (classic-style archive fields) | App persists `PlayerState` as custom JSON instead (`PilotStore.swift`); the classic-archive encode path is unused by the app (though `PilotArchive`'s *backup/restore* mechanics are now used — see wired table). |
| **Pilot creation** | `PilotFactory` builds a pilot from a `chär` scenario | Used only by CLI (`main.swift:305`) + tests. `AppModel.startNewPilot()` exists but has **zero call sites** in the app. |
| **Game calendar** | `GameDate` in-game date math | No app reference. |
| **Story guide UI** | `StoryGuideView`, `StorylineBrowserView`, `StoryGuidePresenter`, `StoryGuideModel` (in `app/NovaSwift/Story/`) | Not presented by any screen; also carries hardcoded sample data. Orphaned. |

## Missing / shells ❌ (not built, or placeholder only)

| Gap | Detail |
|---|---|
| **Missions & BBS in-game** | **Correction from the previous audit:** the Mission BBS and Bar mission list are now backed by a real `StoryEngine` (see Wired table) — "No missions available at this time." is the genuine empty state, not a hardcoded placeholder, when no `mïsn` is currently offerable. What's still missing: the galaxy-day never advances (see Built-not-wired table), so time-gated/story-progressing missions never become offerable through play; mission side effects that need `spawnMissionShips`/`changePlayerShip`/`movePlayer`/`setStellarDestroyed` are stubbed to a log line only. In-game "Mission Log" is still a hardcoded "coming soon" alert (`GameMenuView.swift`). |
| **Player death / stakes** | Nothing checks player `armor <= 0`; the NPC disable/destroy path is explicitly `!ship.isPlayer`-gated. No game-over, no respawn. Player is immortal. |
| **Repair economy** | Landing/ship-rebuild resets shields/armor/fuel to full for free — still a free full heal, no paid mechanic. (Note: uncommitted WIP is adding a separate *paid ally-assistance* flow — hailing a friendly ship for an in-flight fuel/repair transfer — which is a different feature from spaceport repairs and not yet merged.) |
| **Targeting → weapon-lock nuance** | Target-lock itself is now wired (see above); guided-weapon lock-tone/lock-loss and point-defense-vs-guided interactions are the remaining depth items, tracked in `docs/AI.md`. |
| **New Pilot / multi-pilot UI** | `startNewPilot()` (reset+reroll) is still never called. Save history/restore now works, but there's no multi-pilot selection UI — all three main-menu save buttons resume the same single save. |
| **Orphaned data** | `PersRes` (`përs` named NPCs) is parsed but has zero consumers anywhere. |

## Priority implication

Per [`CHARTER.md`](CHARTER.md), **a feature that isn't wired does not exist for
the player.** The highest-leverage work is therefore not building new systems —
it is:

1. **Wiring `StoryEngine`'s day-advancement/cron loop** (`advanceOneDay`/
   `advanceDays`/`evaluateCrons`) into the live session, and fleshing out
   `AppGameServices`'s remaining stub methods (`spawnMissionShips`,
   `changePlayerShip`, `movePlayer`, `setStellarDestroyed`, `showNews`).
   Mission offer/accept/decline itself is now wired (see Wired table) — this
   is the narrower remaining piece, but it's still the gate on the galaxy
   feeling alive over time (background news, dated story beats).
2. **Closing the remaining stakes gaps** — player death/game-over and paid
   repairs are the two big glaring ones left (fuel and targeting are done).
3. **Pilot management** — real New Pilot reset and a multi-pilot selection UI
   (save/restore itself now works).
4. **Finishing the decoder→behavior wiring from the latest reverse-engineering
   pass** — several systems now have correct, tested backend code with zero
   live caller: escort hire/upgrade/sell (`PilotStore`), government
   legal-record penalties (`Diplomacy.record*` into `World.swift`'s combat
   resolution), outfit mass-proportional pricing and gun/turret slot limits
   (`PilotStore.buyOutfit`/`canBuyOutfit`), and junk/`öops` trading. See the
   new Built-not-wired rows above and [`ROADMAP.md`](ROADMAP.md) for the
   concrete per-item task list.

See [`ROADMAP.md`](ROADMAP.md) for the sequenced plan.
