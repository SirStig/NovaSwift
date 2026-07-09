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
`Mass` | Tons of free mass the item consumes (0 = no appreciable mass). Consumed from the hull's free-mass pool exactly like cargo does — outfits and cargo share one mass budget.
`Flags 0x0001` | "This item is a fixed gun" — installs into a **gun** mount.
`Flags 0x0002` | "This item is a turret" — installs into a **turret** mount.
`Flags 0x0400` | "This item's total mass (at purchase) is proportional to the player's ship's mass" — `shipClass.Mass × outfit.Mass / 100`. Positive-mass items only.

There is no separate "outfit slot" system beyond mass and the fixed-gun/turret
flags: a hull just declares `MaxGuns`/`MaxTurrets` counts (`shïp` @42/@44), and
any `oütf` flagged 0x0001/0x0002 competes for those slots. Everything else
(shield boosters, cargo pods, cloaks, etc.) only consumes mass, no dedicated
slot. `ModType 45`/`46` ("modify max guns"/"modify max turrets") let an outfit
itself add or remove gun/turret capacity (e.g. a gun-mount-adding pod).

Cross-reference: `Sources/EVNovaEngine/ShipLoadout.swift` sums `.maxGuns`/
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
`NovaEconomy.sells(techLevel:at:)` (`Sources/EVNovaKit/NovaEconomy.swift:165-166`):
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

Implemented: `Sources/EVNovaKit/NovaAIModels.swift` decodes `contribute` (`@30`),
`require` (`@38`), `requireGovt` (`@1010`) on `OutfRes`. Logic in
`app/EVNova/Spaceport/ItemLocking.swift`:
- `contributedBits(pilot:)` (lines 24-30) ORs the current ship's `contribute`
  with every owned outfit's `contribute`.
- `requireGovtApplies` (lines 37-49) implements the four range cases above.
- `lockState(for:pilot:at:diplomacy:)` (lines 52-59) combines Availability +
  Require-if-in-scope into the final available/locked/hidden state.

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
`OutfitterView.stock` (`app/EVNova/Spaceport/SpaceportScreens.swift:163`).

### 3.5 The "ignore everything" escape hatch

> "0x0800 This item can be sold anywhere, regardless of tech level,
> requirements, or mission bits."

Implemented as `OutfRes.ignoresRequirements`, checked first in
`lockState(for:pilot:at:spob:diplomacy:)` — but note it's only wired into the
`Require`/`Availability` check, not into the **tech-level** filter upstream in
`NovaGame.outfitsSold` (`NovaEconomy.swift:186-193`), which unconditionally
calls `sells(techLevel:at:)` before this flag is ever consulted. **This is a
gap**: per the Bible's literal wording ("regardless of tech level..."), an
0x0800 item should show up even at a spaceport whose tech level is too low for
it, and today it won't.

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
`Cost` | Base credits charged (Int32, `@14`). Refund on sell is the **same** value — the Bible has no separate sell-price field for outfits (unlike commodities, which have buy/sell spreads via `PriceLevel`).
`Flags 0x0200` | "This item's total price is proportional to the player's ship's mass. (ship class Mass field is multiplied by this item's Cost field)" — i.e. actual charge = `shipClass.Mass × outfit.Cost`, not the flat `Cost` shown.

`OutfRes.cost` is decoded (`NovaAIModels.swift`) and used directly as the
displayed/charged price in `OutfitterView.info` and `PilotStore.buyOutfit`/
`sellOutfit` (`app/EVNova/Game/PilotStore.swift:206-230`) — full refund on
sell, matching the Bible's flat-refund model. **Gap**: `Flags 0x0200`
(mass-proportional pricing) is not decoded on `OutfRes` at all and not applied
anywhere; every mass-scaled-price outfit in real data would be mis-priced by
this engine today (charged/refunded at the flat `Cost` instead of
`shipMass × Cost`).

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
extra ammo units on the matching weapon id. **Gap**: `ModType 27`
("increase maximum", used for ammo-cap-raising permits/pods) is decoded as an
enum case (`.increaseMax`) but never consumed in `ShipLoadout.swift`'s
aggregation switch (falls into `default: break`) — an outfit that's supposed
to raise another outfit's `Max` currently does nothing.

## 6. Purchase constraints

Field | Meaning | Implemented?
---|---|---
`Max` | "How many you can have (not counting weapon limitations)" — a hard per-player cap, 0 = unlimited | Yes — `OutfRes.maxInstallable` (`@10`), enforced in `PilotStore.canBuyOutfit` (`app/EVNova/Game/PilotStore.swift:206-211`): `owned(outfit:) >= maxInstallable` blocks Buy.
`Flags 0x0001`/`0x0002` (fixed gun / turret) | Ties the purchase to consuming a hull's `MaxGuns`/`MaxTurrets` slot | **No.** Not decoded on `OutfRes` at all, and `ShipRes.maxGuns`/`maxTurrets` are never read at purchase time (only inside `Galaxy.loadout`'s post-hoc stat aggregation). A player can currently buy more gun-type outfits than the hull has gun mounts for; the loadout math will silently fold them all in as if every one fit.
`Flags 0x0004` | "This item stays with you when you trade ships (persistent)" | Not decoded/enforced — `buyShip` in `PilotStore.swift` has a comment "Outfits carry over (EV Nova keeps persistent items)" but that's applied unconditionally to *all* outfits, not gated on this flag.
`Flags 0x0020` | Persistent specifically across a mission's forced ship-swap (`set` operator), independent of 0x0004 | Not decoded.
`Flags 0x0008` | "This item can't be sold" | **Not decoded or enforced** — `PilotStore.sellOutfit` (`PilotStore.swift:224-230`) allows selling back any owned outfit unconditionally.
`Flags 0x0010` | "Remove any items of this type after purchase (useful for permits and other intangible purchases)" | Not decoded/enforced — a permit-type outfit would currently sit in inventory as a normal ownable item instead of vanishing on purchase.
`ItemClass` | "The item's classification, used in the pêrs resource for items that are given out by non-player characters' ships." | Not decoded on `OutfRes` at all (no field).
`ScanMask` (outfit-level) | Marks an outfit as contraband to governments whose own `ScanMask` shares a bit — distinct from the mission `ScanMask` field already decoded in `MissionModels.swift`. | Not decoded on `OutfRes`. (`MissionModels.swift` decodes a *different*, mission-level `scanMask` used for boarding/cargo-scan checks — not this one.)

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
  (`Sources/EVNovaKit/NovaEconomy.swift`) take an optional `day` (an absolute
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
  (`app/EVNova/Spaceport/SpaceportScreens.swift`) now pass
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

## 8. What's implemented vs. what's missing

Mechanic | Bible field | Status | Where
---|---|---|---
Tech-level gating | `TechLevel` + `spöb.SpecialTech` | Done | `NovaEconomy.swift:165-166`
NCB Availability test | `Availability` | Done | `OutfRes.availBits` + `ItemLocking.swift:54`
Contribute/Require prerequisite | `Contribute`/`Require` | Done | `ItemLocking.swift:24-30, 52-59`
RequireGovt scoping | `RequireGovt` | Done | `ItemLocking.swift:37-49`
Show-greyed vs. fully hide | `Flags 0x0100/0x4000` | Done | `OutfRes.hidesWhenLocked`
Sell-anywhere override | `Flags 0x0800` | Partial — only overrides Require/Availability, **not** the upstream tech-level filter | `OutfRes.ignoresRequirements`; gap noted in §3.5
Max-owned cap | `Max` | Done | `PilotStore.canBuyOutfit`
Base price + flat refund | `Cost` | Done | `OutfRes.cost`, `PilotStore.buyOutfit`/`sellOutfit`
Mass-proportional price | `Flags 0x0200` | **Missing** — not decoded, not applied | —
Mass-proportional install mass | `Flags 0x0400` | **Missing** — not decoded, not applied | —
Weapon/ammo linkage | `ModType 1`/`3` | Done | `OutfRes.grantedWeapons`/`.ammoFor`, folded in `ShipLoadout.swift:140-141`
Ammo/other-item cap increase | `ModType 27` | Decoded but **inert** — falls to `default: break` | `ShipLoadout.swift`'s aggregation switch
Fixed-gun/turret slot flags | `Flags 0x0001/0x0002` | **Missing** entirely — no gun/turret purchase-time slot limit enforced | —
Can't-sell flag | `Flags 0x0008` | **Missing** — every owned outfit is sellable | `PilotStore.sellOutfit`
Consumed-on-purchase (permits) | `Flags 0x0010` | **Missing** | —
Persistent-across-ship-trade | `Flags 0x0004`/`0x0020` | **Missing** as a distinct rule — outfits currently always carry over regardless of the flag | `PilotStore.buyShip` comment
DispWeight-tier suppression | `Flags 0x1000` | **Missing** | —
Ranks-section outfit | `Flags 0x2000` | **Missing** | —
Illegal-outfit `ScanMask` | `ScanMask` (outf-level) | **Missing** — not decoded (distinct from the mission-level `scanMask` that *is* decoded) | —
`ItemClass` (for pêrs loot) | `ItemClass` | **Missing** | —
Daily restock roll | `BuyRandom` (both resources) | Done, including the documented zero-behavior asymmetry | `NovaEconomy.swift` `onOfferToday`, §7 above

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
