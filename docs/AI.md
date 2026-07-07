# NPC AI system

This documents the AI that populates a system with living ships — traders coming
and going, patrols on station, pirates hunting, defense fleets scrambling — the
way EV Nova does. It is a faithful reconstruction driven **entirely by the
player's own game data** (`gövt`, `düde`, `flët`, `shïp`, `wëap`, `sÿst`).

The whole thing lives in `EVNovaEngine` and is exercised headlessly by
`evnova-extract ai <baseDir> [systemID] [seconds]`.

## The core idea: NPCs are ships with a brain

Every ship — player or NPC — is a `Ship`. The simulation only ever reads a
`ControlIntent` (turn / thrust / fire / desiredHeading). The player's fingers
produce one; an NPC's `AIBrain` produces the *same struct*. That symmetry means
one flight model, one combat model, one collision model drives everything — an
NPC obeys exactly the physics the player does.

```
perceive world ─▶ AIBrain.think() ─▶ ControlIntent ─▶ Ship.step() ─▶ physics
                        ▲                                   │
                        └──────────── world state ◀─────────┘
```

## Data it reads (all verified against the real game)

Decoders in `EVNovaKit` (`NovaAIModels.swift`, `NovaModels.swift`), with byte
offsets taken from the EV Nova / ResForge `TMPL` templates and cross-checked
against real resources:

| Resource | What we use it for | Key fields (offsets) |
|---|---|---|
| `gövt` | Diplomatic relations & behavior flags | Flags1 @2, penalties @6–18, **Classes[4] @24, Allies[4] @32, Enemies[4] @40** |
| `düde` | An AI archetype: disposition + ship table | AIType @0, Govt @2, Flags @4, **Ships[16] @8, Probs[16] @40** |
| `flët` | A flagship + weighted escorts | LeadShip @0, Escorts @2, Mins @10, Maxes @18, Govt @26, LinkSystem @28 |
| `shïp` | Hull stats, loadout, faction | speed/accel/turn, shield/armor, **inherentAI @66, strength @70, inherentGovt @72, weapons @18/26/34** |
| `wëap` | Damage, range, guidance | reload @0, duration @2, armorDmg @4, shieldDmg @6, guidance @8, speed @10 |
| `sÿst` | Who spawns here, how densely | **Dudes[8] @68, Probs[8] @84, AvgShips @100, Govt @102** |

(These offsets were confirmed empirically — e.g. the Federation government's
Comms Name decodes at @52, and both `düde` 128's and Sol's spawn probabilities
sum to exactly 100.)

## Diplomacy — who fights whom

`Diplomacy` (built from every `gövt`) mirrors EV Nova's class-based relations:

- A government belongs to a set of **classes** and lists **ally** and **enemy**
  classes.
- Two governments are enemies when one's `enemies` intersect the other's
  `classes` — evaluated symmetrically (either side's hostility starts a fight).
- **Xenophobes** attack everyone who isn't an ally.
- The **player** is tracked separately by a per-government legal record; a
  government turns hostile via its flags (`always/never attacks player`, `nosy`
  toward criminals) or once the player's record there goes negative. Firing on a
  government's ship dents the player's standing (and its allies' a little).

Independent ships (`gövt` −1) are hostile to no one unless provoked.

## Dispositions — the `düde` AI types

| AIType | Behavior |
|---|---|
| Wimpy Trader | Bolts for the hyperspace edge at the first sign of a threat |
| Brave Trader | Trades blows if armed and healthy; runs when hull drops below 40% |
| Warship | Patrols; hunts and engages hostiles; retreats if its government flag says so and shields fall below 25% |
| Interceptor | Aggressive warship — closes distance and presses the attack |

Fleet escorts adopt their flagship's target and fight for it; if the flagship
dies they fall back to their own disposition.

## Behavior state machine

`AIBrain` runs a small state machine each frame (`AIState`):

```
spawning ─▶ traveling ⇄ departing        (traders: fly to a planet, then jump out)
         ─▶ patrolling                     (warships: roam waypoints, scan)
              │
              ▼ hostile in scan range
           attacking ──▶ fleeing ──▶ departing   (hurt / outmatched → run → jump)
           escorting  (fleet members stay on their leader, adopt its target)
```

Steering primitives turn a goal into a `ControlIntent`:

- **seek / arrive** — face a point and thrust, braking inside a slow radius.
- **attack** — lead the target by `distance / projectileSpeed`, hold at a
  standoff range (interceptors crowd closer), and fire only when the target is
  within weapon range and inside a tight firing arc.
- **flee / depart** — steer away from the threat toward the system edge and
  request a hyperspace jump; the world despawns the ship once it's past the edge.

## Combat — what makes "attack" real

`Combat.swift` + the `World` loop:

- Ships have **shield / armor** with regen; damage hits shields first and bleeds
  the leftover proportion into armor.
- Weapons become `WeaponSpec`s (damage, reload, projectile speed, range, beam vs.
  guided vs. fixed). A mount tracks cooldown and ammo.
- Firing spawns a **`Projectile`** (guided rounds steer toward the target) or, for
  beams, does an **instant hitscan** along the aim ray. No self-hits, no friendly
  fire within a government.
- Armor ≤ 0 destroys the ship: the world emits an explosion + `shipDestroyed`
  event and clears anyone targeting it.

## Population — the `Spawner`

`Spawner` reads a system's `SpawnTable` (its `düde`/`flët` list + average ship
count) and keeps the system inhabited:

- On entry it fills to the target population; thereafter it tops up over time as
  ships jump out or die.
- Dudes are picked by probability, then a ship class is picked from the dude's
  weighted table; a brain is attached matching the dude's disposition.
- Fleets spawn a flagship plus its escorts, formed up and escorting.
- Arrivals appear at the hyperspace edge and fly inward; departures leave past
  the edge (`shipArrived` / `shipDeparted` events for audio/visuals).

## Wiring it up

`GameSession.makeWorld(game:systemID:player:)` assembles a fully-wired, populated
`World` in one call — player ship, diplomacy, system geometry, spawner — and hands
back the `Galaxy` catalog for sprite lookups. The renderer drains `World.events`
each frame for shots, beams, explosions and arrivals/departures, and reads
`world.npcs` / `world.projectiles` for what to draw.

## Determinism & testing

The simulation uses a seeded `SplitMix64` PRNG, so a given seed replays
identically. Coverage:

- `DiplomacyTests` — class relations, xenophobes, player standing.
- `CombatTests` — shield/armor bleed-through, projectile travel & kills, no
  friendly fire, instant beams.
- `AIBehaviorTests` — warship engages a hostile, wimpy trader flees, trader
  travels to a planet, departing ships jump out, and a full deterministic duel
  between two hostile interceptors resolves.
- Integration: `evnova-extract ai "…/Nova Files"` runs the whole thing on the
  real game — e.g. Sol's traders come and go peacefully, while Kania and Auroran
  space break into real dogfights.
