import Foundation
import EVNovaKit

/// Which dudes and fleets populate a system, and how densely. Built by the app
/// from a decoded `SystRes` (its `dudeSpawns`/`fleetSpawns`/`averageShips`).
public struct SpawnTable {
    public var dudes: [(dudeID: Int, prob: Int)]
    public var fleets: [(fleetID: Int, prob: Int)]
    public var averageShips: Int
    public var systemGovt: Int
    /// This system's own `sÿst.id` — needed to test `flët.LinkSyst`'s
    /// "128-2175 = a specific system id" case (FLEETS.md §3). -1 when a
    /// table is built without a real system (e.g. ad-hoc/test tables), which
    /// simply makes that one `LinkSyst` band never match.
    public var systemID: Int
    /// Reactive reinforcement fleet + timing: `sÿst.ReinfFleet`/`ReinfTime`/
    /// `ReinfIntrval` (FLEETS.md §5). -1 = no reinforcement fleet configured
    /// for this system.
    public var reinforcementFleet: Int
    /// Frames before `reinforcementFleet` arrives once triggered.
    public var reinforcementDelay: Int
    /// Minimum days between `reinforcementFleet` triggers (regen gate).
    public var reinforcementRegen: Int

    public init(dudes: [(dudeID: Int, prob: Int)] = [],
                fleets: [(fleetID: Int, prob: Int)] = [],
                averageShips: Int = 4, systemGovt: Int = independentGovt,
                systemID: Int = -1, reinforcementFleet: Int = -1,
                reinforcementDelay: Int = 0, reinforcementRegen: Int = 0) {
        self.dudes = dudes; self.fleets = fleets
        self.averageShips = averageShips; self.systemGovt = systemGovt
        self.systemID = systemID
        self.reinforcementFleet = reinforcementFleet
        self.reinforcementDelay = reinforcementDelay
        self.reinforcementRegen = reinforcementRegen
    }

    /// Build directly from a decoded system.
    public init(system: SystRes) {
        self.init(dudes: system.dudeSpawns, fleets: system.fleetSpawns,
                  averageShips: system.averageShips, systemGovt: system.government,
                  systemID: system.id, reinforcementFleet: system.reinforcementFleet,
                  reinforcementDelay: system.reinforcementDelay,
                  reinforcementRegen: system.reinforcementRegen)
    }
}

/// Maintains a living NPC population in the current system: it periodically spawns
/// dudes and fleets from the `SpawnTable`, weighted by their probabilities, at the
/// hyperspace edge, and lets the world despawn ships that jump out or die. This is
/// what makes a system feel inhabited — traders coming and going, patrols on
/// station, the occasional pirate pack.
public final class Spawner {
    public let galaxy: Galaxy
    public var table: SpawnTable
    /// How many NPCs to keep around; derived from the system's average count.
    public var targetPopulation: Int
    public var maxPopulation = 18
    /// Seconds between arrival attempts once below target.
    public var spawnInterval: Double = 2.5
    private var timer: Double = 0

    /// Sim-seconds since this spawner was created — drives the reactive
    /// reinforcement-fleet timers below (FLEETS.md §5), independent of
    /// `timer` (which only gates *ambient* dude/fleet arrivals).
    private var simClock: Double = 0
    /// Sim-time at which a triggered reinforcement fleet should actually
    /// arrive, once its `ReinfTime`/frame delay has elapsed. `nil` = no
    /// reinforcement currently in flight for this system.
    private var reinforcementDueAt: Double?
    /// Sim-time before which a new reinforcement trigger is suppressed —
    /// `sÿst.ReinfIntrval`'s regen gate, so a system with allies stuck in a
    /// losing fight doesn't re-summon every tick once it first triggers.
    private var reinforcementCooldownUntil: Double = 0
    /// EV Nova's `ReinfIntrval` is in calendar days, but nothing at this
    /// layer (`Spawner`/`World`) tracks a galaxy day clock — that lives in
    /// `EVNovaStory.GameDate`, a layer up, and isn't threaded through combat
    /// simulation. Treat a "day" as this many sim-seconds so the regen gate
    /// still does its job (suppressing back-to-back re-triggers) without
    /// pretending to calendar accuracy — an engine invention in the same
    /// spirit as `maxPopulation`/`spawnInterval` above (see FLEETS.md §7).
    private let secondsPerReinforcementDay: Double = 60

    public init(galaxy: Galaxy, table: SpawnTable) {
        self.galaxy = galaxy
        self.table = table
        let avg = max(2, table.averageShips)
        self.targetPopulation = min(maxPopulation, avg + 2)
    }

    /// Where a spawn comes from: mid-system (initial fill), the hyperspace edge
    /// (a jump-in), or lifting off from a stellar object (planet launch).
    private enum SpawnOrigin { case interior, edge, planet }

    /// Fill the system to its target population immediately (used on entry so the
    /// system isn't empty for the first few seconds).
    public func populate(_ world: World) {
        var guardCount = 0
        while world.npcs.count < targetPopulation && guardCount < maxPopulation * 2 {
            spawnOne(into: world, origin: .interior)
            guardCount += 1
        }
    }

    /// Called every step by the world.
    public func update(_ dt: Double, world: World) {
        simClock += dt
        updateReinforcements(world)

        timer -= dt
        guard world.npcs.count < targetPopulation, timer <= 0 else { return }
        timer = spawnInterval
        // Most arrivals jump in from hyperspace; some lift off from a spaceport so
        // the player also sees traffic *leaving* planets, not only inbound.
        let hasPads = world.systemContext.bodies.contains { $0.canLand }
        let origin: SpawnOrigin = (hasPads && world.rng.double(in: 0...1) < 0.35) ? .planet : .edge
        spawnOne(into: world, origin: origin)
    }

    // MARK: Spawning

    private func spawnOne(into world: World, origin: SpawnOrigin) {
        // Decide fleet vs. dude across the combined weighted table. Fleets always
        // jump in as a group (they don't lift off a single pad together), and a
        // fleet a system's own DudeTypes table lists is still filtered here by
        // its own `LinkSyst` (FLEETS.md §3/§8: treated as a second validity
        // check on top of the system's explicit reference, since the current
        // `SpawnTable` is built solely from one system's own spawn table and
        // has no way to sweep in fleets that aren't listed anywhere).
        let eligibleFleets = origin == .planet ? [] : table.fleets.filter { isFleetEligible($0.fleetID, world: world) }
        let dudeWeight = table.dudes.reduce(0) { $0 + $1.prob }
        let fleetWeight = eligibleFleets.reduce(0) { $0 + $1.prob }
        let total = dudeWeight + fleetWeight
        guard total > 0 else { return }

        let roll = world.rng.int(in: 0...(total - 1))
        if !eligibleFleets.isEmpty, roll < fleetWeight {
            if let fid = weightedPick(eligibleFleets.map { ($0.fleetID, $0.prob) }, roll: roll, world: world) {
                spawnFleet(fid, into: world, origin: origin)
                return
            }
        }
        let dRoll = world.rng.int(in: 0...(max(1, dudeWeight) - 1))
        if let did = weightedPick(table.dudes.map { ($0.dudeID, $0.prob) }, roll: dRoll, world: world) {
            spawnDude(did, into: world, origin: origin, leaderID: nil)
        }
    }

    // MARK: LinkSyst eligibility

    /// `flët.LinkSyst`: which systems a fleet may spawn in (FLEETS.md §3 —
    /// Bible: "-1 Any system · 128-2175 ID of a specific system · 10000-10255
    /// Any system belonging to this specific government · 15000-15255 Any
    /// system belonging to an ally of this govt · 20000-20255 Any system
    /// belonging to any but this govt · 25000-25255 Any system belonging to
    /// an enemy of this govt"). Looks the fleet up by id first; missing data
    /// is not eligible (nothing to check).
    private func isFleetEligible(_ fleetID: Int, world: World) -> Bool {
        guard let fleet = galaxy.game.fleet(fleetID) else { return false }
        return isFleetEligible(fleet, world: world)
    }

    /// The government referenced by each banded `LinkSyst` range is *not*
    /// necessarily the fleet's own `Govt` — it's an independent government id
    /// encoded directly in the `LinkSyst` value (e.g. a pirate fleet can be
    /// flagged eligible for "systems hostile to the Federation" without the
    /// fleet itself belonging to the Federation). Ally/enemy tests reuse
    /// `Diplomacy.areAllied`/`.areEnemies` — no new relational logic, per
    /// FLEETS.md §3's own analysis.
    private func isFleetEligible(_ fleet: FleetRes, world: World) -> Bool {
        let link = fleet.linkSystem
        switch link {
        case -1:
            return true
        case 128...2175:
            return link == table.systemID
        case 10000...10255:
            return table.systemGovt == link - 10000
        case 15000...15255:
            guard let dip = world.diplomacy else { return true }
            return dip.areAllied(table.systemGovt, link - 15000)
        case 20000...20255:
            return table.systemGovt != link - 20000
        case 25000...25255:
            guard let dip = world.diplomacy else { return true }
            return dip.areEnemies(table.systemGovt, link - 25000)
        default:
            // Outside the documented bands (or 0/blank on non-`flët` test
            // fixtures) — permissive default so it doesn't silently zero out
            // a fleet the system's own spawn table already explicitly lists.
            return true
        }
    }

    // MARK: Reactive reinforcement fleets (sÿst.ReinfFleet/ReinfTime/ReinfIntrval)

    /// The reactive half of FLEETS.md §5: `AIBrain.favorableOdds` already
    /// gates whether an individual ship picks a fight; this is the other
    /// half — when a government's ships already *in* this system are
    /// outnumbered and under attack, summon `table.reinforcementFleet` after
    /// its frame delay, then hold off retriggering until the regen window
    /// passes. One reinforcement can be in flight (triggered-but-not-yet-
    /// arrived) at a time per system, matching "a fleet jumps in as a unit."
    private func updateReinforcements(_ world: World) {
        guard table.reinforcementFleet >= 128 else { return }

        if let dueAt = reinforcementDueAt {
            guard simClock >= dueAt else { return }
            reinforcementDueAt = nil
            if isFleetEligible(table.reinforcementFleet, world: world) {
                spawnFleet(table.reinforcementFleet, into: world, origin: .edge)
            }
            reinforcementCooldownUntil = simClock
                + Double(max(0, table.reinforcementRegen)) * secondsPerReinforcementDay
            return
        }

        guard simClock >= reinforcementCooldownUntil,
              let fleet = galaxy.game.fleet(table.reinforcementFleet) else { return }
        // The reinforcement fleet's own government is who we're checking is
        // "outmatched" — falling back to the system's controlling government
        // when the fleet has none set, same fallback order `spawnFleet` uses.
        let reinforcementGovt = fleet.govt >= 128 ? fleet.govt : table.systemGovt
        guard governmentUnderAttackAndOutmatched(reinforcementGovt, world: world) else { return }

        let delaySeconds = Double(max(0, table.reinforcementDelay)) / max(1, galaxy.combatTuning.framesPerSecond)
        reinforcementDueAt = simClock + delaySeconds
        Log.world.debug("Spawner: reinforcement fleet \(self.table.reinforcementFleet) triggered for govt \(reinforcementGovt), arriving in \(delaySeconds, format: .fixed(precision: 1))s")
    }

    /// System-wide odds check for the reinforcement trigger: are `govt`'s
    /// ships (plus its allies) present in this system, currently being
    /// targeted by an enemy, and outmatched per that government's own
    /// `gövt.MaxOdds`? This mirrors the power formula `AIBrain.favorableOdds`
    /// uses (combat strength scaled 30%-100% by shield fraction) but at
    /// government/system granularity rather than one ship's personal
    /// go/no-go decision — a different question ("should the *system*
    /// summon backup") from AIBrain's ("should *I* personally engage"), so
    /// this doesn't reuse that method directly; see the assignment note on
    /// why no hook was added to `AIBrain.swift`.
    private func governmentUnderAttackAndOutmatched(_ govt: Int, world: World) -> Bool {
        guard govt >= 128, let dip = world.diplomacy, let gov = dip.govt(govt), gov.maxOdds > 0 else { return false }

        func isFriend(_ s: Ship) -> Bool { s.government == govt || dip.areAllied(govt, s.government) }
        func isFoe(_ s: Ship) -> Bool {
            s.isPlayer ? dip.isHostileToPlayer(govt) : dip.areEnemies(govt, s.government)
        }
        func power(_ s: Ship) -> Double { s.combatStrength * (0.3 + 0.7 * s.shieldFraction) }

        let living = world.allShips.filter { $0.isAlive && !$0.disabled }
        let friends = living.filter(isFriend)
        let foes = living.filter(isFoe)
        guard !friends.isEmpty, !foes.isEmpty else { return false }

        // "Under attack": at least one friendly ship is a foe's current
        // target — not just diplomatically hostile-capable presence.
        let friendUnderFire = friends.contains { friend in
            foes.contains { $0.currentTargetID == friend.entityID }
        }
        guard friendUnderFire else { return false }

        let friendlyStrength = friends.reduce(0.0) { $0 + power($1) }
        let enemyStrength = foes.reduce(0.0) { $0 + power($1) }
        guard friendlyStrength > 0 else { return true }
        let tolerated = friendlyStrength * (Double(gov.maxOdds) / 100.0)
        return enemyStrength > tolerated
    }

    private func weightedPick(_ entries: [(Int, Int)], roll: Int, world: World) -> Int? {
        guard !entries.isEmpty else { return nil }
        let total = entries.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return entries.first?.0 }
        var acc = 0
        let target = ((roll % total) + total) % total
        for e in entries { acc += e.1; if target < acc { return e.0 } }
        return entries.last?.0
    }

    /// Spawn a single dude's ship with an AI brain matching its disposition.
    @discardableResult
    private func spawnDude(_ dudeID: Int, into world: World, origin: SpawnOrigin,
                           leaderID: Int?) -> Ship? {
        guard let dude = galaxy.game.dude(dudeID) else { return nil }
        let roll = world.rng.int(in: 0...9999)
        guard let shipID = dude.pickShip(roll: roll) else { return nil }
        let govt = dude.govt >= 128 ? dude.govt : (galaxy.shipSpec(shipID)?.government ?? independentGovt)

        let (pos, ang, arrival) = spawnPose(world, origin: origin)
        // Equip NPCs from their real hull loadout (preinstalled outfits: afterburner,
        // extra shields/weapons, fuel) — the same aggregation the player uses — so a
        // spawned ship matches its authentic EV Nova fit, not a bare hull.
        guard let ship = galaxy.makeLoadedShip(shipID, government: govt, at: pos, angle: ang,
                                               skillRoll: world.rng.double(in: -1...1)) else { return nil }
        let brain = AIBrain(aiType: dude.aiType, govt: govt)
        brain.leaderID = leaderID
        ship.brain = brain
        world.addNPC(ship, arrival: arrival)
        return ship
    }

    /// Spawn a fleet: a lead ship plus its escorts, formed up on the leader. The
    /// leader flies to its own disposition (from the hull's inherent AI), and each
    /// escort takes a numbered formation slot so they hold a tidy wing.
    private func spawnFleet(_ fleetID: Int, into world: World, origin: SpawnOrigin) {
        guard let fleet = galaxy.game.fleet(fleetID) else { return }
        let govt = fleet.govt >= 128 ? fleet.govt
                 : (galaxy.shipSpec(fleet.leadShip)?.government ?? table.systemGovt)

        let (pos, ang, arrival) = spawnPose(world, origin: origin)
        guard let lead = galaxy.makeLoadedShip(fleet.leadShip, government: govt, at: pos, angle: ang,
                                               skillRoll: world.rng.double(in: -1...1)) else { return }
        // The flagship acts on its own hull's disposition (a freighter convoy leader
        // trades; a warfleet's leader fights) rather than always being a warship.
        let leadAI = galaxy.game.ship(fleet.leadShip).map { AIType(raw: $0.inherentAI) } ?? .warship
        lead.brain = AIBrain(aiType: leadAI == .unknown ? .warship : leadAI, govt: govt)
        let leadID = world.addNPC(lead, arrival: arrival)

        var slot = 0
        for escort in fleet.escorts {
            let count = escort.min == escort.max ? escort.min
                      : world.rng.int(in: escort.min...max(escort.min, escort.max))
            for _ in 0..<max(0, count) {
                guard world.npcs.count < maxPopulation else { return }
                let offset = Vec2(world.rng.double(in: -120...120), world.rng.double(in: -120...120))
                guard let e = galaxy.makeLoadedShip(escort.shipID, government: govt,
                                                    at: pos + offset, angle: ang,
                                                    skillRoll: world.rng.double(in: -1...1)) else { continue }
                // Escorts fly their own hull's disposition so that, if the flagship
                // dies, they fall back to hull-appropriate behavior rather than
                // always reverting to a generic interceptor.
                let escortAI = galaxy.game.ship(escort.shipID).map { AIType(raw: $0.inherentAI) } ?? .interceptor
                let brain = AIBrain(aiType: escortAI == .unknown ? .interceptor : escortAI, govt: govt)
                brain.leaderID = leadID
                brain.formationSlot = slot
                e.brain = brain
                world.addNPC(e, arrival: arrival)
                slot += 1
            }
        }
    }

    /// A spawn position, facing, and the arrival effect it should trigger. Edge
    /// spawns jump in on a random bearing pointed inward; interior (initial fill)
    /// spawns scatter mid-system with no effect; planet spawns lift off a landable
    /// stellar object, facing outward.
    private func spawnPose(_ world: World, origin: SpawnOrigin) -> (Vec2, Double, World.ArrivalMode) {
        let ctx = world.systemContext
        switch origin {
        case .planet:
            let pads = ctx.bodies.filter { $0.canLand }
            if let pad = pads.isEmpty ? ctx.bodies.first : pads[world.rng.int(in: 0...(pads.count - 1))] {
                let outward = (pad.position - ctx.center)
                let ang = (outward.length < 1 ? Vec2(0, 1) : outward).angle
                return (pad.position, ang, .launch)
            }
            fallthrough
        case .edge:
            let bearing = world.rng.double(in: 0...(2 * .pi))
            let pos = ctx.center + Vec2(sin(bearing), cos(bearing)) * ctx.spawnRadius
            return (pos, (ctx.center - pos).angle, .hyperspace)
        case .interior:
            let bearing = world.rng.double(in: 0...(2 * .pi))
            let r = world.rng.double(in: 300...(ctx.jumpRadius * 0.6))
            let pos = ctx.center + Vec2(sin(bearing), cos(bearing)) * r
            return (pos, (ctx.center - pos).angle, .populate)
        }
    }
}
