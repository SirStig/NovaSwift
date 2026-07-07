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

    /// Fill the system to its target population immediately (used on entry so the
    /// system isn't empty for the first few seconds).
    public func populate(_ world: World) {
        var guardCount = 0
        while world.npcs.count < targetPopulation && guardCount < maxPopulation * 2 {
            spawnOne(into: world, atEdge: false)
            guardCount += 1
        }
    }

    /// Called every step by the world.
    public func update(_ dt: Double, world: World) {
        timer -= dt
        guard world.npcs.count < targetPopulation, timer <= 0 else { return }
        timer = spawnInterval
        spawnOne(into: world, atEdge: true)
    }

    // MARK: Spawning

    private func spawnOne(into world: World, atEdge: Bool) {
        // Decide fleet vs. dude across the combined weighted table.
        let dudeWeight = table.dudes.reduce(0) { $0 + $1.prob }
        let fleetWeight = table.fleets.reduce(0) { $0 + $1.prob }
        let total = dudeWeight + fleetWeight
        guard total > 0 else { return }

        let roll = world.rng.int(in: 0...(total - 1))
        if roll < fleetWeight {
            if let fid = weightedPick(table.fleets.map { ($0.fleetID, $0.prob) }, roll: roll, world: world) {
                spawnFleet(fid, into: world, atEdge: atEdge)
                return
            }
        }
        let dRoll = world.rng.int(in: 0...(max(1, dudeWeight) - 1))
        if let did = weightedPick(table.dudes.map { ($0.dudeID, $0.prob) }, roll: dRoll, world: world) {
            spawnDude(did, into: world, atEdge: atEdge, leaderID: nil)
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
    private func spawnDude(_ dudeID: Int, into world: World, atEdge: Bool,
                           leaderID: Int?) -> Ship? {
        guard let dude = galaxy.game.dude(dudeID) else { return nil }
        let roll = world.rng.int(in: 0...9999)
        guard let shipID = dude.pickShip(roll: roll) else { return nil }
        let govt = dude.govt >= 128 ? dude.govt : (galaxy.shipSpec(shipID)?.government ?? independentGovt)

        let (pos, ang) = spawnPose(world, atEdge: atEdge)
        guard let ship = galaxy.makeShip(shipID, government: govt, at: pos, angle: ang) else { return nil }
        let brain = AIBrain(aiType: dude.aiType, govt: govt)
        brain.leaderID = leaderID
        ship.brain = brain
        world.addNPC(ship)
        return ship
    }

    /// Spawn a fleet: a lead ship plus its escorts, formed up on the leader.
    private func spawnFleet(_ fleetID: Int, into world: World, atEdge: Bool) {
        guard let fleet = galaxy.game.fleet(fleetID) else { return }
        let govt = fleet.govt >= 128 ? fleet.govt
                 : (galaxy.shipSpec(fleet.leadShip)?.government ?? table.systemGovt)

        let (pos, ang) = spawnPose(world, atEdge: atEdge)
        guard let lead = galaxy.makeShip(fleet.leadShip, government: govt, at: pos, angle: ang) else { return }
        lead.brain = AIBrain(aiType: .warship, govt: govt)
        let leadID = world.addNPC(lead)

        for escort in fleet.escorts {
            let count = escort.min == escort.max ? escort.min
                      : world.rng.int(in: escort.min...max(escort.min, escort.max))
            for _ in 0..<max(0, count) {
                guard world.npcs.count < maxPopulation else { return }
                let offset = Vec2(world.rng.double(in: -120...120), world.rng.double(in: -120...120))
                guard let e = galaxy.makeShip(escort.shipID, government: govt,
                                              at: pos + offset, angle: ang) else { continue }
                let brain = AIBrain(aiType: .interceptor, govt: govt)
                brain.leaderID = leadID
                e.brain = brain
                world.addNPC(e)
            }
        }
    }

    /// A spawn position and facing. Edge spawns arrive from hyperspace on a random
    /// bearing pointed inward; non-edge (initial fill) spawns scatter mid-system.
    private func spawnPose(_ world: World, atEdge: Bool) -> (Vec2, Double) {
        let ctx = world.systemContext
        let bearing = world.rng.double(in: 0...(2 * .pi))
        let r = atEdge ? ctx.spawnRadius : world.rng.double(in: 300...(ctx.jumpRadius * 0.6))
        let pos = ctx.center + Vec2(sin(bearing), cos(bearing)) * r
        // Face roughly toward the centre so arrivals fly into the system.
        let inward = (ctx.center - pos).angle
        return (pos, inward)
    }
}
