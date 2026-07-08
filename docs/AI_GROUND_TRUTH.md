# AI ground truth — extracted from ATMOS's own developer docs

Source: `Documentation/Nova Bible.txt` (the official EV Nova plugin-developer
"Resource Bible", ©1995-2004 Ambrosia Software / Matt Burch) inside the user's
owned `EV Nova CE` install. Read in full (not sampled) — every field below is a
direct quote/paraphrase of that document, not a guess. This is the actual
design spec the original AI was built against — much stronger ground truth
than reverse-guessing from behavior descriptions.

A second artifact exists if we ever need exact runtime math the Bible doesn't
give us: `EV Nova.exe` at `~/Downloads/EV Nova/EV Nova.exe` (x86 PE, not fully
stripped) — a candidate for disassembly later.

**The core correction to how we'd been thinking about this:** EV Nova's AI is
not "4 dispositions, each a fixed rule." It's 4 base dispositions layered with
several independent sources of *variance*, some universal, some only applying
to ~5% of ships, some only under mission control. See "Where behavior varies"
below — that's the part our current `AIBrain` is missing almost entirely.

## 1. The four base dispositions (`düde.AIType`)

| AIType | Real behavior (verbatim intent) |
|---|---|
| 1 Wimpy Trader | Visits planets and runs away when attacked |
| 2 Brave Trader | Visits planets and fights back when attacked, **but runs away when his attacker is out of range** |
| 3 Warship | Seeks out and attacks his enemies, or jumps out if there aren't any |
| 4 Interceptor | Seeks out his enemies, or **parks in orbit around a planet** if none exist. **Buzzes incoming ships to scan them for illegal cargo.** Acts as **"piracy police"**: attacks any ship that fires on or attempts to board another, non-enemy ship while it's watching. |

Two concrete corrections vs. our current `AIBrain.swift`:
- **Brave Trader's flee condition is attacker-out-of-range, not our-hull-%.**
  We currently flee braveTrader at `armorFraction < 0.4` — not documented
  anywhere; the real trigger is range-based.
- **Interceptor is piracy police, not "aggressive warship that closes
  distance."** It should orbit-park when nothing's hostile, scan/buzz
  passersby for illegal cargo, and intervene on behalf of *any* non-enemy
  ship under attack — a 3rd-party-defense behavior we don't have at all.

`düde.AIType = 0` means "use the ship's own inherent AI" (`shïp.InherentAI`,
only meaningful for escorts).

## 2. Combat-odds gating (`gövt.MaxOdds`) — completely missing from our sim

> "Combat odds are calculated by summing the strengths of the ship's enemies
> (`shïp.Strength`, modified between 30% and 100% of that value depending on
> the ship's present shield stat) and comparing it to the sum of the strength
> of the ship's friends. A value of 100 in this field represents 1-to-1 combat
> odds... 200 represents 2-to-1... won't engage if outnumbered by more than
> 2-to-1."

This is the single biggest behavioral gap. Real Nova ships **do a cost-benefit
calculation before picking a fight** — a lone interceptor won't charge a
4-ship convoy even if hostile. We already decode `GovtRes.maxOdds` and
`ShipRes.strength` (`NovaAIModels.swift:163`, `NovaModels.swift:162`) — **they
are never read anywhere in `AIBrain`/`Diplomacy`/`World`.** This alone
explains a lot of "toothless"/uniform-feeling combat: everything just charges
in regardless of numbers.

Also related: **reinforcement fleets** (`sÿst.ReinfFleet`) get called in
specifically when "ships allied with the reinforcement fleet's government are
under attack and the combat odds against them exceed `MaxOdds`" — i.e. the
same calculation gates a second, dynamic layer of population.

## 3. Disable is a deterministic armor threshold, not a coin flip

> `shïp.Flags 0x0010`: "Ship is disabled at 10% armor instead of 33%."

The *default* (flag unset) is **disabled at 33% armor** — this is implied
directly by the flag's phrasing ("instead of 33%"). Our current
`World.swift:522-534` instead lets armor hit 0 ("killed"), then rolls a random
`disableChance` (0.6 trader / 0.18 warship / 0.35 default) to decide disabled
vs. destroyed. That's our own invention; the real mechanic is a hard
percentage-of-max-armor trigger, checked continuously as armor drops, not a
post-mortem dice roll. (We do already decode `shïp.Flags` — worth checking
whether bit 0x0010 is captured; if not, that's a one-line decoder addition.)

## 4. Where behavior varies (this is the user's point — it isn't monolithic)

EV Nova deliberately layers several independent randomization/variance
sources on top of the base 4-type model:

1. **`përs` resources (named individuals).** "When ships are created, there
   is a 5% chance that a specific AI-person will also be created." A `përs`
   has its own:
   - `Aggress` (1–3): "how close ships have to be before the person will
     attack" — engagement-range variance per character, not a global constant.
   - `Coward` (%): "at what percent of shield capacity will the person run
     away" — e.g. 25 flees at 25% shields. This is a **per-character**
     retreat threshold, distinct from the government-level 25%-shields
     retreat flag (`gövt.Flags 0x0010`, which is opt-in per-government and
     when *unset* means "fight to the death" — also not universal).
   - `ShieldMod`, custom weapons/ammo loadout, custom credits, grudge-holding
     flag (attacks the player on sight forever after being attacked once).
   - The other 95% of ships get baseline AIType behavior with no such
     per-individual tuning (in the original — but nothing stops us from
     giving *every* NPC a touch of derived variance for a livelier universe).
2. **`shïp.SkillVar`** (1–50%): "the amount... to which this ship's pilots'
   skill varies... a skill variance of 10% would make each ship of a given
   type up to 10% slower or faster than stock" — per-ship-instance accel/turn
   jitter, applied every time a ship is created.
3. **`gövt.SkillMult`**: a global government-wide skill multiplier (50 =
   half as skilled, 150 = 50% more skilled) — some factions are just
   better/worse pilots across the board.
4. **Dude probability tables** — which ship class spawns for a given `düde`
   slot is already probabilistic (we have this).
5. **Ammo-out behavior is conditional**, not universal:
   `shïp.Flags2 0x0080`: "AI ships of this type will run away/dock if out of
   ammo for all ammo-using weapons" — only ships with that flag do this; a
   beam-only warship never runs dry and never triggers it.
6. **Cloak-driven AI behavior is per-ship-type-flagged**, and there are seven
   independent triggers (`shïp.Flags2`): cloak when weapon in burst reload
   (0x0100), cloak when running away (0x0200), cloak when hyperspacing
   (0x0400), cloak when just flying around (0x0800), won't uncloak until
   close to target (0x1000), cloak when docking (0x2000), cloak when
   preemptively attacked (0x4000). A given ship type might have any subset.
7. **Bribery** is opt-in per-government and per-ship-class-of-govt
   (`gövt.Flags`: 0x0200 warships take bribes, 0x2000 freighters take bribes,
   0x8000 pirates demand more but always take them) — a probabilistic
   "avoid the fight by paying" escape valve that's govt-specific.
8. **Mission/special-ship overrides replace standard AI outright.**
   `mïsn.ShipBehav`: -1 = use standard AI, 0 = "always attack the player", 1 =
   "protect the player", 2 = "attempt to destroy enemy stellars." Mission
   special ships (up to 31 per mission) can also have goals layered on top
   (destroy/disable-only/board/escort/observe/rescue/chase-off) that
   completely change what "success" looks like for that ship, independent of
   its AIType.
9. **Xenophobic vs. not** is per-government (`gövt.Flags 0x0001`): only some
   factions attack everyone-but-allies; most only fight declared enemy
   classes or a hostile player.
10. **Jamming affects targetability itself**, not just accuracy: government
    inherent jamming (`InhJam1-4`, 0-100% per of 4 types) and per-weapon
    `JamVuln1-4` interact; freighters get "50% of the standard InherentJam
    value for warships of the same government" (`gövt.Flags 0x0080`) — so a
    trader and a warship of the *same* government aren't equally hard to hit.
    Guided weapons have their own jam-reactions: "turns away if jammed"
    (`wëap.Seeker 0x0010`) vs. "may attack parent ship if jammed" (0x8000) —
    a jammed missile can behave in two opposite ways depending on the weapon.
11. **Point-defense and turret blind spots** mean not every mount can track
    every target: turrets can have front/side/rear blind spots
    (`shïp.Flags 0x1000/0x2000/0x4000`, and independently per-weapon in
    `wëap.Flags`), front/rear-quadrant-only turrets (Guidance 7/8, ±45° arcs),
    and dedicated PD mounts (Guidance 9/10) that "fire automatically at
    incoming guided weapons and nearby ships" — an entirely separate targeting
    loop from the main attack routine.
12. **Standoff-attack and swarming are per-ship-type flags**
    (`shïp.Flags2 0x0001` swarm, `0x0002` prefers standoff) — currently we
    hardcode "interceptors crowd, everyone else holds range" in `AIBrain`
    rather than reading a ship-type flag.
13. **Ionization can freeze a ship's ability to act**: `oütf` ModType 39/40
    (ion dissipator/absorber) and `wëap.Ionization` — a sufficiently-ionized
    ship is "nearly immobilized," and guided weapons "can't fire if ship is
    ionized" (`wëap.Seeker 0x0020`). We don't model ionization at all yet.
14. **Planetary defense fleets** (`spöb.DefenseDude`/`DefCount`) can launch in
    waves (encoded packed digits, e.g. 1082 = four waves of two), and
    **stellar weapons** can be set to "only fire when provoked" vs. always —
    another per-stellar behavioral switch, not universal.

## 5. Combat mechanics we don't model at all yet

- **Point defense** (Guidance 9 turret / 10 beam): auto-fires at incoming
  guided shots and nearby ships; separate from the main weapon-select loop.
  Some guided weapons are explicitly PD-immune (`wëap.Flags 0x0080`).
  PD damage to guided shots is "100% of mass damage plus 50% of energy
  damage," and guided shots have a `Durability` (PD hits survived).
- **Recoil** (`wëap.Recoil`): firing can thrust the ship, inversely
  proportional to mass — heavy weapons on light ships kick.
- **Tractor beams** (`wëap.Impact` negative on a beam): pulls small ships in,
  or lets a small ship "latch onto" something bigger.
- **Disable-only weapons** (`wëap.Flags2 0x1000`): can disable but never
  destroy — a distinct weapon-level property, separate from the ship-level
  33%/10% disable threshold.
- **Fast-ship immunity for some guided weapons** (`wëap.Flags 0x0008`):
  "don't fire at fast ships (turn rate > 3)" — a guided weapon that simply
  won't lock certain nimble targets.
- **Recursive submunitions** with a split-count cap, and "submunitions fire
  toward nearest valid target" as an optional flag.
- **AI-excluded weapons** (`wëap.Flags2 0x0100`): "AI ships won't use this
  weapon" — some weapons are player-only in practice.

## 6. Priority read for implementation (rough order)

1. Combat-odds gating (`MaxOdds` vs. summed `Strength`×shield-scaled friend/foe) —
   biggest behavioral lever, data already decoded, just unused.
2. Deterministic 33%/10% armor disable threshold, replacing the random roll.
3. Interceptor real behavior (park/scan/piracy-police) — currently
   mislabeled as "aggressive warship."
4. Brave Trader flee-on-out-of-range instead of hull-%.
5. Per-govt retreat-at-25%-shields as an opt-in flag (`warshipsRetreat`
   already models this correctly — worth double-checking it's actually
   flag-gated per govt and not applied as a blanket rule).
6. SkillVar/SkillMult pilot-quality jitter — cheap, high variance payoff.
7. Ammo-out retreat/dock flag.
8. Cloak-triggered AI flags (for ships that carry cloaking devices).
9. Point defense as a second targeting loop.
10. Bribery escape valve.
11. Ionization modeling.
12. Mission ShipBehav overrides (only matters once missions drive spawns).

This list is ground truth, not yet a plan — next step is deciding how much of
this to actually implement now vs. defer.
