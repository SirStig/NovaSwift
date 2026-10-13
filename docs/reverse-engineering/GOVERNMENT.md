# Government, legal status & rank — reverse-engineered from the Nova Bible

Read in full from the Nova Bible: `gövt` (lines 932–1163), `ränk` (2252–2344),
Appendix I — Combat Ratings (~3518–3543), Appendix II — Legal Status
(~3543–3577), and the control-bit primer (~97–229). See the
[folder README](README.md) for the standard every claim here follows, and
[STATUS.md](../STATUS.md) for what's implemented.

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
| `InhJam1-4` | Inherent jamming (0–100%) per of 4 jam types — see [AI_GROUND_TRUTH.md §4.10](AI_GROUND_TRUTH.md) for how this interacts with targeting/guided weapons. |
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
  [AI_GROUND_TRUTH.md §2](AI_GROUND_TRUTH.md). A "Wanted Criminal" in a
  system where the local warships are badly outnumbered still won't be
  charged by a lone patrol ship.

## 3. Combat rating (Appendix I)

> "Your combat rating is based on the number of kills you have made, which is
> the sum of the strengths of all the ships you have destroyed, times some
> internal multiplier for adjustment."

`shïp.Strength` (per-kill contribution) is documented elsewhere in the Bible
and used identically for `gövt.MaxOdds` — see
[AI_GROUND_TRUTH.md §2](AI_GROUND_TRUTH.md) for that field's shield-scaled
30–100% modifier. **The "internal multiplier for adjustment" is not given a
value anywhere in the Bible** — it's explicitly acknowledged as unspecified
developer-internal tuning, not scenario-editable data.

**Resolved (partially) by disassembling `EV Nova.exe`.** The tier-selection
algorithm itself is now fully decompiled — `fcn.00469030` in the real binary
(x86 PE, "EV Nova Community Edition r4" per its embedded version string,
verified byte-identical to this repo's `data/EV Nova/EV Nova.exe` against
public patch addresses in
[andrews05/EV-Nova-CE](https://github.com/andrews05/EV-Nova-CE)'s
`src/*.c`/`sym.cpp`, which target this exact build). It's a straight
11-tier comparison ladder:

```
ecx = 0
if [0x735444] <= 0: goto tail          // ecx stays 0 ("No Ability")
ecx = 1                                // ("Little Ability")
tail:
if [0x735444] < 100:  jump past the rest of the ladder (ecx unchanged)
ecx = 2                                 // ("Fair Ability")
if [0x735444] < 200:  skip
ecx = 3  ...  400→ecx=4, 800→ecx=5, 1600→ecx=6, 3200→ecx=7,
              6400→ecx=8, 12800→ecx=9
if [0x735444] >= 25600: ecx = 10        // ("Frightening")
// ecx (0-10) then indexes a 256-byte-stride runtime string-cache
// buffer at 0x62c1cc for the tier's display label (STR# 138 text,
// loaded/formatted at startup — not present as static data in the
// .exe, so the label text itself couldn't be read this way).
```

The 11 comparison thresholds are **the literal values from Appendix I**
(`100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600`, found as a
suspiciously regular stride-17-byte sequence of `cmp dword [addr], imm32`
instructions — that regularity is what made this findable via a blind
constant search of the binary at all) — **compared directly against
`[0x735444], with no multiplication or scaling applied at this stage.**
So whatever "internal multiplier for adjustment" the Bible refers to is
**not** a display-time scaling of the tier thresholds — the boundaries a
plugin author sees in Appendix I are exactly what the game checks.

**Still unresolved:** what the multiplier actually adjusts, and its value.
`[0x735444]` is read-only in this function; two call sites were traced
(a debug-mode-only overlay at `~0x49ad17`, gated on `g_nv_debugMode`
matching `sym.cpp`'s `SETCGLOB(0x00596D3A, g_nv_debugMode)`; and the
player-info dialog's stat-line renderer at `~0x487c57`, confirming this is
the same "combat rating" the Bible says appears there) — neither writes to
`[0x735444]` first, meaning it's a persistent global already holding the
live tally by the time either caller runs, not a value computed fresh per
call. Its write sites are scattered across several unrelated-looking
functions (one does a `fist` float-truncation and writes/compares against
`0x989680` = 10,000,000, suggesting **this exact global address may be
reused for an unrelated purpose elsewhere in the binary** — plausible for
a single-threaded, memory-tight 1990s codebase, but means those write
sites can't be trusted as "the kill-tally update" without further
disassembly to isolate which one actually fires on a kill event and
whether it applies a multiplier before adding a destroyed ship's
`Strength` to the tally. That's the next concrete step for anyone
continuing this thread, not attempted further in this pass.

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

The executable spreads rank Flags `0x0100` (won't attack) and `0x0200` (always land) to every government allied with the rank's government (`Government_AreGovtsAllied`, 0x0046bc90). The same government id counts as allied. If either side has government Flags `0x0800` (derelict, starts disabled), they are not allied. Otherwise a 4×4 class-slot overlap either way is enough. Xenophobe is government Flags `0x0001`. Rank-table `0x0800` in the table above is free repair, a different bit. NovaSwift does not spread either privilege yet (EC-10).

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

## 5. Where NovaSwift stands

Status lives in [STATUS.md](../STATUS.md). Where an older note in this file disagrees with the executable, [FIDELITY_PLAN.md](FIDELITY_PLAN.md) wins.

Still open here: EC-10 (Flags `0x0100` and `0x0200` spread to allies; government Flags `0x0800` is derelict and breaks that alliance), EC-04 and EC-05 (the same clearance ladder and fee cover planets, hypergates and wormholes), and EC-25 (a paid bribe lasts one approach).

### 5.3 Byte-offset verification record

The evidence trail for the three offsets this doc depends on. Sources are the
community-maintained `gövt`/`mïsn`/`ränk` TMPLs in
`third_party/ResForge/Plugins/Sources/NovaTools/Templates.rsrc` (read via
`novaswift-extract tmpl`) plus raw dumps of real records.

**`gövt` — the full 192-byte struct, byte-verified.** TMPL #507 reveals a
**second** `Flags` word (`Flags 2`, 8 more behavior bits — *Can't Request
Assist/Mercy*, *Doesn't use hypergates*, *Prefers wormholes*, …) immediately
after `Flags 1`, which the Bible's prose glosses over. Re-deriving every offset
from the TMPL and cross-checking against a hex dump of the real `gövt #128`
"Federation" record (192 bytes) confirms the entire struct:

```
voiceType@0, flags1@2, flags2@4, scanFine@6, crimeTolerance@8,
smugglePenalty@10, disablePenalty@12, boardPenalty@14, killPenalty@16,
shootPenalty@18, initialRecord@20, maxOdds@22, classes@24(×4),
allies@32(×4), enemies@40(×4), shipSpeedFactor@48, scanMask@50,
commName@52(16B), targetCode@68(16B), require@84(8B QB64),
jamming1-4@92(8B RECT), mediumName@100(64B C040), mapColor@164(4B),
shipColor@168(4B), interface@172(2B), newsPic@174(2B), 16B padding → 192
```

The Federation record's own values corroborate it: `maxOdds=200` ("2-to-1" — a
whole, sane odds ratio only at this offset), `shipSpeedFactor=100` (100%, the
Bible's "unmodified" convention), and `commName`'s 16 bytes literally spell
`Federation` padded with nulls. So `shipSpeedFactor` is real — simply not named
in the Bible's prose, only inferable from the TMPL — and `commName` /
`targetCode` are not shifted. All of `require`, `jamming`, `mediumName`,
`mapColor`, `shipColor`, `interface`, `newsPic` are now decoded in
`NovaAIModels.swift`. `mediumName` is the long form for a reinforcement-fleet message. Where a decoded field's rule still differs from the executable, the fidelity plan wins.

**`ränk.Contribute` @ 14 (8 bytes).** TMPL #515 computes `Contribute@14` as an
8-byte `QB64` field immediately followed by `Flags` — matching `RankRes.init`
reading `flags = mu16(d, 22)` exactly (14 + 8 = 22). The TMPL's computed total
of 152 bytes matches both [MISSIONS.md's verified figure](../MISSIONS.md#ränk--152-bytes)
and a real dump (`ränk #128 "Federation Naval Rank of Commander;Fed 1"`, 152
bytes on the nose). That record also proves the field carries live data: bytes
14–21 decode to a non-zero 64-bit value (word at offset 16 = `123`).

**`mïsn.Require` @ 1622 (8 bytes).** TMPL #510 computes `Require@1622` as an
8-byte `QB64` field, matching `MissionModels.swift`'s existing `// 1622:
Require (8 bytes)` comment. Both boundaries corroborate it: `OnAbort` (a
255-byte NCB set) ends at `1367 + 255 = 1622`; then `Require` (8B); then
`Date Post Increment@1630` (`DWRD`, 2B), matching `mi16(d, 1630)`; then
`onShipDone@1632`, matching `cstr(d, 1632, 255)`. The template's grand total
of 1970 bytes matches real data exactly — sampled missions #128–133 are all
precisely 1970 bytes.

A raw sweep of ~190 real missions found `Require` itself zero in every record,
which is consistent with the Bible framing it as a niche gate (§4.4) rather
than evidence against the offset — and the sweep did turn up a live, sane value
at the *adjacent* field: mission #172 has `Date Post Increment = 180` at offset
1630, exactly where the template puts it after an 8-byte `Require`, pinning the
boundary empirically. Two independent sources (the community TMPL and this
codebase's own pre-existing comment) agree on 1622.

### 5.4 Questions the Bible text left open

Settled from the executable. See WP-04, EC-02, AI-05 and FL-15 in [FIDELITY_PLAN.md](FIDELITY_PLAN.md).
