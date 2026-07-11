# Outfit / combat systems audit — status & follow-ups

Working document for the branch `claude/outfitter-systems-audit-6pi03w`. It
records what was implemented, what was confirmed against real data, and what is
deliberately left for later. Temporary — move the durable parts into the
per-topic reverse-engineering docs (`docs/reverse-engineering/*`) and delete
this once triaged.

Everything here is grounded in the shipped `Nova Data 1–6.rez` records and the
EV Nova Bible (`Nova Bible.txt`). No behavior was invented; where the Bible
specifies endpoints but not a curve (e.g. interference → sensor range), the
interpolation is called out as an engine reading, not a documented rule.

---

## ⚠️ Build / test caveat (read first)

**None of this was compiled or run in the authoring environment** — the Swift
toolchain host is blocked by the sandbox egress policy and there is no CI in the
repo. Every change was verified by reading, matching existing patterns, and unit
tests, but not by a build.

**Before merging: run `swift build && swift test`.** The highest-risk areas to
watch the compiler on:

- `Loadout`'s synthesized memberwise init — several fields were appended; arg
  order in `Galaxy.loadout`'s `return Loadout(...)` must match declaration order
  (checked by hand, but the compiler is authoritative).
- `PlayerState` gained new **optional** fields (`chartedSystems`, `persGrudges`,
  `defeatedPers`, `shownPersQuotes`) — optional specifically so old `pilot.json`
  saves still decode. `Tests/.../*` round-trip tests cover this.
- `WorldEvent` gained cases (`shipBoarded`, `shipCaptured`, `personGrudge`,
  `personDefeated`); both switch consumers (`GameScene`, `novaswift-extract`)
  have a `default`, so they should be safe.
- App concurrency: the new scene→host closures (`onPlayerScanned`,
  `onPersGrudge/Defeated`, `persSpawnEligible`) follow the existing `jumpCommit`
  pattern (plain, non-`@MainActor` closures invoked on the main thread). If
  strict-concurrency checking is on, these may want annotation.

---

## What shipped

### Part 1 — Outfitter / modifier / license audit

All grounded in `oütf` Bible fields; see `docs/reverse-engineering/OUTFITTERS.md`
(status table updated).

| Mechanic | Status | Where |
|---|---|---|
| **Map outfit (ModType 16)** — scoped reveal, not whole-galaxy | ✅ | `NovaGame.mapRevealedSystems`, `PlayerState.chartedSystems`, `applyOutfitAcquisition` |
| Clean legal record (ModType 21) | ✅ | `PlayerState.applyOutfitAcquisition` |
| Mass-proportional price (Flags 0x0200) | ✅ | `PilotStore.effectiveCost` |
| Fixed-gun/turret slot enforcement (0x0001/0x0002) | ✅ | `PilotStore.canBuyOutfit` |
| Increase-maximum (ModType 27) | ✅ | `NovaGame.effectiveMaxInstallable` |
| Sell-anywhere tech bypass (0x0800) | ✅ | `NovaEconomy.outfitsSold` |
| OnPurchase / OnSell NCB (@301/@556) | ✅ | `PilotStore.runOutfitScript` |

### Part 2 — Combat / world systems (Phases 1–6)

| Phase | System | Status | Key files |
|---|---|---|---|
| 1 | Boarding capture-odds (crew/marines/strength) | ✅ engine + tested; UI already existed | `World.captureChance`, `ShipLoadout` (marines) |
| 2 | Contraband scanning & fines | ✅ engine/story/app | `Contraband.swift`, `ContrabandScan.swift`, `GameHost` scan wiring |
| 3 | Fighter bays (Guidance 99) | ✅ engine + tested | `World.updateFighterBays`, `FighterBaySpec` |
| 4 | Cloak / cloak-scanner / interference / murk | ✅ engine + app toggle | `World.stepCloak`/`canDetect`/`effectiveSensorRange` |
| 5 | ItemClass loot + escape-pod detection | ✅ engine/app | `PersModels`, `World.takePlunderOutfits`, `Spawner` |
| 6 | Full pêrs: hail quotes, link missions, grudges | ✅ engine/story/app | `PersEncounter.swift`, `World.playerPersGrudges` |

---

## Data offsets confirmed this session (reference)

Verified empirically against the shipped `.rez` records (put these into the
per-resource docs / `NovaAIModels` comments if not already there):

- `gövt.ScanMask` **@50** (`WB16`). Hierarchical faction mask; shares
  `mïsn.ScanMask@24`'s bit-space. Fed `0x8000`, sub-factions inherit it
  (Bureau `0x8008`, Civvies `0x8010`).
- `sÿst.Interference` **@108**, `sÿst.Murk` **@146** (both `0-100`; validated
  across 545 systems — interference max 80, murk max 50).
- `wëap` fighter bay: `Guidance@8 == 99`, `AmmoType@12` = fighter `shïp` id,
  `MaxAmmo@108` = fighters carried (Viper Bay 4, Thunderhead 3), `Reload@0` =
  launch interval.
- `oütf.ItemClass@1004`: stock data uses **only class 25** (one outfit) — the
  loot mechanic is intentionally rare in the base game.
- `përs` (400-byte record): `LinkSyst@0 Govt@2 AIType@4 Aggress@6 Coward@8
  ShipType@10 WeapType[4]@12 WeapCount[4]@20 AmmoLoad[4]@28 Credits@36(i32)
  ShieldMod@40 HailPict@42 CommQuote@44 HailQuote@46 LinkMission@48 Flags@50
  ActiveOn@52(NCB,255) GrantClass@308 GrantProb@310 GrantCount@312`. Confirmed
  against story characters (Terrapin, Jack Folstam, Dr Ralph). Note the on-disk
  order differs from the Bible's narrative order; the weapon arrays are 4-wide.

---

## Follow-ups / what's left

### A. pêrs system — remaining polish
- **In-flight LinkMission dialog.** Hailing/boarding a named person *offers* the
  mission (resolved by `PersEncounter.offeredMission`) but the app currently
  surfaces it as a HUD pointer, not a full accept/decline panel in flight. Wire
  it to the same offer flow the bar uses (`StoryEngine.present` /
  `services.pendingOffer`) so it can be accepted mid-flight. Flags to honor on
  accept: `0x0040` replace-with-SpecialShip, `0x0100` deactivate-after,
  `0x0800` leave-after, `0x0100`/`quoteOnce` bookkeeping.
- **pêrs weapon customization.** `WeapType/WeapCount/AmmoLoad[4]` are decoded but
  not yet layered onto the spawned hull — `Spawner.applyPersonCustomization`
  applies `ShieldMod` + `Credits` only. Add the extra weapon mounts (respecting
  the "negative count removes stock weapons" rule).
- **HailPict in the comm dialog.** `PersHailResult.hailPictID` is resolved but
  the hail dialog doesn't render the custom `PICT` yet.
- **HailQuote attack-context (flag 0x0010).** Shown only "when the ship begins
  to attack the player" — there's no attack-start hook feeding
  `PersEncounter.hail(disabled:)`; only hail/board/disabled contexts are wired.
- **`showsDisasterInfo` (0x8000)** and the `Aggress`/`Coward` AI tuning fields
  are decoded but not consumed by the brain.

### B. Sensors / cloak
- **Murk fog rendering.** `World.systemMurk` (+ `Loadout.murkModifier`) is
  exposed; the actual visual fog overlay in `GameScene` is not drawn. Bible: a
  murk `< 0` also hides the starfield.
- **Cloak flag 0x1000 (area cloak).** Decoded (`cloakIsArea`) but formation-mates
  of an area-cloaker are not themselves cloaked yet.
- **Cloak scanner radar/screen reveal (0x0001/0x0002).** `canDetect` uses the
  "target cloaked" bit (0x0008); the "show cloaked on radar/screen" bits are not
  fed to the HUD/renderer.
- **Interference "fuzz" is applied to AI sensor *range* only.** The Bible frames
  it as radar fuzziness; the player HUD radar doesn't yet degrade with it. The
  linear `range × (1 − interference/100)` curve is an engine reading of the
  0/100 endpoints.
- **`gövt.InhJam1-4` + weapon jam/interference `Seeker` bits** (0x0008 confused
  by interference, 0x0010 turns away if jammed) — decoded elsewhere, not
  consumed by guided-weapon behavior.

### C. Boarding / escape pods
- **Escape-pod survival.** `Loadout.hasEscapePod`/`hasAutoEject` (ModType 11/20,
  `shïp.EscapePod`) are detected but not wired into the player's death handler —
  surviving destruction in a pod (and auto-eject) is not implemented.
- **NPC cargo holds.** `takePlunderCargo` works, but NPCs still spawn with empty
  holds (no `düde.Booty`/random-cargo system), so cargo plunder is usually
  empty. See `düde.Booty` in the Bible (flags defining boarding yield).
- **pêrs boarding LinkMission** (flag 0x0200) is resolved but only noted via HUD;
  same dialog gap as A.

### D. Modifiers still inert (low priority; small or need a host system)
- `densityScanner` (13), `IFF` (14) — radar/HUD rendering only (Bible marks both
  "ignored" mechanically; they're display features).
- `miningScoop` (31), `inertialDamper` (38), `deionize`/`ionCapacity` (39/40),
  `gravityResist` (41), `stellarResist` (42), `paint` (43),
  `reinforcementInhibitor` (44), `bomb`/`nonlethalBomb` (47/50),
  `iffScrambler` (48), `repairSystem` (49) — decoded enum cases, no consuming
  system yet. `hyperspaceDist` (23, no-jump-zone radius) likewise.
- Outfit `Flags 0x1000` (DispWeight-tier suppression) and `0x2000`
  (Ranks-section) — still unimplemented (see OUTFITTERS.md §3.6 / §9).
- Persistent-across-mission-swap outfit flag `0x0020` (distinct from the
  ship-trade `0x0004` which *is* handled).

### E. Fighter bays — edge cases
- Fighters currently auto-deploy when the carrier is in combat and dock when out
  of ammo / hurt / the carrier disengages; there's no explicit player
  launch/recall command. A carrier's death orphans live fighters (they keep
  their government). Consider a player "launch/recall fighters" control.

---

## Testing status

New unit tests (pure logic, no app layer needed — they build synthetic
resources):

- Kit: `OutfitMechanicsTests`, `ContrabandTests`, `SystemFieldTests`,
  `PersTests` (+ full decode).
- Engine: `BoardingTests`, `FighterBayTests`, `CloakTests`.
- Story: `OutfitAcquisitionTests`, `ContrabandScanTests`, `PersEncounterTests`.

Not covered by unit tests (need the app/SpriteKit layer, so verify by play):
the scan-fine HUD flow, boarding-loot grant, cloak keybind, hail-quote dialog,
and grudge persistence across jumps.
