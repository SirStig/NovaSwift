# The Ship System

How a ship becomes what it *actually is* in flight: the hull (`shïp`) plus its
installed outfits (`oütf`) resolved into effective stats, plus the live resource
pools (shields, armor, fuel, cargo) and the weapon loadout. Everything is driven
from the player's own game data — nothing is hard-coded per ship.

Built 2026-07-07. Verified against the real EV Nova data (`novaswift-extract ship`).

## Where it lives

| Layer | File | Responsibility |
|-------|------|----------------|
| Data | `NovaSwiftKit/NovaModels.swift` (`ShipRes`) | Full hull decode: cargo, shield/armor + recharge, speed/accel/turn, **fuel capacity**, free mass, max guns/turrets, cost, crew, tech, preinstalled outfits, stock + extended weapon slots. Offsets verified against novaparse. |
| Data | `NovaSwiftKit/NovaAIModels.swift` (`OutfRes`, `OutfitModType`) | Outfit decode: mass, cost, tech, max, and the up-to-four **modifier functions** (the 50 EV Nova ModTypes: shield, armor, speed, fuel, afterburner, weapon-grant, ammo, maxGuns…). |
| Aggregation | `NovaSwiftEngine/ShipLoadout.swift` (`Loadout`, `Galaxy.loadout`) | Folds a hull + all its outfits into one **effective** ship: summed stats, resolved weapons, fuel/cargo/mass, afterburner. The heart of the system. |
| Runtime | `NovaSwiftEngine/World.swift` (`Ship`) | Live pools: `shield`/`armor` (+recharge, in `Combat.swift`), **`fuel`** (+regen), **cargo hold**, **afterburner** state; jump-fuel and cargo APIs; afterburner physics in `step`. |
| Runtime | `NovaSwiftEngine/Combat.swift` | Weapons: `WeaponSpec`/`WeaponMount` (reload, ammo), projectiles/beams, damage → shields fully first, then armor (no bleed-through; shield-penetrating weapons `wëap` Flags 0x0020 excepted). |
| App | `app/NovaSwift/…` | Player ship built via `Galaxy.makeLoadedShip`; HUD shows shield/armor/fuel(+jumps)/cargo/active-weapon; afterburner bound to its `GameAction`; projectiles rendered. |

## Fuel (important nuance)

EV Nova's ship resource stores one blue-gauge resource at @10/@94. novaparse labels
it "energy", but in EV Nova it is the player-facing **Fuel** gauge: **100 units =
one hyperjump**, and it is also what the **afterburner** burns. We decode it as
`fuelCapacity`/`fuelRegen` and model it as fuel throughout. There is no separate
energy bar. `ShipFuel.perJump = 100`.

## How aggregation works (`Galaxy.loadout`)

1. Merge the hull's **preinstalled** outfits with any the player has installed.
2. Sum every outfit modifier into hull stat-space (`× count`): shields, armor and
   their recharge, speed/accel/turn, fuel capacity + regen, free cargo, max
   guns/turrets. Track consumed **mass**.
3. Resolve weapons: hull stock weapons + outfit-granted weapons (ModType 1),
   merged by id, with ammo from stock + ammunition outfits (ModType 3).
4. Convert to sim units with the *same* scales NPCs use (`Galaxy.shipSpec`), so
   player and NPC ships share one footing. `makeLoadedShip` then instantiates a
   live `Ship` with full tanks and the weapon mounts installed.

`freeMass = ship.freeSpace` available; `massCapacity = freeSpace + Σ installed
outfit mass`. Cargo is a separate pool (`cargoCapacity` tons).

## What works now

- Real per-ship stats from the user's data (e.g. Shuttle: 30/30, 300 fuel = 3
  jumps, 10t cargo, Light Blaster).
- Outfits change the ship: reactors add fuel-regen/speed/accel, cargo expansions
  add tons, shield/armor boosters raise capacity, afterburners appear, weapon
  outfits arm the hull. (e.g. Fed Carrier resolves to its turrets, missile ammo,
  fighter bays, Thorium Reactor, afterburner, and 169t of outfit mass.)
- Live flight: shields & armor regen; **afterburner** drains fuel for a speed/accel
  boost and goes inert when dry; **hyperjumps** cost 100 fuel; **cargo** load/unload
  respects capacity; weapons fire respecting reload & ammo, spawning projectiles.
- HUD reflects all of it (shield/armor/fuel bars, jump count, cargo tonnage,
  active weapon + ammo, thrust vs. burn).
- Outfitter buy/sell, persisted per pilot: `app/NovaSwift/Spaceport/SpaceportScreens.swift`
  calls `pilot.buyOutfit(...)`/`pilot.sellOutfit(...)` (single-unit at lines 495/511,
  bulk "buy N" quantity-prompt variants at lines 357/361). The underlying
  `PilotStore` methods (`app/NovaSwift/Game/PilotStore.swift:356-432`) gate each
  purchase on affordable effective cost (rank-scaled `priceMultiplier`), free mass,
  the outfit's (expander-adjusted) max-installed cap, and free gun/turret mounts for
  fixed-gun/turret items, then mutate `PilotState` and persist via `save()`; selling
  refunds at the same effective price and blocks non-sellable items (`Flags 0x0008`).

## Hyperspace jumps

Pressing `J` (or the map's JUMP button) with a plotted course engages the
hyperdrive. The jump is a scene-owned animation — turn to face the destination
(the outbound galactic-map direction), tear away as the stars streak, white
flash, and pop out at the new system's hyperspace edge coasting inward — with the
world swapped **in place** (no scene rebuild). Fuel (100/hop) is spent and the
pilot follows the course only at the flash peak, so the HUD/map never claim you've
arrived before you actually have. The nav readout shows the plotted destination
and remaining jumps the whole time, as in the original. See `docs/AI.md` for the
matching NPC jump-ins and `GameScene`/`NavigationModel`/`GameContainerView` for
the player path.

Jump behaviour is modified by the real jump `oütf` ModTypes, folded into the
`Loadout`:

| ModType | Field | Effect |
| --- | --- | --- |
| 32 `multiJump` | `maxJumpHops` | one jump command crosses N linked systems at once |
| 37 `fastJump` | `instantJump` | inertialess jump — skips the slow turn/align spin-up, near-instant |
| 22 `hyperspaceSpeed` | `hyperspaceSpeedBonus` → `PilotStore.jumpSpeedFactor` | speeds up the jump sequence (engine interpretation: +1%/point, clamped) |

## Not yet (future)

- Ion/heat, cloak, jammers-vs-guidance, point-defense targeting (decoded as
  ModTypes; not yet simulated).
- Per-weapon `snd ` and muzzle/impact art (uses a stock report today).

## Try it

```
novaswift-extract ship   "data/base/Nova Files" 143   # Fed Carrier: full loadout
novaswift-extract outfit "data/base/Nova Files"        # every outfit + its modifiers
novaswift-extract outfit "data/base/Nova Files" 197    # Afterburner
```
