# Reverse-engineering

The `.rez` files hold only static data — numbers, text, sprites. They never hold
the *rules* that act on it. These docs recover those rules, per resource, so the
port can reimplement them instead of guessing.

## The standard

Every claim in this folder follows the same contract, so individual docs don't
repeat it:

- **Ground truth is ATMOS's own developer documentation.** Claims are verbatim
  quotes or close paraphrases of `Nova Bible.txt`, the official Ambrosia / Matt
  Burch "Resource Bible" — not inference from watching the game.
- **Field offsets come from the real templates.** ResForge's `TMPL` resources in
  `third_party/ResForge/Plugins/Sources/NovaTools/Templates.rsrc` are
  authoritative. Dump one with
  `novaswift-extract tmpl <Templates.rsrc> <id>` (spöb 520, shïp 518, shän 517,
  wëap 522; `list` the file for the rest), then confirm against real bytes with
  `novaswift-extract raw data/base <type> <id>`.

  Watch for `KEYB`/`KEYE` union sections — the dumper walks them sequentially
  rather than overlaying them, so for `wëap` and `shän` the printed branch
  offsets are *not* the flat record layout.
- **Guesses are labelled.** Where the Bible gives endpoints but no curve, the
  interpolation is called out as our reading, not a documented rule. Where it
  gives nothing at all, that's stated as an open question rather than invented.

**These docs describe the original game, not our progress against it.** For
whether something is implemented, see [STATUS.md](../STATUS.md) — one place, so
nine documents can't disagree.

## The documents

| Doc | Resources | Covers |
|---|---|---|
| [AI_GROUND_TRUTH.md](AI_GROUND_TRUTH.md) | `düde`, `gövt`, `shïp` | AI dispositions and combat behaviour, extracted from the Bible in full |
| [GOVERNMENT.md](GOVERNMENT.md) | `gövt`, `ränk` | Government relations, legal status and crime tolerance, combat rating, rank and salary |
| [FLEETS.md](FLEETS.md) | `flët`, `sÿst` | Fleet composition, `LinkSyst` targeting, background traffic vs. reinforcements |
| [ECONOMY.md](ECONOMY.md) | `spöb`, `jünk`, `öops` | Commodity pricing, junk cargo, price-disaster events |
| [JUNK_OOPS_DESIGN.md](JUNK_OOPS_DESIGN.md) | `jünk`, `öops` | Implementation plan for junk trading and price disasters (builds on ECONOMY.md) |
| [DOMINATION.md](DOMINATION.md) | `spöb`, `düde` | Demand Tribute: defence waves, the combat-rating gate, daily tribute |
| [OUTFITTERS.md](OUTFITTERS.md) | `oütf` | Slots and mass, availability gating, pricing, ammo linkage, `BuyRandom` stocking |
| [EVENTS.md](EVENTS.md) | `crön` | Timed and triggered background events, the activate/hold/start/end lifecycle, galaxy news |
| [ESCORTS.md](ESCORTS.md) | `përs`, `shïp` | Named NPCs, and the real hire/requisition/capture escort system (it lives in `shïp`, not `përs`) |

Covered elsewhere: mission and NCB scripting in [MISSIONS.md](../MISSIONS.md);
hull and outfit stat aggregation in [SHIP_SYSTEM.md](../SHIP_SYSTEM.md);
container and sprite formats in [DATA_FORMAT.md](../DATA_FORMAT.md).

## Open questions

The Bible is a prose spec, not a formula sheet. Each doc lists its own
unresolved points; these are the ones that would need `EV Nova.exe` disassembly
to settle:

- The combat-rating formula's internal multiplier (GOVERNMENT.md §3).
- Whether government hostility is symmetric or one-directional per declarer
  (GOVERNMENT.md §1.2).
- The exact Low/Medium/High commodity price arithmetic — the Bible gives tiers,
  not a formula from a base price (ECONOMY.md §1).
- Whether `crön`'s iterative flags loop within one day-tick or across days
  (EVENTS.md).
- The escort hire-price field and roster capacity, which the Bible never names
  (ESCORTS.md §4).
