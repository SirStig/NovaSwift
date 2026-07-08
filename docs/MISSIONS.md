# Missions & Story (`EVNovaStory`)

> ⚠️ **Status: BUILT, NOT WIRED.** This module is fully implemented and tested,
> but the running app does **not** drive it — the only live consumer is the
> `evnova-extract` CLI and unit tests, plus a **read-only** `StorylineAnalyzer`
> that computes a static guide. **No app type conforms to `GameServices`**, and
> the app never instantiates `StoryEngine` for play, so the player cannot yet
> accept or progress missions. Wiring this in is roadmap **P0**. See
> [STATUS.md](STATUS.md) and [ROADMAP.md](ROADMAP.md). "Done" below means "the
> library works," not "the player experiences it."

The story layer — bar/computer missions, the control-bit ("NCB") scripting
language, background `crön` events, ranks, and the campaign save-state. It is a
**self-contained module** (`Sources/EVNovaStory`) that depends only on
`EVNovaKit`, so it plugs into the game as combat, AI, audio, and the authentic
UI come online. Everything it can't do itself goes through one protocol,
`GameServices`, which starts as a logging stub.

This is roadmap item **5 (Missions & story)**.

## What's done

- **Typed decoders** (in `EVNovaKit/MissionModels.swift`) for `mïsn`, `crön`,
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
- **Tests** (`Tests/EVNovaStoryTests`) + a real-data playthrough:
  `evnova-extract story <baseDir> 128` drives the actual Vell-os storyline
  through the engine.

## Verified binary layouts

Confirmed by dumping real resources (`evnova-extract raw/strscan/tmpl`) and
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

A new **`StorylineAnalyzer`** (`EVNovaStory`) reconstructs the campaigns straight
from the mission bit-graph — no hand-authored guide. It links "who sets bit N"
(a mission's `OnSuccess`/`OnShipDone`/`OnAccept`, or a cron's `OnStart`/`OnEnd`)
to "who needs bit N" (`AvailBits`), groups missions by EV Nova's `"Name; TagN"`
convention, and for any pilot reports each step's status plus — for the current
locked step — **exactly what to do to unlock it**.

Proven on the real game: `evnova-extract storylines <baseDir> [b350,b6666,…]`
reconstructs all 23 campaigns (Fed 37, Polaris 36, Auroran 28, Vell-os 29, …) and
prints next-step guidance like *"needs b208 set — via Complete 'Find and Return
with Bazara'"*.

The SwiftUI UI lives in `app/EVNova/Story/`:
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

## Not yet wired (needs the other systems)

- Special/auxiliary **ship spawning** and destruction reporting (needs combat/AI
  to tag spawned ships with the mission id — the hook is `spawnMissionShips`).
- **`përs`** captains offering their linked missions in space (needs AI to place
  them; the decoder + `activeOn`/`linkMission` fields are ready).
- Govt **allies/enemies** stellar selectors resolve as plain govt matches until
  the government-relations table (AI module) is queryable.
- Rendering of `dësc` **PICT**/movie art in offers (needs the UI + PICT decoder).
