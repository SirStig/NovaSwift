# Missions & Story (`NovaSwiftStory`)

> ✅ **Status: WIRED (as of 2026-07-12).** This module is now driven by the
> running app end-to-end, not just the CLI/tests. `app/NovaSwift/Story/AppGameServices.swift`
> is a real `GameServices` conformer; `MissionBoardView.swift` runs a live
> `StoryEngine`; accepting/declining a mission mutates and saves `PlayerState`;
> **`GameContainerView.handleStoryLanding` calls `engine.playerLanded` on every
> dock** so delivery/courier/passenger/cargo missions complete, pay out, and
> show completion text; **`advanceGameDay` advances the galaxy-day clock** on
> landing/gate/hyperjump so `crön` background events (timed bit-flips, news)
> fire; and **mission ships spawn into the live world** and report
> disable/board/destroy back to the engine (`spawnActiveMissionShips` →
> `World.spawnMissionShips` → `.missionShipGoalReached`). Remaining follow-ups
> are narrow: govt allies/enemies stellar selectors resolve as plain govt
> matches until the government-relations table is queried at those call sites;
> a *landed* player's hull-swap/relocate takes effect on the next takeoff
> rebuild rather than instantly (in-flight, both rebuild the live scene
> immediately). `dësc` **PICT/movie** art in offers is now decoded and
> rendered (`DescRes.pictureID`/`movieFilename`, `MissionOffer.pictureID`,
> `MissionSingleDialog`'s briefing pane + "Play Clip" holovid overlay, backed
> by `GameDataController.videoURL(named:)` — searches the base data dir and
> every plugin dir, so a plugin-shipped clip like ARPIA2's `gasminer.mov`
> resolves the same way its base-install `Race N.mov` clips already did). See
> [STATUS.md](STATUS.md),
> [ROADMAP.md](ROADMAP.md), and
> [reverse-engineering/EVENTS.md](reverse-engineering/EVENTS.md) §5. "Done"
> below now means both "the library works" *and* "the player experiences it."

The story layer — bar/computer missions, the control-bit ("NCB") scripting
language, background `crön` events, ranks, and the campaign save-state. It is a
**self-contained module** (`Sources/NovaSwiftStory`) that depends only on
`NovaSwiftKit`, so it plugs into the game as combat, AI, audio, and the authentic
UI come online. Everything it can't do itself goes through one protocol,
`GameServices`, which starts as a logging stub.

This is roadmap item **5 (Missions & story)**.

## What's done

- **Typed decoders** (in `NovaSwiftKit/MissionModels.swift`) for `mïsn`, `crön`,
  `përs`, `ränk`, `dësc`, `STR#`. Field offsets were **verified empirically
  against the real game** (791 missions, 125 crons, 31 ranks) — see below.
- **NCB engine** (`NCBExpression.swift`): a hand-rolled parser + evaluator for
  both control-bit dialects (TEST expressions that gate availability, SET
  expressions that apply effects). Case-insensitive; matches the ResForge
  NovaTools grammar.
- **Player save-state** (`PlayerState.swift`): `Codable` pilot file — control
  bits, credits, ship, cargo, outfits, ranks, legal records, explored systems,
  active/completed/failed missions, cron runtime, galaxy clock.
- **Story engine** (`StoryEngine.swift`): mission availability → offer → accept/
  decline/abort → objective tracking → completion + rewards; `crön` evaluation
  against the galaxy clock; rank salaries; the full SET-op executor.
- **Galaxy clock** (`GameDate.swift`): day/month/year with Julian-day arithmetic
  for deadlines and cron windows.
- **Tests** (`Tests/NovaSwiftStoryTests`) + a real-data playthrough:
  `novaswift-extract story <baseDir> 128` drives the actual Vell-os storyline
  through the engine.

## Verified binary layouts

Confirmed by dumping real resources (`novaswift-extract raw/strscan/tmpl`) and
cross-checking the ResForge NovaTools TMPL definitions.

### `mïsn` — 1970 bytes

```
@0   AvailStellar (i16)      @46  CompRewardGovt (i16)
@2   (unused)                @48  CompLegalReward (i16)
@4   AvailLocation (i16)     @50  ShipSubtitle STR# (i16)
@6   AvailRecord (i16)       @52  BriefText dësc (i16)
@8   AvailRating (i16)       @54  QuickBrief dësc (i16)
@10  AvailRandom (i16)       @56  LoadCargoText dësc (i16)
@12  TravelStellar (i16)     @58  DropCargoText dësc (i16)
@14  ReturnStellar (i16)     @60  CompletionText dësc (i16)
@16  CargoType (i16)         @62  FailureText dësc (i16)
@18  CargoQty (i16)          @64  TimeLimit (i16)
@20  CargoPickup (i16)       @66  CanAbort (i16)
@22  CargoDropoff (i16)      @68  ShipDoneText dësc (i16)
@24  ScanMask (u16)          @72  AuxShipCount (i16)
@28  PayVal (i32)            @74  AuxShipDude (i16)
@32  ShipCount (i16)         @76  AuxShipSystem (i16)
@34  ShipSystem (i16)        @78  Flags1 (u16)
@36  ShipDude (i16)          @80  Flags2 (u16)
@38  ShipGoal (i16)          @86  RefuseText dësc (i16)
@40  ShipBehavior (i16)      @88  AvailShipType (i16)
@42  ShipName STR# (i16)
@44  ShipStart (i16)

@92    AvailBits   (255-byte NUL-terminated NCB TEST string)
@347   OnAccept    (255)     @1112  OnFailure (255)
@602   OnRefuse    (255)     @1367  OnAbort   (255)
@857   OnSuccess   (255)     @1622  Require (8 bytes)
                             @1630  DatePostIncrement (i16)
                             @1632  OnShipDone (255)
@1887  AcceptButton (C32)  @1919 RefuseButton (C33)  @1952 DisplayWeight (i16)
```

Offer text follows EV Nova's convention: `dësc` id `3872 + missionID`
(verified: mïsn 128 → dësc 4000 "Delivery to Earth").

### `crön` — fixed head + 3 NCB strings

```
@0 firstDay @2 firstMonth @4 firstYear @6 lastDay @8 lastMonth @10 lastYear
@12 Random @14 Duration @16 PreHoldoff @18 PostHoldoff @20 IndepNews STR# @22 Flags
@24 EnableOn (255)  @279 OnStart (255)  @534 OnEnd (255)
```

### `ränk` — 152 bytes

```
@0 Weight @2 Govt @4 PriceModifier @6 Salary(i32) @10 SalaryCap(i32)
@14 Contribute(8) @22 Flags @24 ConvName(C64) @88 ShortName(C64)
```

### `dësc` / `STR#`

`dësc` is a leading NUL-terminated C-string (the narrative text) followed by
picture/movie/flags. `STR#` is a `u16` count then that many Pascal strings.

## The NCB scripting language

Two dialects stored as short strings inside the resources above.

**TEST** (availability gates), standard boolean precedence `!` > `&` > `|` with
`(…)` grouping. Operands (case-insensitive; bit refs are lowercase in the data):

| token | meaning |
|-------|---------|
| `bN`  | control bit N is set |
| `oN`  | player has outfit N |
| `eN`  | player has explored system N |
| `pN`  | unregistered ≤ N days (registered player ⇒ always true) |
| `g`   | player is male |

Example (real mïsn #128): `!(b511 | b515) & !b350`.

**SET** (side effects), whitespace-separated ops:

| token | effect | token | effect |
|-------|--------|-------|--------|
| `bN` `!bN` `^bN` | set / clear / toggle bit | `GN` `DN` | grant / remove outfit |
| `SN` `AN` `FN` | start / abort / fail mission | `KN` `LN` | activate / deactivate rank |
| `MN` `NN` | move to system | `CN` `EN` `HN` | change ship (variants) |
| `YN` `UN` | destroy / regen stellar | `PN` | play sound |
| `XN` | explore system | `TN` | change ship title (STR#) |
| `Q` `QN` | leave stellar (opt. message) | `R(a b)` | random 50/50 |

Example (real mïsn #128 OnSuccess): `b350 b6666`.

## The plug-in seam: `GameServices`

The engine owns story state; effects that reach outside it are declared in
`GameServices` and implemented by whichever system owns them. Until then,
`LoggingGameServices` makes the whole engine runnable and testable.

| method | implemented by |
|--------|----------------|
| `presentMissionOffer` / `showStoryText` | authentic UI |
| `playSound` | audio system |
| `spawnMissionShips` | combat + AI (tag ships with `missionID`) |
| `changePlayerShip` | shipyard / outfitting |
| `movePlayer` / `setStellarDestroyed` | galaxy map / nav |
| `notify` | HUD toasts / mission log |

## Wiring it into the game (for the other subsystems)

```swift
let engine = StoryEngine(game: novaGame, player: pilot, services: myServices)

// spaceport / bar:
for m in engine.missionsOffered(at: .bar, spob: currentSpob) { engine.present(m) }
engine.accept(missionID)          // or engine.decline(missionID)

// navigation:
engine.playerJumped(toSystem: id)
engine.playerLanded(onSpob: id)   // advances cargo + completes return objectives

// combat / AI (report by mission id the spawned ship was tagged with):
engine.missionShipDestroyed(missionID: id)
engine.missionShipDisabled(missionID: id)
engine.missionShipBoarded(missionID: id)

// main loop, once per in-game day:
engine.advanceOneDay()            // crons, deadlines, salaries
```

`engine.player` is the `Codable` save file — persist it directly.

## In-game Pilot window + aftermarket Story Guide

A new **`StorylineAnalyzer`** (`NovaSwiftStory`) reconstructs the campaigns straight
from the mission bit-graph — no hand-authored guide. It links "who sets bit N"
(a mission's `OnSuccess`/`OnShipDone`/`OnAccept`, or a cron's `OnStart`/`OnEnd`)
to "who needs bit N" (`AvailBits`), groups missions by EV Nova's `"Name; TagN"`
convention, and for any pilot reports each step's status plus — for the current
locked step — **exactly what to do to unlock it**.

Proven on the real game: `novaswift-extract storylines <baseDir> [b350,b6666,…]`
reconstructs all 23 campaigns (Fed 37, Polaris 36, Auroran 28, Vell-os 29, …) and
prints next-step guidance like *"needs b208 set — via Complete 'Find and Return
with Bazara'"*.

The SwiftUI UI lives in `app/NovaSwift/Story/`:
- **`PilotInfoView`** — the Pilot window: credits, ship, combat rating, ranks,
  government standings, active missions, escorts (original-game info window).
- **`StorylineBrowserView`** — the *aftermarket* EV-Bible-style browser: every
  storyline with a progress bar, each step's status, a "YOU ARE HERE" marker, and
  the unlock hint for the locked next step.
- **`StoryGuideView`** — a tabbed container of the two.

They render in Xcode Previews via `StoryGuideModel.sample`. To show over the real
loaded game (one line, from whichever view owns the interactive menu):

```swift
@State private var showGuide = false
Button("Pilot Log") { showGuide = true }
    .storyGuideSheet(isPresented: $showGuide,
                     model: .over(dataController.game!))   // pass the live pilot once it exists
```

`StoryGuideModel.over(game:player:)` accepts the pilot's live `PlayerState` once
the running game owns one; until then it uses a starter pilot so the guide is
browsable immediately.

## Now wired (was "not yet wired")

- ✅ Special/auxiliary **ship spawning** and destruction reporting —
  `spawnMissionShips` → `World.spawnMissionShips`, with disable/board/destroy
  reported back via `.missionShipGoalReached`.
- ✅ **`përs`** captains offering their linked missions in space — the `përs`
  system places named NPCs with hail quotes, link-missions, and grudges into
  the live world.
- ✅ `ShipSyst` **−1/−2/−5/−6 mission-ship selectors** — the full selector
  table (initial system, random-but-frozen-per-mission, adjacent-to-initial,
  follow-the-player, plus travel/return spöb systems and specific system ids)
  is implemented in `missionSystemMatches`
  (`app/NovaSwift/Game/GameContainerView.swift:1695`).
- ✅ Background **news** local/independent precedence per station —
  `StoryEngine.stationNews(forGovt:)`
  (`Sources/NovaSwiftStory/StoryEngine.swift:892`) collects local news tagged
  for the requesting station's govt (or a govt allied with it) and falls back
  to the shared independent pool only when no local news applies; wired into
  `HolovidView` (`app/NovaSwift/Spaceport/SpaceportScreens.swift:944`).
- ✅ A destroyed stellar renders its **wreck** graphic
  (`spöb.DestroyedGraphic` → `spïn` → `rlëD`, decoded by
  `NovaGame.spobDestroyedSprite`, `Sources/NovaSwiftKit/NovaModels.swift:1241`)
  when wreck art exists for it; it only vanishes from the system when there's
  no wreck art at all (`app/NovaSwift/Game/GameContainerView.swift:159`).

## Still not fully wired (low-value polish)

- Govt **allies/enemies** stellar selectors resolve as plain govt matches until
  the government-relations table is fully queried at those call sites.
- A *landed* player's hull-swap/relocate takes effect on the next takeoff
  rebuild rather than instantly; in-flight, both `onChangePlayerShip` (via
  `rebuildFlightHost`) and `onMovePlayer` (via `movePlayerToSystem`) rebuild
  the live scene immediately (`app/NovaSwift/Game/GameContainerView.swift:1492`).
