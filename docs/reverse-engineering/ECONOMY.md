# The trade economy — commodity pricing, junk, and disasters

Source: `Documentation/Nova Bible.txt` (the official EV Nova plugin-developer
"Resource Bible", ©1995-2004 Ambrosia Software / Matt Burch) inside the user's
owned `EV Nova CE` install. The `spöb` (lines 2764–3002), `jünk` (1163–1207)
and `öops` (1792–1819) resource sections were read in full, plus Part I "Game
Constants" (37–68) and Appendix III "Patching STR# Resources" (3580–3609).
Every field below is a direct quote/paraphrase of that document, not a guess.

This doc does **not** re-derive the `spöb` flag-word layout (services bits,
the six commodity-price nibbles, tech level, `DefenseDude`/`DefCount`, etc.)
— that's already decoded field-by-field in `docs/SHIP_SYSTEM.md` and
`Sources/EVNovaKit/NovaEconomy.swift`. This doc is about the **behavior**
those fields drive: what actually sets a price, what changes it over time,
and what the two ancillary trade resources (`jünk`, `öops`) do.

## 0. Relevant game constants (Part I, lines 37–68)

| Constant | Value |
|---|---|
| Max Cargo Types | 256 |
| Max Junk Types | 128 |
| Max Disasters | 256 |

The six standard commodities (food/industrial/medical/luxury/metal/equipment)
occupy cargo-type slots 0–5 of the 256; `jünk` types are a separate pool of up
to 128, addressed by their own resource IDs, not by cargo-type index. (Mission
cargo, per `evnova-ai-system`/`evnova-missions-story` notes elsewhere, uses
IDs ≥ 6 in the same 256-slot cargo-type space as the standard six — `jünk`
appears to be a parallel resource family rather than sharing that index space;
the Bible never states the two are unified, and nothing cross-references a
`jünk`'s "cargo type" with the 0–255 numbering used for the `öops.Commodity`
field. See open question in §4.)

## 1. Base commodity pricing model

The Bible documents pricing for the six standard commodities through **two
separate mechanisms** that must be combined:

1. **Per-stellar price *tier*** — the `spöb` `flags` word (lines 2791–2814)
   ORs in one of four states per commodity: "won't trade" (0x0), Low, Medium,
   or High. This is per-stellar, per-commodity, and static for that stellar
   (it's a flag baked into the `spöb` resource, not something that drifts
   tick-to-tick). Already decoded as `SpobRes.priceLevel(_:)` in
   `Sources/EVNovaKit/NovaEconomy.swift:127-130`.
2. **The actual credit values behind Low/Medium/High** — Appendix III,
   "Patching STR# Resources" (lines 3580–3609), lists a chart of `STR `
   resource ID ranges a plugin can override without touching the built-in
   `STR#` resource. It includes:

   > `Base prices of commodities` — replacement `STR ` ID range **9300-9305**
   > `Commodity abbreviations for status display` — **9400-9405**

   Six IDs, one per standard commodity (food, industrial, medical, luxury,
   metal, equipment, in that order — matching `STR# 4000`'s commodity-name
   ordering used elsewhere in the data). **This means the numeric base
   prices are themselves scenario data** (patchable per-plugin via `STR ` 9300-9305), not a hardcoded
   engine constant. The Bible doesn't spell out the exact arithmetic that
   turns one "base price" string into three Low/Medium/High numbers (no
   formula like "Low = base × 0.8" is stated anywhere in the document), but
   the existence of exactly one base-price string per commodity — not three —
   implies Medium is that base value and Low/High are computed offsets from
   it, most likely a fixed or per-commodity delta baked into the engine
   itself (see the discrepancy noted in §5: the current Swift table's
   Low/High deltas are *not* a single constant percentage across all six
   goods, e.g. food is ±20%, medical is ±11%, so whatever the true rule is,
   it isn't "one universal percent" — it's either per-commodity-tuned data or
   an engine formula the Bible doesn't expose).

3. **Tech level does *not* gate commodity trading.** `spöb.TechLevel` and
   `SpecialTech` (lines 2825–2836) only govern which *outfits* and *ships*
   (by their own `TechLevel` field) are offered — the commodity-exchange
   fields are entirely separate flag bits with no tech dependency. A tech-1
   backwater and a tech-8 capital can both trade "High" food if their flag
   bits say so.
4. **Government affiliation does not modify commodity price either.**
   `spöb.Govt`/`MinStatus` (lines 2839–2854) gate *landing clearance*
   (whether you're allowed to dock at all, based on your legal standing with
   that government), not the price you pay once you're there. No field
   anywhere in the `spöb` resource applies a government-specific markup or
   discount to commodities.
5. **No day-to-day price drift for standard commodities beyond `öops`.**
   Outside of an active `öops` disaster (§4), nothing in the `spöb` resource
   varies a commodity's price over time — the Low/Medium/High tier is a
   static property of the stellar for the life of the game (or plugin). Any
   "market feels alive" fluctuation in real Nova comes entirely from the
   `öops` system layered on top, not from an independent supply/demand
   simulation.

**Tribute** (`spöb.Tribute`, line 2817) is a related but distinct economic
field — the per-day (or lump, if unspecified) credit payout to the player
once a stellar is dominated, defaulting to `1000 × TechLevel` credits/day if
set to -1 or 0. It has nothing to do with commodity trading, but is the other
place the Bible attaches a credit formula to a stellar.

## 2. Buy/sell spread

**The Bible does not document a buy/sell spread for standard commodities.**
No field in `spöb`, and no prose anywhere in the document, describes a
different price for selling a commodity than for buying it — the
Low/Medium/High price *is* "the price," full stop, for both directions. (Junk
is even more explicit about this — see §3, `jünk.BasePrice` is singular, not
a buy/sell pair.) Nova's commodity exchange models a single spot price per
good per stellar, not a bid/ask spread; profit comes entirely from buying Low
at one stellar and selling High (or during a favorable `öops`) at another,
not from a built-in transaction cost.

## 3. Junk cargo (`jünk` resource, lines 1163–1207)

Junk resources describe "specialized commodities that can be bought and sold
at a few locations" — a parallel, much narrower trade-goods system layered on
top of the six standard commodities:

| Field | Meaning |
|---|---|
| `SoldAt1-8` | Up to 8 stellar-object IDs where this junk type is available to buy. 0/-1 = unused slot. |
| `BoughtAt1-8` | Up to 8 stellar-object IDs where this junk type can be sold. 0/-1 = unused slot. |
| `BasePrice` | "The average price of the commodity (works much like the base prices for 'regular' commodities)" — a single average price, not a Low/Medium/High per-stellar tier. |
| `Flags` | `0x0001` Tribbles — multiplies in the cargo bay over time. `0x0002` Perishable — decays away in the cargo bay over time. |
| `ScanMask` | Illegal-cargo bitmask, ANDed against a ship's government's `ScanMask` (same mechanism as `oütf.ScanMask`) — if any bits match, that government considers this junk type contraband. |
| `LCName` / `Abbrev` | Player-info-dialog name / status-bar abbreviation. |
| `BuyOn` / `SellOn` | Control-bit test expressions gating availability to buy/sell — independent boolean gates, not percent chances. |

Key differences from the six standard commodities:

- **Location-gated, not tier-gated.** Standard commodities trade at *any*
  stellar with a commodity exchange, at a price set by that stellar's
  Low/Med/High flag. Junk trades **only** at the specific stellar IDs listed
  in `SoldAt1-8`/`BoughtAt1-8` — a junk type might be sellable at exactly one
  station in the galaxy and buyable nowhere (pure salvage/mission-flavor
  loot), or vice versa.
- **Single average price, no per-stellar tier.** `BasePrice` is one number
  per junk type; there's no Low/Medium/High mechanism for junk the way there
  is for standard goods.
- **No `BuyRandom`-style daily availability roll documented for junk.**
  Unlike `oütf.BuyRandom`/`shïp.BuyRandom` (§5), the `jünk` resource has no
  percent-chance field at all — its only gates are the boolean `BuyOn`/`SellOn`
  control-bit expressions and the fixed `SoldAt`/`BoughtAt` stellar lists.
- **Two unique cargo-bay side effects not shared with standard goods**:
  Tribbles (self-multiplying) and Perishable (self-decaying) — both purely
  junk-flag behaviors; no standard commodity has an analogous flag.
- **Can be illegal cargo** via `ScanMask`, exactly like outfits — standard
  commodities have no `ScanMask` field and are never contraband.

## 4. The `öops` "disaster" system (lines 1792–1819)

The Bible is explicit that the name is a misnomer: "Oops resources contain
info on planetary disasters. Actually, the term 'disasters' is a misnomer, as
these occurrences simply affect the price of a single commodity at a planet
or station, for good or bad." It's a scripted, timed price-modifier event,
not a catastrophe with any other gameplay effect. "Nova uses the name of the
resource in the commodity exchange dialog box to indicate that a disaster is
currently going on at a planet" — i.e. the resource's own name string doubles
as the in-UI label shown to the player while it's active.

| Field | Meaning |
|---|---|
| `Stellar` | Scope of the disaster. `128-1628`: a specific stellar object ID. `-1`: "Any planet or station (use sparingly)" — a galaxy-wide roll, presumably applied independently per qualifying stellar or globally per the Bible's own caution against overuse. `-2`: "Nothing (used for mission-related news)" — a no-op disaster that exists purely to drive news/flavor text, with no price effect at all. |
| `Commodity` | Which of the six standard commodities to affect: 0 = food, 1 = industrial, etc. (the Bible's own example enumerates only the standard six; it does not state whether this field can index a `jünk` type instead — see open question below). |
| `PriceDelta` | The amount to raise or lower the affected commodity's price. Negative = price drop. Additive to the stellar's existing Low/Med/High price, not a replacement or a percentage. |
| `Duration` | How many days the disaster lasts before its price effect reverts. |
| `Freq` | **Percent chance per day that the disaster will occur.** This is a per-day Bernoulli roll, not a scheduled/deterministic trigger — every eligible day, there's an independent `Freq`% chance the disaster fires (and, presumably, is excluded from re-rolling while already active for its `Duration`, though the Bible doesn't state re-entrancy rules explicitly). |
| `ActivateOn` | Control-bit test expression. "Leave blank if unused." An additional gate on top of the `Freq` roll — the disaster can only trigger on days where this expression evaluates true (e.g. gating a disaster to only be eligible after a certain mission/story flag is set). Blank = no gate, `Freq` alone governs eligibility. |

Putting the fields together, the trigger semantics are: on each game day, if
`ActivateOn` is unset or evaluates true, roll a `Freq`-percent chance; on a
hit, apply `PriceDelta` to `Commodity`'s price at `Stellar` for `Duration`
days, and surface the `öops` resource's own name in the commodity-exchange
dialog as the "what's happening here" label for the duration.

**Open question the Bible text alone doesn't resolve:** whether `Commodity`
can reference a `jünk` type (via some ID offset above 5) or is strictly
limited to the six standard indices 0–5. Given "Max Disasters" is 256 (Part
I) and junk types top out at 128, there's numeric headroom for either
reading, but nothing in the `öops` section or elsewhere cross-references the
two resource families. Treat `öops` as standard-commodity-only unless a
counter-example turns up in actual scenario data.

## 5. What's implemented vs. what's missing

| Bible spec | Swift status | Reference |
|---|---|---|
| `spöb` flag word → per-stellar Low/Med/High/not-traded tier per commodity | ✅ Implemented | `SpobRes.priceLevel(_:)`, `Sources/EVNovaKit/NovaEconomy.swift:127-130` |
| Numeric credit values for Low/Medium/High | ⚠️ Implemented, but as **hardcoded Swift constants**, contradicted by the Bible's Appendix III entry that base prices are patchable `STR ` 9300-9305 scenario data | `Commodity.prices`, `Sources/EVNovaKit/NovaEconomy.swift:56-66`; the file's own header comment (lines 9-13, "the standard commodity prices themselves are engine constants — not stored in the scenario data") is the discrepancy — per the Bible, they *are* stored (as replaceable `STR ` strings), just not decoded from the user's data yet. Should read `STR# 9300-9305` (falling back to today's constants) the same way `commodityName` already reads `STR# 4000` (`NovaEconomy.swift:147-153`). |
| Tech level does not gate commodity trading | ✅ Correctly not implemented as a gate (no code applies `techLevel` to `commodityMarket`) | `Sources/EVNovaKit/NovaEconomy.swift:171-178` |
| Buy/sell spread | N/A per Bible (none specified) | Matches: `TradeCenterView.buy()`/`sell()` and `PilotStore.buyCommodity`/`sellCommodity` both transact at the single `c.price` — `app/EVNova/Spaceport/SpaceportScreens.swift:107,120`, `app/EVNova/Game/PilotStore.swift:182-203` |
| `jünk` resource (salvage/specialty cargo) | ❌ Not implemented at all. The four-char code is registered (`Sources/EVNovaKit/FourCharCode.swift:67`, `.junk = "jünk"`) but there is no `JunkRes` model, no decoding of `SoldAt`/`BoughtAt`/`BasePrice`/`Flags`/`ScanMask`/`BuyOn`/`SellOn`, and no UI surfaces junk trading anywhere in `app/`. | — |
| `öops` "disaster" price-event system | ❌ Not implemented at all. The four-char code is registered (`Sources/EVNovaKit/FourCharCode.swift:68`, `.oops = "öops"`) but there is no `OopsRes` model, no per-day `Freq` roll, no `PriceDelta` application, and no in-game clock/day-counter hook feeding it (the day-based `BuyRandom` roll in `NovaEconomy.swift:220-232` shows the engine already has a notion of "current day," so an `öops` roll could reuse the same day-seeded-hash pattern instead of true RNG, matching how `BuyRandom` was done). No UI shows a disaster name/label in the trade dialog. | — |
| Tribute payout when dominated | ❌ Not implemented — `spöb.Tribute` and the domination flag (`spöb` Flags2 `0x0020` "always dominated") aren't wired to any credits-per-day mechanic in `PilotStore` or `World`. | — |
| `oütf.BuyRandom` / `shïp.BuyRandom` (per-day stock availability) | ✅ Implemented (most recent commit `ff8fc20`, "Enhance item availability mechanics with BuyRandom feature") — a deterministic FNV-1a hash of `(day, spobID, itemID)` compared against the percent chance, so stock is stable within a day and re-rolls only when the day advances. Correctly encodes the Bible's per-type zero-behavior asymmetry (outfits: `BuyRandom <= 0` → always available; ships: `BuyRandom == 0` → never available). | `Sources/EVNovaKit/NovaEconomy.swift:185-232`; fields decoded at `Sources/EVNovaKit/NovaModels.swift:240,280` (`ShipRes.buyRandom` @904) and `Sources/EVNovaKit/NovaAIModels.swift:157,181` (`OutfRes.buyRandom` @1008) |
| `jünk`/`öops` equivalent of a "daily availability roll" | N/A — the Bible documents no `BuyRandom`-style field for junk; junk availability is purely the fixed `SoldAt`/`BoughtAt` stellar lists plus the boolean `BuyOn`/`SellOn` gates, so nothing is "missing" here beyond the junk resource itself not being decoded at all. | — |
| Cargo-hold interaction (capacity, load/unload) | ✅ Implemented, standard commodities only — `ShipLoadout.cargoCapacity`, `PilotStore.cargoFree/cargoUsed/held/buyCommodity/sellCommodity`. Not yet extended to a junk inventory (no `JunkRes` to attach one to), and doesn't model Tribbles self-multiplication or Perishable decay (`jünk.Flags` 0x0001/0x0002) since no junk cargo exists in the pilot's cargo dictionary at all yet. | `Sources/EVNovaEngine/ShipLoadout.swift:62,105,135,175`; `app/EVNova/Game/PilotStore.swift:151-203` |

### Third-party reference check

`third_party/NovaJS` (partial TypeScript reimplementation) has no commodity/
trade/economy logic — its "commodity"/"price"/"trade" hits are all in the
*outfitter* parser/UI (`OutfitParse.ts`, `outfitter.ts`, `OutiftData.ts`),
which is about outfit items, not the six standard trade goods or `jünk`/
`öops`. It offered nothing usable for this doc beyond confirming the
outfitter item-grid metrics already cited in `docs/SHIP_SYSTEM.md`'s sibling
UI work (`SpaceportScreens.swift:18-25`).
