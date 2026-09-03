# The trade economy — commodity pricing, junk, and disasters

Read in full from the Nova Bible: `spöb` (lines 2764–3002), `jünk` (1163–1207),
`öops` (1792–1819), Part I "Game Constants" (37–68) and Appendix III "Patching
STR# Resources" (3580–3609). See the [folder README](README.md) for the standard
every claim here follows, and [STATUS.md](../STATUS.md) for what's implemented.

This doc does **not** re-derive the `spöb` flag-word layout (services bits,
the six commodity-price nibbles, tech level, `DefenseDude`/`DefCount`, etc.)
— that's already decoded field-by-field in `docs/SHIP_SYSTEM.md` and
`Sources/NovaSwiftKit/NovaEconomy.swift`. This doc is about the **behavior**
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
cargo, per `novaswift-ai-system`/`novaswift-missions-story` notes elsewhere, uses
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
   `Sources/NovaSwiftKit/NovaEconomy.swift`.
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
| `Commodity` | Which of the six standard commodities to affect: 0 = food, 1 = industrial, etc. (the Bible's own example enumerates only the standard six; empirically, every real `öops` record in the base game stays within 0–5 — see resolved question below). |
| `PriceDelta` | The amount to raise or lower the affected commodity's price. Negative = price drop. Additive to the stellar's existing Low/Med/High price, not a replacement or a percentage. |
| `Duration` | How many days the disaster lasts before its price effect reverts. |
| `Freq` | **Percent chance per day that the disaster will occur.** This is a per-day Bernoulli roll, not a scheduled/deterministic trigger — every eligible day, there's an independent `Freq`% chance the disaster fires (and, presumably, is excluded from re-rolling while already active for its `Duration`, though the Bible doesn't state re-entrancy rules explicitly). |
| `ActivateOn` | Control-bit test expression. "Leave blank if unused." An additional gate on top of the `Freq` roll — the disaster can only trigger on days where this expression evaluates true (e.g. gating a disaster to only be eligible after a certain mission/story flag is set). Blank = no gate, `Freq` alone governs eligibility. |

Putting the fields together, the trigger semantics are: on each game day, if
`ActivateOn` is unset or evaluates true, roll a `Freq`-percent chance; on a
hit, apply `PriceDelta` to `Commodity`'s price at `Stellar` for `Duration`
days, and surface the `öops` resource's own name in the commodity-exchange
dialog as the "what's happening here" label for the duration.

**Resolved (as far as this method can tell):** whether `Commodity` can
reference a `jünk` type (via some ID offset above 5) or is strictly limited
to the six standard indices 0–5. Two independent pieces of evidence now
point the same way:

1. **The TMPL itself is typed.** `öops`'s `Commodity` field (TMPL #512,
   `third_party/ResForge/Plugins/Sources/NovaTools/Templates.rsrc`) is a
   `CASR` enum listing exactly six named cases, `Food=0` through
   `Equipment=5` — no "or a jünk ID" case, no open-ended integer hint. The
   editor's own authoring UI presents this as a closed six-way choice, not a
   free-form resource-id picker (contrast with `Stellar`@0, which *is* typed
   as a raw `RSID`/free integer).
2. **Every real `öops` record in the base game stays in range.** All 19
   `öops` resources that ship with EV Nova (`Nova Data 2.rez`, ids 128–146 —
   the only `.rez` file that has any; see `swift run novaswift-extract list
   "data/EV Nova/Nova Files/Nova Data 2.rez" öops`) were dumped with
   `swift run novaswift-extract raw "data/EV Nova" öops <id>` for id in
   128...146. `Commodity`@2 is 0, 1, 2, 3, 4, or 5 in every single one —
   never higher. Several are semantically self-confirming, which is stronger
   than a bare range check: #143 "The discovery of a new ore deposit" has
   `Commodity`=4 (metal) with `PriceDelta`=-110; #144 "The discovery of a new
   drug" has `Commodity`=2 (medical) with `PriceDelta`=-150; #134 "A spate of
   break-downs" has `Commodity`=5 (equipment) with `PriceDelta`=+115; #128
   "An enormous food surplus" has `Commodity`=0 (food) with `PriceDelta`=-15.
   The disaster's own name and its `Commodity` index line up correctly every
   time, which only makes sense if `Commodity` really is indexing the six
   named goods, not some other resource family.

Absence of evidence isn't proof — there is no `jünk`-referencing counter-example anywhere
to point to, and the sample is limited to the 19 stock `öops` records (a
third-party plugin could still choose to abuse the field with an
out-of-range value the engine happens to tolerate). But between the TMPL's
closed six-case enum and 19/19 real records staying in range with several
showing exact name↔commodity semantic matches, this is as close to a
confirmed "no" as the reverse-engineering method can produce without engine
source. Treat `öops` as standard-commodity-only.

## 5. Implementation status

| Bible spec | Status | Where |
|---|---|---|
| `spöb` flag word → per-stellar Low/Med/High/not-traded tier per commodity | ✅ Implemented | `SpobRes.priceLevel(_:)`, `NovaEconomy.swift` |
| Numeric credit values for Low/Medium/High | ✅ Wired, with a `STR ` override path (§5.1) | `NovaGame.commodityBasePrice(_:)`/`commodityPrices(_:)`/`overrideString(_:)`, `NovaEconomy.swift` → `SpaceportScreens.swift` |
| Tech level does *not* gate commodity trading | ✅ Correctly not implemented as a gate | — |
| Buy/sell spread | N/A per Bible (none specified) | Matches: `TradeCenterView.buy()`/`sell()`, `PilotStore` |
| `jünk` resource (salvage/specialty cargo) | ✅ Wired — trading, cargo, Tribbles/Perishable, contraband (§5.2) | `JunkModels.swift`, `SpaceportScreens.swift`, `PilotStore.swift`, `Contraband.swift`, `ContrabandScan.swift` |
| `öops` disaster price events | ✅ Wired — daily roll, expiry, price delta (§5.3) | `OopsModels.swift`, `StoryEngine.swift`, `SpaceportScreens.swift` |
| `oütf.BuyRandom` / `shïp.BuyRandom` (per-day stock) | ✅ Implemented — deterministic FNV-1a hash of `(day, spobID, itemID)` vs. the percent chance, so stock is stable within a day and re-rolls only when the day advances. Correctly encodes the Bible's per-type zero asymmetry (outfits: `BuyRandom <= 0` → always available; ships: `BuyRandom == 0` → never available) | `NovaEconomy.swift`; decoded at `ShipRes.buyRandom` `@904` (`NovaModels.swift`) and `OutfRes.buyRandom` `@1008` (`NovaAIModels.swift`) |
| Cargo-hold interaction (capacity, load/unload) | ✅ Implemented for standard commodities **and** junk — junk shares the pilot's cargo dictionary, with Tribbles multiplication and Perishable decay applied by `tickJunkCargo` | `ShipLoadout.cargoCapacity`, `PilotStore.cargoFree`/`cargoUsed`/`held`/`buyCommodity`/`sellCommodity`/`tickJunkCargo` |
| `jünk`/`öops` daily-availability roll | N/A — the Bible documents no `BuyRandom`-style field for junk. Availability is the fixed `SoldAt`/`BoughtAt` lists plus the boolean `BuyOn`/`SellOn` gates; confirmed absent from the byte layout above (no percent-chance field between `ScanMask@36` and the two NCB test strings) | — |
| Tribute payout when dominated | ❌ Not implemented — `spöb.Tribute` and the domination flag (`spöb` Flags2 `0x0020`, "always dominated") aren't wired to any credits-per-day mechanic in `PilotStore` or `World` | — |

[JUNK_OOPS_DESIGN.md](JUNK_OOPS_DESIGN.md) is the design doc that guided the
`jünk`/`öops` implementation, and records where the shipped code diverges from
that plan.

### 5.1 Commodity base prices and the `STR ` override

`NovaGame.commodityBasePrice(_:)` reads the `STR ` 9300-9305 override (one
Pascal-string resource per commodity, via `overrideString(_:)`), and
`commodityPrices(_:)` re-anchors this build's per-commodity Low/High offsets
around that value, falling back to the hardcoded `Commodity.prices` table when
no override exists. `commodityMarket(at:)` — consumed by `TradeCenterView` —
calls `commodityPrices(_:)` rather than the raw table, so this is live in the
trade UI.

**Empirically verified against the real base-game data:** none of the 22 base
resource files (`Nova.rez`, `Nova Files/*.rez`) contain any `STR ` (single
string) resources at all — only `STR#` (indexed list) resources
(`novaswift-extract types <file>`, on each). So `commodityBasePrice` returns
`nil` for every commodity in the stock game and the fallback table is what's
live today. The override path is real code that a plugin's own `STR ` 9300-9305
resources would activate — matching the Bible's Appendix III description of
that range as a *plugin* override mechanism, not something the base game
populates.

### 5.2 `jünk` — verified layout

`JunkRes` decodes TMPL #509 (`Templates.rsrc`, 676 bytes, no KEYB/union
ambiguity) via `NovaGame.junk(_:)`/`junks()`. `TradeCenterView.market` builds
junk buy/sell rows straight from `game.junks()`, gated by the `BuyOn`/`SellOn`
NCB tests and the `SoldAt`/`BoughtAt` stellar lists (`TradeRow.Origin.junk`).
Junk shares the pilot's standard-commodity cargo dictionary, including the
Tribbles (multiply) and Perishable (decay) side effects (`tickJunkCargo`).
`ScanMask` contraband is wired through `Contraband.isCargoContraband`, consumed
by `ContrabandScan.swift`.

Layout confirmed via `novaswift-extract tmpl ".../Templates.rsrc" 509`,
cross-checked against all 23 real records in `Nova Data 1.rez` (ids 128-150):

```
SoldAt1-8@0 (8× RSID, 16B)   BoughtAt1-8@16 (8× RSID, 16B)
BasePrice@32 (WORD, 2B)      Flags@34 (WORV, 2B)
ScanMask@36 (WB16, 2B)       LCName@38 (C040, 64B)
Abbrev@102 (C040, 64B)       BuyOn@166 (n0FF/NCB Test, 255B)
SellOn@421 (n0FF/NCB Test, 255B)                    → 676 bytes total
```

Verified against #128 "Vrenna Ice Lizard Pelts": `SoldAt`={219, 449, -1×6},
`BoughtAt`={164, 175, 207, 242, 267, 345, -1, -1} (all real `spöb` ids),
`BasePrice`=750, `Flags`=0, `ScanMask`=2048 (`0x0800`); the ASCII view shows
`"ice-lizard pelts"` and `"Pelts"` landing exactly at the computed
`LCName`/`Abbrev` offsets. Across all 23 records `BasePrice` ranges 50-3000
credits (always plausible) and `Flags` was 0 in every one — no counter-example
of the Tribbles or Perishable bits actually in use exists in the stock data.

### 5.3 `öops` — verified layout

`OopsRes` decodes TMPL #512 (`Templates.rsrc`, 282 bytes, no KEYB/union
ambiguity) via `NovaGame.oops(_:)`/`oopses()`, with
`commodityEnum`/`appliesToAnyStellar`/`isNewsOnly` accessors. The per-day
`Freq` roll and expiry run in `StoryEngine.evaluateDisasters`, called every day
from `advanceDays`, tracking active disasters in `player.activeDisasters`
(stellar/commodity/expiry, keyed by öops id).
`disasterPriceDelta(spobID:commodity:activeOops:)` sums the additive
`PriceDelta` for every active disaster matching a stellar and commodity, and is
consumed by `TradeCenterView.market` on top of the Low/Med/High price.

Two known divergences from [JUNK_OOPS_DESIGN.md](JUNK_OOPS_DESIGN.md):

- The daily roll uses the shared, stateful `StoryRNG` (`rng.chance(percent:)`)
  rather than a pure deterministic hash of `(day, oopsID)`, so it does **not**
  reproduce identically across relaunches the way the `BuyRandom` stocking hash
  does (§B.3 of that doc).
- No UI shows the active disaster's name as a banner in the trade dialog —
  `activeDisasterNames` has no callers, so only the price effect is applied
  (§B.5).

Layout confirmed via `novaswift-extract tmpl ".../Templates.rsrc" 512`,
cross-checked against all 19 real records in `Nova Data 2.rez` (ids 128-146):

```
Stellar@0 (RSID, 2B)      Commodity@2 (CASR 6-case enum, 2B)
PriceDelta@4 (2B)         Duration@6 (2B)
Freq@8 (2B)               ActivateOn@10 (n100/NCB Test, 256B)
[unused]@266 (F010, 16B)                            → 282 bytes total
```

Verified against #128 "An enormous food surplus": `Stellar`=137 (a real `spöb`
id), `Commodity`=0 (food — matching the disaster's own name), `PriceDelta`=-15
(a *surplus* correctly drops the price), `Duration`=30 days, `Freq`=35%,
`ActivateOn`=blank. All 19 records show sane `Freq` (25-75%) and `Duration`
(15-100 days) values, and several have `Commodity` semantically matching the
name: #143 "discovery of a new ore deposit" → 4/metal, #144 "discovery of a new
drug" → 2/medical, #134 "spate of break-downs" → 5/equipment. See §4 for the
resolved `Commodity`-range question.

### Third-party reference check

`third_party/NovaJS` (partial TypeScript reimplementation) has no commodity/
trade/economy logic — its "commodity"/"price"/"trade" hits are all in the
*outfitter* parser/UI (`OutfitParse.ts`, `outfitter.ts`, `OutiftData.ts`),
which is about outfit items, not the six standard trade goods or `jünk`/
`öops`. It offered nothing usable for this doc beyond confirming the
outfitter item-grid metrics already cited in `docs/SHIP_SYSTEM.md`'s sibling
UI work (`SpaceportScreens.swift`).
