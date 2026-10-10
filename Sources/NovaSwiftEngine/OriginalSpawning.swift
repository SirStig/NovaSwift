import Foundation
import NovaSwiftKit

/// The original engine's population rules, as numbers and pure helpers
/// (FIDELITY_PLAN AI-09..AI-12, AI-17). `Spawner`'s `.original` model below
/// drives a live `World` with them.
public enum OriginalSpawnRules {
    /// NPC ship slots: the original's 64-slot pool less the player's slot 0
    /// and the 8-slot reserve every ambient spawn leaves free.
    public static let npcSlots = 55

    /// A jump-in starts this far from the system origin (0, 0), facing it.
    /// The spawners sum the arrival brake (50 px/tick, less 1.165 each tick
    /// while positive, the speed stored as a 32-bit float each step) and add
    /// 1000: 2098.004 px. That sum assumes one brake step per 1.0-scale
    /// tick; the brake actually runs once per raw call while the ship moves
    /// only 0.63 of its speed per call, so at the 21 ms floor it slides about
    /// 700 px and rests near 1400 px out. The first audit's 2102.64 used 1.16
    /// for the brake; the exe's constant is the double 1.165 (0x00575250).
    public static let jumpInRadius: Double = {
        var sum = 0.0
        var speed = Float(jumpInSpeedPerTick)
        repeat {
            sum += Double(speed)
            speed = Float(Double(speed) - arrivalBrakePerTick)
        } while speed > 0
        return Double(Float(sum) + 1000)
    }()
    /// How far behind their formation slot the player's escorts are placed
    /// on a jump arrival (0x0041af90): Σ(45 − 1.165k) while positive, ≈ 892 px,
    /// before they're flung forward at 50 px/tick.
    public static let escortJumpLag: Double = {
        var sum: Float = 0
        var speed: Float = 45
        repeat {
            sum += speed
            speed = Float(Double(speed) - arrivalBrakePerTick)
        } while speed > 0
        return Double(sum)
    }()
    /// Inbound speed of a jump-in, px/tick (`0x0057522c`).
    public static let jumpInSpeedPerTick = 50.0
    /// How fast the arrival state lets the speed fall back, px/tick per raw call.
    public static let arrivalBrakePerTick = 1.165
    /// The same brake per normalized tick: 47.62 raw calls a second.
    public static var arrivalBrakePerSecondSquared: Double {
        OriginalClock.perSecondSquared(arrivalBrakePerTick / OriginalClock.rawCallTickScale)
    }
    /// Speed leaving a hypergate, px/tick (half that for a ship attached to the player).
    public static let gateExitSpeedPerTick = 30.0
    /// Initial-fill ships scatter over `[-750, 750)` on each axis around the origin.
    public static let initialScatter = 750
    /// Fleet escorts start within ±150 px of their lead on each axis.
    public static let escortScatter = 150
    /// A speed-0 warship of the initial fill anchors this far from the system's
    /// first stellar (`0x00575268`).
    public static let anchorDistance = 100.0
    /// përs slot 0x3fe: the revenge përs that hunts a dominator (AI-16).
    public static let revengePersID = 0x3fe + 128

    /// `sÿst` DudeTypes weights as the loader keeps them: when the dude weights
    /// don't already total 100 (or 0), each is rescaled by `100 / total` and
    /// truncated. Fleet entries never take part.
    public static func normalizedDudeWeights(_ table: [(dudeID: Int, prob: Int)]) -> [(dudeID: Int, weight: Int)] {
        let total = table.reduce(0) { $0 + $1.prob }
        guard total != 0, total != 100 else { return table.map { ($0.dudeID, $0.prob) } }
        let scale = Float(100) / Float(total)
        return table.map { ($0.dudeID, Int(Float($0.prob) * scale)) }
    }

    /// The original's cumulative weighted pick: `roll` is `range(total)`, and
    /// the first entry whose running total reaches `roll + 1` wins.
    public static func cumulativePick<T>(_ entries: [(T, Int)], roll: Int) -> T? {
        var acc = 0
        for (value, weight) in entries {
            acc += weight
            if roll + 1 <= acc { return value }
        }
        return nil
    }

    /// The `LinkSyst` bands, as the fleet sweep (0x00425280) and the përs
    /// spawner (0x004235c0) test them against `systemID` owned by `systemGovt`
    /// (`independentGovt` when unowned). Two quirks are kept:
    /// - a value equal to the system's 0-based *index* also matches, so
    ///   `LinkSyst 5` appears in system 133 and `LinkSyst 128` in both system
    ///   128 and system 256;
    /// - the përs spawner opens its government band at 9999, one below the
    ///   fleet sweep's 10000, so a përs with `LinkSyst 9999` haunts every
    ///   independent system.
    /// The ally, not-that-government and hostile bands never match an
    /// independent system.
    public static func linkSystMatches(_ link: Int, systemID: Int, systemGovt: Int,
                                       persBands: Bool,
                                       allied: (Int, Int) -> Bool,
                                       hostile: (Int, Int) -> Bool) -> Bool {
        let index = systemID - 128
        let govtIndex = systemGovt >= 128 ? systemGovt - 128 : -1
        if link == -1 || link == index { return true }
        if (128..<10000).contains(link), index == link - 128 { return true }
        if ((persBands ? 9999 : 10000)..<15000).contains(link), link - 10000 == govtIndex { return true }
        guard govtIndex >= 0 else { return false }
        switch link {
        case 15000..<20000: return allied(link - 15000 + 128, systemGovt)
        case 20000..<25000: return link - 20000 != govtIndex
        case 25000..<30000: return hostile(link - 25000 + 128, systemGovt)
        default: return false
        }
    }

    /// A `flët` Quote with its `#` characters filled the original's way: the
    /// first `#` of a run becomes 1–9 and each following `#` 0–9.
    public static func fillQuote(_ text: String, rng: inout NovaRandom) -> String {
        var out = ""
        var inRun = false
        for ch in text {
            if ch == "#" {
                out.append(Character(String(inRun ? rng.range(10) : rng.range(9) + 1)))
                inRun = true
            } else {
                out.append(ch)
                inRun = false
            }
        }
        return out
    }

    /// The name the përs spawner dedups by: the record name with any
    /// `;`-subtitle dropped. Two përs sharing it count as one (known bug #128).
    public static func persDedupName(_ name: String) -> String {
        name.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
    }

    /// One nav stellar as `Stellar_SelectRandomAdjacentTravelStellar`
    /// (0x0040c790) weighs it.
    public struct TravelStellar {
        public let index: Int
        /// Present, and at x < 1000 and y < 1000 in the data's coordinates.
        public let usable: Bool
        /// spöb Flags 0x20 (uninhabited) and not a gate or wormhole.
        public let uninhabited: Bool
        /// Its government is hostile to (or xenophobic toward) the ship's.
        public let hostile: Bool
        public let hypergate: Bool
        public let wormhole: Bool
        public init(index: Int, usable: Bool, uninhabited: Bool, hostile: Bool, hypergate: Bool, wormhole: Bool) {
            self.index = index; self.usable = usable; self.uninhabited = uninhabited
            self.hostile = hostile; self.hypergate = hypergate; self.wormhole = wormhole
        }
    }

    /// The stellars a ship of a government with gövt Flags2 `govtFlags2` may
    /// pick as its next travel stop, `strict` being the `Rand(3) == 0` roll of
    /// `Stellar_SelectRandomAdjacentDestination` (0x0046e9e0). The original
    /// draws `Rand(16)` until a slot qualifies, i.e. uniformly among these.
    public static func travelCandidates(_ stellars: [TravelStellar], govtFlags2: Int, strict: Bool) -> [Int] {
        let avoidsGates = govtFlags2 & 0x20 != 0
        let prefersGates = govtFlags2 & 0x40 != 0
        let prefersWormholes = govtFlags2 & 0x80 != 0
        let open = stellars.filter { $0.usable && !$0.hostile }
        let gates = open.filter(\.hypergate)
        let wormholes = open.filter(\.wormhole)
        let ports = open.filter { !$0.uninhabited }
        let plainPorts = ports.filter { !$0.hypergate && !$0.wormhole }
        if prefersWormholes, !wormholes.isEmpty { return wormholes.map(\.index) }
        if prefersGates, !gates.isEmpty { return gates.map(\.index) }
        if !ports.isEmpty, strict, !avoidsGates, !plainPorts.isEmpty || !gates.isEmpty {
            return ports.filter { !$0.wormhole }.map(\.index)
        }
        guard !ports.isEmpty, !plainPorts.isEmpty || (!gates.isEmpty && !avoidsGates) else { return [] }
        return ports.filter { s in
            !(s.wormhole && !prefersWormholes) && !(s.hypergate && avoidsGates)
        }.map(\.index)
    }
}

// MARK: - The original maintenance loop

extension Spawner {

    /// `System_RebuildInitialNpcAndMissionPopulation` 0x0041af90, ambient
    /// slice: exactly `AvgShips` attempts, each a përs (1 in 7), else a
    /// LinkSyst fleet sweep (1 in 7 of the rest), else a system dude. The
    /// ships scatter over the middle of the system on random headings at
    /// their class speed. Then each Person1-8 slot rolls its %Prob.
    func populateOriginal(_ world: World) {
        for _ in 0..<max(0, table.averageShips) {
            originalDudeAttempt(world, maintenance: false)
        }
        for slot in galaxy.game.system(table.systemID)?.persons ?? [] {
            guard world.persSpawnEligible(slot.id) else { continue }
            guard world.rng.range(100) + 1 <= slot.chance else { continue }
            if let ship = originalSpawnPers(world, maintenance: false, forcedID: slot.id) {
                placeInitialFill(ship, world: world)
                world.addNPC(ship, arrival: .populate)
            }
        }
        originalTryAmbush(world)
    }

    /// `Mission_TrySpawnMissionShipAmbush` 0x00426dd0, on every arrival and
    /// launch: once the player has dominated a world, the revenge përs (1150,
    /// slot 0x3fe) comes for them on 1 arrival in 10 (one dominated world) or
    /// 1 in 5 (more), hostile, with its HailQuote.
    func originalTryAmbush(_ world: World) {
        let revengeID = OriginalSpawnRules.revengePersID
        let dominated = world.dominatedStellars.count
        guard dominated > 0, world.persSpawnEligible(revengeID),
              world.rng.range(dominated == 1 ? 10 : 5) == 0,
              let ship = originalSpawnPers(world, maintenance: true, forcedID: revengeID) else { return }
        ship.brain?.behaviorOverride = .attackPlayer
        // It takes the përs spawner's own slot placement: scattered over the
        // middle of the system, not jumping in.
        let span = 2 * OriginalSpawnRules.initialScatter
        ship.position = Vec2(Double(world.rng.range(span) - OriginalSpawnRules.initialScatter),
                             Double(world.rng.range(span) - OriginalSpawnRules.initialScatter))
        world.addNPC(ship, arrival: .populate)
        // 0x00426d10: a 'STR ' resource at HailQuote + 4999 overrides STR# 7101.
        // `<OSN>` names the speaking përs (0x004444f0); the host's status bar
        // fills the player tags.
        if let pers = galaxy.game.pers(revengeID), pers.hailQuote > 0 {
            let quotes = galaxy.game.stringList(7101)?.strings ?? []
            let quote = galaxy.game.singleString(pers.hailQuote + 4999)
                ?? (pers.hailQuote <= quotes.count ? quotes[pers.hailQuote - 1] : nil)
            if let quote, !quote.isEmpty {
                world.postOverlayMessage(quote.replacingOccurrences(of: "<OSN>", with: pers.name), frames: 0x1a4)
            }
        }
    }

    /// The tail of 0x0041d6e0: `Rand(30) + 30` maintenance calls after an
    /// arrival or launch, the cargo holds of the player's non-mission escorts
    /// on trader hulls (InherentAI < 3) are summed; 200 tons or more brings
    /// flët 383, 50–199 brings flët 382, both led by interceptors.
    func originalEscalationTick(_ world: World) {
        if escalationCountdown == nil { escalationCountdown = world.rng.range(30) + 30 }
        guard let left = escalationCountdown, left >= 0 else { return }
        guard left == 0 else { escalationCountdown = left - 1; return }
        escalationCountdown = -1
        let holds = world.npcs.reduce(0) { sum, ship in
            guard ship.brain?.leaderID == World.playerEntityID, ship.missionID == nil,
                  let hull = galaxy.game.ship(ship.shipTypeID), hull.inherentAI < 3 else { return sum }
            return sum + hull.cargoSpace
        }
        if holds >= 200 {
            originalSpawnFleet(383, world: world, leadAI: .interceptor, showQuote: true)
        } else if holds >= 50 {
            originalSpawnFleet(382, world: world, leadAI: .interceptor, showQuote: true)
        }
    }

    /// One raw call of `System_TickNpcSpawnMaintenance` 0x0041d6e0's ambient
    /// arm. While fewer than `AvgShips` ships not attached to the player are
    /// in the system (fleets and hulks count), it draws `Rand(500)`:
    /// - 1: a pinned (negative DudeTypes) fleet when `Rand(100) + 1` is within
    ///   their summed %Prob, shown with its Quote;
    /// - 0, or a 1 whose fleet roll failed: one dude attempt.
    /// Any other draw does nothing: an attempt every ~250 calls (about 5 s),
    /// a dude ship every ~340, not at once.
    func maintainOriginal(_ world: World) {
        maintainOriginalAmbient(world)
        originalEscalationTick(world)
    }

    private func maintainOriginalAmbient(_ world: World) {
        guard originalAmbientCount(world) < table.averageShips,
              world.npcs.count < OriginalSpawnRules.npcSlots else { return }
        var draw = world.rng.range(500)
        if draw == 1 {
            let prob = table.fleets.reduce(0) { $0 + $1.prob }
            if !table.fleets.isEmpty, world.rng.range(100) + 1 <= prob,
               let fleetID = pickPinnedFleet(world) {
                originalSpawnFleet(fleetID, world: world, leadAI: nil, showQuote: true)
            } else {
                draw = 0
            }
        }
        guard draw == 0, !originalDudeWeights().filter({ $0.weight > 0 }).isEmpty else { return }
        originalDudeAttempt(world, maintenance: true)
    }

    /// Active ships the maintenance loop counts: everything in the system but
    /// the player and ships attached to the player.
    func originalAmbientCount(_ world: World) -> Int {
        world.npcs.reduce(0) { n, ship in
            n + (world.isPlayerFleetMember(ship.entityID) ? 0 : 1)
        }
    }

    /// `Dude_SpawnRandomDudeShipInSystem` 0x0041c710 (maintenance) or the
    /// initial-fill loop: a përs on `Rand(7) == 0`, else a LinkSyst fleet on
    /// `Rand(7) == 0`, else a system dude. Maintenance ships jump in (or come
    /// out of a gate); initial-fill ships are already in the system.
    func originalDudeAttempt(_ world: World, maintenance: Bool) {
        if world.rng.range(7) == 0 {
            guard let ship = originalSpawnPers(world, maintenance: maintenance, forcedID: nil) else { return }
            if maintenance {
                placeArrival(ship, world: world)
            } else {
                placeInitialFill(ship, world: world)
                world.addNPC(ship, arrival: .populate)
            }
        } else if world.rng.range(7) == 0 {
            originalLinkSystSweep(world, showQuote: maintenance)
        } else {
            guard let ship = originalSpawnSystemDude(world, anchorWarships: !maintenance) else { return }
            if maintenance {
                // A hull that carries no fuel is dropped (0x0041c710).
                guard ship.maxFuel >= 1 else { return }
                placeArrival(ship, world: world)
            } else {
                placeInitialFill(ship, world: world, keepPosition: ship.position != Vec2())
                world.addNPC(ship, arrival: .populate)
            }
        }
    }

    /// The system's dude weights, normalized as the loader stores them.
    func originalDudeWeights() -> [(dudeID: Int, weight: Int)] {
        if let cached = originalDudeWeightsCache { return cached }
        let weights = OriginalSpawnRules.normalizedDudeWeights(table.dudes)
        originalDudeWeightsCache = weights
        return weights
    }

    /// `EncounterFleet_SpawnRandomSystemDudeShip` 0x0041ba80: pick a dude
    /// from the system table, then a hull among the dude's *available* ships
    /// (unavailable hulls leave the weights before the roll). The ship flies
    /// the dude's government (independent when it has none) and AIType, or
    /// the hull's InherentAI when the dude's is unset. Returns it unplaced
    /// (at the origin) unless `anchorWarships` puts a speed-0 warship by the
    /// first stellar.
    func originalSpawnSystemDude(_ world: World, anchorWarships: Bool) -> Ship? {
        let weights = originalDudeWeights().map { ($0.dudeID, $0.weight) }
        let total = weights.reduce(0) { $0 + $1.1 }
        guard total > 0,
              let dudeID = OriginalSpawnRules.cumulativePick(weights, roll: world.rng.range(total)),
              let dude = galaxy.game.dude(dudeID) else { return nil }
        let hulls = dude.ships.filter { entry in
            guard let res = galaxy.game.ship(entry.shipID) else { return false }
            return res.appearOn.isEmpty || world.shipSpawnEligible(entry.shipID)
        }.map { ($0.shipID, $0.prob) }
        let hullTotal = hulls.reduce(0) { $0 + $1.1 }
        guard hullTotal > 0,
              let shipID = OriginalSpawnRules.cumulativePick(hulls, roll: world.rng.range(hullTotal)),
              let hull = galaxy.game.ship(shipID) else { return nil }
        let govt = dude.govt >= 128 ? dude.govt : independentGovt
        let ai = dude.aiTypeRaw >= 1 ? dude.aiType : AIType(raw: hull.inherentAI)
        let heading = Double(world.rng.range(360)) * .pi / 180
        guard let ship = galaxy.makeLoadedShip(shipID, government: govt, at: Vec2(), angle: heading,
                                               skillScale: galaxy.skillVarianceScale(classOf: shipID, rng: &world.rng),
                                               includeDefaultItems: false, defaultItemCapabilities: true) else { return nil }
        ship.dudeID = dudeID
        let brain = AIBrain(aiType: ai, govt: govt)
        // Cadence `Rand(3) XOR 2` ∈ {2, 3, 0} (0x0041bf32): a third retreat at
        // 15 %, a third never retreat, a third never pick the player up by
        // distance (AI-05, AI-20).
        brain.cadence = world.rng.range(3) ^ 2
        ship.brain = brain
        rollDudeCargo(dude, into: ship, world: world)
        world.assignBootyCredits(ship, dude: dude)          // Booty: credits + boarding cargo (EC-18)
        if anchorWarships, ai == .warship, hull.speed == 0,
           let first = world.systemContext.bodies.first {
            let bearing = Double(world.rng.range(360)) * .pi / 180
            ship.position = first.position + Vec2(sin(bearing), cos(bearing)) * OriginalSpawnRules.anchorDistance
        }
        return ship
    }

    /// Initial-fill pose: scattered over `[-750, 750)²` around the origin
    /// (unless anchored), keeping its random heading, moving at its top speed.
    func placeInitialFill(_ ship: Ship, world: World, keepPosition: Bool = false) {
        if !keepPosition {
            let span = 2 * OriginalSpawnRules.initialScatter
            ship.position = Vec2(Double(world.rng.range(span) - OriginalSpawnRules.initialScatter),
                                 Double(world.rng.range(span) - OriginalSpawnRules.initialScatter))
        }
        ship.velocity = Vec2(sin(ship.angle), cos(ship.angle)) * ship.stats.maxSpeed
        ship.throttleSpeed = ship.stats.maxSpeed
    }

    /// A maintenance arrival: out of a gate when the ship's random travel
    /// pick lands on a hypergate or wormhole (0x0046e9e0), else a jump-in
    /// from `jumpInRadius` on a random bearing, facing the origin.
    func placeArrival(_ ship: Ship, world: World) {
        if let gate = originalTravelStellar(for: ship.government, world: world).flatMap({ $0.isGate ? $0 : nil }) {
            ship.position = gate.position
            ship.angle = gate.gateEmergeAngle ?? Double(world.rng.range(360)) * .pi / 180
            world.addNPC(ship, arrival: .gate(spobID: gate.id))
            return
        }
        let bearing = Double(world.rng.range(360)) * .pi / 180
        ship.position = Vec2(sin(bearing), cos(bearing)) * OriginalSpawnRules.jumpInRadius
        ship.angle = (Vec2() - ship.position).angle
        world.addNPC(ship, arrival: .hyperspace)
    }

    /// `Stellar_SelectRandomAdjacentDestination` 0x0046e9e0 over this
    /// system's stellars for a ship of `govt`.
    func originalTravelStellar(for govt: Int, world: World) -> StellarBody? {
        let bodies = world.systemContext.bodies
        let dip = world.diplomacy
        let stellars = bodies.enumerated().map { i, body in
            OriginalSpawnRules.TravelStellar(
                index: i,
                usable: body.position.x < 1000 && -body.position.y < 1000,
                uninhabited: body.isUninhabited && !body.isGate,
                hostile: govt >= 128 && body.government >= 128 && (dip?.areEnemies(govt, body.government) ?? false),
                hypergate: body.isHypergate, wormhole: body.isWormhole)
        }
        let flags2 = govt >= 128 ? Int(galaxy.game.govt(govt)?.flags2 ?? 0) : 0
        let strict = world.rng.range(3) == 0
        let picks = OriginalSpawnRules.travelCandidates(stellars, govtFlags2: flags2, strict: strict)
        guard !picks.isEmpty else { return nil }
        return bodies[picks[world.rng.range(picks.count)]]
    }

    /// The pinned (negative DudeTypes) fleets' weighted pick (0x0046b6d0),
    /// over those that are available (AppearOn).
    func pickPinnedFleet(_ world: World) -> Int? {
        let open = table.fleets.filter { fleetAppearOnAllowed($0.fleetID, world: world) }.map { ($0.fleetID, $0.prob) }
        let total = open.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        return OriginalSpawnRules.cumulativePick(open, roll: world.rng.range(total))
    }

    /// `EncounterFleet_TrySpawnRandomEncounterFleet` 0x00425280: draws one of
    /// the 256 fleet slots at random and spawns it only if its LinkSyst band
    /// matches this system and it is available — `E / 256` per attempt.
    /// There is no filter on enemy fleets in an owned system.
    func originalLinkSystSweep(_ world: World, showQuote: Bool) {
        let fleetID = world.rng.range(256) + 128
        guard let fleet = galaxy.game.fleet(fleetID), fleet.leadShip >= 128,
              originalLinkMatches(fleet.linkSystem, world: world, persBands: false),
              fleetAppearOnAllowed(fleetID, world: world) else { return }
        originalSpawnFleet(fleetID, world: world, leadAI: nil, showQuote: showQuote)
    }

    func originalLinkMatches(_ link: Int, world: World, persBands: Bool) -> Bool {
        let dip = world.diplomacy
        return OriginalSpawnRules.linkSystMatches(
            link, systemID: table.systemID, systemGovt: table.systemGovt, persBands: persBands,
            allied: { dip?.areAllied($0, $1) ?? false },
            hostile: { dip?.areEnemies($0, $1) ?? false })
    }

    /// `EncounterFleet_SpawnRandomEncounterFleet` 0x004259b0: the lead flies
    /// its hull's InherentAI (or `leadAI`, e.g. interceptor for
    /// reinforcements) and arrives like any other ship; each escort starts
    /// within ±150 px of it on the same heading and velocity, bound to it.
    /// Fleet `Flags` 0x0001 puts `Rand(holds) + 1` tons in one random
    /// commodity of every ship whose hull InherentAI is below 3. With
    /// `showQuote` the fleet's Quote flashes for 360 frames.
    func originalSpawnFleet(_ fleetID: Int, world: World, leadAI: AIType?, showQuote: Bool) {
        guard let fleet = galaxy.game.fleet(fleetID),
              world.npcs.count < OriginalSpawnRules.npcSlots else { return }
        let govt = fleet.govt >= 128 ? fleet.govt : independentGovt
        guard let lead = galaxy.makeLoadedShip(fleet.leadShip, government: govt, at: Vec2(), angle: 0,
                                               skillScale: galaxy.skillVarianceScale(classOf: nil, rng: &world.rng),
                                               includeDefaultItems: false, defaultItemCapabilities: true) else { return }
        let hullAI = galaxy.game.ship(fleet.leadShip).map { AIType(raw: $0.inherentAI) } ?? .warship
        let leadBrain = AIBrain(aiType: leadAI ?? (hullAI == .unknown ? .warship : hullAI), govt: govt)
        leadBrain.isFleetMember = true
        leadBrain.fleetID = fleetID
        lead.brain = leadBrain
        originalFleetCargo(fleet, ship: lead, shipID: fleet.leadShip, world: world)
        placeArrival(lead, world: world)
        let leadID = lead.entityID

        var slot = 0
        for escort in fleet.escorts {
            let count = world.rng.range(escort.max - escort.min + 1) + escort.min
            for _ in 0..<max(0, count) {
                guard world.npcs.count < OriginalSpawnRules.npcSlots else { break }
                let span = 2 * OriginalSpawnRules.escortScatter
                let offset = Vec2(Double(world.rng.range(span) - OriginalSpawnRules.escortScatter),
                                  Double(world.rng.range(span) - OriginalSpawnRules.escortScatter))
                guard let e = galaxy.makeLoadedShip(escort.shipID, government: govt,
                                                    at: lead.position + offset, angle: lead.angle,
                                                    skillScale: galaxy.skillVarianceScale(classOf: nil, rng: &world.rng),
                                                    includeDefaultItems: false, defaultItemCapabilities: true) else { continue }
                let escortAI = galaxy.game.ship(escort.shipID).map { AIType(raw: $0.inherentAI) } ?? .interceptor
                let brain = AIBrain(aiType: escortAI == .unknown ? .interceptor : escortAI, govt: govt)
                brain.cadence = 2   // a class-spawned escort (0x00422400)
                brain.leaderID = leadID
                brain.formationSlot = slot
                brain.isFleetMember = true
                brain.fleetID = fleetID
                e.brain = brain
                originalFleetCargo(fleet, ship: e, shipID: escort.shipID, world: world)
                if let gateID = gateID(of: lead, world: world) {
                    e.position = lead.position
                    world.addNPC(e, arrival: .gate(spobID: gateID))
                } else {
                    world.addNPC(e, arrival: .hyperspace)
                }
                slot += 1
            }
        }
        if showQuote, fleet.hailQuote > 0,
           let strings = galaxy.game.stringList(fleet.hailQuote)?.strings, !strings.isEmpty {
            let line = strings[world.rng.range(strings.count)]
            world.postOverlayMessage(OriginalSpawnRules.fillQuote(line, rng: &world.rng), frames: 360)
        }
    }

    private func gateID(of ship: Ship, world: World) -> Int? {
        world.systemContext.bodies.first { $0.isGate && $0.position == ship.position }?.id
    }

    private func originalFleetCargo(_ fleet: FleetRes, ship: Ship, shipID: Int, world: World) {
        guard fleet.freightersHaveRandomCargo,
              let hull = galaxy.game.ship(shipID), hull.inherentAI < 3 else { return }
        let bin = world.rng.range(6)
        let tons = world.rng.range(hull.cargoSpace) + 1
        ship.cargo[bin, default: 0] += tons
    }

    /// `Pers_SpawnShipFromPersDef` 0x004235c0. Without `forcedID` it collects
    /// every përs that is alive and active (ActiveOn), has an AIType and
    /// passes its LinkSyst band (maintenance also drops derelict-government
    /// përs), then draws one of the 1022 slots at random and spawns only if
    /// that slot is among them. With `forcedID` (Person1-8) only that përs is
    /// a candidate. Either way a përs whose name (sans `;` subtitle) matches
    /// one already in the system is skipped. The ship flies the përs's own
    /// hull, government (independent when unset) and AIType.
    func originalSpawnPers(_ world: World, maintenance: Bool, forcedID: Int?) -> Ship? {
        let all = originalPerses()
        let present = Set(world.npcs.compactMap { npc in
            npc.personID.flatMap { pid in all.first { $0.id == pid } }.map { OriginalSpawnRules.persDedupName($0.name) }
        })
        func eligible(_ p: PersRes) -> Bool {
            if let forcedID { return p.id == forcedID }
            guard p.aiType > 0, p.shipType >= 128, world.persSpawnEligible(p.id),
                  originalLinkMatches(p.linkSyst, world: world, persBands: true) else { return false }
            if maintenance, p.govt >= 128, galaxy.game.govt(p.govt)?.startsDisabled == true { return false }
            return true
        }
        let candidates = all.filter { eligible($0) && !present.contains(OriginalSpawnRules.persDedupName($0.name)) }
        guard !candidates.isEmpty else { return nil }
        let id = forcedID ?? (world.rng.range(0x3fe) + 128)
        guard let pers = candidates.first(where: { $0.id == id }), pers.shipType >= 128 else { return nil }
        let govt = pers.govt >= 128 ? pers.govt : independentGovt
        let heading = Double(world.rng.range(360)) * .pi / 180
        guard let ship = galaxy.makeLoadedShip(pers.shipType, government: govt, at: Vec2(), angle: heading,
                                               skillScale: galaxy.skillVarianceScale(classOf: nil, rng: &world.rng),
                                               includeDefaultItems: false, defaultItemCapabilities: true) else { return nil }
        ship.brain = AIBrain(aiType: AIType(raw: pers.aiType), govt: govt)
        // Cadence: the përs's clamped Aggress, set in `applyPersonCustomization`.
        ship.personID = pers.id
        applyPersonCustomization(pers, to: ship, world: world)
        if govt >= 128, galaxy.game.govt(govt)?.startsDisabled == true {
            // A derelict's hulk (AI-17): no shields, a third of its armor (a
            // tenth for hull Flags 0x10) less one, adrift.
            let fraction = ship.disableArmorFraction == Ship.lowDisableFraction ? 0.1 : 0.33
            ship.armor = Double(Float(ship.maxArmor) * Float(fraction) - 1)
            ship.shield = 0
        }
        return ship
    }

    func originalPerses() -> [PersRes] {
        if let cached = originalPersCache { return cached }
        let all = galaxy.game.perses().sorted { $0.id < $1.id }
        originalPersCache = all
        return all
    }
}
