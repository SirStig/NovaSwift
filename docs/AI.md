# NPC AI system

This documents the AI that populates a system with living ships — traders coming
and going, patrols on station, pirates hunting, defense fleets scrambling — the
way EV Nova does. It is a faithful reconstruction driven **entirely by the
player's own game data** (`gövt`, `düde`, `flët`, `shïp`, `wëap`, `sÿst`).

The whole thing lives in `NovaSwiftEngine` and is exercised headlessly by
`novaswift-extract ai <baseDir> [systemID] [seconds]`.

## ⚠️ Fidelity status — this is the port's biggest gap

**EV Nova's AI and spawning logic were never open-sourced.** There is no
original source to port — everything here is *reconstructed* from the game's
data tables (`gövt`/`düde`/`flët`/`sÿst`) and observed behavior, cross-checked
against the Nova Bible (see [`AI_GROUND_TRUTH.md`](AI_GROUND_TRUTH.md)). That
reconstruction covers the documented behavior well, but it is honestly the area
where the port still *feels* least like the original. The known weak points:

- **Spawn cadence / density.** The ambient population is a trickle heuristic —
  a spawn every `spawnInterval` toward the system's `sÿst.AvgShips` — built "in
  the same spirit as" the original, not its exact algorithm. Traffic can read
  as slightly too sparse or too evenly paced; it doesn't yet reproduce the
  original's precise arrival rhythm and ship mix.
- **Flight handling.** The steering is hand-tuned heuristics ("thrust when
  roughly pointed the right way," turn-limit lifts through hard turns, escort
  heading-hold hacks). To match the original's *precise* AI flight — and to kill
  the momentum overshoot, wrong-direction turn drift, and constant escort
  micro-correction — AI-controlled ships now fly the engine's **driftless
  (inertialess) model** by default (`FlightTuning.aiInertialess`, see below),
  the way EV Nova's own AI flew tighter than the player on the same hull. That
  removes the biggest wobble source; the residual heuristics are what's left.
- **Behavior edge cases.** One mission `ShipBehav` case falls through to normal
  AI; ships with no brain drift; some engagement/disengagement transitions
  approximate timing the Bible never documented.

**Most core gameplay is replicated well** — this AI is the standout exception,
and tightening it (spawn cadence toward the real feel, smoother steering) is
the top fidelity backlog item. Everything below is the current design and where
it already matches the original; read it alongside the caveats above.

## The core idea: NPCs are ships with a brain

Every ship — player or NPC — is a `Ship`. The simulation only ever reads a
`ControlIntent` (turn / thrust / fire / desiredHeading). The player's fingers
produce one; an NPC's `AIBrain` produces the *same struct*. That symmetry means
one flight model, one combat model, one collision model drives everything.

**One deliberate asymmetry — inertialess AI flight.** EV Nova's NPC AI doesn't
wrestle the same Newtonian momentum the player does: its ships turn and their
velocity tracks the nose far more tightly than a human flying the identical
hull, which is exactly why AI traffic reads as *precise* rather than drifty.
We reproduce that by flying AI-controlled ships on the engine's driftless
(inertialess) flight model — the same `Ship.step` path a hull with the real
`shïp` Flags2 0x0040 flag uses — regardless of whether their hull carries the
flag. The player still flies authentic Newtonian flight (with inertia) unless
*their own* hull/outfits set the flag. This is controlled by
`FlightTuning.aiInertialess` (`AIInertialessScope`): `.all` (the default —
every NPC), `.formations` (only fleet members and escorts, to steady a wing's
station-keeping), or `.off` (strict "identical physics for player and AI,"
only the real hull flag counts). `Ship.fliesInertialess(_:)` is the single
predicate both `Ship.step` and the `AIBrain` steering primitives read. Driving
NPCs driftless is what removes the momentum overshoot, wrong-direction drift on
turns, and the constant escort micro-correction a from-source flight AI wouldn't
have.

```
perceive world ─▶ AIBrain.think() ─▶ ControlIntent ─▶ Ship.step() ─▶ physics
                        ▲                                   │
                        └──────────── world state ◀─────────┘
```

## Data it reads (all verified against the real game)

Decoders in `NovaSwiftKit` (`NovaAIModels.swift`, `NovaModels.swift`), with byte
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
| Brave Trader | Trades blows if armed and in range; runs once its attacker is out of its own weapon range |
| Warship | Patrols; hunts and engages hostiles it can actually win against; retreats if its government flag says so and shields fall below 25% |
| Interceptor | Hunts enemies same as a warship; when idle, holds a slow orbit near a stellar object instead of patrolling, occasionally buzzing passing traffic; also acts as **piracy police** — attacks whoever it sees targeting a non-enemy third party, even if that aggressor isn't normally its own enemy |

Fleet escorts adopt their flagship's target and fight for it; if the flagship
dies they fall back to their own disposition.

A warship/interceptor won't *initiate* a fight against odds its government
wouldn't accept: `Diplomacy`'s `gövt.MaxOdds` is checked against the summed
`shïp.Strength` of nearby hostiles vs. friends (each shield-scaled 30–100%) —
see `AIBrain.favorableOdds`. Once already engaged, it fights it out.

Any disposition with `shïp.Flags2` bit 0x0080 set (`Ship.fleeWhenOutOfAmmo`)
flees or docks once every *ammo-using* weapon mount is dry (`AIBrain.outOfAmmo`)
— ships that only carry unlimited-ammo guns/beams never trigger this.

See `docs/AI_GROUND_TRUTH.md` for the full Bible-sourced field-by-field
reference and what's still explicitly deferred (cloak-triggered AI, bribery,
mission `ShipBehav` overrides, `gövt.SkillMult`) and why.

## Behavior state machine

`AIBrain` runs a small state machine each frame (`AIState`):

```
spawning ─▶ traveling ⇄ departing        (traders: fly to a planet, then jump out)
         ─▶ patrolling ─▶ departing        (LOCAL-AUTHORITY warships: circuit the planets, then jump out after a tour of duty)
         ─▶ orbiting  ⇄ scanning ─▶ departing  (LOCAL-AUTHORITY interceptors: hold near a planet, buzz-scan traffic, then jump out)
         ─▶ traveling                       (FOREIGN combat ships: just cross the system and leave)
              │
              ▼ hostile in scan range (or, for authority interceptors, a piracy-police target)
           attacking ──▶ fleeing ──▶ departing   (hurt / outmatched / out of ammo → run → jump)
           escorting  (fleet members hold a tight triangle on their leader; break off only to attack)
```

**Ships come and go.** A local-authority warship/interceptor doesn't police one
system forever — with no fight to be had, after a randomized *tour of duty* it
heads for the hyperspace edge and leaves (Bible: a warship "jumps out if there
aren't any" enemies). Traders arrive, visit a planet, and leave; fleets arrive on
their own cadence; the spawner tops the population back up toward the system's
`sÿst.AvgShips`. That turnover — not a fixed set of hulls looping in place — is
what makes traffic feel alive. **Only interceptors scan the player**, and only
about once per system visit (a per-visit latch, `World.playerScanned`), matching
the original's "you get buzzed by roughly one ship each time you enter."

**Who patrols matters.** Only the *local authority* — ships of the government
that controls the system (`sÿst.Govt`), or an ally of it — runs the patrol beat,
holds orbit, and scans traffic. A warship or interceptor of any *other*
government has no business policing someone else's space, so with no fight to
join it just travels across the system and leaves, like a trader. In an unowned
(independent) system anyone armed may patrol. This is what makes a Federation
system feel like Federation space instead of a free-for-all of every faction's
warships wandering in circles.

Steering primitives turn a goal into a `ControlIntent`:

- **seek / arrive** — face a point and thrust; `arrive` coasts to a stop inside a
  slow radius and only reverse-thrusts to scrub speed when coming in hot, so idle
  ships *settle* on a waypoint instead of wheeling around it in little loops.
- **attack** — lead the target by `distance / projectileSpeed`, hold at a
  standoff range (interceptors crowd closer), and fire only when the target is
  within weapon range and inside a tight firing arc.
- **flee / depart** — steer away from the threat toward the system edge and
  request a hyperspace jump; the world despawns the ship once it's past the edge.
- **patrol** — *cruise* an in-order circuit of the system's stellar objects (aiming
  at each body's outer face in turn), flying the beat at speed and moving straight
  on to the next waypoint rather than coasting to a stop and hovering — the
  stop-and-hover is what used to read as "circling one point forever."
- **orbit** — a slow, smooth circular holding pattern around the nearest stellar
  object (the Bible's "parks in orbit around a planet").
- **scan** — the interceptor's "check you out" pass (only interceptors scan, per
  the Bible; and the player at most once per visit): break off the orbit, fly over a
  passing ship (the player first), emit a one-shot `shipScanned` event at scan
  range (a visible sensor sweep — cosmetic, no contraband system yet), hold
  alongside a beat, then resume. Rate-limited so patrols don't chain-scan.
- **escort** — hold a numbered slot in a tight triangle off the leader (leader at
  the apex, escorts filling alternating left/right rows), matched to the leader's
  heading and pace so the wing stays crisp while cruising; leave formation only to
  attack when the leader engages, then fall straight back in.

## Combat — what makes "attack" real

`Combat.swift` + the `World` loop:

- Ships have **shield / armor** with regen; damage hits shields first and the
  hull is untouched until shields are gone (no bleed-through — the shot that
  empties the shields does not also damage armor). The one exception is a
  shield-penetrating weapon (`wëap` Flags 0x0020), whose armor damage reaches
  the hull through live shields.
- Weapons become `WeaponSpec`s (damage, reload, projectile speed, range, beam vs.
  guided vs. fixed). A mount tracks cooldown and ammo.
- Firing spawns a **`Projectile`** (guided rounds steer toward the target) or, for
  beams, does an **instant hitscan** along the aim ray. No self-hits, no friendly
  fire within a government.
- A ship is **disabled**, not destroyed, the instant its armor crosses a fixed
  percentage of max armor — 33% by default, 10% if `shïp.Flags` bit 0x0010 is
  set (`Ship.disableArmorFraction`). This is a deterministic one-time state
  transition, not a random roll: it becomes a drifting, weaponless hulk
  (`shipDisabled` event) that everyone stops targeting. Only a ship that's
  *already* disabled is actually destroyed when a further hit zeroes its
  armor (`shipDestroyed` event). The player is never disabled this way — the
  app owns player death.
- **Point defense** (`wëap` Guidance 9/10, `WeapRes.isPointDefense`): a second
  targeting loop (`World.runPointDefense`) independent of a ship's own
  `currentTargetID` — each PD-equipped mount auto-targets the nearest
  in-range, PD-vulnerable (`wëap.Flags` 0x0080 inverted) guided `Projectile`
  and destroys it outright. Simplified: a real shot's `Durability` (PD hits
  survived) isn't modeled.
- **Ionization**: a hit adds `wëap.Ionization` to the victim's `Ship.ionCharge`
  (capped at `shïp.IonizeMax`); it dissipates at `shïp.Deionize`-derived
  `deionizePerSec` in `Ship.regen`. Once `ionCharge >= ionizeMax` the ship is
  "nearly immobilized" (Bible) — `Ship.step` ignores turn/thrust/afterburner
  input until it drops back below the threshold — and a weapon flagged
  `cantFireWhileIonized` (`wëap.Seeker` 0x0020) refuses to fire while its own
  ship is ionized.

## Population — the `Spawner`

`Spawner` reads a system's `SpawnTable` (its `düde`/`flët` list + average ship
count) and keeps the system inhabited:

- On entry it fills to the target population (and places one eligible fleet up
  front, so you often arrive to find a formation already on station); thereafter
  it tops up over time as ships jump out or die. The ambient trickle is
  deliberately unhurried (`spawnInterval`) so a system doesn't churn like an
  airport.
- Dudes are picked by probability, then a ship class is picked from the dude's
  weighted table; a brain is attached matching the dude's disposition.
- **Single ships are the backbone; fleets are an accent.** The lone-ship
  trickle is maintained toward `targetPopulation` counting *only* single ships
  (`singleShipCount`), so a fleet passing through never starves it. Fleets, by
  contrast, are capped to `maxConcurrentFleets` (1 in most systems, 2 in a busy
  hub) and each arrival prefers a `flët` type not already present, so a system
  reads as mostly lone traffic with the occasional varied formation among it —
  not the same couple of fleets sitting on top of the whole population. (An
  earlier cut let fleets top the head-count up to `maxPopulation` on their own
  timer while singles only filled to the smaller `targetPopulation`, so a fleet
  or two crowded the singles out entirely — "all fleets, no lone ships." This
  split is the fix.)
- **Fleets** spawn a flagship plus its escorts, formed up and escorting. They run
  on their *own* cadence (`fleetInterval`), separate from the ambient single-ship
  trickle — otherwise a lone-trader coin-flip won them every time and the player
  "never saw fleets" (the opposite failure). A fleet's `flët.LinkSyst` government bands are read against
  the system's government correctly (the index is `+128` to a resource id — an
  earlier off-by-128 silently made every govt-banded fleet ineligible).
- **Jump-in** isn't a standing start: an arrival tears in along its inbound
  heading well above its cruise cap (`Ship.entryOverspeed`, applied before the
  speed clamp in `Ship.step`) and decelerates to normal speed over ~1.3s — the
  visible inrush that reads as "warping in," on top of the renderer's warp
  streak. Departures leave past the edge (`shipArrived` / `shipDeparted` events
  for audio/visuals; the renderer also draws a `shipScanned` sensor sweep).

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
- `CombatTests` — shields-absorb-then-hull, projectile travel & kills, no
  friendly fire, instant beams, disable-threshold determinism, point defense
  (shoots down/ignores-immune guided shots), ionization (charge/dissipation/
  immobilization/blocked-firing).
- `AIBehaviorTests` — warship engages a hostile (and declines/accepts a fight
  by `MaxOdds`), wimpy trader flees, brave trader fights in range but flees
  out of range, interceptor orbits when idle and intervenes as piracy police,
  ammo-exhausted ships flee or dock, trader travels to a planet, departing
  ships jump out, and a full deterministic duel between two hostile
  interceptors resolves.
- `ShipSystemTests` — SkillVar jitters accel/turn by a supplied roll (and
  leaves them alone with none).
- Integration: `novaswift-extract ai "…/Nova Files"` runs the whole thing on the
  real game — e.g. Sol's traders come and go peacefully, Kania and Auroran
  space break into real dogfights, and interceptors visibly orbit/patrol
  across dozens of real systems.
