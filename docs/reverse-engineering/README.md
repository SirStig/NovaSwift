# Reverse-engineering docs

The `.rez` data files only encode *static data* (numbers, text, sprites) —
never the *rules* that act on that data. These docs reverse-engineer the
actual game logic, so the team can reimplement it from scratch without
guessing. Same standard as `../AI_GROUND_TRUTH.md` (the original of this
series, kept in `docs/` proper): every claim is a verbatim quote or close
paraphrase of `data/EV Nova/Documentation/Nova Bible.txt` — the official
Ambrosia/Matt Burch developer "Resource Bible" — not a guess, plus a
file:line comparison against what `Sources/NovaSwiftKit`/`NovaSwiftEngine`/
`NovaSwiftStory` actually do today. Where the Bible doesn't give a formula or
number, that's stated explicitly as an open question rather than invented.

| Doc | Resource(s) | Covers |
|---|---|---|
| [GOVERNMENT.md](GOVERNMENT.md) | `gövt`, `ränk`, Appendix I/II | Government relations, legal status/crime tolerance, combat rating, rank/reputation/salary |
| [FLEETS.md](FLEETS.md) | `flët`, `sÿst` | Scripted fleet composition, `LinkSyst` targeting, background system traffic vs. reinforcement fleets |
| [ECONOMY.md](ECONOMY.md) | `spöb`, `jünk`, `öops` | Commodity pricing, junk cargo, price "disaster" events |
| [JUNK_OOPS_DESIGN.md](JUNK_OOPS_DESIGN.md) | `jünk`, `öops` | **Design-first** implementation plan for wiring junk trading + price disasters into the live game (builds on ECONOMY.md §3-5) |
| [DOMINATION.md](DOMINATION.md) | `spöb`, `düde` | Planetary domination ("Demand Tribute"): defense waves, combat-rating gate, daily tribute — **now wired end-to-end** |
| [OUTFITTERS.md](OUTFITTERS.md) | `oütf` | Slots/mass, availability gating, pricing, ammo linkage, `BuyRandom` stocking |
| [EVENTS.md](EVENTS.md) | `crön` | Background timed/triggered events, the activation/hold/start/end lifecycle, galaxy-news |
| [ESCORTS.md](ESCORTS.md) | `përs`, `shïp` | Named NPCs, the real hire/requisition/capture escort system (it lives in `shïp`, not `përs`) |

Not covered here (already owned elsewhere): AI dispositions/combat behavior
→ [`../AI_GROUND_TRUTH.md`](../AI_GROUND_TRUTH.md); mission/NCB scripting,
`crön`/`përs`/`ränk` field offsets → [`../MISSIONS.md`](../MISSIONS.md); ship
+ outfit stat aggregation → [`../SHIP_SYSTEM.md`](../SHIP_SYSTEM.md).

## Standout findings

> **Update:** a follow-up implementation pass landed real Swift for a large
> batch of the gaps this section originally flagged (new decoder fields on
> `GovtRes`/`FleetRes`/`OutfRes`/`SystRes`/`ShipRes`/`CronRes`/`RankRes`/
> `MissionRes`, new `JunkRes`/`OopsRes` models, and behavior wiring in
> `Diplomacy.swift`/`Spawner.swift`/`ShipLoadout.swift`/`PilotStore.swift`/
> `StoryEngine.swift`/`GameServices.swift`). The bullets below are updated to
> match. The single theme all six docs converged on independently: most of
> this new code is **correct and tested but has no live caller** — see each
> doc's own "Implementation status" section (near its top) for the full
> detail this list only summarizes.

- **Escort recruitment now has real backend code — and it's a textbook
  "implemented but completely unwired" case.** `ShipRes` decodes
  `hireRandom`/`escortCategory`/`escortUpgradesTo`/`escortUpgradeCost`/
  `escortSellValue`, and `PilotStore` (`app/NovaSwift/Game/PilotStore.swift`) has
  real, working credit-transaction logic — `hireEscort`/`upgradeEscort`/
  `sellEscort`/`escortAvailableToday`. `EscortsView.swift` was separately
  rebuilt as a geometry-accurate recreation of the real DLOG/DITL #1022
  "Escorts" panel — but it's a **static empty state**: every control is
  disabled, "No escorts hired." is hardcoded, and it has zero data binding.
  A repo-wide grep of `app/NovaSwift/` finds zero call sites for the `PilotStore`
  escort functions outside their own declarations. See ESCORTS.md's
  Implementation status note.
- **`crön`'s byte-truncation bug is fixed, and the fix is confirmed against
  live data, not just source reading.** `OnEnd` now decodes as the correct
  256 bytes (was 255), and `CronRes` gained `contribute`/`require`/
  `newsGovts`/`govtNewsStrs`. Re-running `novaswift-extract raw` against cron
  #128 "Wraith Change" gives exactly the predicted 822-byte size, with
  `newsGovts[0] == 130` and `govtNewsStrs[0] == 15000` landing at the
  predicted offsets. `StoryEngine.evaluateCrons()`/`announceNews(for:)` also
  now implement the full activate→hold→start→end lifecycle and local/
  independent news resolution described in the Bible. See EVENTS.md.
- **The mission/story runtime is more wired into the live app than
  `STATUS.md` previously tracked — discovered while verifying this pass, not
  a product of it.** `app/NovaSwift/Story/AppGameServices.swift` is a real
  `GameServices` conformer, and `MissionBoardView.swift` — embedded in both
  the real Mission BBS (`SpaceportView.swift`) and Bar (`SpaceportScreens.swift`)
  screens — instantiates a real `StoryEngine` per landing; mission offer,
  accept, and decline are genuinely live and persist to the pilot save today.
  However `AppGameServices.showNews` is only a logging stub (no news UI), and
  — the decisive gap — nothing in `app/` ever calls
  `advanceOneDay()`/`advanceDays()`/`evaluateCrons()`, so the galaxy-clock day
  never advances during live play and cron background events (including all
  news) still never fire for a real player. See EVENTS.md's Implementation
  status note; `docs/STATUS.md` has been corrected to match.
- **Government legal status gained real combat-rating plumbing, but combat
  still doesn't call it.** `Diplomacy.isCriminal` now reads each government's
  own `crimeTolerance` instead of one hardcoded threshold, and `Diplomacy`
  gained `recordKill`/`recordDisable`/`recordBoard`/`recordSmuggling`, which
  apply the correct Bible penalty fields (`KillPenalty`/`DisabPenalty`/
  `BoardPenalty`/`SmugPenalty`) instead of the dead `ShootPenalty`. These
  methods are correct but **`World.swift`'s actual combat code still docks
  legal record from `gov.shootPenalty` on every hit** and never calls them —
  combat rating still never increments during real play. Separately,
  `RankRes.contribute`/`MissionRes.require` are decoded and wired into
  `StoryEngine`'s mission-availability check, and **as of 2026-07-12 the
  spaceport purchase-gate (`ItemLocking.contributedBits`) now folds in
  active-rank *and* active-crön `Contribute`** (mirroring
  `StoryEngine.activeContributeBits`), so a rank-gated *purchase* — the Bible's
  own headline example — is finally achievable through the shipyard/outfitter UI.
  See GOVERNMENT.md.
- **`flët.LinkSyst` and `sÿst`'s reinforcement fields are now decoded *and*
  wired — and because `Spawner.swift` is already in the live NPC-spawning
  path (`GameSession.makeWorld`), these two are the rare case in this batch
  that's actually player-visible today**, not just correct-but-inert.
  `Spawner.isFleetEligible` evaluates `LinkSyst`'s five bands and filters
  spawn-table fleets by it; `SystRes.reinforcementFleet`/`reinforcementDelay`/
  `reinforcementRegen` are decoded, and `Spawner.updateReinforcements`
  implements the reactive "summon reinforcements when a government's ships
  are under fire and outmatched" mechanic the Bible and `AI_GROUND_TRUTH.md`
  §2 describe. `flët.AppearOn`/`Quote` are decoded and `AppearOn` is wired;
  `flët.Flags` 0x0001 (freighter random cargo on boarding) is **now wired too
  (2026-07-12)** — `Spawner.spawnFleet` rolls random standard-commodity cargo
  into a fleet's freighters (InherentAI ≤ 2) via `rollRandomFreighterCargo`, so
  boarding a convoy hauler yields loot. See FLEETS.md.
- **`jünk`/`öops` now have real decoder models; commodity base-price
  overrides are wired into the live trade UI, though inert for stock data.**
  `JunkModels.swift`/`OopsModels.swift` add `JunkRes`/`OopsRes`, decoding
  correctly against the byte layouts ECONOMY.md documents — but nothing
  outside `NovaSwiftKit` calls `junk()`/`junks()`/`oops()`/`oopses()` yet, so
  junk trading and price-disaster events remain decoded-but-inert (a
  design-first implementation plan for wiring both now exists —
  [JUNK_OOPS_DESIGN.md](JUNK_OOPS_DESIGN.md)). Separately,
  `NovaEconomy` now reads base commodity prices from `STR ` 9300-9305 (with
  fallback to the hardcoded table) through the same `commodityMarket(at:)`
  path the trade UI already calls — genuinely live, though the stock game
  never actually supplies an override, so it's currently a no-op in practice.
  Planetary tribute (Demand Tribute) is **now fully wired** — see DOMINATION.md.
  See ECONOMY.md.
- **Outfit mass/sell-flag enforcement is real and live in the spaceport;
  pricing and slot limits are computed but not enforced.** `Flags 0x0400`
  (mass-proportional mass) is fully wired into `Galaxy.loadout`'s mass
  aggregation, and `Flags 0x0008`/`0x0010` (can't-sell / consumed-on-purchase)
  are fully enforced in the live `PilotStore.sellOutfit`/`buyOutfit`. But
  `Flags 0x0200` (mass-proportional price) has correct math
  (`OutfRes.effectiveCost`) that `PilotStore.buyOutfit`/`sellOutfit` never
  call — every such outfit in real data is still charged/refunded at flat
  `Cost` — and `Loadout.usedGunSlots`/`freeGunSlots`/`freeTurretSlots` are
  computed but `PilotStore.canBuyOutfit` never reads them, so a player can
  still buy more gun/turret outfits than the hull has mounts for. See
  OUTFITTERS.md.
- **`BuyRandom` is real, not invented** — verified against the Bible for
  both `shïp` and `oütf`, including a one-field asymmetry (`<=0` vs. `==0`
  for "always available") that the current implementation gets right. See
  OUTFITTERS.md's closing section. (Unchanged by this pass.)

## Open questions needing binary disassembly

The Bible is a prose spec, not a formula sheet — several numeric constants
and edge-case behaviors aren't stated anywhere in it. Each doc's closing
section lists what's unresolved from Bible text alone; the recurring ones
that would need `EV Nova.exe` disassembly (a candidate noted in
`AI_GROUND_TRUTH.md`) to pin down exactly:
- The combat-rating formula's "internal multiplier" (GOVERNMENT.md §3).
- Whether government-to-government hostility is symmetric (OR'd) or strictly
  one-directional per declarer (GOVERNMENT.md §1.2).
- The exact Low/Medium/High commodity price arithmetic — the Bible gives
  tiers, not a formula from a single base price (ECONOMY.md §1).
- Whether `crön`'s iterative flags (`0x0001`/`0x0002`, "keep evaluating
  OnStart/OnEnd until EnableOn is no longer true") loop within one day-tick or
  across days (EVENTS.md, closing section) — **note:** the 33-byte undecoded
  tail this item used to also reference is resolved; `OnEnd`'s correct
  256-byte length plus `NewsGovt`/`GovtNewsStr` are now decoded and confirmed
  against live data (see "Standout findings" above), closing the byte gap.
  The iterative-flags execution-model question itself is unaffected by that
  fix and remains open.
- Escort hire-price field and roster capacity — not named anywhere in the
  Bible prose (ESCORTS.md §4).
