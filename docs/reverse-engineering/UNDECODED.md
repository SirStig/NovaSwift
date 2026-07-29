# Undecoded & unwired — the remaining fidelity gap

*Audited 2026-07-28 against `ccdf827`, by diffing every field name and flag bit
in `data/EV Nova/Documentation/Nova Bible.txt` against what `NovaSwiftKit`
actually decodes, and every decoded `public let` against whether any
production (non-test) code reads it.*

Unlike the other docs in this folder, this one is **not** organised by
resource — it's organised by *how far short of the original we fall*, so it can
be worked top-down. Method notes are at the bottom so the audit is repeatable.

Everything here was verified in code, not inferred from the other docs. Items
that turned out to be complete (all 27 resource types decode; fighter bays,
point defense, message buoys, `SpecialTech`, `ïntf` HUD regions, tractor beams,
submunitions, ionization, cloak, murk/interference, reinforcement fleets,
`AstTypes`) are deliberately absent.

---

## 1. Documented in the Bible, never decoded

| Gap | Bible says | What we do instead |
|---|---|---|
| **`wëap` JamVuln1-4** | "The weapon's vulnerability to the four different types of jamming, from 0 to 100%." | Not decoded at all. `ShipLoadout.swift:386` sums `oütf` ModTypes 33-36 into one scalar `jamming`, and `World.swift:2307-2308` computes `govtJam + t.jamming` clamped 0-100. A govt with four 50-point inherent jam values reads as **100% jam against every seeker**. Four independent jam types collapsed into one blunt scalar. |
| **`spöb.Fee` @564** | "The fee that is deducted from the player's credits when landing" | No field on `SpobRes`. The offset is named in a comment at `NovaModels.swift:820` while explaining its neighbours, then skipped. Landing is always free. |
| **`spöb.Gravity` @568** | "0 for none, positive for stellars that…" (pull/push on nearby ships) | No field. Both immunities are fully plumbed — `shïp.Flags3` 0x0010 → `ShipRes.ignoresGravity`, `oütf` ModType 41 → `Loadout.hasGravityResist`, folded at `ShipLoadout.swift:592` — but there is no force to be immune to. |
| **`spöb.DeadTime` @578** | "The amount of time a stellar remains destroyed before it [regenerates]" | Not decoded. Only `DestroyedGraphic`@576 is read (`NovaModels.swift:213`). `onRegen` is decoded and handled at `StoryEngine.swift:120`, but **nothing ever schedules a regeneration**, so that branch is dead. Destroyed stellars are permanent. |
| **`spöb.ExplodType` @580** | stellar death explosion | Not decoded — a destroyed stellar just disappears. |
| **`spöb.Flags2` 0x0040 / 0x0400 / 0x0010** | starts destroyed / outfit shop buys used outfits / loop the stellar's sound | Not decoded. |
| **`shän` Alt layer** — AltImageID, AltMaskID, AltSetCount, AltXSize, AltYSize | "Sprites from the alt sprite sets can be displayed on top of the basic sprite for the ship, cycling through each available set" | `ShanRes` (`NovaModels.swift:101`) decodes base / engine / light / weapon-glow / shield layers only. The alt layer has no field. |
| **`shän.BaseTransp`** | "inherent transparency of the basic sprite images, 0-32" | Not decoded — hulls always render fully opaque. |
| **`wëap.SmokeSet`** | "Which cicn set to use for this weapon's smoke trail (0 = cicn 1000-1007…)" | Not decoded. `generatesSmallSmoke` / `generatesBigSmoke` / `persistentSmoke` all decode from `Flags`, but the icon set they should draw does not. |

## 2. Weapon flag bits never decoded

Census of the mask literals in `NovaAIModels.swift`'s `WeapRes` against the
Bible's four flag tables. Bits in **bold** change behaviour, not just looks.

**`Flags`** — decoded: 0x0001, 0x0002, 0x0010, 0x0020, 0x0040, 0x0080, 0x0200,
0x0400, 0x0800, 0x8000. Missing:

- `0x0004` cycling weapons always start on the first frame
- **`0x0008` for guided weapons, don't fire at fast ships (turn rate > 3)**
- **`0x0100` weapon's blast doesn't hurt the player**
- **`0x1000` / `0x2000` / `0x4000` turreted weapon has a blind spot to the front / sides / rear**

**`Flags2`** — decoded: 0x0008, 0x0010, 0x0020, 0x0200. Missing:

- `0x0004` proximity detonator ignores asteroids
- `0x0040` don't show ammo quantity on the status display
- **`0x0080` weapon only fires with a `KeyCarried`-type ship aboard**
- **`0x0100` AI ships won't use this weapon**
- **`0x0400` planet-type weapon — can only hit planet-type ships or destroyable
  stellars.** Directly relevant to `StellarWeapons.swift`.
- `0x0800` don't allow selection/display when out of ammo
- **`0x1000` weapon can disable but not destroy**
- `0x2000` for beams, draw underneath ships instead of on top
- **`0x4000` weapon can be fired while cloaked**
- **`0x8000` weapon does ×10 mass damage to asteroids**

**`Flags3`** — fully decoded (0x0001, 0x0002, 0x0004, 0x0010, 0x0020).

**`Seeker`** — decoded: 0x0008, 0x0010, 0x0020. Missing:

- `0x0001` passes over asteroids
- `0x0002` decoyed by asteroids
- **`0x4000` loses lock if target is not directly ahead**
- **`0x8000` may attack parent ship if jammed**

## 3. Fidelity deviations — implemented, but not the way Nova does it

### NPCs are given the hull's `DefaultItems`

The Bible, on `shïp.DefaultItems`: *"Up to eight default items with which to
equip this ship **when the player buys or captures one**. Note that
AI-controlled ships will ignore these fields."*

We ignore that. `Galaxy.loadout(shipID:extraOutfits:)` unconditionally merges
the hull's preinstalled outfits:

```swift
// ShipLoadout.swift:298-300
for (oid, c) in s.outfits { outfitCounts[oid, default: 0] += c }
```

and `Spawner.swift:603` routes **every** NPC through `makeLoadedShip`, which
calls exactly that. So spawned NPCs fly with afterburners, shield boosters and
extra fuel the original never gives them — measurably stronger than authentic,
and it skews every combat-odds calculation downstream.

The correct split: NPC armament comes from `shïp`'s own WeapType/WeapCount/
AmmoLoad list (already decoded separately, `NovaModels.swift:355`) plus `përs`
overrides (`Spawner.applyPersonWeapons`). `DefaultItems` should apply on the
player-purchase and capture paths only.

### Animated stellars don't animate

`spöb.AnimDelay`, `Frame0Bias`, and `Flags2` 0x0001 / 0x0002 / 0x0080 are not
decoded. Every stellar renders as a static frame.

### shän overlay layer dimensions are read and discarded

`engineWidth`/`engineHeight`, `lightWidth`/`lightHeight`,
`weaponGlowWidth`/`weaponGlowHeight`, `shieldWidth`/`shieldHeight` are all
decoded on `ShanRes` and read by no production code. `ShanRes`' own doc comment
cites shän #131 "Leviathan", whose engine layer is 180×180 against a 144×144
base — those overlays are being laid out against base dimensions.

### Asteroids are stationary

A deliberate call, documented at `Asteroid.swift:6-9`: the Bible specifies no
position/velocity field for `röid`, only `SpinRate`, so rocks are scattered once
on system entry and spin in place. Defensible from the source data — but the
original does drift them, so this is a visible difference. Logged here rather
than in §1 because it's a decision, not an oversight.

## 4. Decoded, but zero production consumers

Found by scanning every `public let`/`var` declared in `NovaSwiftKit` for `.name`
reads anywhere outside `Tests/`. These all parse correctly and are covered by
the extractor and/or unit tests; nothing in the play loop reads them.

| Resource | Field(s) | What the player is missing |
|---|---|---|
| `ränk` | `permanent`, `freeRepairRefuel` (flags 0x0800) | Rank perks — free repair/refuel at the granting govt's worlds, and ranks that can't be lost |
| `spöb` | `landableOnlyWhenDestroyed` (Flags 0x0080) | Decoded **twice** — `NovaModels.swift` and `NovaEconomy.swift:129` — consumed zero times. Stellars gated behind "destroy me first" are landable anyway |
| `mïsn` | `quickBriefText` | `StoryEngine.swift:1205` synthesizes a quick brief by collapsing the full offer text rather than using the real STR# |
| `mïsn` | `refuseText` | No text shown when the player declines a mission |
| `mïsn` | `shipSubtitleStrID` | Mission ships carry no subtitle on the target display |
| `mïsn` | `invisible` (flags1 0x0400) | Missions flagged hidden still appear in the list |
| `cölr` | `menuFontSize`, `progressBar` (ProgDim), `buttonFontSz`, `slide1-3` | Interface theming data decoded but never applied to the UI |
| `oütf` | `outfitterName`, `lowercaseName`, `lowercasePlural`, `ignoresRequirements`, `persistsOnShipTrade` | Per-outfitter display names; correct running text ("2 fuel scoops"); two purchase/retention rules |
| `jünk` | `lowercaseName`, `statusBarAbbrev` | Junk cargo has no running-text or status-bar form (blocked behind the junk UI generally — see JUNK_OOPS_DESIGN.md) |
| `përs` | `showsDisasterInfo` (flags 0x8000) | Named captains who'd tell you about active `öops` disasters |
| `öops` | `isNewsOnly` | Disasters that should only surface as news |
| `shïp` | `deathDelay`, `inherentGovt`, `showArmorOnTargetDisplay` | Per-hull death-animation length; hull-inherent government; armor bar on the target display |
| `chär` | `startingSystems`, `datePrefix` | Only `.first` is ever used (`startingSystem`), so multi-start scenarios always pick slot 0 |
| `wëap` | `WeaponParticleSpec.lifeMin` | Particle lifetime is effectively fixed rather than ranged |

---

## Method

Repeatable, and worth re-running after any decoder work:

1. `iconv -f MACROMAN -t UTF-8 "data/EV Nova/Documentation/Nova Bible.txt"`
   (the file is Mac-Roman with CRLF — grep silently finds nothing otherwise).
2. Extract `^\*\s*The (\S+) resource` section headers and, within each, field
   names matching `^([A-Z][A-Za-z0-9]{2,20})\s\s+\S`.
3. Case-insensitively substring-match each field name against a corpus of every
   `.swift` and `.md` file under `Sources/`, `app/NovaSwift/`, `Tests/` —
   **excluding `.claude/worktrees/`**, which holds concurrent agent checkouts
   that are often ahead of `main` and will mask real gaps.
4. Manually triage the misses: most are naming differences (`GuidedTurn` →
   `turnRate`, `ExplodType` → `explosionBoomID`, `LCPlural` →
   `lowercasePlural`). Only confirm a gap by reading the decoder's field list.
5. For flag bits, enumerate `grep -oE "flagsN? & 0x[0-9A-Fa-f]{4}"` per decoder
   and diff against the Bible's flag table for that resource. Watch for masks
   applied inside `init` rather than in a computed property (`loopSound` is set
   from `flags & 0x0010` at decode time).
6. For dead data, parse every `public let`/`var` per struct and count
   `\.<field>\b` occurrences across production vs. test sources separately.
   Beware fields consumed only by a computed property in the same file
   (`DudeRes.carriesFood` etc. feed `bootyCommodities`, which *is* live) — those
   are not dead.
