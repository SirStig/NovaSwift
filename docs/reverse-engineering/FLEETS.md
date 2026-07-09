# Fleets and random-encounter spawning

Source: `Documentation/Nova Bible.txt` (the official EV Nova plugin-developer
"Resource Bible", ©1995-2004 Ambrosia Software / Matt Burch) inside the user's
owned `EV Nova CE` install. Sections read in full for this doc: the `flët`
resource (lines 886–932) and the whole `sÿst` resource (lines 3002–3132), plus
every cross-reference surfaced by a case-insensitive grep for "fleet" across
the entire Bible (24 hits — table in §6). Every field below is a direct
quote/paraphrase of that document, not a guess.

This doc does **not** re-derive reinforcement fleets (`sÿst.ReinfFleet` +
`gövt.MaxOdds` gating) — that's already covered in
[AI_GROUND_TRUTH.md](AI_GROUND_TRUTH.md) §2 and §6 item 1. This doc is about
the other, larger half of the population picture: how a `flët` (a scripted
convoy/patrol/pirate-pack) and a system's own background `düde` traffic table
come to put ships in a system in the first place, and how that's currently
wired (or not) in `Spawner.swift`.

## 0. Two independent population mechanisms

The Bible describes **two separate systems** that both put NPC ships in a
system, and it's easy to conflate them:

1. **Background traffic** — a `sÿst` resource's own `DudeTypes`/`%Prob`/
   `AvgShips` fields: a per-system weighted table of individual `düde` ship
   types, with a target population size. This is "how many random traders and
   patrol ships wander this system."
2. **Fleets** (`flët`) — a scripted group: one lead ship plus up to four
   escort *types*, each with its own min/max count, one shared government,
   and a rule (`LinkSyst`) for which systems it's allowed to appear in at
   all. This is "a coherent convoy/patrol/pirate-pack jumps in as a unit,"
   distinct from the ambient one-at-a-time traffic above.

Critically, the Bible's `sÿst.DudeTypes` field text (below) only ever
describes it as holding a `düde` ID (128–639). It does **not** state, anywhere
in the prose, how a system's spawn table refers to a `flët` instead of a
`düde`. The existing decoder (`SystRes.spawns`,
`Sources/EVNovaKit/NovaModels.swift:323-338`) resolves this by convention: a
**negative** value in a `DudeTypes` slot is read as `-value` = a `flët` id
(`fleetSpawns`), while a positive value ≥128 is a `düde` id (`dudeSpawns`).
This is a reasonable, and empirically-confirmed, inference — running
`evnova-extract ai "data/EV Nova" <sysID> 1` against the real Nova.rez data
shows most Federation-space systems reporting `8 dude(s), 0 fleet(s)`, but
Alphara (#131) and Nesre Secundus (#133) report `7 dude(s), 1 fleet(s)` out of
the same 8 total slots — i.e. real stock data does mix negative (fleet) and
positive (dude) values in the same 8-slot table. The Bible text itself never
documents this sign convention, though; it's worth keeping in mind as an
inference validated by data, not a quoted spec, if a future disassembly pass
turns up a different rule (e.g. a separate flag bit rather than sign).

## 1. `sÿst` fields governing traffic/density (lines 3002–3132)

Full field list, in Bible order, with what's decoded in `SystRes`
(`Sources/EVNovaKit/NovaModels.swift:316-360`) noted per row:

| Field | Bible meaning | Decoded in `SystRes`? |
|---|---|---|
| `xPos`, `yPos` | Map position | ✅ `x`, `y` @0, @2 |
| `Con1`–`Con16` | Hyperspace links; `-1` none, `128-1127` linked system id | ✅ `links` @4-34 |
| `NavDef` (×16, F1-F4) | Nav defaults for stellar objects — "if you don't set a planet as a nav default, the AIs won't 'see' it, it won't show up on the radar, and you can't select it" | ❌ not decoded on `SystRes` (`spobs` @36-66 lists stellar object ids present in the system, but not which are nav defaults) |
| `DudeTypes` (×8) | "Which type of dude to place… 128 to 639 ID number… -1 unused" | ✅ `spawns` ids @68-82 (see §0 re: negative = fleet convention) |
| `%Prob` (×8) | "Probability that a given ship placed is of each of the above types," 1-99 | ✅ `spawns` probs @84-98 |
| **`AvgShips`** | **"The average number of AI ships in the system. 0 = no ships, empty system. 1 and up = this number of ships, +/- 50%"** | ✅ `averageShips` @100 |
| `Govt` | "Which government owns the system… -1 = Ignored (independent)" | ✅ `government` @102 |
| `Message` | Message-buoy `STR# 1000` entry, `-1` none | ❌ not decoded |
| `Asteroids` | How many asteroids (0-16) | ❌ not decoded |
| `Interference` | "How thick the static… 0 is no static, 100 is complete sensor blackout" | ❌ not decoded |
| `Person` fields | Force a specific `përs` to always appear | ❌ not decoded |
| `Visibility` | Control-bit test expression; hide/replace whole system | ❌ not decoded |
| `BkgndColor`, `Murk`, `AstTypes` | Cosmetic / hazard flags | ❌ not decoded |
| `ReinfFleet`, `ReinfTime`, `ReinfIntrval` | Reinforcement-fleet id/delay/regen interval — see [AI_GROUND_TRUTH.md](AI_GROUND_TRUTH.md) | ❌ **not decoded anywhere in `SystRes`** — see §5 below, this is a sharper gap than AI_GROUND_TRUTH's phrasing implies |

**This directly answers the brief's question** ("any fields governing general
ship traffic/density/danger level"): there is **no separate "danger level" or
"traffic level" stat**. The Bible only ever gives you two knobs for ambient
population —

- **`AvgShips`**: the target ship count, "+/- 50%" (i.e. the real instantaneous
  count randomly varies in `[0.5×, 1.5×] × AvgShips`), and
- **`DudeTypes`/`%Prob`**: which ship *types* (traders vs. patrols vs.
  pirates, per whatever `düde`s the system lists) make up that count, and in
  what mix.

"Danger" in EV Nova is an emergent property of *which dudes/fleets a system's
designer chose to list* (e.g. a pirate-heavy `%Prob` mix, or a `flët` with a
hostile `Govt`), not a dial the engine reads directly. `Interference` (sensor
blackout) and `Asteroids` are separate hazard fields, not traffic-density
controls, and neither is decoded yet.

`Spawner.swift` reflects the two real knobs closely:
`targetPopulation = min(maxPopulation, avg + 2)` derives a live cap from
`averageShips` (`Sources/EVNovaEngine/Spawner.swift:44-45`), and
`spawnOne` draws from the combined `dudes`+`fleets` weighted table
(`Spawner.swift:76-95`) — matching `%Prob`'s weighted-pick semantics
(`weightedPick`, `Spawner.swift:97-105`, same algorithm as `DudeRes.pickShip`
in `NovaModels.swift:337-348`). The "+/- 50%" variance itself isn't modeled as
a per-arrival roll — `targetPopulation` is a fixed derived number, not
re-rolled — see §7.

## 2. `flët` resource fields (lines 886–932)

> "A flet resource defines the parameters for a fleet, which is a collection
> of ships that can be made to appear randomly throughout the galaxy."

| Field | Bible meaning | Decoded in `FleetRes`? |
|---|---|---|
| `LeadShipType` | "ID of the fleet's flagship's ship class" | ✅ `leadShip` @0 |
| `EscortType` (×4) | "IDs of the flagship's escorts' ship classes." Unused slots should still hold a valid ship class id, with `Min`/`Max` set to 0 so "the extra ships [just] don't appear" | ✅ `escorts[].shipID` @2,4,6,8 |
| `Min` (×4) | "The minimum number of each type of escort to put in the fleet" | ✅ `escorts[].min` @10,12,14,16 |
| `Max` (×4) | "The maximum number of each type of escort to put in the fleet" | ✅ `escorts[].max` @18,20,22,24 |
| `Govt` | "ID of the fleet's government, or -1 for none" | ✅ `govt` @26 |
| `LinkSyst` | "Which systems the fleet can be created in" (ranges — see §3) | ✅ decoded as `linkSystem` @28, but **never read anywhere** — see §7 |
| `AppearOn` | "A control bit test field that will cause a given fleet to appear only when the expression evaluates to true. If this field is left blank it will be ignored" | ❌ not decoded |
| `Quote` | "Show a random string from the STR# resource with this ID when the fleet enters from hyperspace. Any occurrences of the character '#'… will be replaced with a random digit (0-9)" | ❌ not decoded |
| `Flags` | `0x0001`: "Freighters (`InherentAI <= 2`) in this fleet will have random cargo when boarded" | ❌ not decoded |

`FleetRes.init` (`Sources/EVNovaKit/NovaAIModels.swift:364-379`) only reads
bytes 0–29 (through `LinkSyst` @28-29); the resource almost certainly
continues past byte 30 for `AppearOn`/`Quote`/`Flags`, but neither the Bible
(prose-only, no byte offsets) nor novaparse (no `FleetResource.ts` — the
TypeScript port never parsed `flët` at all, confirmed by grepping
`third_party/NovaJS` for "fleet": the only hit is a stray comment in its
README) gives an authoritative offset for them. Treat those three fields as
"known to exist, offset unverified" until a disassembly pass or another
reference turns one up.

**Escort count roll.** The Bible doesn't state whether each escort count is
independently rolled uniformly in `[Min, Max]` or something else (e.g.
Gaussian, or all four types rolled together against a shared budget); the
engine's own choice (`Spawner.spawnFleet`,
`Sources/EVNovaEngine/Spawner.swift:148-149`) is a plain independent uniform
roll per escort type, `world.rng.int(in: min...max(min,max))`, which is the
natural reading of "the minimum/maximum number of each type" but not something
the Bible spells out mechanically.

## 3. `LinkSyst` targeting semantics

> "Which systems the fleet can be created in: -1 Any system · 128-2175 ID of a
> specific system · 10000-10255 Any system belonging to this specific
> government · 15000-15255 Any system belonging to an ally of this govt ·
> 20000-20255 Any system belonging to any but this govt · 25000-25255 Any
> system belonging to an enemy of this govt"

| Raw range | Meaning | Decode rule |
|---|---|---|
| `-1` | Any system in the galaxy | sentinel |
| `128`–`2175` | One specific `sÿst` id | value used directly as a system id |
| `10000`–`10255` | Any system whose `sÿst.Govt` is this specific government | `govtID = value - 10000` |
| `15000`–`15255` | Any system belonging to a government **allied with** this govt | `govtID = value - 15000`; test via govt's ally-class list |
| `20000`–`20255` | Any system belonging to **any government but** this one | `govtID = value - 20000`; negate an equality test |
| `25000`–`25255` | Any system belonging to a government **hostile to** this govt | `govtID = value - 25000`; test via govt's enemy-class list |

The "govt" in each banded range (10000/15000/20000/25000 + govt id) is *not*
the fleet's own `Govt` field — it's an independent govt id encoded in the
`LinkSyst` value itself, letting a fleet's spawn-eligibility reference a
*different* government than the one the fleet fights for (e.g. a pirate fleet
with `Govt = Pirates` but `LinkSyst = 25000 + Federation id`, meaning "spawn in
systems hostile to the Federation," which could be a third faction's space).
The ally/enemy tests are exactly the class-membership relations already
decoded on `gövt` (`GovtRes.allies`/`.enemies`,
`Sources/EVNovaKit/NovaAIModels.swift:234-237`) and already evaluated by
`Diplomacy.areAllied`/`Diplomacy.considersHostile`
(`Sources/EVNovaEngine/Diplomacy.swift:70-84`) — no new relational logic would
be needed to implement `LinkSyst`, only a lookup that walks all known systems'
`government` field through those same two functions.

**How this interacts with §0's negative-id convention.** As currently
authored, real stock data (Alphara #131, Nesre Secundus #133) hard-codes a
specific `flët` id directly into that system's own `DudeTypes` slot — i.e. the
system-side spawn table already pins exactly which fleets are eligible there,
independent of whatever the fleet's own `LinkSyst` says. That raises an open
question the Bible text doesn't resolve (see §8): is `LinkSyst` a **second,
redundant validity check** the engine runs before honoring a system's
explicit reference to a fleet (so a plugin author's dude-table entry could be
silently ignored if it violates the fleet's own `LinkSyst`), or is it used for
some *other*, `-1`/wildcard-only case where a fleet is expected to appear
across many systems without being individually listed in each of their spawn
tables (in which case per-system spawn-table wiring alone, as currently
implemented, would systematically miss those fleets)? Nothing in the engine
resolves this today — `linkSystem` is decoded and then never read (§7).

## 4. `AppearOn` gating and the hyperspace-arrival `Quote`

- **`AppearOn`** is the same "control bit test expression" family as `spöb`'s
  `Visibility` field (lines 3072-3079, same section) and as the `mïsn`/`crön`
  TEST-expression grammar already implemented for the story layer
  (`NCBTest`, `Sources/EVNovaStory/NCBExpression.swift:17-40` — bit refs
  `bNNN`, `&`/`|`/`!`/parens, evaluated against an `NCBTestContext`). It's
  blank-means-always-eligible ("If this field is left blank it will be
  ignored"), not blank-means-never. The parser/evaluator for this grammar
  already exists in `EVNovaStory` — wiring `flët.AppearOn` up is a decode +
  plumbing task (read the string, hand it to `NCBTest`, evaluate against
  `PlayerState`), not a new-grammar task.
- **`Quote`** fires once, at the moment the fleet "enters from hyperspace" —
  i.e. only for edge/jump-in arrivals, not for `.interior` (initial system
  fill) or `.planet` (launch) spawns in `Spawner`'s own vocabulary
  (`Spawner.SpawnOrigin`, `Sources/EVNovaEngine/Spawner.swift:50`). It's a
  `STR#`-id reference, and the Bible calls out one piece of text
  substitution: literal `#` characters in the chosen string get replaced with
  a random digit 0-9 (e.g. for a squadron call-sign like "Patrol Wing #-#").
  Contrast this with `gövt.MediumName`'s documented use in "Sensors detect xxx
  reinforcement fleet approaching" (line 1144) — that's the *reinforcement*
  arrival string (government-name-driven, no `STR#`/`Quote` lookup), a
  separate text path from a regular `flët`'s `Quote`.
- **`Flags 0x0001`** (random cargo on freighters with `InherentAI <= 2` when
  boarded) is a boarding-mechanic detail; this engine doesn't model boarding
  at all yet (noted already in AI_GROUND_TRUTH's interceptor section), so
  there's nothing to wire this flag into today.

## 5. Relationship to reinforcement fleets

[AI_GROUND_TRUTH.md](AI_GROUND_TRUTH.md) §2/§6-item-1 already covers the
*combat-odds* half of this (`gövt.MaxOdds`, `AIBrain.favorableOdds`) in depth
— not re-derived here. What's worth adding, specific to the fleet-spawn
question this doc is about: **the reactive reinforcement-fleet-summon
mechanism itself has no decode path at all.** `sÿst.ReinfFleet` /
`ReinfTime` / `ReinfIntrval` are not fields on `SystRes` (§1 table) — only
`x`, `y`, `links`, `spobs`, `spawns`, `averageShips`, and `government` are
decoded, all at byte offsets ≤102, and the Bible places `ReinfFleet` well
after those (following `AstTypes`, near the end of the resource). So today:

- `AIBrain.favorableOdds` (`Sources/EVNovaEngine/AIBrain.swift:163-182`)
  correctly gates whether an *already-present* warship/interceptor picks a
  fight — the "before you charge in, weigh the odds" half.
- There is **no** implementation of "and if the odds are already bad and
  allies are under attack, summon `sÿst.ReinfFleet` after `ReinfTime` delay,
  regenerating every `ReinfIntrval` days" — the *reactive, dynamic
  second-wave* half. `Spawner` only ever draws from the static per-system
  `SpawnTable` built once at system entry (`GameSession.swift:47`); nothing
  calls back into it mid-combat.

These are genuinely two different systems in the Bible (a fleet that's part
of ambient background population vs. a fleet that's specifically summoned as
backup for allies losing a fight), and only the "should this ship engage"
gating half of the second system is implemented.

## 6. Full "fleet" grep — cross-references outside `flët`/`sÿst`

24 case-insensitive hits total (the Bible is stored as extended-ASCII with
CRLF; a plain `grep -i` without `-a` reports it as binary and finds nothing —
worth noting for anyone re-running this). Grouped:

| Location | What it says |
|---|---|
| Part I "Game Constants" (line 65) | `Max Fleets  256` — a hard cap on the number of distinct `flët` resources a scenario/plugin set may define |
| `flët` section (886-932) | The resource itself (§2 above) |
| `gövt.MediumName` (1144) | Used in "Sensors detect xxx reinforcement fleet approaching" (§4 above) |
| `spöb.DefenseDude`/`DefCount` (2881-2896) | A **different**, unrelated "fleet" concept: a stellar object's own defense-ship wave-launch system (already noted as a distinct mechanism in [AI_GROUND_TRUTH.md](AI_GROUND_TRUTH.md) §4 item 14 — not a `flët` reference at all, no escort/Min/Max/LinkSyst fields, just a `düde` id + packed wave-count digits) |
| `sÿst.ReinfFleet`/`ReinfTime`/`ReinfIntrval` (3115-3132) | §5 above |

No hits inside `gövt`, `düde`, or `përs` sections beyond what's already listed
— the brief's concern about missing a cross-reference in `spöb`/`gövt` turned
out to be the `DefenseDude` hit above, which is adjacent-but-distinct rather
than a `flët` reference.

## 7. What's implemented vs. what's missing

| Bible spec | Status | Where |
|---|---|---|
| Lead ship + up to 4 escort types w/ independent min/max | ✅ implemented | `FleetRes` decode (`NovaAIModels.swift:364-379`); `Spawner.spawnFleet` rolls each escort count independently uniform-in-range (`Spawner.swift:147-150`) |
| Fleet-wide `Govt` (or -1/none → fall back) | ✅ implemented, reasonable fallback | `Spawner.swift:134-135`: `govt >= 128 ? govt : (leadShip's govt ?? system's govt)` — not documented as the exact fallback order, but a sensible reading of "-1 for none" |
| Lead ship flies its own hull's inherent AI, not a fixed disposition | ✅ implemented, and *better* than a naive reading — Bible doesn't say this explicitly but it's consistent with `düde.AIType 0` "use the ship's own inherent AI" | `Spawner.swift:142-143` |
| Escorts fly their own hull's inherent AI + hold formation slot | ✅ implemented (not Bible-specified either way) | `Spawner.swift:159-166`; formation math in `AIBrain.escort` (`AIBrain.swift:452-473`) |
| `LinkSyst` (which systems a fleet may spawn in) | ⚠️ **decoded but dead** — `FleetRes.linkSystem` is parsed and then never read by `Spawner` or anything else. Eligibility today is entirely implicit: whichever `flët` ids a given `sÿst`'s own spawn table happens to list (§0/§3) | `NovaAIModels.swift:362,378`; confirm via `grep -rn linkSystem Sources/` — zero call sites |
| `AppearOn` control-bit gate | ❌ not decoded, not evaluated. The `NCBTest` evaluator it needs already exists (`NCBExpression.swift`) but nothing decodes the field or calls it for fleets | n/a |
| `Quote` (hyperspace-arrival STR# text, `#`→digit) | ❌ not decoded, no arrival-text event exists in `Spawner`/`World` at all for *any* spawn origin, fleet or dude | n/a — `Spawner.spawnPose` (`Spawner.swift:174-195`) returns an `ArrivalMode` (`.hyperspace`/`.launch`/`.populate`) that only drives visual/audio arrival *effects*, no text |
| `Flags 0x0001` (random cargo on freighters when boarded) | ❌ not decoded; boarding isn't modeled in this engine at all | n/a |
| `sÿst.AvgShips` "+/- 50%" live variance | ⚠️ partially implemented — `targetPopulation` derives once from `averageShips` (`min(maxPopulation, avg+2)`) but is a fixed number for the system's lifetime, not re-rolled per Bible's "+/- 50%" phrasing, and the `+2`/`maxPopulation=18` constants are the engine's own invention, not from the Bible | `Spawner.swift:36,44-45` |
| `sÿst.DudeTypes`/`%Prob` weighted background traffic | ✅ implemented, matches the weighted-pick semantics | `Spawner.spawnOne`/`weightedPick` (`Spawner.swift:76-105`); `SystRes.dudeSpawns` (`NovaModels.swift:332-334`) |
| `sÿst.ReinfFleet`/`ReinfTime`/`ReinfIntrval` (reactive reinforcement summon) | ❌ not decoded on `SystRes`, no reactive spawn-on-bad-odds mechanism exists; only the *pre-fight gating* half (`gövt.MaxOdds`) is implemented (see §5, and [AI_GROUND_TRUTH.md](AI_GROUND_TRUTH.md) §6 item 1) | n/a |
| Fleets always arrive as a group at the hyperspace edge (never mid-system or launched from a planet) | ✅ implemented as a deliberate restriction | `Spawner.spawnOne`: `if origin != .planet, roll < fleetWeight` (`Spawner.swift:85`) — not from the Bible text (which doesn't say fleets *can't* appear via other origins), but a defensible reading of "enters from hyperspace" in the `Quote` field's own wording |
| A ship-count cap so escorts can't overflow the system | ⚠️ engine invention, not in the Bible | `Spawner.swift:151`: `guard world.npcs.count < maxPopulation else { return }` mid-escort-loop — can silently truncate a fleet's escort count if the system is near its cap, with no Bible-documented equivalent behavior (real Nova likely has its own "Max Ships On Screen"-style constant not captured in this doc's source range) |

## 8. Open questions the Bible prose alone doesn't resolve

1. **Exact byte offsets for `AppearOn`/`Quote`/`Flags`** in the `flët`
   resource past byte 30 — no vendored source (novaparse, ResForge) decodes
   this resource at all; would need either a `TMPL` resource dump from a real
   `.rez`/plugin, or `EV Nova.exe` disassembly.
2. **`LinkSyst` vs. per-system spawn-table wiring** (§3): does `LinkSyst`
   gate/validate what a system's own `DudeTypes` table already pins, or does
   it independently drive spawn eligibility for fleets that *aren't*
   individually listed in any system's table (e.g. `LinkSyst = -1` "any
   system" fleets that never appear in a `DudeTypes` slot at all, and would
   need the engine to sweep all `flët` resources against every system's govt
   whenever it decides what to spawn)? If the latter, the current
   `SpawnTable(system:)` construction (`GameSession.swift:47`, built solely
   from one system's own `spawns`) would systematically never surface those
   fleets, regardless of how `LinkSyst` gets wired up later.
3. **Escort-count roll distribution**: independent uniform per type (current
   engine choice) vs. some other original-game distribution — Bible doesn't
   say.
4. **The negative-id-means-fleet convention itself** (§0) — empirically
   confirmed against real stock data via `evnova-extract ai`, but not stated
   anywhere in the Bible's own `DudeTypes` field description; worth treating
   as "very likely correct, unverified from prose" rather than a quoted spec.
