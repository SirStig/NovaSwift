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

## Implementation status (updated since this doc was first written)

This doc was originally written as a pure reverse-engineering pass, and §7
recorded almost every field in this area as undecoded or unwired. A follow-up
implementation pass has since landed in `Spawner.swift`, `NovaModels.swift`,
and `NovaAIModels.swift`. Confirmed by reading the current code and running
`swift build` (clean success, no errors):

- **`flët.LinkSyst` is now implemented and wired**, not just decoded.
  `Spawner.isFleetEligible` (`Spawner.swift:158-193`) evaluates all five
  documented bands (`-1`/specific-system/govt/ally/enemy, §3) and filters
  ambient spawn-table fleets by it before they're allowed to jump in. This
  answers §8 open question 2 in one specific direction: the engine now
  treats `LinkSyst` as **a second validity check layered on top of a
  system's own explicit `DudeTypes` reference** (interpretation A), not as
  an independent sweep that would surface `LinkSyst = -1`/wildcard fleets
  never individually listed in any system's spawn table (interpretation B,
  still unimplemented — see updated §8 note).
- **`sÿst.ReinfFleet`/`ReinfDelay`/`ReinfRegen` are now decoded on `SystRes`
  and implemented end-to-end.** `SpawnTable` carries all three
  (`Spawner.swift:16-23`), and `Spawner.updateReinforcements`
  (`Spawner.swift:204-229`) implements the reactive mechanism the Bible and
  AI_GROUND_TRUTH.md §2 describe: when a government's ships present in the
  system are under fire and outmatched per its own `gövt.MaxOdds`
  (`governmentUnderAttackAndOutmatched`, `Spawner.swift:241-267`, a
  system/government-granularity sibling of `AIBrain.favorableOdds`), the
  reinforcement fleet is summoned after its frame delay and regen-gated
  afterward. This closes the gap AI_GROUND_TRUTH.md §2 flagged — see the
  note added there.
- **`flët.AppearOn`/`Quote`(now `hailQuote`)/`Flags`(now
  `freightersHaveRandomCargo`) are now *decoded* on `FleetRes`** (real byte
  offsets, confirmed earlier against TMPL #506) **but still not consulted
  anywhere** — `grep -rn "appearOn\|hailQuote\|freightersHaveRandomCargo"
  Sources/` turns up only the property declarations and the `init` that
  populates them; no call site evaluates `appearOn` against `NCBTest`, no
  arrival-text event exists to read `hailQuote`, and there's still no
  boarding mechanic for `freightersHaveRandomCargo` to attach to. Decoding a
  field and acting on it are different states — these three are the former,
  not the latter.

The updated §7 table below reflects all three. The Bible quotes, byte-offset
findings, and open questions elsewhere in this doc are unchanged from the
original pass except where explicitly noted inline.

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
`Sources/NovaSwiftKit/NovaModels.swift:323-338`) resolves this by convention: a
**negative** value in a `DudeTypes` slot is read as `-value` = a `flët` id
(`fleetSpawns`), while a positive value ≥128 is a `düde` id (`dudeSpawns`).
This is a reasonable, and empirically-confirmed, inference — running
`novaswift-extract ai "data/EV Nova" <sysID> 1` against the real Nova.rez data
shows most Federation-space systems reporting `8 dude(s), 0 fleet(s)`, but
Alphara (#131) and Nesre Secundus (#133) report `7 dude(s), 1 fleet(s)` out of
the same 8 total slots — i.e. real stock data does mix negative (fleet) and
positive (dude) values in the same 8-slot table. The Bible text itself never
documents this sign convention, though; it's worth keeping in mind as an
inference validated by data, not a quoted spec, if a future disassembly pass
turns up a different rule (e.g. a separate flag bit rather than sign).

## 1. `sÿst` fields governing traffic/density (lines 3002–3132)

Full field list, in Bible order, with what's decoded in `SystRes`
(`Sources/NovaSwiftKit/NovaModels.swift:316-360`) noted per row:

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
| `ReinfFleet`, `ReinfTime`, `ReinfIntrval` | Reinforcement-fleet id/delay/regen interval — see [AI_GROUND_TRUTH.md](AI_GROUND_TRUTH.md) | ✅ decoded as `reinforcementFleet`/`reinforcementDelay`/`reinforcementRegen` @406-410 (`NovaModels.swift:392-441`) and wired to a live reactive-summon mechanism — see §5 below (updated) |

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
`averageShips` (`Sources/NovaSwiftEngine/Spawner.swift:44-45`), and
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
| `LinkSyst` | "Which systems the fleet can be created in" (ranges — see §3) | ✅ decoded as `linkSystem` @28 **and now read** by `Spawner.isFleetEligible` — see §7 (updated) |
| `AppearOn` | "A control bit test field that will cause a given fleet to appear only when the expression evaluates to true. If this field is left blank it will be ignored" | ✅ decoded as `appearOn` (`FleetRes.swift`/`NovaAIModels.swift:425,453`), offset `@30`, a 256-byte NCB test string — **still never read anywhere in `Spawner` or elsewhere**, see §7 (updated) |
| `Quote` | "Show a random string from the STR# resource with this ID when the fleet enters from hyperspace. Any occurrences of the character '#'… will be replaced with a random digit (0-9)" | ✅ decoded as `hailQuote` @286 (`RSID`, 2 bytes) — **still never read anywhere**, no arrival-text event exists, see §7 (updated) |
| `Flags` | `0x0001`: "Freighters (`InherentAI <= 2`) in this fleet will have random cargo when boarded" | ✅ decoded as `flags` @288 (`WORV`, 2 bytes) with a computed `freightersHaveRandomCargo` property — **still never read anywhere**; boarding isn't modeled, see §7 (updated) |

`FleetRes.init` (`Sources/NovaSwiftKit/NovaAIModels.swift:440-455`) now reads
through byte 288 (`appearOn`, `hailQuote`, `flags`), not just bytes 0–29 as
when this doc was first written. Decoding `flët`'s real TMPL (TMPL #506 in
`third_party/ResForge/Plugins/Sources/NovaTools/Templates.rsrc`, via the
now-fixed `novaswift-extract tmpl`) gave `AppearOn@30`(`n100`= a 256-byte NCB
test string, not a short field — much bigger than the 2-byte slot one might
guess), `HailQuote@286`(`RSID`, 2B — this is the Bible's `Quote` field, named
`Hail Quote` in the template), `Flags@288`(`WORV`, 2B), then 16 bytes of
declared-`Unused` padding to a total of **306 bytes**. Confirmed against
`swift run novaswift-extract raw "data/EV Nova" flët 128` ("Small Federation
Fleet"): real size is exactly 306 bytes, `LinkSyst@28=10000` (="any system of
this fleet's own government" per §3's offset convention, `10000 + govtIndex`,
consistent with `AffilGovt@26=128`= Federation, index 0), and `AppearOn`/
`HailQuote`/`Flags` all read `0` (blank/unused) for this particular fleet —
consistent with "if this field is left blank it will be ignored." A fleet
using a non-blank `AppearOn` or `Quote` would need a scenario/plugin search
to find a worked example; not attempted here. **Decoding these three fields
is now done; evaluating/acting on them (the "wiring" half) is still entirely
outstanding** — see §4 and §7 (updated).

**Escort count roll.** The Bible doesn't state whether each escort count is
independently rolled uniformly in `[Min, Max]` or something else (e.g.
Gaussian, or all four types rolled together against a shared budget); the
engine's own choice (`Spawner.spawnFleet`,
`Sources/NovaSwiftEngine/Spawner.swift:148-149`) is a plain independent uniform
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
`Sources/NovaSwiftKit/NovaAIModels.swift:234-237`) and already evaluated by
`Diplomacy.areAllied`/`Diplomacy.considersHostile`
(`Sources/NovaSwiftEngine/Diplomacy.swift:70-84`) — no new relational logic would
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
  (`NCBTest`, `Sources/NovaSwiftStory/NCBExpression.swift:17-40` — bit refs
  `bNNN`, `&`/`|`/`!`/parens, evaluated against an `NCBTestContext`). It's
  blank-means-always-eligible ("If this field is left blank it will be
  ignored"), not blank-means-never. The parser/evaluator for this grammar
  already exists in `NovaSwiftStory`, and the **decode half is now done**
  (`FleetRes.appearOn`, §2) — but the **plumbing half is still outstanding**:
  nothing calls `NCBTest` on it or gates `Spawner.isFleetEligible`/spawn
  selection with the result, so a fleet with a non-blank `AppearOn` would
  spawn exactly as freely as one without today.
- **`Quote`** (now decoded as `FleetRes.hailQuote`, §2) fires once, at the
  moment the fleet "enters from hyperspace" — i.e. only for edge/jump-in
  arrivals, not for `.interior` (initial system fill) or `.planet` (launch)
  spawns in `Spawner`'s own vocabulary (`Spawner.SpawnOrigin`,
  `Sources/NovaSwiftEngine/Spawner.swift:93`). It's a `STR#`-id reference, and
  the Bible calls out one piece of text substitution: literal `#` characters
  in the chosen string get replaced with a random digit 0-9 (e.g. for a
  squadron call-sign like "Patrol Wing #-#"). Contrast this with
  `gövt.MediumName`'s documented use in "Sensors detect xxx reinforcement
  fleet approaching" (line 1144) — that's the *reinforcement* arrival string
  (government-name-driven, no `STR#`/`Quote` lookup), a separate text path
  from a regular `flët`'s `Quote`. **The value is decoded but there is still
  no arrival-text event anywhere in `Spawner`/`World` for any spawn origin**
  — `hailQuote` is read into `FleetRes` and never looked at again.
- **`Flags 0x0001`** (random cargo on freighters with `InherentAI <= 2` when
  boarded) is a boarding-mechanic detail; the flag is now decoded as
  `FleetRes.freightersHaveRandomCargo`, but this engine still doesn't model
  boarding at all (noted already in AI_GROUND_TRUTH's interceptor section),
  so there's nothing for the flag to be consulted by today.

## 5. Relationship to reinforcement fleets

[AI_GROUND_TRUTH.md](AI_GROUND_TRUTH.md) §2/§6-item-1 already covers the
*combat-odds* half of this (`gövt.MaxOdds`, `AIBrain.favorableOdds`) in depth
— not re-derived here. **Update: the reactive reinforcement-fleet-summon
mechanism described below is no longer just a gap — it's implemented.**
`sÿst.ReinfFleet`/`ReinfDelay`/`ReinfRegen` are now fields on `SystRes` (§1
table, `NovaModels.swift:392-441`), threaded through `SpawnTable`
(`Spawner.swift:16-23`), and acted on by `Spawner.updateReinforcements`
(`Spawner.swift:204-229`, detailed below the byte-offset findings). The
paragraphs immediately below, describing the byte offsets, are the original
(still-accurate) reverse-engineering findings; the "so today" summary that
followed them has been updated to reflect the current implementation.

**Byte offsets now confirmed against real data.** Decoding `sÿst`'s real TMPL
(`third_party/ResForge/Plugins/Sources/NovaTools/Templates.rsrc` TMPL #521,
via the now-fixed `novaswift-extract tmpl`) and cross-checking against
`swift run novaswift-extract raw "data/EV Nova" sÿst 128` ("Kania", 428 bytes,
matching the TMPL's computed total exactly): `ReinfFleet@406`(RSID, 2B),
`ReinfDelay@408`("frames", 2B — the Bible's `ReinfTime`), `ReinfRegen@410`
("days", 2B — the Bible's `ReinfIntrval`), then 16 bytes of declared-`Unused`
padding to 428. Kania's real record has `ReinfFleet=129` (a real, non-`-1`
`flët` index — this system genuinely uses the mechanism),
`ReinfDelay=900`(frames, = 30s at the Bible's "30 = one second" convention
from the `AIBrain`/jamming docs), `ReinfRegen=2`(days). So today:

- `AIBrain.favorableOdds` (`Sources/NovaSwiftEngine/AIBrain.swift:163-182`)
  correctly gates whether an *already-present* warship/interceptor picks a
  fight — the "before you charge in, weigh the odds" half. Unchanged by this
  update.
- **The reactive, dynamic second-wave half is now implemented.**
  `Spawner.updateReinforcements` (`Spawner.swift:204-229`) is called every
  tick (`Spawner.update`, `Spawner.swift:106-118`) and, once a govt with a
  configured `reinforcementFleet` has a friendly ship under fire and
  outmatched per its own `gövt.MaxOdds`
  (`governmentUnderAttackAndOutmatched`, `Spawner.swift:241-267` — a
  system/government-granularity sibling of `AIBrain.favorableOdds`, not a
  reuse of it, since it's answering "should the *system* call for backup"
  rather than "should *I* personally engage"), it schedules the
  reinforcement fleet to arrive after `ReinfDelay` frames (converted via
  `galaxy.combatTuning.framesPerSecond`) and then honors `LinkSyst`
  eligibility (§3/§7) before actually spawning it at the hyperspace edge.
  `ReinfRegen`'s "days" unit is approximated as a fixed number of sim-seconds
  (`secondsPerReinforcementDay = 60`, `Spawner.swift:82`) since no galaxy-day
  calendar clock is threaded into combat simulation at this layer (that
  lives one layer up, in `NovaSwiftStory.GameDate`) — a documented engine
  approximation, not a byte-verified constant, worth flagging alongside the
  other engine inventions in §7's table.
  `Spawner` still only draws ambient/fleet arrivals from the static
  per-system `SpawnTable` built once at system entry — the reinforcement
  path is the one exception where something now calls back into fleet
  spawning mid-combat, outside that static table's normal draw loop.

These are genuinely two different systems in the Bible (a fleet that's part
of ambient background population vs. a fleet that's specifically summoned as
backup for allies losing a fight); as of this update, **both** the "should
this ship engage" gating half and the "should the system summon backup"
reactive half are implemented.

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
| `LinkSyst` (which systems a fleet may spawn in) | ✅ **implemented and wired** — `FleetRes.linkSystem` is decoded and now read by `Spawner.isFleetEligible` (`Spawner.swift:158-193`), evaluated for every ambient fleet draw (`spawnOne`, `Spawner.swift:130`) and for the reinforcement fleet before it's summoned (`updateReinforcements`, `Spawner.swift:210`). All five documented bands (`-1`, specific-system, govt, ally, enemy) are handled; the ally/enemy bands reuse `Diplomacy.areAllied`/`.areEnemies` per §3's own analysis. Note: the engine resolved §8 open question 2 as "second validity check on top of a system's own `DudeTypes` reference," not as an independent sweep for unlisted `LinkSyst = -1` fleets — see updated §8 | `NovaAIModels.swift:425` (decode); `Spawner.swift:158-193` (consult) — confirm via `grep -rn linkSystem Sources/`, no longer zero call sites |
| `AppearOn` control-bit gate | ⚠️ **decoded but not wired** — `FleetRes.appearOn` now reads the real 256-byte NCB test string (§2), but nothing evaluates it. The `NCBTest` evaluator it needs already exists (`NCBExpression.swift`) and would slot into `Spawner.isFleetEligible` alongside the `LinkSyst` check, but no call site does that yet — every fleet is treated as always-eligible regardless of `appearOn`'s contents. **Offset confirmed: `@30`, 256-byte NCB string** — see §2 | `NovaAIModels.swift:425,453` (decode); zero consult call sites |
| `Quote` (hyperspace-arrival STR# text, `#`→digit) | ⚠️ **decoded but not wired** — `FleetRes.hailQuote` now reads the real `RSID`, but there is still no arrival-text event anywhere in `Spawner`/`World` for *any* spawn origin, fleet or dude, to read it into. **Offset confirmed: `@286`, `RSID`** — see §2 | `NovaAIModels.swift:429,454` (decode); `Spawner.spawnPose` (`Spawner.swift:346-367`) returns an `ArrivalMode` (`.hyperspace`/`.launch`/`.populate`) that only drives visual/audio arrival *effects*, no text — zero consult call sites |
| `Flags 0x0001` (random cargo on freighters when boarded) | ⚠️ **decoded but not wired** — `FleetRes.flags`/`freightersHaveRandomCargo` now read the real `WORV` bit, but boarding isn't modeled in this engine at all, so there's nothing for the flag to feed into. **Offset confirmed: `@288`, `WORV`** — see §2 | `NovaAIModels.swift:432,436,455` (decode); zero consult call sites |
| `sÿst.AvgShips` "+/- 50%" live variance | ⚠️ partially implemented — `targetPopulation` derives once from `averageShips` (`min(maxPopulation, avg+2)`) but is a fixed number for the system's lifetime, not re-rolled per Bible's "+/- 50%" phrasing, and the `+2`/`maxPopulation=18` constants are the engine's own invention, not from the Bible | `Spawner.swift:87-88` |
| `sÿst.DudeTypes`/`%Prob` weighted background traffic | ✅ implemented, matches the weighted-pick semantics | `Spawner.spawnOne`/`weightedPick` (`Spawner.swift:122-147,269-277`); `SystRes.dudeSpawns` (`NovaModels.swift:332-334`) |
| `sÿst.ReinfFleet`/`ReinfTime`/`ReinfIntrval` (reactive reinforcement summon) | ✅ **implemented and wired** — decoded on `SystRes` and threaded through `SpawnTable` into `Spawner.updateReinforcements` (`Spawner.swift:204-229`), which detects a friendly-under-fire-and-outmatched condition (`governmentUnderAttackAndOutmatched`, `Spawner.swift:241-267`, gated by the govt's own `MaxOdds`) and summons the fleet after `ReinfDelay`, regen-gated by `ReinfRegen`. Both the *pre-fight gating* half (`gövt.MaxOdds` via `AIBrain.favorableOdds`) and this *reactive-summon* half are now implemented (see §5, and [AI_GROUND_TRUTH.md](AI_GROUND_TRUTH.md) §6 item 1/§2 note). One caveat: `ReinfRegen`'s "days" unit is approximated as a fixed 60 sim-seconds/day (`Spawner.swift:82`) since no galaxy-day calendar clock reaches this layer — an engine invention, not a Bible-verified conversion. **Offsets confirmed: `ReinfFleet@406`, `ReinfDelay@408`, `ReinfRegen@410`** — see §5; real system #128 "Kania" has a live, non-`-1` reinforcement fleet configured, proving this was a genuine live-data feature, not a theoretical one | `NovaModels.swift:392-441` (decode); `Spawner.swift:16-23,204-229,241-267` (consult) |
| Fleets always arrive as a group at the hyperspace edge (never mid-system or launched from a planet) | ✅ implemented as a deliberate restriction | `Spawner.spawnOne`: fleets are excluded from `eligibleFleets` when `origin == .planet` (`Spawner.swift:130`) — not from the Bible text (which doesn't say fleets *can't* appear via other origins), but a defensible reading of "enters from hyperspace" in the `Quote` field's own wording |
| A ship-count cap so escorts can't overflow the system | ⚠️ engine invention, not in the Bible | `Spawner.swift:323`: `guard world.npcs.count < maxPopulation else { return }` mid-escort-loop — can silently truncate a fleet's escort count if the system is near its cap, with no Bible-documented equivalent behavior (real Nova likely has its own "Max Ships On Screen"-style constant not captured in this doc's source range) |

## 8. Open questions the Bible prose alone doesn't resolve

1. ~~Exact byte offsets for `AppearOn`/`Quote`/`Flags`~~ — **resolved**, see
   §2 and §7. `third_party/ResForge/Plugins/Sources/NovaTools/Templates.rsrc`
   turned out to have the authoritative `flët`/`sÿst` field layouts (TMPL
   #506/#521) all along; `novaswift-extract tmpl` just computed their offsets
   wrong (didn't multiply `Rnnn` repeat groups, didn't size several field
   types) until fixed in this pass. Confirmed against real `flët #128` and
   `sÿst #128` records via `novaswift-extract raw`.
2. **`LinkSyst` vs. per-system spawn-table wiring** (§3): does `LinkSyst`
   gate/validate what a system's own `DudeTypes` table already pins, or does
   it independently drive spawn eligibility for fleets that *aren't*
   individually listed in any system's table (e.g. `LinkSyst = -1` "any
   system" fleets that never appear in a `DudeTypes` slot at all, and would
   need the engine to sweep all `flët` resources against every system's govt
   whenever it decides what to spawn)? If the latter, the current
   `SpawnTable(system:)` construction (`GameSession.swift:47`, built solely
   from one system's own `spawns`) would systematically never surface those
   fleets, regardless of how `LinkSyst` gets wired up later. **Still open
   against the original game's actual behavior** — but the engine has since
   made an implementation choice here (not a Bible-sourced answer):
   `Spawner.isFleetEligible` (§7) treats `LinkSyst` as the "gate/validate"
   reading only, run as a filter on top of whatever a system's own
   `DudeTypes`/`ReinfFleet` already reference. It does **not** implement the
   "independent sweep" reading — a `LinkSyst = -1` fleet that isn't listed in
   any system's spawn table still never spawns anywhere, which is exactly
   the failure mode this open question predicted if that reading turns out
   to be the correct one.
3. **Escort-count roll distribution**: independent uniform per type (current
   engine choice) vs. some other original-game distribution — Bible doesn't
   say.
4. **The negative-id-means-fleet convention itself** (§0) — empirically
   confirmed against real stock data via `novaswift-extract ai`, but not stated
   anywhere in the Bible's own `DudeTypes` field description; worth treating
   as "very likely correct, unverified from prose" rather than a quoted spec.
