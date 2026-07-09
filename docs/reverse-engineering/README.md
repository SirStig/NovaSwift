# Reverse-engineering docs

The `.rez` data files only encode *static data* (numbers, text, sprites) —
never the *rules* that act on that data. These docs reverse-engineer the
actual game logic, so the team can reimplement it from scratch without
guessing. Same standard as `../AI_GROUND_TRUTH.md` (the original of this
series, kept in `docs/` proper): every claim is a verbatim quote or close
paraphrase of `data/EV Nova/Documentation/Nova Bible.txt` — the official
Ambrosia/Matt Burch developer "Resource Bible" — not a guess, plus a
file:line comparison against what `Sources/EVNovaKit`/`EVNovaEngine`/
`EVNovaStory` actually do today. Where the Bible doesn't give a formula or
number, that's stated explicitly as an open question rather than invented.

| Doc | Resource(s) | Covers |
|---|---|---|
| [GOVERNMENT.md](GOVERNMENT.md) | `gövt`, `ränk`, Appendix I/II | Government relations, legal status/crime tolerance, combat rating, rank/reputation/salary |
| [FLEETS.md](FLEETS.md) | `flët`, `sÿst` | Scripted fleet composition, `LinkSyst` targeting, background system traffic vs. reinforcement fleets |
| [ECONOMY.md](ECONOMY.md) | `spöb`, `jünk`, `öops` | Commodity pricing, junk cargo, price "disaster" events |
| [OUTFITTERS.md](OUTFITTERS.md) | `oütf` | Slots/mass, availability gating, pricing, ammo linkage, `BuyRandom` stocking |
| [EVENTS.md](EVENTS.md) | `crön` | Background timed/triggered events, the activation/hold/start/end lifecycle, galaxy-news |
| [ESCORTS.md](ESCORTS.md) | `përs`, `shïp` | Named NPCs, the real hire/requisition/capture escort system (it lives in `shïp`, not `përs`) |

Not covered here (already owned elsewhere): AI dispositions/combat behavior
→ [`../AI_GROUND_TRUTH.md`](../AI_GROUND_TRUTH.md); mission/NCB scripting,
`crön`/`përs`/`ränk` field offsets → [`../MISSIONS.md`](../MISSIONS.md); ship
+ outfit stat aggregation → [`../SHIP_SYSTEM.md`](../SHIP_SYSTEM.md).

## Standout findings

A few things surfaced during this pass that are worth flagging up front
because they change what the team should build next, not just what it
should document:

- **Escort recruitment doesn't live where anyone assumed.** There's no
  hire/requisition logic in `përs` — it's entirely in `shïp` fields
  (`HireRandom`, `EscortType`, `UpgradeTo`, `EscUpgrdCost`, `EscSellValue`)
  plus `dësc`'s reserved requisition-dialog IDs, none of which are decoded
  yet. The recent "assistance mechanics" commit is an unrelated one-shot
  paid tow-truck hail service, not escort recruitment. See ESCORTS.md §2.2–2.3.
- **`crön` resources are silently truncated.** Real crons are 822 bytes;
  `CronRes` only decodes 789, dropping the `NewsGovt`/`GovtNewsStr` news
  fields — confirmed against real game data, not just source reading. See
  EVENTS.md's gap table.
- **Government legal status is mostly dead code.** `CrimeTol` is decoded but
  never consulted; the live penalty path (`ShootPenalty`) is the one field
  the Bible itself says is "currently ignored," while the fields that should
  matter (`KillPenalty`/`DisabPenalty`/`BoardPenalty`/`SmugPenalty`/
  `ScanFine`) aren't read anywhere. Combat rating never increments during
  play. See GOVERNMENT.md §5.
- **`BuyRandom` is real, not invented** — verified against the Bible for
  both `shïp` and `oütf`, including a one-field asymmetry (`<=0` vs. `==0`
  for "always available") that the current implementation gets right. See
  OUTFITTERS.md's closing section.
- **`FleetRes.linkSystem` is decoded but has zero call sites** — dead data;
  and `sÿst.ReinfFleet`/`ReinfTime`/`ReinfIntrval` aren't decoded on `SystRes`
  at all, so reinforcement fleets can be gated (`gövt.MaxOdds`) but never
  actually summoned. See FLEETS.md §5, §7.
- **`jünk`, `öops`, and Tribute are entirely unimplemented** — four-char
  codes may be registered, but there are no resource models or call sites.
  See ECONOMY.md §5.

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
- The 33-byte undecoded tail of `crön` and whether its iterative flags loop
  within one day-tick or across days (EVENTS.md, closing section).
- Escort hire-price field and roster capacity — not named anywhere in the
  Bible prose (ESCORTS.md §4).
