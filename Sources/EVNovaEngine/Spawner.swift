import Foundation
import EVNovaKit

/// Which dudes and fleets populate a system, and how densely. Built by the app
/// from a decoded `SystRes` (its `dudeSpawns`/`fleetSpawns`/`averageShips`).
public struct SpawnTable {
    public var dudes: [(dudeID: Int, prob: Int)]
    public var fleets: [(fleetID: Int, prob: Int)]
    public var averageShips: Int
    public var systemGovt: Int

    public init(dudes: [(dudeID: Int, prob: Int)] = [],
                fleets: [(fleetID: Int, prob: Int)] = [],
                averageShips: Int = 4, systemGovt: Int = independentGovt) {
        self.dudes = dudes; self.fleets = fleets
        self.averageShips = averageShips; self.systemGovt = systemGovt
    }

    /// Build directly from a decoded system.
    public init(system: SystRes) {
        self.init(dudes: system.dudeSpawns, fleets: system.fleetSpawns,
                  averageShips: system.averageShips, systemGovt: system.government)
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
        // jump in as a group (they don't lift off a single pad together).
        let dudeWeight = table.dudes.reduce(0) { $0 + $1.prob }
        let fleetWeight = table.fleets.reduce(0) { $0 + $1.prob }
        let total = dudeWeight + fleetWeight
        guard total > 0 else { return }

        let roll = world.rng.int(in: 0...(total - 1))
        if origin != .planet, roll < fleetWeight {
            if let fid = weightedPick(table.fleets.map { ($0.fleetID, $0.prob) }, roll: roll, world: world) {
                spawnFleet(fid, into: world, origin: origin)
                return
            }
        }
        let dRoll = world.rng.int(in: 0...(max(1, dudeWeight) - 1))
        if let did = weightedPick(table.dudes.map { ($0.dudeID, $0.prob) }, roll: dRoll, world: world) {
            spawnDude(did, into: world, origin: origin, leaderID: nil)
        }
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
        guard let ship = galaxy.makeLoadedShip(shipID, government: govt, at: pos, angle: ang) else { return nil }
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
        guard let lead = galaxy.makeLoadedShip(fleet.leadShip, government: govt, at: pos, angle: ang) else { return }
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
                                                    at: pos + offset, angle: ang) else { continue }
                let brain = AIBrain(aiType: .interceptor, govt: govt)
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
