# Planetary domination — "Demand Tribute"

Source: `Documentation/Nova Bible.txt` (the official EV Nova plugin-developer
"Resource Bible", ©1995-2004 Ambrosia Software / Matt Burch) inside the user's
owned `EV Nova CE` install — the `spöb` resource section (Tribute/DefenseDude/
DefCount/Flags2/OnDominate/OnRelease), cross-checked against the real `spöb`
`TMPL` (#520 in `third_party/ResForge/.../NovaTools/Templates.rsrc`) and raw
`spöb` dumps (`novaswift-extract raw "data/base" spöb <id>`).

## What it is

The player targets a stellar and demands tribute. A governed planet with a
defense fleet answers with force, launching `DefenseDude` ships in waves until
its `DefCount` pool is spent. Destroy them all and demand again → the planet
surrenders and is **dominated**: it fires its `OnDominate` control bits and pays
its `Tribute` in credits **per day** (auto-added by the galaxy day clock — *not*
collected on landing), until released.

## Fields (verified byte offsets vs. TMPL #520 + real data)

| Field | Offset | Bible meaning | Decoded on `SpobRes` |
|---|---|---|---|
| `Tribute` | @10 `DWRD` | Credits/day when dominated. `-1`/`0` = default `1000 × TechLevel`; `≥1` = exact | `tribute`, `dailyTributeAmount` |
| `DefenseDude` | @28 `RSID` | `düde` class launched to defend (`<128` = no defense fleet) | `defenseDude`, `hasDefenseFleet` |
| `DefCount` | @30 | Decimal-packed total + wave size (see below) | `defenseCountRaw` → `defenseTotal`, `defenseWaveSize` |
| `Flags2 0x0020` | @32 | "Stellar is always dominated" | `startsDominated` |
| `OnDominate` | @54 `n0FF` | NCB set expression run on conquest | `onDominate` |
| `OnRelease` | @309 `n0FF` | NCB set expression run on release | `onRelease` |

Verified against real records: **Earth** (#128) — `Tribute 10000`, `DefenseDude
130` ("Lone Big Federation Ship"), `DefCount 7006`; a typical Federation world —
`DefCount 2206`.

### DefCount decimal-packing (Bible, quoted)

> "If you set this number to be above 1000, ships will be launched in waves. The
> last number in this field is the number of ships in each wave, and the first
> 3-4 numbers (minus 1 from the first digit) are the total number of ships in
> the planet's fleet. For example, a value of 1082 would be four waves of two
> ships for a total of eight. A value of 2005 would create waves of five ships
> each, with 100 ships total."

So for `raw > 1000`: `waveSize = raw % 10`; `total = (raw/10)` with 1 subtracted
from the leading digit. `1082 → 8 total, 2/wave`; `2005 → 100 total, 5/wave`;
`7006 → 600 total, 6/wave` (Earth). For `raw ≤ 1000` the whole fleet launches at
once (`total = raw`, `waveSize = total`). **Note:** ResForge's TMPL presents this
16-bit field as a `WB12`+`WB04` *bit* split (its editor convention); the actual
engine value is the raw decimal number decoded per the rule above — the two
disagree, and the Bible's decimal rule is the authoritative engine behavior
(only it yields the Bible's own worked examples).

## The flow (engine — `NovaSwiftEngine/Domination.swift`)

`World.demandTribute(spobID:) -> TributeOutcome`:

1. Already dominated → `.refused(.alreadyDominated)`.
2. Not an in-system stellar we have data for → `.refused(.notDominatable)`.
3. `Flags2 0x0020` always-dominated → immediate `.dominated`.
4. No defense fleet (`DefenseDude < 128` or `DefCount 0`) → `.refused(.noDefenseFleet)`.
5. **Combat-rating gate** (first demand only): if `playerCombatRating <
   defenseTotal × tributeRatingPerDefender`, the planet laughs it off →
   `.refused(.combatRatingTooLow)`. This gate is an **engine addition** — stock
   EV Nova has no combat-rating threshold; its only gate is defeating the defense
   fleet. Set `World.tributeRatingPerDefender = 0` to disable it (fully faithful).
6. Otherwise open a contest and scramble the first wave (`.defending(launched:)`).
   `World.updateStellarDefenses()` (called each `step`) relaunches the next wave
   from the remaining pool whenever the current wave is wiped out, until the pool
   is spent.
7. Re-demanding while defenders remain → `.stillDefending`. Re-demanding once the
   pool is exhausted and no defenders are alive → `.dominated` (emits
   `WorldEvent.stellarDominated`).

Defenders are spawned from `DefenseDude` with `AIBrain.behaviorOverride =
.attackPlayer` and tagged `Ship.spobDefenderOf`, reusing the mission/fleet spawn
infrastructure.

## Persistence & tribute (story — `NovaSwiftStory`)

- `PlayerState.dominatedStellars: Set<Int>?` — persisted, save-compatible optional.
- `StoryEngine.dominateStellar(_:)` / `releaseStellar(_:)` — the seam the app
  calls on `WorldEvent.stellarDominated`; updates the set and fires
  `OnDominate`/`OnRelease` NCB expressions + a `StoryNotification`.
- `StoryEngine.payDailyTribute()` — runs inside `advanceDays` next to
  `payDailySalaries`; each dominated stellar's `dailyTributeAmount` is added to
  the player's credits **per day** automatically (the authentic behavior — not a
  landing collection).

## Engine inventions (flagged, not silent)

- The **combat-rating gate** and its `tributeRatingPerDefender` scaling — stock
  Nova has none; added at the user's request as the "laughs at you" gate.
- Waves relaunch by keeping the field clear→refill cadence; the Bible specifies
  wave *size* and *total* but not the exact relaunch timing.
- A contest resets when the player leaves the system (the `World` is rebuilt per
  visit), matching the transient nature of the defense fight.

## Wiring status

Engine flow + events + `spöb` decode + `PlayerState` persistence + daily tribute
are implemented and covered by unit tests (`DominationTests`,
`StoryEngineTests`) and a headless proof (`novaswift-extract tribute <baseDir>
<systemID> [spobID] [rating]`). What remains is **app-side**: a "Demand Tribute"
input/command on a targeted planet that calls `World.demandTribute`, HUD text for
the `tributeRefused`/`stellarDefendersLaunched`/`stellarDominated` events, and
calling `StoryEngine.dominateStellar` on conquest — blocked on the same
story-runtime-not-wired gap tracked elsewhere.
