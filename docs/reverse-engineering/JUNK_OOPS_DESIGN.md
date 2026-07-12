# Junk & Öops — implementation design (design-first)

Status: **DESIGN ONLY — not implemented.** This is the "design first" step for
wiring the two decoded-but-inert trade resources into the running game. The
reverse-engineering ground truth (byte layouts, field meanings, verified real
records, the resolved `öops.Commodity`-range question) already lives in
[`ECONOMY.md`](ECONOMY.md) §3 (`jünk`), §4 (`öops`) and §5 (implemented-vs-missing).
This document does not re-derive any of that; it turns ECONOMY.md §5's two
"to wire this up would need" sketches into a concrete, buildable plan so the
implementation can proceed without re-litigating the shape.

Decoders in place today: `Sources/NovaSwiftKit/JunkModels.swift` (`JunkRes`,
`NovaGame.junk(_:)`/`junks()`) and `Sources/NovaSwiftKit/OopsModels.swift`
(`OopsRes`, `NovaGame.oops(_:)`/`oopses()`). Neither has a single caller outside
its own model/tests.

---

## Guiding principles (match how the port already works)

1. **Determinism over RNG for anything price/stock related.** The economy is
   already deterministic: stocking (`shïp`/`oütf.BuyRandom`) is a day-seeded
   FNV-1a hash of `(day, spobID, resourceID)`, not `Math.random`
   (`NovaEconomy.swift` ~line 366-380; `PilotStore.swift:366-380` mirrors it).
   Öops activation must use the **same** hash pattern so a market shows the same
   prices whether you relaunch, revisit, or reload a save on the same in-game
   day. No stored RNG state, no per-frame rolls.
2. **BYO-data, no hardcoding.** Everything is driven from the player's own
   `jünk`/`öops` resources; the only constants are the six standard-commodity
   ids (0-5) already defined by `Commodity`.
3. **Save-compatible optionals.** New `PlayerState` fields are optionals (like
   `dominatedStellars: Set<Int>?`) so old saves decode.
4. **The day clock is the single driver.** Öops lifecycles advance inside
   `StoryEngine.advanceDays` next to `payDailyTribute()`/`payDailySalaries()`
   (`StoryEngine.swift:637-642`) — the one place the calendar moves.

---

## Part A — `jünk` (specialty/salvage cargo)

### A.1 What it is (from ECONOMY.md §3)

A parallel, much narrower trade-goods pool (max 128 types) layered on top of the
six standard commodities. A junk type:
- trades **only** at the specific `SoldAt` (buy-from-market) / `BoughtAt`
  (sell-to-market) `spöb` id lists — no galaxy-wide market;
- has one flat `BasePrice` (no Low/Med/High tier);
- is gated by boolean NCB `BuyOn` / `SellOn` expressions (not a percent chance —
  there is no `BuyRandom` for junk);
- may be contraband via `ScanMask` (same mechanism as `oütf.ScanMask`);
- may `multipliesInCargoHold` (Tribbles, `Flags` 0x0001) or `decaysInCargoHold`
  (Perishable, `Flags` 0x0002) over time — though no stock record uses either.

### A.2 Data model

Junk cargo is a **separate hold dictionary** from standard commodities so the
two price models never mix.

```swift
// PlayerState (NovaSwiftStory)
public var junkCargo: [Int: Int]?   // jünk id → tons held. Optional for save-compat.
```

Cargo capacity is shared: junk tonnage counts against the same
`ShipLoadout.cargoCapacity` the standard hold uses. Extend the used/free
accounting so both holds draw from one pool:

```swift
// PilotStore
func totalCargoUsed() -> Int { state.usedCargoSpace + (state.junkCargo?.values.reduce(0,+) ?? 0) }
func cargoFree(galaxy:) -> Int { max(0, cargoCapacity - totalCargoUsed()) }   // updated
```

Every existing `cargoFree`/`cargoUsed` reader (Trade buy gate, mission cargo
load) must switch to the combined figure, or junk + commodities could overflow
the hold together.

### A.3 Trading UI

Surface junk in the existing spaceport trade flow (`TradeCenterView` /
`SpaceportScreens.swift`), not a new top-level screen:
- **A "Specialty Goods" section** shown only when the current `spöb.id` appears
  in some junk type's `SoldAt` or `BoughtAt` list AND its `BuyOn`/`SellOn` NCB
  test passes for this pilot. When the section would be empty, hide it entirely
  (most stations have no junk).
- Buy rows appear for junk whose `SoldAt` contains this stellar; sell rows for
  junk whose `BoughtAt` contains it (and which the player holds). Price is the
  flat `BasePrice` both directions (ECONOMY.md §2 — Low/Med/High collapses to a
  single number for junk).
- Reuse the standard buy/sell tonnage stepper; charge `pilot.credits`, move tons
  into/out of `junkCargo`, respect the combined `cargoFree`.

### A.4 Contraband (`ScanMask`)

`jünk.scanMask` uses the identical bitmask mechanism as `oütf.scanMask`, which is
already wired: `Sources/NovaSwiftStory/ContrabandScan.swift` +
`Sources/NovaSwiftKit/Contraband.swift`. Extend the scan check so a scanning
government whose `ScanMask` shares a set bit with a **held junk type's**
`scanMask` flags the player as carrying contraband, exactly as for illegal
outfits. `Contraband.swift:56` already does `junk(cargoID)` — confirm whether
that path reads `junkCargo` once it exists, or is currently dead.

### A.5 Cargo-hold side effects (Tribbles / Perishable)

Advance in `StoryEngine.advanceDays`, per junk type held:
- `multipliesInCargoHold` → grow the held tonnage (a modest per-day growth,
  capped at combined `cargoFree` so it can't exceed the hold);
- `decaysInCargoHold` → shrink held tonnage, removing the entry at zero.

Both are day-driven and deterministic (no RNG needed — growth/decay is a fixed
schedule). Guard behind a "any junk held?" early-out so the common case is free.
Flag this as **lowest priority**: no stock record sets either flag, so it only
matters for plug-ins.

---

## Part B — `öops` (commodity price "disaster")

### B.1 What it is (from ECONOMY.md §4)

A misnomer — not a catastrophe, just a **timed additive price shift** for one
standard commodity:
- `Stellar`: a specific `spöb` id (128-1628), `-1` = any stellar (galaxy-wide,
  "use sparingly"), `-2` = news-only (no price effect at all).
- `Commodity`: which of the six standard goods (0-5) — resolved as
  standard-commodity-only in ECONOMY.md §4, never a junk id.
- `PriceDelta`: additive credit adjustment (negative = drop). Not a percent.
- `Duration`: days the effect lasts before reverting.
- `Freq`: percent chance **per day** it triggers (a daily Bernoulli roll).
- `ActivateOn`: NCB gate; the disaster can only start on days this evaluates true.

### B.2 Data model

Track active disasters in persistent, save-compatible state so a relaunch on the
same day shows the same market:

```swift
// PlayerState (NovaSwiftStory)
public struct ActiveOops: Codable, Hashable, Sendable {
    public let oopsID: Int
    public let startedDay: Int      // GameDate day-number when it fired
    public let expiresDay: Int      // startedDay + Duration
}
public var activeOops: [ActiveOops]?   // optional for save-compat
```

### B.3 Daily lifecycle (in `StoryEngine.advanceDays`)

Runs once per advanced day, next to `payDailyTribute()`:

1. **Expire** any `activeOops` whose `expiresDay <= today`.
2. **Roll new** for each `öops` resource not already active:
   - skip if `ActivateOn` is non-blank and its NCB test fails for the pilot;
   - fire if `dayHash(day, oopsID) % 100 < Freq`, reusing the **exact** FNV-1a
     `(day, id)` hash the stocking code uses (so it's deterministic and
     relaunch-stable). Do **not** call any RNG.
   - on fire, append an `ActiveOops`; surface the resource's own `name` as news
     (route through the existing `showNews`/`stationNews` path so it reads at a
     station, matching how cron news already surfaces — see
     `AppGameServices.swift:120-127`). `-2` news-only disasters do exactly this
     and nothing else.

Because the roll is a pure function of the day number and the resource id, it
needs no stored RNG and yields identical results across reload/relaunch within a
day — the same guarantee the rest of the economy already gives.

### B.4 Applying the price delta

The **only** place a live commodity price is computed is
`NovaEconomy.commodityPrices(_:)` / `commodityMarket(at:)`
(`NovaEconomy.swift:199,225`). Add the active-disaster delta there:

- `commodityMarket(at spob:)` sums, for every active `öops` whose `Stellar`
  matches `spob.id` (or is `-1` galaxy-wide) and whose `Commodity` matches the
  row, the `PriceDelta`, and applies it additively (clamped ≥ some floor, e.g.
  1cr) on top of the Low/Med/High value it already returns.
- This needs the set of active disasters passed in. Keep `NovaEconomy` a pure
  pricing kernel: add an overload `commodityMarket(at:activeOops:)` (or inject
  the active list), rather than reaching into `PlayerState` from `NovaSwiftKit`
  (which must not depend on `NovaSwiftStory`). The caller in the spaceport (which
  already has the pilot) threads the active list in.

### B.5 Trade UI

`TradeCenterView` shows the active disaster's `name` as a "what's happening here"
banner when any `öops` is active for the current stellar/commodity, per the
Bible. The price rows already reflect the delta via B.4, so this is label-only.

---

## Module-boundary notes

- `NovaSwiftKit` (where `JunkRes`/`OopsRes`/`NovaEconomy` live) **must not**
  import `NovaSwiftStory`. So: pricing takes the active-öops list as a parameter;
  the daily roll + persistence live in `NovaSwiftStory` (`StoryEngine` /
  `PlayerState`); the NCB `BuyOn`/`SellOn`/`ActivateOn` evaluation uses the same
  `NCBTest(...).evaluate(player)` seam `ItemLocking` already uses.
- Junk cargo capacity accounting is the one cross-cutting change with real bug
  potential: every current `cargoFree`/`cargoUsed` reader must move to the
  combined figure at the same time, or holds overflow.

---

## Suggested phasing (each independently shippable)

1. **Öops pricing** — `ActiveOops` state + daily roll + `PriceDelta` in
   `commodityMarket` + trade banner. Highest player-visible value, self-contained,
   no cargo-model surgery. Testable headlessly (advance N days, assert a known
   disaster fires deterministically and shifts the price, then reverts after
   `Duration`).
2. **Junk trading** — `junkCargo` + combined capacity + trade section +
   `BuyOn`/`SellOn` gating. The cargo-capacity refactor lands here.
3. **Junk contraband** — hook `jünk.scanMask` into the existing scan check.
4. **Tribbles / Perishable** — day-driven growth/decay. Lowest priority (no stock
   data exercises it; plug-in-only).

## Test hooks (mirror the domination proof)

- Extend `novaswift-extract` with an `oops <baseDir> <spobID> <day>` subcommand
  that advances the day clock, fires the deterministic roll, and prints which
  disasters are active and the resulting delta on the affected commodity — the
  same headless-proof pattern `tribute` uses for domination.
- Unit tests: deterministic öops firing (same day → same result), expiry after
  `Duration`, additive delta in `commodityMarket`, junk buy/sell moving the right
  tonnage under a shared capacity, `ScanMask` contraband parity with outfits.
