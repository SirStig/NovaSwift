# Reverse-engineering

The game's data files hold numbers, text and sprites, not the rules that act on
them. The docs here describe those rules so NovaSwift can implement them.

## Sources, strongest first

1. **The original executable.** The Windows build of EV Nova CE has been
   decompiled in full (3,199 functions). Behaviour read from it is cited by
   function address and name. Where reading wasn't enough, the routine was run
   by itself in an emulator on test inputs and its output recorded. This is the
   final word.
2. **The Nova Bible**, ATMOS's resource documentation (`Nova Bible.txt`). Good
   for intent and field meanings; it gives no formulas.
3. **The resource templates** in
   `third_party/ResForge/Plugins/Sources/NovaTools/Templates.rsrc`, for field
   offsets. Dump one with `novaswift-extract tmpl <Templates.rsrc> <id>` (spöb 520,
   shïp 518, shän 517, wëap 522) and check it against real bytes with
   `novaswift-extract raw data/base <type> <id>`. The dumper walks `KEYB`/`KEYE`
   union sections in sequence instead of overlaying them, so for `wëap` and
   `shän` the printed branch offsets are not the flat record layout.

Most of the per-resource docs below were first written from the Bible and real
data. Where one of them disagrees with
[FIDELITY_PLAN.md](FIDELITY_PLAN.md), the plan is right, because it was checked
against the executable.

No decompiled code is kept here or anywhere in the repository. Specs restate
behaviour in prose, short formulas and constants, with the original address so
anyone with the executable can check them.

These docs describe the original game, not NovaSwift's progress. For that, see
[STATUS.md](../STATUS.md).

## The documents

| Doc | Covers |
|---|---|
| [FIDELITY_PLAN.md](FIDELITY_PLAN.md) | Every difference found between NovaSwift and the original executable, as 177 items with addresses, fixes and tests. Also lists the optional Enhancements and remaining open questions. |
| [NCB_BINARY.md](NCB_BINARY.md) | NCB test expressions, run against the original executable: cursor, counted sets, operators, negation. |
| [PERSON_DEFENSE_BINARY.md](PERSON_DEFENSE_BINARY.md) | `përs` ShieldMod scales armor as well as shields, checked against the executable. |
| [AI_GROUND_TRUTH.md](AI_GROUND_TRUTH.md) | AI dispositions and combat behaviour from the Bible (`düde`, `gövt`, `shïp`). |
| [GOVERNMENT.md](GOVERNMENT.md) | Government relations, legal status, combat rating, ranks (`gövt`, `ränk`). |
| [FLEETS.md](FLEETS.md) | Fleet composition, `LinkSyst`, background traffic and reinforcements (`flët`, `sÿst`). |
| [ECONOMY.md](ECONOMY.md) | Commodity prices, junk cargo, price disasters (`spöb`, `jünk`, `öops`). |
| [JUNK_OOPS_DESIGN.md](JUNK_OOPS_DESIGN.md) | The original design notes for junk trading and price disasters. |
| [DOMINATION.md](DOMINATION.md) | Demand Tribute, defence waves, daily tribute. |
| [OUTFITTERS.md](OUTFITTERS.md) | Outfit slots, mass, availability, pricing, ammo (`oütf`). |
| [EVENTS.md](EVENTS.md) | `crön` events and galaxy news. |
| [ESCORTS.md](ESCORTS.md) | Named NPCs, and hired, requisitioned and captured escorts (`përs`, `shïp`). |

Also: missions and NCB scripting in [MISSIONS.md](../MISSIONS.md), hull and
outfit stats in [SHIP_SYSTEM.md](../SHIP_SYSTEM.md), file formats in
[DATA_FORMAT.md](../DATA_FORMAT.md).

## Open questions

Most questions these docs used to list were settled from the executable,
including the combat-rating multiplier (WP-04), commodity price arithmetic
(EC-03), `crön` iteration (MS) and hire prices (EC-09). What is still open is in §6 of
[FIDELITY_PLAN.md](FIDELITY_PLAN.md).
