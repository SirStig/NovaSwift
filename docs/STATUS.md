# Status

What a player can actually do today. This is the only doc that answers that
question — if another doc claims a feature is finished, this one wins.

Three words, from the [charter](CHARTER.md):

- **Wired** — the running app drives it. The player feels it.
- **Built, not wired** — the code exists and is tested, but nothing in the play
  loop calls it. For the player, it isn't in the game.
- **Missing** — not built, or a UI shell.

## The short version

NOVA Swift is a near-complete, faithful port. The whole game is playable start
to finish on macOS, iPadOS, iOS and tvOS: create a pilot from a real starting
scenario, fly, fight, trade, take missions, play the storylines through, and die
with consequences.

What's left is fidelity fine-tuning and polish, not missing systems. The one real
soft spot is how ships fly and spawn.

## What works

**Flying and fighting.** Newtonian flight on your real hull-and-outfit stats.
NPCs spawn from the actual `düde` and `flët` tables, fight using their
government's dispositions, and take real damage. Target lock, radar and the
status bar are driven from live state through the authentic `ïntf` layout.
Weapons behave as their `wëap` records describe — guidance modes, turret arcs and
blind spots, submunitions, point defense, fighter bays, beams, ionization,
cloaking, and per-type jamming weighed against each seeker's own vulnerability.

**Stakes.** You can die. With an escape pod you're rescued at the nearest port
minus your ship and outfits; without one it's back to the main menu. Repairs and
fuel cost credits. Shooting the wrong government dents your record, and that
record decays with distance from where it happened.

**The galaxy.** Real `sÿst` coordinates and links, fuel-gated hyperjumps,
hypergates and wormholes, message buoys, minable asteroids, nebulae on the map,
and stellar objects you can dominate for tribute — or, where the data allows,
shoot to pieces and watch regenerate on their own timer.

**Missions and story.** The story runtime is live end to end. Pick up a job at
the bar, fly it, finish it — cargo, courier, passenger, bounty, escort. Mission
ships spawn into the world around you and report back when you destroy, disable
or board them. The galaxy clock advances on every landing and jump, so `crön`
events and news fire on schedule. Storylines rewrite the map: systems appear and
vanish, planets get destroyed.

**The spaceport.** Trade, outfitter and shipyard run against a persistent pilot
with real prices, mass-proportional outfit costs, gun and turret slot limits,
tech-level and mission-bit gating, and rank discounts. Junk cargo trades
alongside the six standard commodities. The bar's extras — hiring escorts,
gambling on the races, the mission board — all work.

**Boarding and plunder.** Disable a ship, board it, and take its cargo, credits,
fuel or ammo — or capture the hull outright and add it to your escort wing.

**Presentation.** Real `bööm` explosion sprites over a particle system, weapon
smoke and spark trails, hit spray, asteroid debris, lightning beams, animated
stellars, and the `shän` overlay layers (engine glow, running lights, weapon
glow, shields, alternating detail). The main menu is the original's, down to the
button plates sliding into place.

**Pilots and platforms.** Multiple pilots with save history and backups.
Controller support everywhere, and required on tvOS. iCloud sync for imported
game data. Host-authoritative co-op. Plug-ins download, install and override
correctly.

## The one thing that still feels off

EV Nova's AI and spawning logic were never open-sourced. Unlike the rest of the
port there was no original code to work from: `AIBrain.swift`, `Spawner.swift`
and the flight code are rebuilt from the data tables and hours of watching how
the original behaves. It covers what the Bible documents (see [AI.md](AI.md) and
[AI_GROUND_TRUTH.md](reverse-engineering/AI_GROUND_TRUTH.md)) and it's close, but
three things still don't quite *feel* right:

- **Spawn rhythm.** Ambient traffic is a heuristic that trickles toward
  `sÿst.AvgShips`, not the original's algorithm. Single ships are the backbone
  and fleets a capped accent, which fixed the old "all fleets, no stragglers"
  problem — but the arrival cadence and ship mix are still hand-tuned.
- **Flight handling.** Ships holding formation fly a driftless model, which
  reproduces the original's tight formation-keeping. Lone traffic, lone
  combatants and the player fly Newtonian — including the reverse-and-fire
  maneuver that's a signature of the original — so ambient flight rests on
  hand-tuned steering rather than anything documented.
- **Combat transitions.** One mission `ShipBehav` case falls through to normal
  AI, brainless ships drift, and some engagement timings are approximations.

Most of the game plays close to the original. This is where you can still tell
it's a reconstruction, because for this one piece there was nothing to copy.

## Built, not wired

- **Junk and `öops` price disasters.** The decoders are correct and the wiring is
  designed ([JUNK_OOPS_DESIGN.md](reverse-engineering/JUNK_OOPS_DESIGN.md)), but
  there's no daily price-disaster roll yet. `përs.showsDisasterInfo` and
  `öops.isNewsOnly` are waiting on the same work.
- **Classic pilot save encoding.** `PilotSave` can write the original archive
  format; the app persists native JSON instead. The decode path is used, the
  encode path isn't.

## Missing

- **AI, spawning and flight fidelity** — the quality gap described above.
- **Two cosmetic `cölr` anchors.** `menuFont`/`menuFontSize` has no target here
  (our main-menu labels are PICT art, not rendered text), and `progressBar` is a
  fixed Mac-pixel rect where our loading bar reflows. Both decode; neither is
  carried.

## What's next

The rule, from the charter: *if the player can't feel it, it isn't done.*

1. **Make ships fly and spawn like the original.** The biggest remaining gap
   between this and "it feels like EV Nova." Polish on something that already
   works, not a new feature. See [AI.md](AI.md).
2. **Junk and `öops` trading.** The last economy corner, already designed —
   price disasters first, then junk trading.

[ROADMAP.md](ROADMAP.md) has the full sequence.
