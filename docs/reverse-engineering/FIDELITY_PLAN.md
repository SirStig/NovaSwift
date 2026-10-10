# Fidelity plan — matching the original engine

The other docs in this folder recover rules from the Nova Bible. This one is different: it is an
**implementation plan** built from engine-level audits that compared NovaSwift against a
reconstruction of the original EV Nova CE Windows executable. It merges and de-duplicates those
audits, re-checks the doubtful claims against a raw Ghidra export of the executable, and orders
the work into batches. The first consolidation covered five audits (flight, weapons, AI, economy,
missions). A second pass folded in the exe-level answers to the open questions, two new areas
(outfit special systems, player-facing rules) and a binary coverage map.

## Sources

| Source | Where | What it is |
|---|---|---|
| Audits | `~/Projects/evnova-re/audit/{flight,weapons,ai,economy,missions}.md` | Five read-only audits dated 2026-10-09; this plan supersedes them as the working list |
| Open questions resolved | `~/Projects/evnova-re/audit/open_questions_resolved.md` | Answers to the audits' open questions read straight from the exe (sections A1–A10 flight/RNG, B1–B7 weapons, C1–C8 economy, D1–D12 AI/missions). Folded into the items below; cited as "OQ A1" etc. |
| Outfit special systems | `~/Projects/evnova-re/audit/outfits_special.md` | Outfit ModTypes, cloak, fighter bays, escape pods, radar/IFF/density scanner, bombs, gravity, stellars → `OS-xx` items |
| Player-facing rules | `~/Projects/evnova-re/audit/ui_rules.md` | Saving, Strict Play, star map, targeting, landing/hail flow, HUD and status-bar strings, Player Info, keys, pilot-file state, plug-in order → `UI-xx` items |
| Coverage map | `~/Projects/evnova-re/audit/coverage.md` (+ `function_map.tsv`) | Port coverage of all 3199 exe functions; see §7 |
| Function oracle | `~/Projects/evnova-re/oracle/` (`README.md`, `examples/`) | A Unicorn harness that executes single original functions on synthetic inputs, with no game, Wine or Windows API. It has pinned the RNG, the thrust/max-speed formulas, the NCB TEST evaluator and the NCB SET interpreter. Wherever a test below says **Oracle**, generate the expected values by running the named address under it rather than from prose |
| Decomp | `~/Projects/evnova-re/evnova-decomp` | wraitii's MIT-licensed C++ reimplementation derived from the decompiled exe (`@port 0xADDR` / `Ghidra 0xADDR` tags) |
| Ghidra export | `~/Projects/evnova-re/decomp/functions/<addr>_<name>.c` (index in `index.tsv`) | Raw pseudo-C of every function in the exe; used here to spot-check |
| Executable | `~/Projects/evnova-re/bin/EVNova.exe`, SHA-256 `4fd5d9b4b98a0ea8ae479a582e0c353f30d75cb86816d1435cedaf591ceaef32` | PE32 x86, image base `0x00400000`. Floating-point constants quoted below were read directly from its `.rdata` |

This is not the binary that [NCB_BINARY.md](NCB_BINARY.md) pinned (that one is the WineNova CE
image, `08fa47d2…`). Addresses in this doc refer to the `4fd5d9b4…` build only.

**Legal boundary.** Nothing decompiled is reproduced here. Behaviour is restated in prose, short
formulas and constants, with the original function address and its Ghidra name so an implementer
can re-derive it. Neither decompiled C nor the decomp's C++ belongs in this repo.

## The ruling

> Default gameplay must match the **original** game exactly, including its quirks and bugs.
> Any NovaSwift behaviour that is not original stays only as an optional **Enhancement**
> setting, **default OFF**.

What that means in practice:

- Where the decomp marks its own `BUGFIX` / `DIVERGENCE` / "feel tuning", the original arm wins.
  The decomp's fixes are not the original game.
- Known original bugs are targets, not defects: the frame-rate-dependent afterburner, the
  "good record makes the owner's enemies attack you" inversion, the `{!…}` negate latch, the
  tech-markdown cap and so on.
- Each item is one of two classes.
  - **FIX**: change the default to the original. The current behaviour is an approximation with
    no design value of its own and is dropped.
  - **FIX+ENH**: change the default to the original *and* keep today's behaviour behind a named
    Enhancement toggle (default off). Toggles are listed in §3.

## How to read an item

Each item has an ID (`FL` flight, `WP` weapons and damage, `AI` NPC AI, spawning and escorts,
`EC` economy, government and landed services, `MS` missions and story, `LD` loader, `OS` outfit
special systems, `UI` player-facing rules, saving and pilot state), the original behaviour with
addresses, today's NovaSwift code, its class, impact and confidence, and a test idea.

- Items marked **DONE** have landed; they stay in the list so their IDs remain stable.
- "Settled (user)" marks a decision the user has made; it replaces the open decision.

- NovaSwift `file:line` references were re-checked against the working tree on 2026-10-09.
  A concurrent agent edits this tree, so treat lines as anchors. Search for the named symbol if
  a line has moved.
- Paths are repo-relative. `Engine/` = `Sources/NovaSwiftEngine/`, `Kit/` = `Sources/NovaSwiftKit/`,
  `Story/` = `Sources/NovaSwiftStory/`, `App/` = `app/NovaSwift/`.
- Time units. The original's normalized tick is 1/30 s (`Frame_MeasureFrameTiming` 0x00432ea0
  publishes `elapsed_ms × 0.03`), so px/tick × 30 = px/s and px/tick² × 900 = px/s². Some
  original code runs once per *raw* ~21 ms call instead; FL-01 covers that.
- Confidence describes the reading of the original. "Exe-verified" means the constant or branch
  was confirmed in the Ghidra export and the executable during this consolidation.

---

## 1. Spot-check results

The claims below were the ones most likely to be wrong, or ones where two audits disagreed. Each
was re-read in the Ghidra export, with constants read from the executable.

**Confirmed (exe-verified):**

| Claim | Function | Result |
|---|---|---|
| Combat rating ×0.2, +1 below strength 5, cap 10,000,000 | 0x0046f1e0 `Frame_AddCombatRatingPoints` | Confirmed. The constant at `0x00575870` is 0.2, and the result is truncated by the exe's x87 round-and-correct idiom. At or above the cap, the rating is *set* to exactly 10,000,000. |
| NPC cooldown ladder vs the player | 0x00414550 `Weapon_FireShipWeapons` | Confirmed: ×1.75 / 1.5 / 1.25 / 1.1 (`0x00575118`/`130`/`1d0`/`1c0`) below class-0 Strength × 100 / 400 / 800 / 1600. Applies only when the shot's target slot is the player. |
| Strict Play ×1.5 top speed | 0x004642e0 `Ship_ComputeShipEffectiveMaxSpeed` | Confirmed: `0x005757b8` = 1.5, applied to the player and to ships whose squad leader is the player, when strict-play byte `0x00596d2f` is 0. |
| Thrust ×2.0 | 0x004640a0 `Ship_ComputeShipEffectiveThrust` | Confirmed: `0x005757a8` = 2.0 for the player and for NPCs. **Correction to the flight audit (D13):** a velocity-matched NPC gets ×0.333 (`0x00575788`) *instead of* ×2.0, so its thrust is 1/6 of normal, not 1/3. Its top speed is ×0.333. |
| Disable threshold 33.333 % / 10 % | 0x004687b0 `Ship_IsShipDisabled` | Confirmed: `armor×100 < maxArmor×33.333` (10.0 with hull Flags 0x10). The player is **not** exempt. Two extra arms the audits did not list: a ship of a government with Flags 0x0800 is always disabled, and an un-boarded ShipGoal-5 (rescue) mission ship is always disabled. |
| Fuel regen is `1/FuelRegen` per tick | 0x00463b30 `Ship_ComputeShipFuelRechargeRate` | Confirmed. The player needs hull Flags 0x0008; NPCs always qualify. Each ModType-18 outfit adds `count × (1/ModVal)`. NPCs count their stock outfits. |
| Hyperspace travel days | 0x00465550 `Stellar_ComputeHyperspaceTravelDays` | Confirmed, plus a quirk the audits missed. The ModType-22 term is `count × ModVal` **cast to unsigned 16-bit** before it is added, so a negative ModVal wraps to roughly +65535 days instead of subtracting. The `≥ 1` floor tests only the low 16 bits. See open question Q-FL-12. |
| Commodity prices | 0x0048c730 `NovaUi_RunTradeCenterWindow` | Confirmed: scale 1.25, or 1.1 when the stellar is governed and system reputation < 0, or 1.5 when dominated (the dominated test runs last and wins). Low = trunc(base/scale), Medium = base, High = trunc(base×scale), floor 5. An active öops replaces the price with `base + delta`, floor 5. **Corrected (OQ C7):** the first pass read the junk-row `break` as ending the scan. It exits only the inner 8-stellar loop, so later junks overwrite earlier ones and the **highest-index** qualifying junk wins, for both rows. |
| Outfit resale ×0.5 | 0x0048ea70 `NovaUi_RunOutfitterInteractionLoop` | Confirmed: `0x00575940` = 0.5 when the owned count is ≤ the count held when the outfitter opened. The resale base is the unscaled `Outfit_ComputeOutfitPurchasePrice` (0x0046e910). `Outfit_ComputeScaledPurchasePrice` is called and its result discarded, which confirms the "rank PriceMod never reaches outfits" quirk. A sale is also refused if it would push free mass below 0. |
| Splash damage | 0x00437780 `Shot_ResolveShotCollisionHit` | Confirmed: per-axis `|d| ≤ BlastRadius` (inclusive), **raw** weapon mass/energy damage with no decay and no ×0.5, impact passed through, and no government gate. The directly hit ship is excluded from the splash pass. Owner immunity: an NPC owner always, the player only with wëap Flags 0x0100. |
| Warship retreat thresholds | 0x00402e50 `Ship_UpdateShipAiBehavior0x03_Warship` | Confirmed: cadence 1 → 0.3 × maxShield, 2 → 0.15, otherwise never. The përs arm uses Coward × 0.01 × maxShield. The odds arm fires below 0.5 shields with odds > MaxOdds. An armed warship keeps a disabled target while `Weapon_HasAnyFireableNonSecondaryWeapon` is true. |
| Rank `L` on a permanent rank | 0x00427f40 `Rank_Deactivate` | Confirmed: an active rank is always cleared. 0x0008 only shields *siblings* from the 0x0002 and 0x0020 cascades. |

**Resolved disagreements:**

- **Escort cap polarity** (AI §C.2, economy Q4). 0x00468920 `Ship_CanPlayerHaveMoreEscorts`
  counts active ships with squad leader = player, behavior 6, and mission-fleet slot == −1, so it
  counts **non-mission** escorts. The cap is `< 6`. The decomp's *code* has the polarity
  inverted; its docs are right.
- **Capture-odds escort term** (economy Q4). 0x00484230 `Boarding_BuildOptions` uses the same
  non-mission filter plus one more: the escort's class field +0x12 must be > 2, believed to be
  InherentAI. Such escorts add 0.1 × their crew **and** 0.1 × their Strength to the player's
  totals. The odds are then `trunc(crew / (targetCrew × 10) × 100)`.
- **Outfitter and shipyard time costs** (economy Q1). `NovaUi_RunTravelDestinationInteractionLoop`
  0x00491f30 runs one daily tick when the departing visit included any outfit buy or sell (flag
  `0x007d4c04`, set at both sites in 0x0048ea70), and **four** daily ticks when a ship was bought
  (flag `0x007d4c05`, set in 0x00492f30). This is in addition to the launch tick.
- **Who scans for contraband** (AI A13 vs economy D10). 0x00401800 accepts any behavior-3 or
  behavior-4 scanner, but its only caller is `Ship_UpdateShipAiState` 0x00405590 (the state-7
  approach). The two audits agree once the scanner/trigger split is explicit.
- **Strict Play has more consumers than speed.** Byte `0x00596d2f` is also read by
  `Ship_RunSpaceflightMode` 0x00489210, which deletes the pilot file on death ("deleting pilot
  file due to strict play death"), except when the ship is class index 0x2ff (shïp 895, the
  escape pod). It is read in the player-ship core 0x0044aa70 by the escape-pod respawn, which
  saves only under Strict Play. It also scales the Max Speed row of the player-info window
  0x0049a540 by 2/3 when not strict, and is saved in the pilot (0x004c7dd0 / 0x004cb260).
  **Corrected:** the first pass said strict play auto-saves after every hyperjump arrival. The
  ui_rules audit enumerated all five call sites of `PilotFile_SaveGame` 0x004c7db0 (new game,
  spaceport launch tail, the strict-only pod respawn); none is on the hyperjump-arrival path.

**Second-pass corrections** (OQ = `open_questions_resolved.md`):

- Junk trade rows: highest index wins, not first match (OQ C7; EC-03).
- Player turn rate truncates, so Maneuver 25 gives 2°/tick (OQ A2; FL-10).
- përs slot 0x3ff is the shareware License Enforcer, which a registered copy never spawns. Its
  ×2 speed/thrust and +1 turn are dropped from FL-15 (OQ A10). Slot 0x3fe stays real: it is the
  revenge/ambush përs of AI-16, never bribable, and dies only 1 time in 8 when destroyed.
- "Bay fighters take 75 % damage" is not a damage factor: behavior-5 ships have ×1.333 max
  shield and armor and ×1.333 shield regen, not armor regen (OQ B3/B7; AI-41, OS-03).
- Negative Inaccuracy has no radians/degrees quirk; it is a decomp port bug (OQ B4; WP-21).
- Planetary bribes clamp to [1000, 900000], not 20000 (OQ C3; EC-25).
- Gate and wormhole transit costs 0 days (outfits_special O6, corroborated by the exhaustive
  daily-tick caller list in OQ C2; OS-06).
- Landing day: OQ C2 counts "+1 per landing" in 0x00455e10 and FL-05 said "launch ticks once" in
  the same function. 0x00455e10 is the whole dock-and-launch sequence, so the net is one tick per
  landing visit; only its moment within the visit is unpinned.

---

## 2. Existing GameSettings against the ruling

`App/App/GameSettings.swift` (the `// MARK: Gameplay` block at :234–266).

| Setting | Default | Original? | Mapping under the ruling |
|---|---|---|---|
| `difficulty` (`playerDamageScale` 0.3 / 0.6 / 1.0 / 1.5, applied at `Engine/World.swift:2773`) | `.normal` = ×1.0 | Default is faithful; the other values are invented | Move under Enhancements (Batch 0: the Settings picker now sits there). The original's own difficulty curve is the rating-based NPC fire ramp (AI-03) plus Strict Play (FL-03); neither exists today. |
| `systemAliveness` (`populationScale`, `passThroughChance`) | `.authentic` (was `.normal`; changed in Batch 0) | **No.** `.normal` is the engine's invented population (floor 3, cap 18, 6 s refill, guaranteed fleet, 26 s fleet timer). Even `.authentic` (×0.55 plus 55 % pass-through) is not the original. | Add `.original` (exactly `AvgShips`, original refill and fleet rates; AI-09/10) and make it the default. The existing values become Enhancement presets. |
| `gameSpeed` | `.x1` | Default faithful | Keep. Non-×1 values are an enhancement. The comment's claim of a Caps-Lock ~2× mode in the original is unverified. |
| `controlSensitivity` (→ `ControlTuning.turnScale`, `Engine/World.swift:23`) | 1.0 | ×1.0 is neutral, but the player's turn rate is not quantized today (FL-10) | After FL-10, values other than 1.0 are an enhancement that bypasses quantization. |
| `autoLanding` | off | Port-only autopilot (`App/Game/GameScene.swift:608` `stepAutoLand`; the decomp's `flight_automation.cpp` is clean-room too) | Already compliant: an Enhancement, default off. |
| `autoTargetAfterFiring`, `confirmLanding`, `mouseAiming` | off | Input conveniences | Compliant (off). |
| `tutorialHints` | on | Presentation, no gameplay effect | Outside the ruling. |
| `shipBarPosition` | `.above` | **Not original** (the original never floated bars over ships) | Presentation. Needs a user decision on whether the ruling covers presentation defaults. |
| `frameRateCap` | platform | Render only; the sim is a fixed 30 Hz step | Outside the ruling. |

**Non-original defaults hidden in engine code (not exposed as settings):**

| Knob | Where | Note |
|---|---|---|
| ~~`FlightTuning.default` (0.55 / 0.55 / 3.0)~~ | Now the `portFlightTuning` enhancement | FL-02 |
| ~~`FlightTuning.aiInertialess = .formations`~~ | Now the `formationFlying` enhancement | FL-11 |
| ~~`World.friendlyFireAllowed = false` (the player is immune to their own splash)~~ | Now the `playerBlastImmunity` enhancement; `friendlyFireAllowed` gates only co-op player-on-player splash | WP-06 |
| `Spawner.maxPopulation 18` / `spawnInterval 6` / `fleetInterval 26` / `secondsPerReinforcementDay 60` | `Engine/Spawner.swift:61, 85, 93, 126` | AI-09/10/13 |
| `PilotEconomy.maxEscorts = 9` | `Story/PilotEconomy.swift:551` | EC-19 |
| Free IFF outfit for new pilots | `Story/PilotFactory.swift:109–121` | MS-22 |
| ~~Autosave on jump, periodic heartbeat, backgrounding, combat events; in-flight position/heading saved~~ | Now the `frequentAutosave` enhancement | UI-01 |
| ~~Every NPC spawn drops DefaultItems (`includeDefaultItems: false`)~~ | Fixed: capabilities read them (OS-01) | OS-01 |
| ~~Fighter bays and ammo rebuilt full on every takeoff~~ | Now the `freeMunitionsRefill` enhancement | OS-03, UI-02 |
| ~~Hull PodCount alone grants a survivable escape pod~~ | Now the `forgivingEscapePod` enhancement | OS-02 |
| ~~Plug-ins start disabled; discovered recursively; case-sensitive order~~ | Now the `manualPluginOrder` enhancement (UI-16) | UI-16 |
| Presentation defaults `screenShake = true`, `shipBarPosition = .above`, `sidebarPauseMenu = true`, `showMissionStorylineTags = true` | `App/App/GameSettings.swift:279–282` | Decision 2 |

**Strict Play — settled (user).** The original asks for Strict Play at pilot creation and stores
it in the pilot file. NovaSwift has no such field (no `strictPlay` anywhere in `Sources/` or
`app/`). The user ruled it faithful: per-pilot state in `PlayerState` and the new-pilot flow,
checkbox default **off**; non-strict gives the player and direct escorts ×1.5 top speed; strict
death without a pod deletes the `.evpilot` with its backups and iCloud copies. FL-03 covers it.

**Saving — settled (user).** The original saves only at new pilot, on leaving the spaceport and
after an escape-pod respawn under Strict Play. That is the default; NovaSwift's other saves become
the `frequentAutosave` Enhancement (UI-01).

---

## 3. Enhancement toggles

Every NovaSwift-invented behaviour the audits found was first given a proposed toggle; on
2026-10-10 the user cut the list to the eight worth keeping. All are default **off**. Toggles
flagged † affect the simulation, which matters for future multiplayer parity.

**Infrastructure (Batch 0).** Toggles live in `GameplayEnhancements` (`Engine/GameplayEnhancements.swift`),
stored as `GameSettings.enhancements` and copied to `World.enhancements` wherever the app builds a
world. Adding one is a stored `Bool` plus one row in `GameplayEnhancements.catalog`; the catalog
drives coding (missing keys decode as off, keys no longer in the catalog are ignored, so saved
settings that still carry a removed toggle load cleanly) and the Settings ▸ Enhancements list,
which also hosts the separate Difficulty, System Aliveness and Auto-landing options.
`ceHyperspaceLook` is a presentation setting (`GameSettings.ceHyperspaceLook`, Settings ▸ Graphics
"Windows hyperspace look"), not an Enhancement: the Windows CE no-fade jump, with the Mac 1.5 s
fade as the default (FL-04).

**Map charts are not an enhancement.** The decomp confirms the existing user ruling is original:
`Outfit_GrantOutfitToPlayer` 0x00427770 applies a ModType-16 map and flags the outfit consumed, so
a chart never enters inventory and stays buyable.

| Toggle | Invented behaviour it preserves | Items |
|---|---|---|
| `manualPluginOrder` | Plug-ins off until enabled, user drag order, recursive discovery | UI-16 |
| `frequentAutosave` | Saves on every jump, on a periodic timer, on backgrounding and after combat events, with in-flight position and heading restored, so death or quit in flight loses nothing | UI-01 |
| `quickHyperjump` † | Align-only (no brake) jump, 0.45 s burst at 4× top speed, 0.14 s flash; instant-jump outfit skips the align phase | FL-04, FL-06 |
| `forgivingLanding` | Circular landing reach `radius + 70`, 130 px/s speed limit, no clearance step | FL-12 |
| `autoRoutePlotting` | Tap a system to get a BFS shortest path (also through unexplored systems), unbounded length, "Nearest System" auto-plot | UI-05 |
| `nearestFirstTargeting` † | Target cycle sorted nearest-first, wrapping, 3000 px cap; R = nearest ship | UI-07 |
| `modernKeyBindings` | Return = fire secondary (macOS Ctrl-arrow clash), Shift = afterburner, P = pause, I = ship info, invented Evasive key | UI-15 |
| `formationFlying` † | Fleet and escort members holding formation fly the port's driftless model instead of their hull's momentum (the FormationGlue cheats went with the port's AI) | FL-11, AI-40 |

**Removed 2026-10-10.** The toggle and the invented code behind it are gone; the original
behaviour is the only path.

- `portFlightTuning` — removed, original only (FL-02, FL-10).
- `retroThrustReverse` — removed, original only (FL-09).
- `npcAfterburners` — removed, original only (FL-08).
- `freeMunitionsRefill` — removed, original only (OS-03, UI-02).
- `playerBlastImmunity` — removed, original only (WP-06).
- `forgivingEscapePod` — removed, original only (OS-02).
- `starterIFF` — removed, original only (MS-22).
- `piracyPolice` — removed, original only (AI-06).
- `planetLaunchArrivals` — removed, original only (AI-12).
- `hypergateTraffic` — removed, original only (AI-12, AI-23).
- `reinforcementShortcut` — removed, original only (AI-13; the System Aliveness port traffic model keeps its own shortcut).
- `targetArmorReadout` — removed, original only (UI-10).
- `extraStatusMessages` — removed, original only (UI-11).
- `largerEscortWing` — removed, original only (EC-19).
- `immediateMissionEscortLink` — removed, original only (AI-39).
- `sweptShotContact` — removed, original only (WP-17; spriteless test worlds keep the round outline).
- `novaSwiftAI` — removed, original only: `OriginalAI` is the only NPC brain; `AIBrain` keeps only the shared fields and helpers it mirrors (AI-23 and the AI batch).

The proposed `livelySystemAI`, `modernRequestAssistance` and `modernEscortOrders` toggles were never
built and are dropped with the rest.

`forgivingLanding` also keeps the one-press landing without request/clearance lines, "Land picks
the nearest body regardless of selection", and the invented "Request Landing" hail button
(UI-06, UI-08, UI-09).

"Loitering traders" are **not** an invention. The original trader also flies to a stellar,
damps to a stop, and coasts 300–499 ticks (10–17 s) beside it before jumping out. NovaSwift's
8–16 s `.docked` dwell is close. What differs is target choice, the jump-out (in place, not at the
system edge) and the absence of any landing. That makes it a FIX inside AI-23, not a toggle.

Behaviours that are plainly wrong are FIX-only and get no toggle. Examples: the per-port
FNV stock roll, the 2 % disabled-hulk armor, the hard-coded commodity table, completed missions
never re-offered, outfit full refunds, paid repair, the off-by-one buoy message, gate travel
costing a day, interference shrinking radar range, the density scanner revealing cargo, the
invented 3× gambling payout, and shield/armor restored from the save. Any of them can be
promoted to a toggle on request.

---

## 4. Batches

| Batch | Theme | Items (first pass + second pass) | New in the second pass | Depends on |
|---|---|---|---|---|
| 0 | Data decoding, parse bugs, loadout aggregation, plug-in loading | 4 + 5 = 9 (all DONE) | LD-02, OS-01, OS-09, UI-12, UI-16 | — |
| 1 | Flight constants, hyperjump, travel days, fuel, cadence, **saving and Strict Play** | 22 + 6 = 28 | UI-01, UI-02, UI-03, OS-06, OS-11, FL-23 | 0 |
| 2 | Weapons, damage, disable, combat rating, **special systems** | 25 + 7 = 32 (all DONE; AI-03 shipped with it) | WP-26, WP-27, OS-02, OS-03, OS-04, OS-07, OS-12 | 0, 1 (cadence) |
| 3 | Legal-record model, NPC fire control, hostility, spawning | 17 + 3 = 20 | OS-10, OS-13, UI-17 | 2 |
| 4 | Economy, landing, outfits, shipyard, escorts-as-commerce, comm dialogs | 24 + 5 = 29 | EC-24, EC-25, EC-26, OS-08, UI-09 | 3 (system reputation) |
| 5 | Mission lifecycle, ranks, crön, text, exploration | 21 + 3 = 24 | MS-24, UI-04, OS-14 | 0, 3, 4 |
| 6 | Full AI state-machine port, escort AI | 24 | — | 1–5 |
| 7 | **New:** player-facing rules: map, targeting, landing flow, HUD text, Player Info, keys, radar | 11 | UI-05, UI-06, UI-07, UI-08, UI-10, UI-11, UI-13, UI-14, UI-15, UI-18, OS-05 | 1 (FL-12), 2 (WP-03, OS-12), 3 (EC-02), 4 |
| | **Total** | **177** (9 done) | **40** | |

Items merged into existing ones rather than given IDs: outfits_special O12 (gravity flags →
FL-19), O14 (fuel clamp, regen while disabled → FL-07; auto-refueller → EC-23); ui_rules B2/C1
(Strict Play → FL-03), A9 (multi-jump → FL-06), A14 (ship hail gating → AI-44), B6 (16-mission cap
→ MS-17), C6 (buoy → UI-12); OQ B6 (AI disable-only shots → WP-02), OQ B1 (PD → WP-14).

**Changes to the requested order, and why:**

- **NCB SET tokenizer (MS-02) moved from Batch 5 to Batch 0.** It is a parse bug in the same
  class as the mïsn offsets. The MS-01 fix will start running OnAbort/OnSuccess strings of 44
  auto-abort missions, and several of those contain lowercase opcodes the current tokenizer
  drops silently. Fixing the reader without the tokenizer would surface half-executed scripts.
- **The legal-record model (EC-02) moved from Batch 4 to the head of Batch 3.** The original
  keeps one reputation per *system*. The player-hostility ladder (AI-05), landing access (EC-04),
  the commodity 1.1 scale (EC-03), AvailRecord (MS-17), CompGovt (MS-10) and PayVal (MS-09) all
  read it. Hostility cannot be made faithful on the per-government record.
- **Cadence infrastructure (FL-01) leads Batch 1.** The afterburner, disabled-drift damping, beam
  lifetimes, rocket blending and jamming retargets all run per raw call in the original.
- **Ship WP-04 (combat rating) and AI-03 (rating fire ramp) in the same release.** Fixing either
  alone shifts early-game difficulty in one direction only.
- **Player disable (WP-03) needs Batch 0.** Its mission side (Flags 0x0004 quick-fail) only means
  the right thing once MS-01 lands. Today the misread flag makes 243 can't-refuse missions fail on
  disable.
- **Batch 6 last** because it consumes nearly everything: jump duration (FL-04), weapon selection
  (AI-02), disable (WP-02/03), hostility (AI-05), reinforcement triggers (AI-13) and bribe/payment (AI-42).
- **Saving and Strict Play (UI-01..03, FL-03) sit in Batch 1.** They are settled user decisions,
  self-contained, and change the risk loop every later batch is play-tested under. Doing them
  first also stops mid-flight autosaves from masking regressions in later batches.
- **OS-01 (NPC DefaultItems capabilities) and OS-09 (per-def stacking) go to Batch 0.** They are
  loadout-aggregation fixes that WP-09, OS-04, OS-07, FL-06 and AI-27 all read.
- **UI-12 and UI-16 go to Batch 0**: a 1-based index bug and the resource load order are decode
  issues, and plug-in precedence decides what every later batch reads.
- **Batch 7 is presentation-heavy and mostly independent** of the AI port, so it can run in
  parallel with Batch 6 once Batches 1–4 have landed. UI-14 (legal labels) needs EC-02.
- **OS-02 (escape pods) needs WP-03**, because eject works while disabled.

---

## 5. Items

### Batch 0 — data decoding and parsing

#### MS-01 · mïsn Flags / Flags2 / RefuseText / AvailShipType offsets — **DONE**
- **Original.** `NovaResources_LoadMisnResourceDefs` 0x0043bbb0 reads Flags at +0x50 (80), Flags2
  at +0x52 (82), RefuseText at +0x58 (88) and AvailShipType at +0x5a (90). Stock data agrees: +78
  is 0 in all 791 mïsn and +86 is always 0.
- **NovaSwift.** Fixed. `Kit/MissionModels.swift:~275–283` reads 80/82/88/90. No consumer needed
  re-pointing: they already used the Bible bit meanings and were only fed the wrong words.
  `docs/MISSIONS.md` now documents the correct layout.
- **Verified by** `Tests/NovaSwiftKitTests/MissionFlagsRealDataTests.swift` on stock data: 44
  auto-abort missions and 86 ship-restricted missions decode as expected.
- **Split out.** The AvailShipType *value* semantics (government bands and exact band edges) were
  not part of the offset bug; they are MS-24 (Batch 5).
- **Class.** FIX. **Impact** high. **Confidence** very high (stock data).

#### MS-02 · NCB SET interpreter — moved from Batch 5 — **DONE**
- **Original.** `Mission_ExecuteMisnScriptEngine` 0x00449370 folds every byte to upper case.
  Opcode letters arm a pending command and digits accumulate an operand. Any other byte is a
  delimiter that executes the pending command. An opcode letter arriving while a command is
  pending re-arms without executing, so `S862S863` runs only `S863`. `!NNN` (clear without `b`)
  and `^NNN` (toggle) are valid. Each command has its own accepted operand range; control-bit
  operands ≥ 10000 are ignored.
- **NovaSwift.** Fixed. `NCBSet.resolve` (`Story/NCBExpression.swift:~298`) ports the byte
  machine, including the `R(…)` spacing quirks and the per-command operand ranges, and
  `StoryEngine.apply` executes through it.
- **Verified by** running the original routine under the oracle
  (`~/Projects/evnova-re/oracle/examples/ncb_set.py`) and comparing the resolved command lists.
- **Class.** FIX. **Impact** high: 19 stock mïsn with lowercase ops, crön 288–292 knock-off
  conversions, and mïsn 867–871. **Confidence** very high (oracle-verified).

#### EC-01 · Commodity base prices come from STR# 4004 — **DONE**
- **Original.** The trade center 0x0048c730 reads base prices from STR# 0xfa4 (4004). Stock values
  are `75, 350, 750, 900, 200, 550` (Food, Industrial, Medical, Luxury, Metal, Equipment).
- **NovaSwift.** `Kit/NovaEconomy.swift:67–76` hard-codes `(12,15,18)…(400,450,500)` as a
  fallback for an `STR ` 9300–9305 override that does not exist in stock data, so the fallback
  always runs.
- **Class.** FIX (decode only; the Low/High formula is EC-03). **Impact** high: every trade price
  is wrong (Medical 90 instead of 750). **Confidence** high (stock data).
- **Test.** Load stock data and assert Medium prices equal STR# 4004 entries 1–6.
- **Done.** `NovaGame.commodityBasePrice` reads `STR ` 9300+i, else STR# 4004 entry i+1
  (0x004b0c20); the hard-coded table is gone. Low/High now use the default 1.25 scale with the
  floor of 5 (`Commodity.prices(base:scale:)`); the 1.1 / 1.5 scales stay with EC-03. Pinned by
  `LoaderFidelityTests` (stock data: 75/350/750/900/200/550).

#### LD-01 · Loader-side decodes and normalisations — **DONE**
The original loader `0x004bd3c0` normalises many fields at load time. Do these once, in the
models, so later batches can rely on them.
- gövt **SkillMult** at payload +0x30 (byte 48), × 0.01, with values < 1 → 1.0. NovaSwift labels
  this field "Ship Speed Factor@48" but never applies it, and AI_GROUND_TRUTH §6.6 lists it as
  "no verified byte offset". It is consumed in FL-15.
- shïp **SkillVar** clamped to 1..50.
- gövt **MaxOdds** = int16 × 0.01, clamped to ≥ 0.01. Today `MaxOdds ≤ 0` means "no limit" at
  `Engine/AIBrain.swift:512`.
- sÿst **Person1–8 %Prob** at +0x7e (byte 126), clamped 0..100. Only the ids at 110–124 are
  decoded today (`Kit/NovaModels.swift:~708`).
- përs **Aggress** clamped to {1, 2, ≥3 → 4}.
- wëap **Deionize** ≤ 0 → 1.0 per tick; otherwise Deionize × 0.01 per tick
  (`Engine/Galaxy.swift:305` and `Engine/World.swift` `flooredDeionize` substitute a floor today).
- oütf / shïp **BuyRandom** and **HireRandom** clamped 0..100, where **0 means never** (the Bible
  says the opposite).
- Decode the unread shïp bits: Flags 0x0020/0x0040 (AI afterburner), Flags2 0x0001 (swarm),
  0x0002 (standoff), 0x0100–0x2000 (cloak triggers), 0x0080 (ammo-out flee), Flags3 0x1/0x2
  (miner), the EscortType field, and the class-capability blind-spot bits 0x1000/0x2000/0x4000.
- **Class.** FIX. **Impact** medium (enabler). **Confidence** high (decomp `scenario_data.cpp`
  loader; SkillMult re-checked via 0x004640a0 / 0x004642e0, which multiply by the government
  table's float at +100).
- **Test.** Decoder unit tests for each field against stock records.
- **Done.** Normalised accessors next to the raw fields: `GovtRes.skillMult` / `maxOddsRatio`,
  `SystRes.persons` (id + clamped %Prob), `PersRes.aggressionLevel`, `ShipRes.deionizePerTick`,
  `ShipRes.escortClass` (the loader's inference for Automatic), and the shïp bit accessors
  (afterburner, blind spots, swarm, standoff, untargetable, cloak triggers, re-cloak, miner).
  SkillVar and BuyRandom/HireRandom are clamped at decode. Two consumers changed with the decode:
  BuyRandom < 1 now means never for outfits too (51 stock oütf, mostly mission variants such as
  "Thorium Reactor - bomb", stop appearing in outfitters), and hull deionization uses the loader
  rate with the invented 12 s fade floor removed (WP-11 still owns graded ionization). Other
  consumers (MaxOdds ≤ 0 as "no limit", Person %Prob, Aggress) stay with AI-08, AI-11, AI-21 and
  FL-15. The plan's "wëap Deionize" is the shïp field (@874). Tests: `LoaderFidelityTests`,
  `CombatTests.testDeionizeUsesTheLoaderRate`.

#### LD-02 · Record zero-padding to fixed minimum sizes — from the coverage map — **DONE**
- **Original.** `Resource_GetByTypeAndId` 0x004ce250 with `Resource_ByteSwapAndPadRecordByType`
  0x004ce700 and the descriptor interpreter 0x004ce660 (all unexplored by the decomp) zero-pad
  every record to a fixed minimum size before any field is read. Sizes in bytes: mïsn 1970, shïp
  1860, spöb 1118, oütf 1028, crön 822, jünk 676, nëbu 518, sÿst 428, përs 400, flët 306, öops
  282, cölr 244, gövt 192, shän 192, ïntf 166, ränk 152, wëap 134, düde 88, röid 40, spïn 12,
  bööm 6, chär 362 (plus ëbug 64, csüm 4). A short or old plug-in record therefore reads its
  missing tail as zeros. The loader 0x004bd3c0 also ignores ids outside each type's slot range
  (UI-16).
- **NovaSwift.** Decoders read with per-field bounds checks and model-specific defaults, so a
  short record's missing fields may decode to a non-zero default.
- **Class.** FIX. **Impact** low for stock data, medium for old plug-ins. **Confidence** high.
- **Test.** Truncate each stock record type to half length; every missing field decodes as 0.
  The per-type field-width maps in `~/Projects/evnova-re/audit/raw/resource_field_layouts.tsv`
  (i16/i32/skip per offset, each ending exactly at the minimum size) double as a field-width
  check for every NovaSwift decoder.
- **Done.** `GameLibrary.merge` ends with `ResourceCollection.normalizeScenarioRecords()`, which
  zero-pads every record to `NovaType.minimumRecordSize` (and drops out-of-slot ids, UI-16), so
  every consumer, raw-byte readers included, sees the original's padded view. Stock records already
  meet every minimum. The field-width cross-check against `resource_field_layouts.tsv` was not
  automated.

#### OS-01 · NPC capability probes read DefaultItems; stats do not — **DONE**
- **Original.** NPC max shield, armor, fuel capacity, speed, thrust, turn and regen use the class
  base only: the outfit loop in 0x00463550 / 0x00463680 / 0x004638e0 / 0x00463a20 / 0x004640a0 /
  0x004642e0 runs only for the player. Every *capability* probe, however, has an NPC arm that
  walks the class's 8 DefaultItems (`class+0x14` ids, `class+0x24` counts):
  - cloak and every cloak flag (0x00464b50, 0x00464c80, 0x00464db0, 0x00465090, 0x00464e30,
    0x00464f60, 0x004651a0, 0x00467e80);
  - cloak-scanner reveal (0x004652a0), target-cloaked and target-untargetable scanners
    (0x0046ca60, 0x0046c930);
  - fuel scoop (0x00463b30), mining scoop (0x0046cb90), fast jump (0x0046d080), multi-jump
    (0x0046cdd0), repair system (0x0046e540), jamming (0x00464810).
- **NovaSwift.** Every AI spawn passes `includeDefaultItems: false` (`Engine/Spawner.swift:618,
  692, 785, 811`; `Engine/Domination.swift:188`; `Engine/World.swift:1476, 3356`), so cloak,
  jammer, scanner, repair, scoop, fast-jump and multi-jump capabilities are zero for every NPC
  (`Engine/ShipLoadout.swift:~326–329`). Cloaking hulls whose device is a default item never
  cloak; `Engine/World.swift:1701` (NPC repair) is unreachable on stock data.
- **Conflict to resolve.** The Bible's "AI ignores DefaultItems" is true only for stats, and the
  spawn path implements the Bible literally. The fix must not disturb the player inventory
  invariant (player loadouts keep passing both include flags false, because `PlayerState.outfits`
  already owns the DefaultItems). Split the aggregation instead: NPC *stats* stay class-only, and
  NPC *capabilities* come from a separate DefaultItems scan, each def counted once (OS-09).
- **Class.** FIX. **Impact** high (enables WP-09, AI-27, OS-04, OS-07, FL-06, FL-07 for NPCs).
  **Confidence** high.
- **Test.** A stock hull with a cloak in DefaultItems spawned as an NPC reports a cloak device;
  its max shield equals the class base.
- **Done.** `Galaxy.loadout(…, defaultItemCapabilities:)`: with DefaultItems excluded it still
  reads them for cloak, cloak scanner, fuel regen (counted per unit, as the original does), mining
  scoop, fast jump, multi-jump, repair and jamming. Every AI spawn passes `true`; the player path
  is unchanged (both include flags false). Pinned by `DefaultItemCapabilityTests`.

#### OS-09 · Outfit stacking quirks: once per owned def — **DONE**
- **Original.** Player jamming (0x00464810) adds each owned def's ModVal **once**, whatever the
  count. Multi-jump depth (0x0046cdd0) is `max(1, 1 + Σ ModVal)` over owned ModType-32 defs, not
  × count (OQ A3). ModType 45/46 (max guns/turrets, 0x004656a0) also add once per def (latent in
  stock data).
- **NovaSwift.** `Engine/ShipLoadout.swift:~395–398, 417–420` multiply by count.
- **Class.** FIX. **Impact** medium-low. **Confidence** high (multi-jump aggregation: medium,
  untested against data).
- **Test.** Two units of a 20-point jammer give a jam score of 20.
- **Done.** Jamming (ModTypes 33–36), multi-jump and ModType 45/46 add ModVal once per def in
  `Galaxy.loadout`. Pinned by `DefaultItemCapabilityTests`.

#### UI-12 · Buoy message is read off by one — **DONE**
- **Original.** `System_ShowSystemEventMessage` 0x00467cf0 first tries `STR ` id+999, then
  STR# 1000 entry `id`, which is **1-based**; shown for 0x1e0 raw calls (≈ 10 s). Message ≤ 0 shows
  nothing.
- **NovaSwift.** `App/Game/GameContainerView.swift:157–160` indexes `strings[message]` 0-based, so
  every buoy shows the next entry (Message 1 shows #2 "UHP-1001 not to be landed on"), Message 0
  shows a string, and the `STR ` overrides are ignored.
- **Class.** FIX. **Impact** medium. **Confidence** high (verify on one stock system).
- **Test.** The Auroran system with Message 1 shows STR# 1000 #1.
- **Done.** `NovaGame.systemMessageText` (`STR ` message+999, else 1-based STR# 1000, nothing
  for ≤ 0); `GameContainerView` uses it. The ≈ 10 s display time and the generated
  "entering system" line for Message −1 belong to UI-11. Stock Nil'kol has Message 20003, which
  resolves to nothing, as in the original.

#### UI-16 · Plug-in loading order and base-file precedence — **DONE**
- **Original.** `nv_LoadFilesInFolder` 0x0046f500 loads every top-level `*.rez` in `Nova
  Plug-Ins` (fallback `Plug-Ins`, 0x0087265d), skipping subfolders, in FindFirstFileA order
  (case-insensitive alphabetical on NTFS). Archives are prepended (0x004ff900) and lookups walk
  head-first (0x004cdfa0), so the last file wins, by whole-resource replacement. `nv_WinMain`
  0x004d2a80 opens `Nova.rez` before the Nova Files scan, so it is the *weakest* base archive.
  The scenario loader 0x004bd3c0 keeps only ids inside fixed slot ranges (spöb/sÿst 0x800, oütf
  0x200, wëap 0x100, shïp 0x300, düde 0x200, gövt 0x100, përs 0x400, flët 0x100, crön 0x200,
  jünk 0x80, id = slot + 128). The registration gate on plug-ins is treated as always open (CE is
  freeware).
- **NovaSwift.** Plug-ins start disabled (`Kit/GameLibrary.swift:108–114`), are discovered
  recursively (:103), new ones are ordered by case-sensitive id (`App/Data/GameDataController.swift:306–312`),
  base files are path-sorted so `Nova.rez` is the strongest (`Kit/GameLibrary.swift:152`; only
  `ppat 128` overlaps, latent), and any id is accepted. Override semantics already match
  (`Resource.swift:42`).
- **Class.** FIX+ENH → `manualPluginOrder`. **Impact** medium. **Confidence** high.
- **Test.** Two plug-ins `a.rez` and `B.rez` overriding the same resource: `B.rez` wins; a `.rez`
  in a subfolder is ignored; a shïp id 1000 in a plug-in is ignored.
- **Done.** Base files load `Nova.rez` first (`GameLibrary.baseLoadOrder`); ids outside the slot
  ranges are dropped (`normalizeScenarioRecords`); with the `manualPluginOrder` enhancement off,
  every installed plug-in is enabled and loaded in case-insensitive alphabetical order
  (`GameLibrary.originalPluginOrder`), and the launcher hides its switches and arrows. The user's
  saved enable set and order are kept for when the enhancement is on.
  **Deviation kept on purpose:** a plug-in folder (how the store and importer install a plug-in)
  still counts as one plug-in and is read recursively; only *top-level* bundles are plug-ins. The
  original would ignore a subfolder entirely, which would make every store install invisible.

### Batch 1 — flight, hyperjump, travel days, fuel, saving

#### FL-01 · Raw-call cadence — do first — **DONE**
- **Done.** `Engine/OriginalClock.swift`: `RawCallCadence` is a 21 ms accumulator over game time,
  so a per-call rule runs 1 or 2 times a 30 Hz step (47–48 a second); `World.rawCallsThisStep`
  exposes it to batch 2. Hitches still drop time past the 5-tick cap (Q-FL-13 open).
- **Original.** `Frame_MeasureFrameTiming` 0x00432ea0 runs the loop at about 47.6 Hz (21 ms
  floor) and publishes a normalized tick scale of 0.03 per ms. Most consumers scale by ticks, but
  some run once per raw call: the afterburner push and cap decay, the disabled 0.995 damp, the
  0.985 inertialess damp, rocket blending, bomb weathervane, jamming retarget odds, beam-record
  ticks and particle life.
- **NovaSwift.** Fixed 30 Hz step (`App/Game/GameScene.swift:~411`) with a 5-tick catch-up cap.
- **Settled (OQ A5/B5).** The loop busy-waits to ≥ 21 ms, so the raw rate is ≤ 47.62 Hz. The
  scale sample is `elapsed_ms × 0.03`, accepted only in [0.01, 10), averaged
  `avg = (avg × 3 + sample) × 0.25`, and settles at 0.63. Raw-cadence consumers (confirmed):
  beam life and beam damage, rocket blend, bomb weathervane, jamming and lost-lock retargets,
  SWParticles life, collision tests. Normalized: projectile life and position, guided turn,
  bööm sprites, smoke. A separate 60.01 Hz `TickCount` thread (0x004d5e10) drives UI timers.
  `Platform_OnAppActivated/Deactivated` 0x00497cf0 / 0x00497d50 (unexplored) reset the frame dt
  to 1.0 and pause the game on app switch.
- **Class.** FIX. Introduce a "raw calls per tick = 1/0.63" conversion so per-call rules can be
  applied exactly at 30 Hz. Whether to reproduce the hitch behaviour (the EMA stretches the tick
  rather than dropping time) is open question Q-FL-13.
- **Impact** low by itself; it is a prerequisite for FL-08, FL-17, WP-01, WP-09 and WP-19.
  **Confidence** high.
- **Test.** A per-call rule ticked for 1 s of game time matches its 47.6-call closed form.

#### FL-02 · Base flight constants — **DONE**
- **Done.** `FlightTuning.original` (0.30 / 0.18 / 3.0) is the default; the old scales are the
  `portFlightTuning` enhancement. Oracle-pinned thrust sequence in `OriginalFlightTests`.
- **Original.** Loader 0x004bd3c0, `Ship_ComputeShipEffectiveThrust` 0x004640a0 and
  `Ship_ComputeShipEffectiveMaxSpeed` 0x004642e0 give max speed = Speed/100 px/tick, thrust =
  Accel/10000 × 2.0 px/tick², and turn = Maneuver × 0.1 deg/tick. At 30 Hz: top speed = 0.30 ×
  Speed px/s, thrust = 0.18 × Accel px/s², turn = 3 × Maneuver deg/s. Player outfits add ModType 8
  (speed, ModVal/100) and ModType 7 (accel, ModVal/10000) before the multipliers. NPCs get
  SkillVar × SkillMult (FL-15). Ionization multiplies thrust by `1 − min(I, 0.7)` (WP-11).
- **NovaSwift.** `Engine/World.swift:118` `FlightTuning.default = (0.55, 0.55, 3.0)`, documented
  as "calibrated to side-by-side play". Top speed is 1.83× strict (1.22× non-strict) and thrust is
  3.06× the original. Turn matches.
- **Class.** FIX+ENH → `portFlightTuning`. **Impact** high. **Confidence** high (exe-verified).
- **Test.** Shuttle (Speed 300 / Accel 300): top speed 90 px/s strict, 135 px/s non-strict;
  0→top in 90/54 = 1.67 s.

#### FL-03 · Strict Play pilot option — merges ui_rules B2 / C1 — **DONE** (Player Info row: UI-13)
- **Done (1a, speed).** `PlayerState.strictPlay` (nil = off), a new-pilot checkbox, and
  `World.strictPlay`: non-strict ×1.5 for the player and ships led by the player, including the
  arrival speed (`World.effectiveMaxSpeed(of:)`).
- **Done (1b).** A strict death without a pod (`PlayerState.strictPlayDeathDeletesPilot`, false in
  shïp 895) calls `AppModel.deleteStrictPlayPilot`: `PilotRoster.deleteAfterStrictPlayDeath`
  deletes the slot's `.evpilot` and backup folder from the live store and from the other store
  (local ⇄ iCloud migration copies rather than moves) via `PilotArchive.deleteEverywhere`, and
  clears the live `pilot.json` mirror. Only the played save slot goes; other slots of the same
  pilot group are separate saves (a NovaSwift feature the original lacks — flagged for the user).
  The strict-only pod save is UI-01. The Player Info ×2/3 row stays with UI-13.
- **Original.** Per-pilot flag `0x00596d2f`, set by the new-pilot dialog checkbox (`FUN_00489d70`,
  DITL control 4, default **off**), saved at pilot block 2 +0x02 and read back as `== 1`
  (0x004cb260). Its consumers:
  - not strict: the player and ships whose squad leader is the player get ×1.5 top speed
    (0x004642e0), which also sets the hyperspace arrival speed (FL-13);
  - strict: death without a pod deletes the pilot file (0x00489210 → `PilotFile_Delete`
    0x004cd040), skipped when the ship is class index 0x2ff (shïp 895, the pod);
  - strict: the escape-pod respawn saves the pilot (0x0044aa70; OS-02), so a pod respawn cannot be
    undone by reloading;
  - the Player Info Max Speed row shows speed × 2/3 when not strict (UI-13), cancelling the bonus.
  - **There is no hyperjump-arrival save** (§1 correction; UI-01).
- **NovaSwift.** Absent.
- **Settled (user).** Faithful. The new-pilot checkbox defaults off. A strict death without a pod
  deletes the `.evpilot` **including its backups and iCloud copies**. Non-strict gives the ×1.5.
- **Class.** FIX (new state). **Impact** high (with FL-02, it sets the player's speed).
  **Confidence** high (exe-verified; oracle: 250 → 375 with the byte clear, 250 with it set).
- **Test.** Oracle-derived: toggling strict play changes `effectiveMaxSpeed(player)` by exactly
  1.5. A strict death removes the pilot, its backups and its iCloud copy; a strict death in the
  pod hull does not.

#### UI-01 · Save cadence — merges ui_rules B1 — **DONE**
- **Done.** `Story/PilotSavePolicy.swift` `PilotSaveReason.shouldSave`: only `.newPilot`, `.launch`
  and (Strict Play) `.podRespawn` write the durable `.evpilot`; land, jump, gate, periodic,
  background, in-flight menu and story/combat-event saves happen only under the new
  `frequentAutosave` Enhancement. The departure save is taken still docked (`landedSpob` set) after
  the visit's day ticks; without the Enhancement no position/heading is written, so a reload lifts
  off the launch stellar on a random heading. The in-flight "Save Pilot" row explains the rule
  instead of saving. `pilot.json` (`PilotStore.save`) is a live mirror, never a resume point.
- **Open point for the user (iOS/tvOS suspension).** Backgrounding saves only under
  `frequentAutosave`, as decided. iOS can kill a suspended app without a quit, so without the
  Enhancement shopping done on a spaceport visit that never departs is lost — even though the
  original's quit-while-landed *does* save (its launch tail runs). A landed-only background save
  would match that; not implemented pending a decision.
- **Original.** `PilotFile_SaveGame` 0x004c7db0 has five call sites: new game (0x0048a747 /
  0x0048a7d2), the spaceport launch tail (0x00456103, which also runs on quit while landed), and
  the Strict-Play-only escape-pod respawn (0x0044da30 / 0x0044da53). There is no jump save and no
  periodic save. Dying, or quitting in flight, rolls the pilot back to the last launch. The
  restore point is the docked stellar; position and heading are not saved (the loader places the
  ship at the stellar with a random heading).
- **NovaSwift.** Saves on every jump (`App/Game/GameContainerView.swift:1266, 1487, 2083`, whose
  comment "EV Nova saves on every hyperjump" is wrong), on a periodic heartbeat (:1128), on
  backgrounding (:1100), after përs grudge/defeat (:320, :323), on escort loss (:1646), on
  contraband failure (:269) and after co-op NCB changes (`AppModel.swift:165`), and restores the
  in-flight position and heading (`Story/PlayerState.swift:209–211`). A death without a pod
  reloads the last in-flight autosave.
- **Settled (user).** Original cadence by default; NovaSwift's saves become `frequentAutosave`.
  If crash safety is wanted with the toggle off, keep it as a separate resume file that a death
  invalidates and that never moves the restore point off the docked stellar.
- **Class.** FIX+ENH → `frequentAutosave`. **Impact** high (the core risk loop). **Confidence**
  high.
- **Test.** Launch, kill a ship, jump twice, quit: reopening the pilot finds it docked at the
  launch stellar with the pre-launch state.

#### UI-02 · Ammo and carried fighters persist — ui_rules B4 — **DONE**
- **Done.** Q-UI-01 answered from `Weapon_ReconcileOutfitPoolWithWeaponBanks` 0x00462ec0: an
  ammunition outfit's owned count *is* its bank's loaded rounds (owned outfits, in id order,
  explain rounds up to what the bank holds and are clamped past that; unexplained rounds — plunder —
  go to the first matching outfit). `Story/Munitions.swift` does that reconcile on landing and
  before every save (`Munitions.record`), and a takeoff loads each bay with the owned fighter
  ammunition up to capacity (`loadCarriedFighters`); a bay no outfit loads still flies full. At a
  jump's fire, deployed fighters with fuel for a jump dock back and the rest are abandoned (FL-23).
  The old free restock is `freeMunitionsRefill`. Shared pools (pod + turret) take the emptier
  mount. The rest of OS-03 (×1.333, launch rules, docking geometry) is Batch 2.
- **Original.** Pilot block 1 +0x241a holds mounted counts and +0x261a loaded ammo per bank;
  +0xe74e holds carried-fighter classes. Fired ammo and lost fighters stay spent across landing
  and reload until bought again; plundered ammo adds to the saved count.
- **NovaSwift.** Ammo lives only on in-flight `WeaponMount`s and is rebuilt from the outfit counts
  on every takeoff (`Engine/ShipLoadout.swift:356–490`; `App/Game/GameContainerView.swift:1505–1510,
  2449`), so missiles and fighters restock for free.
- **Class.** FIX+ENH → `freeMunitionsRefill`. Needs the ammo/owned-count reconciliation question
  (Q-UI-01) answered first. **Impact** high. **Confidence** high.
- **Test.** Fire 5 of 10 missiles, land, launch: 5 remain.

#### UI-03 · Other pilot-file state — ui_rules B8–B10, B14 — **DONE** (AI-owned counters: AI-13, AI-35)
- **Counters, cleanup 1.** Re-checked against their owning models: DatePrefix/DateSuffix are saved
  (`PlayerState.datePrefix/dateSuffix`, UI-11); the intro latch is implicit (the intro only runs
  for a new pilot); the per-stellar domination-day counter (stellar +0x2a, saved at block 2
  +0x2086) is incremented by `Player_CollectStellarTribute` 0x00423540 — only while the current
  stellar lacks flag 0x20 — and reset by a release, but **nothing reads it**, so it has no
  gameplay to port. The reinforcement cooldown and the escort group orders/voice modes persist
  state of models that are AI-13 and AI-35's, and move there.
- **Done.** `PlayerState.normalizeForLoad` on Open/Enter Ship (`AppModel.play`): shield and armor
  load at full (only fuel is restored), and outfits, junk cargo and a hull whose definitions are
  gone are pruned / replaced by the first defined hull (logged; the STR# 0x8c #0x34 warning dialog
  is not shown). The save format is unchanged, so old saves load as before.
- **Deferred to their owning items.** The persistent counters persist state of models that are
  still the port's own: the reinforcement cooldown (AI-13's model is invented today), escort group
  orders and voice modes (AI-35 / escort AI), domination-day counters (EC tribute), DatePrefix/
  DateSuffix and the intro latch (UI-13 text). Each should be added to `PlayerState` when its item
  ports the original model.
- **Original.**
  - Shield (+0x10) is written but never read; shield and armor are recomputed at load, so a ship
    always loads at full. Only fuel (+0x12) is restored.
  - Persistent counters: per-stellar domination days (block 2 +0x2086), per-system reinforcement
    cooldown (+0x3d90), escort group-order codes (+0x5d90), escort voice modes (block 1 +0xe8ce),
    released/upgrade flags, carried-fighter classes, DatePrefix/DateSuffix (+0x5ede/+0x5eee), the
    intro-seen latch (+0x3086).
  - `PilotFile_LoadSave` 0x004cb260 repairs missing plug-in data: zeroes outfits, banks and junk
    whose defs are gone, replaces a TechLevel −9999 ship class with the first defined class,
    repairs a −1 jump destination, and returns −0x2e (autoresume refuses; Open Pilot warns with
    STR# 0x8c #0x34 and continues).
- **NovaSwift.** Restores shield and armor (`Story/PlayerState.swift:234–235`); the counters are
  session-only or absent; load records only `dataFingerprint` (`App/Pilots/PilotRoster.swift:131`).
- **Class.** FIX. **Impact** low-medium. **Confidence** high (shield: medium).
- **Test.** Save a damaged ship (with `frequentAutosave` on) and reload: it loads at full shields
  and armor. Reinforcement cooldown survives a reload.

#### FL-04 · Player hyperjump sequence — **DONE**
- **Done.** `Engine/Hyperjump.swift` `PlayerHyperjump`, run by `World.step` in place of the
  player's flight while `World.playerJump` is set (weapons cold): brake (×0.99203847/tick, 1.0 ×
  thrust inside `max(turn+1, 20)°`, ends at both `|trunc(v)| < 2` px/tick; inertialess bleeds its
  scalar), spin-up (×0.98006866 unless fast jump; fires at timer ≥ 30 ticks from seed 2 *and*
  cue end = `cue60 / multiplier`, cue = snd 128 in 60 Hz ticks, 350 fallback, multiplier from
  shïp Flags 0x1/0x2/0x4), tunnel (`min(progress, 50)` px/tick position step within
  `max(turn, 30)°`), disabled collapse (STR# 2002 #35). `GameScene` draws it and swaps the world
  in place at the fire as before. Presentation: the Mac fade starts when progress passes 55 and
  fades out over 1.5 s after arrival, with control returned at once; `ceHyperspaceLook` keeps
  only the boom flash. The old sequence is `quickHyperjump`.
- **Not reproduced.** The Warp up cue is played as the existing loop at normal pitch (the original
  plays it at the multiplier's speed); the timing uses the computed length, so only the sound
  differs. Streak intensity follows `min(progress, 50)` (the original's streak pass is unresolved).
  Escorts don't run the original's spin-up sync (state 0x0B; Batch 6). x2 mode is not modelled.
- **Original** (decomp `travel.cpp`, `docs/player_hyperspace.md`):
  1. **Brake** (0x0044F127 / 0x0044F275): turn to face opposite the velocity, damp 0.99203847 per
     tick (`0x005755f0`), and within `max(turn+1, 20)°` apply 1.0 × thrust backward. Ends when
     both `|trunc(v)| < 2` px/tick.
  2. **Spin-up** (0x0044C528 / 0x0044C704): damp 0.98006866 per tick and turn to the map bearing.
     The jump timer must reach ≥ 30 ticks *and* the "Warp up" snd 128 cue must have finished. The
     cue is 6.078 s divided by `max(scale × 1.3, 0.5)`, where scale is 0.7 / 1.3 / 1.6 / 1.0 for
     shïp Flags 0x1 / 0x2 / 0x4 / none. That gives 6.68 / 3.60 / 2.92 / 4.68 s.
  3. **Tunnel** (0x0044CCAF): progress = `elapsed60 × mult / (dur60 × 0.01) − 35/mult`. Once it is
     > 0 and the ship is aligned within `max(turn, 30)°`, the position (not the velocity) steps
     `min(progress, 50)` px per tick along the heading.
  4. **Fire** at cue end (0x0044F3D0 / 0x0044F660).
  5. **Disabled collapse** (0x0044B037 / 0x0044B120): a disabled player's engaged jump collapses.
- **NovaSwift.** `App/Game/GameScene.swift:3402` `stepJump`: `.align` with "No braking"; a burst
  at 4 × top speed for 0.45 s / jumpSpeed (0.18 s instant, :3433); a 0.14 s flash.
- **Class.** FIX+ENH → `quickHyperjump`.
- **Presentation — settled (user).** The Windows build has no white fade (0x00467e60 is a no-op);
  the Mac build fades white for about 1.5 s. The user made an explicit presentation exception:
  the default is the Mac ~1.5 s white fade, and the CE no-fade look is the `ceHyperspaceLook`
  option. All jump mechanics and timings (brake, cue-timed spin-up, tunnel, arrival) stay
  Windows-exact either way; the fade is drawn over them and never delays them.
- **Impact** high. **Confidence** high.
- **Test.** A ship moving at full speed with no flag 0x1/0x2/0x4 takes brake time + 4.68 s from
  engage to fire. A Flags 0x4 hull takes brake + 2.92 s.

#### FL-05 · Travel days and calendar ticks — **DONE** (pod and DatePostInc days: OS-02, MS)
- **Done.** `Galaxy.hyperspaceTravelDays` (oracle-pinned table in `OriginalHyperjumpTests`), the
  jump running `max(player, attached non-disabled ships)` daily ticks once per jump; landing ticks
  nothing; departure runs `SpaceportVisitDays.departureDays` (launch 1, +1 outfitter buy/sell, +4
  ship purchase, + trunc(escorts sold or upgraded / 2)); gates 0 (OS-06). **Q-FL-12 settled by the
  oracle:** the per-term unsigned-16-bit cast wraps, but every caller stores the result in a signed
  short, so a negative ModVal simply subtracts (`max(1, base + Σ count × ModVal)` within 16 bits).
  The day flags are set only by completed transactions (Q-EC-12 still open). The 15–44-day pod
  respawn is OS-02 and mission DatePostInc is the missions batch. The tribble/perishable tick still
  runs per day, not per 250 frames (EC-24).
- **Original.** `Stellar_ComputeHyperspaceTravelDays` 0x00465550: 1 day if hull mass ≤ 99, 2 if
  100–199, 3 if ≥ 200, plus (player only) Σ count × ModVal of ModType 22 outfits, with the
  unsigned-16-bit wrap noted in §1, minimum 1. Arrival runs the daily update that many times,
  taking the max over attached escorts. Other ticks:
  - landing does **not** tick;
  - launch ticks once (0x00455e10);
  - an outfit transaction during the visit adds 1 tick, and a ship purchase adds 4 (§1);
  - escort sell/upgrade adds `trunc((sold + upgraded)/2)` (0x004229d0): 1 escort = 0 days;
  - an escape-pod respawn adds `rand(30) + 15` (0x0044d371, `push 0x1e` at 0x0044d856);
  - a mission success or auto-abort adds its DatePostInc (0x00440410 / 0x00447d90);
  - gate and wormhole transit add **0** (OS-06); trade, bar, BBS and refuel add 0.

  Settled by OQ C2 / A3: one game day is one call of 0x00466cb0, which Ghidra misnames
  `ShipClass_RerollShipClassAvailabilityChances` but which is the whole daily tick (date, crön,
  deadlines, tribute, disasters, garrison, stock rerolls). Its seven callers are the complete list
  of day costs above. The jump count is the max over the player and attached, **non-disabled**
  escorts, computed once even for a multi-jump. The outfit and ship flags are cleared on entering
  the spaceport and both apply in one visit (5 days), and either one also clears the nav target.
  Whether a cancelled outfit buy still sets the outfit flag needs the oracle (Q-EC-12).

  Escort payroll is charged per travel day (EC-20).
- **NovaSwift.** `App/Game/GameContainerView.swift:2081` (one day per jump), `:1485` (gate),
  `:1143` (landing ticks the day). `Story/PilotEconomy.swift:~154–161` and `docs/SHIP_SYSTEM.md:86`
  treat ModType 22 as an animation speed-up.
- **Class.** FIX. **Impact** high (deadlines, crön timing, payroll). **Confidence** high
  (exe-verified).
- **Test.** A 150 t hull adds 2 days per jump; a landing adds 0 and a launch 1; buying a ship
  then launching adds 5.

#### FL-06 · Jump-outfit semantics (ModType 37 fast jump, ModType 32 multi-jump) — **DONE**
- **Done.** Fast jump is class Flags2 0x0020 or ModType 37 and only skips the brake and the
  spin-up damp. `Loadout.multiJumpDepth = max(1, 1 + Σ ModVal)` per def; `maxJumpHops = max(1,
  Σ ModVal)` route systems, one fuel debit and one travel-day computation per jump; only the
  final system is explored. Not reproduced: intermediate systems' region (nebula) events and the
  latent −1-system bug.
- **Original.** Fast jump (`Ship_CheckSpecialLoadoutCapability` 0x0046D080: class Flags2 0x0020
  or ModType 37) only skips the brake stop-gate and the 0.98 spin-up damp. The cue-timed spin-up
  still runs.
- **Multi-jump (OQ A3, ui_rules A9).** Depth = `max(1, 1 + Σ ModVal)` over owned ModType-32
  defs, once per def (OS-09); NPCs use DefaultItems (OS-01). It applies only in the jump-fire
  block (0x0044f3d0) when the route head is the system being jumped to. The hop loop advances
  along the plotted route `depth − 1 = Σ ModVal` systems **in total** (at least 1, clamped to the
  route length), so ModVal 1 is an ordinary jump and ModVal 2 covers two route systems, firing
  each intermediate system's region events; only the final system becomes discovered (level 1).
  Fuel is debited **once** (−100), and travel days are computed **once** (FL-05). The ship heads
  for the armed first hop. Latent original bug: if the route head stops resolving mid-loop, the
  current system is stored as −1.
- **NovaSwift.** `App/Game/GameScene.swift:~3356–3372, 3433`: ModType 37 is "instant", skipping
  align and shortening the burst to 0.18 s. Multi-jump charges fuel per hop and needs fuel for
  every hop (`NavigationModel.swift:111, 127`, `canAfford(hops:)`), multiplies ModVal by count
  (`Engine/ShipLoadout.swift:383, 398, 540`) and heads for the final hop
  (`App/Game/GameContainerView.swift:2063`).
- **Class.** FIX (the old fast-jump behaviour lives on under `quickHyperjump`). **Impact**
  medium. **Confidence** high (multi-jump per-def aggregation: medium).
- **Test.** A fast-jump ship moving at speed starts spin-up without stopping, and the spin-up
  takes the full cue time. A ModVal-2 multi-jump along a 3-hop route lands two systems on, costs
  100 fuel and one jump's days, and marks only the final system explored.

#### FL-07 · Fuel regeneration — **DONE**
- **Done.** `Loadout.fuelRegenPerSec` (NPC) and `playerFuelRegenPerSec` (hull term gated on Flags
  0x0008): `1/FuelRegen` per tick plus `count/ModVal` per ModType-18 outfit, negative draining
  (oracle-pinned). Capacity clamps to 0…32000. The player's regen runs while disabled.
- **Original.** 0x00463b30 (exe-verified): `+1/FuelRegen` per tick when FuelRegen > 0 and (NPC
  or hull Flags 0x0008); each ModType-18 outfit adds `count/ModVal` per tick. A negative ModVal
  drains fuel ("fuel sucking").
- **NovaSwift.** `Engine/ShipLoadout.swift:523` `fuelRegenPerSec = max(0, FuelRegen + ΣModVal) ×
  0.03`, applied at `Engine/World.swift:763` `regen`. That is inverted (FuelRegen 300 → 9 fuel/s
  instead of 0.1/s), has no 0x0008 gate, and clamps negatives away.
- **Also (outfits_special O1/O14).** NPCs add DefaultItems ModType-18 scoops (OS-01). Fuel
  capacity (0x00463a20, ModType 12) is clamped 0..32000, which `Engine/ShipLoadout.swift:522`
  lacks. The player's fuel regen has no disabled gate; NovaSwift stops it while disabled
  (`Engine/World.swift:1740`; medium confidence).
- **Class.** FIX. **Impact** high where it applies. **Confidence** high (exe-verified).
- **Test.** FuelRegen 300 with Flags 0x0008 gives 0.1 fuel/s; without 0x0008 the player gets 0;
  ModVal −300 drains 0.1/s.

#### FL-08 · Afterburner — **DONE**
- **Done.** Player-only per-call push and 1.8× caps decaying thrust × 0.4 per call, no thrust key
  needed; burn = last owned ModType 15 × 0.0333/tick. Oracle-pinned. NPC afterburning survives as
  the new `npcAfterburners` enhancement. Not reproduced: the original's one-tick lag between cap
  update and clamp.
- **Original** (decomp `spaceflight_movement.cpp`, 0x00451630 tail):
  - Engages when held, ModType 15 is owned, the maneuver timer ≤ 0, and `0 < burn ≤ fuel`.
  - Burn = the **last** owned afterburner's ModVal / 30 per tick, not multiplied by count
    (0x0046E060).
  - The normal clamp widens to 1.8 × max (`0x00575610`) unless in a gravity pull.
  - Each **raw call** adds thrust × 2.75 (`0x00575648`) per axis inside the 1.8× projection,
    otherwise it damps the axis ×0.99. This runs **without** the thrust key.
  - After release, each axis cap decays by thrust × 0.4 per call (`0x00575680`).
  - Frame-rate dependence is a known original bug; reproduce it at 47.6 calls/s via FL-01.
- **NovaSwift.** `Engine/ShipLoadout.swift:29–34` (×1.5 speed, ×1.4 accel), `:397` (fuel sums
  ModVal across outfits), and `Engine/World.swift:~916–923, 966–975` (needs the thrust key; one-tick
  clamp on release).
- **Class.** FIX. **Impact** medium-high. **Confidence** high.
- **Test.** Afterburner alone (no thrust) accelerates to 1.8 × max; after release the speed decays
  over several frames; two afterburners burn the last one's rate.

#### FL-09 · Reverse key — **DONE**
- **Done.** Turns to `bearing(v) + 180°` above the 0.05 px/tick gate, overriding the turn keys and
  face-target; inertialess reverse bleeds speed. Retro-thrust is `retroThrustReverse`. Auto-land
  and the jump align now steer instead of relying on retro-thrust.
- **Original.** `PlayerTick_ReverseCommand` 0x0044FFF0: a non-inertialess ship turns to
  `bearing(velocity) + 180°` one rounded turn step per tick, with no thrust and no damping, when
  `|vx| ≥ 0.05 || |vy| ≥ 0.05`. An inertialess ship's scalar speed decays by thrust × ticks.
- **With face-target held (OQ A9).** In 0x0044aa70 face-target runs first, then reverse, which
  overwrites the desired heading whenever either velocity component exceeds 0.05; below that the
  face-target heading drives the turn. Turn keys are ignored while either auto-turn is armed.
  The auto-turn step is `trunc(turnDeg)` per tick (FL-10), with a 30° fallback.
- **NovaSwift.** `Engine/World.swift:967` thrusts backward at 0.5 × accel and does not turn.
- **Class.** FIX+ENH → `retroThrustReverse`. **Impact** medium-high (a core EV control idiom).
  **Confidence** high.
- **Test.** At speed, holding reverse rotates the ship to face retrograde without changing |v|.

#### FL-10 · Player turn-rate quantization — **DONE**
- **Done.** `ShipStats.playerTurnDegPerTick` (exact, in hundredths; ModType 9 is ModVal × 0.01,
  not Maneuver units). The player's auto-turn stops within one step without snapping. Pinned to the
  emulator table (1–19 → 1 … 60 → 6). Sensitivity ≠ 1 applies only under `portFlightTuning`.
- **Original (settled, OQ A2).** `Ship_ComputeShipMaxTurnRateDeg` 0x00463e70 returns an
  unrounded float: Maneuver × 0.1, plus Σ ModType-9 `count × ModVal × 0.01`, floored to 1.0 when
  the base is ≥ 1 and the sum < 1, × 0.333 when velocity-matched, × (1 − min(I, 0.7)) when
  ionized, clamped ≥ 0. The player tick converts it with the compiler's FIST-and-correct idiom
  (0x0044c8d7), which is **truncation**: Maneuver 25 → 2°/tick, 29 → 2. NPCs step the unrounded
  rate × frame scale and snap when within one step. The decomp's `round` is wrong.
- **NovaSwift.** `Engine/World.swift:141` (`turnRate × turnScale`, unrounded) plus the
  `ControlTuning.turnScale` sensitivity multiplier (:23).
- **Class.** FIX (sensitivity ≠ 1.0 stays an enhancement). **Impact** medium.
  **Confidence** high.
- **Test.** Maneuver 25 and 29 both give 2 deg/tick for the player; a ModType-9 outfit adding
  0.5° to Maneuver 20 changes nothing.

#### FL-11 · Inertialess flight; AI formations — **DONE**
- **Done.** Hull-inertialess ships keep speed with no idle decay and steer by ≤ 4 × thrust per axis;
  `aiInertialess` defaults to `.off`, and the momentum/FormationGlue model is `formationFlying`
  (its boost/glue are ignored when off).
- **Original.** Thrust adds `thrust × ticks` to scalar speed, clamped. There is **no idle decay**.
  Velocity steps toward `heading × speed` by at most `thrust × 4.0 × ticks` per axis
  (`Ship_SteerVelocityTowardShipHeading` 0x0043B020). NPCs are inertialess only with class Flags2
  0x40 (not in control mode 0x0c).
- **NovaSwift.** `Engine/World.swift:933–962` (idle coast to stop at :940; reverse at :939);
  `:106` `aiInertialess = .formations` plus `formationGlue`/`formationBoost` (turn ×7, accel ×6,
  speed ×2) at :~870–893.
- **Class.** FIX+ENH → `formationFlying` (the FormationGlue work is deliberate; see the
  momentum-prototype notes). **Impact** medium. **Confidence** high.
- **Test.** An inertialess hull keeps its speed when thrust is released; a non-0x40 escort flies
  Newtonian.

#### FL-12 · Landing approach — **DONE**
- **Done.** Square `round(2r × 1.75)` envelope, 0.75 px/tick per axis, ±250 px clearance arm (per
  system visit), cloaked ships refused; the old circle is `forgivingLanding`. The "Cleared to land"
  message/cue, the 0x7ff selection expiry and landing on the *selected* body belong to UI-06/08/11.
- **Original.** 0x00457580 (arrival gate) and 0x00459950 (clearance):
  - The envelope is a square `|dx|, |dy| < R` with `R = round(spinFrameWidth × 1.75)` (75 with
    no sprite).
  - Speed must be `|vx|, |vy| ≤ 0.75` px/tick (22.5 px/s per axis) with the maneuver timer ≤ 0.
  - The stellar must first have been approached within ±250 px per axis, which arms the "Cleared
    to land" timer (0x2ee) and its cue. The selection expires at 0x7ff.
  - Cloaked ships are refused (STR# 0x7d2 #0x49).
- **NovaSwift.** `App/Game/GameScene.swift:467` (`landingSpeedLimit = 130` px/s) and `:1527`
  (circle of `radius + 70`); no clearance, no cloak refusal.
- **Class.** FIX+ENH → `forgivingLanding`. **Impact** medium. **Confidence** high.
- **Test.** A 96 px planet accepts at (160, 160) offset and rejects at 23 px/s on one axis.

#### FL-13 · Player hyperspace arrival — **DONE**
- **Done.** `World.placePlayerAtHyperspaceArrival(bearing:)`: 1350 px from (0,0) along bearing +
  180°, velocity zeroed then `effectiveMaxSpeed` along the whole-degree heading (inertialess: the
  scalar), no refill. Used in both jump modes.
- **Original.** `FireJump` (decomp `travel.cpp`): position = 1350 px from the system origin (0,0)
  along `jumpBearing + 180°`, no shield/armor refill. **Settled (OQ A4):** velocity is zeroed,
  then a polar velocity of `Ship_ComputeShipEffectiveMaxSpeed(player)` is added along
  `trunc(heading)` (asm 0x0044f5e7–0x0044f660), so it **includes** the non-strict ×1.5 and
  ModType-8 bonuses. An inertialess ship sets its scalar speed to that value instead. The decomp
  omits the ×1.5.
- **NovaSwift.** `App/Game/GameScene.swift:~3528–3537` and `Engine/Galaxy.swift:417` use the
  stellar **centroid** and `0.85 × jumpRadius` (1190–2720 px), with entry speed
  `min(2.4 × max, 3200)` decaying over 1.3 s (:3535–3536).
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** Arrival distance from (0,0) is exactly 1350 px; speed equals 1.5 × max speed for a
  non-strict pilot and 1.0 × for a strict one.

#### FL-14 · No-jump zone — **DONE**
- **Done.** `x² + y² ≤ r²` from (0,0), gated on any non-gate stellar; the radius is no longer
  clamped at 0 (the original squares it).
- **Original.** `Stellar_ComputeTravelRangeSq` 0x00465610 and 0x0044C18A: refused while
  `x² + y² ≤ (1000 + Σ ModType-23 ModVal × count)²` measured from **(0,0)**, but only if the
  system has at least one nav stellar with `(availability & 0x3000) == 0`. Fast jump does not
  bypass it. The disabled player cannot engage (FL-04).
- **NovaSwift.** `App/Game/GameScene.swift:~4053–4063` measures from `systemContext.center` and
  gates on `bodies.contains { $0.canLand }`. The radius formula matches
  (`Story/PilotEconomy.swift:169`).
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** A system with only an uninhabited planet still enforces the zone; an off-centre
  system measures from (0,0).

#### FL-15 · Skill variance, SkillMult, velocity-match and përs multipliers — **DONE**
- **Done.** `Galaxy.skillVarianceScale` (`range(2p + 1)`), class 0 for fleets, përs, defense ships and
  hired escorts; gövt SkillMult on speed and thrust. `Ship.velocityMatchTargetID` applies the ×0.333
  multipliers, but nothing sets it until the Batch 6 AI port.
- **Original.** At spawn, `scale = (rand(2p+1) + 100 − p) × 0.01` with p = SkillVar (clamped
  1..50). It applies to **max speed and thrust, not turn**, followed by gövt SkillMult (LD-01) on
  both (0x004640a0 / 0x004642e0; spawn 0x0046b870). The allocator draws variance from **class 0**
  for fleet members, përs, defense ships and hired escorts. Only random dudes and mission ships
  use their own class. A velocity-matched NPC gets thrust and top speed ×0.333 (§1).
  **Dropped (OQ A10):** përs slot 0x3ff's ×2 speed and thrust and +1 turn belong to the shareware
  License Enforcer (`Registration_SpawnLicenseEnforcer` 0x0046ac50), which a registered copy
  never spawns. NovaSwift does not port it.
- **NovaSwift.** `Engine/Galaxy.swift:202` `jitteredStats` scales accel and turn, not speed; it is
  skipped when SkillVar = 0. Hired escorts roll 0...1 only (`App/Game/GameScene.swift:~1835`). No
  SkillMult.
- **Class.** FIX. **Impact** medium. **Confidence** high (exe-verified multipliers).
- **Test.** A SkillVar-20 dude's speed lies in [0.8, 1.2] × base and its turn equals base.

#### FL-16 · Asteroid field — **DONE**
- **Done.** 16-slot field scattered on the first step around the player, `range(400)` drift, signed
  spin, off-view rocks dropped and refilled at the edge once per raw call, fragments
  `range(f) + f/2` into free slots, yields left as resource boxes (OS-11). The view size comes from
  the scene (`World.viewportHalfExtent`).
- **Original.** 0x004216b0 / 0x00421830 / 0x00421e60 / 0x00436910:
  - A 16-slot pool; `min(count, 16)` rocks scattered around the **player's viewport**.
  - Drift `(rand(400) − 200) × 0.01` px/tick per axis.
  - Spin `(rand(41) + 80) × 0.01 × spinRate` with a random sign.
  - Rocks leaving the window recycle to the far side, so the field travels with the player.
  - Destruction (0x00462550): fragments `rand(frag) + floor(frag/2)`; frag = 1 gives 0, a quirk
    to keep.
  - Yield `trunc((rand(101) + 50) × qty × 0.01)` **freeflight resource boxes** that must be
    scooped (0x0041f800 / 0x0041fb50 / 0x0042c1b0).
  - `Asteroid_SpawnRecord` 0x00421e60 (röid record → yield and spawn parameters) is only 40 %
    ported in the decomp; read it in Ghidra before porting the yield side. The scooping side is
    OS-11.
- **NovaSwift.** `Engine/World.swift:~1583–1621, 1623` `destroyAsteroid` and
  `Engine/Asteroid.swift`: static, uncapped, fixed spin sign; yield credited directly.
- **Class.** FIX. **Impact** medium (visible). **Confidence** high.
- **Test.** In an asteroid system at most 16 rocks exist, they drift, and they surround the player
  wherever the player flies.

#### FL-17 · Disabled drift damping — **DONE**
- **Done.** × 0.995 per raw call (velocity and inertialess speed).
- **Original.** 0x00433050: a disabled NPC's velocity × 0.995 per raw call (≈ 0.788/s).
- **NovaSwift.** `Engine/World.swift:1692` `1 − 0.35 × dt` (≈ 0.703/s).
- **Class.** FIX (needs FL-01). **Impact** low. **Confidence** high.
- **Test.** After 1 s a disabled hulk keeps 78.8 % of its speed.

#### FL-18 · Speed-cap shape — **DONE**
- **Done.** Per-axis polar clamp for all ships, plus the player's per-axis box. Float32 ties can
  differ by one step from the original (it overshoots an axis share our doubles land on exactly).
- **Original.** Thrust clamps each axis to its polar projection of max (0x0043B4E0); the final cap
  is a per-axis box (0x0044D05B), so turning under thrust can leave net speed slightly above max.
- **NovaSwift.** Magnitude clamp at `Engine/World.swift:~972–975`.
- **Class.** FIX. **Impact** low. **Confidence** high.
- **Test.** A diagonal heading under thrust reaches `|v| > max` by the expected margin.

#### FL-19 · Stellar gravity and crash immunity — merges outfits_special O12 — **DONE**
- **Done.** `Gravity / max((d/100)², 30)` px/tick per tick (0x00575860 = 30.0) for every ship;
  shielding = Flags3 0x0020, inertialess, or the player's ModType 41; crash immunity = Flags3 0x0020
  or the player's ModType 42. Any gravity stellar in the system stops the afterburner widening.
  Q-FL-14 settled: ModType 38 is not read. The pull direction is exact, not the integer bearing.
- **Original.** 0x0043adb0 / 0x0046e2f0: `accel = gravity × ticks / max(d², 1)` toward each
  stellar with gravity, for all 64 ships. A gravity pull disables the afterburner's 1.8×
  widening. Immunity (`Stellar_ShipHasGravityShielding` 0x0046e120): shïp **Flags3 0x0020**, any
  inertialess hull, or (player only) ModType 41. Crash immunity
  (`Stellar_ShipImmuneToStellarCrash` 0x0046e210): Flags3 0x0020, or (player only) ModType 42.
  No code reads Flags3 0x0010 ("ignores gravity" in the Bible): an original quirk to keep.
- **Coverage.** 0x0043adb0 is only 10 % ported and 0x0046e120 25 %, and NovaSwift's rule came
  from the wiki. Read the Ghidra function in full (NPC tick placement, crash interaction) before
  porting; that is the remaining part of Q-FL-04.
- **NovaSwift.** `Engine/World.swift:1792` `applyStellarGravity`: `gravity × min(1, r²/d²)`
  px/s². The inertialess exemption is correct. `Kit/NovaModels.swift:566` tests Flags3 0x0010,
  and ModType 41/42 apply to any ship (`Engine/ShipLoadout.swift:637–638`).
- **Contradiction.** The first pass listed the player's exemption as "ModType 38 or 41";
  outfits_special reads 0x0046e120 as Flags3 0x20 / inertialess / ModType 41 only. Re-read
  0x0046e120 before porting (Q-FL-14).
- **Class.** FIX. **Impact** low-medium. **Confidence** medium (flags: high).
- **Test.** The player's acceleration at distance d matches `gravity/d²` × 900 px/s². A Flags3
  0x0010 hull is pulled; a Flags3 0x0020 hull is not; an NPC with a ModType-41 default item is
  pulled.

#### FL-20 · Launch placement and refill — **DONE**
- **Done.** Stellar centre, at rest, `range(360)` heading, shields and armor refilled (takeoff and a
  load while docked).
- **Original.** `Stellar_RunDockAndLaunchSequence` 0x00455e10: velocity zeroed, position = the
  stellar centre, heading = rand(360)°, shields and armor refilled free (see EC-06).
- **NovaSwift.** `App/Game/GameScene.swift:3603` `reloadForDeparture` places the ship `radius + 60`
  out, facing away from the centroid.
- **Class.** FIX. **Impact** low. **Confidence** high.
- **Test.** The launch position equals the stellar position; the heading distribution is uniform.

#### FL-21 · World wrap — **DONE**
- **Done.** `World.recenterForWorldWrap`: ships, shots, rocks and boxes within 15000 px move with
  the player; distant NPCs never wrap. Scene-only effects are not shifted.
- **Original.** `Ship_RecenterSpaceObjectsForWorldWrap` 0x0045BAA0: when the player passes
  |x| or |y| > 15000 from the origin, the player and every ship, shot and effect within 15000 px
  of the player shift by ∓25000 on that axis. Stellars stay put.
- **NovaSwift.** `Engine/World.swift:1862` `wrapIntoSystem` folds each ship toroidally at
  `max(jumpRadius + 3000, 10000)` around the centroid, without carrying neighbours.
- **Class.** FIX. **Impact** low-medium. **Confidence** high.
- **Test.** Crossing x = 15000 puts the player at −10000 with a nearby escort still alongside.

#### FL-22 · RNG algorithm and draw shape — **DONE**
- **Done.** `NovaRandom` (bit-exact, oracle-pinned, including seeds ≥ 2³¹ and negative bounds;
  `range(0)` returns 0 and leaves the seed). `World.rng` uses it; integer draws at the sites ported
  here (headings, drift, skill, asteroids, boxes). The AI's continuous draws stay until Batch 6.
- **Original (settled, OQ A1; oracle-verified).** One generator, `NovaRandom_Range` 0x004683b0,
  the Mac Toolbox `Random()`: Park–Miller MINSTD, `seed = seed × 16807 mod (2^31 − 1)` on the u32
  seed at 0x007ccdd8. The output uses only the low 16 bits: `u = seed & 0xFFFF`, with 0x8000
  mapped to 0 (the stored seed is unchanged), and `Range(n) = (n × u) >> 16`, giving `[0, n)` with
  0 very slightly over-weighted. `Range(0)` reseeds from the clock and the 60 Hz tick and returns
  **garbage** (the caller's EBP); `NovaRandom_Reseed` 0x004ab970 is `Range(0)`, called once at
  startup. There is no CRT `rand`. Any formula whose range truncates to 0 hits the reseed path,
  so dynamic-range call sites (bribes, plunder) must be checked for their `max(1, …)` guards.
  The decomp substitutes mt19937, so its sequences are not faithful.
- **NovaSwift.** `Engine/RNG.swift` SplitMix64 with many continuous `double(in:)` draws where the
  original draws integers.
- **Class.** FIX: adopt the MINSTD generator and the `Range` scaling, and use integer draws
  wherever the original does (rand(360) headings, rand(400) drifts). Bit-exact *sequences*
  additionally need the original's call order, which only the per-system ports can deliver, so
  treat sequence identity as a test aid, not a requirement. Reproduce the `n == 0` garbage return
  as a deterministic stand-in (document the chosen value). **Impact** low-medium.
  **Confidence** high.
- **Test.** Oracle golden values: seed 1, `Range(100)` ×10 → `25 23 67 4 71 85 55 3 18 1`; seed
  12345, `Range(32767)` ×8 → `30486 11007 10335 21947 10961 8331 10285 32036`. Launch headings are
  whole degrees.

#### FL-23 · Jump-engage and player-tick fragments — from the coverage map — **DONE**
- **Done (cleanup 1).** The +0x50 "engage countdown" is the jump timer FL-04 already runs (seed 2,
  fire at ≥ 30 ticks with the cue; `PlayerHyperjump.timer`). The cannot-jump overlay clear: while
  the jump command engages, and every tick the timer runs, a status line still showing #42 / #36
  / #30 / #31 is replaced by an empty one (0x0044aa70 → `GameScene.clearCannotJumpOverlays`). The
  tribble tick is EC-24.
- **Done.** Engage is refused silently while disabled. Read 0x0044c2e0 for the taunt: it counts
  attached **behavior-5 (bay) fighters** that can't jump and whose class lacks Flags2 0x0010, and
  shows `<class name>: ` + STR# 2002 #160/161 (one) or #162/163 (several) — "Wait for me!" / "Wait
  for us!" — so it is a fighter warning, not an escort hyperdrive check. At the fire those fighters
  are abandoned (#164/#165 line) and the rest dock back (UI-02).
- **Deferred.** The +0x50 engage countdown, the cannot-jump overlay auto-clear (UI-11), the
  tribble tick (EC-24).
- **Original.** The player-ship core (`Ship_HandlePlayerShipCore` 0x0044aa70, 47 % ported) and
  its untagged fragments 0x0044bf50 / 0x0044ead0 / 0x0044c2e0 / 0x0044eed5 / 0x0044df50 hold:
  - jump engage: a countdown at ship +0x50, and an escort taunt (STR# 2002 #160–163) when an
    escort's shïp lacks the hyperdrive flag 0x10 at class +0x9ea;
  - the "cannot jump" overlays #30 / #31 / #36 / #42, cleared automatically once a jump becomes
    legal (UI-11);
  - the arrival vector derived from the sÿst link geometry (FL-13);
  - the tribble/perishable tick every 250 frames (EC-24).
  `Ship_RunSpaceflightMode` 0x00489210 is only 12 % ported and
  `PlayerTick_MouseTargetAndControlCommands` 0x0044e019 27 %.
- **NovaSwift.** No escort-hyperdrive check at jump engage.
- **Class.** FIX. **Impact** low-medium. **Confidence** medium (fragment boundaries are Ghidra
  mis-splits; read the parent and fragments together).
- **Test.** Jumping with a hyperdrive-less escort shows one of STR# 2002 #160–163.

#### OS-06 · Hypergate and wormhole transit — **DONE**
- **Done.** Gate transit runs no daily tick. Arrival is at the destination gate's position, facing
  its emergence angle (else `range(360)`), at 0.5 × effective top speed.
  `NovaGame.wormholeExitCandidates(from:currentSystem:isVisible:)`: links filtered to visible
  systems ("Unable to use this wormhole." when none); link-less picks other link-less wormholes
  outside the current system in visible systems, with no fallback. Q-OS-02 stays a static read.
- **Original.** `Stellar_EnterHypergate` 0x00456480 / `Stellar_EnterWormhole` 0x00456ca0 and the
  shared arrival (decomp `NovaTravel_CompleteRestrictedTravel`): payroll periods are zeroed and no
  daily tick runs, so gate and wormhole transit costs **0 days** (none of the seven daily-tick
  callers in FL-05 is on this path). Arrival is at the destination stellar's exact position,
  heading = its emergence angle when 0–359 (else random), speed 0.5 × max. A wormhole with links
  picks uniformly among links whose system is visible; if it has links but none is visible,
  travel fails with "Unable to use this wormhole". A link-less wormhole picks among other
  available, link-less wormholes, excluding the current system and requiring a visible system.
- **NovaSwift.** `advanceGameDay()` on every gate jump (`App/Game/GameContainerView.swift:1485`);
  wormhole fallback is any other wormhole without the visibility or current-system filters
  (`Kit/NovaModels.swift:1296–1305`); arrival is offset from the gate with speed capped at 160
  (`App/Game/GameScene.swift:3510–3522`).
- **Class.** FIX. **Impact** medium. **Confidence** medium-high (0 days inferred from the absence
  of a tick; confirm in 0x00457580, Q-OS-02).
- **Test.** A gate jump leaves the date unchanged; a wormhole whose only link is hidden refuses.

#### OS-11 · Mining scoop and resource boxes — **DONE**
- **Done.** `FreeflightObject` pool (64; 300–499 tick life, random spin and drift); a player with
  ModType 31 and room in the hold (`World.playerHoldHasRoom`) collects 1 ton per box; hull Flags3
  0x0002 no longer grants a player scoop. NPC miners (AI state 0x11) and jettisoned cargo are later.
- **Original.** Destroyed asteroids drop freeflight debris objects (FL-16). A ship with the scoop
  latch (the player with ModType 31 and free cargo, or an NPC in AI state 0x11) collects **1 ton
  per object** by pixel overlap (0x004374f0, 0x0046cb90); debris can also be junk (1000–1127).
  The latch clears when cargo + junk ≥ fleet capacity. Hull Flags3 0x0002 only drives the AI miner
  (AI-31), **not** the player scoop.
- **NovaSwift.** The killer instantly receives `yieldQty ± 50 %` tons, and hull Flags3 0x0002
  grants the player a scoop (`Engine/ShipLoadout.swift:352`; `Engine/World.swift:1634–1637`).
- **Class.** FIX (with FL-16). **Impact** medium-low. **Confidence** high.
- **Test.** Destroying a rock without a scoop yields nothing; with a scoop, flying through 3 boxes
  adds 3 tons.

### Batch 2 — weapons, damage, disable, combat rating

Batch 2 landed in `Engine/World.swift` (damage, shots, beams, point defense, cloak, bays),
`Engine/EscapePod.swift`, `Story/EscapePodRespawn.swift` and the host. Tests:
`OriginalWeaponsTests`, `EscapePodTests`, `EscapePodRespawnTests`, plus `CombatTests`,
`CloakTests`, `FighterBayTests` and `DiplomacyTests` rewritten to the original's numbers.

#### WP-01 · Beams damage every tick of their lifetime — **DONE**
- **Done.** `World.BeamRecord`: every fire of a beam bank queues a record (64 max) that lives
  `Count` raw calls (+ `16 − CoronaFalloff` fading calls with Decay) and deals the full weapon
  damage on every call it touches a ship, so Count > Reload stacks. A fixed beam lies along the
  hull's sprite frame, a turret beam tracks its target, spread is redrawn per call. Weapon fire
  itself runs per 30 Hz step except Reload 0, which fires on every raw call.
- **Original.** `Shot_UpdateBeamHitQueue` 0x0042f270: each queued beam record lives `Count`
  ticks and applies mass + energy damage on every tick it stays in contact, plus `15 − Falloff`
  extra ticks when Decay > 0. Beams re-queue every Reload, so Count > Reload stacks (the known
  "auto machine-gun" bug).
- **NovaSwift.** `Engine/World.swift:2297` `fireBeam` damages once per reload; `refreshBeam` only
  moves geometry; `Engine/Combat.swift:505` uses Count for visual life.
- **Cadence (OQ B5).** Beam life is −1 per raw call (also on reduced x2-mode passes), and damage
  is the full Mass/Energy per call, so a Count-N beam lasts N × 21 ms and its DPS is dmg × 47.62.
- **Class.** FIX (per raw call; needs FL-01). **Impact** high (beam DPS ≈ 1/Count of the
  original). **Confidence** high.
- **Test.** A Count-10 beam held on a target for one Reload deals 10 hits.

#### WP-02 · Disable is derived from armor, not latched — **DONE**
- **Done.** `Ship.disabled` is derived on every read (`armor < max × 0.33333`, 0.10 with Flags
  0x0010); `heldDisabled` carries the derelict-government and un-boarded rescue arms (and is what
  a plain `disabled = true` writes). Derelicts and rescue ships keep their real armor; a stellar's
  defense ship is never disabled by armor. `Ship.applyDamage(nonLethal:)` is the Flags2 0x1000
  arm (armor stops at 1); the AI-state arms wait for Batch 6. **Added from the exe:** a hit that
  takes a ship straight past the line to destroyed pays DisabPenalty as well as KillPenalty.
- **Original.** `Ship_IsShipDisabled` 0x004687b0 (exe-verified) evaluates
  `armor × 100 < maxArmor × 33.333` (10.0 with hull Flags 0x10) every frame. A ship is also
  disabled if its government has Flags 0x0800, or if it is an un-boarded rescue mission ship.
  Destruction is `armor ≤ 0`. Armor just subtracts, so one hit can go straight from healthy to
  destroyed. A disabled hulk keeps its real armor (up to 33 %).
- **AI disable-only shots (OQ B6).** A shot carries a non-lethal flag when wëap Flags2 0x1000
  is set; or the shooter (an NPC) is locked on that target in AI state 0x0D, or state 4 with
  control 0x0F (`Ship_IsShipLockedOnTarget` 0x004124f0; beams also need `param_6 ≠ 1`); or, for
  projectiles, the shooter is in state 0x0D at all. `Ship_ApplyDamageToShip` also flags direct
  hits when the attacker or its squad leader is in state 0x0D and targets this ship. Non-lethal
  armor damage that would reach ≤ 0 sets armor to 1.0 instead (unless already ≤ 0). This is the
  only "can't kill" rule; NovaSwift's universal latch is not.
- **NovaSwift.** `Engine/World.swift:2871–2873` latches `disabled` at `≤ maxArmor × 0.33` and
  sets armor to `max(1, maxArmor × 0.02)` even on a killing blow. Derelicts and mission wrecks get
  2 % at `:1282, :1496`.
- **Class.** FIX. **Impact** high (no one-shot kills; wrong kill/disable ratio; hulks too
  fragile). **Confidence** high (exe-verified).
- **Test.** A hit taking a ship from 50 % to −10 % armor destroys it outright. A ship disabled at
  30 % needs 30 % more armor damage to die.

#### WP-03 · The player can be disabled — **DONE**
- **Done.** No player exemption. On the transition the player's armor truncates, a 300-tick
  post-disable window starts (`recentlyHitTicks`), the host shows STR# 2002 #287 and fails
  Flags2-0x0004 missions; while disabled only the face-target auto-turn works, velocity damps
  × 0.995 per raw call, nothing regenerates or fires, and jump engage is refused (FL-23).
- **Original.** On the transition (decomp `collision.cpp`), the game shows the "disabled" overlay
  (STR# 0x7d2 #0x11f), arms a 300-tick recently-hit timer, and quick-fails missions with Flags
  0x0004. While disabled, the player has no input except face-target turning, restricted-velocity
  damping, and no shield/armor regen. Jump engage is refused and an engaged jump collapses
  (0x0044B037). Pirates can board (AI-29).
- **NovaSwift.** `Engine/World.swift:2871` excludes `isPlayerControlled` from disabling.
- **Class.** FIX (after MS-01). **Impact** high. **Confidence** high (exe-verified: no player
  exemption in 0x004687b0).
- **Test.** Player armor at 30 % gives the disabled overlay, no thrust, a Flags-0x0004 mission
  failed, and jump refused.

#### WP-04 · Combat rating ×0.2, escort kills, exclusions — dedupes weapons #4 and economy D3 — **DONE**
- **Done.** `CombatRatingRule` (oracle-pinned table in `DiplomacyTests`): Strength < 5 → +1,
  else trunc(× 0.2); a rating at 10,000,000 stays there. Credited (with the legal penalties) for
  the player's and direct escorts' kills, never for defense ships or derelict governments; the
  host folds the delta with `CombatRatingRule.fold`. Shipped with AI-03.
- **Original.** `Frame_AddCombatRatingPoints` 0x0046f1e0 (exe-verified): `strength < 5` → +1;
  else `rating = trunc(rating + strength × 0.2)`; at ≥ 10,000,000 the rating is set to
  10,000,000. It is credited when the player **or a direct player escort** kills. Defense-fleet
  ships, the Shareware-Enforcer përs (0x3ff) and derelict-government ships are excluded. Rank
  thresholds 100 / 200 / … / 25600 already match. This settles GOVERNMENT.md §3.
- **NovaSwift.** `Engine/Diplomacy.swift:293` `combatRating += shipStrength`; only `ownerID == 0`
  kills count (`Engine/World.swift:~2898–2903`).
- **Class.** FIX. Ship it with AI-03. **Impact** high (titles, AvailRating gates and the tribute
  gate unlock about 5× early). **Confidence** high.
- **Test.** Killing a Strength-30 ship adds 6; Strength 3 adds 1; an escort kill counts.

#### WP-05 · Homing (mode 1) missiles — **DONE**
- **Done.** `World.stepGuidance`. **Correction:** turning starts once the shot is older than
  `15 × frame scale` normalized ticks — 15 *raw calls*, ≈ 9.45 ticks (0.315 s) — not 15 ticks.
  Velocity is Speed along the heading every tick; a dead target latches 998 (inert, hits nothing).
  `canShotHit` is `Weapon_CanWeaponHitTarget`.
- **Original.** `Shot_UpdateShotGuidance` 0x00431530:
  - Pure pursuit with bearing straight to the target, no lead.
  - Turning starts only after shot age > 15 ticks.
  - Turn = GuidedTurn × 0.1 deg/tick, and it holds rather than overshooting.
  - It hits **only its recorded target** unless Flags2 0x0008
    (`Weapon_CanWeaponHitTarget` 0x00426ef0).
  - If the target dies, the shot latches inert state 998.
- **NovaSwift.** `Engine/World.swift:~2527–2540` leads from frame 0 and collides with any
  `canHit` ship; untargeted missiles hit anything.
- **Class.** FIX. **Impact** medium-high. **Confidence** high.
- **Test.** A missile flies straight for 0.5 s, then pursues; it passes through a bystander.

#### WP-06 · Blast-radius splash — **DONE**
- **Done.** `World.blast`: square, inclusive, full undecayed damage and impact, any government,
  owner spared if an NPC or (player) with Flags 0x0100, ionization × `(1 − d²/r²)`. The old
  blanket immunity is the `playerBlastImmunity` enhancement. Co-op's friendly-fire rule still
  gates one player's blast on another.
- **Original.** 0x00437780 (exe-verified; see §1): per-axis square, full raw damage and impact,
  no government gate, NPC owner immune, player owner immune only with wëap Flags 0x0100. Splash
  ionization is attenuated `points × (1 − d²/r²)` (0x0046f3f0).
- **NovaSwift.** `Engine/World.swift:~2684–2701`: ×0.5, euclidean, `canHit` gate, owner always
  spared; `blastSparesPlayer` (:2694) and `friendlyFireAllowed = false` (:2691) exempt the player
  from every blast; no splash knockback.
- **Class.** FIX+ENH → `playerBlastImmunity`. **Impact** medium-high. **Confidence** high.
- **Test.** Point-blank player rocket without 0x0100 hurts the player; a same-government
  bystander takes full damage.

#### WP-07 · Expiry blast needs wëap Flags 0x8000 — **DONE**
- **Done.** `World.expire`; an expiry blast also passes over planet-type ships.
- **Original.** On expiry (`Shot_HandleShot` 0x00435830 arm), area damage runs only with Flags
  0x8000, BlastRadius > 0 and no Flags2 0x0400; otherwise only the impact effect plays.
- **NovaSwift.** `Engine/World.swift:2563–2567` → `detonate(expired: true)` always blasts when
  `blastRadius > 0`.
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** A missile without 0x8000 that misses deals no area damage at end of life.

#### WP-08 · Submunitions — **DONE**
- **Done.** `World.spawnSubmunitions`: only from a proximity-fuse hit or expiry (unless Flags2
  0x0020); rockets inherit the parent's velocity, others start from rest; a negative SubTheta fans
  evenly across ±|θ|.
- **Original.** `Shot_SpawnLinkedShotsOnImpact` 0x00420d30 runs on a proximity-pass hit (the
  direct sprite-contact pass passes "no linked shots"), and on expiry unless Flags2 0x0020. Mode 6
  children inherit the parent's velocity; others start polar from rest. SubTheta < 0 fans the
  children deterministically.
- **NovaSwift.** `Engine/World.swift:2719` spawns on every non-expiry detonation; no negative fan.
- **Class.** FIX. **Impact** medium-low. **Confidence** medium-high.
- **Test.** A ProxRadius-0 splitter does not split on direct contact.

#### WP-09 · Jamming — **DONE**
- **Done.** Per-channel lock rolls at launch; `World.jamScores` (inherent government of the hull's
  `InherentGovt` + jammers, halved for an NPC of a Flags-0x0080 government, 0 disabled); a jammed
  seeker keeps its target with turn 0 (negated for 0x0010), 0x8000 turns on its owner at 1/500
  per raw call, and losing a cloaked target flattens the turn (1/1000 retarget).
- **Original.** 0x00431530 and `Ship_GetShipJammingScore` 0x00464810. At launch each channel rolls
  `lock[ch] = rand(JamVuln + 1)`. Each frame, if `jamScore[ch] > 100 − lock[ch]`, the turn rate is
  0 (negated with Seeker 0x0010) and the target is kept. Seeker 0x8000 retargets the owner at
  1/500 per raw call. The jam score is the class's **InherentGovt** InhJam plus jammer outfits
  (the player's counted once per owned def, OS-09; an NPC's from its DefaultItems, OS-01),
  halved for government Flags 0x80, clamped 0..100, and 0 when disabled. Jamming starts once the
  shot's normalized age exceeds 15 × scale. A separate cloak-rules loss of lock retargets at
  1/1000 per raw call (OQ B5).
- **NovaSwift.** `Engine/World.swift:2500`: only Seeker 0x0010 weapons are jammable; per-second
  `jamChance × dt` clears the target permanently; 0x8000 is 50 %; strength uses `t.government`.
- **Class.** FIX. **Impact** medium (most jammable missiles are immune today). **Confidence** high.
- **Test.** A jam score of 100 against JamVuln 50 flattens the turn while the target is kept.

#### WP-10 · Seeker 0x0008 interference, 0x0002 asteroid decoy — **DONE**
- **Done.** **Correction:** the launch roll is `rand(trunc(100 / scale)) + 1 ≤ Interference` with
  the scale ≈ 0.63, i.e. `rand(158)`, so an Interference-100 system confuses ≈ 63 % of 0x0008
  missiles, not all. The weave and the 1-in-10 asteroid decoy (state 1) are per raw call.
- **Original.** 0x0008: at launch, `rand(100/frameScale) + 1 ≤ sÿst.Interference` latches state
  999, a weave alternating ±GuidedTurn on a 300-call phase. 0x0002: on a 1/10 roll per raw call, an
  asteroid within 200 px per axis and 16° steals the lock.
- **NovaSwift.** 0x0008 scales the turn (`Engine/World.swift:~2534–2536`); 0x0002 is decoded
  (`Engine/Combat.swift:~109`) and unused.
- **Class.** FIX. **Impact** low-medium. **Confidence** high.
- **Test.** In an Interference-100 system every 0x0008 missile weaves.

#### WP-11 · Graded ionization — **DONE**
- **Done.** `Ship.ionIntensity`; the speed drag lives in `Ship.deionize`; the player's turn step
  truncates after the × (1 − I).
- **Original.** Intensity `I = min(0.7, ionPoints / capacity)` (`Ship_GetIonizationIntensity`
  0x0046c160; the 0.7 clamp is exe-verified in 0x004640a0).
  - Thrust × (1 − I). Turning × (1 − I) only while not thrusting.
  - Velocity damps toward (1 − I) × max at 0.025/tick.
  - Points accumulate uncapped.
  - Weapon Seeker 0x20 pins only at I ≥ 1.
  - Decay = Deionize × 0.01 per tick (LD-01).
- **NovaSwift.** `Engine/World.swift:2798` caps the charge; `Engine/World.swift:330` freezes
  control only at the cap.
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** At 50 % ion charge, thrust is × 0.5; at ≥ 70 % it stays × 0.3.

#### WP-12 · Negative shields; shield-piercing — **DONE**
- **Done.** `Ship.applyDamage`. HUD bars clamp at 0.
- **Original.** 0x004192d0 `Ship_ApplyDamageToShip`: `shield −= energy`. If `shield ≤ 0`,
  `armor −= mass` and the shield floors at −10 % of max. With wëap Flags 0x0020 only armor damage
  applies, with no shield flash.
- **NovaSwift.** `Engine/World.swift:742` `applyDamage` floors the shield at 0; piercing hits
  still apply shield damage.
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** After a shield break, a mass-only hit reaches armor until the shields regenerate
  above 0.

#### WP-13 · Death hull blast and DeathDelay — **DONE**
- **Done.** `Ship.deathSequenceDuration` (DeathDelay raw calls, × 3 for the player, to the
  finale at 2) and `World.deathBlast`. **Correction:** the blast is called with the non-lethal and
  "keep above the disable line" arms (param_9/param_10) and impact 750, not armor-only: it can
  neither kill nor disable (a ship pushed past the line is left at `max × 0.3333 + 1`). Skipped for
  planet-type hulls.
- **Original.** `Ship_UpdateVisualState` 0x00428340: hulls ≥ 100 t blast
  `radius = mass × 0.075 + 50` and `damage = mass × 0.0375 + 25` (to both shields and armor,
  armor-only forced) across the square radius. DeathDelay frames drive the timer, ×3 for the
  player.
- **NovaSwift.** Fixed `deathSequenceDuration = 1.8` (`Engine/World.swift:644`); `shïp.deathDelay`
  is decoded (`Kit/NovaModels.swift:498`) but unused; no blast.
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** A 400 t hull's death deals 40 to ships within 80 px per axis.

#### WP-14 · Point defense — **DONE**
- **Done.** `World.runPointDefense`: per raw call, first ready bank only, cooldown `+= Reload /
  mounted`; mode-9 rounds hit homing shots only (friend or foe, durability bite) and ships only by
  proximity; mode-10 beam records bite per call. A target *ship* (hull Flags2 0x0008) must be
  attacking the owner or its leader (from the exe).
- **Original.** `Weapon_SelectTurretTargetWithinArc` 0x0043a310:
  - Only the first ready mode-9/10 bank fires, once per call (known bug).
  - Reach is range × 1.5 for mode 9 and BeamLength for mode 10; blind spots apply.
  - Targets are mode-1 shots that are neither jammed nor decoyed, lack Flags 0x0080, and target
    this ship or its squad leader. With no such shot, a ship whose class has Flags2 0x0008 may be
    targeted.
  - Mode 9 fires a real lead-aimed projectile. A mode-10 beam subtracts `mass + ceil(energy/2)`
    per tick from the shot's Durability.
  - Cooldown `+= reload / mounted`.
  - **Mode-9 projectiles (settled, OQ B1).** They live in their own sprite pool and collide only
    with Guidance-1 shots (and asteroids) through a bounding-rectangle callback (0x00438630).
    There is **no friend/foe check**, so a PD round destroys friendly missiles too. Each contact
    consumes the PD round; if the missile's durability is > 0 it loses `MassDmg +
    trunc(EnergyDmg/2)`, otherwise it dies (impact effect 0 at the PD round). A missile of
    Durability D therefore needs `ceil(D/dmg) + 1` contacts. PD rounds never hit ships by
    contact, only through a ProxRadius > 0 blast. The beam path uses the same truncating
    `trunc(EnergyDmg/2)` (×2 in x2 mode); the decomp rounds half up, which is wrong.
- **NovaSwift.** `Engine/World.swift:1882` `runPointDefense`: every PD mount fires, reach =
  range, any hostile homing shot, instant kill, Durability counts hits.
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** Two PD turrets fire one shot per call between them; a missile aimed at another ship
  is ignored.

#### WP-15 · Quadrant turrets (modes 7/8) — **DONE**
- **Done.** `World.fireAngle` / `npcFireEnvelope`.
- **Original.** The arc is < 46° from the nose (7) or tail (8).
  - Player (0x00455150): mode 7 out of arc or without a target dumb-fires; mode 8 holds fire.
  - NPC (0x00414550): out of arc both hold; without a target, 7 dumb-fires and 8 holds.
  - NPC fire also needs `|dx|, |dy| < range + 32`.
- **NovaSwift.** `Engine/World.swift:2099`: both fire along the ship's axis, with a 45° arc.
- **Class.** FIX. **Impact** low-medium. **Confidence** high.
- **Test.** A rear turret with no target in arc stays silent.

#### WP-16 · Knockback and recoil — **DONE**
- **Done.** `World.applyKnockback` (from `applyHit`), `World.applyRecoil`. A tractor beam pulls
  through the same path; the original's shooter-pulled-by-heavier-target arm is not ported.
- **Original.** Impact pushes `impact / massTons` along the impact→target bearing, clamped per
  axis to the class base speed and then to effective max. It is skipped for capability 0x400 hulls
  and in hyperspace; a negative (tractor) impulse is zeroed within 50 px (0x0043b4e0). Recoil is
  `kickback / mass` toward the hull's rear once per volley; the player only for > 0, NPCs for any
  value except −1.
- **NovaSwift.** `Engine/World.swift:2680` `impact × 6 / max(4, radius)`; `:2286` `applyRecoil`.
- **Class.** FIX. **Impact** low-medium. **Confidence** high.
- **Test.** Equal impact moves a 50 t hull 4× as far as a 200 t hull.

#### WP-17 · Projectile collision geometry — **DONE**
- **Done.** Kit builds 1-bit opaque masks straight from the `rlëD` opcode stream
  (`RLED.decodeMasks`, `SpriteMaskSet`, 64-bit words per row; `NovaGame.collisionMask(rleID:)` /
  `shipCollisionMask` / `weaponCollisionMask`, cached, not dropped by `flushSpriteSheets`);
  `Galaxy.hullCollisionMask` / `shotCollisionMask` cache them per hull / spïn for the engine.
  `World.spriteContact` tests each raw call's discrete position (no swept path, so fast shots
  can skip small hulls, as in the original): broad phase on the frame rectangles, then a hull
  frame ≤ 32 px wide uses the strict `<` half-width circle (`SpriteContact.circlesOverlap`,
  0x00475be0), a wider one the mask overlap (0x00475c80). Placement: hull top-left = pos −
  (w/2, h/2), shot top-left = pos − (w/2, w/2), integer pixels, y down. Frames:
  `SpriteFrames.headingFrame` = `trunc(heading° × frames / 360)` (0x00428340), now also what
  `HullAnim.heading`, `Ship.spriteFrame` and the shot renderer use; spin shots cycle
  `Projectile.animFrame` every `BeamWidth` ticks per raw call, wrapping or holding (Flags2
  0x0002), frame 0 during ProxSafety with Flags2 0x0001. Proximity width is the hull frame width.
  Ships without sprite data (hand-built test ships) keep the swept circle; a shot without a
  graphic is one opaque pixel. Enhancement `sweptShotContact` restores the old swept circle.
  Cost (release, 144×144 hull vs 48×48 shot, broad phase included): ≈ 170 ns per candidate test;
  a mask frame is 8 B × ⌈w/64⌉ × h (3.4 KB for a 144 px frame, 124 KB for 36 such frames).
- **Approximations.** The hull mask is the level-flight set's heading frame (banking/animation
  sets are renderer-side); positions are floored world pixels, not camera-relative truncation; a
  spin shot starts on frame 0 (the original randomises unless Flags 0x0004); asteroids still use
  their circle (the original always masks them).
- **Original.** `Sprite_TestPixelMaskOverlap` 0x00475c80 tests opaque pixels of the shot frame
  against the ship frame. It falls back to a strict `<` bounding circle summing both half-widths
  when the frame is ≤ 0x20 wide or scaled ≥ 2.0 (0x00475be0). Proximity is
  `trunc(ProxRadius + 0.333 × shipFrameWidth)`.
- **NovaSwift (before).** Swept point against a `max(w,h)/2` circle; proximity `radius + ProxRadius`.
- **Class.** FIX+ENH → `sweptShotContact`. **Impact** low-medium. **Confidence** high.
- **Test.** `SpriteCollisionTests` (a pixel inside the old circle but clear on a stock hull misses,
  the centre hits, a ≤ 32 px frame uses the circle, the circle is strict); `SpriteMaskTests`
  (masks equal the decoded alpha of stock sheets).

#### WP-18 · Asteroid damage — **DONE**
- **Done.** `World.applyAsteroidHit`: energy only (× 10 with Flags2 0x8000), destroyed below
  zero, surviving rocks nudged and clamped.
- **Original.** `integrity −= energyDamage` (× 10 with Flags2 0x8000); mass damage is ignored;
  destroyed at `< 0`. A surviving rock is nudged by `impact / def.mass`, clamped ±2 px/frame.
- **NovaSwift.** `Engine/World.swift:2467` `applyAsteroidHit`: `(shield + armor) × damageScale`,
  ×10 on armor, `≤ 0`, no nudge, and `damageScale` applied twice.
- **Class.** FIX. **Impact** low-medium. **Confidence** high.
- **Test.** A pure-mass weapon cannot mine.

#### WP-19 · Shot lifetime and launch velocity — **DONE**
- **Done.** `WeaponSpec.lifeTicks` / `World.spawnProjectile`; rocket blend and bomb weathervane
  per raw call in `stepGuidance`.
- **Original.** `Shot_SpawnShotFromWeapon` 0x0041fd30: life = raw Count ticks; velocity = owner
  velocity + polar(heading, speed) for every mode except 5/6.
  - Player mode-5 bombs keep 0.8 × owner velocity and weathervane 1° per call.
  - Player mode-6 rockets blend `v = (v × 95 + polar × 5) × 0.01` per raw call.
  - NPC 5/6 shots get the full polar add.
- **NovaSwift.** `Engine/Combat.swift:445–446` life = `range/speed` with a 60 px range floor;
  rockets ramp linearly over 0.5 s (`Engine/World.swift:~2542–2546`).
- **Class.** FIX. **Impact** low-medium. **Confidence** high.
- **Test.** A Speed-0 weapon lives Count ticks, not 60 s.

#### WP-20 · Burst preload, reload floor, exclusive banks, burst ammo — **DONE**
- **Done.** `WeaponMount.init` preloads BurstReload; no reload floor (Reload 0 fires per raw
  call); exclusive banks hold the others to `cooldown + 2` ticks. The re-run on a cloaked ship being
  attacked waits for AI-27.
- **Original.** `Weapon_InitShipWeaponBursts` 0x00413810 starts banks with BurstCount at
  `cooldown = BurstReload`; this re-runs when a cloaked ship is attacked. Reload has no floor.
  Exclusive (Flags3 0x20) raises the other banks to `cooldown + 2` ticks. The Flags3 0x0001 cost
  is paid every BurstCount volleys.
- **NovaSwift.** `Engine/Combat.swift:558` cooldown starts at 0; `:437` floors reload at one
  frame; `Engine/World.swift:~1926` exclusive has no +2; `Engine/Combat.swift:602` ammo per
  `burstCount × count`.
- **Class.** FIX. **Impact** low. **Confidence** high.
- **Test.** A burst weapon cannot fire until BurstReload after spawn.

#### WP-21 · Inaccuracy — **DONE**
- **Done.** Whole-degree `rand(2s) − s` (bombs: sprite only); negative = parallel launch by the
  exit point's side.
- **Original.** Integer spread `rand(2s) − s`, applied before velocity except for mode 5 (after
  velocity, sprite only). Beams redraw every tick except mode 10. Negative Inaccuracy is
  "parallel launch": hull heading ± |s| **degrees** by muzzle side (class exit table +0xa42), no
  random spread. **Settled (OQ B4):** there is no radians/degrees mix; ship heading is stored in
  degrees, and the quirk is the decomp's own port bug. Do not copy it.
- **NovaSwift.** Continuous spread drawn once (`Engine/World.swift:~2046–2048`); negative = no
  spread.
- **Class.** FIX. **Impact** low. **Confidence** high.
- **Test.** Spreads are whole degrees.

#### WP-22 · Stellar defense batteries — **DONE**
- **Done.** `StellarWeapons.swift`: centre muzzle, one-step lead, hits only its target
  (`batteryTargetID`), disabled hulls skipped only by disable-only or massless weapons, stellars
  destroyed below zero.
- **Original.** `Stellar_TickStellarDefenseBatteries` 0x0042d890 targets the nearest hostile in
  range that is not cloaked past the threshold. It skips disabled hulls only for disable-only or
  zero-mass weapons. The shot is ownerless, from the stellar centre, with zero velocity, and hits
  only the target or its defense ships. Lead is one-step `t = dist/speed`
  (`Shot_AimStellarBatteryShot` 0x0043ba30). A planet-type shot against a stellar uses the pixel
  mask and destroys at strength < 0.
- **NovaSwift.** `Engine/StellarWeapons.swift:~54–140, 178–181`: always skips disabled, muzzle at
  0.7 × radius (:94), quadratic lead (:85), hits any `canHit`, `≤ 0`.
- **Class.** FIX. **Impact** low-medium. **Confidence** medium-high.
- **Test.** A disabled hostile is still shot by a mass-damage battery.

#### WP-23 · Turret blind spots and aim lead — **DONE**
- **Done.** `World.turretBlind` (46°/136°, weapon or hull bits), `World.leadAngle(spec:)`.
- **Original.** `Weapon_IsTargetBearingInTurretBlindSpot` 0x0046b360: front < 46°, sides < 136°,
  rear otherwise, forced on by shïp capability bits 0x1000/0x2000/0x4000. Lead is single-step
  with relative velocity (`Ship_AimWeaponPredictive` 0x0043b740).
- **NovaSwift.** `Engine/Combat.swift:151` `turretCanBear` uses weapon flags only, with 45/135°;
  `Engine/World.swift:2125` `leadAngle` is quadratic.
- **Class.** FIX. **Impact** low. **Confidence** high.
- **Test.** A hull with bit 0x2000 cannot fire turrets to the side.

#### WP-24 · Hit particles — **DONE**
- **Done.** Hit events carry the impact point; the scene sprays `HitPartCount` 1-px particles at
  the authored speed and life (the ± 20/25 % jitter is averaged).
- **Original.** `Weapon_SpawnWeaponImpactParticleBurst` 0x004274d0: `count` one-pixel particles at
  the **shot** position, speed HitPartVel × 0.01 px per call ± 20 % (beams ± 25 %), life
  `[HitPartLife, round(HitPartLife × 1.25)]` calls.
- **NovaSwift.** `App/Game/GameScene.swift:4400` `spawnHitSpray`: capped at 24, 3 px, at the ship
  centre.
- **Class.** FIX (presentation tied to data). **Impact** low. **Confidence** high.
- **Test.** The particle origin equals the impact point.

#### WP-25 · Smaller weapon items — **DONE**
- **Done.** Decay per Decay interval counted per raw call; splash undecayed; deadly stellars kill
  hulks too and instantly; beam centre-in-cone scan ignoring government (`World.beamCast`); exact
  beam length; per-ship, per-exit-type quadrant cursor from a random start.
- Decay drops one point when elapsed ticks exceed Decay, and splash ignores decay (exe-verified);
  NovaSwift decays continuously and also decays the splash (`Engine/World.swift:~2558–2561`).
- A deadly stellar kills instantly, without the death sequence, disabled ships included;
  NovaSwift skips disabled ships (`Engine/World.swift:~1828`).
- The beam scan ignores government and uses a centre-in-cone test (the "beam holes" bug);
  NovaSwift uses perpendicular distance with the `canHit` gate (`:~2363–2371`).
- Beam length is exact; NovaSwift floors it at 60 px (`Engine/Combat.swift:445`).
- Exit points rotate per ship and per ExitType group from a random quadrant (+1 mod 4,
  `Weapon_SelectTurretQuadrant` 0x0046c320); NovaSwift keeps a per-mount cursor starting at 0.
- **Class.** FIX. **Impact** low. **Confidence** high.

#### WP-26 · Turret tracking roll (modes 4 and 9) — settles Q-WP-02 — **DONE**
- **Done.** `Projectile.turretRoll`, `Ship.turretRating` (from `ShipRes.escortClass`).
- **Original (OQ B2).** At spawn (0x0041fd30), a shot from a ship slot whose raw Guidance is 4
  or 9 stores `roll = Rand(shooterRating) + 1` (`Rand(100) + 1` when the rating is < 1); every
  other weapon stores −1. At hit (`Weapon_CanWeaponHitTarget` 0x00426ef0, used by sprite contact,
  proximity detonation and nearest-target search), the shot **passes through** when
  `targetRating < roll` and the target is not disabled. Rating comes from the class category:
  shïp EscortType 0..3 if set, else inferred (InherentAI < 3 → freighter; mass < 50 fighter,
  < 200 medium, else warship); fighter 80, medium 90, warship and freighter 100. Warship →
  fighter misses 20 %, warship → medium 10 %, medium → fighter 11.1 %, nothing misses a warship
  or freighter.
- **NovaSwift.** No equivalent.
- **Class.** FIX. **Impact** low-medium. **Confidence** high.
- **Test.** Over 10⁴ turret shots from a warship at a fighter, 20 % pass through; at a disabled
  fighter, none.

#### WP-27 · Secondary-weapon selection — from the coverage map — **DONE**
- **Done.** `Ship.secondaryWeaponIDs` (Flags 0x0002, guidance < 9 or 99, bank order),
  `Ship.clearSecondary()`; the "S" key is UI-15.
- **Original.** A player-tick fragment of 0x0044aa70 cycles the secondary selection over the
  bank list, accepting banks whose wëap Flags has 0x0002 (secondary) and whose guidance is < 9 or
  == 99, with a latch at 0x007cab42; per-bank cooldowns decay at ship +0xf8. "S" clears the
  selection (UI-15).
- **NovaSwift.** Secondary cycling by outfit list order; no clear-secondary command.
- **Class.** FIX. **Impact** low. **Confidence** medium (fragment only partly read).
- **Test.** A mode-9 PD weapon and a mode-10 beam never appear in the secondary cycle; a mode-99
  bay does.

#### OS-02 · Escape pods, eject and respawn — merges outfits_special O2 and ui_rules B3 — **DONE**
- **Done.** Engine `EscapePod.swift` (eject rules, wreck, pod flight, bay-fighter eject),
  `EscapePodRespawn` in NovaSwiftStory, host wiring in `GameContainerView.respawnFromEscapePod`;
  Alt+X is the `eject` action. The old rescue is `forgivingEscapePod`. **From the exe:** a pod
  releases the player's escorts (the host drops the escort roster); the old class's OnRetire runs
  at the eject; the pilot respawns in flight at (50, 50). Not reproduced: the respawn's armor bug
  is clamped to max armor by the host's ship build; dësc 13999 shows in the story dialog.
- **Original.**
  - **Eject** needs an owned ModType-11 outfit, or an ejectable bay (mode-99 bay whose carried
    class has shïp Flags 0x8000). Manual eject (Alt+X) works while disabled or destroyed.
    Destroyed: automatic only with a ModType-20 auto-eject outfit, once the death timer is
    ≤ DeathDelay × 0.5 or ≤ 30 ticks. The old hull stays as a derelict wreck and hostiles
    retarget it. The player flies the pod (shïp 895, class index 0x2ff, base shield/armor) for 350
    ticks, or the bay fighter at rand(50..79) % of base shield, armor and fuel (0x00451024).
  - **Respawn** (`PlayerTick_TimedActionTransition` 0x0044d490 / 0x0044d570,
    `Ship_ResetPlayerShipState` 0x004b3350): abort **every** active mission; reset to class 0
    (shïp 128, ignoring chär; Q-UI-02) with its stock weapons and DefaultItems and run its
    OnPurchase; keep persistent outfits (Flags 0x0004), clear the rest with cargo and junk; move
    to `Stellar_FindValidRespawnStellar` 0x00467710 (DFS over visible, discovered neighbour
    systems for an available, travel-usable shipyard stellar passing MinStatus; never the death
    system; else system 0); run `rand(30) + 15` daily ticks; rename the ship "<class name> dddd"
    (digits 1–9); **reset every system's reputation to its government's InitialRec**
    (0x004b4220); refill armor with the max-*shield* value (original bug, 0x0044d83f); stay in
    flight and show dësc 13999; save only under Strict Play (FL-03).
  - shïp PodCount (+0x4c) is cosmetic: the number of pod/debris puffs during an NPC's death.
    përs with Flags 0x0002 emit a pod unless the government has Flags 0x0100 (AI-20).
- **NovaSwift.** `hasEscapePod = podCount > 0 || ModType 11` (`Engine/ShipLoadout.swift:353`);
  every pod death auto-rescues (`Engine/World.swift:506–515`, "deliberately not implemented");
  no manual or disabled eject, no wreck, no pod flight; rescue at the nearest inhabited spöb in the
  death system (`App/Game/GameContainerView.swift:519`) in the chär start hull with **all**
  outfits cleared (:531–552); no days, missions and record kept, always saves and returns to the
  main menu (:331–342).
- **Class.** FIX+ENH → `forgivingEscapePod`. Needs WP-03 (player disable). **Impact** high.
  **Confidence** high.
- **Test.** Destroyed with a ModType-11 pod but no auto-eject and no key press: the pilot dies.
  Ejecting: 15–44 days pass, the pilot is in shïp 128 in a neighbouring system with no active
  missions and reputations at InitialRec.

#### OS-03 · Carried fighters — **DONE**
- **Done.** × 1.333 (AI-41's behavior-5 arm, `Ship.applyCarriedFighterScale`); launch needs a
  target (the player's too), from the carrier's centre at the bay's Speed/100, cooldown `Reload /
  mounted`; a carrier that stands down recalls its fighters; docking within 75 px per axis, an
  empty bay re-arms to Reload. The port's low-ammo/low-health recall is gone. Q-OS-04 stays open.
- **Original.** Bay contents are the bank's loaded-ammo count (persisted, UI-02). A launched
  fighter is behavior 5 (×1.333 max shield/armor and shield regen, AI-41). Launch
  (`Ship_LaunchShipFromCarrierBay` 0x0040d9a0) needs an in-system target; cooldown is
  `Reload / mounted` (mounted, not loaded: a quirk); the fighter starts at the carrier centre,
  heading ± Inaccuracy, velocity `Speed/100` clamped to its max. Fighters return (state 5) when
  the carrier stands down (0x00410d10), on escort command 3, or when the carrier jumps. Docking
  (`Ship_RecoverCarriedShipToBay` 0x00415ea0) happens within 75 px per axis: ammo + 1, and an
  empty bay's cooldown re-arms to Reload. On a player jump, deployed fighters whose class fuel is
  < 100 are lost ("N fighter(s) abandoned", UI-11) and not refilled. Bay capacity is
  `MaxAmmo × mounted` (0x004694a0).
- **NovaSwift.** Bays rebuilt full on every takeoff (`Engine/ShipLoadout.swift:503–507`,
  `Engine/World.swift:451`, `App/Game/GameContainerView.swift:469`); no ×1.333; NPC carriers
  launch on `carrierInCombat` with Reload/30 s per bay at `radius + 20` ahead, inheriting carrier
  velocity (`Engine/World.swift:3260–3370`); return only on low ammo, HP < 30 % or recall
  (:3312–3320); docking at `2 × radius + 30`; deployed fighters dropped on jump then refilled free
  (`App/Game/GameScene.swift:3494`).
- **Class.** FIX+ENH → `freeMunitionsRefill`. **Impact** high-medium. **Confidence** high.
- **Test.** A carrier with 4 fighters that loses 2 lands with 2 in the bay.

#### OS-04 · Cloaking engine — **DONE**
- **Done.** `World.stepCloak`, `Ship.isCloaked` (24/8/16 thresholds), `World.canDetect` (scanner
  0x0002 within 200 px, own escorts). Upkeep sums every owned device rather than the first; the
  Flags2 0x4000 re-cloak waits for AI-27.
- **Original.**
  - Fade progress 0..32 at 0.75 per tick (≈ 1.42 s), or 1.5 when the **hull** has Flags2 0x0001;
    the device's ModVal 0x0001 is never read (quirk; 0x00428340).
  - "Cloaked" (no fire, no targeting, off radar) once progress > 24 while entering, until < 8
    while clearing, > 16 otherwise (`Ship_IsShipCloakVisibilityThresholdActive` 0x0046c7a0).
  - Upkeep: drain = nibble × 1/30 per tick, first matching device only (0x00464db0 / 0x00465090);
    the player's shields are re-zeroed **every tick** with flag 0x0004 (NPCs only on activation);
    shield drain applies only while shields ≥ the rate, leaving the last 1–8 points (quirk).
  - `Ship_CanMaintainCloakState` 0x00467e80: disabled drops the cloak; the cloak always needs
    fuel > 0 even for no-fuel devices, and the shield gate never fires (it reads the ModType word,
    not ModVal): both quirks. The player cannot hold a cloak during spin-up unless Flags2 0x0400.
  - Damage decloaks only when the fade is complete or entering. Attacked NPCs with Flags2 0x4000
    re-cloak and reset bursts (WP-20, AI-27).
  - Cloaked ships are engageable within 200 px per axis by ships with scanner bit 0x0002, and by
    the cloaker's own escorts (0x00464a90). Landing while cloaked is refused (FL-12).
- **NovaSwift.** Linear 1.2 s fade (×2 on device 0x0001), cloaked at level ≥ 0.99; shields zeroed
  once at level 0; fuel and shields run to 0 before the cloak drops; no disabled or hyperspace
  gate; detection needs scanner 0x0008 only (`Engine/World.swift:468, 3193, 3205–3220, 3236`).
- **Class.** FIX. **Impact** medium-high. **Confidence** high.
- **Test.** A cloak device with no fuel drain still drops at 0 fuel; a cloaked player's shields
  read 0 every tick with flag 0x0004.

#### OS-07 · Repair system (ModType 49) — **DONE**
- **Done.** `World.tickRepairSystem`. **Correction:** the overlay is STR# 2002 #37 (0x25); #287 is
  the disabled overlay and #288 "ship destroyed". The 300-tick window is the player's; NPCs roll
  at once.
- **Original.** `Frame_ShouldTriggerAutoRepairTick` 0x0046e540: player and NPC (via
  DefaultItems), while disabled and after the 300-tick post-disable window, roll 1/500 per 30 Hz
  tick (≈ 16.7 s mean); success sets armor to `maxArmor/3 + 1` (`/10 + 1` with hull Flags 0x10),
  just above the disable line. The player gets the "repair systems engaged" overlay and sound
  (STR# 2002 #287/#288). Surrender conversion piggybacks on the same roll.
- **NovaSwift.** NPC only, 5 %/s, +20 % armor (`Engine/World.swift:1701–1707`); the player never
  self-repairs, and NPCs never own the outfit (OS-01).
- **Class.** FIX (needs WP-02/WP-03, OS-01). **Impact** medium. **Confidence** high.
- **Test.** A disabled player with a repair system recovers to `max/3 + 1` armor on average
  ~16.7 s after the 10 s window.

#### OS-12 · Untargetable ships — **DONE**
- **Done.** `World.canTarget` (target cycle, nearest, click-select, AI acquisition).
- **Original.** shïp Flags2 0x0004 ships cannot be targeted, cycled or auto-picked unless the
  player has scanner bit 0x0004 (0x0046c930; decomp `targeting.cpp`, `ship_ai_weapons.cpp`).
  NPC AI applies the same rule.
- **NovaSwift.** Absent.
- **Class.** FIX. **Impact** medium-low. **Confidence** high.
- **Test.** A Flags2-0x0004 ship is skipped by the target cycle until a 0x0004 scanner is fitted.

### Batch 3 — legal model, NPC fire control, hostility, spawning

#### EC-02 · Legal record is per system, with relation-laddered flood propagation — moved from Batch 4 — **DONE**
- **Done.** `Kit/SystemReputation.swift` (rules), `Story/LegalRecord.swift` (pilot binding).
  `PlayerState.systemReputation` (system id → value, ±32000) replaces the per-government record;
  `Diplomacy` seeds it per system session and drains `consumeReputationDelta()`. The flood is
  pinned by the oracle run of 0x00466fc0 → 0x00467140 (`emulator_results.md` §2, which settles
  Q-EC-13 and supersedes the relation sign rule below): the victim's own and allied systems take
  the full penalty, every other government's systems a *bonus* of half their own penalty,
  independent systems ¼ of the victim's (or −½ for a xenophobic victim), an independent victim
  the first government's penalty table; ×0.65 per depth-first level, truncated toward zero,
  stopping where the change is below 1; a zero-change system blocks; same-position twins change
  together. `GovtRelations` ports the original allied / hostile-or-xenophobic / share-class
  helpers (derelict and independent quirks). Mission ships, derelict victims and boarding përs
  1150/1151 change nothing. Also ported: mission success (galaxy-wide, ±½ to hostile/allied,
  16-bit wrap), failure (−½ in CompGovt's systems), abort (−5×) — MS-10 still owns *which* paths
  call them; clean record (ModType 21, PayVal −1xxxx/−2xxxx/−3xxxx) lifts only negative values;
  new pilots start at each owner's InitialRec (floored at 0) and the `chär` statuses overwrite
  allied / hostile systems (0x004b4220, 0x004cd4b0). Consumers moved to the current system's
  reputation: AI ladder (AI-05), stellar batteries (0x004629e0's player arm), contraband gate,
  përs "likes you", AvailRecord (comparison form left to MS-17), landing denial / planet hail
  (thresholds left to EC-04 / UI-09), and the UI labels (left to UI-14).
- **Removed by the ruling.** The per-government model (and the wiki 3/5-system radius) is not kept
  as an Enhancement: every consumer would need a second code path. Old saves still decode.
- **Settled (user decision, "migration default").** On first load a pilot saved under the old
  model is migrated once: each system takes the standing its owning government held there (the
  old universal record plus that system's combat component), independent systems start at 0,
  clamped to ±32000; the old fields stay in the save, unread, and the migration is logged.
  The user can override this default (Q-EC-10).
- **Original.** One signed int16 `system_reputation[system]` (±32000), with no per-government
  record. `Government_ProcessFactionCombatEvent` 0x00466fc0 feeds
  `Government_PropagateFactionCombatInfluenceToNearbySystems` 0x00467140. For each system the
  delta comes from the event government's penalty table (`GovtDef + 0x48 + event × 2`), laddered
  by the event faction's relation to *that system's* government:
  - same → full;
  - system independent → × 0.25 (−× 0.5 if the faction is xenophobic);
  - faction independent → the system government's penalty × 0.5, signed by its flags;
  - not allied → −penalty(sysgov) × 0.5;
  - allied → full.

  Then `rep = trunc(rep − delta)`, clamped to ±32000, applied to every system in the alias chain
  (system +0xba/+0xb8). It recurses into all 16 links at × 0.65, visiting each system once, until
  |delta| < 1. There is no fixed radius. Crimes also revoke non-permanent allied ranks (EC-10).
  Mission CompReward, by contrast, is galaxy-wide with no decay (MS-10).
- **Still open (OQ D4).** Ghidra's call names in the relation block look swapped, so which
  relation receives the + and which the − half-penalty is medium confidence. Pin it with the
  oracle on a 3-government fixture before porting (Q-EC-13).
- **NovaSwift.** `Kit/NovaAIModels.swift:~502–548` `LegalRecordPropagation`: a per-government
  record, 5-hop/3-hop linear taper, plus a "universal" `PlayerState.legalRecord`. This is the
  spatial model from the 2026-07-14 audit.
- **Class.** FIX. It replaces the legal model. Migration of existing pilots needs a decision
  (Q-EC-10). **Impact** high (every standing change). **Confidence** high.
- **Test.** A kill in system A changes A by the full penalty, a neighbour by × 0.65 and its
  neighbour by × 0.4225, stopping below 1.

#### AI-02 · NPCs fire one AI-selected bank — dedupes weapons #6 and AI A2 — **DONE**
- **Done.** `Engine/NPCWeaponSelection.swift`: an NPC fires only its armed forward bank (the
  first homing bank that can track the target with `dist² × 0.95 ≤ range²`, else the in-range
  unguided / beam / rocket bank with the most energy damage while the target's shields are ≥ 0,
  else the most mass damage, rockets outside 2.5 × blast radius, one relaxed retry with homing
  banks) and its best turret / quadrant bank. Range is the whole-pixel distance within
  `BeamLength + 32` / `range + 32`. Under the original AI (Batch 6) the control modes ask for a
  kind of bank and only the selectors for that kind run (`ControlIntent.npcMounts`, with the
  unguided 0x0040d7e0 and general 0x0040d910 selectors added); under `novaSwiftAI` the selectors
  still run every trigger.
- **Batch 2 note.** Not taken in Batch 2: AI-03 doesn't need it; the bank selectors belong with the Batch 3 fire
  control. Batch 2 did port the per-bank firing envelope (`World.npcFireEnvelope`), and NPCs no
  longer get the port's `range × 1.05` gate.
- **Original.** `Weapon_FireShipWeapons` 0x00414550 serves only `active_weapon_bank_slot`, chosen
  by the selectors:
  - direct fire (0x0040d470): the in-range bank with the highest EnergyDmg, else the highest
    MassDmg;
  - guided (0x0040d220): the first mode-1 bank that can track with `dist² × 0.95 ≤ range²`;
  - unguided and general fallbacks (0x0040d7e0 / 0x0040d910);
  - turrets fire through `Weapon_FireTurretAtTarget` 0x0040ce00.

  The firing envelope is `range + 32` per axis.
- **NovaSwift.** `Engine/World.swift:1914` `fireWeapons`: AI ships fire every mount on
  `anyTrigger` (:1917–1941); range gate `≤ range × 1.05` (:1962).
- **Class.** FIX. **Impact** high (NPC burst damage multiplied by the number of weapon types).
  **Confidence** high.
- **Test.** An NPC carrying guns and missiles fires one bank per trigger.

#### AI-03 · Rating-based NPC fire slowdown — dedupes weapons #5 and AI A3 — **DONE**
- **Done (with Batch 2, beside WP-04).** `World.ratingFireRamp` against class 0's Strength,
  stretching the per-shot reload (not BurstReload) of an NPC whose target is the player;
  `World.livePlayerCombatRating` adds kills not yet folded.
- **Original.** 0x00414550 (exe-verified): when the target is the player, the cooldown is × 1.75 /
  1.5 / 1.25 / 1.1 while rating < 200 / 800 / 1600 / 3200 (class-0 Strength 2 × 100/400/800/1600).
  This is the original's new-pilot difficulty ramp.
- **NovaSwift.** None (`Engine/Combat.swift:586` `perShotReload`).
- **Class.** FIX. Ship it with WP-04. **Impact** high. **Confidence** high.
- **Test.** At rating 0, an NPC's interval against the player is 1.75 × Reload, and against
  another NPC it is 1.0 ×.

#### AI-04 · Armed warships finish off disabled targets — **DONE**
- **Done.** `AIBrain.hasLethalWeapon` (0x00415c10): a target that becomes disabled stays a
  target, and is acquired, for a ship whose primaries include a mass-damage, non-disable-only
  weapon with ammo; others drop it.
- **Original.** 0x00402e50 / 0x00403de0 (exe-verified): the target is dropped only if it is
  inactive, destroyed, or disabled **and** the attacker has no lethal weapon
  (`Weapon_HasAnyFireableNonSecondaryWeapon` 0x00415c10: MassDmg > 0 and not wëap Flags2 0x1000).
  Acquisition admits disabled candidates when armed (0x0040eea0).
- **NovaSwift.** `Engine/AIBrain.swift:256` `isHostile` rejects disabled ships;
  `Engine/World.swift:~2873–2878` clears everyone's target on disable.
- **Class.** FIX (needs WP-02). **Impact** high. **Confidence** high.
- **Test.** A warship destroys a disabled enemy; a disable-only ship gives up.

#### AI-05 · Player-hostility ladder — dedupes AI A7 and economy D14 — **DONE**
- **Done.** `Diplomacy.reputationFlagsPlayer` / `xenophobeTargetsPlayer` / `inherentGovtGrudge`
  and `AIBrain.flagsPlayer`: the ladder on the current system's reputation, `Flags` 0x0040
  blocking, 0x0004 attacking on sight, xenophobes system-wide (peaceful at home with rep ≥ 1),
  the `cadence × 600` px per-axis box (`AIBrain.cadence`: dudes `Rand(3) XOR 2`, class escorts 2,
  përs clamped Aggress), the 1-in-50 roll each think without a target (not for the player's wing
  or mission ships), rank privilege and the scrambler latch clearing it. The box still sits
  inside the port's 1500 px sensor scan (AI-21).
- **Original.** `Ship_AcquirePrimaryTargetForShip` 0x0040e020, using the player's **current
  system** reputation `rep` and the ship government's CrimeTol:
  - same as the system government: `rep + CrimeTol < 0` (strict);
  - unowned system: only nosy (Flags 0x0002) and `rep + 2·CrimeTol < 0`;
  - hostile to the system owner: `CrimeTol < rep` (known bug #132: a good record makes the
    owner's enemies attack);
  - neutral: nosy only, with 2 × CrimeTol;
  - allied: `rep < −1.5·CrimeTol`.

  Further rules:
  - Flags 0x0040 blocks all of the above.
  - A 1-in-50 roll flags the player if the player hull's inherent government is hostile.
  - Xenophobes (0x0001) flag the player unless they are in their own system with rep ≥ 1.
  - Rank no-auto-attack and the IFF scrambler clear the flag.
  - Acquisition box is `cadence × 600` px per axis (AI-21).
  - Every candidate passes the MaxOdds filter (AI-08).
- **NovaSwift.** `Engine/Diplomacy.swift:172` `isHostileToPlayer`: per-government
  `−record ≥ CrimeTol` (:153), xenophobes always hostile (:183), fixed 1500 px euclidean scan.
- **Class.** FIX (needs EC-02). **Impact** high. **Confidence** high.
- **Test.** A ladder table test, including a positive local record making an enemy-of-owner
  ship hostile.

#### AI-06 · Provocation propagation; piracy police — **DONE**
- **Done.** `World.propagateHostilityFromPlayerAttack` (0x004102e0): the player's own hit on
  the ship it targets turns every idle warship / interceptor of the victim's or an allied
  government, or a nosy one, on the player (relation, rank, xenophobe, independent, Flags
  0x0800 / 0x0020 rules as the original); the old same-government sweep (traders included) is
  gone. Toggle: `piracyPolice` keeps the authority patrols.
- **Original.** When the player's shot hits its intended target (collision.cpp `suppress_retarget`
  path), `Government_PropagateHostilityFromAttack` sets every active behavior-3/4 ship not already
  in state 4 to attack the player. There is no distance gate; the whole 64-slot pool is scanned.
  - Eligible responders are same-government or allied with the victim, or of a Flags-0x0002
    government, subject to the relation and rank exclusions.
  - Victim Flags 0x0020 or 0x0800 suppresses propagation.
  - A xenophobic victim gets same-government responders only.
  - The victim adds the damage to its own and its squad leader's hostility.

  NPC-vs-NPC intervention happens only through the ally-support scan in acquisition (0x0040e3c0):
  allied, with `targetStrength ≤ ownStrength × MaxOdds`.
- **NovaSwift.** `Engine/World.swift:~2829–2861` provokes same-government ships only (traders
  included). `Engine/AIBrain.swift:367` `pickPirateInterventionTarget` (wired at :~627–639) lets
  system-authority ships attack aggressors and the wronging player.
- **Class.** FIX+ENH → `piracyPolice`. **Impact** medium-high. **Confidence** high.
- **Test.** Shooting a Federation ship turns allied warships hostile; same-government traders do
  not join.

#### AI-07 · Grudge latch — **DONE**
- **Done.** Any player hit on a përs with Flags 0x0001 sets the grudge; only such a përs honours
  it (`Ship.personFlags`).
- **Original.** Any player hit on a përs with Flags 0x0001 sets its grudge; acquisition forces
  hostility only when `(flags & 1) && grudge`.
- **NovaSwift.** `Engine/World.swift:2894` sets a grudge only on disable, for any përs;
  `Engine/AIBrain.swift:~276` honours it without the flag check.
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** A merely-shot Flags-0x0001 përs holds a grudge; a non-flagged përs never does.

#### AI-08 · MaxOdds and perceived strength — **DONE**
- **Done.** `AIBrain.perceivedStrength` (0.25…1 shield clamp, escorts / allies, ×2 when under
  attack, the stale-fraction quirk for shieldless supporters), `acceptsTarget` (MaxOdds × 0.01,
  floor 0.01, so 0 means almost never) and `oddsScore` (player Strength × clamp(rating ÷
  (class-0 Strength × 6400), 1, 2) by integer division). The port's whole-system sum survives only
  for the `piracyPolice` patrols.
- **Original.** `Ship_ComputePerceivedCombatStrength` 0x00411800 computes `Strength ×
  clamp(shield/max, 0.25, 1)`, plus each allied/squad supporter's term, doubled if that supporter
  is threatened. A candidate is rejected when `candidate > own × MaxOdds`.
  `Ship_UpdateShipCombatOddsScore` 0x004133f0 counts the player's Strength ×
  `clamp(rating / (2 × 0x1900), 1, 2)`.
- **NovaSwift.** `Engine/AIBrain.swift:507` `favorableOdds` sums all sides with `0.3 + 0.7f`
  (:513); `≤ 0` means unlimited.
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** MaxOdds 0 never engages; a supporter under fire doubles its weight.

#### AI-09 · Ambient population — **DONE**
- **Done.** `Engine/OriginalSpawning.swift`: `Spawner.model` defaults to `.original`, which runs
  `maintainOriginal` once per raw call (`World.rawCallsThisStep`). It counts every NPC not attached
  to the player (fleets and hulks included) against exactly `AvgShips`, caps the pool at 55 NPC
  slots (64 less the player and the 8-slot reserve), normalizes DudeTypes weights to 100 by
  truncation, drops unavailable hulls before the hull roll, and discards fuel-less maintenance
  spawns. The initial fill makes exactly `AvgShips` attempts (no fuel check). The port's traffic is
  `Spawner.model = .port`, which the System Aliveness presets Quiet (was "Authentic") / Normal /
  Bustling select; Settings ▸ System Aliveness gained **Original**, the new default.
- **Correction (disasm-verified, 0x0041e120).** The dude attempt runs only when `Rand(500)` is 0,
  or is 1 and the pinned-fleet roll fails; any other draw does nothing. So the system makes an
  attempt every ~250 raw calls (about 5 s) and, with the përs and sweep shares, lands a dude ship
  every ~340 (about 7 s) — not "within ticks". The decomp's "dude every tick" fallback is its own
  bug.
- **User decision.** A pilot whose settings blob already stores `systemAliveness = authentic`
  (the Batch 0 default) keeps that preset; only fresh settings start on Original. Migrating it to
  Original is a one-line change if wanted.
- **Original.** `System_TickNpcSpawnMaintenance` 0x0041d6e0 runs each raw call. It counts every
  active ship not attached to the player (fleets and hulks included). While the count is below
  `AvgShips`, it tries the pinned-fleet roll (AI-10), otherwise
  `Dude_SpawnRandomDudeShipInSystem` 0x0041c710. The initial fill makes exactly `AvgShips`
  attempts. The cap is 64 slots minus an 8-slot reserve. Dude spawns with fuel capacity < 1 are
  discarded. Unavailable hulls are excluded from the weights before rolling, and positive weights
  are rescaled to 100.
- **NovaSwift.** `Engine/Spawner.swift:149` (floor 3), `:61` (cap 18), `:85` (6 s), `:223`
  (invented cuts), `:293` (fleets and disabled excluded from the count).
- **Class.** FIX+ENH → `systemAliveness` gains `.original` as the default. **Impact** high.
  **Confidence** high.
- **Test.** An AvgShips-8 system holds 8 non-player ships; a kill is replaced within ticks.

#### AI-10 · Fleet selection and rate — **DONE**
- **Done.** Pinned negative DudeTypes fleets spawn only on `Rand(500) == 1 && Rand(100) + 1 ≤ Σ%Prob`
  (weighted 0x0046b6d0 pick among available ones); the LinkSyst sweep runs on 6/49 of dude
  attempts and spawns `Rand(256)` only when that def is eligible and available. No guaranteed
  fleet, no owned-system filter, no concurrency cap. `OriginalSpawnRules.linkSystMatches` keeps the
  bands 10000–14999 / 15000–19999 / 20000–24999 / 25000–29999 and two quirks: a value equal to the
  system's 0-based index also matches, and (përs only) 9999 matches independent systems. The
  Quote (first `#` 1–9, following `#` 0–9) flashes for 360 frames as `WorldEvent.overlayMessage`
  for maintenance-spawned fleets.
- **Original.** Three separate paths:
  - Pinned negative DudeTypes fleets spawn only via `rand(500) == 1 && rand(100) < Σ%Prob` per
    maintenance tick (0x0046b6d0).
  - A LinkSyst sweep (0x00425280) runs on 6/49 of dude attempts and spawns def
    `rand(0x100)` if it is eligible and available (bands: −1; 128–9999 system; 10000+ government;
    15000+ allied; 20000+ not-that-government; 25000+ hostile).
  - Reinforcements (AI-13).

  No guaranteed initial fleet; no owned-system filter.
- **NovaSwift.** `Engine/Spawner.swift:186` (guaranteed fleet), `:93` / `:247` (26 s ± 40 %),
  `:368` (owned-system filter), with weight 1 for swept fleets.
- **Class.** FIX (the old behaviour lives on in `systemAliveness` presets). **Impact** high.
  **Confidence** high.
- **Test.** Over 10⁵ simulated attempts, the fleet rate equals `(6/49)·(E/256)`.

#### AI-11 · përs spawning and Person1–8 — **DONE**
- **Done.** `Spawner.originalSpawnPers`: 1/7 of ambient and initial-fill attempts; eligible =
  alive and active (`World.persSpawnEligible`), AIType > 0, LinkSyst band, and (maintenance) not a
  derelict government; `slot = Rand(0x3fe)` must hit an eligible one. The ship flies the përs's own
  hull, government (independent when unset) and AIType. Dedup is by name without its `;`
  subtitle (bug #128). Person1–8 roll `Rand(100) + 1 ≤ %Prob` after ActiveOn. No credit jitter:
  `plunderCredits` is the përs Credits as is. WeapType triples naming the same weapon overwrite.
  The old 5 % retag of dude hulls survives only in the `.port` model.
- **Done (AI pass 2).** përs Flags 0x0002 forces the afterburner latch (AI-26's
  `canUseAfterburner`); Flags2 is decoded (payload +0x17e, `PersRes.flags2`; 64 stock përs set
  0x0001) and 0x0001 spawns the ship with no fuel, so it parks instead of jumping out.
- **Original.** `Pers_SpawnShipFromPersDef` 0x004235c0 runs on 1/7 of ambient and initial-fill
  attempts.
  - The eligible set: alive, AIType > 0, ActiveOn, LinkSyst band; maintenance also excludes
    derelict governments.
  - It draws `slot = rand(0x3fe)` and spawns only if that slot is eligible.
  - The ship is standalone, with the përs's own ShipType, Govt and AIType.
  - Dedup is by first character plus name id (known bug #128).
  - Person1–8 each roll `rand(100) + 1 ≤ prob` after ActiveOn, also in empty systems.
  - Only four WeapType triples apply, and a duplicate id overwrites (does not add).
  - përs Flags 0x0002 forces the afterburner; Flags2 0x0001 gives zero fuel.
  - **No ±25 % credits at spawn (OQ C6).** PersDef +0x618 (përs Credits) is read only by
    boarding (EC-18); the spawner writes no credits.
- **NovaSwift.** `Engine/Spawner.swift:702` `assignPersonIfLucky` retags 5 % of matching dude
  hulls and keeps the dude AIType; `:681` `spawnPinnedPersons` always spawns, falling back to the
  system government.
- **Class.** FIX. **Impact** high. **Confidence** high.
- **Test.** A përs whose hull no dude flies can appear; Person %Prob 30 appears about 30 % of the
  time.

#### AI-12 · Arrival geometry, gate emergence, planet launches — **DONE** (mission-ship gate hold open)
- **Done.** Maintenance arrivals jump in at `OriginalSpawnRules.jumpInRadius` from (0, 0), facing it,
  at 50 px/tick, the speed cap decaying at 1.165 px/tick² (`World.addNPC` `.hyperspace`, NPCs only;
  a co-op peer keeps the old inrush). **Correction:** the radius is 2098.004 px, not 2102.64 — the
  exe's brake constant is the double 1.165 (0x00575250); 2102.64 came from using 1.16. Gate
  emergence happens only when the ported `Stellar_SelectRandomAdjacentTravelStellar` pick
  (`OriginalSpawnRules.travelCandidates`, Rand(3) strict flag, gövt Flags2 0x20/0x40/0x80) lands
  on a hypergate or wormhole: at the gate's exact position on its CustSndID heading (else random),
  leaving at 30 px/tick (15 when attached to the player). Fleet escorts start ±150 px from their
  lead. No planet launches. Enhancements: `planetLaunchArrivals` (40 % launches, 65 % of traders
  outbound) and `hypergateTraffic` (the fixed 35 % / 4 % emergence).
- **Done (AI pass 2 audit).** The 60-tick hold inside the gate is modelled
  (`OriginalAI.enterGateEmergence`: state 0x15, maneuver timer 60, then the −30 / −15 slide).
- **Done (fidelity cleanup).** After gate travel the player's roster escorts come out of the
  same gate (`World.addEscortEmergingWithPlayer`, from `GameScene.spawnRosterEscort` when
  `lastArrivalGateID` is set): on the gate's integer position, on the player's heading, entering
  state 0x15 with a `Rand(20) + 15`-tick hold instead of 60, then the −15 px/tick slide
  (0x00457580). `World.escortGateEmergences` carries the hold to the original AI's next step.
- **Not done.** ShipSyst −6 mission ships' `Rand(50) + 100` gate hold; `hypergateTraffic` covers
  emergence only — the AI's 35 % / 4 % gate *departure* (`AIBrain.pickDepartureGate`) is AI-23
  territory.
- **Original.**
  - Ordinary jump-ins start ≈ 2102.64 px from (0,0) (`1000 + Σ(50 − 1.16k)`), facing the origin,
    at 50 px/tick inward. State 8 raises the desired speed from −50 by 1.165 per tick, so ships
    settle near 1000 px.
  - Fleet escorts start at lead ± 150.
  - Gate emergence (0x004159e0 / 0x0046e9e0) happens only when the random adjacent-destination
    pick has availability 0x3000. It holds 60 ticks, takes its heading from the gate's CustSndID
    when 0–359 (else random), then enters state 8 at −30 px/tick (−15 for ships attached to the
    player), with thrust command −3.0. **Settled (OQ D7):** every caller passes a gate or
    wormhole, so the CustSndID heading never applies to an ordinary stellar. The player's own
    escorts arriving with the player take the player's heading and hold `Rand(20) + 15` ticks;
    ShipSyst −6 mission ships hold `Rand(50) + 100`.
  - No planet-launch arrivals exist.
- **NovaSwift.** `Engine/World.swift:1240` (2.4 × max, ≤ 3200), `:1259` (gentle gate push),
  `Engine/Galaxy.swift:417` (0.85 × jumpRadius at the centroid), `Engine/Spawner.swift:807`
  (± 120), `:845` (35 % / 4 %), `:270` (40 % planet launches).
- **Class.** FIX+ENH → `planetLaunchArrivals`, `hypergateTraffic`. **Impact** medium.
  **Confidence** high.
- **Test.** A jump-in's first position is 2102.6 px from the origin; a system with no gate never
  emits gate traffic.

#### AI-13 · Reinforcements and the flët Quote — **DONE**
- **Done.** The invented "targeted while non-hostile" shortcut is now `reinforcementShortcut`
  (always on in the `.port` model). In the original model the warning (STR# 2002 #306 +
  MediumName + #307) shows for 240 frames once under 25 % of the ReinfTime countdown remains, the
  lead arrives as an interceptor with the fleet Quote, and a system calls its reinforcements once
  per visit (the `max(ReinfIntrval, 1)`-day delay can't elapse in flight).
- **Done with Batch 6.** The original AI makes the per-ship call (`Spawner.requestAssistance`
  from the state machine's retreat / attack arms and brave traders): ReinfFleet present, no
  countdown, delay spent, odds > 0, fleet government allied, `MaxOdds × 0.5 < odds`; a latched
  ModType-44 inhibitor on either government spends the system's call for the visit. With the
  original AI flying, the system-level strength comparison no longer triggers (it stays for
  `novaSwiftAI` and the port model; `reinforcementShortcut` still applies).
- **Done (AI pass 2).** The day delay persists: a call (or an inhibitor-spent call) emits
  `.reinforcementsCalled(systemID, max(ReinfIntrval, 1) / 1)`, the app keeps
  `PlayerState.reinforcementRetriggerDays`, the daily tick counts it down
  (`StoryEngine.tickSystemDefenses`), and a system still counting can't call on the next visit
  (`Spawner.holdReinforcements`). The comm dialog's forced call (a rank-0x0400 ally answering
  Request Assistance) is `OriginalComms.Effect.attackAndReinforce` (AI-42).
- **Original.** `Government_TryTriggerGovtAssistanceEncounter` 0x00413610 is called (OQ D11)
  from state 3 every frame while within 251 px per axis of the attacker and not jumping
  (0x004066a5; allied-escort pairs drop to state 0 first), from state 4 right after the
  carrier-bay launch (0x00406bdb), from brave traders entering state 3 (0x00402bd0), and from the
  comm dialog with `(player, 1)`. It returns at once with no government or no system ReinfFleet.
  All of these must hold:
  - the system has a ReinfFleet, the countdown is ≤ 0 and the day delay is 0;
  - odds > 0 and the fleet's government is allied;
  - `MaxOdds × 0.5 < odds`.

  When triggered:
  - The countdown = ReinfTime **ticks**.
  - Below 25 % of the countdown, a banner (STR# 2002 #306 + MediumName + #307) shows for 240
    frames with a sound.
  - The lead spawns as behavior 4 with the Quote.
  - The retrigger delay is `max(ReinfIntrval, 1)` game days; the ModType-44 inhibitor gives
    1 day.
  - The Quote (random STR#, first `#` → 1–9, later `#` → 0–9, 360 frames) shows for swept,
    reinforcement and escalation fleets.
- **NovaSwift.** `Engine/Spawner.swift:526` (system-wide strength sum), `:554` (targeted-shortcut
  trigger), `:126` (60 s per day), `:788` (lead flies InherentAI); no banner, no Quote
  (`FleetRes.hailQuote` unused).
- **Class.** FIX+ENH → `reinforcementShortcut`. **Impact** medium. **Confidence** high.
- **Test.** Reinforcements need one game day between triggers; the warning banner appears at
  75 % elapsed.

#### AI-14 · Mission ship placement (ShipStart, aux ships, rescue wrecks) — **DONE**
- **Done.** `World.spawnMissionShips`: ShipStart 1 jumps in at the original radius with a ±256 px
  scatter; other starts take a new slot's `[-750, 750)²` scatter; ShipGoal 3 sits ±256 px from the
  origin; ShipStart −1..−16 places the ship exactly on that nav stellar (`navStellarIndex`, passed
  by `GameContainerView`); rescue wrecks get armor `max × 0.33 (0.1) − 1` on a random heading.
- **Done (AI pass 2).** ShipStart 1 queues the batch (`World.scheduleMissionArrival`) for
  `Rand(100) + 100` maintenance ticks (30 for a ShipBehav-1 escort goal), counted in raw calls,
  then it jumps in on the bearing toward the system the player came from
  (`World.previousSystemBearing`, kept across takeoffs; Rand(360) before the first jump), one
  bearing per batch, ±256 px per ship, no escort re-centring. ShipStart 2 enters its cloak at
  once. Auxiliary ships wait `Rand(70) + 70` ticks and jump in from a random side; without mïsn
  Flags 0x0010 each arrival spends `ActiveMission.auxShipsRemaining`, so destroyed aux ships
  don't come back; with it they return every visit.
- **Original.** `Mission_SpawnMissionShipFromDudeDef` 0x0041cf40 and 0x0041af90:
  - ShipStart 1 is a delayed jump-in after a 100–199 maintenance-tick rearm (30 for ShipBehav 1 +
    ShipGoal 3), on the previous-system bearing ± 256.
  - ShipStart 2 is cloaked.
  - ShipStart −1..−16 places the ship exactly at **this system's** nav stellar
    `[−1 − ShipStart]` (system +0x2a), with no scatter, after (and overriding) the ShipGoal-3
    scatter; heading and velocity are kept (settled, OQ D6; the decomp's comment is wrong).
  - ShipGoal 3 ships are placed ± 256 px from the origin.
  - Rescue wrecks get armor `base × 0.33 (0.1) − 1` and a random heading.
  - Aux ships jump in after a rearm roll; with flag 0x0010 they respawn without limit.
- **NovaSwift.** `App/Game/GameContainerView.swift:1745` `spawnActiveMissionShips` (ShipStart 1 =
  immediate edge arrival, others an annulus); `Engine/World.swift:1496` (2 % wreck armor); aux
  ships never respawn.
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** ShipStart −2 spawns at the second stellar.

#### AI-15 · Defense fleets and garrison persistence — **DONE**
- **Done.** `World.launchDefenders`: defenders start exactly on the stellar as warships whatever the
  dude says, at full speed on a random heading, hostile to the player; the trickle launches at
  most one per raw call across all stellars.
- **Done (AI pass 2).** The garrison persists: `World.stellarGarrisons` is seeded from
  `PlayerState.stellarGarrisons`, a contest draws its pool from it, `World.garrisonSnapshot()`
  credits survivors back (pool + live defenders; the dead are lost) on every save, jump and
  takeoff; release reseeds it (full DefCount), domination empties it. The daily tick regrows a
  dominated stellar's garrison +1 on `Rand(450) == 0` up to DefCount.
- **Done (fidelity cleanup).** A *disabled* defender keeps its slot: `World.liveDefenders`
  counts every live ship tagged to the stellar, as the maintenance tick counts active slots
  (0x0041d6e0), so a hulk draws no replacement and still blocks the surrender until it is
  destroyed or boarded away. (The port's old free-the-slot convenience was dropped, not kept
  as an Enhancement.)
- **Original.** `Stellar_SpawnDefenseFleetShip` 0x00421fd0 forces behavior 3 and spawns at the
  stellar's exact position, moving at max speed on a random heading, hostile to the player. It
  trickles at most one ship per maintenance tick while live < `DefCount % 10`. The garrison
  persists across visits: survivors are credited back, and dominated stellars regain +1 per day
  at 1/450.
- **NovaSwift.** `Engine/Domination.swift:172` `launchDefenders` uses the dude AIType, ± 60 px, a
  launch arrival, and resets per World. The wave decode itself matches.
- **Class.** FIX. **Impact** medium-low. **Confidence** high.
- **Test.** Leaving with 3 of 10 defenders killed and returning finds 7.

#### AI-16 · Ambush përs and escalation fleets — **DONE**
- **Done.** `Spawner.originalTryAmbush` runs on every world build (arrival and launch): with one
  dominated world 1 in 10, more than one 1 in 5, përs 1150 is force-spawned hostile with its
  HailQuote (STR# 7101). `originalEscalationTick`: `Rand(30) + 30` maintenance calls after
  arrival, the holds of the player's non-mission trader-hull escorts are summed; ≥ 200 brings
  flët 383, 50–199 flët 382, interceptor-led, with their Quotes. The availability-bit 0x20 filter
  on the dominated-world count is not applied (every dominated world counts).
- **Original.**
  - `Mission_TrySpawnMissionShipAmbush` 0x00426dd0 runs on every arrival and launch. If përs
    slot 0x3fe (përs 1150) is alive, it rolls 1/10 (one qualifying dominated planet) or 1/5
    (more than one) and force-spawns the përs hostile with its HailQuote. The slot is first set
    alive at the player's first domination.
  - Escalation: Rand(30) + 30 maintenance ticks after arrival or launch, the cargo holds of the
    player's non-mission behavior-6 escorts with class AI < 3 are summed. ≥ 200 spawns flët 383
    and 50–199 spawns flët 382, as interceptors.
- **NovaSwift.** Missing.
- **Class.** FIX. **Impact** medium-low. **Confidence** high.
- **Note.** Slot 0x3fe is real gameplay, unlike the Enforcer slot 0x3ff (§1): it is never
  bribable and survives destruction 7 times in 8 (UI-17).
- **Test.** After a domination, the revenge përs appears on about 10 % of arrivals.

#### AI-17 · Spawn-time miscellany — **DONE** (cargo loot is EC-18)
- **Done.** Initial fill: `[-750, 750)²` scatter, random heading, moving at top speed; a speed-0
  warship anchors 100 px from the first stellar. Fleet Flags 0x0001: `Rand(holds) + 1` tons in one
  random commodity, hulls with InherentAI < 3 only. Escorts are bound to the lead. A derelict
  përs spawns with no shields and armor `max × 0.33 (0.1) − 1`.
- **AI pass 2 audit.** Escorts that lose their lead and have no sibling fall back to their
  class InherentAI in state 0x13 — the original's own rule (AI-37), not a gap. Dude Booty cargo
  is still filled at spawn; the original rolls it at board time, which belongs to EC-18's
  cargo/fuel loot rolls.
- Fleet flag 0x1 puts `rand(holds) + 1` tons in one random bin, only on classes with AI < 3.
  Plunder cargo comes from düde Booty at board time (known bug #85: fleet random cargo does
  nothing). NovaSwift fills 30–90 % / 30–80 % at spawn (`Engine/Spawner.swift:~649–676`).
- Derelicts: armor `base × 0.33 (0.1) − 1`, zero shields, random heading; NovaSwift uses 2 %
  (`Engine/World.swift:1282`).
- Initial fill: scattered over [−750, 750)² around the origin, random heading, at class base
  speed. Speed-0 behavior-3 hulls anchor 100 px from the first stellar. NovaSwift uses an annulus,
  facing centre, at rest (`Engine/Spawner.swift:896`).
- Fleet escorts are behavior 6 bound to the lead; the lead gets InherentAI (or 4 for reinforcement
  and escalation fleets). NovaSwift escorts fly their own InherentAI (`:~815–816`).
- **Class.** FIX. **Impact** low-medium. **Confidence** high (cargo: medium).

#### OS-10 · IFF scrambler (ModType 48) and reinforcement inhibitor (ModType 44) latches — **DONE**
- **Done.** `GovernmentLatches` (Engine/Diplomacy.swift): owning a scrambler / inhibitor latches
  every government holding its ModVal class (scrambler −1 matches nothing; inhibitor −1 inhibits
  all) for the rest of the app session; selling clears nothing. The scrambler latch clears the AI
  ladder, the inherent roll and stellar batteries; the reinforcement trigger reads the inhibitor
  latch. Not yet: the hail behaviour (UI-09, AI-44).
- **Original.** `Outfit_RecomputeOutfitDerivedState` 0x0046d4b0: owning one sets per-government
  byte latches (+0x82 inhibited, +0x83 scrambled) that are **never cleared** in the session, so
  they stick after selling. Scrambler ModVal −1 matches nothing (class −1 entries are excluded);
  inhibitor ModVal −1 sets a global "inhibit all". The scrambler also suppresses stellar-battery
  hostility and changes hail behaviour (UI-09, AI-44).
- **NovaSwift.** Recomputed live from current outfits; scrambler −1 fools every government
  (`Engine/AIBrain.swift:305–311`); not applied to stellar defenses or hails.
- **Class.** FIX. **Impact** medium-low. **Confidence** high.
- **Test.** Buy and sell a scrambler: the government stays fooled until the session ends.

#### OS-13 · Destroyable stellars — **DONE**
- **Done.** A player shot that destroys a stellar fires ten kill floods against its government
  (`applyStellarHit`); partial damage persists across visits (`PlayerState.stellarStrengthLeft`,
  cleared on destruction or regeneration).
- **Original.** A player shot that destroys a stellar fires 10 faction-combat events against
  its government (EC-02). Live Strength persists across visits until regeneration (DeadTime: 0 =
  next day, −1 = never). OnDestroy runs only on weapon destruction and OnRegen only on the DeadTime
  countdown; NCB `Y`/`U` set state without running them (MS-18).
- **NovaSwift.** No reputation consequence (`App/Game/GameContainerView.swift:2990–2999`); partial
  damage resets with each World (`Engine/StellarWeapons.swift:165–169`).
- **Class.** FIX (needs EC-02). **Impact** low-medium. **Confidence** high.
- **Test.** Half-damaging a stellar, leaving and returning finds it still half-damaged.

#### UI-17 · përs alive/dead rules — ui_rules B7 — **DONE**
- **Done.** Any destruction of a përs ship clears it unless Flags 0x0002; përs 1150 only on
  `Rand(8) == 0` (`World.persDiesWithShip`); a successful capture consumes the përs; the
  Flags 0x0100 mission-accept consumption already existed.
- **Original.** Any destruction of a përs ship clears its alive flag (0x00428340) unless përs Flags
  0x0002 (escape pod) is set; slot 0x3fe dies only 1 time in 8. Capture also consumes the përs
  (0x00423fa0), as does accepting a hail-offered mission from a përs with Flags 0x0100
  (0x00454910).
- **NovaSwift.** `personDefeated` only when `npc.killedByPlayer` (`Engine/World.swift:2930`),
  ignoring Flags 0x0002; capture and mission accept do not consume.
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** A përs without Flags 0x0002 killed by another NPC never reappears; one with the flag
  does.

### Batch 4 — economy, landing, outfits, shipyard, escort commerce, comm dialogs

#### EC-03 · Commodity price formula, öops, junk rows, quantities — **DONE**
- **Done (Batch 4).** `LandedServices.tradeRows`: scale 1.25 / 1.1 / 1.5 through `LandedServices.systemReputation`, which reads the pilot's per-system record (EC-02), öops replace with `base + delta` floored at 5 at the activated stellar (−1 picks one inhabited stellar, stored in `PlayerState.disasterStellars`; other values below 128 inert; no re-roll on the expiry day), highest-index junk per row with BuyOn/SellOn, unfloored; rank PriceMod gone from commodities; plain click 10, cap 32000. Buy-max truncates: the exe's round-and-correct idiom is a truncation, so the audit's "lround overspend" does not happen.
- **Original.** 0x0048c730 (exe-verified; see §1): Low = trunc(base/scale), Medium = base,
  High = trunc(base × scale), with scale 1.25 / 1.1 (governed, rep < 0) / 1.5 (dominated) and a
  floor of 5.
  - An active öops replaces the price with `base + delta` (floor 5). Tier and scale are ignored;
    the last match wins. `Stellar = −1` picks **one** random eligible stellar per activation;
    −2 and other values below 0x80 are inert (`System_UpdateDisasterStates` 0x00424f90).
  - Junk: at most one BoughtAt-here junk (row 6, `trunc(base × scale)`) and one SoldAt-here junk
    (row 7, `trunc(base/scale)`); no floor. In each row the **highest-index** qualifying junk wins
    (OQ C7; the match `break` exits only the inner stellar loop). Each row also requires the
    junk's own availability condition (+0x328 / +0x427).
  - A plain click moves `min(10, …)`; buy-max uses `lround(credits/price)`, which can overspend
    by under one unit (a quirk); cap 32000.
- **NovaSwift.** `Kit/NovaEconomy.swift:67` (tier table), `App/Spaceport/SpaceportScreens.swift:~81–99`
  (floor 1, every junk at flat `BasePrice × rankMult`), `Kit/OopsModels.swift:~109`
  (`tierPrice + Σ deltas`, `appliesToAnyStellar` everywhere), `Story/PilotEconomy.swift:179`
  (floor division).
- **Class.** FIX. **Impact** high. **Confidence** high (exe-verified).
- **Test.** Medical at a Low world with rep < 0 costs trunc(750/1.1) = 681; at a dominated High
  world it costs 1125.

#### EC-04 · Landing access — **DONE**
- **Done (Batch 4).** `LandedServices.landingClearance` in the original order (fee, rep vs MinStatus, dominated/uninhabited/bribed, Require mask, mission travel/return stellar, allied AlwaysLand); STR# 2002 #81–83 refusals. The IFF-scrambler clearance waits for OS-10.
- **Original.** `NovaTravel_PlayerMeetsStellarAccess` (in 0x00457580): a governed stellar is
  landable when `rep ≥ MinStatus` or MinStatus = −32767, and never when MinStatus = 32767. It is
  overridden by domination, an accepted bribe (engage timer > 0x2ed), the stellar being an active
  mission's travel/return stellar, and the AlwaysLand rank privilege (allied governments
  included). A government Require-mask failure denies. In the comm window the IFF scrambler clears
  a denial.
- **NovaSwift.** `App/Game/GameContainerView.swift:1379` `landingRefusalReason` with a hard-coded
  `≤ −150` at `:1411`; MinStatus is read only for hypergates.
- **Class.** FIX (needs EC-02). **Impact** high. **Confidence** high.
- **Test.** MinStatus 32767 is never landable; a mission destination is landable despite a bad
  record.

#### EC-05 · Landing fee gate — **DONE**
- **Done (Batch 4).** Unpayable fee refuses with STR# 2002 #61+#62–64; dominated waives; full fee deducted on touchdown.
- **Original.** 0x00457580: when the fee > 0 and the stellar is not dominated, `credits < fee`
  **denies landing**; otherwise the full fee is deducted. Dominated stellars waive it.
- **NovaSwift.** `App/Game/GameContainerView.swift:1930` `chargeLandingFee` charges
  `min(fee, credits)` and never denies or waives.
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** 10 credits against a fee of 50 → landing refused.

#### EC-06 · Free repair and refill on launch — **DONE**
- **Done (Batch 4).** Shields and armor refilled free on docking for every stellar; paid repair removed.
- **Original.** `Stellar_Launch` (0x00456020 / 0x00455e10) refills shields and armor free on every
  launch. No paid repair exists.
- **NovaSwift.** `App/Game/GameContainerView.swift:1939` `repairOnLanding` charges 2 cr per armor
  point unless Roadside Assistance or a rank applies.
- **Class.** FIX. **Impact** medium-high. **Confidence** high.
- **Test.** Launch with 10 % armor → 100 %, credits unchanged.

#### EC-07 · Outfit resale at half price — **DONE**
- **Done (Batch 4).** `PilotEconomy.outfitSalePrice`: half (truncated) unless owned > count at outfitter open (newest first); sale refused if free mass would go from ≥ 0 to < 0; sell rule `owned && !(Flags & 0x0008)`.
- **Original.** 0x0048ea70 (exe-verified): units owned when the outfitter opened sell for
  `trunc(unscaledPrice × 0.5)`; units bought in the same session refund in full. A sale that would
  push free mass negative is refused.
- **NovaSwift.** `Story/PilotEconomy.swift:383` `sellOutfit` always refunds the full effective
  cost (the comment at `:380` says this is the original rule, which is wrong).
- **Class.** FIX. **Impact** high (economy exploit). **Confidence** high.
- **Test.** Buy, leave, re-enter, sell → 50 %; buy then sell in the same session → 100 %.

#### EC-08 · Free mass includes the stock loadout — **DONE**
- **Done (Batch 4).** `NovaGame.stockFittingMass` (stock weapons, AmmoLoad, DefaultItems, TechLevel < 32767) added to `massCapacity`.
- **Original.** Loader 0x004bd3c0 raises the class FreeMass by the purchase mass of the stock
  weapons, stock ammo and DefaultItems. With `Σ owned × mass` subtracted at runtime
  (`Ship_ComputeShipFreeMass` 0x00463470), a stock hull shows exactly its resource FreeMass.
- **NovaSwift.** `Engine/ShipLoadout.swift:535` `massCapacity: s.freeMass` while `usedMass` counts
  the granted stock fittings (the player inventory invariant).
- **Class.** FIX. Keep the inventory invariant and fold the stock mass into capacity.
  **Impact** high. **Confidence** medium-high (the loader port is tagged 68 %).
- **Test.** A new Shuttle shows free mass equal to shïp FreeMass.

#### EC-09 · Ship price, trade-in and hire price — **DONE**
- **Done (Batch 4).** `LandedServices.scaledPurchasePrice` (oracle-pinned table: double-precision products on a single-precision scale, e.g. 14,000 × 0.9 → 12,500), trade-in = scaled twice, ½ non-persistent outfits; purchase credits trade-in, OnRetire, charges price, OnPurchase, redraws the class roll; hire = trunc(price × 0.1).
- **Original.** `Outfit_ComputeScaledPurchasePrice` 0x0049d640:
  - Tech markdown: if item tech < 6, stellar tech < 6, item < stellar and base > 99, then
    `trunc(base × (100 − 3 × (stellar − item)) × 0.01)` (a known original cap; keep it).
  - Then `max(1, trunc(price × rankScale))`.
  - Prices > 100 are truncated to a multiple of 10 (≤ 10k), 100 (≤ 100k) or 1000.

  Trade-in (`Ship_ComputeTradeInValue` 0x00469100) is `trunc(0.25 × hull)` plus `0.5 × price` per
  owned **non-persistent** outfit, and the total is scaled twice. On purchase (0x00492f30): credit
  the trade-in, run OnRetire, charge the full price, then add 4 days (FL-05). Hire price is
  `trunc(scaledPrice × 0.1)`.
- **NovaSwift.** `Story/PilotEconomy.swift:425` `tradeInValue` (25 % of everything, persistent
  included), `:447` `buyShip` (`cost × rankMult` rounded), `Kit/NovaModels.swift:474`
  `escortHireFee = max(1, cost/10)`.
- **Class.** FIX. **Impact** high. **Confidence** high.
- **Test.** A tech-3 ship at a tech-5 port costs 94 % of base, rounded to the table.

#### EC-10 · Rank effects: scope, stacking, revocation — **DONE**
- **Done (Batch 4).** Product over allied ranks (PriceMod < 1 → 100, Float like the original) for ships, trade-ins and hire; never commodities or outfits; AlwaysLand allied.
- **Done (cleanup 1).** Crime revocation (`Government_ProcessFactionCombatEvent` 0x00466fc0):
  after the flood, every active non-permanent rank allied with the victim (or its own) with Flags
  0x0040, or 0x0004 on a disable or kill, is deactivated in id order with the `L` cascade
  (`PlayerState.revokeRanks`); a derelict victim or a mission ship changes nothing. In flight
  `Diplomacy` queues its crimes and the host applies them at its sync points.
- **Original.**
  - PriceMod is the **product** over every active rank whose government is allied (or the same)
    to the landed stellar's government. It applies to ships, trade-ins and hire; not to
    commodities; and not to outfits (the price is computed and discarded, exe-verified).
  - No-auto-attack (0x0100) and AlwaysLand (0x0200) extend to allied governments.
  - Crimes revoke non-permanent allied ranks: 0x0040 on any crime, 0x0004 on disable or kill
    (decomp `government.cpp`).
- **NovaSwift.** `Story/PilotEconomy.swift:265` `rankPriceMultiplier` takes the minimum over
  exact-government ranks and applies it to commodities, outfits and ships;
  `App/Game/GameContainerView.swift:126` uses the exact government only; no revocation.
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** Two allied 0.9 ranks give 0.81 on ships; outfit prices are unchanged.

#### EC-11 · Daily stock rolls for outfits and ships — **DONE**
- **Done (Batch 4).** `NovaGame.dailyStockRoll`: one roll per item per day shared by every port (derived from the date), owned outfits skip it, a ship purchase redraws its class (`PlayerState.stockRerolls`).
- **Original.** One roll per outfit and per ship class per **day**, shared by every port, redrawn
  at the daily tick (`ShipClass_RerollShipClassAvailabilityChances` 0x00466cb0). An item shows when
  BuyRandom ≥ 1 and roll ≤ BuyRandom (0 = never; LD-01). Owning a visible item zeroes its roll.
  Buying a ship re-rolls its class.
- **NovaSwift.** `Kit/NovaEconomy.swift:325` `onOfferToday` (a per-day, per-spöb FNV hash; ≤ 0 =
  always).
- **Class.** FIX. **Impact** medium. **Confidence** medium-high.
- **Test.** Two outfitters on the same day list the same random-stock items.

#### EC-12 · RequireGovt band — **DONE**
- **Done (Batch 4).** Outside the RequireGovt band the outfit is locked; Require bits checked everywhere.
- **Original.** `NovaLanded_CanBuyOutfit` 0x00491950: outside the RequireGovt band the item
  **cannot be bought**; the Require bits are checked everywhere.
- **NovaSwift.** `App/Spaceport/ItemLocking.swift:~48–71` (outside the band the gate is skipped, which is
  the Bible's wording).
- **Class.** FIX. **Impact** low-medium. **Confidence** medium.
- **Test.** An item with RequireGovt is unbuyable at an out-of-band port.

#### EC-13 · Ammo purchase cap — **DONE**
- **Done (Batch 4).** `PilotEconomy.ammoLimit`: MaxAmmo × mounted launchers when the first modifier is ModType 3.
- **Original.** `Outfit_ClampOutfitOwnedCountToCurrentLimits` 0x004656a0 caps ammo at
  `MaxAmmo × mounted launchers`; with no launcher, no ammo can be bought.
- **NovaSwift.** Missing (`Story/PilotEconomy.swift:284` `canBuyOutfit`).
- **Class.** FIX. **Impact** low-medium. **Confidence** high.
- **Test.** Without a launcher the ammo Buy button is disabled.

#### EC-14 · Mass- and price-scaled outfits — **DONE**
- **Done (Batch 4).** Floors at the base mass/cost; non-positive cost is free.
- **Original.** Flags 0x0400: mass = `trunc(mass × hull × 0.01)`; Flags 0x0200: price =
  `cost × hull`. Each is floored at the outfit's base value (0x0046e910 / 0x0046e950).
- **NovaSwift.** `Engine/ShipLoadout.swift:~255–268` has no floor.
- **Class.** FIX. **Impact** low. **Confidence** high.
- **Test.** A 50 t hull pays base mass, not half.

#### EC-15 · Contraband scan and penalties — **DONE**
- **Done (cleanup 1).** Q-EC-11 settled from 0x00401800: player +0xa4 is the jump's spin-up start
  tick, and the term is the FL-04 tunnel progress. After its roll, the scan is dropped when the
  jump timer runs, the player is not disabled and that progress is above 0
  (`World.reportScan`).
- **Done (Batch 4).** Penalty side done in `ContrabandScan`: SmugPenalty ≠ 0 gate, no CrimeTol gate, outfit/junk arms cost SmugPenalty, mission arm never does, outfit fines flat only, percentage arm `trunc(credits × −fine × 1e−4) × 100` (min 1), scannable junk suppresses the outfit arm. The scan trigger (100 px, 75 %) is AI-24.
- **Done (Batch 4 merge).** The trigger's government gate is `Contraband.scanFires` (SmugPenalty ≠ 0, then `Rand(100) ≤ 75`), called by the original AI's scan. In flight the SmugPenalty flood goes to the live per-system record (`Diplomacy.recordSmuggling`, EC-02); `ContrabandScan.enforce` floods the pilot directly only off-session. The jump-progress gate (Q-EC-11) is settled below (cleanup 1).
- **Original.** `Ship_ScanPlayerForContraband` 0x00401800 needs a behavior-3/4 scanner, a
  government SmugPenalty ≠ 0, the scanner within 100 px per axis (exe-verified), cloak rules, and
  `rand(100) ≤ 75`. A scan is dropped once the player's jump is past the tunnel onset (Q-EC-11).
  - The mission-cargo arm never fires faction event 0 (a quirk).
  - Outfit and junk arms fire event 0.
  - A mission with flag 0x20 fails; otherwise a warning or fine.
  - Outfit fines are flat positive only. The percentage arm
    (`trunc(credits × −fine × 1e−4) × 100`, minimum 1) applies to mission and junk only.
  - A junk item with any ScanMask suppresses the outfit arm.
  - There is no CrimeTol gate.
- **NovaSwift.** `Story/ContrabandScan.swift:35, 45` (CrimeTol skip; SmugPenalty only for mission
  smuggling), `Story/Contraband.swift:~30` (`cash × pct / 100`); interceptors only, at 240 units.
- **Class.** FIX (the scan *trigger* is AI-24). **Impact** high. **Confidence** high.
- **Test.** An illegal outfit found by a scan floods SmugPenalty; mission contraband does not.

#### EC-16 · Demand Tribute — **DONE**
- **Done (Batch 4).** `World.demandTribute(firstPressInWindow:)`: flat 12,800 gate; every demand drops a record still ≥ MinStatus to MinStatus − 1 and fires KillPenalty once, five more on domination or when the defence opens (`applyTributeCrime`: `Diplomacy.lowerReputationHere` writes the current system's reputation, then `recordCrime(.kill)` floods — EC-02; an ungoverned stellar floods as an independent victim); nothing left to fight → the window's first demand dominates; Release reseeds and runs OnRelease. Garrison persistence is AI-15.
- **Original.** 0x00480030:
  - Every demand fires faction event 3. If the player's reputation still meets MinStatus, it is
    first dropped to `MinStatus − 1`.
  - `combat_rating < 12800` is laughed off.
  - With no present or mounted garrison, the first press dominates immediately (five more event-3
    floods, then OnDominate).
  - Otherwise five event-3 floods fire and a wave of `max % 10` (or the whole count) is mounted
    from the persistent garrison.
  - Release reseeds the garrison, drops reputation the same way, and runs OnRelease.
- **NovaSwift.** `Engine/Domination.swift:46` `demandTribute`: `.noDefenseFleet` refusal at :66;
  gate `defenseTotal × tributeRatingPerDefender` (:36); no reputation cost; per-World pool.
- **Class.** FIX (needs EC-02 and AI-15). **Impact** high. **Confidence** high.
- **Test.** An undefended world is dominated on the first demand; rating 12799 is refused.

#### EC-17 · Capture ship swap — **DONE**
- **Done (Batch 4).** `PilotEconomy.takeCommandOfCapturedHull`: only Flags 0x0004 outfits stay, prize fittings granted, OnRetire then OnCapture, old hull kept only with escort room (STR# 2002 #304/#305). Live-bank ammo remapping approximated by the stock AmmoLoad.
- **Original.** `Player_ReplaceShipWithCapturedHull` 0x00423fa0: zero every non-persistent outfit;
  the captured hull's live banks fill only empty player banks (ammo remapped by AmmoType); add the
  class DefaultItems; run OnRetire (old) then OnCapture; the old hull becomes a behavior-6 escort.
  The swap is refused if no ship slot is free.
- **NovaSwift.** `App/Game/GameContainerView.swift:2574` `takeCommandOfCapturedShip` keeps every
  outfit and adds the new fittings; no OnRetire.
- **Class.** FIX. **Impact** high (duplicated outfits). **Confidence** high.
- **Test.** After a swap, the outfit count equals the new hull's defaults plus persistent items.

#### EC-18 · Boarding loot, capture odds, panic self-destruct — **DONE**
- **Done (cleanup 1).** Loot rolls per 0x00484230: the cargo option is one commodity drawn by
  `rand(7)` until it hits a düde Booty bit, in `rand(holds/2) + holds/2` tons (the signed `/2`
  idiom is a truncating halve, not the `(holds+1)/2` read above); no Booty commodity bit → no
  cargo, whatever the hold carries. Fuel is `rand(fuel/10) × 10` of the hull. Both are rolled once
  per hulk, cut to the room (fleet free space / the tank) and spent when taken — with no room the
  cargo option is still spent (0x00482940). Line: "You salvaged N tons of X from this ship."
  (#115/#391/#108) or #114. Düde ships from the original spawner now record their Booty. The
  original's draw spins forever on a Booty with only bits above 0x40; that offers nothing here.
- **Done (Batch 4).** Escorts add a tenth of crew/strength (non-mission, InherentAI > 2), +10 when strength > 5 × the **target** class's strength (the exe compares against the target; this item's "player's class" wording was wrong), odds 0 for govt Flags 0x0800 or a full wing, capture succeeds on roll ≤ odds with `5 − rand(11)`; booty credits per OQ C6 (düde 0x40 at spawn, përs × 0.5); panic 15 + rand(26) × 2/1.25/2/1.5; 1-in-10 scuttle; hulk left disabled; recruit at half armor. Cargo/fuel loot rolls (`rand((holds+1)/2) + …`, `rand(fuel/10) × 10`) still use the spawn-time hold.
- **Original.** `Boarding_BuildOptions` 0x00484230 and `NovaUi_RunBoardingPlunderWindow` 0x00482940:
  - Credits (settled, OQ C6): with düde Booty 0x40, `v = trunc(Cost/1000) × 0.025`; if v > 2,
    `trunc((Rand(trunc(v)) + v) × 1000)`, else `trunc(v × 1000)`; floored at 1000. Without
    0x40, a përs uses `v = trunc(Credits/1000) × 0.5` (PersDef +0x618) with the same formula and
    **no** 1000 floor; any other ship has no credits option. Mission ships spawned from a düde use
    that düde's Booty. Credits < 1 → no option.
  - Cargo: `rand((holds+1)/2) + (holds+1)/2` of one random booty commodity.
  - Fuel: `rand(fuelMax/10) × 10`.
  - Crew = player class crew + 0.1 × crew of non-mission AI > 2 escorts (§1) + positive marines.
  - Odds = `trunc(crew / (targetCrew × 10) × 100)` + negative-marine %, + 10 when the strength
    accumulator exceeds 5 × the **player's** class strength, + `5 − rand(11)`, clamped [1, 75].
    Odds are 0 for derelict governments or at the escort cap.
  - Panic is seeded `15 + rand(26)` and multiplied by × 2 / × 1.25 / × 1.5 per loot action; each
    loop rolls `rand(100) ≤ panic` to self-destruct. A successful capture has a 1/10 "Oops".
  - An escort recruit gets armor = max × 0.5.
  - A boarded hulk stays disabled (boarded latch).
- **NovaSwift.** `Engine/World.swift:3456` `captureChance` (escort crew at full value, inverted
  strength comparison), `:3493` (credits from a hash), `:3565` `finishBoardingWithoutCapture`
  **destroys** the hulk.
- **Class.** FIX. **Impact** medium. **Confidence** medium-high (credits: high).
- **Test.** Boarding without capture leaves a hulk; a 40 % odds table matches the formula.

#### EC-19 · Escort cap and hire availability — dedupes economy D16 and AI C8 — **DONE**
- **Done (Batch 4).** Cap 6 non-mission escorts (`largerEscortWing` keeps 9 incl. mission); hire list = one galaxy-wide roll per class per day, redrawn on hire; invented 1–5 stock removed.
- **Original.** The cap is 6 non-mission behavior-6 escorts (0x00468920, exe-verified); at the cap,
  capture odds are 0 ("You already have the maximum…"). Hire availability is one global roll per
  class per day, `rand(100) + 1 ≤ HireRandom` (0 = never), redrawn on hire so the class drops off
  that day's list. The price is EC-09.
- **NovaSwift.** `Story/PilotEconomy.swift:551` `maxEscorts = 9`, mission escorts counted;
  `:509` / `:529` per-port FNV plus a 1–5 stock; capture still succeeds at the cap
  (`App/Game/GameContainerView.swift:~1212`).
- **Class.** FIX+ENH → `largerEscortWing` (cap only; the stock model is FIX). **Impact**
  medium-high. **Confidence** high.
- **Test.** A 7th hire is refused; hired classes vanish from every port that day.

#### EC-20 · Salary and escort payroll — dedupes economy D25 and AI C9 — **DONE**
- **Done (Batch 4).** Slot order, fee `trunc(cost × 0.01)` with no floor, negative salary clamped to 0.
- **Done (cleanup 1).** Upkeep left the daily tick: `StoryEngine.processEscortPayroll` runs one
  period as the spaceport closes (after the escort fleet pass) and `travelDays` periods on each
  hyperspace arrival; gates add none. Hired escorts only, disabled ones skipped; an unpaid escort
  defects (a non-mission freighter hands its cargo share over first, EC-21) and one dialog says so
  (STR# 2002 #302 / #303). The invented per-charge HUD line is `extraStatusMessages`.
- **Original.**
  - Salary is paid when `credits < cap || cap < 1`; afterwards a negative balance is clamped to 0
    (decomp `mission_world.cpp`).
  - Escort upkeep (`Player_ProcessEscortPayroll` 0x004232d0) is `trunc(cost × 0.01)`, charged one
    period at every landing (the tail of 0x004229d0) plus `travelDays` periods per jump.
  - It is charged in slot order, skipping disabled, ShipBehav-1 mission and captured escorts, with
    one message (STR# 0x7d2 0x12e/0x12f).
  - A defector is deactivated with behavior 1; freighters transfer cargo first.
- **NovaSwift.** `Story/StoryEngine.swift:869` `payDailyEscortFees` (per calendar day, cheapest
  first, a message per escort), `:885` `payDailySalaries` (no clamp), `Kit/NovaModels.swift:477`
  (floor 1).
- **Class.** FIX (needs FL-05). **Impact** medium. **Confidence** high.
- **Test.** A 2-day jump charges two periods; landing charges one.

#### EC-21 · Freighter escorts pool cargo — dedupes economy D27 and AI C3 — **DONE**
- **Done (Batch 4).** `PilotEconomy.cargoCapacity` adds non-mission escorts with InherentAI < 3, cap 32000.
- **Done (cleanup 1).** `PilotEconomy.transferCargoToEscort` (0x00469810): ratio
  `min(1, holds / (player holds + Σ freighter holds))`, each non-mission stack loses
  `trunc(tons × ratio)`. Run when a non-mission freighter escort dies or defects, and for any
  escort released from the escort window (whatever its hull, as the original does).
- **Original.** Fleet capacity (0x00469760 / 0x0046a7c0) = player holds + holds of non-mission
  behavior-6 escorts with InherentAI < 3, capped at 32000; the trade center uses it. Losing such an
  escort removes cargo by `ratio = recipientHolds / fleetCapacity`
  (`TransferCargoAndJunkToEscortByRatio` 0x00469810).
- **NovaSwift.** `Story/PilotEconomy.swift:124` `cargoCapacity` (player hull only).
- **Class.** FIX. **Impact** high. **Confidence** high.
- **Test.** Hiring a 50 t freighter adds 50 t of tradeable capacity.

#### EC-22 · Escort sell and upgrade flow — **DONE**
- **Done (cleanup 1).** The escort window (0x004853a0) sets exclusive toggle marks: Upgrade only
  when the class's UpgradeTo hull passes its availability expression, Sell never for a hired or
  mission escort. `PilotEconomy.processEscortFleetAtStellar` (0x004229d0) runs as the spaceport
  closes, at a shipyard stellar only: sales first (non-disabled, non-mission, EscSellValue or 10 %
  of cost), then each affordable upgrade (an unaffordable one stays marked); one dialog "One
  escort was sold for a profit of N credits." (#298–#301, capitalised STR# 137 count words, the
  two sentences separated by a blank line), and `trunc((sold + upgraded) / 2)` days via
  `SpaceportVisitDays` (0x00466cb0 is the full daily tick, despite its name). Release hands over
  the cargo share and leaves the ship in system with its default AI.
- **Original.** `Player_ProcessEscortFleetAtStellar` 0x004229d0: sale and upgrade are **marks**,
  processed on landing at a shipyard stellar (flag 0x8). The pass refills every escort and costs
  `(sold + upgraded)/2` days. An upgrade requires UpgradeTo's availability expression. Release
  transfers cargo and leaves the ship in system as an NPC with its default AI. Sell value is
  EscSellValue, or `trunc(0.1 × cost)` when ≤ 0 (already matches).
- **NovaSwift.** `Story/PilotEconomy.swift:~611, 644` (immediate sale, upgrade ignores
  availability, no days, release despawns).
- **Class.** FIX. **Impact** low-medium. **Confidence** high.
- **Test.** Selling two escorts at a shipyard adds 1 day.

#### EC-23 · Refuel service — **DONE**
- **Done (Batch 4).** `LandedServices.refuel`: nothing at uninhabited, whole units at 1 cr, partial, free when dominated; auto-refueller the same with no waiver.
- **Original (settled, OQ C1).** The Refuel button (item 4 of 0x00491f30) does nothing at an
  uninhabited stellar (runtime flags 0x20). Otherwise fuel is truncated to whole units, `need =
  trunc(capacity − fuel)`, and at a non-dominated stellar `need` is clamped to credits and
  charged at **1 cr per unit** (100 cr per jump), allowing partial fills. A dominated stellar
  refuels free to capacity. No rank, government or Roadside Assistance waiver exists. The
  ModType-19 auto-refueller (`Player_RefuelShipWithCredits` 0x004250f0) uses the same 1 cr/unit
  partial fill, truncating, with no dominated waiver.
- **NovaSwift.** `App/Spaceport/SpaceportView.swift:~301–372` (all-or-nothing at the port's
  recharge price; free with Roadside Assistance or a rank with flag 0x0800); the auto-refueller is
  all-or-nothing (:320–334), and the `Engine/ShipLoadout.swift:174` doc ("for free") is stale.
- **Class.** FIX. **Impact** low-medium. **Confidence** high.
- **Test.** 30 credits with 100 fuel missing buys 30 units; at a dominated world refuel is free;
  at an uninhabited world the button does nothing.

#### AI-42 · Bribe and Beg For Mercy on hostile ships — **DONE**
- **Done (AI pass 2).** The whole button tree of 0x0047e470 is `OriginalAI.pressAssistance` / `pressGreetings` / `settle`: the ShipBehav-0 mission exemption, the defense-ship and revenge-përs refusals, separate lines for busy (0x10, 0x16 for escorts, 0x1D when already helping), not in trouble (0x0E), rather not (0x11) and can't do that (0x19); help against a threat (behavior 2 only faction-less with `instance % 3 == 0`, 3/4 paid, ≥ 5 free) and rank 0x0400 allies (free, plus the reinforcement call); flags_secondary 0x0001 disables the button and 0x0008 mutes it; rank 0x0800 makes assistance free. The label is STR# 150 #25. A Flags-0x8000 government takes the ordinary price draw first and then its own (two draws). `Ship_IsThreatened` (0x0040fc00) compares the ship's own target with its own slot, so it never fires; only a non-idle state (not 0/1/2/7/0x14) makes a ship busy. A player-led behavior-6 mission escort that is not ShipBehav 1 is let go (STR# 3001) and leaves when the window closes; its cargo hand-back is not modelled.
- **Done (Batch 4 merge).** Under the original AI each ship hail opens an `OriginalComms.Session` (variant, personality, price); the middle button reads Beg For Mercy while the ship keeps pressing. Beg For Mercy offers the bribe (bribable rule, never përs 1150) and Request Assistance runs `assistanceReply`; both price through Batch 4's shared `PaymentWindow` (DLOG 1008, haggle 36 %), free with flags_secondary 0x10. Paid bribe → state 2, behavior 1; refused → hostile, price + 1000; paid assistance → state 9 / 0x0F. Not yet: the mission-linked exemption, the separate busy/not-in-trouble/rather-not lines (they share #0x13), the Beg For Mercy STR# 150 label, and the greedy-government double roll.
- **Original.** `NovaUi_RunTargetShipCommWindow` 0x0047e470. When the ship keeps pressing its
  target, the assistance button reads "Beg For Mercy".
  - A bribe is offered (never by defense ships) when the ship is faction-less, or its government
    has 0x2000 and behavior < 3, or 0x0200 and behavior > 2.
  - Cost = `(rand(floor(credits × 5e−7)) × 1000 + 3000) × personality`. With government 0x8000
    it is `(rand(floor(credits × 1e−4)) × 1000 + 10000) × personality`.
  - `personality = (rand(0x29) + 0x50) × 0.01`, then a 1/5 chance of −0.5, else a 1/5 chance of
    +0.5.
  - Each `Rand` range is `max(1, trunc(…))` (truncated, not ceil). The result is capped at
    `trunc(credits × 0.333)`, floored to a multiple of 1000, and clamped [1000, 20000].
  - përs slot 0x3fe and mission-linked ships whose mïsn +0xc == 0 are never bribable. The
    personality also picks the prompt (p < 0.8 → STR# 3000 #0x17; ≤ 1.2 → #0x12 bribe / #0x1c
    assist; else #0x18).
  - If paid, the ship leaves (state 2, behavior 1). If refused, it turns hostile, and a refused
    roll raises the next price by 1000 for this comm session.
  - Government flags_secondary 0x10 grants the request free.
  - **Payment window (settled, OQ C8; replaces Q-AI-12).** `FUN_00482280` (DLOG 1008, PICT 0x2142),
    shared by ship bribes, Request Assistance and planetary bribes (EC-25), is interactive. At open
    it rolls `haggleOK = Rand(100) ≤ 35` (36 %). Pay accepts the current price. The haggle button
    succeeds once if `haggleOK` (price × 0.75, then `trunc(price × 0.01) × 100`; the window stays
    open with haggle spent), otherwise refuses and closes. Callers first test credits < price
    ("can't afford"). The decomp's automatic 35 % roll is not the original.
- **NovaSwift.** "They aren't interested in talking." (`App/Game/GameContainerView.swift:2804`);
  `NegotiationView` (#1008) is unwired.
- **Class.** FIX. **Impact** high. **Confidence** high.
- **Test.** A pirate with Flags 0x0200 offers a bribe in [1000, 20000], a multiple of 1000. With
  the RNG seeded so `haggleOK` holds, one haggle on 8000 gives 6000 and a second press is
  impossible (oracle: 0x00482280).

#### AI-43 · Greetings text — **DONE**
- **Done (AI pass 2).** `OriginalAI.buildGreeting` at window open, in the original's draw order: STR# 2002 #175 by default; düde InfoTypes (now decoded, `DudeRes.infoTypes`, ships carry `dudeID`) pick a set type by `Rand(4)` rejection — a galaxy-wide trade tip (`Rand(6)` commodity, `Rand(0x800)` stellar until low/high: "<name> is a good place to buy|sell <commodity>."), a disaster report from the host's active disasters with > 1 day left (#179–#186), STR# (bits & 0xfff) + 7500 entry `Rand(DAT_007d17ca % count + 1) + 1` (`World.commQuoteRoll`: `Rand(0x800)` per arrival, −1 after a stellar comm), or the government's `STR ` 10010/10015 + variant falling back to STR# 7000 + govt; short or `*` text → STR# 3000 #46–50; a përs CommQuote overrides; a përs with Flags 0x8000 and no CommQuote reports a disaster. The opening line is the original's prompt 0/2/4/5/8 ("Glad to see you, <pilot>." for a ShipGoal-3 ship); Greetings answers "Stop wasting my time." while the ship presses or dislikes the player (`Ship_DoesShipLikePlayer` 0x0040fd20, `OriginalAI.likesPlayer`) and "No response." when disabled or flags_secondary 0x0001. Fleet ships have no düde, so they say "Greetings." (known bugs #125/#126).
- **Original.** 0x004819d0 picks one type uniformly from the set bits of düde +0x06:
  - 0x1000: a trade tip;
  - 0x2000: a disaster report;
  - 0x4000: STR# (bits & 0xfff) + 7500;
  - 0x8000: government `STR ` faction × 10 + 10010/10015 + random, falling back to STR#
    faction + 7000.

  Short or `*` text falls back to STR# 3000 prompt 0x2e. A përs CommQuote overrides (Greetings
  only). Keep-pressing or disliking ships answer "Stop wasting my time." Opening prompts come from
  STR# 3000/3001 (`idx × 5 + rand(5) + 1`, 0x004828c0). Fleet ships and përs ignore generic
  government quotes (known bugs #125/#126).
- **NovaSwift.** Canned English (`App/Game/GameContainerView.swift:~900–903, 2804–2826`).
- **Class.** FIX. **Impact** medium (flavour). **Confidence** high.
- **Test.** A düde with only 0x1000 always gives a trade tip.

#### AI-44 · Hail eligibility — **DONE**
- **Done (AI pass 2).** `OriginalAI.hailCheck` (0x00454910): beep while the player is cloaked, dead or jumping; #54 for a ship spinning up (#53 if it is also disabled); #53 for a Flags-0x0400 government or hull inherent government (përs included) unless the ship is the player's non-mission escort, for class 0x2ff, a disabled ship and the Enforcer përs; the player's behavior-6 escorts open the escort window. The app routes hails through it under the original AI.
- **Original.** Government Flags 0x400 (or the class inherent government's 0x400) blocks hailing
  any ship not attached to the player, përs included. Disabled ships, class 0x2ff and përs 0x3ff
  cannot be hailed. flags_secondary 0x1 hides assistance (Greetings answers "No response."), and
  0x8 makes assistance answer "No response.".
- **NovaSwift.** `App/Game/GameContainerView.swift:~2787–2795` (përs exempt, disabled hailable,
  inherent-government and flags2 0x8 ignored; 0x10 reused for roadside assistance).
- **Also (ui_rules A14).** The player cannot hail (beep only) while cloaked, destroyed or
  jumping. A jumping target answers "Unable to send hail - target ship is entering hyperspace."
  (STR# 2002 #54); a disabled jumping target "No response." (#53). NovaSwift's "No response to your
  hail." (`App/Game/GameContainerView.swift:2791`) is not an original string. Escorts of the
  player (behavior 6, leader 0, non-mission) open the escort window DLOG 1022 instead of comms.
- **Class.** FIX. **Impact** low. **Confidence** high.
- **Test.** A disabled ship cannot be hailed.

#### UI-09 · Stellar hail window — ui_rules A8 — **DONE**
- **Done (Batch 4).** No window for uninhabited stellars or gates (STR# 2002 #53 — `StellarComm.open` returning nil is the one implementation; Batch 7's duplicate was dropped in the merge); STR# 3002/3000 lines by prompt×5 + variant; status Dominated/Owned/Hostile/Forbidden; class fragment STR 7000+graphic / STR# 1100; buttons Greetings|Offer Bribe, Demand Tribute|Release, Close. Request Landing only under `forgivingLanding`.
- **Original.** `Ship_HandlePlayerTargetActionCommand` 0x00454910 (Alt forces the stellar
  channel, UI-06): an uninhabited stellar (flags 0x20), a gate or wormhole (0x3000), an
  unavailable stellar or an inactive sprite gets no window, just a beep and "No response." (#53).
  The window (0x00480030 / 0x004812c0):
  - header: name, class fragment (STR# 1100 entry `link_a_id + 1`, or `STR ` `link_a_id + 7000`)
    and "Status:" (#196) with "Uninhabited" (#170), "Owned" (#171) / "Dominated" (#172), or for
    a denied stellar "Hostile" (#174, red, rep < 0) / "Forbidden" (#173);
  - opening text: STR# 3002 `rand(5) + 1` + name + "." when open or dominated; STR# 3000 #11–15
    when denied;
  - buttons: Close Channel / Greetings **or** Offer Bribe (EC-25) / Demand Tribute **or** Release
    (always shown; Release when dominated); Greetings answers STR# 3000 #46–50.
- **NovaSwift.** Opens for every planet; fixed "Channel open to X." plus an invented refusal; an
  invented "Request Landing" button (`App/Spaceport/SpaceportGraphics.swift:209`, flipping to
  "Landing clearance granted…" at `App/Game/GameContainerView.swift:2909`); Demand Tribute only
  when a defense fleet exists (:2846–2849); Greetings "Just a routine hail, nothing more."
  (:900–903); hostility from `legalRecord <= −150`; no Status word, class fragment, Release or
  bribe.
- **Class.** FIX (the Request Landing button survives only under `forgivingLanding`). Needs EC-02.
  **Impact** medium. **Confidence** high.
- **Test.** Hailing an uninhabited planet shows "No response." and no window; a dominated world
  offers Release.

#### EC-24 · Tribbles and perishable junk — settles Q-EC-03 — **DONE**
- **Done (Batch 4).** `PilotEconomy.runJunkCargoEvent` on the 0…1024 raw-call counter at multiples of 250, in flight; tribbles +1 t/type while fleet free space > 0; perishables −1 t only then — with no tribble aboard they never rot (user ruling on the stale slot).
- **Original (OQ C4).** In flight only, every 250 frames of the 0..1024 wrapping frame counter
  (5 events per 1025 frames, the last gap 25 frames), inside the player tick 0x0044aa70
  (0x00451e6f / 0x00451f0f). Junk Flags 0x1 (tribbles; a junk with both bits counts as a tribble)
  grows by **+1 ton per type per event** while fleet free space (computed once per event) is > 0,
  so several tribble types can overfill by a ton each. Junk Flags 0x2 (perishable) loses 1 ton
  per type per event, gated on the same free-space variable: perishables rot only while the hold
  is not full. With no tribble aboard that variable is a stale stack slot (original bug; Q-EC-03
  remains for the oracle).
- **NovaSwift.** `Story/PilotEconomy.swift:~202–210`: +50 %/day tribbles, −25 %/day perishables,
  per calendar day (invented, and documented as such).
- **Class.** FIX (needs FL-01 for the frame cadence). **Impact** low. **Confidence** high
  (stale-slot case: medium).
- **Test.** One tribble type with 10 t free grows 5 t per 1025 raw frames; a full hold stops
  perishable decay.

#### EC-25 · Planetary bribe — settles Q-EC-06 — **DONE**
- **Done (Batch 4).** `StellarComm` + `PaymentWindow`: price per OQ C3, per-jump latch, 0x8000 always bribable, paid → landing granted until the jump, refused/failed haggle → latch 0 and price + 1000; haggle 36 %, ×0.75 then to the hundred, a second haggle ends the deal.
- **Original (OQ C3).** Computed when the stellar comm window opens (0x00480030): `n = max(1,
  trunc(credits × 1e−6))`, `cost = Rand(n) × 1000 + 3000`, ×1.5 (truncated) for government Flags
  0x8000, capped at `trunc(credits × 0.333)`, floored to a multiple of 1000 and clamped
  **[1000, 900000]**. The planet is bribable when a per-jump latch `Rand(100)` (reset to −1 on
  every jump) is > 30 and the stellar is ungoverned or its government has Flags 0x4000;
  government 0x8000 is always bribable. The button works only when landing is refused (record <
  MinStatus, or MinStatus 32767) and the stellar is not dominated. Payment goes through the
  shared window (AI-42): paid → landing granted (EC-04) and credits debited; refused or failed
  haggle → price + 1000 and no further bribe until the next jump.
- **NovaSwift.** No planetary bribe (`NegotiationView` #1008 unwired).
- **Class.** FIX (needs EC-02, EC-04). **Impact** medium. **Confidence** high.
- **Test.** At 2,000,000 credits the offer lies in {3000, 4000} (× 1.5 for 0x8000 worlds);
  refusing blocks the button until the next jump.

#### EC-26 · Bar gambling — from the coverage map — **DONE**
- **Done (Batch 4).** `LandedServices.RaceBet`. Q-EC-14 settled from 0x0047dc50: the standard wager is min(credits, 1000); the modifier opens an amount prompt capped at min(credits, 10000) — "Bet 5000" is not what the window does. Payout 4×; repeat-winner re-roll excludes the pick.
- **Original.** `NovaUi_RunBarGamblingWindow` 0x0047dc50 / `NovaUi_DrawBarGamblingWindow`
  0x0047e1e0, buttons 0x004a2c30 / 0x004a2de0 (named-only; wraitii: "not reconstructed"). The
  wager is `min(credits, 1000)`, or `min(credits, 10000)` with the Bet modifier, deducted up
  front. The machine rolls `rand(4)`; quirk: if the first roll equals the previous round's roll,
  re-rolls exclude both that roll **and** the player's pick, so the round is a guaranteed loss. A
  match pays 4× the wager (STR# 2002 #370). The outcome dësc is 0x7ff8 + roll.
- **NovaSwift.** `App/Story/GamblingView.swift:178–185`: fixed 1000 / 5000 stakes (refused if
  credits are short), uniform `Int.random(1...4)`, and a 3× return documented as "this port's own
  reasonable choice".
- **Contradiction.** STR# 150 labels the second button "Bet 5000", while the coverage audit reads
  the modifier wager as `min(credits, 10000)`. Re-read 0x0047dc50 before porting (Q-EC-14).
- **Class.** FIX. **Impact** low. **Confidence** medium (named-only function; payout and quirk
  read from Ghidra).
- **Test.** After a round whose roll was r, picking a colour ≠ r on a first roll of r always
  loses; a win returns 4× the stake.

#### OS-08 · Bombs (ModType 47 lethal, 50 nonlethal) — **DONE**
- **Done (Batch 4).** Fuse from rand(100) counting sim ticks to 300; lethal bomb is a pod-less game over (STR# 2002 #38 or the dësc); nonlethal removes all units, impact `ModVal − 128`, armor-only damage.
- **Original.** Each derived-state recompute (0x0046d4b0) seeds a timer at `rand(100)`; it counts
  30 Hz ticks to 300, so a bomb goes off 6.7–10 s after acquisition (0x0044b3d4). Lethal (47,
  0x0044daa0): shields and armor set to −1, overlay "You <outfit> detonated" or STR# 2002 #0x26,
  then **back to the main menu**: game over, no escape pod. Nonlethal (50, 0x0044b446): removes
  **all** units, spawns spöb impact effect `ModVal − 128`, and deals armor-only damage
  `base_armor + rand(base_armor × 0.5 + 1)` (as ported; see Q-OS-01).
- **NovaSwift.** `App/Game/GameContainerView.swift:2348–2385`: lethal after a 3–8 s wall-clock
  `DispatchQueue` delay with 1e6 damage through the normal death path (a pod can save it);
  nonlethal 3 % per heartbeat, removes one unit, 30 % shield + 12 % armor, never fatal.
- **Class.** FIX. **Impact** medium-low (plug-in content). **Confidence** high.
- **Test.** A lethal bomb ends the game 6.7–10 s of game time after purchase, pod or not.

### Batch 5 — missions, ranks, crön, text

#### MS-03 · Rank activate/deactivate semantics — merges missions D4/D21 and economy D13 (cascade part) — **DONE**
- **Done.** `L` clears permanent ranks; 0x0001/0x0010 and 0x0002/0x0020 cascades spare permanent siblings; `<RRK>` tracks the last `K` (`activateRank`/`deactivateRank`).
- **Original.**
  - `Rank_Deactivate` 0x00427f40 (exe-verified) always clears an active rank. 0x0008 shields only
    siblings from the 0x0002 (same-government) and 0x0020 (lower-weight) cascades.
  - `Rank_Activate` 0x00427df0: 0x0001 clears same-government siblings except permanent ones;
    0x0010 clears lower-weight siblings.
- **NovaSwift.** `Story/StoryEngine.swift:150` ignores `L` for permanent ranks; `:195`
  `activateRank` handles only 0x0001 and clears permanent siblings.
- **Class.** FIX. **Impact** high (Vell-os T5→T0, Fed 128/129/149, Wild Geese 138 accumulate;
  stacked salaries and perks). **Confidence** very high.
- **Test.** Run mïsn 194's `L131 K132`: only 132 is active afterwards.

#### MS-04 · Completed missions can be re-offered — **DONE**
- **Done.** No completed gate in `isEligible` or përs offers; `completedMissions` is kept only for the storyline guide.
- **Original.** Eligibility (decomp `mission.cpp`) has no "completed" gate; the only duplicate gate
  is "not currently active". AvailBits alone controls repeatability.
- **NovaSwift.** `Story/StoryEngine.swift:289` (and `Story/PersEncounter.swift:~41`) reject completed
  missions; `:532` records them.
- **Class.** FIX. **Impact** high (93 generic stock missions become once-per-pilot).
  **Confidence** very high.
- **Test.** Complete "Delivery to <DST>" and see it offered again.

#### MS-05 · Every eligible bar mission is offered in sequence — **DONE**
- **Done.** `nextLaneOffer`/`MissionOfferState` (removed/shown/context latches per the emulator); bar re-offers on the 15 / rand(30)+30-tick timer; shops offer on open only (their in-screen timer arms are not modelled).
- **Original.** `Mission_RunAvailLocOffers` 0x00448670 plus the bar loop: the first eligible
  AvailLoc-matching mission is offered 15 ticks after entering. Accept or decline removes it, and
  a `rand(0x1e) + 0x1e`-tick recheck offers the next, in DispWeight order. Declined offers stay
  gone until the list is rebuilt.
- **Re-offers (OQ D12, medium-high).** Accepted and refused missions leave the lane list until the
  next arrival. A mission closed without accepting, or whose activation failed (cargo space, no
  free slot), only gets a per-context "shown" flag. Changing context clears all shown flags
  except when the new context is the main spaceport (3); the main screen's periodic offer tick
  sets the context to 3. So leaving the bar, letting the main-screen tick fire (≈ 0.5–1 s), and
  re-entering re-offers an activation-failed mission; going straight back does not. Settle the
  timer unit with the oracle if exactness matters (Q-MS-03).
- **NovaSwift.** `App/Spaceport/SpaceportScreens.swift:944` `rollPatron` (one per bar per day);
  the same "first only" rule at `App/Spaceport/SpaceportView.swift:~121–142`.
- **Class.** FIX. **Impact** high. **Confidence** high.
- **Test.** Two eligible bar missions are both offered in one visit.

#### MS-06 · Auto-abort (Flags 0x0001) resolution — **DONE**
- **Done.** `resolveAutoAbort` on the first objective completion (flight pass, landing pass, or the docked accept tail); OnAbort, DatePostInc, fuel −100, Flags2 0x0002 PayVal, no CompGovt. ShipStart-1 spawn-count nuance not modelled.
- **Original.** When the objective first completes, the game shows ShipDone and runs OnShipDone,
  then `Mission_ResolveMisnSlot` 0x00447d90 runs OnAbort, DatePostInc daily ticks, Flags 0x0008
  `fuel −= 100`, and Flags2 0x0002 PayVal via 0x00440750. CompGovt is **not** applied (an
  original omission).
- **NovaSwift.** `Story/StoryEngine.swift:465` aborts only no-ship missions at accept; ship-goal
  auto-aborts go through `completeMission`.
- **Class.** FIX (after MS-01). **Impact** high/medium. **Confidence** high.
- **Test.** mïsn 905 pays 50000 and resolves; mïsn 896 cleans the record.

#### MS-07 · Two-stage failure lifecycle — **DONE**
- **Done.** `quickFail` keeps the slot (marked • in the mission list); final resolution on landing at ReturnStel reruns OnFailure, takes CompReward/2 and shows FailText with `[Error]` tags.
- **Done (cleanup 1).** Ship release (`Mission_ClearMisnSlotAssignments` 0x00440aa0,
  `GameServices.releaseMissionShips` → `World.releaseMissionShips`): untagged, a grouped ship back
  to its class's default AI, kept in the system (removed while docked) — on an abortable
  quick-fail, the final failure, the auto-abort resolution and every abort. **Correction:** that
  release also clears the slot's active latch, so an abortable (CanAbort) mission that quick-fails
  is dropped at once with its cargo and never reaches the landing resolution; only a
  non-abortable one keeps its failed slot.
- **Original.**
  - Quick fail (`Mission_FailMissionSlotQuick` 0x00440bf0) runs OnFailure, marks the mission
    failed (0xA5 marker in the mission computer), and releases ships only if CanAbort — which
    also clears the slot (see the correction above).
  - The deadline arm fails when the countdown < 1, showing the STR# 0x7d2 0x11d overlay (skipped
    for Flags 0x0400). It is suppressed while landed.
  - Final resolution happens only on landing at ReturnStel (`Mission_ResolveMissionFailure`
    0x00440930): OnFailure runs **again**, CompReward/2 is subtracted across CompGovt systems,
    FailText shows with `[Error]` wildcards, and ships are released.
- **NovaSwift.** `Story/StoryEngine.swift:552` `failMission` removes the mission immediately and
  evaluates per day, including while landed.
- **Class.** FIX. **Impact** medium-high. **Confidence** high.
- **Test.** A failed mission persists in the list until landing at its return stellar.

#### MS-08 · Completion needs the travel leg; ReturnStel −1 means TravelStel — **DONE**
- **Done.** Landing pass (`playerLanded`) follows 0x00443780: travel latch, cargo at travel/return, success only with travel reached and objective complete.
- **Original.** `Mission_ResolveMissionStellarTargets` 0x0043d240 resolves return −1 to
  TravelStel. Success requires `travelReached && objectiveComplete` at ReturnStel. A resolved −1
  return never succeeds.
- **NovaSwift.** `Story/StoryEngine.swift:~701–705` completes in space; `:~1124–1131` checks the
  travel visit only for cargo drop-offs.
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** "Go to X then Y" without cargo does not complete at Y without visiting X.

#### MS-09 · PayVal codes and acceptance fee — dedupes economy D23 and missions D9 — **DONE**
- **Done.** `applyPayVal` per 0x00440750; fee after OnAccept clamped at 0, offers hidden when unaffordable. Clean-record codes lift only negative per-system reputation to 0 (`PlayerState.cleanLegalRecord` → `SystemReputation.clean`, EC-02).
- **Original.** `Government_ApplyReputationCreditDelta` 0x00440750:
  - ≥ 1 adds credits; −9999..0 does nothing; ≤ −40100 does nothing.
  - −10128-g / −20128-g / −30128-g set only **negative** reputation to 0, in systems of that
    government / its allies / sharing a class.
  - −40001..−40099 takes `trunc(credits − credits × pct × 0.01)`.
  - The acceptance fee runs **after** OnAccept as `max(0, credits − fee)`; offers are hidden when
    `credits < fee`.
- **NovaSwift.** `Story/StoryEngine.swift:1194` `applyPayVal` (literal debits for uncoded
  negatives; clean-record wipes positive standing via `Story/PlayerState.swift:~530`; fee charged
  before OnAccept).
- **Class.** FIX (needs EC-02). **Impact** medium. **Confidence** high.
- **Test.** PayVal −500 costs nothing; −10128 leaves positive systems untouched.

#### MS-10 · CompGovt / CompReward and abort penalty — **DONE**
- **Done.** On the per-system record (EC-02): success walks every system (`SystemReputation.applyMissionSuccess`: full delta in CompGovt's systems, ±delta/2 in allied/hostile ones), failure −delta/2 and a player abort −5× (`abortMission(manual:)`) in CompGovt's systems only.
- **Original.** Success (0x00440410) walks **every system in the galaxy**, with no distance decay
  and no clamp: full delta to systems owned by CompGovt, −delta/2 to systems of hostile/xenophobic
  governments, +delta/2 to allied ones, independents unchanged (OQ D4). A manual abort from the mission
  computer only (docked dialog 0x00446150) applies −5× with Flags 0x0040. Script `A` and
  auto-abort apply nothing.
- **NovaSwift.** `Story/StoryEngine.swift:538` (CompGovt record only), `:500` (−5× on every abort
  path).
- **Class.** FIX (needs EC-02). **Impact** medium. **Confidence** high.
- **Test.** Script `A` on a Flags-0x0040 mission leaves reputation unchanged.

#### MS-11 · Ship-goal conditions — **DONE**
- **Done.** Goal counters A/B/C/E on `ActiveMission`; World now reports every lost/disabled mission ship and chase-off departures; escort/observe sighting from the scene heartbeat. A boarded-pickup cargo denial does not yet refuse the board itself.
- **Original.** `Mission_HandleMissionOrSurrenderShipReaction` 0x00443c60:
  - Disable goal: destroying the target (even after disabling it) fails the mission.
  - Board/rescue: destroying an un-boarded target quick-fails.
  - Escort: fails if any escort is destroyed **or disabled**.
  - Observe: completes only when a mission ship is on screen (cloak rules).
  - Chase-off: `counterE + counterA ≥ target`.
- **NovaSwift.** `Engine/World.swift:~2881–2887, 2946–2951`; `Story/StoryEngine.swift:~412–413,
  670–679` (escort/observe "passive").
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** Killing a disable target fails the mission.

#### MS-12 · Cargo-space gate — **DONE**
- **Done.** Activation and travel/boarding pickups check total and free space (STR# 2002 0x165/0x166); the BBS hides only Flags2 0x0001 missions.
- **Original.** Activation refuses when the resolved CargoQty exceeds total or free space.
  Travel-stellar and boarding pickups re-check, showing STR# 0x7d2 0x165/0x166 (0x00440370). The
  BBS hides missions only with Flags2 0x0001.
- **NovaSwift.** `Story/StoryEngine.swift:327` `canAccept` (gated on the misread flag), with
  pickups unchecked (`:~588–595, 654–657`). Keeping unaffordable missions visible is a deliberate
  UX choice (`:~309–317`), which the ruling turns into a FIX.
- **Class.** FIX (after MS-01). **Impact** medium. **Confidence** high.
- **Test.** A full hold cannot accept a 20 t cargo mission.

#### MS-13 · Deadlines — **DONE**
- **Done.** Fails on the flight pass once `date ≥ accept + N` (never in the landing pass); STR# 2002 0x11d overlay unless invisible.
- **Original.** The countdown decrements per daily tick and the mission fails on the next flight
  tick after it reaches 0. In practice the mission must finish by accept + N − 1 unless already
  landed.
- **NovaSwift.** `Story/StoryEngine.swift:404, 896` (`date > accept + N`, one extra day).
- **Class.** FIX (with FL-05). **Impact** medium. **Confidence** high.
- **Test.** A 3-day mission accepted on day 10 fails in flight on day 13.

#### MS-14 · crön lifecycle details — **DONE**
- **Done.** `evaluateCrons` runs the original counters (holdoff/duration/active, old date runtimes converted); window, Duration 0, PreHoldoff quirk, pre-run iterative checks and cap 0x2711 as in 0x00439500.
- **Original.** `Mission_TickDailyCronEvents` 0x00439500 and the window check 0x0046c800:
  - Month/day bounds apply every year, independent of year bounds.
  - Duration 0 runs OnStart **and** OnEnd the same day, then OnEnd again the next day.
  - PostHoldoff with PreHoldoff 0 never deactivates (crön 184, 185, 192 fire once per game).
  - The iterative flags check Require + EnableOn before each run, cap 0x2711.
  - The Random roll `rand(0..100) ≤ Random` happens before the gates.
  - Duration < 0 marks the slot absent.
- **NovaSwift.** `Story/StoryEngine.swift:904` `evaluateCrons`, `:1077` `dateInWindow` (year ≤ 0
  ignores month/day at `:1082`), `:988` (cap 1000).
- **Class.** FIX. **Impact** medium/low (crön 156 Drop Bear season, crön 129 Terraforming).
  **Confidence** high.
- **Test.** crön 156 is active only between 1 Sep and 30 Dec.

#### MS-15 · Random destinations and locator codes — **DONE**
- **Done.** `selectStellar`/`locatorHasCandidate` with the 0x00468b50 adjacency/twin rules and anchor fallback. Twins are approximated as same-position systems; the −2 stale-index and spin quirks are not reproduced.
- **Fixed (cleanup 1).** The 30000/31000 class-share families compared the *compacted* class
  list position by position, so a class after an empty slot shifted. `MissionGeography` now
  delegates allied / hostile / share-class to `GovtRelations`, whose share test reads the raw
  `classSlots` slot by slot (0x0046bff0); every class, ally and enemy list drops any negative slot
  (`-1 < slot`), not only −1. The other consumers test membership, which compaction doesn't
  change.
- **Original.** `Mission_SelectMissionStellarByLocator` 0x0043d510 and
  `Mission_IsStellarValidRandomDestination` 0x00468b50 reject the offering system, **any system
  adjacent to it**, and stellars absent from any twin of their system.
  - −2/−3 use stellar flags 0x10/0x20.
  - 15000 = allied (the exact government excluded for Travel/Return); 25000 = hostile or
    xenophobic; 30000/31000 = class share (positional).
  - The 5000–7047 adjacent-system family is supported.
  - Same-system denial applies to direct TravelStel/ReturnStel.
  - **No-candidate fallback (settled, OQ D3).** Every locator family returns its *anchor* when
    nothing qualifies (as do a bad literal 1..127 and locators −1/−4). Offer-time eligibility
    passes anchor −1, so the mission is **never offered**; acceptance (0x0043d240) passes the
    offering stellar (in flight: the system's first nav stellar), so the mission targets the
    offering stellar. Quirks to keep: the −2 arm validates the stale pre-scan index, so its
    adjacency gate is always true; and its pre-scan skips the visibility and 0x10 tests, so a
    galaxy whose only candidates fail them spins forever (guard with a loop cap and log).
- **NovaSwift.** `Story/StoryEngine.swift:1491` `concreteStellar` (a date × spöb hash) and
  `Story/StellarMatching.swift:~17–46` (25000 selects g's own worlds; 5000-family unsupported).
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** No 10000-family mission targets a neighbour of the offering system.

#### MS-16 · Mission text wildcards — **DONE**
- **Done.** `MissionText.resolve` replaces tags in the original order with `[Error]` fallbacks, rolled `<CQ>`, STR# 4001 `<CT>`, grouped `<PAY>`, long-date `<DL>`, crossed `<PRKnnn>/<SRKnnn>`. `<OSN>` (ship hails) and `<PNN>` nicknames have no source yet.
- **Original.** `Stellar_BuildTravelDestinationDescription` 0x004444f0:
  - `<CQ>` = the rolled tonnage.
  - `<CT>` = STR# 4001 entry type + 1 of the resolved type.
  - `<PAY>` is comma-grouped (0x00465c10) with fee and percent forms.
  - `<DL>` = full month + ordinal + the chär date affixes, `[Error]` when due today.
  - `<SN>` is rolled at accept; `<OSN>` = the speaking përs; `<RRK>` = the recently activated
    rank; `<PNN>`, `<REG>`.
  - Unresolved tokens render `[Error]`.
- **NovaSwift.** `Story/MissionTextResolver.swift:~28–148` (and the `<SRKnnn>` short-name bug at
  `:134`); `Story/GameDate.swift:~60`.
- **Class.** FIX. **Impact** medium/low (`<CQ>` is the substantive one). **Confidence** high.
- **Test.** A random-quantity offer's `<CQ>` equals the tons loaded at accept.

#### MS-17 · Remaining eligibility gates — **DONE**
- **Done.** `isEligible` runs the 0x00441b40 gate order; AvailRecord reads `currentSystemReputation()`, the player's per-system reputation here (EC-02). 16 slots, duplicate `S`, per-arrival AvailRandom, përs AvailLoc 2 chain done.
- **Original** (decomp `mission.cpp` `CheckOfferingEligibility`):
  - AvailRecord uses current-system reputation; negative values require `rep ≤ value`;
    −32000/−32001 mean dominated.
  - Flags 0x2000/0x4000 test the player hull's AI type.
  - Flags 0x0008 needs fuel for one jump.
  - A PayVal credit gate; same-system denial.
  - **AvailRecord (settled, OQ D4).** Gate in 0x00441b40 against the current system's int16
    reputation: 0 passes; positive needs `rep ≥ rec`; negative needs `rep ≤ rec` (equality
    passes both ways); −32000 = the landed stellar is dominated, −32001 = some available stellar
    is dominated, both only when landed (in flight they fall through and effectively never pass);
    values below −32001 always fail.
  - **Duplicate `S` (settled, OQ D9).** `S` (operands 128–1127) takes the first free of 16 slots
    with no "already active" check and **no** eligibility chain; it resolves fresh targets, reruns
    OnStart and shows the briefing again. It fails silently with no free slot. NovaSwift has no
    16-slot cap at all (`Story/PlayerState.swift:346`, ui_rules B6).
  - AvailShipType value semantics: MS-24.
  - AvailRandom is rolled once per mission on arrival or landing at a new stellar and zeroed on
    accept.
  - përs LinkMission offers run the full chain with AvailLoc 2.
- **NovaSwift.** `Story/StoryEngine.swift:286` `isEligible`, `:~380`, `:394` (duplicate refused).
- **Class.** FIX (needs EC-02). **Impact** low-medium. **Confidence** high.
- **Test.** An AvailRecord −1 mission is offered only to a criminal.

#### MS-18 · Other SET-op semantics — **DONE**
- **Done.** `F` latch, random-entry `T`/`Q` (Q in flight → overlay, landed → close screen + launch line), `Y`/`U` countdown without OnDestroy/OnRegen, `H` keeps Flags 0x24.
- **Done (cleanup 1).** `C` changes only the class: the new hull's stock armament comes only with
  the E/H arm (the port used to arm a `C` hull; stock data uses only `H`). After E/H every owned
  outfit is clamped to its ammo and (expander-scaled) Max limit
  (`PilotEconomy.clampOwnedOutfitsToLimits`; not reproduced: the original reuses the limit
  out-parameter across outfits unreset). A mid-flight swap keeps the hull's damage and repairs a
  disabled hull one armor point at a time. `M` in flight lands on the new system's first nav
  stellar at rest, `N` keeps the position; both rebuild the system (target cleared, escorts
  re-homed). Docked, `M` launches at the first nav stellar and `N` at the docked stellar's
  coordinates. The invented relocate / new-ship HUD lines are `extraStatusMessages`.
- **Original** (0x00449370):
  - `F` only latches failed.
  - `T`/`Q` use a random STR# entry. `T` replaces `*` with the old name and keeps the name on an
    empty entry. `Q` expands wildcards into the pending-overlay buffer 0x007354d0 (settled,
    OQ D2): **in flight** it shows at the end of the same frame for 500 raw calls (≈ 10.5 s) with a
    sound, unless the player died that frame (then it is lost); **while landed** it force-closes
    the open sub-screen (BBS, trade, shipyard, outfitter) and shows at launch in place of the
    departure line (UI-11); a leftover from flight is discarded on docking.
  - `Y`/`U` set the regen countdown and do not run OnDestroy/OnRegen.
  - `R(!bN bM)` sets both bits (branch-0 skip quirk).
  - `C`/`E`/`H` clamp counts and repair a disabled hull. `H` drops outfits lacking Flags 0x24.
  - The `G`/`D` ranges and the `M`/`N` side effects are honoured.
- **NovaSwift.** `Story/StoryEngine.swift:~90–193, 160–175, 277–279`;
  `App/Story/AppGameServices.swift:~95–104`.
- **Class.** FIX. **Impact** low. **Confidence** high.
- **Test.** `F123` leaves the mission listed as failed. A `Q` fired by OnShipDone in flight
  appears immediately; one fired while landed closes the bar and shows at launch.

#### MS-19 · Random cargo quantity — **DONE**
- **Done.** `specialCount`: −1 → 0, −N → ceil(N/2) + rand(N).
- **Original.** 0x0043d4c0: −1 → 0; −N → `ceil(N/2) + rand(N)`.
- **NovaSwift.** `Story/StoryEngine.swift:1175` gives `[N − N/2, N + N/2]`.
- **Class.** FIX. **Impact** low. **Confidence** high.
- **Test.** CargoQty −10 yields 5..14.

#### MS-20 · crön news — **DONE**
- **Done.** `stationNews` returns one body by the original's local/independent rule; the Holovid falls back to STR# 8101. The disaster-report body is not composed (economy).
- **Original.** One body string. Per crön, the last allied NewsGovt string is "local";
  IndNewsStr comes only from crons with no allied NewsGovt. Priority is local > independent >
  disaster > generic STR# 0x1FA5, shown in the Holovid only.
- **NovaSwift.** `Story/StoryEngine.swift:1045` `stationNews` returns every string; `:~1018–1028`
  pushes news at crön start.
- **Class.** FIX. **Impact** low. **Confidence** high.

#### MS-21 · dësc `{…}` quirks — **DONE**
- **Done.** `NovaDescFormatter.render` is the original character machine (sticky `!`, swallowed malformed headers).
- **Original.** `Ship_ExpandStringPlaceholders` 0x0044a4d0: the `!` negate latch is never reset,
  so every conditional after the first `{!…}` is inverted; malformed headers swallow text.
- **NovaSwift.** `Kit/TextFormatting.swift:~146–181` parses each conditional independently.
- **Class.** FIX. **Impact** low. **Confidence** high.

#### MS-22 · New pilot and intro — **DONE**
- **Done.** Allied/hostile status set per government, credits ≥ 0, intro slides `ticks × 60 ms` (0…300); free IFF is now the `starterIFF` Enhancement.
- **Original.** `PilotData_InitializePlayerState` 0x004cd4b0: chär Govt/Status sets reputation of
  systems allied to that government to Status, and hostile ones to −Status. Credits are clamped
  ≥ 0. Intro frames last `ticks × 60 ms`, clamped 0..300 (stock 45 → 2.7 s). The Strict Play
  checkbox lives here (FL-03).
- **NovaSwift.** `Story/PilotFactory.swift:~147–161` (record arithmetic), `:109–121` (free IFF),
  `App/Pilots/IntroSequenceView.swift` (seconds, clamped 2..7).
- **Class.** FIX+ENH → `starterIFF`. **Impact** low. **Confidence** high.

#### MS-23 · Daily order and leap years — **DONE**
- **Done.** `advanceDays` uses the original order with the salary clamp. The calendar stays Gregorian, identical to `year & 3` for 1101–1299 (persisted day stamps rely on it).
- **Done (cleanup 1).** Escort fees left the day (EC-20), so the tick is date → crön → tribute →
  disasters → regen → salary as in 0x00466cb0. Deadlines are absolute dates (no countdown work)
  and the stock rolls derive from the date (EC-11).
- **Original.** Date → crons → deadlines → tribute → disasters → stellar regen → salary
  (clamped after each) → rerolls. A leap year is `year & 3 == 0`.
- **NovaSwift.** `Story/StoryEngine.swift:744` `advanceDays` uses date → salary → tribute → escort
  fees → crons → disasters → regen → deadlines, with a Gregorian JDN (identical for 1101–1299).
- **Class.** FIX. **Impact** low. **Confidence** high.

#### MS-24 · AvailShipType value bands — split out of MS-01 and MS-17 — **DONE**
- **Done.** `shipTypeMatches`: 128…896, 1128…1896, 2128…2384 (combat or attributes govt), 3128…3384, per the 0x00441b40 edges.
- **Original** (decomp `mission.cpp` `CheckOfferingEligibility`): four bands with these exact
  edges: 128..896 = the player flies that ship; 1128..1896 = the player does **not** fly
  `value − 1000`; 2128..2384 (0x850–0x950) = the player hull's inherent government is
  `value − 2000`; 3128..3384 (0xC38–0xD38) = it is **not** `value − 3000`. Anything else passes.
- **NovaSwift.** `Story/StoryEngine.swift:375` `shipTypeMatches` handles 128...895 and
  1128...1895 (one short of the original upper edges) and accepts every government-band value.
- **Class.** FIX. **Impact** low-medium (stock: the 86 ship-restricted missions of MS-01).
  **Confidence** high for the bands; confirm the inclusive upper edges (896/1896) in 0x00441b40
  before shipping.
- **Test.** A mission with AvailShipType 2128 + g is offered only to a pilot whose hull's
  InherentGovt is g; 3128 + g never is; 896 matches shïp 896.

#### UI-04 · Exploration levels; maps count as explored — merges ui_rules A2, A13, B5 — **DONE**
- **Done.** Charted systems satisfy `E`; `landedSystems` is level 2 (map services, else STR# 2002 #310); new pilots know the start's visible neighbours; maps reveal by the original DFS through declared links and fire nebula events.
- **Original.** One `discovery_state` per system (pilot block 1 +0x1a): 0 unknown, 1 arrived by
  hyperspace (0x0044aa70), mission `X` (min 1), and at new game the start system **and every
  visible adjacent system** (0x0048a17e / 0x0048a1a0); 2 landed (0x00455e10) or revealed by a map
  outfit (ModType 16, 0x00427770 → `System_RebuildSystemVisibilityMap(cur, ModVal, 2)`). Writes go
  to the twin "discovery slot". NCB `E` tests `> 0` (0x00448be0), so **a bought map satisfies
  `Exxx`**. Level 2 gates the map's Goods Traded / Services panel (level 1 shows "<Unknown>",
  STR# 2002 #310). The map reveal is a **DFS** with one global visited mask (0x00467ab0), so it
  can reveal less than the true N-jump radius (quirk); it stops at NCB-hidden twins and fires each
  reached system's nebula region events (OS-14). ModVal −1 needs government −1 plus a nav stellar
  with travel flags 0x20 and availability 0x3000 clear (0x00468af0).
- **NovaSwift.** `chartedSystems` is deliberately excluded from `E` (`Story/PlayerState.swift:213–222,
  578`; `Story/NCBExpression.swift:229`); a new pilot starts with only the current system
  explored (:390); no level 1/2 distinction; exact BFS reveal without twin filtering or region
  events (`MapReveal.swift:46–64`), and ModVal −1 uses `spob.canLand`.
- **Class.** FIX. Charts stay consumable and re-buyable (existing user ruling); only their effect
  on `E` and the level changes. **Impact** high (story gates). **Confidence** high.
- **Test.** Buying a 3-jump map makes `E` true for a charted system; a new pilot's start
  neighbours test explored; a system only jumped through shows "<Unknown>" services.

#### OS-14 · Nebula ActiveOn / OnExplore — **DONE**
- **Done.** `NebuRes` decodes ActiveOn/OnExplore; `exploreNebulae` runs on arrival, multi-jump hops and map reveals, once per nebula.
- **Original.** `Frame_TriggerSystemRegionEvents` 0x00467bd0: reaching a system inside an active,
  unexplored nëbu rect (inset 8 px) runs its OnExplore script once. It also fires for every system
  a map reveal reaches and every intermediate multi-jump hop (UI-04, FL-06).
- **NovaSwift.** `NebuRes` decodes neither field (`Kit/NovaModels.swift:586`).
- **Class.** FIX. **Impact** medium-low (plug-ins and story). **Confidence** high.
- **Test.** A plug-in nebula with OnExplore `b500` sets b500 on the first arrival in a covered
  system.

### Batch 6 — the AI state machine

#### AI-18 · Port the two-level state machine — **DONE**
- **Status.** `Engine/OriginalAI/` (`OriginalAI` + supervisors, state machine, controls) drives every brained NPC by default; `AIBrain` runs under `novaSwiftAI`. Period and state-0x13 roll modelled; per-behavior traces are unit tests, not oracle goldens yet. **Merge wiring:** `WorldAIHost` now reads Batch 3's AI-05 ladder (`Diplomacy.reputationLadderFlagsPlayer`, current-system reputation; xenophobe arm on `reputationHere`), `GovtRelations` allied/hostile (a government is its own ally, as 0x0046bc90), the AI-07 grudge (`Ship.personFlags` 0x0001), Batch 2's lethal-weapon rule (`AIBrain.hasLethalWeapon`), ModType-37 fast jump (`Ship.instantJump`), and routes AI-06 responders into state 4 (`OriginalAI.joinAttack`). Still adapter-side: the EC-15 scan gate. AI pass 2 closed the rest: the comm window (AI-42/43/44), escort category groups (AI-35), the boarding capture arm and the player's boarded latch (AI-29). **Determinism:** the headless sim is a pure function of its seed (`SimulationDeterminismTests`); loadout outfits and fighter bays are walked in id order, and `novaswift-extract ai` has `NOVASWIFT_SIM_DIGEST=1` to diff two runs phase by phase.
- **Original.** `Ship_UpdateShipAI` 0x00401000 dispatches. `Ship_UpdateShipAiState` 0x00405590
  selects `ai_state_code` 0x00–0x16 and `ai_control_mode` 0x00–0x17 each frame;
  `Ship_ApplyShipAiControls` 0x00408150 executes. Four behavior supervisors drive it (Wimpy
  0x00402860, Brave 0x00402bd0, Warship 0x00402e50, Interceptor 0x00403de0) plus escort, defense,
  miner and plunder supervisors. Heavy decisions are throttled by
  `frame % g_ai_update_period == instance % period` (0x00401242).
  - **Period (settled, OQ A6).** It is the frame-quality level `DAT_00591184`: 1 while the
    averaged scale is ≤ 1.0 (which includes the 21 ms floor), 2 up to 1.3, 4 up to 1.7, 8 above.
    On real hardware every ship re-decides every raw call. The skip applies only when control ∉
    {0, 0xf, 0x11, 0x14} and state ∉ {0, 8, 9, 0xf, 0x12}. Squad leaders refresh escort orders
    every 8 raw calls, bucketed by slot/8.
  - **State 0x13 (settled, OQ A7).** Each call rolls `Rand(trunc(100/avg)) == 0` (`Rand(100)`
    when avg ≤ 0) to return to state 0 (≈ 1/100 per 30 Hz tick, mean dwell ≈ 3.3 s); otherwise
    the heavy AI is skipped and controls are kept.
- **NovaSwift.** `Engine/AIBrain.swift:530` `think`, with a 13-state `AIState` (`:24`).
- **Class.** FIX (replace). Keep `AIBrain`'s invented layers only behind the toggles in §3.
  **Impact** high. **Confidence** high.
- **Test.** Per-behavior golden traces of state/mode over scripted encounters.
- **Quiet-system check (2026-10-10).** Headless `novaswift-extract ai <base> <sys> 60` on systems
  128, 300 and 160 fires no shots under the original AI, and that is the data, not a regression:
  none of them ever holds a mutually hostile NPC pair (Kania 128 = Federation + Civvies; Dani
  Evera 300 = Family Dani + Civvies; Jenner 160 = one Civvies Leviathan squad under original
  spawning — the port's 85 shots there are a pirate it spawned shooting the *player*). A sweep of
  all 536 systems (60 s each, original AI): 39 systems ever hold a hostile NPC pair and 36 of them
  see fire; 73 systems fire overall (11.9 k shots vs 13.1 k for `NOVASWIFT_AI=port`). The 3 quiet
  ones are original rules: 139 and 377 pair only traders (AI 1/2 never acquire, AI-19), and 544's
  Fed Carrier chases an unarmed Polaris Sprite that jumps out before closing to gun range while its
  launched fighters hold station (`Ship_ScoreAssistTargetForShip` 0x00412090 only assigns ships
  pressing the leader). The `ai` command now prints the peak hostile-pair count, and
  `NOVASWIFT_AI_TRACE=1` dumps every NPC's behavior/state/mode/primary every 5 s. Guard test:
  `OriginalAITests.testEnemyWarshipsTradeFireWithinFiveSeconds` (warship and interceptor pairs
  of governments at war must both fire within 150 ticks).

#### AI-19 · Traders escalate only after damage — **DONE**
- **Status.** Traders escalate only on damage (`noteHit`); brave traders fight inside 1251 px per axis.
- **Original.** Behaviors 1/2 never acquire targets. They escalate when the hostility accumulator
  > 0 with a primary target (written by `Ship_ApplyDamageToShip`). Wimpy → retreat. Brave → attack
  only if the attacker is within **1251 px per axis** and not jumping, else retreat. In state 4 a
  trader whose target can outrun it (`Ship_CanTargetOutrunShooter` 0x00410f20) retreats.
- **NovaSwift.** `Engine/AIBrain.swift:~563, 601–609` (proximity flee within 1500 px; brave
  traders attack unprovoked).
- **Class.** FIX. **Impact** high. **Confidence** high.
- **Test.** A wimpy trader ignores a passing pirate until it is shot.

#### AI-20 · Retreat thresholds — **DONE**
- **Done** (pulled forward into Batch 3). `AIBrain.shieldRetreatThreshold`: govt Flags 0x0010,
  no squad leader, in a fight; cadence 1 → 30 %, 2 → 15 %, else never; përs Coward %; odds arm
  below 50 % shields when `oddsScore` > MaxOdds, warships on Flags 0x0010, interceptors on 0x0100.
  Not yet: the ×2 MaxOdds while an allied ReinfFleet cools down, and the ammo-out stand-down.
- **Status.** Cadence 30 %/15 %/never, përs Coward, odds arm (0x0010 / interceptors 0x0100), ammo-out. The MaxOdds threshold doubles while an allied ReinfFleet countdown runs (`Spawner.reinforcementInbound`). The cadence is the Spawner's spawn-time seed (`AIBrain.cadence`: `Rand(3) XOR 2` dudes, 2 class escorts, përs Aggress clamped); the AI only draws for a brainless ship.
- **Original.** 0x00402e50 (exe-verified):
  - Shield retreat needs government Flags 0x0010 and no squad leader. The threshold is cadence
    1 → 0.3 × max, 2 → 0.15, else never. Ordinary NPCs seed cadence `Rand(3) XOR 2` ∈ {2, 3, 0},
    so a third retreat at 15 % and two thirds never do.
  - përs: Coward % × max.
  - Odds arm: below 50 % shields with odds > MaxOdds (× 2 while an allied ReinfFleet is cooling
    down). Interceptors (0x00403de0) retreat on this arm only with government Flags 0x0100.
    **Settled (OQ D5):** the same bit also stops përs of that government from emitting an escape
    pod (0x00433050); keep both consumers.
  - **Cadence (settled, OQ D10).** `Rand(3) XOR 2` at 0x00425711 and 0x0041bf32 is literal;
    escorts spawned from a class get 2, the maintenance writer 4, përs their clamped Aggress.
  - Ammo-out (Flags2 0x0080) → retreat; no ready weapon → stand down.
- **NovaSwift.** `Engine/AIBrain.swift:575` (flat 25 %).
- **Class.** FIX. **Impact** high. **Confidence** high.
- **Test.** The retreat-at-15 % share across 300 spawns is about 1/3.

#### AI-21 · përs Aggress and the player-acquisition box — **DONE**
- **Status.** Player-acquisition box `cadence × 600` per axis; përs Aggress clamped 1/2/4.
- **Original.** Aggress is copied into the cadence field (clamped 1, 2, ≥ 3 → 4) and consumed as
  the player-acquisition box `cadence × 600` px per axis (600 / 1200 / 2400). For ordinary NPCs
  the same field gives 1200 / 1800 / 0.
- **NovaSwift.** `Engine/AIBrain.swift:873` (standoff × 0.4/0.7/1.0) and `:141` (fixed 1500 px
  scan).
- **Class.** FIX. **Impact** medium-high. **Confidence** high.
- **Test.** An Aggress-1 përs engages the player only within 600 px per axis.

#### AI-22 · NPC hyperjump in place — **DONE**
- **Status.** Brake, mode 3 out of the centre, mode 4 spin-up for the Warp-up cue / multiplier, position ramp, vanish in place (`Ship.departsInPlace`). Jump-ins slide at 50 px/tick − 1.165 per *raw call* (the override runs once per 21 ms call with no frame scale, 0x00433050, so the slide is ≈ 700 px and ships rest ≈ 1400 px out, not at the spawner's assumed 1000; the hand-back speed is the last call's) from where the Spawner placed them (AI-12 owns the pose: `OriginalSpawnRules.jumpInRadius` = 2098.004 px with the exe's 1.165, escorts ±150 px, mission ships ±256 px); the AI no longer re-places them at 2102.64.
- **Original.** State 2 brakes to < 0.35 px/tick. Mode 4 then points outward from (0,0) and spins
  up for `JumpSequenceDuration60Hz / classMultiplier` (≈ 6.08 s base; FL-04) before deactivating.
  Inside 1000 px of the centre it first thrusts outward (mode 3). Retreat uses the same sequence
  once the attacker is beyond 251 px per axis, and mode 5 (away from the attacker) inside it.
- **NovaSwift.** `Engine/AIBrain.swift:990` `depart`, `:964` `flee` (cruise to jumpRadius, despawn
  at the edge).
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** A departing NPC stops, turns outward and vanishes about 6 s later.

#### AI-23 · Idle loop (traders, warships, interceptors) — **DONE**
- **Status.** Idle ladder, literal picker, gate preference, coast 300–499 / 100–174, park without fuel; NPCs never land. The parked engine-glow fade and fold animation are not reproduced.
- **Original.** `NovaAi_ReacquireTravelOrSettle`:
  - Pick a uniformly random nav stellar (0x0040c790) that is not uninhabited, not hostile, and has
    `x < 1000 && y < 1000` — literal signed 16-bit compares with no lower bound, so any
    negative coordinate passes (settled, OQ A8).
  - **NPCs never land (settled, OQ D1).** Arrival parks the ship: it stops, sets velocity to 0,
    fades its engine glow and sits inert (drawn, collidable, targetable, not firing) for
    `Rand(200) + 300` ticks (`Rand(75) + 100` with Flags3 0x0002); folding hulls play their fold
    animation. No path deactivates a ship for reaching a stellar.
  - Government Flags2 0x80 / 0x40 **always** pick a wormhole / hypergate when one exists (state
    0x14).
  - Fly to within `(9 − min(turn°, 8)) × 8 + 32` px per axis, damp × 0.98 to a stop, coast
    300–499 ticks (100–174 for Flags3 0x2), then jump out (or park in state 6 without fuel).
  - Warships do the same when targetless. Interceptors pick non-gate stellars and park.
- **NovaSwift.** `Engine/AIBrain.swift:1732` `pickPlanetBody` (1/distance weighting), `:1123`
  `patrol`, `:778` (55–135 s duty timer), `:1141` `orbit` (radius + 320), `:1017`
  `pickDepartureGate` (35 % / 4 %), pass-through (`Engine/Spawner.swift:629`).
- **Class.** FIX+ENH → `livelySystemAI`, `hypergateTraffic`. **Impact** medium.
  **Confidence** high.
- **Test.** Idle warships visit a stellar, stop, coast 10–17 s and jump out.

#### AI-24 · Interceptor scanning — **DONE**
- **Status.** Uniform random same-system mark, 100 px box, cached-target exclusion; the SmugPenalty / 76 % gate sits in the adapter until EC-15.
- **Original.** An idle, targetless interceptor (states 0/1/0x14, maneuver timer ≤ 0) picks a
  **uniformly random** active same-system non-interceptor that is not its last scan target. It
  approaches to within 100 px per axis (state 7), clears the target and calls 0x00401800 (EC-15).
  There is no per-visit latch.
- **NovaSwift.** `Engine/AIBrain.swift:1818` `pickScanTarget` (player first, latched once per visit
  at `Engine/World.swift:1153`), `:1158` `scan` (240 units, 22 s / 18 s cooldowns); system
  authority only.
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** Interceptors scan NPC traders too, and can re-scan the player later in a visit.

#### AI-25 · Combat manoeuvring control modes; swarm and standoff — **DONE**
- **Status.** Modes 5/6/7/0xe/0x10/0x11/0x12, swarm mate, standoff 0.85 ×. Fire requests go through the AI-02 selectors (`WorldAIHost.steerFire` → `ControlIntent.npcMounts`: one forward bank, guided › direct › unguided › general, plus the turret bank). Pursuit and strafe aim with `Ship_AimWeaponPredictive` on the last armed forward bank (`activeBank`, standing in for +0x72 / +0xc8da), the straight bearing for a non-projectile bank.
- **Original.** State 4:
  - Within 165 px per axis: mode 6 pursuit, with evasive break 0x10 (± 135°, 1.5 × thrust) and
    boost 0x11 (2.75 × thrust, 1.8 × max).
  - Beyond 165 px: mode 7 strafe. If the target can outrun the shooter, warships brake (mode 0xe)
    and traders retreat.
  - Swarm hulls (Flags2 0x0001) follow a swarm mate at a 15 × max-speed lead (0x12; 0x00411c20 /
    0x00411b40 / 0x00411ae0).
  - Standoff hulls (Flags2 0x0002) hold 0.85 × max weapon range (halved against a disabled
    target).
  - Carrier-bay launch and assistance triggers run each frame (0x00406bc2).
- **NovaSwift.** `Engine/AIBrain.swift:~842–960` (single standoff at 0.7 × min range).
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** A Flags2-0x0002 hull holds at 85 % of its longest range.

#### AI-26 · NPC afterburner is a hull flag — **DONE**
- **Status.** Hull Flags 0x0040/0x0020/0x0400 and përs 0x0002 set the spawn latch for mode-0x11 boosts.
- **Original.** `Ship_CanShipUseAfterburner` 0x0046b260: shïp Flags 0x0040 → always; 0x0020 →
  `Rand(0x540) + 0x100 ≤ rating/2`, rolled at spawn; 0x0400 → never; blocked when the ship is
  someone's swarm mate; përs Flags 0x0002 forces it. It is used for mode-0x11 boosts.
- **NovaSwift.** `Engine/AIBrain.swift:837` `canBurn` (outfit plus fuel > 15 %).
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** A Flags-0x0040 hull without an afterburner outfit boosts in combat.

#### AI-27 · Cloak triggers — **DONE**
- **Status.** All seven triggers drive `Ship.cloakEngaged`.
- **Original.** `Ship_UpdateShipCloakStateFromTraits` 0x00411d00 evaluates each Flags2 bit:
  - 0x0100: a bank reloading longer than its reload time;
  - 0x0200: retreat;
  - 0x0400: jump states;
  - 0x0800: travel/park;
  - 0x1000: stays cloaked in state 4 until within 165 px;
  - 0x2000: state 0;
  - escorts mirror a cloaked leader.

  The 0x4000 bit re-arms bursts and cloak when attacked.
- **NovaSwift.** `Engine/AIBrain.swift:805` cloaks iff fleeing.
- **Class.** FIX. **Impact** medium. **Confidence** high.

#### AI-28 · Target retention — **DONE**
- **Original.** 0x0040e149: a target is kept while active in state 3/4, with no distance cutoff.
- **NovaSwift.** `Engine/AIBrain.swift:540` drops it beyond 2250 px.
- **Class.** FIX. **Impact** low-medium. **Confidence** high.

#### AI-29 · Plunder-government boarding — **DONE**
- **Status.** Victim search, 3 px approach, 100–179-tick pause, yield, coast. `World.npcBoard` (0x00412550): boarding ratio `trunc(crew × 100 / (victimCrew × 2))` ± negative marines + `10 − Rand(21)` in [10, 100]; random-slot cargo transfer into the boarder's free hold; an NPC victim's credits zeroed; a boarded player gets `.shipBoarded(0)` (Flags 0x8000 missions fail) and `.playerBoarded`, and the host takes cargo and `trunc(credits × ratio × 30 × 1e−4)` credits with the STR# 2002 #391/#373/#392/#374 line. **Fix (AI pass 2):** the player has no AI record, so a boarder's 3 px latch on the player (+0xb9) never set and a pirate that disabled the player hovered over it forever; the latch is now kept for the player too (`OriginalAI.playerBoardedLatch`), so the boarding fires and the player isn't boarded twice in a visit. **Capture arm (AI pass 2):** a non-mission NPC victim at ratio ≥ 41 is taken on `Rand(101) ≤ ratio × 0.5` — it joins the boarder's wing (its government, behavior 6, përs cleared, 150-tick coast, shields 0, armor × 0.66); when it was the player's escort every ship targeting it stands down, the roster loses it and the HUD reads "Escort stolen!" / "Fighter stolen!" (STR# 2002 #168/#169 + #374; the fighter/escort split is read as carrier-launched vs other).
- **Original.** 0x004038b0: government Flags 0x1000 warships seek disabled boardable victims (the
  player, or a class with AI < 3 and crew > 0). They close to 3 px (mode 0xf), wait 100–179
  ticks, and board (`Boarding_BoardShipAndTransferCargo`). Competitors yield (state 0x16, 120
  ticks).
- **NovaSwift.** Missing (`GovtRes.plundersBeforeKilling` is decoded and unread).
- **Class.** FIX (needs WP-03). **Impact** medium. **Confidence** high.
- **Test.** A disabled player is boarded by a Flags-0x1000 pirate and loses cargo.

#### AI-30 · Defense-fleet AI — **DONE**
- **Original.** 0x00405120: garrison ships prefer the nearest player-side ship (the player or a
  `squad_leader == 0` ship) within 6000 px, then the nearest anywhere, and return home when there
  is none. Hits from attackers closer than half the stellar distance count 30× hostility.
- **NovaSwift.** `Engine/AIBrain.swift:~650` (`.attackPlayer` only).
- **Class.** FIX. **Impact** low-medium. **Confidence** high.

#### AI-31 · Asteroid miners — **DONE**
- **Status.** Wander and the asteroid manoeuvre; **AI pass 2:** a scooper (Flags3 0x0002 with a scoop and hold room) goes to state 0x11 whenever OS-11 boxes are adrift, mode 0x15 steers at the nearest box (truncated squared distance; thrust inside turn + 15°, else a 1.75 × thrust per-axis bleed; no box → mode 0), and a state-0x11 NPC touching a box scoops it (commodities into its hold; junk counts only for the player, 0x004374f0).
- **Original.** Flags3 0x1/0x2 with no leader runs 0x00402980 (state 0x10 manoeuvre, 0x11 debris
  pickup, nearest-stellar wander via 0x0040cc10).
- **NovaSwift.** Missing.
- **Class.** FIX (needs FL-16 boxes). **Impact** low. **Confidence** high.

#### AI-32 · Taunts — **DONE** (they are distress calls)
- **Done (AI pass 2).** `Ship_ShowPlayerInterceptTauntIfEligible` 0x004112c0 is a distress call:
  a non-përs ship whose government and hull inherent government lack flags_secondary 0x08,
  that likes the player (0x0040fd20), is not attacking them, is uncloaked, with the player alive
  and no overlay message up (`DAT_00597a12`, every overlay sets it; `World.overlayTicks`,
  counted in raw calls), flashes "<class name>:  <STR# 5003 'Ship Help Messages' Rand(20)>" for
  240 frames. Wimpy and brave traders call it every tick they retreat, a brave trader also while
  attacking a warship, a miner when it turns to retreat; the overlay gate keeps it to one message
  at a time (`OriginalAI.distressCall`). The interceptor's line is the scan warning: picking the
  player as its scan mark while the player carries mission cargo whose ScanMask matches its
  government, with no overlay up, it flashes "<class>:  <pilot>, <STR# 2002 #381–#383>!" for 400
  frames (`OriginalAI.scanWarning`; the app supplies `World.missionCargoScanMask` and the pilot's
  name). App-side HUD lines don't hold the gate; only overlays the engine posts do.
- **Original (corrected).** The audit's "STR# 0x138b taunt on entering retreat or attack against
  behavior > 2" reads the same function; 0x138b is STR# 5003, the help messages. Mission ships
  speak with their ShipName.

#### AI-33 · Per-axis box distance metrics — **DONE**
- **Status.** Inside the AI.
- **Original.** Most AI gates are per-axis boxes (165, 251, 1251, 100, cadence × 600, arrival).
  Acquisition distance is `floor|dx|² + floor|dy|²`.
- **NovaSwift.** Euclidean throughout.
- **Class.** FIX (applies across Batch 6). **Impact** low. **Confidence** high.

#### AI-34 · Request Assistance — **DONE**
- **Status.** States 9 (1.0 fuel/tick to 100) and 0x0F (repair); the whole decision tree, its lines and the payment run through the original comm window (AI-42, `OriginalAI.pressAssistance`). The port's flat tiers (`assistanceTier`) remain only under `novaSwiftAI`; no separate `modernRequestAssistance` toggle was added since that path already sits behind the AI enhancement.
- **Original.** 0x0047e470 and `Ship_DoesShipLikePlayer` 0x0040fd20:
  - "In your dreams, pal." when the ship dislikes the player, is xenophobic, or is a warship of a
    Flags-0x1000 government.
  - Busy ships answer "I'm busy." or "Sorry sir, I can't do that.".
  - With no threat, the ship helps only if fuel < 100 or the player is disabled (otherwise "You're
    not in any trouble."). Help is paid via the bribe formula through the interactive payment
    window (AI-42; free with government flags_secondary 0x10) and is state 9 (fuel at 1.0/tick
    to 100) or state 0xF (repair at +1.0 armor/tick). "Fuel < 100" also requires fuel capacity
    > 0.
  - With a threat: behavior 1 "I'd rather not."; behavior 2 only if faction-less and
    `instance % 3 == 0`; behavior 3/4 help for pay and attack a random threat.
- **NovaSwift.** `App/Game/GameScene.swift:1609` `assistanceTier`,
  `App/Game/GameContainerView.swift:~725–743, 2877`, `Engine/World.swift:~3603`.
- **Class.** FIX+ENH → `modernRequestAssistance`. **Impact** high. **Confidence** high.
- **Test.** A disabled player who pays a trader is repaired over time.

#### AI-35 · Player escort orders — **DONE**
- **Status.** Formation default, Defend 550 / 639 px, Attack copies the target, Hold, turret-only formation escorts. **AI pass 2:** `OriginalAI.commandPlayerEscortGroup` ports 0x0045c880 — each escort keeps its own order (+0xc90a, `playerOrder`); an order goes to one EscortType group or all; Return to Hangar reaches carried fighters only and sends anyone else not already in formation back to Formation; a fighter heading home is turned round by any other order; the HUD reads "New escort orders assigned: <group> <action>" (STR# 2002 #134–#159, the jump-time variants included) for 250 frames. The escort window, under the original AI, gains a group selector (All → Fighters → Medium → Warships → Freighters, STR# #140–#144) and a Return to Hangar button, and labels its four buttons Attack / Defend / Formation / Hold Position. The port's whole-wing orders remain under `novaSwiftAI`. The original's combat chatter voice (Frame_QueueCombatChatter) is not played.
- **Original.** `Ship_CommandPlayerEscortGroup` 0x0045c880:
  - 0 Formation is the default. **Settled (OQ D8):** formation escorts fire **turrets only**
    (guidance 3/4/7/8) through `Ship_EscortFireAtUnprovokedTarget` 0x00411540, at a uniformly
    random same-system ship currently pressing an attack (0x00410900); never forward guns or
    guided weapons. Control mode switches at 300 / 600 px per axis from the leader.
  - 1 Defend: engage within 550 px of the leader, drop beyond 408375 px² (≈ 639 px).
  - 2 Attack: copy the player's target unless it is a squad member, else the best assist target.
  - 4 Hold: park, turrets still fire.
  - 3 Return to Hangar: fighters only.
  - Orders go per EscortType category (inferred: freighter if AI < 3, else fighter < 50 t, medium
    < 200 t, else warship), with group keys 1..5 (0x00450710).
- **NovaSwift.** `Engine/World.swift:3111` `setPlayerEscortOrder`; `Engine/AIBrain.swift:~661–725`
  (Aggressive/Defensive/Evasive/Hold, whole wing, default Defensive).
- **Class.** FIX+ENH → `modernEscortOrders`. **Impact** medium. **Confidence** high.
- **Test.** New escorts hold formation and do not fire.

#### AI-36 · NPC-fleet escort order table — **DONE**
- **Status.** Literal index-1 probe read from wëap 0x81.
- **Original.** `Ship_IssueEscortOrders` 0x004152e0, keyed on leader behavior, leader shields
  (< 0.33 / < 0.66), the target state and odds, with categories 0–3. The literal wëap-index-1
  envelope makes "target outranges leader" dead. The fighter envelope is Medium Blaster 350 + 32,
  not the decomp's 382 px.
- **NovaSwift.** Always `.defensive` (`Engine/World.swift:~1483`).
- **Class.** FIX. **Impact** medium. **Confidence** high.

#### AI-37 · Leadership succession — **DONE**
- **Original.** `Ship_ReacquireSquadLeader` 0x004156a0: the heaviest active, non-disabled sibling
  leads. It inherits targets and state when the government matches, otherwise uses the state map.
  Fighters become behavior 6. With no sibling, a ship reverts to its default AI in state 0x13.
- **NovaSwift.** `Engine/AIBrain.swift:~724, 1267–1273` (fleet scatters).
- **Class.** FIX. **Impact** medium. **Confidence** high.

#### AI-38 · Escort persistence across jumps — **DONE**
- **Done (AI pass 2).** `GameScene.carryEscortsThroughJump` (before a jump replaces the world):
  a disabled escort is lost (dropped from the roster); the others keep shields, armor, fuel,
  per-mount ammunition and docked fighters into the next system, where they take the player's
  heading, drop in `OriginalSpawnRules.escortJumpLag` (Σ(45 − 1.165k) ≈ 892 px) behind their
  formation slot and arrive with the 50 px/tick jump-in slide. A takeoff still respawns the wing
  fresh and on station (a launch refills, as the original's).
- **Done (fidelity cleanup).** A non-mission ship in the player's wing leaves it the moment it
  is disabled (`World.leaveWingWhenDisabled`, 0x004192d0): it takes its class's AI and remembers
  it was a bay fighter or an escort (`Ship.formerWingRole`, the original's `+0xc8de`). A
  freighter escort (InherentAI < 3) first takes its share of the fleet's cargo
  (`.escortLeftWingDisabled` → `PilotEconomy.transferCargoToEscort`, 0x00469810; commodities ride
  on the hulk, junk is lost). Its repair system (ModType 49) brings it back with shields 0 ("Escort
  repaired." / "Fighter repaired.", STR# 2002 #127/#128, `World.rejoinWing`); boarding it with room
  in the wing repairs it at `max/3 + 1` armor and returns its cargo, and a former fighter — or any
  hulk of a class a player bay launches and has room for — goes straight into the bay ("Fighter
  captured.", #129; `World.recoverOnBoarding`, 0x0045a3d0 / 0x004694a0 / 0x00415ea0). A dropped
  escort never repaired stays behind at the next jump (its roster record goes, silently); one
  destroyed afterwards takes no second cargo share. Bay fighters no longer count toward the
  six-escort limit (0x00468920 counts behavior 6 only). The gate-arrival hold is AI-12.
- **Approximations.** Bay capacity matches the fighter class exactly (the original also accepts
  a class with the same `+0xa08` group); the `+0xbb` hired/captured distinction across a repair is
  not kept.
- **Original.** 0x0041af90: on jump arrival escorts keep shields, armor and ammo (only a launch or
  shipyard pass refills). Disabled escorts are lost (freighters hand cargo over first). Escorts
  arrive about 892 px behind (Σ(45 − 1.165k)), flung forward at 50 px/tick.
- **Class.** FIX. **Impact** medium-high. **Confidence** high.

#### AI-39 · Mission-escort përs link quirk — **DONE**
- **Done (AI pass 2).** Accepting a përs's LinkMission with përs Flags 0x0040 and a one-ship
  mission now replaces the përs ship with the mission's ship (its own hull when the dude flies
  it) on the same pose (`World.replaceWithMissionShip`, 0x00454910). The replacement is not linked
  to the player — the original makes ShipBehav-1 ships escorts only while building a system — so
  it joins at the next jump (known bug #119). Enhancement `immediateMissionEscortLink` links it
  at once.
- **Original.** Known bug #119: a përs LinkMission ShipGoal-3 replacement is not linked to the
  player until the next jump.
- **Class.** FIX+ENH → `immediateMissionEscortLink`. **Impact** low. **Confidence** high.

#### AI-40 · Formation geometry — **DONE**
- **Status.** Spacing, 20-slot table, truncated heading, 10 × thrust creep with an 8 px deadzone.
- **Original.** 0x00413990 / 0x00413b60 / 0x00414390:
  - Spacing `v = clamp(trunc(max sprite span × 0.7), 24, 60)`.
  - A fixed 20-slot table starting at (∓v, −v); slots beyond it sit at (0, 0).
  - Offsets use the leader's truncated integer heading.
  - Followers creep per axis at thrust × 10 px/tick with an 8 px deadzone.
- **NovaSwift.** `Engine/AIBrain.swift:1222` `formationStation` plus velocity glue.
- **Class.** FIX+ENH → `formationFlying`. **Impact** low (visual). **Confidence** high.

#### AI-41 · NPC personality defense scale — **DONE**
- **Original (settled, OQ B3/B7).** NPC max shield = class Shield × përs ShieldMod (if > 0 and
  the ship is a përs) × 1.333 if behavior 5, float-rounded (0x00463550); max armor the same
  (0x004637a0). Shield regen = `ShieldRe × 0.001`, × 1.333 for behavior 5, **no** përs scale
  (0x00463680). Armor regen = `ArmorRe × 0.001`, **no** 1.333, no përs scale, 0 when disabled
  (0x004638e0). Neither regen sums DefaultItems; the decomp's NPC DefaultItems regen and 1.333
  armor regen are its own divergences. This ×1.333 pool is the whole of the community's "bay
  fighters take 75 % damage". It also applies to captured or surrendered escorts that become
  behavior 5.
- **NovaSwift.** Partially present (commit 9a7c0f9 applied the personality defense multiplier).
- **Contradiction.** outfits_special's mapping table applies ×1.333 to regen generally; OQ B7
  (disassembly-level) limits it to shield regen. B7 wins.
- **Class.** FIX for the remainder. **Impact** low-medium. **Confidence** high.
- **Done.** Bay fighters get the behavior-5 × 1.333 (OS-03). It follows the behavior, as the
  original computes the pools live: a player fighter that drops out disabled loses it
  (`Ship.removeCarriedFighterScale`) and regains it when repaired back as a fighter; a fighter
  captured or recovered by boarding is docked, so it gets the scale when next launched (AI-38).
  The përs ShieldMod arm scales max shield and armor by the Float32 `ShieldMod / 100` when > 0;
  a negative ShieldMod scales nothing and refills shield and armor every call
  (`Ship.refillsDefensesEveryTick`, 0x00433050) instead of the port's old 1,000,000-point shield.

### Batch 7 — player-facing rules: map, targeting, landing flow, HUD text, Player Info, keys

Common root cause across this batch: NovaSwift hard-codes English where the original reads STR#
2002 / 3000 / 3002 / 134 / 137 / 138 / 150 / 1000, so total conversions that re-text those
resources have no effect. Every string fix below reads the resource, never a copy of its text.

#### UI-05 · Route plotting is manual — ui_rules A1 — **DONE**
- **Done.** `Engine/StarMapRoute.swift` (click arms one linked system, Shift+click extends from the
  tail / truncates / clears, 31-hop cap, arrival pops and re-arms) behind `NavigationModel.plan`;
  J with nothing armed posts #29 (#10 without fuel), H re-arms, selecting a stellar disarms (the
  shared travel channel). Touch devices: a second tap on the selected system acts as Shift+click.
  The ship turns toward the armed first hop. BFS, Nearest System and J-opens-the-map are
  `autoRoutePlotting`. Not reproduced: the full-route quirk that overwrites hop 1.
- **Original.** In the star map (0x004a3aa0, inner loop 0x004a4353) a plain click arms only a
  **directly linked** system (mode 3 + link slot); a click elsewhere moves the selection and
  clears the armed slot. Multi-hop routes are built by hand with **Shift+click**, one adjacent hop
  at a time from the route tail, into a `short[0x20]` (current system + at most 31 hops).
  Shift+click on a plotted hop truncates there; on the current system it resets. Clicks count
  only on a latched system (visited, or one hop from a visited one), a mission target or the
  current selection; anything else starts a drag-pan. Arrival pops the route head (0x004a7fc0).
- **NovaSwift.** Any tap runs a BFS fewest-jumps path through `visibleNeighbors`, which keeps
  **unexplored** systems, so routes leak unseen geography (`NavigationModel.swift:94–99, 191–218`;
  `GalaxyMapView.swift:710`); no Shift+click editing, no hop cap; "Nearest System" auto-plots
  (:737–752).
- **Class.** FIX+ENH → `autoRoutePlotting`. **Impact** high. **Confidence** very high.
- **Test.** Clicking a system two jumps away arms nothing; Shift+clicking it after its neighbour
  builds a 2-hop route; a 32nd hop is refused.

#### UI-06 · Ship and stellar selections are independent; Land uses the selection — ui_rules A3 — **DONE**
- **Done.** `GameScene.selectShip`/`selectPlanet` no longer clear each other; `attemptLand` uses the
  selected stellar (nearest body only under `forgivingLanding`); a click on empty space clears the
  stellar, on the player's own ship the ship target; Alt+Y (`hailStellar`), 1–4 (`selectNav1–4`),
  N clears the travel selection, Alt+N the ship target. Q-UI-03 (60-frame re-pick) not modelled.
- **Original.** Two channels: the ship target (+0x70) and the travel stellar (+0x6c, mode 2).
  Selecting one leaves the other. Land works on the **selected** stellar through the arrival gate
  (FL-12); with none selected it auto-picks the nearest available one (0x00462db0). Alt+Y hails
  the stellar even while a ship is targeted (0x00454910). Number keys 1–4 pick nav stellars;
  clear-target (slot 8) clears the travel selection, or the ship target with Alt.
- **NovaSwift.** `selectPlanet` clears the ship target and vice versa
  (`App/Game/GameScene.swift:1629–1642`); `attemptLand()` lands on the nearest landable body
  whatever is selected (:472, 1517–1534); no Alt+Y, no number keys.
- **Class.** FIX (nearest-body landing survives only under `forgivingLanding`). **Impact** high.
  **Confidence** high (the 60-frame nearest re-pick while armed is Q-UI-03).
- **Test.** With a ship targeted, selecting a planet keeps the ship target; Land with the far
  planet selected lands there, not on the nearer one.

#### UI-07 · Target cycling and nearest-target commands — ui_rules A4 — **DONE**
- **Done.** `Engine/PlayerTargeting.swift`: `cyclePlayerTarget(forward:squad:)` in `npcs` (spawn)
  order, no wrap, no range cap, squad-only with Alt+backquote (Q-UI-04); R =
  `selectNearestHostileThreat`, Alt+R = `selectNearestEngaged`. The old cycle is
  `nearestFirstTargeting`. Approximation: freed slots being reused is not modelled; there is no
  AI state 0x15 to filter.
- **Original** (0x00461bd0 / 0x00461f60): cycle in **slot (spawn) order** from `current + 1`,
  **no wrap** (past the last ship it clears to "No Target", and the next press starts over), with
  a previous direction. Plain cycling excludes the player's escorts; the modifier cycles **only**
  the squad. Filters: same system, not AI state 0x15, visible through cloak or scanner, not
  untargetable (OS-12); **no range limit**. R = nearest *hostile* (threatening the player's squad,
  or state 4 locked on a squad member, not disabled; 0x00462bd0); Alt+R = nearest engaged
  (0x00462850); neither range-capped.
- **NovaSwift.** Nearest-first, escorts appended, wraps, 3000 px cap (`App/Game/GameScene.swift:1689–1717`,
  `Engine/World.swift:3022, 3049–3063`); R = nearest ship.
- **Class.** FIX+ENH → `nearestFirstTargeting`. **Impact** medium-high. **Confidence** high (the
  squad modifier key is Q-UI-04).
- **Test.** Cycling through 3 ships gives spawn order then "No Target"; a ship 5000 px away is
  reachable.

#### UI-08 · Landing request and clearance messages — ui_rules A7 — **DONE**
- **Done.** `GameContainerView.pressLand` + `GameScene.landingRequestID`/`landingProblem`: first
  press denied (#81–83, selection cleared), uninhabited ("No response.", cleared at once), or request
  line (skipped inside 250 px); the 250 px arm runs only for the requested body and posts the
  clearance line with the fee (`OriginalText.landingClearance`); second press lands or says too far /
  too fast / cloaked / unable. The fee-unaffordable denial (#61) waits on EC-05. Gate requests reuse
  the existing gate handling after clearance. Q-UI-08 (pilot vs ship name) uses the pilot name.
- **Original.** First Land press (0x00457580): a denied stellar beeps and shows STR# 2002 #81 /
  #82 / #83 (hypergate / docking / landing denied) and clears the selection. Otherwise a request
  line by `rand(3)`: 1/3 "<name> traffic control reads you" (#78; #76 stations), else "Landing
  request received" (#79; #77 stations; gates #74/#75), with 1/2 chance of ", <pilot>", always
  ending ". Begin initial approach." (#80). Within 250 px on both axes the request is skipped.
  On reaching 250 px (0x00459950): clearance by `rand(3)` (#97 / #98 / #99; stations #94–96,
  gates #91–93), then `rand(2)` #100 or #101, plus " [Landing fee is <n> credits.]" (#104 + #105).
  **L must be pressed again** to land. Second-press denials: too far #67/#68, too fast #71/#72,
  cloaked #73, unable #84 + #87/#88 + name + #89/#90, fee unaffordable #61 + #63/#64.
- **NovaSwift.** One press lands when in reach (`App/Game/GameContainerView.swift:2684–2700`); no
  request/clearance text; refusal strings are invented (:1388, 1405, 1412, 1427, 1454–1468);
  too-far and too-fast are silent.
- **Class.** FIX+ENH → `forgivingLanding` (with FL-12). **Impact** medium. **Confidence** high.
- **Test.** Pressing L once far away shows a request line and does not land; reaching 250 px
  shows a clearance line; a second L lands.

#### UI-10 · Target and nav HUD panels — ui_rules A5, A6 — **DONE** (Classic HUD)
- **Done.** `GameScene.updateOriginalTargetText` / `updateOriginalNavText`, drawn by
  `AuthenticHUDView`: përs name, shïp Subtitle, "Shield:" N %, "Armor:" only for Flags 0x100
  (`targetArmorReadout` for all), Shields Down / No Shields / Disabled / Waiting, TargetCode or
  Escort/Fighter, centred TargetCode for Flags 0x200 or ShieldMod < 0, no hostility colour, no
  planet panel; nav Nav System Off / Stellar Navigation / Hyperspace + next hop or "Unexplored
  System", dimmed out of range or under 100 fuel. Not done: the përs special-ship subtitle. The
  Enhanced / Nova Swift HUD keeps its own readout (presentation axis).
- **Original.** Target panel (0x0045f530): name = mission ShipName, else **përs name**, else
  class name; subtitle = mission subtitle, else përs special-ship name, else **shïp Subtitle**;
  status "Shield:" (#13) N %, or when shields are down "Armor:" N % **only** for shïp Flags 0x100,
  else "Shields Down" (#15) / "No Shields" (#14); "Disabled" (#347) or "Waiting" (#348) for a
  ShipGoal-5 ship; Flags 0x200 or përs ShieldMod < 0 suppresses the row and centres the
  TargetCode; bottom right TargetCode, else "Escort" (#168) / "Fighter" (#169) under 100 t;
  "No Target" (#349); planets never drawn; no hostility colour. Nav panel (0x0045e400): "Nav
  System Off" (#342); "Stellar Navigation" (#343) + stellar or "No Destination" (#344);
  "Hyperspace" (#345) + **next-hop** name, or "Unexplored System" (#346) below level 1, dimmed
  until outside the no-jump radius with ≥ 100 fuel.
- **NovaSwift.** `AuthenticHUDView.swift:119–214, 246–270`; `App/Game/GameScene.swift:2354–2385`:
  hull name for përs, no shïp subtitle, armor % for all ships (deliberate, :207–214), "Hostile"
  fallback, a planet "Landable" panel, red hostile tint; nav shows the final destination name
  even unexplored, an invented "N jumps" line, no state titles.
- **Class.** FIX+ENH → `targetArmorReadout` (armor % only). **Impact** medium. **Confidence**
  high.
- **Test.** Targeting a përs shows its name; a route through an unvisited system reads
  "Unexplored System".

#### UI-11 · Status-bar lines, durations and HailQuote broadcasts — ui_rules A10, A15, C5, C7, C8 — **DONE** (hint chain deferred)
- **Done.** `GameHUDModel.post(_:rawCalls:)` runs on sim time (frozen while paused), empty text and
  Return (`dismissMessage`) clear it, `postIfIdle`; arrival line or buoy after every in-place reload
  (`postArrivalLine`, gate/wormhole variants, #49), launch line or a staged `Q` for 0x1f4
  (`postLaunchLine`), #42/#29/#10/#53/#30, dates from STR# 137 with the chär affixes
  (`PlayerState.datePrefix/dateSuffix`, older saves fall back to the first chär), HailQuote broadcasts
  (`GameScene.broadcastHailQuotes`; the 0x0400 / 0x0800 / player-class gates and the ambush trigger
  are not modelled). The invented lines and the 5 s wall-clock timer are `extraStatusMessages`.
  **Deferred:** the new-pilot hint chain #22–31 (it overlaps NovaSwift's `tutorialHints`, decision 2),
  and rewording the remaining invented `hud.post` sites of Batches 2/4/5 (plunder credits/fuel/ammo,
  contraband, domination). **Cleanup 1:** the arrival line carries the abandoned-fighter clause
  ("  (Two fighters abandoned)", separators read from the exe); the cargo salvage line is the
  original's; the escort, relocate and new-hull lines moved behind `extraStatusMessages`; engine
  overlay messages keep their own raw-call durations.
- **Original.**
  - One message slot (`NovaHud_ShowOverlayMessage` 0x0047e2d0) with a per-message duration in
    raw sim calls (0xf0–0x200, ≈ 5–11 s), frozen while paused, dismissable with Return (slot 6)
    or by posting an empty message; taunts and quotes only post when the bar is idle.
  - Jump arrival (0x0044f3d0): with sÿst Message −1, STR# 2002 `#43 + rand(3)` + system + #48 +
    long date + "." (gate/wormhole #46/#47), plus #49 "No stellar objects present." and the
    "N fighter(s) abandoned" clause (#164/#165), 0xf0; otherwise the buoy (UI-12).
  - Launch (0x00456134): `#55..#59` + stellar + #60 + date, 0xf0; a staged `Q` replaces it for
    0x1f4 (MS-18). New pilots get the travel-hint chain #22–28, #30/#31 (quirk: until reload,
    every launch shows the hyperspace hint).
  - Jump refusals: #10 insufficient energy, #29 no destination (NovaSwift opens the map
    instead), #42 too close; #30 when leaving the no-jump radius; #30/#31/#36/#42 auto-clear when a
    jump becomes legal.
  - përs HailQuote (`STR ` id+4999, else STR# 7101) is broadcast for 0x1a4 with sound 1: at
    1/140 per call while the bar is idle and ≥ 0xa8c `TickCount` ticks (60 Hz, ≈ 45 s; unit
    settled by OQ A5) since that ship's last quote, gated by përs flags 0x08 / 0x0400 / 0x0800 / 0x1000–0x4000 / 0x80 (0x00433050); when a flag-0x10 përs
    turns hostile (0x00410700); and on an ambush (0x00426dd0).
  - Dates use STR# 137 (abbreviated month, ordinal) with the chär prefix/suffix (0x00468450 /
    0x00468600).
- **NovaSwift.** `GameHUD.swift:84–92` (fixed 5 s wall-clock timer running while paused, no empty
  message, no dismiss key); about 55 `hud.post` sites with invented or paraphrased text, a daily
  `logDate` line competing with the buoy (`App/Game/GameContainerView.swift:1692, 1908–1912`), no
  arrival or launch lines, HailQuote only inside the comm dialog (:2822).
- **Class.** FIX+ENH → `extraStatusMessages` (the invented lines and the wall-clock timer).
  **Impact** medium. **Confidence** high.
- **Test.** Arriving in a system with no buoy shows "Arriving in the X system on <date>." for
  0xf0 raw calls of sim time; pausing freezes it.

#### UI-13 · Player Info window — ui_rules C2, C4, C9 — **DONE** (Tab cycling, junk count words deferred)
- **Done.** `Story/PlayerInfoPages.swift` (stat grid, daily economy line, cargo / extras by cost with
  trade-in footer / honors by Weight, all STR#-sourced; STR# 138 ratings via
  `OriginalText.combatRating`), drawn by `PlayerInfoView` with live figures from the scene; P opens
  it, jettison confirms with #291 and posts #289. **Deferred:** count words for cargo junk names,
  Tab page cycling (the window would have to take keyboard focus from the flight controls, which
  the iPad hardware-keyboard path needs to close it).
- **Done (cleanup 1).** Jettison per 0x0041f330 with its jettison-all flag
  (`StoryEngine.jettisonCargo`): the hold goes, and so does each abortable mission's cargo
  (zero-ton ones too), which quick-fails — "Mission failed." (#284, unless Flags 0x0400) replaces
  #289. Pods (`World.spawnJettisonedPods`, 0x0041f800): the ship casts
  `clamp(trunc(tons / 5), 1, 12)` and each non-mission freighter escort its share of the ordinary
  tons the same way; spïn 500, half a ship-width behind, `(rand(40) + 30) / 100` px/tick at
  `180 + rand(30) − rand(15)`°, 180–269 ticks. They carry no cargo (the resource-box latch stays
  clear), so a scoop passes through them. Docked, no pods or line.
- **Original.** Opened by P (slot 0x19), Tab/Shift-Tab cycle pages, Enter/Esc/P close
  (0x00499c10). Page 1 (0x0049a540) is a stat grid of STR# 2002 #251–260 and #326: pilot, date,
  system, legal status (UI-14), combat rating (STR# 138), shield / armor / energy status (N/A
  #396, Shields Down #15, Failed #261, jumps #239/#240 with the #262/#263 manoeuvring phrases),
  ship name and class, turn rate × 30 "°/sec" (#258), accel × 2500, max speed × 100 (× 2/3 when
  not strict, FL-03), grouped credits; then Expenses / Income / Net per day (#264–#266) from
  escort upkeep `cost × 0.01`, dominated tribute and salaries. Pages 2–4 (0x0049c050): cargo with
  count words and a free-space footer (#268/#269), extras grouped by `similar_to`, sorted by cost
  descending, footer "Ship trade-in value" (#272/#273, #270), ranks sorted by Weight then Flags
  0x2000 outfits (#274, #271). Jettison confirms (#291), jettisons fleet-wide non-mission cargo
  and junk as floating pods, and shows #289/#290 (0x0041f330).
- **NovaSwift.** `App/Game/PlayerInfoView.swift:112–195`: invented prose, no stats or daily
  economy, abbreviated credits, full English months with a hard-coded " NC", early return below
  record −200 (:126) that drops the date; reachable only from menus (P is pause); `jettisonHold`
  (`App/Game/GameContainerView.swift:2671`) wipes pilot cargo silently; combat titles hard-coded
  (`Story/PilotSave.swift:141–157`), with a "Harmless" fallback that is not in STR# 138.
- **Class.** FIX. **Impact** high (visible). **Confidence** high.
- **Test.** Page 1 of a non-strict pilot shows Max Speed equal to shïp Speed (the ×1.5 and ×2/3
  cancel); jettison spawns pods.

#### UI-14 · Legal-status labels — ui_rules C3 — **DONE** (reads the EC-02 seam)
- **Done.** `Story/LegalStatus.swift`: levels from R and CrimeTol in ×4 steps, Military
  Dictator/Governor over the first three nav slots, N/A for xenophobic governments (and, in Player
  Info, no usable destination); labels from STR# 134. Used by Player Info, the main menu and the
  star map. R comes from the single seam `PlayerState.legalStatusReputation(inSystem:game:)`, which
  reads the per-government record today; EC-02 only has to change that function.
- **Original.** `NovaUi_DrawSystemFactionConflictStatus` 0x00468d90 (Player Info, main menu, map),
  from R = the per-system reputation and T = the system government's CrimeTol (government 0 when
  ungoverned), STR# 134 entry level + 1: R = 0 "No Record"; 0 > R ≥ −T "No Convictions"; then
  thresholds −T, −4T, −16T, −64T, −256T, −1024T, −4096T (Minor Offender … Public Enemy);
  0 < R ≤ 4T "Citizen", then 4T, 16T, 64T, 256T, 1024T (Good … Virtuous Citizen). Overrides: among
  the **first 3** nav slots (quirk), any dominated usable stellar gives "Military Dictator"
  (some) or "Military Governor" (all); a xenophobic government shows "N/A" (#396), as does a
  system with no usable destination in the info window.
- **NovaSwift.** Fixed ±200 cutoffs and invented words from the universal record
  (`App/Game/PlayerInfoView.swift:121–131`, `AuthenticMainMenuView.swift:374–385`).
- **Class.** FIX (needs EC-02). **Impact** high. **Confidence** high.
- **Test.** With CrimeTol 10, R = −50 reads "Offender" and R = −200 "Criminal".

#### UI-15 · Default key bindings and missing commands — ui_rules A11, C10 — **DONE** (map cycles, Caps Lock deferred)
- **Done (cleanup 1).** The original table gains Alt-X eject (OS-02's `requestEject`; only the
  modern table had it, and touch already offers it) and Alt-− self-destruct, a held command
  (`ControlIntent.selfDestruct` → `World.stepSelfDestruct`, the 0x00451954 block of 0x0044aa70):
  pressing arms a 150-tick countdown ("Self-destruct sequence initiated.", #385 #386, 0x28),
  letting go aborts (#385 #387), each 30-tick boundary at ≤ 120 posts "Self-destruct in N
  seconds." (#385 #395 N #389, 0x46), and at ≤ 1 tick the ship blows (shields 0, armor −1, target
  cleared, "Have a nice day." #390). Not modelled: the cue sounds, hulls docked to the player
  dying with it, and a touch control for the hold.
- **Done.** `KeyBindings.defaults` is the original table (Z afterburner, Control secondary, S clear
  secondary, backquote cycle / Shift back / Alt escorts, R / Alt-R, N / Alt-N, 1–4, Alt-Y, H, Return
  dismiss, P Player Info, I mission info); `modernDefaults` is the old table, used by Reset under
  `modernKeyBindings`. Migration: a fresh install saves the original table at once; an install with
  saved settings but no saved bindings is pinned to the old table; actions added since a map was
  saved only take a default key nothing else holds. iOS/tvOS cannot see a bare Control, so there the
  secondary stays on Return. **Clash:** Control-arrow is a reserved macOS Spaces shortcut (decision 3).
  **Deferred:** the map's Tab/backslash adjacent cycle and in-flight backslash destination cycle,
  Caps Lock 2× mode.
- **Original.** Defaults from 0x004b4400 (DIK set-1 codes; meanings from the decomp labels):
  L-Ctrl fire secondary, W next secondary (Shift back), S clear secondary, Y hail, L land, Return
  dismiss message, A face target, N clear target/nav, M map, backquote target cycle (Shift back),
  R nearest hostile (Alt nearest engaged), H hyperspace mode / re-arm from route, \ destination
  cycle without the map (Shift back), J jump, B board, Alt-X eject, Alt-− self-destruct, Z
  afterburner, P Player Info, I mission info, E escorts, F/D/V/C escort commands, Caps Lock 2×
  mode. The map takes Tab/\ to cycle adjacent destinations (0x004a7710).
- **NovaSwift.** `App/Input/KeyBindings.swift:11–48`: Return = secondary (for macOS Ctrl-arrow),
  Shift = afterburner, P = pause, I = ship info, A = autopilot, U = clear target, R = nearest
  ship / T = nearest hostile, X = invented Evasive; S, Return-dismiss, H, \, Alt-X, Alt-−, number
  keys and the map cycle are missing (`App/Input/GameAction.swift:24–26`).
- **Class.** FIX+ENH → `modernKeyBindings`. **Impact** medium. **Confidence** medium (several
  slot meanings and DIK names are Q-UI-04).
- **Test.** A fresh install binds Z to afterburner and P to Player Info.

#### UI-18 · Star-map drawing and panels — ui_rules A12 — **DONE**
- **Done.** `GalaxyMapView`: links only from visited/charted systems, labels only for them (no
  "Unexplored"), Classic markers coloured by `originalMarkerColor` (the dominated colour is an
  unread theme variable 0x00733b32; green per the decomp), selection ring, original side column and
  Ports / Navigation Hazards / date status bar, Show/Hide Borders (persisted) and a prefix Find; no
  JUMP button, colour key or Nearest System in Classic. Goods/services show for visited or charted
  systems (the level-1/level-2 split is UI-04). The full-screen (Enhanced / Nova Swift) map keeps its
  relationship palette and route bar.
- **Original.** Labels for visited systems only (zoom-gated) plus the selection; links radiate
  only **from** visited systems; marker colours (0x00466260): unvisited dark grey, no usable port
  light grey, any dominated stellar orange, any landable blue, forbidden with rep ≥ 0 orange,
  forbidden with rep < 0 red (no yellow "neutral"); political borders toggled by Show/Hide Borders
  (STR# 150 #56/#57, persisted); buttons Show Borders, Clear Route, Find (#60, prefix search over
  visited systems), −, +, Done; status bar "Ports:" (#309), "Navigation Hazards:" (#311: asteroid
  < 4 sparse / < 7 moderate / dense, interference < 34 / < 67, murk < 31 / < 61, "gravity shear"
  when any stellar has +0x46c) and date; side panel Current/Selected/Destination System
  (#337–339), Government (#325), Legal Status (#326, UI-14), Goods Traded (#327), Services
  (#328–331), "<Unknown>" (#310) below level 2.
- **NovaSwift.** `App/Game/GalaxyMapView.swift:313–327, 361–390, 405–560, 870–998`: "Unexplored"
  labels on neighbours, links between any two non-unknown systems, a relationship palette with
  yellow, always-on borders, invented "Named System" / "Nearest System" buttons and an extra JUMP
  button and COURSE/FUEL bar, no Legal Status line.
- **Class.** FIX. **Impact** medium-low. **Confidence** high.
- **Test.** Two unvisited neighbours of a visited system show no link between them.

#### OS-05 · Radar, IFF and density scanner — **DONE**
- **Done.** `World.effectiveSensorRange` no longer shrinks with interference (radar and AI);
  `World.radarStaticChance` drives an all-static radar refresh at most every 250 ms (a display roll,
  off the sim RNG); without IFF every blip is DimRadar and only the target blinks BrightRadar; the
  density scanner draws ≥ 100 t ships as 3×3 boxes and no longer reveals cargo. The IFF stellar
  colour scheme was not re-checked.
- **Original.** Each radar refresh (≥ 250 ms) shows `ppat` static over the whole scope (no
  contacts) with probability `clamp(sÿst.Interference − clamp(Σ ModType 24 × owned, −100, 100),
  0, 100) %` (0x0045d030, 0x0046abb0). There is **no range reduction**, and AI is unaffected.
  Without IFF (ModType 14) every blip is DimRadar and only the selected target blinks
  BrightRadar. With IFF the panel is black and colour-coded (player cyan, disabled grey, threat
  red, squad green, others blue; stellars by gate rank/rep, wormhole dark cyan, dominated green,
  friendly yellow, below MinStatus orange/red, uninhabited grey). The density scanner (ModType 13)
  is read **only** by the radar: ships ≥ 100 t draw as a 3×3 box (0x0045d600).
- **NovaSwift.** Interference shrinks radar and AI scan range linearly (`Engine/World.swift:3176`;
  `App/Game/GameScene.swift:4778`; `Engine/AIBrain.swift:318`); without IFF the authentic HUD
  still draws hostiles bright (`AuthenticHUDView.swift:359–366`); the density scanner reveals
  target cargo (`App/Game/GameScene.swift:2384`).
- **Class.** FIX. **Impact** medium. **Confidence** high.
- **Test.** In an Interference-50 system without a scanner, about half the radar refreshes show
  static and the rest show every contact at full range; AI detection is unchanged.

---

## 6. Open questions

Most of the first pass's questions were settled straight from the exe
(`open_questions_resolved.md`) and folded into the items above. What remains is listed here.
"Ghidra" means reading the export is enough. "Oracle" means running the routine under the
emulator harness (`~/Projects/evnova-re/oracle`) on a synthetic fixture. "Data" means a
stock-data pass. "Decision" means it is not an RE question.

**Oracle to-dos** (the static reading is known; only an execution pins it):

| ID | Question | Fixture |
|---|---|---|
| Q-EC-03 | Perishable decay when no tribble is aboard reads a stale stack slot (EC-24) | Run 0x0044aa70 holding only a perishable junk, `DAT_007356cf = 0`, `DAT_007356d0 = 1`, `DAT_00597992 = 250`; observe `[esp+0x188]` and the decrement |
| Q-EC-13 | Which relation gets the + and which the − half-penalty in the flood (EC-02; OQ D4) | Run 0x00467140 with a 3-government fixture (ally, enemy, neutral) |
| Q-EC-12 | Does a cancelled outfitter buy still set the outfit day flag (FL-05)? | Run 0x0048ea70 with the quantity prompt stubbed to cancel |
| Q-FL-01 | RNG seed source (optional; the generator is settled, FL-22): QTML trap 0x180008, assumed `GetDateTime`, plus the 60 Hz tick | Oracle 0x004683b0 `Range(0)` path. Only matters for reproducing exact sequences |
| Q-MS-03 | Bar re-offer timing: the main-screen offer tick's unit (MS-05) | Drive 0x00491f30's event pump with a timer stub (optional) |

**Static reads still needed:**

| ID | Question | Settle by |
|---|---|---|
| Q-FL-02 | Player engine-glow state machine (thrust / inertialess / afterburner / banking / turnaround / jump) | Ghidra (0x0044aa70 neighbourhood) |
| Q-FL-04 | NPC gravity tick placement and crash interaction; 0x0043adb0 is only 10 % ported (FL-19) | Ghidra 0x0043adb0 in full |
| Q-FL-09 | Asteroid animation frame seed | Ghidra 0x00421830 |
| Q-FL-11 | Jump-brake one-frame entry offset; unported waypoint marker | Negligible |
| Q-FL-14 | **New:** is ModType 38 part of the player's gravity exemption? (FL-19: first pass yes, outfits_special no) | Ghidra 0x0046e120 |
| Q-WP-05 | Data severity: beam Count/Reload, BlastRadius without 0x8000, SubCount with ProxRadius 0, `Speed × Count/100 < 60`, mining energy/mass | Data |
| Q-AI-13 | Combat chatter, acknowledgement sounds, the +0xC4 cohort gate, the fleet 0x400 "on my way" arm | Ghidra |
| Q-GEN-1 | IsShipDisabled exempts NPCs whose field +0x8c ≠ −1. What is +0x8c? | Ghidra (writers) |
| Q-MS-05 | Duplicate `S` behaviour is settled (MS-17); does any stock flow depend on it? | Data |
| Q-EC-14 | **New:** gambling modifier wager `min(credits, 10000)` (coverage audit) vs the "Bet 5000" button label in STR# 150 (EC-26) | Ghidra 0x0047dc50 |
| Q-OS-01 | Nonlethal bomb damage `base_armor + rand(base_armor/2 + 1)` armor-only would be fatal; is it clamped, or misread by the decomp? (OS-08) | Ghidra 0x0044aa70 at the 0x0044b446 call |
| Q-OS-02 | Confirm no daily tick on the hypergate/wormhole branch (OS-06) | Ghidra 0x00457580 |
| Q-OS-03 | Which stock hulls carry cloak, jammer, scoop or repair DefaultItems, and which have PodCount > 0 (sizes the OS-01 / OS-02 impact) | Data (`novaswift-extract`) |
| Q-OS-04 | NPC carrier jumps: are can't-jump fighters lost or recovered first? (OS-03) | Ghidra |
| Q-UI-02 | Does the pod respawn really ignore the chär ship and use class 0 for a total conversion? (OS-02) | Ghidra 0x0044d570 |
| Q-UI-03 | Does the land command's 60-frame nearest re-pick while armed override a manual selection? (UI-06) | Ghidra (decomp `spaceflight.cpp:1145` TODO) |
| Q-UI-04 | Key table: squad-cycle modifier (Ctrl per the port, Alt per the manual), the DIK names of slots 0x0a/0x0d, and the meanings of slots 0x0c (H), 0x0f (K), 0x29 (U) | Ghidra key-name table 0x005776dc and the 0x0044b120 key reads |
| Q-UI-06 | Does the star map preselect (green arrow) when opened from flight with an active mission? | Ghidra 0x004a3aa0 |
| Q-UI-07 | NovaSwift's hidden-twin handling vs the original's root rewrite of every link (possible wrong link lines around the Koria/Vell-os twins) | Ghidra plus data |
| Q-UI-08 | Is `DAT_00599acc` ("<name>, you're cleared to land") the pilot or the ship name? | Ghidra |

**Decisions** (not RE questions):

| ID | Question |
|---|---|
| Q-FL-13 | Hitch behaviour: drop time (NovaSwift) or stretch the tick (original EMA) |
| Q-EC-10 | Migrating existing pilots' per-government records to per-system reputation. **Migration default** (EC-02, user may override): each system seeded from its owner's old standing there, independent systems 0, old fields kept |
| Q-MS-06 | Persisting offer rolls, the target table and aux-ship counts in `.evpilot` (known bug: finite aux ships vanish on reload) |

**Settled in the second pass** (see the cited items): Q-FL-01 algorithm (FL-22), Q-FL-03
multi-jump (FL-06), Q-FL-05 arrival ×1.5 (FL-13), Q-FL-06 truncation (FL-10), Q-FL-07 reverse
wins (FL-09), Q-FL-08 fade (user, FL-04), Q-FL-10 slot 0x3ff (FL-15), Q-WP-01 PD projectiles
(WP-14), Q-WP-02 turret roll (WP-26), Q-WP-03 75 % damage (AI-41), Q-WP-04 no quirk (WP-21),
Q-AI-01 period and Q-AI-02 state 0x13 (AI-18), Q-AI-03 both meanings (AI-20), Q-AI-04 NPCs
never land (AI-23), Q-AI-05 literal filter (AI-23), Q-AI-06 is subsumed by the AI-18 port,
Q-AI-07 cadence 0 literal (AI-20), Q-AI-08 no ±25 % (AI-11, EC-18), Q-AI-09 moot (AI-12),
Q-AI-10 this system (AI-14), Q-AI-11 turrets only (AI-35), Q-AI-12 interactive window (AI-42),
Q-EC-02 refuel (EC-23), Q-EC-05 plunder credits (EC-18), Q-EC-06 planetary bribe (EC-25),
Q-EC-07 highest index (EC-03), Q-MS-01 `Q` timing (MS-18), Q-MS-02 fallback (MS-15). The HailQuote
cooldown unit asked by ui_rules is settled by OQ A5: `FUN_004d5e10` is the 60 Hz `TickCount`.
"Military Dictator" (some dominated) vs "Military Governor" (all dominated) is unambiguous in the
code and is copied as is. Settled during the first consolidation (§1): the escort-cap polarity,
the capture-odds escort filter, outfitter and shipyard day costs, the AvailRecord comparand
(EC-02), and, by the ruling, the tech-markdown cap and the shareware items. Batch 1b settled
Q-FL-12 (oracle: the caller's signed short makes a negative ModType 22 subtract; FL-05) and Q-UI-01
(the ammo reconcile; UI-02). Cleanup 1 settled Q-EC-11 (+0xa4 is the jump's spin-up start; EC-15).

## 7. Coverage

From `~/Projects/evnova-re/audit/coverage.md` (every one of the exe's 3199 Ghidra functions
classified into subsystems and ported/unexplored status, using wraitii's self-reported port
percentages):

| Scope | Functions | Bytes | Port-weighted coverage | Truly unexplored |
|---|---:|---:|---:|---:|
| Gameplay | 718 | 630 KB | 79 % (537 tagged) | 44 functions, 7.7 KB (mostly licensing and tiny UI wrappers) |
| Non-gameplay | 2481 | 820 KB | 11 % (1215 skipped by design: CRT, QuickTime, codecs, winsock, blitters) | 674 |
| All | 3199 | 1.45 MB | 41 % | 718 |

Well covered (≥ 90 %): AI 92 %, spawning 92 %, ship stats/loadout 91 %, government/legal 98 %,
collision 90 %, crön 100 %. Missions/NCB 86 %, flight 85 %, weapons 83 %. The remaining gameplay
risk sits in partially ported and named-only functions (107 named-only, 31 KB), not in
unexplored ones. These still need reading before or while their items are ported:

| Function(s) | Port | What it decides | Item |
|---|---|---|---|
| `Ship_HandlePlayerShipCore` 0x0044aa70 + fragments 0x0044bf50 / 0x0044ead0 / 0x0044c2e0 / 0x0044eed5 / 0x0044df50; `PlayerTick_HyperspaceProgressBranch` 0x0044d371; `PlayerTick_MouseTargetAndControlCommands` 0x0044e019; `Ship_RunSpaceflightMode` 0x00489210 | 12–75 % | Player tick, jump engage, secondary cycling, cannot-jump overlays, tribbles, escape-pod transition | FL-23, WP-27, EC-24, OS-02, UI-11 |
| `Stellar_TickStellarGravityPull` 0x0043adb0, `Stellar_ShipHasGravityShielding` 0x0046e120 | 10 %, 25 % | Gravity | FL-19 |
| `Stellar_HandleStellarEntryAndExit` 0x00457580; `NovaUi_UpdateTravelSelectionSprite` 0x00438fc7 (named-only) | 60 %, 0 % | Landing gate, gate transit, reticle visibility (cloak/scanner/untargetable) | FL-12, UI-08, OS-06, OS-12 |
| Hail / bribe / payment handlers 0x004a0810–0x004a21e0; `NovaUi_RunTravelDestinationBribeWindow` 0x0047f9c0 | partial | Comm buttons and the payment window | AI-42, EC-25, UI-09 |
| `NovaUi_RunBarGamblingWindow` 0x0047dc50, draw 0x0047e1e0, buttons 0x004a2c30 / 0x004a2de0 | named-only | Gambling | EC-26 |
| `Resource_GetByTypeAndId` 0x004ce250, `Resource_ByteSwapAndPadRecordByType` 0x004ce700, descriptor interpreter 0x004ce660; `NovaData_LoadScenarioResourceTables` 0x004bd3c0 | unexplored; 68 % | Record zero-padding to minimum sizes; loader normalisation | LD-02, LD-01 |
| Outfitter grid-select 0x004909a0 (named-only; wraitii mislabels it `OutfitterMenu_FUN`) | 0 % | Sell allowed only when owned > 0 and oütf Flags 0x0008 clear; dësc 3000 + id | Already matches (`Story/PilotEconomy.swift:370–372`); no item |
| `NovaUi_RunOutfitterInteractionLoop` 0x0048ea70; `NovaUi_ShipyardSetCursorSlot` 0x0049458d | 65 %, 25 % | Outfitter/shipyard rules | EC-07, Q-EC-12 |
| `Frame_SpaceflightLoop` 0x00417600, `Frame_TickSystems` 0x004186b0, `Platform_OnAppActivated/Deactivated` 0x00497cf0 / 0x00497d50 | 15–40 %, unexplored | Cadence; dt reset and pause on app switch | FL-01 |
| `NovaUi_DrawPlayerInfoWindow` 0x0049a540, `NovaUi_BuildPlayerSpecialInteractionStrings` 0x0049c050, `NovaUi_RunBarWindow` 0x0047c8e0 | 50–65 % | Player Info text, bar | UI-13, UI-14, MS-05 |
| `Asteroid_SpawnRecord` 0x00421e60 | 40 % | röid yield and spawn | FL-16 |
| Licensing cluster (`Registration_SpawnLicenseEnforcer` 0x0046ac50, License_* 0x004d4430–0x004d5cd0) | 0 % | Shareware enforcement only | Out of scope (registered behaviour) |

The CE debug console `Debug_HandleCheatAndNcbCommands` 0x00872040 is a useful reference for an NCB
test harness, not a port target.

## Decisions needed from the user

Settled since the first pass, now recorded in their items: save cadence (UI-01), Strict Play
default and permadeath scope (FL-03), and the hyperspace fade (FL-04).

1. Migration of existing pilots' legal records when EC-02 replaces the model (Q-EC-10). With
   UI-01 the same migration should state what happens to pilots whose last autosave is
   mid-flight (suggested: move them to their last landed stellar). **Implemented default**
   (EC-02): each system is seeded once from its owning government's old standing there,
   independent systems start at 0, and the old record stays in the save; confirm or override.
2. Whether the ruling covers presentation defaults (current defaults kept by Batch 7): `shipBarPosition = .above`, `screenShake`,
   `sidebarPauseMenu`, `showMissionStorylineTags` (§2), and NovaSwift's `tutorialHints` versus the
   original's launch hint chain (UI-11). The fade exception (FL-04) is the only one ruled so far.
3. Default key bindings (UI-15): the original's L-Ctrl secondary clashes with macOS Ctrl-arrow
   Spaces shortcuts. Batch 7 ships the original table (Control) for new installs and keeps existing
   installs' bindings; the old layout is `modernKeyBindings`. Keep Control on macOS, or default
   Return for secondary on macOS only? Also open: pause has no original key (unbound now; Esc still
   opens the menu), and the touch "tap the selected system again" stand-in for Shift+click (UI-05).
4. Whether `frequentAutosave` off should still keep a crash-recovery resume file that a death
   invalidates (UI-01), or nothing at all — and, on iOS/tvOS, whether a background save while
   *landed* should stay on by default, since the original's quit-while-landed saves (UI-01).
7. Strict Play death deletes only the played save slot; whether it should take the pilot's other
   NovaSwift save slots with it (FL-03).
5. Hitch behaviour (Q-FL-13) and persisting offer rolls / aux ships in `.evpilot` (Q-MS-06).
6. Whether any FIX-only item listed at the end of §3 should be kept as a toggle instead.

## AI / spawn / weapons sweep fixes (fix/ai-combat)

Done from `ai_spawn_comm.md` and `weapons_flight.md`: A1, A2, A3, A4, A5/A6/B-13, A7, A8, B-1 to B-6, B-8 to B-12, B-14, C-1, C-2, D-1 to D-4, and ai_spawn_comm #2, #4, #6, #9 to #19 and #20 (hull availability, gate hold). Pinned by `AICombatFidelityTests`, `BoardingTests`, `ShipSystemTests`.
Also done: chatter categories 0 and 2, the capture name prompt (#119), comm and capture window text and keys (#22), A9 (area blasts, pod debris), C-3, C-4, and the B-7 test. Not done: #20's RNG draw shapes (they change only the random stream), the pod-debris sound (DAT_00591a80, id unknown) and the pers-flag debris arm at 0x00433050 l.904.
