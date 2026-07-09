# Government, legal status & rank — reverse-engineered from the Nova Bible

Source: `Documentation/Nova Bible.txt` (the official EV Nova plugin-developer
"Resource Bible", ©1995-2004 Ambrosia Software / Matt Burch), read in full for
the `gövt` resource (lines 932–1163), the `ränk` resource (lines 2252–2344),
Appendix I — Combat Ratings (~3518–3543), Appendix II — Legal Status
(~3543–3577), and the control-bit/NCB primer (~97–229). Every quoted line
below is verbatim or a close paraphrase of that text, not a guess.

This doc does **not** re-derive:
- `gövt.MaxOdds` combat-odds gating — see [AI_GROUND_TRUTH.md](../AI_GROUND_TRUTH.md#2-combat-odds-gating-gövtmaxodds--completely-missing-from-our-sim),
  referenced briefly below where legal status interacts with it.
- `ränk`'s exact on-disk byte layout and the NCB test/set grammar — both are
  tabulated in [MISSIONS.md](../MISSIONS.md#ränk--152-bytes) and
  [MISSIONS.md](../MISSIONS.md#the-ncb-scripting-language); only the *fields'
  meaning*, not their offsets, is repeated here.
- Ship/outfit stat aggregation — see [SHIP_SYSTEM.md](../SHIP_SYSTEM.md).

## 1. The `gövt` resource — government relations model

> "A govt resource defines the parameters for a government, which is in turn
> defined as 'any collection of ships and planets that react collectively to
> the actions of the player and other ships.' Governments keep track of how
> they feel toward you, and they can also have set enemies and allies."

### 1.1 Numeric fields

| Field | Meaning (Bible text) |
|---|---|
| `VoiceType` | Which of 8 voice sets (comm sounds `1000+`) a govt's escorted ships use; `-1` = silent. |
| `CrimeTol` | "The maximum amount of evilness the player can accumulate before warships of this govt start to beat on him." |
| `ScanFine` | Fine when caught with illegal/mission cargo *while not yet evil enough to be attacked*. `>=1` = flat fine; `0` = warning only; `<=-1` = that % of the player's cash (`-5` = 5%). |
| `SmugPenalty` | Evilness gained for being *detected smuggling* illegal cargo (a `mïsn`-defined cargo) past this govt's ships. |
| `DisabPenalty` | Evilness for disabling one of this govt's ships. |
| `BoardPenalty` | Evilness from pirating (boarding) one of this govt's ships. |
| `KillPenalty` | Evilness from killing this govt's ships. |
| `ShootPenalty` | Evilness from shooting one of this govt's ships — **"currently ignored"** (the Bible says so explicitly; not a live mechanic in the original game). |
| `InitialRec` | Player's starting legal record with this govt (0 neutral, + good, − bad) — superseded per-pilot by `chär.Govt1-4/Status1-4` (see §5's `PilotFactory.initialLegalRecord` note). |
| `MaxOdds` | Combat-odds gate — see linked doc above. |
| `Class1-Class4` | "Arbitrary groupings of govts" this govt itself belongs to. |
| `Ally1-Ally4` | Classes *this* govt declares itself allied with. |
| `Enemy1-Enemy4` | Classes *this* govt declares itself enemies with. |
| `Interface` | `ïntf` resource id used when the player flies a ship whose inherent govt equals this govt (values `<128` clamp to 128). |
| `NewsPic` | News-window background PICT when landed on this govt's turf; `<128` falls back to generic (PICT 9000). |
| `SkillMult` | Global pilot-skill multiplier for this govt's ships (100 = normal, 50 = half as skilled, 150 = 50% more skilled); values `<1` ignored. |
| `ScanMask` | 16-bit mask; if it shares a set bit with a `mïsn`'s `ScanMask`, this govt considers that mission's cargo illegal. `0` = unused. |
| `Require` (2×32-bit → 64-bit) | AND'ed against the player's ship+outfit `Contribute` bits; unmet ⇒ **can't land on any planet/station of this govt at all** — "useful for making travel permits." |
| `InhJam1-4` | Inherent jamming (0–100%) per of 4 jam types — see [AI_GROUND_TRUTH.md §4.10](../AI_GROUND_TRUTH.md) for how this interacts with targeting/guided weapons. |
| `MediumName` | Medium-length name, used in "Sensors detect *xxx* reinforcement fleet approaching." |
| `Color` / `ShipColor` | HTML-style theme colors for UI / ship paint. |
| `CommName` | Short name shown when the player hails a ship of this govt. |
| `TargetCode` | Short string shown in the target display. |

### 1.2 Relations model — worked semantics

Two governments are **not** symmetric by default. Each govt declares:
- which arbitrary `Class` tags it *carries* (`Class1-4`),
- which `Class` tags it treats as *ally* (`Ally1-4`),
- which `Class` tags it treats as *enemy* (`Enemy1-4`).

Government A is hostile to government B iff **A's `Enemy` classes intersect
B's `Class` tags** — a one-directional declaration. The Bible doesn't state
whether the engine ORs both directions into a symmetric fight/no-fight
decision or strictly honors the declarer's direction only; see §5 for how the
Swift code resolves this (by OR, a defensible but *invented* symmetrization,
since no fight can really be one-sided in a real-time sim).

> "Doing evil deeds to one government will improve your rating with its
> enemies, and vice versa. Allied governments also communicate your actions,
> so attacking one government will make its allies hate you too."

This is the two documented **cross-government propagation rules**:
1. Hurting govt X's standing **raises** your standing with X's declared
   enemies (not just X's allies suffering — this positive-propagation half is
   easy to miss).
2. Hurting X also dents your standing with X's **allies** (they "communicate
   your actions").

Neither the exact magnitude of propagated change nor whether it applies
per-class or per-specific-govt is given a number by the Bible — this is an
open question (see closing summary).

### 1.3 `Flags` bit table (verbatim)

| Bit | Effect |
|---|---|
| `0x0001` | Xenophobic — warships attack everyone except their allies (pirates, etc). |
| `0x0002` | Attacks the player in non-allied systems if he's a criminal *there* (lets a govt police only its own turf, or be nosy everywhere). |
| `0x0004` | Always attacks player. |
| `0x0008` | Player's shots won't hit ships of this govt. |
| `0x0010` | Warships retreat below 25% shields — otherwise fight to the death. |
| `0x0020` | Nosy ships of *other* non-allied governments ignore ships of this govt that are under attack. |
| `0x0040` | Never attacks player (and player's weapons can't hit them). |
| `0x0080` | Freighters (AiTypes 1–2) of this govt have 50% of the InherentJam of this govt's warships (AiType 3). |
| `0x0100` | `pers` ships of this govt won't use an escape pod, but act as if they did. |
| `0x0200` | Warships take bribes. |
| `0x0400` | Can't hail ships of this govt (inherited by ship type if set on its inherent govt). |
| `0x0800` | Ships of this govt start disabled (derelicts) — other govts don't care if you attack/board them. |
| `0x1000` | Warships plunder non-mission, non-player enemies before destroying them. |
| `0x2000` | Freighters take bribes. |
| `0x4000` | Planets of this govt take bribes. |
| `0x8000` | Bribe-takers of this govt demand a larger % of cash; their planets **always** take bribes (pirates). |

### 1.4 `Flags2` bit table (verbatim)

| Bit | Effect |
|---|---|
| `0x0001` | Hailing disables the "request assistance / beg for mercy" button; govt is not talkative. |
| `0x0002` | "Minor" govt — ignored for political-boundary map drawing. |
| `0x0004` | This govt's systems don't affect political boundaries on the map. |
| `0x0008` | Ships don't send distress messages / don't greet when hailed (inherited by ship type). |
| `0x0010` | "Roadside Assistance" — always repairs/refuels the player for free. |
| `0x0020` | Ships don't use hypergates. |
| `0x0040` | Ships prefer hypergates over jumping out. |
| `0x0080` | Ships prefer wormholes over jumping out. |

## 2. Legal status (Appendix II)

> "Your legal status in a system is based on the crime tolerance of that
> system's government. (if the system is independent, it is based on the
> first government's [ID 128] crime tolerance.) On this scale, enough 'good'
> or 'evil' points to equal the government's crime tolerance is given a value
> of 1."

I.e. the tier lookup is a **ratio**, not a raw point count:

```
ratio = |legalRecord[govt]| / govt.CrimeTol      (govt = system's owner, or govt 128 if independent)
tier  = highest table row whose threshold <= ratio, using the Good table if
        legalRecord[govt] > 0, the Evil table if < 0
```

| Good scale (ratio) | Legal status | | Evil scale (ratio) | Legal status |
|---|---|---|---|---|
| 0 | Clean | | 0 | No record |
| 4 | Citizen | | 1 | Minor Offender |
| 16 | Good Citizen | | 4 | Offender |
| 64 | Upstanding Citizen | | 16 | Criminal |
| 256 | Leading Citizen | | 64 | Wanted Criminal |
| 1024 | Model Citizen | | 256 | Fugitive |
| 4096 | Virtuous Citizen | | 1024 | Hunted Fugitive |
| | | | 4096 | Public Enemy |

"The text strings listed above are given only by way of illustration, since
they can be changed by editing STR# 134" (evil) / the Good table shares the
same STR#. The *ratio thresholds themselves* are not configurable per the
Bible text — only the display strings are.

### 2.1 Mechanical consequences the Bible actually specifies

The tier ladder above is purely a **display** label. The actual behavioral
thresholds are separate, per-government fields, all keyed off the same raw
`legalRecord[govt]` point value (not the ratio):

- **Attack threshold**: a govt's warships turn hostile once the player's
  evilness in that govt's systems reaches `CrimeTol` (i.e. ratio ≥ 1 on the
  Evil scale — "Criminal" territory sits well past this in the *display*
  ladder, so a player can be shot at well before the label says "Criminal").
  `Flags 0x0002` (nosy) extends this enforcement into *non-allied* systems
  too, not just the govt's own turf; `0x0001` (xenophobic) overrides the
  whole legal-status check entirely — xenophobes attack regardless of legal
  standing.
- **Scan-and-fine**: if the player carries illegal cargo (matched via
  `mïsn.ScanMask` ∩ `gövt.ScanMask`) or a mission-defined illegal item, and
  is *not yet* evil enough to be attacked outright, he's scanned and fined
  `ScanFine` (or a %-of-cash fine if negative, or just a warning if zero).
  Being *detected* smuggling this way is itself what awards `SmugPenalty`
  evilness — i.e. `SmugPenalty` is the point cost of getting caught, not of
  merely carrying the cargo.
- **Combat/piracy evilness**: `DisabPenalty` (disable), `BoardPenalty`
  (board/pirate), `KillPenalty` (destroy) are the three point sources actually
  live in the original game; `ShootPenalty` is explicitly dead per the Bible
  quote above — every shot fired does **not** cost legal standing by itself,
  only the disable/board/kill outcome does.
- **Propagation**: see §1.2 — hurting govt X also raises standing with X's
  enemies and lowers it with X's allies.
- **MaxOdds interaction**: legal status determines *whether* a govt's ships
  want to fight the player at all (via the attack threshold above); `MaxOdds`
  then gates whether they actually *commit* to that fight once hostile — see
  [AI_GROUND_TRUTH.md §2](../AI_GROUND_TRUTH.md). A "Wanted Criminal" in a
  system where the local warships are badly outnumbered still won't be
  charged by a lone patrol ship.

## 3. Combat rating (Appendix I)

> "Your combat rating is based on the number of kills you have made, which is
> the sum of the strengths of all the ships you have destroyed, times some
> internal multiplier for adjustment."

`shïp.Strength` (per-kill contribution) is documented elsewhere in the Bible
and used identically for `gövt.MaxOdds` — see
[AI_GROUND_TRUTH.md §2](../AI_GROUND_TRUTH.md) for that field's shield-scaled
30–100% modifier. **The "internal multiplier for adjustment" is not given a
value anywhere in the Bible** — it's explicitly acknowledged as unspecified
developer-internal tuning, not scenario-editable data. Treat as an open
question (flagged again in the closing summary); a from-scratch reimplementation
has no documented value to match and will need either disassembly of
`EV Nova.exe` or an accepted approximation (e.g. multiplier = 1).

| Kills | Rating |
|---|---|
| 0 | No Ability |
| 1 | Little Ability |
| 100 | Fair Ability |
| 200 | Average Ability |
| 400 | Good Ability |
| 800 | Competent |
| 1600 | Very Competent |
| 3200 | Worthy of Note |
| 6400 | Dangerous |
| 12,800 | Deadly |
| 25,600 | Frightening |

"The text strings listed above are given only by way of illustration, since
they can be changed by editing STR# 138." Same pattern as legal status: the
*thresholds* (0/1/100/200/400/800/1600/3200/6400/12800/25600) are fixed;
only the labels are scenario-configurable.

## 4. The `ränk` resource

> "The rank resource is used to give the player a feeling of 'belonging' to a
> given government. It can also be used to give the player certain advantages
> that come with rank. When a rank is made active (which is accomplished
> through any suitable control bit set string) the player is given all the
> privileges of that rank, whatever they might be, and the name of that rank
> is displayed in the player-info dialog."

### 4.1 Fields (verbatim)

| Field | Meaning |
|---|---|
| `Weight` | "The importance of this rank, relative to the other rank resources that might be active. Ranks with higher weight are displayed first in the player-info dialog, and the active rank with the highest weight is selected for the `<PRK>` and `<PSR>` mission briefing tags." |
| `AffilGovt` | "The ID of the government affiliated with this rank." |
| `Contribute` | "Another 64 bits of Contribute values that kick in when the rank is active. These can be used to prevent the player from buying certain items or doing certain missions until achieving a certain rank, for example." — the *same* 64-bit space `shïp`/`oütf`/`crön` Contribute fields feed and `misn`/`oütf`/`shïp`/`gövt` Require fields consume (see §4.4). |
| `Salary` | "The number of credits that the affiliated government will pay the player, per day." |
| `SalaryCap` | "The maximum amount of money the player can have before the affiliated government stops paying the salary. Set to 0 or -1 if unused." |
| `Flags` | See §4.2. |
| `PriceMod` | "Used to modify the prices of items and ships at planets owned by the affiliated government. A value of 100 equals 100% of original price... can be used to let distinguished players get special deals... at 'friendly' planets that have granted them the rank." |
| `ConvName` | Long conversational form for the `<PRK>` tag; empty ⇒ never used in conversation. If no active rank has a `ConvName`, `<PRK>` renders "captain". |
| `ShortName` | Short conversational form for the `<PSR>` tag; same empty-string/fallback behavior. |
| resource name | The rank's full formal title shown in the player-info dialog, e.g. `"Commission of Space Marshall in the Hector Empire"`. |

### 4.2 `Flags` bit table (verbatim)

| Bit | Effect |
|---|---|
| `0x0001` | Deactivate all other active ranks affiliated with this same govt when this rank is **activated** (excludes permanent ranks). |
| `0x0002` | Deactivate all other active ranks affiliated with this same govt when this rank is **deactivated** (excludes permanent ranks). |
| `0x0004` | Deactivate this rank if the player destroys or disables a ship of the affiliated government or its allies. |
| `0x0008` | Rank is **permanent** — cannot be deactivated except by an explicit control-bit set string. |
| `0x0010` | Deactivate all other active *and lower-weighted* ranks of this govt when this rank is **activated** (excludes permanent ranks) — a weight-ordered variant of `0x0001`. |
| `0x0020` | Deactivate all other active *and lower-weighted* ranks of this govt when this rank is **deactivated** — weight-ordered variant of `0x0002`. |
| `0x0040` | Deactivate this rank if the player commits any crime against the affiliated government. |
| `0x0100` | Ships of the affiliated government will not automatically attack the player while he holds this rank. |
| `0x0200` | All planets of the affiliated government let the player land regardless of their `MinStatus` field. |
| `0x0400` | Player can always request battle assistance from ships of the affiliated government, who will also call in reinforcements on the player's behalf if available. |
| `0x0800` | Ships allied with the affiliated govt always repair/refuel the player for free. |

### 4.3 Activation / deactivation / multi-rank interaction

- Activated/deactivated exclusively through NCB **set** expressions: `Kxxx`
  ("activate rank ID xxx") / `Lxxx` ("deactivate rank ID xxx") — see the
  control-bit primer (Bible lines ~203–205) and
  [MISSIONS.md's NCB table](../MISSIONS.md#the-ncb-scripting-language).
- A player can hold **multiple ranks simultaneously**, even across different
  governments; `Weight` only orders *display* (player-info dialog listing)
  and picks the single rank used for `<PRK>`/`<PSR>` text substitution — it
  is not itself a cap or exclusivity rule.
- Same-govt exclusivity is opt-in per rank via the Flags above: plain
  same-govt exclusivity (`0x0001`/`0x0002`) vs. weight-ordered exclusivity
  (`0x0010`/`0x0020`) vs. no exclusivity at all (none of those bits set —
  ranks stack freely).
- Auto-revocation is also opt-in: `0x0004` (revoke on hurting the govt/its
  allies) and `0x0040` (revoke on *any* crime against the govt) are two
  distinct, independently-settable triggers — a rank could revoke on the
  lighter "any crime" trigger without the heavier "destroyed/disabled a ship"
  one, or vice versa, or neither (only `permanent`'s `0x0008` blocks *all*
  automatic revocation, requiring an explicit `Lxxx`).

### 4.4 The `Contribute`/`Require` permit chain

Six resource fields share one 64-bit bit-space, split into two roles:

**Contributors** (bits are OR'd together across everything the player
currently has/has-active):
- `shïp.Contribute` — the player's *current hull*.
- `oütf.Contribute` — each outfit item the player owns.
- `crön.Contribute` — each currently-active background event.
- `ränk.Contribute` — each currently-active rank.

**Requirers** (bits are AND'ed against the combined Contribute set; every 1
bit in a Require field must have a matching 1 bit somewhere in the combined
Contribute set, or the gate fails):
- `oütf.Require` — gates whether an outfit item can be bought.
- `shïp.Require` — gates whether a ship can be bought.
- `mïsn.Require` — gates mission availability (distinct from, and additional
  to, `mïsn.AvailBits`'s NCB test).
- `gövt.Require` — "you won't be allowed to visit any planets or stations
  owned by this govt... useful for making travel permits."

This is exactly the mechanism the Bible calls out for `ränk.Contribute`:
"prevent the player from buying certain items or doing certain missions until
achieving a certain rank." A rank is therefore not just cosmetic/salary —
it's a first-class gate in the same permit system planets, ships, and outfits
use for their own restrictions.

## 5. What's implemented vs. what's missing

Cross-referenced against `Sources/EVNovaEngine/Diplomacy.swift`,
`Sources/EVNovaKit/NovaAIModels.swift`, `Sources/EVNovaKit/NovaModels.swift`,
`Sources/EVNovaKit/MissionModels.swift`, `Sources/EVNovaStory/StoryEngine.swift`,
`Sources/EVNovaStory/PlayerState.swift`, `Sources/EVNovaStory/PilotFactory.swift`,
`Sources/EVNovaStory/PilotSave.swift`, `Sources/EVNovaStory/StellarMatching.swift`,
`Sources/EVNovaEngine/World.swift`. `third_party/NovaJS` has no government/legal
logic beyond decoding `shïp.inherentGovt` (`ShipResource.ts:140`) and labeling
outfit ModType 21 `"clean legal record"` (`OutfResource.ts:103`) — it never
evaluates either.

### Correctly modeled

- **Class/Ally/Enemy relation resolution** —
  `Diplomacy.considersHostile`/`areEnemies`/`areAllied`
  (`Sources/EVNovaEngine/Diplomacy.swift:54-82`) correctly implements "A is
  hostile to B iff A's Enemy-classes intersect B's Class-tags," with
  xenophobic (`0x0001`) override, and symmetrizes ally/enemy declarations by
  OR — a reasonable, Bible-silent engineering choice (§1.2).
- **`isHostileToPlayer`** (`Diplomacy.swift:91-101`) correctly encodes the
  `neverAttacksPlayer`/`alwaysAttacksPlayer`/xenophobic/nosy flag precedence.
- **Rank activation/exclusivity/salary (partial)** —
  `StoryEngine.activateRank` (`StoryEngine.swift:112-122`) handles Flags
  `0x0001`; salary payment with `SalaryCap` gating runs in
  `StoryEngine.swift:398-402`. `Kxxx`/`Lxxx` parse correctly
  (`NCBExpression.swift:299-300`).
- **Combat-rating title ladder exists** but see mismatch below.
- **Legal record as a mission gate** — `StoryEngine.isEligible`
  (`StoryEngine.swift:135-138`) checks `combatRating`/`legalRecord` against a
  mission's `availRating`/`availRecord`.
- **`chär.Govt1-4/Status1-4` seeding** — `PilotFactory.initialLegalRecord`
  (`PilotFactory.swift:100-115`) correctly seeds starting legal record and
  propagates the negation to the starting govt's enemies' classes (this is
  *not* the general §1.2 propagation rule — it only fires once, at pilot
  creation, from the `chär` scenario fields, which is what the Bible
  specifies for that field).

### Gaps and discrepancies (file:line)

- **`CrimeTol` is decoded but never consulted.** `GovtRes.crimeTolerance`
  (`NovaAIModels.swift:224`) exists, but `Diplomacy.isCriminal`
  (`Diplomacy.swift:86-87`) compares `legalRecord[govt]` against a single
  hardcoded `hostileThreshold = -1` (`Diplomacy.swift:20`) for *every*
  government, regardless of that govt's own crime tolerance. A government
  with `CrimeTol = 500` and one with `CrimeTol = 5` currently turn hostile at
  the exact same point (−1), which the Bible's model rules out entirely.
- **`ScanFine`/`SmugPenalty`/`DisabPenalty`/`BoardPenalty`/`KillPenalty` are
  decoded but dead.** All five are struct fields on `GovtRes`
  (`NovaAIModels.swift:223-228`) with no reader anywhere else in the
  codebase. The only place legal record is ever docked
  (`World.applyHit`, `World.swift:730-735`) uses `gov.shootPenalty` — the one
  field the Bible explicitly says is **"currently ignored"** in the real
  game — and applies it on *every hit*, not on kill/disable/board. So today:
  shooting (not destroying/disabling/boarding) is the only thing that dents
  legal record, using the one documented-dead field, while the three
  documented-live fields (`KillPenalty`, `DisabPenalty`, `BoardPenalty`) are
  never read. `ScanFine`/`SmugPenalty` have no illegal-cargo-detection system
  to attach to at all (see next point).
- **No illegal-cargo/ScanMask system.** `MissionRes.scanMask`
  (`MissionModels.swift:123/206`) is decoded; `GovtRes` has no `scanMask`
  field decoded at all (see below). Nothing in the engine ever checks
  "is the player carrying scan-illegal cargo" — `AIBrain.swift:441`'s own
  comment confirms this ("no illegal-cargo/ScanMask system yet"). `ScanFine`
  and `SmugPenalty` are consequently unreachable.
- **No positive-propagation-to-enemies rule.** `Diplomacy.recordCrime`
  (`Diplomacy.swift:105-112`) only propagates a *penalty* (half the amount)
  to governments allied with the victim; it never raises standing with the
  victim's *enemies*, despite the Bible's explicit "will improve your rating
  with its enemies" clause. The half-penalty magnitude for the ally
  propagation is also an invented constant — not specified by the Bible.
- **`combatRating` never increments during play.**
  `PilotFactory.swift:66` sets it once from `chär.Kills` at character
  creation. `World.despawnDepartedAndDead` (`World.swift:764-803`) emits a
  `.shipDestroyed` event on every kill but nothing consumes that event to
  add `shïp.Strength` to `player.combatRating` — a pilot's combat rating is
  frozen for the entire game at whatever their starting scenario granted.
- **Combat-rating title ladder doesn't match Appendix I.**
  `CombatRating` (`PilotSave.swift:131-142`) has 9 titles at thresholds
  `[0,100,200,400,800,1600,3200,6400,12800]`. The Bible's table has 11 rows
  including a `1 → "Little Ability"` tier and a `25600 → "Frightening"` tier
  that this ladder omits entirely — anything at or above 12,800 kills reads
  as the top ("Ultimate", itself a non-Bible label) with no further tier, and
  a rating of exactly 1 reads the same as 0 ("Harmless").
- **No legal-status tier-title function at all.** Unlike combat rating,
  there is no equivalent of `CombatRating.title(forRating:)` for the
  Appendix II good/evil ladder anywhere in the codebase — the ratio-to-tier
  formula in §2 isn't implemented, so nothing can currently display "Wanted
  Criminal" / "Model Citizen" etc.
- **`ränk.Contribute` is not decoded**, only commented:
  `// 14: Contribute (8 bytes)` (`MissionModels.swift:385`, right where the
  field sits per the verified 152-byte layout in
  [MISSIONS.md](../MISSIONS.md#ränk--152-bytes)). A rank's ability to gate
  purchases/missions (§4.4) is entirely unimplemented on the rank side.
- **`mïsn.Require` is likewise not decoded** — `// 1622: Require (8 bytes)`
  (`MissionModels.swift:247`). Mission availability today only checks
  `AvailBits` (NCB test), never `Require`.
- **`gövt.Require` is not decoded at all** in `GovtRes` — no `require1`/
  `require2` field exists on the struct (`NovaAIModels.swift:216-244`), so
  government-scoped "travel permit" gating (landing gated on Contribute
  bits) cannot exist yet.
- **The whole Contribute/Require chain is inert even where decoded.**
  `shïp.contribute`/`shïp.require` (`NovaModels.swift:232-234`,
  `NovaModels.swift:276-278`) and `oütf.contribute`/`oütf.require`
  (`NovaAIModels.swift:146-147`, `NovaAIModels.swift:177-178`) *are* decoded,
  but a repo-wide search finds no code anywhere that reads `.contribute` or
  `.require` off either type — no purchase-gating function combines them.
  So even the two Contribute/Require sources this codebase does parse are
  presently dead data; buying an outfit/ship never checks its `Require`
  against anything.
- **Most `ränk.Flags` bits are unmodeled.** Only `0x0001` is checked
  (`StoryEngine.activateRank`, `StoryEngine.swift:115`). `0x0002`, `0x0004`,
  `0x0008` (permanent), `0x0010`, `0x0020`, `0x0040` have no decoded property
  or check anywhere — e.g. a "permanent" rank can currently be removed by a
  plain `Lxxx` exactly like a non-permanent one, since nothing distinguishes
  them. `0x0100` (`govtWontAttack`), `0x0200` (`canAlwaysLand`), `0x0800`
  (`freeRepairRefuel`) *are* decoded as computed properties
  (`MissionModels.swift:372-374`) but are never read by
  `Diplomacy.isHostileToPlayer`, any landing/`MinStatus` gate, or
  `GameServices` — three more dead properties. `PriceMod`
  (`priceModifier`, `MissionModels.swift:364/382`) is decoded but never
  applied to shipyard/outfitter pricing anywhere.
- **`GovtRes`'s own field coverage looks incomplete, possibly mislabeled.**
  Per the file's header comment (`NovaAIModels.swift:6-8`), the decoder is
  "verified against the real game data" only via a couple of spot checks
  (`CommName` at offset 52 for govt 128). Counting Bible fields between
  `Enemy1-Enemy4` (ending at offset 48 given the preceding fields' sizes) and
  `CommName` (offset 52) leaves room for exactly one 2-byte field, yet the
  Bible lists **seven** more fields in between (`Interface`, `NewsPic`,
  `SkillMult`, `ScanMask`, `Require` (8 bytes), `InhJam1-4`, `MediumName`).
  The Swift struct instead decodes a single mystery field at offset 48 named
  `shipSpeedFactor` (`NovaAIModels.swift:238/279`) that has no counterpart of
  that name anywhere in the Bible's `gövt` section. `SkillMult` is already
  separately confirmed missing/unguessable in
  [AI_GROUND_TRUTH.md §4.6](../AI_GROUND_TRUTH.md) (no `GovtResource.ts` in
  novaparse to verify against). Recommend treating `shipSpeedFactor` as
  suspect and auditing the real offset table (ResForge `Templates.rsrc` TMPL
  or `EV Nova.exe` disassembly) before trusting any `GovtRes` field past
  `Enemy4`, including `commName`/`targetCode` themselves — the whole tail of
  the struct may be shifted.
- **Story-layer govt-scoped selectors don't call `Diplomacy` at all.**
  `StellarMatch.spob`'s ally/enemy/class selector ranges (15000/25000/30000/
  31000, `StellarMatching.swift:35-40`) fall back to a plain govt-id match
  instead of resolving real ally/enemy relations — `EVNovaEngine.Diplomacy`
  (which gets this right, see above) and `EVNovaStory` are two separate
  modules that never talk to each other. Already flagged from the story side
  in [MISSIONS.md's "Not yet wired" section](../MISSIONS.md#not-yet-wired-needs-the-other-systems).
- **`flët` (fleet) resource is decoded but never spawns anything.**
  `FleetRes.linkSystem` (`NovaAIModels.swift:355-378`) includes the
  govt-scoped `LinkSyst` ranges from the Bible, but no `Spawner`/`Galaxy` code
  references `FleetRes` at all — random/reinforcement fleet population from
  `flët` is entirely unimplemented (tangential to the `sÿst.ReinfFleet`
  gap already noted in
  [AI_GROUND_TRUTH.md §2](../AI_GROUND_TRUTH.md)).
- **`oütf` ModType 21 ("clean legal record") is decoded but inert.**
  `OutfitModType.cleanRecord` (`NovaAIModels.swift:96`) has no reader
  anywhere — an IFF-scrambler-style item that's supposed to reset/clean the
  player's legal record currently does nothing if equipped.
- **Bribery and "roadside assistance" flags are decoded/partially exposed
  but never acted on.** `GovtRes.warshipsTakeBribes`/`cantBeHailed`/
  `plundersBeforeKilling` (`NovaAIModels.swift:253-258`) expose only a subset
  of the bribery-related bits (`0x0200`); `0x2000`/`0x4000`/`0x8000` (freighter
  bribes, planet bribes, pirate-bribe-demands-more) and Flags2 `0x0010`
  (roadside assistance) have no computed property at all, only the raw
  `flags1`/`flags2` integers. Bribery itself is already tracked as
  deliberately deferred pending a hail-dialog UI in
  [AI_GROUND_TRUTH.md item 10](../AI_GROUND_TRUTH.md); roadside assistance
  isn't mentioned there and has no tracking anywhere else either.

### Open questions the Bible text doesn't resolve

1. The combat-rating "internal multiplier for adjustment" (Appendix I) has
   no documented value.
2. The magnitude of the two cross-government propagation rules in §1.2
   ("improve rating with enemies," "allies... dent standing") isn't
   quantified — only that they happen.
3. Whether govt-govt hostility (§1.2/§5) is meant to be resolved
   symmetrically (OR) or should strictly honor only the declaring
   government's own `Enemy`/`Ally` list, leaving the other side's opinion
   irrelevant to whether *it* gets attacked.

Both require either `EV Nova.exe` disassembly or accepted from-scratch
design decisions — flagging rather than guessing further.
