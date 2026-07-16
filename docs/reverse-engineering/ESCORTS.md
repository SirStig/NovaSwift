# Escorts & Named/Special NPCs — Behavioral Ground Truth

Source: `data/EV Nova/Documentation/Nova Bible.txt` (official Ambrosia/Matt Burch
"Resource Bible"), read in full for the `përs` section (lines 2108–2252) plus
every other section that documents escort *behavior* — the `mïsn` special-ship
goal fields (~1417–1462), the `flët` fleet-escort fields (~896–944), the `gövt`
`VoiceType` field (~944–964), the `shïp` escort/hire/capture fields
(~2531–2735), and the `dësc` reserved-ID table (~723–732). Grep of the raw file
for `escort`/`hire`/`requisition` (case-insensitive) found **every** hit these
sections cover — there is no separate "escort resource"; escorting is a
cross-cutting behavior assembled from `përs`, `düde`/`flët`, `mïsn`, `gövt`, and
`shïp` fields.

## Implementation status (updated — escorts are now fully wired)

Since this doc's original "byte-verified, nothing built" pass, and since the
follow-up "backend logic, zero player-visible surface" pass that immediately
preceded this revision, escorts have gone all the way to a complete,
player-reachable feature. Every layer this doc used to describe as inert now
has a real caller:

- **`ShipRes` decoding (`Sources/NovaSwiftKit/NovaModels.swift`):**
  `hireRandom` (`@906`), `escortCategory` (`@1842`), `escortUpgradesTo`
  (`@1832`), `escortUpgradeCost` (`@1834`), and `escortSellValue` (`@1838`)
  are decoded struct fields, plus derived `escortHireFee`/`escortDailyFee`
  properties (`NovaModels.swift:434,437` — see the "Pricing gap" note in §2.2,
  now resolved).
- **Escort economics (`app/NovaSwift/Game/PilotStore.swift`):**
  `escortAvailableToday(_:at:day:)` (`:550`), `escortHireRemaining(_:at:day:)`
  (`:583`), `hireEscort(_:at:day:)` (`:596`), `requestEscortUpgrade(recordID:
  game:)` (`:619`), `cancelEscortUpgrade(recordID:)` (`:629`),
  `applyPendingEscortUpgrades(at:game:)` (`:651`), `escortSellValue(for:)`
  (`:677`), and `sellEscort(recordID:game:)` (`:685`) are real, working
  credit-transaction logic against `state.credits`/`PlayerState.escortWing`.
  `PilotStore.maxEscorts = 9` (`:22`) caps the roster.
- **A persistent roster exists:** `EscortRecord` (`Sources/NovaSwiftStory/
  PlayerState.swift:109-`, with `EscortOrigin` `.hired`/`.captured`/`.mission`
  at `:92-101`) and `PlayerState.escortWing`/`hiredEscorts` (`:421,423`) are a
  real, `Codable` (save-persisted) data model — not just library functions
  with nowhere to write their result.
- **A real hire dialog exists:** `app/NovaSwift/Spaceport/HireEscortView.swift`
  (240 lines) is a working DITL #1004-based hire browser — see the new §2.2a
  below.
- **`EscortsView.swift` (`app/NovaSwift/Game/EscortsView.swift`, 361 lines)**
  is fully data-bound, not a static empty-state shell: it takes `records:
  [EscortRecord]`, `game: NovaGame?`, `currentOrder: EscortOrder?`, and
  closures `onCommand`/`onRelease`/`onUpgrade`/`onCancelUpgrade`/`onSell`
  (`EscortsView.swift:38-56`), renders the live roster and per-escort
  upgrade/sell pricing (`:285-303`), and gates its four standing-order
  buttons on whether the wing is non-empty (`:130-133,233-237`).
- **The wiring, end to end:** `app/NovaSwift/Game/GameContainerView.swift`
  instantiates `EscortsView` with the live roster and wires every closure to
  a real handler (`:2063-2073`): `onCommand` → `scene.commandEscorts($0)`,
  `onRelease` → `releaseEscort($0)` (`:2380-2386`), `onUpgrade` →
  `upgradeEscort($0)` (`:2393-2402`, calls `PilotStore
  .requestEscortUpgrade(recordID:game:)`), `onCancelUpgrade` →
  `cancelEscortUpgrade($0)` (`:2405-2409`), `onSell` → `sellEscort($0)`
  (`:2412-2419`, calls `PilotStore.sellEscort(recordID:game:)`).
- **Daily billing is wired:** `StoryEngine.payDailyEscortFees()`
  (`Sources/NovaSwiftStory/StoryEngine.swift:721-735`) runs inside
  `advanceDays` right next to `payDailyTribute()`/`payDailySalaries()`
  (`:643-645`) — hired escorts are charged `dailyFee` per in-game day,
  cheapest-first, and depart (via `.escortDeparted`) if the player can't pay.

**What this means:** the "not wired together" framing this doc previously
carried is no longer accurate. `hireEscort`/`requestEscortUpgrade`/
`sellEscort`/`escortAvailableToday` all have real call sites outside their own
declarations, `EscortsView` reads `PilotStore`/`ShipRes` escort fields
directly, there is a hire-escort dialog (`HireEscortView`) and a persistent
roster data model (`EscortRecord`/`PlayerState.escortWing`), and the whole
loop — hire → fly with the wing → command it → upgrade/sell/release it →
pay its daily upkeep — is player-reachable in one playthrough. See the
updated §5 table below for the field-by-field breakdown.

This doc does **not** re-derive:
- `përs`/`düde` field-offset tables — see `docs/MISSIONS.md` (`PersRes`,
  `Sources/NovaSwiftKit/MissionModels.swift:317-351`) for the verified byte layout.
- The 4 base `AIType` dispositions or combat-AI variance sources (odds gating,
  cloak flags, jamming, etc.) — see `docs/AI_GROUND_TRUTH.md`, whose §1 already
  quotes `AIType = 0` = "use the ship's own inherent AI, only meaningful for
  escorts" verbatim. That statement is the hinge for this doc's §2 below.

---

## 1. What a `përs` is, and how it's placed in the world

> "The pers resource defines the characteristics of an AI personality - that
> is, a specific person the player can encounter in the game. These AI-people
> have their names (which are also the names of the associated pers resource)
> displayed on the target-info display in place of the name of their ship
> class."

Key distinction from a plain `düde` fleet ship: a `düde` class produces
anonymous, interchangeable ships of a probabilistic type; a `përs` is a single
named individual with hand-authored stats, loadout, and dialogue, layered
*on top of* the normal ship-spawning system.

**Appearance roll.** "When ships are created, there is a 5% chance that a
specific AI-person will also be created. (obviously, as AI-people are killed
off, they cease to appear in the game.)" — i.e. `përs` creation piggybacks on
ordinary ship spawning (dude/fleet spawns), it isn't scheduled independently,
and a `përs` has exactly one life: once its ship is destroyed, that roll can
never again produce it. (AI_GROUND_TRUTH.md §4.1 already covers this 5% figure
as one of the "where behavior varies" variance sources; repeated here only
because it's the *placement* mechanic, this doc's actual subject.)

**Location gating — `LinkSyst`:**

| Value | Meaning |
|---|---|
| -1 | Any system |
| 128–2175 | ID of a specific system |
| 9999–10255 | Any system belonging to this specific government |
| 15000–15255 | Any system belonging to an ally of this govt |
| 20000–20255 | Any system belonging to any but this govt |
| 25000–25255 | Any system belonging to an enemy of this govt |

**Existence gating — `ActiveOn`:** a standard NCB (control-bit) test
expression; blank = always eligible for the 5% roll. This is on top of, not
instead of, `LinkSyst` — both must pass.

**Character/ship fields relevant to placement, beyond what MISSIONS.md
already tables:** `Govt` (-1 = independent, else a specific government ID —
this is the government whose diplomatic stance the person's ship uses, and
per the `gövt` resource it also selects which of the 8 `VoiceType` comm-sound
sets plays for it); `ShipType` (the person's hull); custom `WeapType`/`WeapCount`/
`AmmoLoad` (×8 each) that can *add or remove* weapons relative to the hull's
stock loadout — "Standard weapons can be 'removed' by entering their ID
numbers in the WeapType fields and entering the negative of their standard
load ... in the WeapCount field"; `Credits` (±25% variance); `ShieldMod`
(percent multiplier on stock shield capacity — "a value less than zero makes
this person invincible"); `Color` (paint override, 00RRGGBB, 0 = no tint);
`Flags2 0x0001` ("This person starts with zero fuel").

---

## 2. `përs` as escort: recruitment, `AIType 0`, and the Bible's actual hire/requisition system

**The Bible's own escort economy does not run through `përs` at all — it runs
through the `shïp` resource's hire/capture fields, `flët`'s NPC-fleet-formation
fields, and `mïsn`'s special-ship-goal fields. `përs` only enters escort
territory indirectly, via mission linkage (§2.3 below).** This is the single
most important structural finding in this doc — do not build a "recruit this
`përs` as a permanent wingman" feature expecting it to be Bible-documented;
it isn't the design that shipped.

### 2.1 `AIType 0` and `shïp.InherentAI`

`düde.AIType`: "If you set this to 0, each ship will use its own inherent AI
type." `shïp.InherentAI` is introduced with: "The next field tells Nova what
kind of AI the ship will have if it's not created in connection with a dude
resource. **The only place this field is useful is when a ship is created as
an escort ship; otherwise, it's ignored:**"

> `InherentAI` — "What AI the ship uses when it's escorting the player. 1-4:
> Use this kind of AI... Note that only ships with inherent AI of 1 or 2 can
> be used to carry cargo when they are the player's escorts."

So: an escort ship (of any origin — hired, captured, or mission-granted) that
isn't itself governed by a `düde` uses its *hull's* `InherentAI` (1–4, the
same Wimpy/Brave/Warship/Interceptor scale as everywhere else) to decide how
it flies while tagging along — and only Wimpy/Brave-trader-classed escort
hulls (`InherentAI` 1 or 2) are eligible to actually haul cargo for the
player. This is a hull-level property (`shïp` resource), not a `përs`-level
one — a `përs`'s own `AI Type` field (1-4, same section, lines 2131-2138)
governs how that *named individual* fights/flees while independent/hostile,
before and separately from any escort relationship.

### 2.2 The real hire/requisition/capture system (`shïp` + `dësc` resources)

The Bible documents a full escort acquisition economy, entirely on ordinary
(non-`përs`) ship-class fields:

| Field (on `shïp`) | Meaning |
|---|---|
| `HireRandom` | "The percent chance that a ship of this type will be available for hire in the bar on a given day. A HireRandom of 0 means this ship will never be made available for hire." |
| `EscortType` | "Tells Nova which of the four categories of escorts to put this ship type into when organizing the escort control menu." -1 = auto-detect, 0 Fighter, 1 Medium Ship, 2 Warship, 3 Freighter |
| `UpgradeTo` | "If an escort ship of this type can be upgraded, this field holds the ID of the ship type that it can be upgraded to." 0/-1 = not upgradeable |
| `EscUpgrdCost` | "The cost to upgrade an escort ship of this type to the next more advanced version" |
| `EscSellValue` | "The amount of cash the player gets for selling off a captured escort of this type." ≤0 defaults to 10% of the ship's original `Cost` |
| `Crew` | "Ships with 0 crew can't be boarded, nor can they capture any other ships." — gates whether a hull can ever become a *captured* escort |
| `OnCapture` | NCB control-bit-set expression evaluated when the player captures a ship of this type |
| `OnRetire` | NCB control-bit-set expression evaluated when the player sells/replaces a ship of this type (applies to escorts sold off too) |

**Byte offsets now confirmed** (superseding the "unknown layout" framing this
section previously had). Method: `third_party/ResForge/Plugins/Sources/NovaTools/Templates.rsrc`
TMPL #518 (`shïp`), decoded field-by-field via `swift run novaswift-extract tmpl
"third_party/ResForge/Plugins/Sources/NovaTools/Templates.rsrc" 518`, gives a
1860-byte total record. Cross-checked against real `shïp` records with
`swift run novaswift-extract raw "data/EV Nova" shïp <id>` for **12 ships**
spanning fighters, medium ships, warships, carriers, and freighters (#128
Shuttle, #129 Heavy Shuttle, #130 Cargo Drone, #135 Lightning, #137 Valkyrie,
#141 Fed Destroyer, #142 Fed Patrol Boat, #143 Fed Carrier, #144 Fed Viper,
#161 Manta, #164 Raven, #167 Viper), plus a scripted sweep of the offsets
below over **284 of the ~288 base-game `shïp` records** (ids 128–415) to
check for outliers — every one of the 284 is exactly 1860 bytes:

| Bible field | Confirmed offset | Real type/size | Evidence |
|---|---|---|---|
| `HireRandom` | `@906` | `DWRD`, 2B | Sane 0–100 percentages across all 284 swept ships (208 are 0 = never hireable, e.g. Cargo Drone #130, Wraith variants #168-170 — matches non-combat/plot-only hulls; nonzero values cluster on fighters/mediums/warships, e.g. Viper #167 = 95, Valkyrie #137 = 50, Fed Viper #144 = 35) |
| `EscortType` (doc's name; field is unlabeled `DWRD` in the TMPL — naming it `EscortCategory` here to match this doc's evidence-based convention) | `@1842` | `DWRD`, 2B | Distribution across the 284-ship sweep: 0=Fighter ×25, 1=Medium Ship ×105, 2=Warship ×106, 3=Freighter ×48 — and the assignments are sane per-hull: Viper #167/Manta #161/Fed Viper #144 → 0 (Fighter); Valkyrie #137/Fed Patrol Boat #142 → 1 (Medium); Shuttle #128/Heavy Shuttle #129/Cargo Drone #130 → 3 (Freighter). No ship in the sweep used -1 (Automatic) |
| `UpgradeTo` | `@1832` | `RSID`, 2B | Every non-`(-1)` value in the sweep resolves to a **real `shïp` id with the same class name and equal-or-better stats** — e.g. Shuttle #128→#188 "Shuttle" (shield 30→35, armor 30→40), Fed Viper #144→#223 "Fed Viper" (shield 60→80), Valkyrie #137→#280 "Valkyrie" (armor 120→130), Fed Patrol Boat #142→#217 "Fed Patrol Boat" (shield 350→400), Viper #167→#335 "Viper" (shield 45→50), Manta #161→#315 "Manta" (shield 100→180) — confirmed with `swift run novaswift-extract ship "data/EV Nova" <id>` on both ends of each chain. 133/284 swept ships are `-1` (not upgradeable), e.g. Cargo Drone #130, all three Wraith age-variants #168-170 |
| `EscUpgrdCost` | `@1834` | `DLNG`, 4B | Sane, tier-scaled credit values across the sweep: Shuttle #128 = 5,000cr, Fed Viper #144 = 50,000cr, Fed Patrol Boat #142 = 70,000cr, up to Leviathan #131 = 1,000,000cr (a superfreighter — plausible top-end price). Zero negative/overflow values anywhere in the 284-ship sweep |
| `EscSellValue` | `@1838` | `DLNG`, 4B | **Confirmed 0 on literally all 284 swept ships, with no exceptions.** Per the Bible's own text ("≤0 defaults to 10% of the ship's original `Cost`"), this means the retail game never overrides this field — every escort sale falls through to the automatic 10%-of-`Cost` default. (An earlier working note from this session misread ship #128's field at this offset as "3" — that was actually reading 4 bytes too far forward, into `EscortCategory@1842`'s value for that ship, which is legitimately 3 = Freighter. Re-verified byte-by-byte against the raw dump: `@1838`'s two 16-bit words are `0,0` for Shuttle, and `0,0` for every other ship checked.) |
| `Crew` | already decoded | — | `crew` at `Sources/NovaSwiftKit/NovaModels.swift:189` (`@68`, per the TMPL field list) — unrelated to this session's new offsets, listed here for completeness since the Bible groups it with the hire/capture fields |
| `OnCapture` | `@976` | `n0FF`, 255B (NCB Set) | Not spot-checked against real data this session (would require parsing/decoding an NCB control-bit-set expression, out of scope here) — offset is TMPL-derived only |
| `OnRetire` | `@1231` | `n0FF`, 255B (NCB Set) | Same caveat as `OnCapture` |

**Layout-confidence note: the `shïp` record's two weapon/outfit tables are
real, not a template-parser artifact.** The TMPL dump shows what looks like a
duplicate weapon table (4×`(RSID weapon, DWRD count, DWRD ammo)` at both
`@18` and `@1742`) and a duplicate outfit table (4×`(RSID outfit, DWRD count)`
at both `@78` and `@880`) — raising the question of whether this tool's
lack of `KEYB`/union support was silently printing the same physical bytes
twice under two labels (which would put every offset *after* the first
occurrence, including all of §2.2's escort fields, in doubt). This was
checked directly against real data across the same 12-ship sample:
- **The second outfit table (`@880`) is empty (`-1,-1,-1,-1`, counts `0,0,0,0`)
  on every one of the 12 ships checked**, including ships whose first table
  (`@78`) *is* populated (e.g. Fed Patrol Boat #142: `@78` = `[197, 240, -1,
  -1]` counts `[1, 1, 0, 0]` — a real afterburner-class outfit — vs. `@880` =
  all empty). A pure duplicate-read bug would mirror `@78`'s content into
  `@880`; it doesn't. This table appears to be a genuinely distinct,
  currently-unused-in-retail-data field, not a misread.
- **The second weapon table (`@1742`) is not a duplicate of `@18` either, and
  is not always empty** — it holds real, *different* weapon ids on ships
  whose primary 4-slot table (`@18`) is completely full: Fed Carrier #143's
  `@18` = `[132, 135, 149, 150]` (4/4 slots used) and `@1742` = `[133, -1,
  -1, -1]` (weapon 133, count 2) — a fifth weapon type absent from the
  primary table. Same pattern on Fed Destroyer #141 (`@18` full with
  `[131, 134, 128, 133]`, `@1742` = `[129, ...]`), Aurora Carrier #153
  (`@18` full, `@1742` = `[144, ...]`), and Aurora Cruiser #154 (`@18` full,
  `@1742` = `[162, ...]`). This is not a universal rule — Pirate Carrier #147
  also has a full `@18` table but an empty `@1742` — and every ship checked
  with a non-full primary table (Shuttle, Valkyrie, Manta, Viper, Raven,
  Manticore, Arachnid, Fed Viper, Fed Patrol Boat) has an empty `@1742`
  regardless of fill level. The evidence best supports **`@1742` being a real,
  optional fifth weapon slot** used by a minority of heavily-armed hulls that
  need more than four distinct weapon types, not a parser double-read.

Practical upshot for this doc: since both "second table" regions sit
*between* `EscUpgrdCost`/`EscSellValue`/`EscortCategory` (all `@1832+`) and
have no bearing on whether the bytes *before* them (`@0`–`@904`, where
`HireRandom` and `BuyRandom` live) are correctly located, and since the total
record size (1860B) was independently confirmed exact across all 284 swept
ships, this ambiguity does not undermine confidence in any offset cited in
the table above — it was worth resolving on its own merits (per the shared
open question from this reverse-engineering pass), and the answer is "two
genuinely separate, TMPL-declared fields," not "one field misread as two."

Capture odds themselves are computed from `Crew` plus the `oütf` ModType 25
("marines") outfit: "Adds the value in ModVal to your ship's effective crew
complement when calculating capture odds ... -1 to -100: Increase the
player's capture odds by this amount" — i.e. marines are a purchasable,
stackable capture-odds booster, separate from any escort mechanic per se, but
this is how a *captured enemy ship* becomes an escort in the first place
(hire in the bar and capture in combat are the two acquisition paths; there is
no third "recruit a `përs`" path in the resource fields).

**UI surfaces named explicitly** (`dësc` reserved-ID table): "13000-13767 Ship
class descriptions, shown in the shipyard and **requisition-escort dialog**."
/ "14000-14767 Ship pilot descriptions, shown in the **hire-escort dialog**."
— two distinct dialogs: a "requisition" flow (likely the free/mission-granted
path) and a paid "hire" flow (the bar, gated by `HireRandom`), each with its
own description-text resources. There's also a standing **"escort control
menu"** referenced in passing by the `FloatingMap` field: "Floating hyperspace
map / escort menu border color" — i.e. escorts get a persistent management
UI, grouped into the four `EscortType` categories, not just a hail-dialog
button.

**Pricing gap — resolved in code (inferred, not Bible-sourced).** The Bible
documents `HireRandom` (availability chance) and `EscUpgrdCost`/`EscSellValue`
(upgrade/resale) but never states a distinct "hire price" field — `Cost` is
introduced once, for outright purchase ("tells Nova how much to charge you
when you buy this ship"), and no second price field exists near `HireRandom`.
The Bible text alone still doesn't answer this. The implementation picks a
concrete, documented-as-inferred answer rather than leaving it unresolved:
`ShipRes.escortHireFee` (`Sources/NovaSwiftKit/NovaModels.swift:434`) is a flat
10% of `cost`, and `ShipRes.escortDailyFee` (`:437`) is 10% of the hire fee
(1% of `cost`) — neither is a resource field; both are engine-hardcoded
constants, per that file's own doc comment (`:422-431`), chosen to keep
hiring below buying (so capturing stays the better play) and to match the one
community-documented ratio (daily ≈ 10% of hire price). `HireEscortView`
(§2.2a below) is what actually charges these.

### 2.2a `HireEscortView` — the hire-escort dialog (implemented)

`app/NovaSwift/Spaceport/HireEscortView.swift` (240 lines) is the spaceport
bar's real **Hire Escort** browser — the dëscribed-above "hire-escort dialog"
(`dësc` 14000-range pilot descriptions), reusing the Shipyard's DITL #1004
frame/grid layout (PICT #8501) applied to renting instead of buying:

- **Stock** (`:56-61`): `game.shipsSold(at: spob, day: nil)` (tech-eligible,
  same pool the shipyard sells from) filtered to `hireRandom > 0` and
  `pilot.escortAvailableToday($0, at: spob, day: day)` — a deterministic
  per-day `HireRandom` roll, the same FNV-1a-hash pattern `NovaEconomy` uses
  for `BuyRandom` stocking — then filtered again for lock state and sorted by
  `(escortCategory, escortHireFee)`. A bar with no shipyard offers nothing; a
  planet's on-offer hulls change day to day.
- **Detail pane** (`:147-173`): shows the ship's `dësc` 14000-range pilot
  description (falling back to the 13000-range class description), shield/
  armor/gun/turret stats, and category label (Fighter/Medium Ship/Warship/
  Freighter, matching `EscortType`'s four categories).
- **Pricing shown** (`:175-183`): `escortHireFee` ("Hire:") and
  `escortDailyFee` ("Per day:") against the player's current credits.
- **Hire action** (`:192-209`): `canHire` gates on affordability, lock state,
  remaining daily stock (`escortHireRemaining`), and `PilotStore.maxEscorts`;
  tapping "Hire Escort" calls `pilot.hireEscort(s, at: spob, day: day)`
  (`:201`), which is `PilotStore.hireEscort(_:at:day:)` (`PilotStore.swift
  :596`) — a real credit-transaction call, not a stub.

**`gövt.VoiceType`:** "Sets this government's voice type, used for when you
have a ship of this government as your escort (i.e. an escort with an
inherent attributes govt field that points to this govt). There can be up to
eight different voice types" (0-7), each with 10 acknowledgement + 10
targeting + 10 victory `snd ` clips (1000-1029 for type 0, +100 per type). So
an escort's *comm voice* is selected by its ship's `InherentGovt`, not by
anything `përs`-specific either.

### 2.3 Where `përs` actually connects to escorting: mission linkage + flag 0x0040

A `përs` becomes an escort only by being folded into a *mission's* special
ships, via its `LinkMission` field and this flag:

> `Flags 0x0040`: "When LinkMission is accepted with a single SpecialShip,
> replace it with this ship while removing this one from play. **This is
> generally only useful for escort and refuel-a-ship missions.** Note: if the
> mission's SpecialShip dude type contains the pers ship's ship type in it,
> the SpecialShip that's created will be of the same type as the pers ship...
> to prevent a pers ship from accidentally morphing into another ship type
> before the player's eyes."

And the companion note on `mïsn.ShipStart`: "a ShipStart value of 0 (appear
randomly in the system) is the proper value to use in conjunction with pers
resource flag 0x0040." So the intended flow is: the player hails/boards a
named `përs` captain in open space → accepts their `LinkMission` → the game
despawns the standalone `përs` ship and spawns the mission's `ShipCount`/
`ShipDude`/`ShipGoal` special ship(s) in its place (same hull type, guaranteed
by the sub-rule above) → the mission's `ShipGoal = 3` ("Escort them - keep
them from getting killed") makes that former-`përs` ship the player's
protection charge for the mission's duration. This is a **per-mission,
temporary** escort relationship scoped to one mission's lifetime, not the
persistent hire/requisition roster from §2.2 — the Bible gives no field
anywhere that promotes a mission's special ship into the *permanent* escort
list after the mission ends.

Related `mïsn` fields (full section starts ~line 1417):

| Field | Values |
|---|---|
| `ShipCount` | -1 none, 0-31 special ships |
| `ShipSyst` | where they appear (-1 initial system … -6 "whatever system the player is in (i.e. follow him around)" … or a specific/relative-government system) |
| `ShipDude` | which `düde` class supplies their hull/AI/govt |
| `ShipGoal` | -1 none, **0 destroy all, 1 disable-only, 2 board, 3 escort them (keep them from getting killed), 4 observe, 5 rescue (start disabled, stay so until boarded — unless the govt has the "always disabled" flag), 6 chase them off (kill or scare into jumping out)** |
| `ShipBehav` | -1 standard AI, 0 always attack the player, 1 protect the player, 2 attempt to destroy enemy stellars |
| `ShipStart` | on-top-of-nav-default -4..-1, 0 random (pair with `përs` 0x0040), 1 jump in after delay, 2 random+cloaked |

`ShipBehav = 1` ("protect the player") is the actual command-verb analog of
"defend me" for mission special ships — this, not anything on `përs` itself,
is the field that makes a special ship behave like a bodyguard. AI_GROUND_TRUTH.md
§4.8 already flags `ShipBehav` as a deferred item (needs mission-driven ship
spawning wired through `NovaSwiftStory` — not done).

### 2.4 `flët` (fleet) escorts — a third, unrelated meaning of "escort"

The `flët` resource's `EscortType`(×4)/`Min`(×4)/`Max`(×4) fields describe
**NPC formation escorts around an NPC flagship** (e.g. a warship convoy with
2-4 fighter screens) — nothing to do with the player's own escort roster.
This is the one escort concept that's fully implemented today (§5).

---

## 3. Escort combat/command behavior — comm verbs and what's actually implemented

**The Bible documents no comm-dialog order verbs for player-held escorts at
all** — no "Hold Position," "Attack My Target," "Dock," "Form Up," etc. appear
anywhere in the text (grepped case-insensitively; zero hits for any of those
phrases). The only escort-adjacent *behavioral* toggle the Bible gives the
player is `ShipBehav` on the mission side (§2.3) — an author-time mission
field, not a runtime player command. Real EV Nova's escort command menu (the
one implied by the "escort control menu"/`FloatingMap` border-color field in
§2.2) is understood from general EV Nova knowledge to offer simple stance
toggles per escort (aggressive/defensive/hold-fire and similar), but **the
Bible prose itself stops at the resource-field level and never spells out
those verbs** — this is a real gap in the source document, not something this
doc is choosing to omit.

**The codebase now has two escort-adjacent features — a standing-order
command system for the persistent roster, and a separate one-shot "assist"
hail service:**

**(a) Standing-order commands (implemented).** `EscortsView.swift` — the
window opened by hailing one of your own escorts, a DLOG/DITL #1022
recreation (§ intro above) — exposes exactly the four stance verbs general
EV Nova knowledge would predict: Aggressive / Defensive / Evasive / Hold
Position, as real buttons (`commandButton(_:)`, `EscortsView.swift:130-133`,
enabled only when the wing is non-empty, `:233-237`) wired through `onCommand:
(EscortOrder) -> Void` (`:43`). `EscortOrder` itself is a real enum
(`Sources/NovaSwiftEngine/AIBrain.swift:8`). `GameContainerView.swift` wires
`onCommand` to `scene.commandEscorts($0)` (`:2068`) — a live persistent-escort
object *is* commanded here, contrary to this doc's earlier claim that no such
object exists. The same window's roster list (`roster`, `:154-169`) shows each
live escort's name/shield/armor and origin (hired/captured/mission), and its
action strip (`:239-333`) exposes per-escort Upgrade/Cancel Upgrade/Sell/
Release, calling back into `PilotStore.requestEscortUpgrade`/
`cancelEscortUpgrade`/`sellEscort` via `GameContainerView`'s wiring (see the
Implementation-status section above).

**(b) The "assist" hail service (implemented, separate feature).** the
"assistance mechanics" commit (`bdf82d2`, "Implement assistance
mechanics for NPCs and enhance communication features") added a **one-shot,
paid "tow truck" hail service**, not escort recruitment or command:

- `AIBrain.assist` (`Sources/NovaSwiftEngine/AIBrain.swift:481-502`) — a hailed
  NPC flies to the player, docks within 90 units, and calls
  `World.deliverAssistance` exactly once (`assistDelivered` latch), which
  refuels the player to full and floors armor at 40% max
  (`Sources/NovaSwiftEngine/World.swift:892-897`). After delivery, if the player
  currently has a hostile ship targeted and the assisting NPC is armed, it
  will pitch in against that one target (reusing `attack()` wholesale) before
  departing on a 4-second timer (`AIBrain.swift:492-501`).
- `HailDialogView.swift` (`app/NovaSwift/Game/HailDialogView.swift:17-115`) — the
  generic in-flight comm dialog (opened by hailing a non-escort ship) exposes
  exactly **three** buttons: `Greetings`, `Request Assistance`, `Close
  Channel` (lines 84-88). This dialog is separate from `EscortsView` (§3(a)
  above), which is what opens when the hailed ship *is* one of the player's
  own escorts — assist is requested from, and delivered by, any nearby
  non-hostile ship, ally or stranger, and the relationship ends the moment it
  flies off; it does not use the persistent escort roster at all.
- Pricing is by diplomatic tier, not `përs`/hire economics: `assistanceTier`
  (`GameScene`) maps to free (ally), 300cr (neutral), or 900cr with only a 50%
  acceptance chance (wary/dislikes-you-but-not-hostile) —
  `app/NovaSwift/Game/GameContainerView.swift:190-193, 580-615`. This pricing
  model is an invented scope cut with no Bible citation (the Bible's own
  hire/capture pricing is `Cost`/`EscUpgrdCost`/`EscSellValue`, none of which
  this code path reads).

So: **the `bdf82d2` commit is not an implementation of the Bible's `përs`/
hire-escort system at all** — it's a same-verb-different-mechanic feature
(paid battlefield support call) layered on top of the diplomacy system,
distinct from (and shipped independently of) the standing-order command
system in §3(a). It does not touch `PersRes` in any way. The claim from an
earlier revision of this doc that "there is no persistent escort object to
command" is no longer true — see §3(a) and the Implementation-status section
above: `EscortsView`/`GameContainerView`/`PilotStore`/`PlayerState.escortWing`
together *are* that persistent, commandable object.

---

## 4. Escort persistence, death, and capacity — what the Bible specifies (and doesn't)

- **Death is permanent for a `përs`.** Directly stated: "as AI-people are
  killed off, they cease to appear in the game." No respawn, no re-recruitment
  of the same named individual once destroyed — the 5%-roll population pool
  for that `LinkSyst` simply shrinks by one entry forever.
- **Grudge flag (`Flags 0x0001`) survives death of the relationship, not the
  ship:** "The special ship will hold a grudge if attacked, and will
  subsequently attack the player wherever the twain shall meet" — this is
  about a *hostile* `përs` remembering the player, unrelated to escort
  persistence, but worth noting since it's the only cross-encounter memory
  the resource defines.
- **Escort ships acquired via hire/capture (§2.2) are NOT documented as
  permanent or loss-free either** — `EscSellValue` exists specifically
  because the player can choose to sell a captured escort off, and nothing in
  the text states escorts are shielded from being destroyed in combat; there
  is no "escort invulnerability" flag on `shïp` (contrast with `përs.ShieldMod
  < 0` = invincible, which is a per-`përs` override, not an escort-general
  rule). The closest thing to escort damage immunity is a *different*
  mechanic entirely: `düde.Booty` note "0x0100 Ships of this dude type can't
  be hit by the player and their shots can't hit the player (useful for
  things like AuxShip mission escorts, etc.)" — a dude-class flag for
  *player-proof* NPCs used in some escort-flavored missions, not a property
  of the player's own hired/captured roster.
- **Capacity/hire limits are not specified in the Bible text at all** — no
  field caps the number of simultaneous hired/captured escorts, no bay-space
  or hangar-slot mechanic is mentioned anywhere in the `shïp`/`gövt`/`mïsn`
  sections searched for this doc. (EV Nova is widely known, outside the Bible,
  to cap the escort roster in practice, but that's not something the
  developer-facing resource documentation states — flagging as an unresolved
  gap rather than asserting a number.)
- **Cargo-carrying escorts** are capacity-relevant in one specific way: only
  `InherentAI` 1/2 (trader-classed) escorts "can be used to carry cargo when
  they are the player's escorts" (§2.1) — implying escorts have their own
  cargo holds usable for mission cargo overflow, gated by hull disposition,
  not a universal escort-cargo rule.

---

## 5. What's implemented vs. what's missing

| Bible concept | Status | Where |
|---|---|---|
| `PersRes` field decoder (LinkSyst, Govt, AIType, Aggress, Coward, ShipType, LinkMission, flags, activeOn, subtitle) | ✅ Decoded | `Sources/NovaSwiftKit/MissionModels.swift:317-351`; exposed via `game.pers(id)`/`game.persons()`, `Sources/NovaSwiftKit/NovaModels.swift:454-455` |
| `përs` 5%-chance spawn-time creation, tied to ordinary ship spawns | ❌ Not wired | No caller of `PersRes`/`game.pers`/`game.persons()` exists anywhere outside the decoder file and its accessor (verified by repo-wide grep). `docs/MISSIONS.md`'s own "Not yet wired" section already flags this: "`përs` captains offering their linked missions in space (needs AI to place them; the decoder + `activeOn`/`linkMission` fields are ready)." |
| `AIType 0` → `shïp.InherentAI` fallback for escorts | Partially decoded, not escort-specific | `inherentAI` decoded at `Sources/NovaSwiftKit/NovaModels.swift:193,265` (`@66`); `AIType(raw:)` fallback exists generically (see AI_GROUND_TRUTH.md §1) but nothing in the engine currently creates a "hired/captured escort using its hull's InherentAI" — the only consumer of `InherentAI` today is `Spawner.spawnFleet` picking a flagship/escort's *own* disposition for NPC-fleet ships (`Sources/NovaSwiftEngine/Spawner.swift:132-133,158-165`), not a player-owned escort |
| `shïp.HireRandom` (bar hire availability) | ✅ Decoded and wired | `hireRandom: Int` on `ShipRes`, `Sources/NovaSwiftKit/NovaModels.swift:267,327` — `i16(d, 906)`, matching the `@906` offset §2.2 confirmed. Consumed by `PilotStore.escortAvailableToday(_:at:day:)` (`PilotStore.swift:550`), which gates both `HireEscortView`'s stock (§2.2a) and `hireEscort`'s own guard (`:597`) |
| `shïp.EscortType`/`UpgradeTo`/`EscUpgrdCost`/`EscSellValue` (escort-menu categorization, upgrades, resale) | ✅ Decoded and wired | All four exist on `ShipRes` (`Sources/NovaSwiftKit/NovaModels.swift:272-331`): `escortCategory` (`@1842`), `escortUpgradesTo` (`@1832`), `escortUpgradeCost` (`@1834`), `escortSellValue` (`@1838`). Consumed by `PilotStore.requestEscortUpgrade(recordID:game:)` (`:619`), `applyPendingEscortUpgrades(at:game:)` (`:651`), and `escortSellValue(for:)`/`sellEscort(recordID:game:)` (`:677,685`) — upgrade queues at hail time and charges `escortUpgradeCost` on the next shipyard landing; sale credits `escortSellValue` or the Bible's 10%-of-`Cost` fallback. Both are called from `GameContainerView.swift`'s `upgradeEscort`/`sellEscort` handlers (`:2393-2419`), which `EscortsView`'s action strip invokes per-escort |
| "Requisition-escort" / "hire-escort" dialogs, escort control menu | ✅ Implemented and wired | `app/NovaSwift/Spaceport/HireEscortView.swift` (§2.2a) is the real, working hire-escort dialog — `HireRandom`-gated daily stock, `escortHireFee`/`escortDailyFee` pricing, locking, and a working "Hire Escort" button that calls `PilotStore.hireEscort`. `app/NovaSwift/Game/EscortsView.swift` is the escort control menu — a geometry-accurate recreation of the real DLOG/DITL #1022 "Escorts" panel (424×259, four command buttons Aggressive/Defensive/Evasive/Hold Position, identity/status/roster panels), fully data-bound to `records: [EscortRecord]`/`game: NovaGame?`/`currentOrder: EscortOrder?` and to `onCommand`/`onRelease`/`onUpgrade`/`onCancelUpgrade`/`onSell` closures (`EscortsView.swift:38-56`), all wired to real handlers in `GameContainerView.swift:2063-2073,2380-2419`. `HailDialogView.swift`'s unrelated 3-button in-flight comm dialog for non-escort ships is still separate — see §3 |
| Persistent player escort roster (hired, captured, or mission-granted) | ✅ Implemented | `EscortRecord` (`Sources/NovaSwiftStory/PlayerState.swift:109-`) with `EscortOrigin` `.hired`/`.captured`/`.mission` (`:92-101`), held in `PlayerState.escortWing`/`hiredEscorts` (`:421,423`) — a real, `Codable`, save-persisted array, capped at `PilotStore.maxEscorts = 9` (`PilotStore.swift:22`). `StoryGuideView`'s "Escorts" section renders `EscortsView` bound to this roster (see previous row), and daily upkeep is billed against it by `StoryEngine.payDailyEscortFees()` (next-but-one row) |
| `gövt.VoiceType` (per-government escort comm voice, 8 types × ack/target/victory `snd`) | ✅ Decoded, unused for escorts | `Sources/NovaSwiftKit/NovaAIModels.swift:220,264` decodes `voiceType`; not consumed anywhere for playing escort ack/targeting/victory audio — this is the one escort-adjacent field that's still genuinely unwired, since it needs audio playback wiring unrelated to the roster/hire/command work above |
| Daily escort upkeep billing | ✅ Implemented | `StoryEngine.payDailyEscortFees()` (`Sources/NovaSwiftStory/StoryEngine.swift:721-735`) runs inside `advanceDays` next to `payDailyTribute()`/`payDailySalaries()` (`:643-645`); charges each `.hired` escort's `dailyFee` per in-game day (cheapest-first), and drops/despawns any the player can no longer afford via `.escortDeparted` |
| Capture mechanics (`Crew`, marines `ModType 25`, `OnCapture`) | Partially decoded | `crew` decoded (`NovaModels.swift:189`); marines outfit ModVal handling and `OnCapture` control-bit-set evaluation not found in `Sources/NovaSwiftEngine` (no boarding/capture system exists in this engine yet per AI_GROUND_TRUTH.md's boarding caveat, §1 item 3). Note: captured escorts are otherwise fully modeled once acquired — `EscortOrigin.captured` records exist and support upgrade/sell (previous rows) — the gap is specifically in the boarding/capture-odds combat mechanic that would populate them from combat, not in the escort roster itself |
| `mïsn.ShipGoal`/`ShipBehav`/`ShipStart` (mission special-ship goals incl. `ShipGoal=3` escort-the-NPC, `ShipBehav=1` protect-the-player) | ❌ Deferred | AI_GROUND_TRUTH.md §6 item 12: "blocked on [NovaSwiftStory-to-game-loop wiring], not on anything AI-specific" — same root cause as the `përs` placement gap above. (`EscortOrigin.mission` exists as a roster case, but nothing yet promotes a mission special ship into it.) |
| `flët.EscortType`/`Min`/`Max` — NPC fleet escort formations | ✅ Implemented | `Sources/NovaSwiftEngine/Spawner.swift:126-163` (`spawnFleet`) builds a flagship + numbered escort slots; `Sources/NovaSwiftEngine/AIBrain.swift:17,42-45,240-252,450-473` (`AIState.escorting`, `leaderID`, `formationSlot`, `escort()` V-wing station-keeping) drives their flight. This is the *NPC convoy screen* meaning of "escort," separate from the player's own roster (previous rows) — both are now built. |
| `përs.ShieldMod < 0` invincibility, custom weapon add/remove, grudge flag, escape-pod flag | Field-decoded only | `flags1`/related bits exist on `PersRes` (`MissionModels.swift:328-334`, only 3 of the ~16 documented flag bits have named accessors: `deactivateAfterAccept`, `offerOnBoard`, `leavesAfterAccept`); no runtime behavior consumes any of them since `PersRes` is never instantiated (see row 2) |
| Standing-order commands (Aggressive/Defensive/Evasive/Hold Position) for player-held escorts | ✅ Implemented | `EscortsView`'s command buttons (`EscortsView.swift:130-133,233-237`) call `onCommand: (EscortOrder) -> Void`, wired to `scene.commandEscorts($0)` in `GameContainerView.swift:2068`. `EscortOrder` is a real enum (`Sources/NovaSwiftEngine/AIBrain.swift:8`). Not a Bible-specified verb set (the Bible never spells these out, per §3) but a real, working feature against the persistent roster — see §3(a) |
| "Assist" paid support call (commit `bdf82d2`) | ✅ Implemented, but **not** a Bible `përs`/escort feature | See §3(b) — `AIBrain.assist`, `World.deliverAssistance`, `HailDialogView`'s "Request Assistance" button, `GameContainerView`'s tier-based pricing. A legitimate, self-consistent invented mechanic, separate from (and shipped independently of) the standing-order command system above — it shares no code path with it or with `përs` recruitment. |

**Bottom line (updated):** the escort *AI-formation* half of EV Nova
(flët-driven NPC convoys) was already built. The player-facing half has now
gone all the way from "undocumented in code" through "real backend logic,
zero player-visible surface" to **a complete, wired feature**:
`ShipRes.hireRandom`/`escortCategory`/`escortUpgradesTo`/`escortUpgradeCost`/
`escortSellValue` are decoded; `PilotStore`'s `escortAvailableToday`/
`hireEscort`/`requestEscortUpgrade`/`sellEscort` are working, Bible-cited
credit-transaction logic; `HireEscortView` is a real hire dialog; `EscortsView`
is a real, data-bound command/roster window; `EscortRecord`/
`PlayerState.escortWing` is a real persistent, save-backed roster capped at
9; `GameContainerView` wires every piece together; and
`StoryEngine.payDailyEscortFees()` bills upkeep automatically. The
remaining gaps are narrow and specific, not structural: `gövt.VoiceType`
audio playback is unwired, boarding/capture-odds combat (populating
`.captured` records from combat rather than from a debug spawn) doesn't
exist yet, and `mïsn`-driven promotion of a mission special ship into the
roster (`EscortOrigin.mission`) isn't wired. `PersRes` (the named-individual
`përs` resource itself) still decodes cleanly with zero runtime consumers,
unchanged from before — that gap is unrelated to the escort-roster work
described above.
