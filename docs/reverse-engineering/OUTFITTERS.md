# The Outfitter — availability, pricing, and buy/sell mechanics

Source: `data/EV Nova/Documentation/Nova Bible.txt` (the official Ambrosia/Matt
Burch "Resource Bible", ©1995-2004). The `oütf` resource is documented at
lines 1819-2108 of that file; the ship-purchase (`shïp`) fields it shares
mechanics with are at lines ~2600-2695. The NCB control-bit test-expression
primer is at lines ~97-150. Every field/quote below is a direct quote or close
paraphrase of that document — this is a spec doc, not behavior reverse-guessed
from play. See `docs/AI_GROUND_TRUTH.md` for the sibling doc on AI, and
`docs/SHIP_SYSTEM.md` for how a bought outfit's *stat modifiers* actually fold
into a ship (`Galaxy.loadout`) — this doc does not re-derive that math, only
the shopfront logic: what's for sale, where, at what price, under what
conditions.

Note on encoding: `Nova Bible.txt` is Mac OS Roman with CRLF line endings, not
UTF-8 — plain `grep` silently finds nothing in it unless you decode first
(`python3 -c "open(...).read().decode('mac_roman')"` or equivalent); this bit
several of the greps while researching this doc.

## Implementation status (updated after the outfitter wiring audit)

**Outfitter wiring audit (this pass).** A follow-up pass closed the remaining
"decoded/computed but not wired" gaps the earlier passes had catalogued below,
plus fixed a real behavior bug in the map outfit. All are grounded in the Bible
ModType/Flags text (cross-checked against the andrews05 EV Nova Bible mirror) —
no invented logic:

- **Map outfit (ModType 16) — behavior fix.** Previously *any* map outfit
  revealed the **entire galaxy** (`PilotStore.ownsMapOutfit` → a
  `mapRevealAll` boolean). That is wrong: the Bible's ModVal is "1 and up = how
  many jumps away from present system to explore; -1 = all inhabited independent
  systems; -1000 & down = all systems of that govt class." Now a one-shot reveal
  is computed at acquisition (`NovaGame.mapRevealedSystems(modVal:from:)`) and
  recorded in a new `PlayerState.chartedSystems` set — kept distinct from
  `exploredSystems` so a bought chart never satisfies an NCB `Exxx`
  "have-you-been-there" gate. Wired at both acquisition points (shop
  `PilotStore.buyOutfit` and mission grant `StoryEngine.grantOutfit`).
- **Clean legal record (ModType 21)** now applied on acquisition
  (`PlayerState.applyOutfitAcquisition`): clears standing with the ModVal govt,
  or all govts when ModVal is -1. ✅
- **Mass-proportional price (Flags 0x0200)** now charged/refunded via
  `Galaxy.effectiveCost` in `PilotStore.buyOutfit`/`sellOutfit`/`canBuyOutfit`/
  `tradeInValue` (was computed but never charged). ✅
- **Fixed-gun/turret slots (Flags 0x0001/0x0002)** now enforced at purchase —
  `PilotStore.canBuyOutfit` rejects a buy when `freeGunSlots`/`freeTurretSlots`
  is 0 (was computed but not enforced). ✅
- **Increase-maximum (ModType 27)** now consumed at purchase via
  `NovaGame.effectiveMaxInstallable` (base Max × owned expanders pointing at the
  item); `canBuyOutfit` checks that effective cap (was decoded but inert). ✅
- **Sell-anywhere (Flags 0x0800)** now bypasses the upstream tech-level filter in
  `NovaEconomy.outfitsSold`, not just the Require/Availability check (§3.5). ✅
- **OnPurchase/OnSell (@301/@556)** now decoded on `OutfRes` and executed via
  `StoryEngine.apply(set:)` on buy/sell — permits/licenses that flip story bits
  now work (§3.3a). ✅

## Implementation status (updated after the mass-cost/slot-tracking/sell-flag pass)

Since this doc was first written, a follow-up implementation pass landed real
Swift for several of the gaps identified below:

- **`OutfRes` decoding** (`Sources/NovaSwiftKit/NovaAIModels.swift`): `itemClass`
  (`@1004`) and `scanMask` (`@1006`) are now decoded fields on `OutfRes` (they
  were previously confirmed-by-offset-only, not present in code). Neither is
  consumed by any behavior yet — see §6.
- **Mass-proportional mass** (`Flags 0x0400`): now fully implemented and
  wired — `OutfRes.massIsShipMassProportional`/`.effectiveMass(shipMass:)`
  (`Sources/NovaSwiftEngine/ShipLoadout.swift`) are consumed inside
  `Galaxy.loadout`'s `usedMass` aggregation. ✅
- **Mass-proportional price** (`Flags 0x0200`): the *decoding and math* landed
  the same way (`OutfRes.priceIsShipMassProportional`/`.effectiveCost(shipMass:)`),
  but it is **not wired into the shop** — `PilotStore.buyOutfit`/`sellOutfit`
  (`app/NovaSwift/Game/PilotStore.swift`) still charge/refund the flat `o.cost`
  and never call `effectiveCost`. Verified directly against the current file
  contents for this update. ⚠️ computed, not charged.
- **Gun/turret slot tracking**: `Loadout.usedGunSlots`/`usedTurretSlots`/
  `freeGunSlots`/`freeTurretSlots` are now computed in `Galaxy.loadout`
  (`ShipLoadout.swift`), fed by the newly-added `OutfRes.isFixedGunOutfit`/
  `.isTurretOutfit`. But `PilotStore.canBuyOutfit` still only checks
  affordability, free mass, and `maxInstallable` — it never reads
  `freeGunSlots`/`freeTurretSlots`, so a player can still buy more gun/turret
  outfits than the hull has mounts for. ⚠️ computed, not enforced.
- **Can't-sell (`Flags 0x0008`) and consumed-on-purchase (`Flags 0x0010`)**:
  both are now decoded *and* enforced in `PilotStore.swift` — `sellOutfit`
  rejects a sale when `0x0008` is set, and `buyOutfit` grants then immediately
  `removeOutfit`s when `0x0010` is set. ✅ both fully done.

Everything else in the table below (OnPurchase/OnSell side effects, ModType 27
increase-max, persistent-on-trade flags 0x0004/0x0020, DispWeight suppression
0x1000, Ranks-section 0x2000, outfitter display-name strings) is unchanged
from the original findings — still not implemented.

## 1. What the `oütf` resource is

> "Outf resources store information on the items that you can buy when you
> choose 'Outfit Ship' at a planet or station."

Up to 512 outfit types (`Max Outfit Item Types 512`, Bible Part I). Every
purchasable non-hull item — weapons, ammo, shield/armor boosters, fuel tanks,
cloaks, gadgets, permits — is one `oütf` resource. There is no separate
"weapon shop" resource; weapons are outfits with `ModType = 1`.

## 2. Categories/slots and mass cost

Field | Meaning
---|---
`DispWeight` | Sort order in the outfitter list — "items with a higher display weight are shown closer to the top." Purely cosmetic ordering, not a slot/category.
`Mass` | Tons of free mass the item consumes (0 = no appreciable mass), from `shïp.FreeMass` — its own separate budget from `Holds` (cargo). Earlier text here claimed outfits and cargo "share one mass budget"; that's not supported by the Bible (`FreeMass` line 2422: "space available to add additional items and upgrades... in addition to the space taken up by the ship's stock weapons" — a distinct pool from `Holds`, line 2407). An outfit can still trade one for the other explicitly via two ordinary fields on the same item — negative `Mass` frees equipment budget, a negative ModType-2 (`freeCargo`) modifier shrinks the cargo hold (e.g. stock "Mass Expansion": `Mass -10`, `freeCargo -15`) — but that's the *outfit's* doing, not an engine-level shared pool. `shïp.Holds`'s negative-sign convention ("prevent the player from purchasing mass expansions", line 2408) gates exactly that: `ShipRes.blocksMassExpansion`, enforced in `PilotStore.canBuyOutfit` against any outfit with a negative `.freeCargo` value.
`Flags 0x0001` | "This item is a fixed gun" — installs into a **gun** mount.
`Flags 0x0002` | "This item is a turret" — installs into a **turret** mount.
`Flags 0x0400` | "This item's total mass (at purchase) is proportional to the player's ship's mass" — `shipClass.Mass × outfit.Mass / 100`. Positive-mass items only.

There is no separate "outfit slot" system beyond mass and the fixed-gun/turret
flags: a hull just declares `MaxGuns`/`MaxTurrets` counts (`shïp` @42/@44), and
any `oütf` flagged 0x0001/0x0002 competes for those slots. Everything else
(shield boosters, cargo pods, cloaks, etc.) only consumes mass, no dedicated
slot. `ModType 45`/`46` ("modify max guns"/"modify max turrets") let an outfit
itself add or remove gun/turret capacity (e.g. a gun-mount-adding pod).

Cross-reference: `Sources/NovaSwiftEngine/ShipLoadout.swift` sums `.maxGuns`/
`.maxTurrets` modifiers into the hull's counts (lines 106, 136-137) — that's
the *aggregation* math and is already covered by `docs/SHIP_SYSTEM.md`.

## 3. Availability gating

Three independent gates must all pass for an item to be **purchasable**; a
fourth pair of flags controls whether a failing item is shown greyed-out or
hidden outright.

### 3.1 Tech level

> "TechLevel: What the technology level of the item is. This item will be
> available at all spaceports with a tech level of this value or higher. (The
> exception to this rule involves the SpecialTech fields of the spöb
> resource...)"

I.e. `outfit.techLevel <= spob.techLevel` OR `spob.techLevel` is overridden by
one of the stellar's specific `SpecialTech` grants. Implemented:
`NovaEconomy.sells(techLevel:at:)` (`Sources/NovaSwiftKit/NovaEconomy.swift:165-166`):
`techLevel <= spob.techLevel || spobSpecialTech(spob.id).contains(techLevel)`.
Tech-level failure **fully removes** the item from the list — it's the only
gate the Bible doesn't soften with a "still shown, greyed out" fallback.

### 3.2 `Availability` — the NCB test expression

> "Availability: Control bit test expression. Leave blank if unused. Note that
> depending on the configuration of other flags, the item might appear in the
> outfit window even if Availability is false (it will still not be able to be
> purchased)."

This is the same test-expression grammar used everywhere else in Nova (missions,
ship purchase, etc.), from the Bible's control-bit primer (lines ~97-150):

```
Bxxx   value of control bit xxx (b0..b9999)
Pxxx   1 if registered, or unregistered < xxx days elapsed
G      player's gender (1 male, 0 female)
Oxxx   1 if player has >=1 of outfit item ID xxx (fighters-in-bay count too)
Exxx   1 if player has explored system ID xxx
| & !  or / and / negation;  ( )  grouping
```
"if you leave the field for a test expression blank, it will evaluate to true
as a default." Implemented: `NCBTest` (evaluated in `ItemLocking.swift:54`,
`.evaluate(pilot)`), reading `OutfRes.availBits` (`@46`, up to 255 chars).

### 3.3 `Contribute`/`Require`/`RequireGovt` — cross-item and per-government gating

> "Require... logically and'ed with the Contribute fields from the player's
> current ship and outfit items. If for each 1 bit in the Require fields there
> is a matching 1 bit in one or more of the Contribute fields, the item will be
> available."

So `Contribute` is a 64-bit tag an owned ship/outfit broadcasts (e.g. "I am a
military-grade hull"), and another outfit's `Require` demands a subset of those
tags be present among everything the player currently owns/flies — a form of
prerequisite/permit gating independent of the NCB bit system.

`RequireGovt` scopes *where* the `Require` check even applies:

RequireGovt value | Scope
---|---
`-1` | Everywhere
`128-383` | Only at stellars belonging to this govt or its allies
`1128-1383` | + independent stellars
`2128-2383` | All stellars **except** this govt/allies
`3128-3383` | All-but, **+** independent excluded too

Outside its scope, the `Require` gate simply doesn't apply (item is available
there regardless of what the player owns).

Implemented: `Sources/NovaSwiftKit/NovaAIModels.swift` decodes `contribute` (`@30`),
`require` (`@38`), `requireGovt` (`@1010`) on `OutfRes`. Logic in
`app/NovaSwift/Spaceport/ItemLocking.swift`:
- `contributedBits(pilot:)` (lines 29-41) ORs the current ship's `contribute`
  with every owned outfit's `contribute`.
- `requireGovtApplies` (lines 48-60) implements the four range cases above.
- `lockState(for:pilot:at:diplomacy:)` (lines 63-70) combines Availability +
  Require-if-in-scope into the final available/locked/hidden state.

### 3.3a `OnPurchase`/`OnSell` — side-effect control-bit sets

> "OnPurchase: Control bit set expression. Leave blank if unused." /
> "OnSell: Evaluated when the item is sold."

Distinct from `Availability` (a *test*, read-only, gates the Buy button):
these two are NCB **set** expressions, evaluated as a side effect of the
transaction itself (buying/selling this specific outfit can flip other
control bits — e.g. a permit purchase marking a bit a mission later checks).
Offsets confirmed at `@301`/`@556` respectively (§8). **Fixed in the outfitter
wiring audit**: both are now decoded as `OutfRes.onPurchase`/`.onSell` and run
through the story engine's set-op executor (`PilotStore.runOutfitScript` →
`StoryEngine.apply(set:)`) as a side effect of buying/selling — so a permit
that gates story progress on "player *bought* item X" now flips its bit.
(A mission-*granted* outfit deliberately does not fire OnPurchase — it wasn't
"bought"; its map/record modifier effects still apply.)

### 3.4 Shown-but-locked vs. fully hidden

Both gates above can fail without removing the item from the list — the Bible
default is "shown, can't buy":

> "0x0100 Don't show this item unless the player meets the Require bits, or
> already has at least one of it." / "0x4000 Don't show this item unless its
> Availability evaluates to true, or if the player already has at least one of
> it."

So the *default* (neither flag set) is: show it anyway, just disable Buy. Only
items opting into 0x0100 (hide-on-failed-Require) or 0x4000
(hide-on-failed-Availability) disappear from the grid entirely — and even then,
owning ≥1 already forces it visible. Implemented: `OutfRes.hidesWhenLocked`
(`flags & 0x0100 != 0 || flags & 0x4000 != 0`), consumed by `LockState` in
`ItemLocking.swift` (`.available` / `.locked` / `.hidden`) and filtered in
`OutfitterView.stock` (`app/NovaSwift/Spaceport/SpaceportScreens.swift:163`).

### 3.5 The "sell anywhere" escape hatch (sell-side only)

> "0x0800 This item can be sold anywhere, regardless of tech level,
> requirements, or mission bits."

This bit is documented under **selling**, not buying: it means a *player who
already owns* one of these can sell it back at any outfitter, without that
port needing to stock the item (i.e. it waives the normal
same-tech-level/stock check a sell-back would otherwise be subject to). It is
not a buy-listing bypass — the Bible's own worked example for this class of
item, ARPIA2's "Frandall Laser" (`techLevel` 9999, an NPC-only `Require`
combo), would otherwise show up as purchasable in every outfitter in the
galaxy if 0x0800 were treated as a buy-side escape hatch.

Implemented as `OutfRes.ignoresRequirements` (`flags & 0x0800`). It is **not**
consulted by `NovaGame.outfitsSold`'s tech-level filter (`sells(techLevel:at:)`
in `NovaEconomy.swift`) nor by `lockState(for:pilot:at:spob:diplomacy:)` in
`ItemLocking.swift` — both buy-side gates apply normally regardless of this
flag. (Earlier revisions of this doc and the code incorrectly OR'd
`ignoresRequirements` into both the tech-level filter and the lock-state
check; this has been reverted — see the outfit buy-listing tech-gate fix.)

There is currently no stock/tech-level restriction on the *sell-back* path
itself (`PilotStore.sellOutfitUnit`) to waive: any owned, sellable
(`flags & 0x0008 == 0`) outfit can be sold back at any outfitter today, so
0x0800 has no further effect there in this build. If a sell-back stock
restriction is ever added, it should OR in `ignoresRequirements` to match the
Bible's "sold anywhere" wording.

### 3.6 The "suppress a rival item" flag

> "0x1000 When this item is available for sale, it prevents all
> higher-numbered items with equal DispWeight from being made available for
> sale at the same time."

Not decoded or implemented anywhere (`0x1000` doesn't appear in
`OutfRes`/`ItemLocking.swift`/`OutfitterView`). This is a real Bible mechanic
(plugin authors use it for "buy the deluxe version OR the base version, never
both" style listings) with no current code path.

## 4. Pricing

Field | Meaning
---|---
`Cost` | Base credits charged (Int32/`DLNG`, `@14`, confirmed — see §8). Refund on sell is the **same** value — the Bible has no separate sell-price field for outfits (unlike commodities, which have buy/sell spreads via `PriceLevel`).
`Flags 0x0200` | "This item's total price is proportional to the player's ship's mass. (ship class Mass field is multiplied by this item's Cost field)" — i.e. actual charge = `shipClass.Mass × outfit.Cost`, not the flat `Cost` shown. `Flags` itself is already decoded at the correct offset (`@12`, `WORV`, confirmed — see §8); this is a decoding-*consumption* gap (the bit is never read), not an offset-hunting one.

`OutfRes.cost` is decoded (`NovaAIModels.swift`) and used directly as the
displayed/charged price in `OutfitterView.info` and `PilotStore.buyOutfit`/
`sellOutfit` (`app/NovaSwift/Game/PilotStore.swift:214-242`) — full refund on
sell, matching the Bible's flat-refund model. **Gap (partially closed)**:
`Flags 0x0200` (mass-proportional pricing) is now decoded
(`OutfRes.priceIsShipMassProportional`) and the correct math exists
(`OutfRes.effectiveCost(shipMass:)` / `Galaxy.effectiveCost(of:forShip:)` in
`Sources/NovaSwiftEngine/ShipLoadout.swift`). **Fixed in the outfitter wiring
audit**: `PilotStore.effectiveCost` now calls `Galaxy.effectiveCost` and is
used for the affordability check, the charge, the sell refund, and the ship
trade-in valuation — so a mass-scaled-price outfit is charged/refunded at
`shipMass × Cost` on the player's current hull, not flat `Cost`.

Commodities (the separate Trade Center, not outfits) do have a genuine
buy/sell spread via `PriceLevel` (`NovaEconomy.swift`) — that's a different
resource (`Cömm`/market pricing) and out of scope for this doc.

## 5. Ammo/weapon linkage

The `oütf` resource's `ModType`/`ModVal` pair is how an outfit *is* a weapon or
its ammo — there's no separate "ammo" resource:

ModType | Meaning | ModVal
---|---|---
`1` | It's a weapon | ID of the associated `wëap` resource
`3` | It's ammunition | ID of the associated `wëap` resource **it feeds**

**The Weapon/Ammo `ModVal` is a true union at a single shared offset, `@8`
(confirmed against real data — see §8).** ResForge's `oütf` TMPL (`Templates.rsrc`
id 513) encodes the *primary* modifier slot as a `KWRD` selector (`ModType`,
2 bytes) immediately followed by a `KEYB`/`KEYE`-guarded union body that is
`RSID Weapon='wëap'` when `ModType==1` and `RSID Weapon Ammo='wëap'` when
`ModType==3` — i.e. the editor's template genuinely declares ONE reserved
slot for the id, reinterpreted by case, not two sequential 2-byte reservations
(the naive `novaswift-extract tmpl` dump prints these sub-cases as `@6`/`@8`
because it sums KEYB case bodies sequentially instead of collapsing them —
a known limitation of that dev tool, not evidence of separate storage). Real
byte data settles it outright:

- `swift run novaswift-extract raw "data/EV Nova" oütf 128` → **"Light Blaster"**
  (weapon, `ModType==1`): byte word `@6`=1, `@8`=**128** — 128 is exactly the
  `wëap` id this outfit's own name and the existing `OutfitModType.weapon`
  decoder agree it grants.
- `swift run novaswift-extract raw "data/EV Nova" oütf 135` → **"IR Missile"**
  (ammo, `ModType==3`): byte word `@6`=3, `@8`=**134** — 134 is the `wëap` id
  of outfit #134 "IR Missile Launcher" (itself a `ModType==1` weapon outfit
  whose own `@8` is 134), i.e. launcher and ammo agree on the fed weapon id
  at the identical absolute offset.
- `swift run novaswift-extract raw "data/EV Nova" oütf 130` (weapon, "Light
  Blaster Turret") → `@8`=130, `@12`(Flags)=2 (`0x0002` Turret bit, matching
  the name). `swift run novaswift-extract raw "data/EV Nova" oütf 156` (ammo,
  "Polaron Torpedo") → `@8`=148, matching outfit #155 "Polaron Torpedo Tube"'s
  own weapon id 148.

Three independent weapon/ammo pairs (128/135, 130/—, 156/155) all place the
`wëap` RSID at absolute byte offset **8**, whether the outfit is `ModType 1`
or `ModType 3` — there is no separate "Ammo@16"-style reservation anywhere in
real data (that offset, `@16`, is actually the low 16 bits of `Cost`, see §8).
This is a genuine on-disk union, not merely an editor-UI convenience, and it
matches what `Sources/NovaSwiftKit/NovaAIModels.swift`'s existing `OutfRes`
decoder already does (`modifiers` loop reads type `@6`/value `@8` for the
first slot) — that decoder was already correct here, just previously
unverified against the TMPL/raw method. **The doc's original draft claim of
"Weapon@10/Ammo@16" (unverified) is wrong and is superseded by this finding.**

So a launcher and its missiles are two separate `oütf` entries, both pointing
at the *same* `wëap` id — the weapon defines the projectile/damage/reload
behavior, and the ammo outfit just tops up that weapon's magazine when bought.
`ModType 27` ("increase maximum") is the general mechanism for "buy item A to
raise item B's cap" and is explicitly used for extra ammo capacity too: "Item
B's standard maximum will be multiplied by the number of items the player has
that have a ModType of 27 and point to B."

Implemented: `OutfRes.grantedWeapons` (`ModType == .weapon`) and `.ammoFor`
(`ModType == .ammunition`) in `NovaAIModels.swift`; folded into a `Loadout`'s
resolved weapon list by `Galaxy.loadout` (`ShipLoadout.swift:140-141,
147-158`): weapon-outfit counts become mount counts, ammo-outfit counts become
extra ammo units on the matching weapon id. **`ModType 27` ("increase
maximum") fixed in the outfitter wiring audit**: `NovaGame.effectiveMaxInstallable`
(`OutfitConstraints.swift`) computes base `Max` × the number of owned
ModType-27 items pointing at the target (the Bible's exact multiplier rule),
and `PilotStore.canBuyOutfit` enforces that effective cap. It is *not* a
ship-stat modifier, so `ShipLoadout.swift`'s stat-aggregation switch correctly
leaves it in `default: break` — its only job is raising a purchase cap, which
lives in the shop layer.

## 6. Purchase constraints

Field | Meaning | Implemented?
---|---|---
`Max` | "How many you can have (not counting weapon limitations)" — a hard per-player cap, 0 = unlimited | Yes — `OutfRes.maxInstallable` (`@10`), enforced in `PilotStore.canBuyOutfit` (`app/NovaSwift/Game/PilotStore.swift:206-211`): `owned(outfit:) >= maxInstallable` blocks Buy.
`Flags 0x0001`/`0x0002` (fixed gun / turret) | Ties the purchase to consuming a hull's `MaxGuns`/`MaxTurrets` slot | **Decoded and tracked, not enforced at purchase.** `OutfRes.isFixedGunOutfit`/`.isTurretOutfit` (`Sources/NovaSwiftEngine/ShipLoadout.swift`) are now decoded, and `Galaxy.loadout` computes `Loadout.usedGunSlots`/`usedTurretSlots`/`freeGunSlots`/`freeTurretSlots` from them. But `PilotStore.canBuyOutfit` (`PilotStore.swift:206-211`) still only checks credits, free mass, and `maxInstallable` — it never reads `freeGunSlots`/`freeTurretSlots`. A player can still buy more gun-type outfits than the hull has gun mounts for; the loadout math will silently fold them all in as if every one fit.
`Flags 0x0004` | "This item stays with you when you trade ships (persistent)" | Not decoded/enforced — `buyShip` in `PilotStore.swift` has a comment "Outfits carry over (EV Nova keeps persistent items)" but that's applied unconditionally to *all* outfits, not gated on this flag.
`Flags 0x0020` | Persistent specifically across a mission's forced ship-swap (`set` operator), independent of 0x0004 | Not decoded.
`Flags 0x0008` | "This item can't be sold" | **Implemented and enforced** — `PilotStore.sellOutfit` (`PilotStore.swift:234-242`) now guards `o.flags & 0x0008 == 0` and rejects the sale (returns `false`) when the flag is set.
`Flags 0x0010` | "Remove any items of this type after purchase (useful for permits and other intangible purchases)" | **Implemented and enforced** — `PilotStore.buyOutfit` (`PilotStore.swift:213-230`) grants the outfit, then immediately calls `state.removeOutfit(o.id)` when `o.flags & 0x0010 != 0` — a permit-type outfit now nets a charge with nothing left in inventory, matching the Bible's described behavior.
`ItemClass` | "The item's classification, used in the pêrs resource for items that are given out by non-player characters' ships." | **Decoded, not consumed.** `OutfRes.itemClass` (`@1004`, `NovaAIModels.swift`) is now a real field, but no `pêrs`-loot logic reads it anywhere in the codebase yet. Real data: outfits #128/#135/#130/#156 all read 0 here (unclassified), consistent with these being ordinary shop items rather than pêrs loot.
`ScanMask` (outfit-level) | Marks an outfit as contraband to governments whose own `ScanMask` shares a bit — distinct from the mission `ScanMask` field already decoded in `MissionModels.swift`. | **Decoded, not consumed.** `OutfRes.scanMask` (`@1006`, `NovaAIModels.swift`) is now a real field, but nothing evaluates it against a government's `ScanMask` at scan/boarding time. (`MissionModels.swift` decodes a *different*, mission-level `scanMask` used for boarding/cargo-scan checks — not this one.) Real data: 0 for the four spot-checked outfits (none of them are contraband-flagged).

Mutual exclusivity: the Bible doesn't describe a direct "owning A forbids
buying B" field for outfits; the closest mechanisms are `Require`/`Contribute`
(buying B could be gated behind *not* wanting to have contradictory tags — but
that's cooperative tagging, not an explicit exclusion primitive) and the
0x1000 DispWeight-suppression flag in §3.6 (suppresses a competing *listing*,
not ownership). There is no "if you own outfit X, outfit Y can never be
bought" field in `oütf`.

## 7. Stocking/restocking — `BuyRandom`

> "BuyRandom: The percent chance that an item of this type will be available
> for purchase on a given day, from 1-100. Values less than 1 or greater than
> 100 are interpreted as 100."

That's the entirety of what the Bible says about outfit restocking: a **daily**
percent-chance roll, per item, defaulting to "always" when unset/out-of-range
(since anything `< 1` reads as `100`). It says nothing about re-rolling more
than once per day, nothing about a running inventory count that depletes as
the player buys, and nothing about accumulating/decaying stock over multiple
days — restocking in EV Nova is exactly this one binary per-day roll, not a
quantity-tracking economy simulation.

The ship resource (`shïp`, Bible lines ~2685-2686, *not* in the `oütf` section)
has its **own**, textually near-identical `BuyRandom` field with one crucial
difference in its zero-behavior:

> "BuyRandom: The percent chance that a ship of this type will be available
> for purchase on a given day. A BuyRandom of 0 means this ship will never be
> made available for purchase."

So: outfit `BuyRandom <= 0` → always available (100%); ship `BuyRandom == 0` →
**never** available. Confirmed by direct byte search of the Bible text — this
is a real, documented asymmetry between the two resources, not an
inconsistency introduced by this project.

### What was actually built (commit `ff8fc20`, "Enhance item availability
mechanics with BuyRandom feature")

- `OutfRes.buyRandom` (`@1008`) and `ShipRes.buyRandom` (`@904`) decoded
  verbatim from the Bible fields above.
- `NovaGame.outfitsSold(at:day:)` / `shipsSold(at:day:)`
  (`Sources/NovaSwiftKit/NovaEconomy.swift`) take an optional `day` (an absolute
  day count, e.g. `GameDate.julianDay`) and, when supplied, filter through a
  private `onOfferToday(buyRandom:neverIfZero:spobID:itemID:day:)` helper.
  `neverIfZero` is `false` for outfits, `true` for ships — implementing the
  documented zero-behavior asymmetry above correctly.
- `onOfferToday` is **not a stored/rolled state** — it's a deterministic
  FNV-1a hash of `(day, spöbID, itemID)` reduced mod 100 and compared against
  the item's percent chance. This means: (a) it needs no save-file support —
  nothing is persisted; (b) re-opening the same outfitter twice on the same
  in-game day shows identical stock (stable within a day, as the Bible's "on a
  given day" phrasing implies); (c) advancing the day naturally changes the
  hash and re-rolls every item independently.
- Wired into the UI: `OutfitterView.stock` / `ShipyardView.stock`
  (`app/NovaSwift/Spaceport/SpaceportScreens.swift`) now pass
  `pilot.state.date.julianDay` through, so the visible grid genuinely changes
  day to day.

**Verdict: this is a faithful, not-invented implementation of a real Bible
field**, for both resources, including the documented zero-behavior asymmetry
between them. The one design choice that *is* a team judgment call rather than
something the Bible specifies: the Bible says nothing about *how* the "percent
chance... on a given day" is actually rolled (real Nova likely used a
per-item/per-day RNG state tied to the save, since the original game has no
equivalent of a pure/stateless hash function as a design concept) — the
FNV-1a-hash-of-(day, spöb, item) approach is an implementation detail invented
to get a stable, save-file-free version of the same *observable* behavior the
Bible describes ("a chance per day, stable if you re-check same-day"). It is
not a deviation from Bible *semantics*, but the specific determinism mechanism
is the team's own design, not a documented one (the original engine's actual
RNG/seeding for this roll is unknown — the Bible only specifies the
probability contract, not the implementation).

One remaining open question the Bible text doesn't resolve either way: whether
"on a given day" resets on any day *anywhere in the galaxy* advancing (a
single global roll-day) or is scoped per-system/per-visit — the shipped
`day` parameter is a raw absolute day count applied uniformly everywhere,
which matches the simplest reading but isn't separately confirmed by any
Bible passage beyond the field's one-sentence description.

## 8. Confirmed on-disk field layout (union question resolved)

Method: `third_party/ResForge/Plugins/Sources/NovaTools/Templates.rsrc` TMPL
id 513 is `oütf`'s community-authoritative byte-layout template (dumped with
`swift run novaswift-extract tmpl "third_party/ResForge/Plugins/Sources/NovaTools/Templates.rsrc" 513`).
That dump computes a naive total of 1016 bytes and carries a "contains
KEYB/unhandled construct — treat as lower bound" warning, because the dev
tool sums two unhandled constructs as if they were sequential instead of
zero/shared-width: (a) the Weapon/Ammo `ModVal` union at the primary modifier
slot (§5), and (b) a 3-entry `FCNT`-repeated "Secondary Function" list (each
entry itself a `KWRD` selector + a same-shaped union value, for the outfit's
2nd–4th modifier slots) that the tool sizes as **zero bytes** instead of its
real 12 bytes (3 × 4-byte slots). Real resource size settles the missing
width directly: `swift run novaswift-extract raw "data/EV Nova" oütf 128` and
`... oütf 135` both report **1028 bytes**, i.e. exactly `1016 + 12` — proving
the secondary-function list is the only remaining unsized gap, and letting
every field from `Contribute` onward be corrected by a flat `+12`.

Cross-checked against four real outfits — two weapon-type, two ammo-type, one
pair sharing a launcher/ammo `wëap` id (see §5) and one turret-flagged weapon
(`Flags@12 == 0x0002`, matching its "Turret" name) and one ammo outfit with a
real, non-trivial `Availability` NCB string (`swift run novaswift-extract raw
"data/EV Nova" oütf 156` → `"(b298 & P30) & !b326..."` at `@46`, and
`Flags@12 == 0x4000`, "hide unless Availability true" — a self-consistent
pairing, since a real conditional Availability is exactly when an author
would opt into hiding on failure):

```
displayWeight@0(DWRD,2B) mass@2(DWRD,2B) techLevel@4(DWRD,2B)
modType@6(KWRD,2B: -1=None/1=Weapon/3=Ammunition)
modVal@8(RSID,2B — UNION: wëap id granted if modType==1, wëap id fed if modType==3;
  CONFIRMED shared/single offset, not two reservations — see §5 for the 3-pair evidence)
maximum@10(DWRD,2B) flags@12(WORV,2B) cost@14(DLNG,4B)
secondaryFunctions[3]@18(each: KWRD selector 2B ["None"=-1 or a ModType from
  oütf.ModTypes/TMPL#550] + union value 2B, 4B/slot, slots at @18/@22/@26 —
  matches Sources/NovaSwiftKit/NovaAIModels.swift's existing OutfRes.modifiers
  loop exactly, which reads pos∈[6,18,22,26]) — spot-checked outfits #128/#130/
  #135/#156 all have all three slots = (-1, 0) i.e. unused
contribute@30(QB64,8B) require@38(QB64,8B)
availability@46(n0FF,255B,NCB Test) — spot-check: oütf#135 = "!b424",
  oütf#156 = "(b298 & P30) & !b326..." (real, plausible NCB expressions)
onPurchase@301(n0FF,255B,NCB Set) onSell@556(n0FF,255B,NCB Set)
outfitterName@811(C040,64B) — spot-check: oütf#128 byte-exact "Light Blaster"
  at @811 (found via the raw command's ASCII view), oütf#135 "IR Missile" @811
lowercaseName@875(C040,64B) — "light blaster"@875 / "IR missile"@875 (note:
  #135's "lowercase" field is actually "IR missile", not fully-lowercased —
  Bible field naming is aspirational, not literally enforced by the data)
lowercasePlural@939(C041,65B)
itemClass@1004(DWRD,2B) scanMask@1006(WB16,2B)
availableRandom@1008(DWRD,2B) — matches NovaAIModels.swift's existing
  OutfRes.buyRandom@1008 exactly; real value 100 for oütf#128 ("always
  available", the Bible's documented ≥100-clamped default)
requireBitsApplyTo@1010(DWRD,2B) — matches existing OutfRes.requireGovt@1010
  exactly; real value 127 for oütf#128 (outside all of the Bible's named
  CASR ranges [-1, 128..383, 1128..1383, 2128..2383, 3128..3383] — likely a
  stale/never-touched authoring default rather than a meaningful scope, not
  a decoding bug: the offset itself is confirmed correct by exact agreement
  with the tool-computed position and the resource's exact total byte count)
unused@1012(F010,16B)
TOTAL: 1028 bytes (confirmed exact match against real oütf #128 "Light
  Blaster" AND #135 "IR Missile" — both report exactly 1028 bytes)
```

**Result: `Sources/NovaSwiftKit/NovaAIModels.swift`'s existing `OutfRes` decoder
(offsets `cost@14`, modifier slots at `6/18/22/26`, `contribute@30`,
`require@38`, `availBits@46`, `buyRandom@1008`, `requireGovt@1010`) is
byte-for-byte correct for everything it decodes.** It was previously only
cited as "verified against novaparse" (a third-party partial TypeScript
port); this session independently re-derives and confirms the same offsets
straight from the community TMPL + real game bytes, with no daylight between
the two derivations. The **new** information from this pass is: (1) proof
the Weapon/Ammo slot is a true union rather than an unverified guess, (2)
the previously-undecoded `itemClass@1004`/`scanMask@1006`/`outfitterName@811`/
`lowercaseName@875`/`lowercasePlural@939`/`onPurchase@301`/`onSell@556`
offsets, none of which existed anywhere in this codebase or doc before.

## 9. What's implemented vs. what's missing

Legend: ✅ Implemented and wired (decoded + actually consulted/enforced at
runtime) · ⚠️ Implemented but not wired (decoded and/or computed, but the
consuming call site doesn't use it) · ❌ Not implemented (not decoded, or
decoded with zero behavior anywhere).

Mechanic | Bible field | Status | Where
---|---|---|---
Tech-level gating | `TechLevel` + `spöb.SpecialTech` | ✅ Done | `NovaEconomy.swift:165-166`
NCB Availability test | `Availability` | ✅ Done | `OutfRes.availBits` + `ItemLocking.swift:54`
Contribute/Require prerequisite | `Contribute`/`Require` | ✅ Done | `ItemLocking.swift:24-30, 52-59`
RequireGovt scoping | `RequireGovt` | ✅ Done | `ItemLocking.swift:37-49`
Show-greyed vs. fully hide | `Flags 0x0100/0x4000` | ✅ Done | `OutfRes.hidesWhenLocked`
Sell-anywhere override | `Flags 0x0800` | ✅ Done — overrides Require/Availability **and** the upstream tech-level filter | `OutfRes.ignoresRequirements` + `NovaEconomy.outfitsSold`
Max-owned cap | `Max` | ✅ Done | `PilotStore.canBuyOutfit`
Base price + flat refund | `Cost` | ✅ Done | `OutfRes.cost`, `PilotStore.buyOutfit`/`sellOutfit`
Mass-proportional price | `Flags 0x0200` | ✅ Done — `PilotStore.effectiveCost` calls `Galaxy.effectiveCost`, used by `buyOutfit`/`sellOutfit`/`canBuyOutfit`/`tradeInValue` | `ShipLoadout.swift:107-110, 126-135` + `PilotStore.swift`
Mass-proportional install mass | `Flags 0x0400` | ✅ Implemented and wired — `OutfRes.massIsShipMassProportional` + `effectiveMass(shipMass:)` consumed in `Galaxy.loadout`'s `usedMass` sum | `ShipLoadout.swift:111-124, 196`
Purchase/sale control-bit side effects | `OnPurchase`/`OnSell` | ✅ Done — decoded on `OutfRes` (`@301`/`@556`) and run via `StoryEngine.apply(set:)` on buy/sell | `NovaAIModels.swift` + `PilotStore.runOutfitScript`
Weapon/ammo linkage | `ModType 1`/`3` | ✅ Done | `OutfRes.grantedWeapons`/`.ammoFor`, folded in `ShipLoadout.swift:140-141`
Map reveal | `ModType 16` | ✅ Done — scoped one-shot reveal at acquisition (N jumps / all-independent / govt class), recorded in `PlayerState.chartedSystems`; **was** a whole-galaxy reveal bug | `NovaGame.mapRevealedSystems` + `PlayerState.applyOutfitAcquisition`
Clean legal record | `ModType 21` | ✅ Done — clears standing with the ModVal govt (or all if -1) on acquisition | `PlayerState.applyOutfitAcquisition` / `clearLegalRecord`
Ammo/other-item cap increase | `ModType 27` | ✅ Done — `NovaGame.effectiveMaxInstallable` (base Max × owned expanders) enforced in `PilotStore.canBuyOutfit`; not a ship-stat modifier, so `ShipLoadout` intentionally skips it | `OutfitConstraints.swift` + `PilotStore.swift`
Fixed-gun/turret slot flags | `Flags 0x0001/0x0002` | ✅ Done — `PilotStore.canBuyOutfit` rejects a fixed-gun/turret buy when `Loadout.freeGunSlots`/`freeTurretSlots` is 0 | `ShipLoadout.swift:68-85, 100-106` + `PilotStore.swift`
Can't-sell flag | `Flags 0x0008` | ✅ Implemented and wired — `sellOutfit` rejects the sale when set | `PilotStore.swift:234-242`
Consumed-on-purchase (permits) | `Flags 0x0010` | ✅ Implemented and wired — `buyOutfit` grants then immediately `removeOutfit`s | `PilotStore.swift:213-230`
Persistent-across-ship-trade | `Flags 0x0004`/`0x0020` | ❌ Missing as a distinct rule — outfits currently always carry over regardless of the flag | `PilotStore.buyShip` comment
DispWeight-tier suppression | `Flags 0x1000` | ❌ Missing | —
Ranks-section outfit | `Flags 0x2000` | ❌ Missing | —
Illegal-outfit `ScanMask` | `ScanMask` (outf-level) | ✅ Done — `gövt.ScanMask@50` decoded + `Contraband`/`ContrabandScan` fine the player for scanned contraband (outfit/junk/mission) | `Contraband.swift`, `ContrabandScan.swift`; see docs/reverse-engineering/GOVERNMENT.md
`ItemClass` (for pêrs loot) | `ItemClass` | ✅ Done — `pêrs` decoded (`PersModels.swift`); `NovaGame.personBoardingGrant` hands over `GrantCount/2…GrantCount` random outfits of `GrantClass` when the player boards a named person's hulk; spawner tags 5% of ships as a `pêrs` | `PersModels.swift`, `World.takePlunderOutfits`, `Spawner.assignPersonIfLucky`
`Outfitter Name`/`Lowercase Name`/`Lowercase Plural` | (unnamed in Bible field list; display strings) | ❌ Missing — offsets confirmed `@811`/`@875`/`@939` (§8); engine currently displays only the resource-fork `name` metadata, never these in-record strings | —
Daily restock roll | `BuyRandom` (both resources) | ✅ Done, including the documented zero-behavior asymmetry | `NovaEconomy.swift` `onOfferToday`, §7 above

### NovaJS cross-reference

The vendored partial TypeScript port (`third_party/NovaJS`) does **not**
implement any of this business logic. `novaparse/src/resource_parsers/OutfResource.ts`
only exposes raw fields (`displayWeight`, `mass`, `techLevel`, `max`, `cost`,
`functions` — the same four ModType/ModVal slots, string-labeled instead of
enum-cased) with no `Availability`/`Require`/`Contribute`/`BuyRandom`/flags
decoding at all. `novadatainterface/OutiftData.ts` (filename misspelled
"Outift" in the actual repo) is purely a runtime data-shape interface
(`weapons`, `physics`, `pict`, `price`, `desc`, `displayWeight`, `max`) with
default-value scaffolding, again no gating/pricing logic. `nova/src/spaceport/outfitter.ts`
is UI-only: it renders whatever list it's handed and reads `item.price`/
`item.max` verbatim — no tech-level filter, no BuyRandom, no Require check
visible anywhere in that file. In short: NovaJS is not a second source of
outfitter *rules*, only confirmation of the same raw field layout already
cross-checked against novaparse elsewhere in this codebase.
