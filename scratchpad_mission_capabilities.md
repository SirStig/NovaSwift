# EV Nova `mïsn` / `crön` capability reference (authoritative)

Purpose: an exhaustive, source-quoted list of everything a **mission** (`mïsn`) and
**cron** (`crön`) resource can *do* in EV Nova, so it can be diffed against the
NovaSwift implementation.

Sources, in priority order:
1. Repo: `docs/AI_GROUND_TRUTH.md`, `docs/MISSIONS.md` (mïsn/crön byte layouts +
   the NovaSwift NCB grammar tables).
2. **Nova Bible** (`~/Downloads/EV Nova/Documentation/Nova Bible.txt`, ©1995-2004
   Ambrosia / Matt Burch), the original plugin-developer spec. Quoted verbatim
   below where the exact wording is load-bearing (operator letters, field names).

Everything in the **quoted blocks** (`>`) is the Bible's own text, character for
character (after MacRoman→UTF-8). Line numbers below refer to the converted file.

Terminology note: "NCB" = Nova Control Bit. There are 10,000 bits (`b0`–`b9999`).
Two dialects: **TEST** expressions (availability gates, boolean) and **SET**
expressions (side effects, whitespace-separated ops). A blank TEST field defaults
to **true**; a blank SET field alters nothing.

---

## B. THE COMPLETE NCB "SET" OPERATOR LIST (verbatim)

This is the single most important list for a faithful port. The Bible groups it in
two parts: the three "core" bit operators inline, then the extended single-letter
command table. Quoted verbatim (Bible lines 146–226).

### Core bit ops (inline in the SET grammar)

> b1 b2 !b3 ^b4
>
> In this set expression, bits 1 and 2 will be set, bit 3 will be cleared, and bit
> 4 will be toggled to the opposite of whatever it was previously. No parentheses
> are supported for set expressions. Note that if you leave a set expression
> blank, no control bits will be altered.

| Op        | Effect                                                            |
|-----------|-------------------------------------------------------------------|
| `bXXX`    | **Set** control bit XXX (to 1)                                     |
| `!bXXX`   | **Clear** control bit XXX (to 0)                                   |
| `^bXXX`   | **Toggle** control bit XXX                                         |
| `R(op op)`| **Random**: pick exactly one of the two ops, execute it, skip other |

> By specifying   R(<op1> <op2>)   you can make Nova randomly pick one of the two
> possible choices and execute it, skipping the other one.

### Extended single-letter command operators (verbatim — the full table)

> Axxx - if mission ID xxx is currently active, abort it.
>
> Fxxx - if mission ID xxx is currently active, cause it to fail.
>
> Sxxx - start mission ID xxx automatically.
>
> Gxxx - grant one of outfit item ID xxx to the player
>
> Dxxx - remove (Delete) one of outfit item ID xxx from the player
>
> Mxxx - move the player to system xxx. The player will be put on top of the
>        first stellar in the system, or in the center of the system if no
>        stellars exist there.
>
> Nxxx - move the player to system xxx. The player will remain at the same
>        x/y coordinates, relative to the center of the system.
>
> Cxxx - change the player's ship to ship type (ID) xxx. The player will keep all
>        of his previous outfit items and won't be given any of the default
>        weapons or items that come with ship type xxx.
>
> Exxx - change the player's ship to ship type (ID) xxx. The player will keep all
>        of his previous outfit items and will also be given all of the default
>        weapons and items that come with ship type xxx.
>
> Hxxx - change the player's ship to ship type (ID) xxx. The player will lose any
>        nonpersistent outfit items he previously had, but will be given all of
>        the default weapons and items that come with ship type xxx.
>
> Kxxx - activate rank ID xxx.
>
> Lxxx - deactivate rank ID xxx.
>
> Pxxx - play sound with ID xxx.
>
> Yxxx - destroy stellar ID xxx.
>
> Uxxx - regenerate (Un-destroy) stellar ID xxx.
>
> Qxxx - make the player immediately leave (absquatulate) whatever stellar he's
>        landed on and return to space, and show a message at the bottom of the
>        screen. The message is randomly selected from the STR# resource with
>        ID xxx, and is parsed for mission text tags (e.g. <PSN> and <PRK> )
>        but not text-selection tags like those above (e.g. {G "he" "she"} )
>
> Txxx - change the name (Title) of the player's ship to a string randomly
>        selected from STR# resource ID xxx. The previous ship name will be
>        substituted for any '*' characters which are encountered in the
>        new string.
>
> Xxxx - make system ID xxx be explored.

### Consolidated SET operator table (every letter)

| Letter | Arg      | Action                                                                    |
|--------|----------|---------------------------------------------------------------------------|
| `b`    | bit ID   | Set bit                                                                    |
| `!b`   | bit ID   | Clear bit                                                                  |
| `^b`   | bit ID   | Toggle bit                                                                 |
| `A`    | misn ID  | **Abort** mission (if active)                                             |
| `F`    | misn ID  | **Fail** mission (if active)                                              |
| `S`    | misn ID  | **Start** mission automatically                                          |
| `G`    | outf ID  | **Grant** one of outfit to player                                        |
| `D`    | outf ID  | **Delete/remove** one of outfit from player                             |
| `M`    | syst ID  | **Move** player to system, place on first stellar / center              |
| `N`    | syst ID  | Move player to system, keep same relative x/y coords                     |
| `C`    | ship ID  | **Change ship**, keep outfits, no default weapons                        |
| `E`    | ship ID  | Change ship, keep outfits, **plus** default weapons/items                |
| `H`    | ship ID  | Change ship, **lose non-persistent** outfits, gain defaults              |
| `K`    | ränk ID  | **Activate rank** (grants salary, privileges, standing)                  |
| `L`    | ränk ID  | **Deactivate rank**                                                       |
| `P`    | sound ID | **Play sound**                                                            |
| `Y`    | spöb ID  | **Destroy stellar** (planet/station)                                     |
| `U`    | spöb ID  | **Regenerate (un-destroy) stellar**                                      |
| `Q`    | STR# ID  | Force player off planet back to space + bottom-screen message           |
| `T`    | STR# ID  | Rename (Title) player's ship (`*` = old name)                            |
| `X`    | syst ID  | Mark system explored                                                      |

Notes / gotchas:
- **`R(...)` random** may wrap any two ops, e.g. `R(S130 S131)` (start one of two
  missions), `R(b2 !b3)`.
- **Case-insensitive** ("capitalization doesn't matter"). Bit refs happen to be
  lowercase in the shipped data. Watch the collision: uppercase `X` = explore
  system (SET) but `E` is used *twice* conceptually — as a SET op it means
  "change ship (with defaults)", while in the TEST dialect `Exxx` means "explored
  system". They are different dialects; don't cross them.
- The Bible's own primitive parser warning applies only to TEST expressions
  (precedence). SET is a flat op list.
- Repo status: `docs/MISSIONS.md` documents NovaSwift's decoded equivalents as
  `bN/!bN/^bN, GN/DN, SN/AN/FN, KN/LN, MN/NN, CN/EN/HN, YN/UN, PN, XN, TN,
  Q/QN, R(a b)`. That set matches the Bible letters — **verify `Q` (leave
  stellar + message) and `T` (rename ship, `*` substitution) are actually
  implemented, and that `C`/`E`/`H` differ correctly on outfit/default handling.**

---

## C. THE COMPLETE NCB "TEST" OPERATOR LIST (verbatim)

Quoted verbatim (Bible lines 114–143). These are the availability/gating operands.

> Bxxx   Lookup the value of control bit xxx. Bits are numbered from b0 to b9999.
> Pxxx   Check if the game is registered ([P]aid for) ... evaluates to 1 if
>        the game is registered or is unregistered but less than xxx days have
>        elapsed. Evaluates to 0 only if unregistered for more than xxx days.
> G      Lookup the player's gender - 1 if male, 0 if female
> Oxxx   Returns 1 if the player has at least one of outfit item ID xxx, 0 if not
> Exxx   Returns 1 if the player has explored system ID xxx, 0 if not
> |      Logical or operator
> &      Logical and operator
> !      Logical negation operator
> ( )    Parenthetical enclosure

| Token   | Meaning                                                                       |
|---------|-------------------------------------------------------------------------------|
| `Bxxx`  | Value of control bit xxx (1 if set)                                            |
| `Pxxx`  | 1 if game registered, OR unregistered but < xxx days elapsed; else 0          |
| `G`     | Player gender: 1 = male, 0 = female                                           |
| `Oxxx`  | 1 if player has ≥1 of outfit xxx (**includes deployed carried fighters**)     |
| `Exxx`  | 1 if player has explored system xxx                                            |
| `\|`    | Logical OR                                                                     |
| `&`     | Logical AND                                                                    |
| `!`     | Logical NOT                                                                    |
| `( )`   | Grouping                                                                       |

Important behavioral notes from the Bible:
- **Blank TEST field ⇒ true** ("if you leave the field for a test expression
  blank, it will evaluate to true as a default").
- The evaluator is **primitive**: `b1 & b2 | b3` is unpredictable — the data
  always parenthesizes. Port must either replicate that ambiguity or (as NovaSwift
  does) impose a defined precedence `! > & > |`. Bible verbatim:
  > it may do unpredictable things if you give it an expression like
  > b1 & b2 | b3 ... instead, use proper parentheses
- **`Oxxx` also counts deployed fighters** (a subtlety worth replicating):
  > The Oxxx operator also considers any carried fighters that are deployed when
  > it examines the player's current list of outfits...

**Separate but related — the `dësc` inline text conditional** (not a full TEST
expression, Bible lines 735–744). Any `dësc` string can embed:
> {bXXX "string one" "string two"}
which picks string one/two based on bit XXX (optionally `!bXXX` to negate). This
is how mission/planet text mutates on control-bit state. Only a single bit test,
no boolean composition.

---

## A. `mïsn` FIELDS THAT CAUSE AN EFFECT / ACTION

Below: every field that *does* something (grants, spawns, pays, changes state),
as opposed to the pure availability gates (`AvailStel`, `AvailLoc`, `AvailRecord`,
`AvailRating`, `AvailRandom`, `AvailBits`, `AvailShipType`, `Require`). Byte
offsets from `docs/AI_GROUND_TRUTH.md`'s verified 1970-byte layout are noted.

### A.1 The six NCB SET hook fields (the heart of mission scripting)

These each hold a **SET expression** (see section B). Fired at the named lifecycle
event; can do *anything* a SET op can. Bible lines 1628–1644.

| Field       | Offset | Fires when…                                          |
|-------------|--------|------------------------------------------------------|
| `OnAccept`  | @347   | Mission accepted by the player                       |
| `OnRefuse`  | @602   | Mission refused/declined by the player               |
| `OnSuccess` | @857   | Mission completed successfully (reached ReturnStel)  |
| `OnFailure` | @1112  | Mission failed                                       |
| `OnAbort`   | @1367  | Mission aborted by the player                        |
| `OnShipDone`| @1632  | The mission's **special-ship goal** is completed     |

> OnAccept  — evaluated when the mission is accepted by the player
> OnRefuse  — evaluated when the mission is refused by the player
> OnSuccess — evaluated when the mission is completed successfully
> OnFailure — evaluated when the mission is failed
> OnAbort   — evaluated when the mission is aborted by the player
> OnShipDone— evaluated when the mission's special ship goal is completed

(Bible uses "CompBitSet" loosely elsewhere for these; the auto-abort Flags note at
line 1561 refers to "control bits pointed to by the mission's CompBitSet fields" —
i.e. these SET hooks fire on auto-abort too.)

There is **no separate `AchievementNCB`** field in stock EV Nova `mïsn`. Any
"achievement" is just a bit set in one of the six hooks above. (Some later
engines/plug-ins invented one; stock Nova does not have it.)

### A.2 Reward / economy effects

**`PayVal`** (@28, i32) — the payout, but it is heavily overloaded and does much
more than "pay money." Bible lines 1395–1407:

> PayVal — What you get if you're successful and you return to ReturnStel
>   0 or -1           No pay
>   1 and up          This number of credits
>   -10128 to -10383  Clean legal record with the govt with this ID
>   -20128 to -20383  Clean legal record with the govt with this ID, and all its allies
>   -30128 to -30383  Clean legal record with the govt with this ID, and all its classmates
>   -40001 to -40099  Take away this % of the player's cash (-40001 = 1%, ...)
>   -50000 and down   Take away this number of credits at mission start (-50000 = 0, -50001 = 1, ...)

So `PayVal` can: **pay credits, wipe legal record with a govt (± allies/
classmates), take a percentage of cash, or charge an up-front fee at mission
start.** Port must handle all five ranges, not just "positive = credits."

### A.3 Legal-record / reputation effects on completion

- **`CompGovt`** (@46 `CompRewardGovt`, i16) — which government's record changes.
  > -1  Ignored (no reward other than pay)
  > 128-383  Increase record with this govt
- **`CompReward`** (@48 `CompLegalReward`, i16) — how much to change that record.
  > (any value) Increase record by this much
  > note: if you have a CompGovt and reward defined and you fail the mission, that
  > govt will take it personally and decrease your record by 1/2 the amount
  > specified in CompReward.

  So this field is bidirectional: **+full on success, −½ on failure** with the
  same govt. (And see Flags 0x0040 below: −5× on abort.)

There is **no dedicated combat-rating reward field**. Combat rating ("CompValue")
in EV Nova rises automatically from destroying/disabling ships, not from a mïsn
field. Don't look for one; there isn't one in the 1970-byte layout.

### A.4 Cargo effects (add/remove cargo, illegality)

- **`CargoType`** (@16) — cargo commodity: `-1` none, `0-255` specific, `1000`
  random standard type 0–5.
- **`CargoQty`** (@18) — tons: `-1` none, `0+` this many, `≤-2` = `abs(qty)` ±50%.
- **`CargoPickup`/PickupMode** (@20) — where cargo is added to hold: `0` at start,
  `1` at TravelStel, `2` when boarding the special ship.
- **`CargoDropoff`/DropOffMode** (@22) — where cargo is removed: `0` at TravelStel,
  `1` at mission end (ReturnStel; only if picked up AND ship goal done).
- **`ScanMask`** (@24, u16) — makes the cargo **illegal** to any govt whose own
  ScanMask shares a 1-bit; that govt's scanners will flag/attack you.

Net effect: missions **add tons of (possibly contraband) cargo to the hold and
remove it** at defined points; interacts with `Flags 0x0020` (fail if scanned).

### A.5 Special-ship spawning & goals (the big combat/AI effect)

Six+ fields place *controllable* special ships (up to 31) into the universe:

- **`ShipCount`** (@32) — number of special ships, `-1` none, `0-31`.
- **`ShipSyst`** (@34) — which system they spawn in (`-1` initial, `-2` random,
  `-3` TravelStel sys, `-4` ReturnStel sys, `-5` adjacent to initial, `-6` follow
  the player, `128-2175` specific, plus the 9999/15000/20000/25000/30000/31000
  govt-relative ranges).
- **`ShipDude`** (@36) — `düde` class (128–639) that determines ship types/traits.
- **`ShipGoal`** (@38) — the objective (defines what "OnShipDone" means):
  > 0 Destroy all · 1 Disable but don't destroy · 2 Board them · 3 Escort (keep
  > alive) · 4 Observe · 5 Rescue (start disabled, board to rescue) · 6 Chase off
- **`ShipBehav`** (@40) — AI override:
  > -1 standard AI · 0 always attack the player · 1 protect the player ·
  > 2 attempt to destroy enemy stellars
- **`ShipName`** (@42, STR# id) — names for the special ships.
- **`ShipStart`** (@44) — where they appear: `-4..-1` on nav-defaults 4..1,
  `0` random, `1` jump in from hyperspace after delay, `2` random & cloaked.
- **`ShipSubtitle`** (@50, STR#) — subtitle text for the special ships.

### A.6 Auxiliary-ship spawning (atmosphere only, no goals)

- **`AuxShipCount`** (@72) — `-1` none, `1-31` many (Flags 0x0010 = infinite).
- **`AuxShipDude`** (@74) — `düde` resource to build them from.
- **`AuxShipSyst`** (@76) — where to place them (own range list, incl. adjacency
  and govt-relative). These are "normal" ships for flavor; **no goals**, no
  OnShipDone.

### A.7 Time / date effects

- **`TimeLimit`** (@64) — deadline in days (`≤0` none). Expiry → mission fails →
  `OnFailure` fires.
- **`DatePostIncrement`** (@1630, i16) — **advances the galaxy clock** by this many
  days after successful completion or auto-abort. A mission can *skip time forward*.
  > the game date will be advanced by this number of days after successful
  > completion or auto-aborting of the mission.

### A.8 Ship / rank changes via hooks (not dedicated fields)

Note: **changing the player's ship, granting/removing outfits, activating a rank
(salary), moving the player between systems, destroying/regenerating stellars,
renaming the ship, and exploring systems are NOT separate mïsn fields** — they are
all done by putting `C/E/H`, `G/D`, `K/L`, `M/N`, `Y/U`, `T`, `X` SET ops into the
six hook fields (A.1). This is the key architectural point: the six SET hooks are
the universal effector; the typed fields (pay, cargo, ships, rating) are just
convenience shortcuts for the most common effects.

### A.9 `Flags` (@78) — behavioral effects (verbatim, Bible 1557–1601)

Many of these *cause actions*, not just gate availability:

| Bit    | Effect                                                                    |
|--------|---------------------------------------------------------------------------|
| 0x0001 | Auto-aborting mission (aborts itself after accept; CompBitSet hooks fire) |
| 0x0002 | Don't show red destination arrows on map                                  |
| 0x0004 | Can't refuse                                                              |
| 0x0008 | Takes away 100 units of fuel on auto-abort (won't offer if <100 fuel)     |
| 0x0010 | Infinite auxShips                                                          |
| 0x0020 | **Mission fails if you're scanned** (contraband missions)                 |
| 0x0040 | **Apply −5× CompReward reversal on abort** (big rep hit for bailing)      |
| 0x0080 | Global penalty when jettisoning mission cargo in space (currently ignored)|
| 0x0100 | Show green arrow on map in initial briefing                               |
| 0x0200 | Show additional arrow on map for ShipSyst                                 |
| 0x0400 | Mission invisible (won't appear in mission info dialog)                   |
| 0x0800 | Special-ship type locked at mission start (stays same until mission ends) |
| 0x2000 | Unavailable if player's ship is inherentAI 1/2 (cargo ships)              |
| 0x4000 | Unavailable if player's ship is inherentAI 3/4 (warships)                 |
| 0x8000 | **Mission fails if player is boarded by pirates**                         |

### A.10 `Flags2` (@80) — more effects (verbatim, Bible 1603–1610)

| Bit    | Effect                                                                    |
|--------|---------------------------------------------------------------------------|
| 0x0001 | Don't offer if not enough cargo space to hold mission cargo               |
| 0x0002 | **Apply mission Pay on auto-abort**                                       |
| 0x0004 | **Mission fails if player is disabled or destroyed**                      |

### A.11 Text-display fields (side effects on UI, no state change)

`BriefText`/`QuickBrief`/`LoadCargoText`/`DropCargoText`/`CompletionText`/
`FailureText`/`ShipDoneText`/`RefuseText` (@52–@86) each point to a `dësc` shown at
the corresponding event. `AcceptButton`/`RefuseButton` (@1887/@1919) relabel the
dialog buttons. `DisplayWeight` (@1952) orders the mission in the bar/BBS list
(higher = shown first). Offer text is `dësc` id `3872 + missionID`
(NovaSwift-verified; Bible's 4000-range is the same thing).

---

## D. `crön` (CRON) RESOURCE — FIELDS & EFFECTS

Cron = time-driven background event that fires NCB SET expressions on the galaxy
date clock, invisibly to the player. Fields quoted verbatim (Bible 613–693).
NovaSwift layout (`docs/AI_GROUND_TRUTH.md`): fixed head + 3 NCB strings.

### D.1 Date-window fields (when it may fire)

| Field       | Off | Meaning                                                            |
|-------------|-----|-------------------------------------------------------------------|
| `FirstDay`  | @0  | First day-of-month (1–31); `0`/`-1` = wildcard                     |
| `FirstMonth`| @2  | First month (1–12); `0`/`-1` = wildcard                            |
| `FirstYear` | @4  | First year; `0`/`-1` = wildcard                                    |
| `LastDay`   | @6  | Last day-of-month; `0`/`-1` = wildcard                             |
| `LastMonth` | @8  | Last month; `0`/`-1` = wildcard                                    |
| `LastYear`  | @10 | Last year; `0`/`-1` = wildcard                                     |

> Setting any of the above date fields to 0 or -1 effectively makes that field a
> wildcard field, which will match to anything.

### D.2 Timing / probability fields

| Field        | Off | Meaning                                                                    |
|--------------|-----|----------------------------------------------------------------------------|
| `Random`     | @12 | % chance of activation per eligible day (100 = as soon as possible)        |
| `Duration`   | @14 | Days the event stays active (0 = OnStart and OnEnd same day)               |
| `PreHoldoff` | @16 | Days to wait after activation before OnStart runs (0 = start immediately)  |
| `PostHoldoff`| @18 | Days to wait after OnEnd before deactivation (prevents instant re-trigger) |

### D.3 Effect / scripting fields

| Field      | Off  | Meaning                                                                   |
|------------|------|---------------------------------------------------------------------------|
| `EnableOn` | @24  | **TEST** string gating eligibility (blank = always eligible)              |
| `OnStart`  | @279 | **SET** string run when the event starts (after PreHoldoff)               |
| `OnEnd`    | @534 | **SET** string run when the event ends                                    |

> OnStart — a control bit set string that is called when the cron event starts,
>           after waiting through the PreHoldoff time, if any.
> OnEnd   — a control bit set string that is called when the cron event ends.

Because `OnStart`/`OnEnd` are full SET expressions, **a cron can do everything a
mission hook can**: flip bits, grant/remove outfits, start/abort/fail missions,
change the player's ship, destroy/regenerate stellars, activate ranks, etc.
The M/N (move player) ops are discouraged in crons (Bible note 3: they'd teleport
the player at "seemingly random times").

### D.4 `Flags` (@22) — iterative re-evaluation

| Bit    | Effect (verbatim)                                                           |
|--------|-----------------------------------------------------------------------------|
| 0x0001 | Continuous, iterative cron **entry** — keep re-running OnStart until EnableOn is no longer true or Require constraints fail (can infinite-loop!) |
| 0x0002 | Continuous, iterative cron **exit** — keep re-running OnEnd until EnableOn is no longer true or Require constraints fail (can infinite-loop!) |

### D.5 Require / Contribute (64-bit capability flags)

- **`Contribute`** (two 16-bit fields → 64-bit flag) — while active, contributes
  these bits to the pool combined from the player's ship + outfits, to satisfy
  `Require` fields in `oütf`/`mïsn`. So an active cron can **temporarily unlock
  missions/outfits** that require a capability.
- **`Require`** (two fields → 64-bit) — the cron won't activate unless the
  player's Contribute bits satisfy it.

### D.6 News fields (display effect while active)

- **`NewsGovt1-4`** + **`GovtNewsStr1-4`** — while the cron is active, on
  planets/stations allied with `NewsGovt[i]`, show a random string from STR#
  `GovtNewsStr[i]` as local news (up to 4 govts). `-1` = unused.
- **`IndNewsStr`** (@20 in NovaSwift head, "IndepNews") — STR# for independent
  news shown where no local news applies. `-1` = none.
- Local news always takes precedence over independent news.

### D.7 How it fires on the date clock (summary)

Each in-game day the engine advances the galaxy clock: for every cron not already
active, if today is within the First/Last date window **and** `EnableOn` is true
**and** `Require` is satisfied, roll `Random`%; on success the cron is "activated."
After `PreHoldoff` days it "starts" → run `OnStart` + begin news. After `Duration`
days it "ends" → run `OnEnd`. After `PostHoldoff` days it deactivates and can
re-trigger. Bible note 2: to run once ever, have `OnEnd` set a bit that makes
`EnableOn` false thereafter.

---

## E. THE "BIG THINGS" MISSIONS/CRONS DO, MAPPED TO PRIMITIVES

Every large-scale narrative effect in EV Nova decomposes into the primitives above.
This is the checklist to diff the implementation against.

| Big effect                                  | Primitive(s) used                                                                 |
|---------------------------------------------|-----------------------------------------------------------------------------------|
| **Spawn a hostile/friendly fleet**          | `ShipCount`/`ShipDude`/`ShipSyst`/`ShipStart` + `ShipBehav` (attack/protect); or `AuxShip*` for flavor; crons can't spawn ships directly — they set bits that auto-start (`S`) a spawning mission |
| **Add escorts to the player**               | `ShipBehav = 1` (protect) special ships, or grant a fighter-bay/escort `oütf` via `G` |
| **Add / remove cargo**                      | `CargoType`/`CargoQty`/`CargoPickup`/`CargoDropoff` (typed), illegality via `ScanMask` |
| **Change combat rating**                    | No field/op — rating changes only from actually destroying/disabling ships in play |
| **Pay money / charge money**                | `PayVal` (credits, %-of-cash removal, up-front fee); Flags2 0x0002 pay-on-auto-abort |
| **Add salary (rank)**                       | `K` op activates a `ränk` (salary, price modifier, standing); `L` deactivates       |
| **Change government reputation**            | `CompGovt`+`CompReward` (typed, ±½ on fail, −5× on abort via Flags 0x0040); or `PayVal` −10128/−20128/−30128 ranges to *clean* a record with a govt (+allies/classmates) |
| **Unlock outfits / tech**                   | `G` grant outfit; availability of buyable outfits gated by NCB bits set in hooks; `Contribute`/`Require` 64-bit gating |
| **Change which planets/systems exist / ownership** | `Y` destroy stellar, `U` regenerate stellar; ownership/appearance flips via control bits that `spöb`/`sÿst` visibility conditions test (bit-gated stellar/system variants); `X` mark explored |
| **Add / remove wormholes / hypergates**     | Toggle the bits that gate the wormhole/hypergate `sÿst` links / `spöb` presence (bit-conditional map objects); no dedicated op — it's `b`/`!b` on the link's condition bit |
| **Unlock ships (shipyard)**                 | Shipyard `shïp` availability gated by NCB bits set in hooks; or force a hull via `C`/`E`/`H` |
| **Move the player across the galaxy**       | `M` (onto first stellar) / `N` (same relative coords); or `DatePostIncrement` to skip time |
| **Total conversion / faction takeover (e.g. Vell-OS)** | A cascade of `b`/`!b` bits set in mission `OnSuccess` and cron `OnStart`/`OnEnd`, which flip the bit-conditions on dozens of `spöb`/`sÿst`/`gövt`/`oütf`/`shïp`/`përs`/news resources at once; the "universe changing" is entirely a large control-bit state change plus bit-gated resource variants, sequenced by crons on the date clock |

Key architectural takeaway for the port: **the control-bit set is the single
source of world-state truth.** Missions and crons never mutate the galaxy
directly except through (a) the ~4 typed convenience effects (pay, cargo, special
ships, date-skip) and (b) the SET-op letters. Everything else — who owns what
planet, which wormholes are open, which ships/outfits are for sale, which govts
are at war, what the news says — is *content data with bit-gated variants* that
merely *reads* the bits. Get the 20 SET letters + 5 TEST tokens + the PayVal
overloads + CompGovt/CompReward sign behavior + the Flags side-effects exactly
right, and the whole story engine follows.

---

## Quick diff checklist vs. NovaSwift (from repo docs)

`docs/MISSIONS.md` shows NovaSwift decodes all six hook fields (`OnAccept`,
`OnRefuse`, `OnSuccess`, `OnFailure`, `OnAbort`, `OnShipDone`) and a SET-op set
that matches the Bible letters. Confirm each of these is *executed*, not just
parsed:

1. `PayVal` — all 5 ranges (credits / clean-record ×3 / %-cash / up-front fee), not just positive credits.
2. `CompReward` — the −½-on-failure and (Flags 0x0040) −5×-on-abort reversals.
3. SET ops `Q` (leave stellar + STR# message) and `T` (rename ship, `*` substitution) — easy to miss.
4. `C` vs `E` vs `H` ship-change semantics (default weapons / non-persistent outfit handling differ).
5. `Y`/`U` destroy/regen stellar and `X` explore — do they actually mutate galaxy/nav state?
6. `DatePostIncrement` — does completion advance the galaxy clock?
7. Cron `Flags` 0x0001/0x0002 iterative re-evaluation, and `PreHoldoff`/`Duration`/`PostHoldoff` timing.
8. `Contribute`/`Require` 64-bit capability gating (both crons and missions) — noted "new" in EVENTS.md §5.
9. Cron news (`NewsGovt/GovtNewsStr/IndNewsStr`) display while active — needs the news UI.
10. `ScanMask` cargo illegality + `Flags 0x0020` (fail if scanned) + `Flags 0x8000`/`Flags2 0x0004` (fail on boarded/disabled).
11. The galaxy clock must actually advance (per MISSIONS.md the app never calls `advanceOneDay()` in live play — so **no cron fires for a real player yet**, and time-limit/salary/date-skip effects don't tick).
