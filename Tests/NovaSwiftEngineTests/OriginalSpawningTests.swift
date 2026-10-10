import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// The original engine's population rules (FIDELITY_PLAN AI-09..AI-12, AI-17):
/// `Spawner`'s default `.original` model.
final class OriginalSpawningTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    private func ship(_ id: Int, fuel: Int = 300, cargo: Int = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 0, cargo)
        put16(&b, 6, 300)      // speed
        put16(&b, 10, fuel)
        put16(&b, 12, 40)      // free mass
        put16(&b, 14, 120)     // armor
        return Resource(type: NovaType.ship, id: id, name: "Hull\(id)", data: Data(b))
    }

    private func dude(_ id: Int, aiType: Int, govt: Int, ships: [(Int, Int)]) -> Resource {
        var b = [UInt8](repeating: 0, count: 88)
        put16(&b, 0, aiType); put16(&b, 2, govt)
        for (i, s) in ships.prefix(16).enumerated() {
            put16(&b, 8 + i * 2, s.0); put16(&b, 40 + i * 2, s.1)
        }
        return Resource(type: NovaType.dude, id: id, name: "Dude\(id)", data: Data(b))
    }

    private func fleet(_ id: Int, lead: Int, escorts: [(Int, Int, Int)] = [], govt: Int,
                       linkSyst: Int, flags: Int = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 306)
        put16(&b, 0, lead)
        for (i, e) in escorts.prefix(4).enumerated() {
            put16(&b, 2 + i * 2, e.0); put16(&b, 10 + i * 2, e.1); put16(&b, 18 + i * 2, e.2)
        }
        put16(&b, 26, govt); put16(&b, 28, linkSyst); put16(&b, 288, flags)
        return Resource(type: NovaType.fleet, id: id, name: "Fleet\(id)", data: Data(b))
    }

    private func govt(_ id: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 200)
        put16(&b, 24, 1)
        for i in 1..<4 { put16(&b, 24 + i * 2, -1) }
        for i in 0..<8 { put16(&b, 32 + i * 2, -1) }
        return Resource(type: NovaType.govt, id: id, name: "Govt\(id)", data: Data(b))
    }

    private func world(_ galaxy: Galaxy, seed: UInt32 = 7) -> World {
        let w = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        w.galaxy = galaxy
        w.diplomacy = galaxy.makeDiplomacy()
        w.rng = NovaRandom(seed: seed)
        return w
    }

    /// One trader dude flying hull 128, in an independent system.
    private func dudeOnlyGalaxy(fuel: Int = 300) -> Galaxy {
        var col = ResourceCollection()
        col.add(ship(128, fuel: fuel))
        col.add(dude(128, aiType: 1, govt: -1, ships: [(128, 100)]))
        return Galaxy(game: NovaGame(col))
    }

    // MARK: Pure rules

    func testJumpInRadiusIsTheOriginalBrakeSum() {
        // 1000 + Σ (50 − 1.165 k) over the 43 positive float speeds.
        XCTAssertEqual(OriginalSpawnRules.jumpInRadius, 2098.004, accuracy: 0.001)
        // AI-38: the player's escorts drop in Σ(45 − 1.165k) behind their slot.
        XCTAssertEqual(OriginalSpawnRules.escortJumpLag, 892, accuracy: 1)
        // 1.165 per raw call, 47.62 raw calls a second: 1.165 / 0.63 per tick.
        XCTAssertEqual(OriginalSpawnRules.arrivalBrakePerSecondSquared, 1048.5 / 0.63, accuracy: 1e-6)
    }

    func testDudeWeightsNormalizeToHundredByTruncation() {
        let w = OriginalSpawnRules.normalizedDudeWeights([(128, 50), (129, 30)])
        XCTAssertEqual(w.map(\.weight), [62, 37])      // 50 × 1.25, 30 × 1.25 truncated
        XCTAssertEqual(OriginalSpawnRules.normalizedDudeWeights([(128, 60), (129, 40)]).map(\.weight), [60, 40])
    }

    func testLinkSystBandsAndQuirks() {
        func matches(_ link: Int, system: Int = 133, govt: Int = 130, pers: Bool = false) -> Bool {
            OriginalSpawnRules.linkSystMatches(link, systemID: system, systemGovt: govt, persBands: pers,
                                               allied: { $0 == 140 && $1 == 130 },
                                               hostile: { $0 == 150 && $1 == 130 })
        }
        XCTAssertTrue(matches(-1))
        XCTAssertTrue(matches(133))                 // that system
        XCTAssertTrue(matches(5))                   // quirk: the system's 0-based index
        XCTAssertTrue(matches(10002))               // govt index 2 = 130
        XCTAssertFalse(matches(10003))
        XCTAssertTrue(matches(15012))               // allied with govt 140
        XCTAssertTrue(matches(20003))               // any but govt 131
        XCTAssertFalse(matches(20002))
        XCTAssertTrue(matches(25022))               // hostile govt 150
        // Independent systems: only the plain bands, and the përs-only 9999.
        XCTAssertFalse(matches(20003, govt: independentGovt))
        XCTAssertFalse(matches(9999, govt: independentGovt))
        XCTAssertTrue(matches(9999, govt: independentGovt, pers: true))
    }

    func testQuoteHashesBecomeDigits() {
        var rng = NovaRandom(seed: UInt32(3))
        let text = OriginalSpawnRules.fillQuote("Convoy ### inbound, # ships", rng: &rng)
        let digits = text.filter { $0.isNumber }
        XCTAssertEqual(digits.count, 4)
        XCTAssertNotEqual(text.dropFirst(7).first, "0", "the first # of a run is 1-9")
        XCTAssertFalse(text.contains("#"))
    }

    func testTravelPickPrefersGatesOnlyWhenTheGovernmentDoes() {
        let planet = OriginalSpawnRules.TravelStellar(index: 0, usable: true, uninhabited: false, hostile: false,
                                                       hypergate: false, wormhole: false)
        let gate = OriginalSpawnRules.TravelStellar(index: 1, usable: true, uninhabited: false, hostile: false,
                                                     hypergate: true, wormhole: false)
        XCTAssertEqual(OriginalSpawnRules.travelCandidates([planet, gate], govtFlags2: 0, strict: false), [0, 1])
        XCTAssertEqual(OriginalSpawnRules.travelCandidates([planet, gate], govtFlags2: 0x40, strict: false), [1])
        XCTAssertEqual(OriginalSpawnRules.travelCandidates([planet, gate], govtFlags2: 0x20, strict: false), [0])
        XCTAssertEqual(OriginalSpawnRules.travelCandidates([planet], govtFlags2: 0x40, strict: true), [0])
    }

    // MARK: Population (AI-09)

    func testInitialFillMakesExactlyAvgShipsAttempts() {
        // With no përs and no fleets, a përs (1/7) or sweep (6/49) attempt
        // spawns nothing, so the fill lands at or below AvgShips, never above.
        let galaxy = dudeOnlyGalaxy()
        var total = 0
        for seed in UInt32(1)...40 {
            let w = world(galaxy, seed: seed)
            let spawner = Spawner(galaxy: galaxy, table: SpawnTable(dudes: [(128, 100)], averageShips: 8, systemID: 500))
            spawner.populate(w)
            XCTAssertLessThanOrEqual(w.npcs.count, 8)
            total += w.npcs.count
            for npc in w.npcs {
                XCTAssertLessThan(abs(npc.position.x), 751)
                XCTAssertLessThan(abs(npc.position.y), 751)
                XCTAssertEqual(npc.velocity.length, npc.stats.maxSpeed, accuracy: 1e-6, "moving at class speed")
            }
        }
        // 8 × 36/49 ≈ 5.88 a system.
        XCTAssertEqual(Double(total) / 40, 8 * 36.0 / 49, accuracy: 0.6)
    }

    func testMaintenanceHoldsExactlyAvgShipsCountingHulks() {
        let galaxy = dudeOnlyGalaxy()
        let w = world(galaxy)
        let spawner = Spawner(galaxy: galaxy, table: SpawnTable(dudes: [(128, 100)], averageShips: 6, systemID: 500))
        for _ in 0..<20_000 { spawner.maintainOriginal(w) }
        XCTAssertEqual(w.npcs.count, 6)
        // A disabled hulk still counts toward AvgShips.
        w.npcs[0].heldDisabled = true
        for _ in 0..<5_000 { spawner.maintainOriginal(w) }
        XCTAssertEqual(w.npcs.count, 6)
    }

    func testRefillRateIsTwoInFiveHundredCallsTimesTheDudeShare() {
        // Rand(500) == 0, or == 1 with no pinned fleet, gives one attempt; of
        // those 36/49 are dude spawns. So a lost ship takes ~340 calls (7 s)
        // on average to replace, not one tick.
        let galaxy = dudeOnlyGalaxy()
        let w = world(galaxy, seed: 11)
        let spawner = Spawner(galaxy: galaxy, table: SpawnTable(dudes: [(128, 100)], averageShips: 4, systemID: 500))
        let calls = 200_000
        var spawned = 0
        for _ in 0..<calls {
            spawner.maintainOriginal(w)
            if !w.npcs.isEmpty { spawned += w.npcs.count; w.removeAllNPCs() }
        }
        let expected = Double(calls) * (2.0 / 500) * (36.0 / 49)
        XCTAssertEqual(Double(spawned), expected, accuracy: expected * 0.12)
    }

    func testFuellessHullsAreDroppedFromMaintenanceOnly() {
        let galaxy = dudeOnlyGalaxy(fuel: 0)
        let w = world(galaxy)
        let spawner = Spawner(galaxy: galaxy, table: SpawnTable(dudes: [(128, 100)], averageShips: 6, systemID: 500))
        for _ in 0..<20_000 { spawner.maintainOriginal(w) }
        XCTAssertTrue(w.npcs.isEmpty)
        spawner.populate(w)
        XCTAssertFalse(w.npcs.isEmpty, "the initial fill has no fuel check")
    }

    // MARK: Arrivals (AI-12)

    func testJumpInsStartAtTheOriginalRadiusHeadingInAt50PxPerTick() {
        let galaxy = dudeOnlyGalaxy()
        let w = world(galaxy)
        let spawner = Spawner(galaxy: galaxy, table: SpawnTable(dudes: [(128, 100)], averageShips: 1, systemID: 500))
        for _ in 0..<20_000 where w.npcs.isEmpty { spawner.maintainOriginal(w) }
        let npc = try! XCTUnwrap(w.npcs.first)
        XCTAssertEqual(npc.position.length, OriginalSpawnRules.jumpInRadius, accuracy: 1e-6)
        XCTAssertEqual(npc.velocity.length, 1500, accuracy: 1e-6)
        XCTAssertLessThan(npc.velocity.normalized.dot(npc.position.normalized), -0.999, "heading for the origin")
    }

    func testGateEmergenceOnlyWhereTheTravelPickFindsAGate() {
        let galaxy = dudeOnlyGalaxy()
        func gateShare(_ bodies: [StellarBody]) -> Double {
            let w = world(galaxy, seed: 5)
            w.systemContext.bodies = bodies
            let spawner = Spawner(galaxy: galaxy, table: SpawnTable(dudes: [(128, 100)], averageShips: 1, systemID: 500))
            var gated = 0, total = 0
            for _ in 0..<60_000 {
                spawner.maintainOriginal(w)
                guard let npc = w.npcs.first else { continue }
                total += 1
                if bodies.contains(where: { $0.isGate && $0.position == npc.position }) { gated += 1 }
                w.removeAllNPCs()
            }
            return Double(gated) / Double(max(1, total))
        }
        let planet = StellarBody(id: 128, position: Vec2(100, -100), radius: 40, canLand: true)
        let gate = StellarBody(id: 129, position: Vec2(-300, 200), radius: 40, canLand: false, isHypergate: true)
        XCTAssertEqual(gateShare([planet]), 0)
        XCTAssertEqual(gateShare([gate]), 1)
        XCTAssertEqual(gateShare([planet, gate]), 0.5, accuracy: 0.12)
    }

    func testNoPlanetLaunches() {
        let galaxy = dudeOnlyGalaxy()
        func launches() -> Int {
            let w = world(galaxy, seed: 9)
            w.systemContext.bodies = [StellarBody(id: 128, position: Vec2(0, 0), radius: 40, canLand: true)]
            let spawner = Spawner(galaxy: galaxy, table: SpawnTable(dudes: [(128, 100)], averageShips: 1, systemID: 500))
            var n = 0
            for _ in 0..<30_000 {
                spawner.maintainOriginal(w)
                for event in w.events { if case .shipLaunched = event { n += 1 } }
                w.removeAllNPCs()
                w.step(0)   // clears the event list
            }
            return n
        }
        XCTAssertEqual(launches(), 0)
    }

    // MARK: Fleets (AI-10)

    func testLinkSystSweepRateIsOneIn256PerEligibleFleet() {
        var col = ResourceCollection()
        col.add(ship(128))
        col.add(govt(128))
        col.add(fleet(128, lead: 128, govt: 128, linkSyst: -1))
        let galaxy = Galaxy(game: NovaGame(col))
        let w = world(galaxy, seed: 21)
        let spawner = Spawner(galaxy: galaxy, table: SpawnTable(averageShips: 4, systemGovt: 128, systemID: 500))
        let calls = 100_000
        var fleets = 0
        for _ in 0..<calls {
            spawner.originalLinkSystSweep(w, showQuote: false)
            if !w.npcs.isEmpty { fleets += 1; w.removeAllNPCs() }
        }
        XCTAssertEqual(Double(fleets), Double(calls) / 256, accuracy: Double(calls) / 256 * 0.15)
    }

    func testPinnedFleetsNeedTheOneInFiveHundredRoll() {
        // No dude table: only Rand(500) == 1 && Rand(100) + 1 <= Σ%Prob spawns.
        var col = ResourceCollection()
        col.add(ship(128))
        col.add(govt(128))
        col.add(fleet(130, lead: 128, govt: 128, linkSyst: 20000))
        let galaxy = Galaxy(game: NovaGame(col))
        let w = world(galaxy, seed: 4)
        let spawner = Spawner(galaxy: galaxy, table: SpawnTable(fleets: [(130, 50)], averageShips: 4,
                                                               systemGovt: 128, systemID: 500))
        let calls = 200_000
        var fleets = 0
        for _ in 0..<calls {
            spawner.maintainOriginal(w)
            if !w.npcs.isEmpty { fleets += 1; w.removeAllNPCs() }
        }
        let expected = Double(calls) / 500 * 0.5
        XCTAssertEqual(Double(fleets), expected, accuracy: expected * 0.2)
    }

    func testFleetEscortsStartWithin150PxOfTheLeadAndRandomCargoIsOneBin() {
        var col = ResourceCollection()
        col.add(ship(128, cargo: 40))
        col.add(govt(128))
        col.add(fleet(128, lead: 128, escorts: [(128, 3, 3)], govt: 128, linkSyst: -1, flags: 1))
        let galaxy = Galaxy(game: NovaGame(col))
        let w = world(galaxy)
        let spawner = Spawner(galaxy: galaxy, table: SpawnTable(averageShips: 4, systemGovt: 128, systemID: 500))
        spawner.originalSpawnFleet(128, world: w, leadAI: nil, showQuote: false)
        XCTAssertEqual(w.npcs.count, 4)
        let lead = try! XCTUnwrap(w.npcs.first { $0.brain?.leaderID == nil })
        for e in w.npcs where e !== lead {
            XCTAssertLessThanOrEqual(abs(e.position.x - lead.position.x), 150)
            XCTAssertLessThanOrEqual(abs(e.position.y - lead.position.y), 150)
            XCTAssertEqual(e.brain?.leaderID, lead.entityID)
        }
        // Hull InherentAI 0 (< 3): one random commodity, 1...holds tons.
        for s in w.npcs {
            XCTAssertEqual(s.cargo.count, 1)
            XCTAssertTrue((1...40).contains(s.cargo.values.first ?? 0))
        }
    }

    // MARK: përs (AI-11)

    func testPersSpawnsOnItsOwnHullWithItsOwnAITypeAndNoCreditJitter() {
        var col = ResourceCollection()
        col.add(ship(128)); col.add(ship(140))
        var person = [UInt8](repeating: 0, count: 400)
        put16(&person, 0, -1)       // LinkSyst: anywhere
        put16(&person, 2, -1)       // independent
        put16(&person, 4, 3)        // warship
        put16(&person, 10, 140)     // a hull no dude flies
        put16(&person, 36, 0)
        col.add(Resource(type: NovaType.pers, id: 128, name: "Captain;Subtitle", data: Data(person)))
        let galaxy = Galaxy(game: NovaGame(col))
        let w = world(galaxy, seed: 2)
        let spawner = Spawner(galaxy: galaxy, table: SpawnTable(averageShips: 4, systemID: 500))
        var spawned: Ship?
        var attempts = 0
        while spawned == nil, attempts < 20_000 {
            attempts += 1
            spawned = spawner.originalSpawnPers(w, maintenance: true, forcedID: nil)
        }
        let ship = try! XCTUnwrap(spawned)
        XCTAssertEqual(ship.shipTypeID, 140)
        XCTAssertEqual(ship.brain?.aiType, .warship)
        XCTAssertEqual(ship.government, independentGovt)
        // The slot draw is Rand(1022): one eligible përs hits about 1 in 1022.
        XCTAssertGreaterThan(attempts, 20)
        // Same-name dedup (known bug #128): once it's here it can't spawn again.
        w.addNPC(ship)
        for _ in 0..<5_000 { XCTAssertNil(spawner.originalSpawnPers(w, maintenance: true, forcedID: nil)) }
        XCTAssertNil(spawner.originalSpawnPers(w, maintenance: false, forcedID: 128))
    }

    func testPersonWeaponTriplesOverwriteDuplicates() {
        var col = ResourceCollection()
        var wb = [UInt8](repeating: 0, count: 130)
        put16(&wb, 0, 30); put16(&wb, 2, 60); put16(&wb, 8, -1); put16(&wb, 10, 100)
        col.add(Resource(type: NovaType.weapon, id: 128, name: "Blaster", data: Data(wb)))
        let galaxy = Galaxy(game: NovaGame(col))
        var b = [UInt8](repeating: 0, count: 400)
        for (i, w) in [128, 128, 0, 0].enumerated() { put16(&b, 12 + i * 2, w) }
        for (i, c) in [2, 3, 0, 0].enumerated() { put16(&b, 20 + i * 2, c) }
        let pers = PersRes(Resource(type: NovaType.pers, id: 500, name: "P", data: Data(b)))
        let s = Ship(name: "S", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        Spawner(galaxy: galaxy, table: SpawnTable()).applyPersonWeapons(pers, to: s)
        XCTAssertEqual(s.weapons.first?.count, 3, "the second triple for the same weapon replaces the first")
    }

    func testPersFlags2ZeroFuelSpawnsDry() {
        let galaxy = Galaxy(game: NovaGame(ResourceCollection()))
        var b = [UInt8](repeating: 0, count: 400)
        put16(&b, 382, 0x0001)
        let dry = PersRes(Resource(type: NovaType.pers, id: 500, name: "Dry", data: Data(b)))
        XCTAssertEqual(dry.flags2, 0x0001)
        let s = Ship(name: "S", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        s.maxFuel = 300; s.fuel = 300
        let w = world(galaxy)
        Spawner(galaxy: galaxy, table: SpawnTable()).applyPersonCustomization(dry, to: s, world: w)
        XCTAssertEqual(s.fuel, 0, "përs Flags2 0x0001 starts with no fuel (AI-11)")
    }

    // MARK: Defense fleets (AI-15)

    func testDefendersLaunchFromTheStellarAsWarshipsOnePerRawCall() {
        var col = ResourceCollection()
        col.add(ship(128)); col.add(govt(128))
        col.add(dude(300, aiType: 1, govt: 128, ships: [(128, 100)]))   // a trader dude
        var spob = [UInt8](repeating: 0, count: 600)
        put16(&spob, 10, 500); put16(&spob, 12, 5); put16(&spob, 20, 128)
        put16(&spob, 28, 300); put16(&spob, 30, 1084)                   // 8 in waves of 4
        col.add(Resource(type: NovaType.spob, id: 128, name: "World", data: Data(spob)))
        let galaxy = Galaxy(game: NovaGame(col))
        let w = world(galaxy)
        let where_ = Vec2(200, 0)
        w.systemContext = SystemContext(bodies: [StellarBody(id: 128, position: where_, radius: 40,
                                                             canLand: true, government: 128)])
        w.playerCombatRating = 1000
        _ = w.demandTribute(spobID: 128)
        for npc in w.npcs where npc.spobDefenderOf == 128 {
            XCTAssertEqual(npc.position, where_)
            XCTAssertEqual(npc.brain?.aiType, .warship, "forced to behavior 3 whatever the dude says")
            XCTAssertEqual(npc.velocity.length, npc.stats.maxSpeed, accuracy: 1e-6)
        }
        // Knock the wave out; the trickle replaces at most one per raw call.
        for npc in w.npcs { npc.armor = 0 }
        w.step(1.0 / 30.0)
        XCTAssertLessThanOrEqual(w.liveDefenders(of: 128), w.rawCallsThisStep)
    }

    // MARK: Ambush and escalation (AI-16)

    func testEscalationFleetFollowsTheEscortsHolds() {
        var col = ResourceCollection()
        col.add(ship(128, cargo: 120))
        col.add(ship(129))
        col.add(govt(128))
        col.add(fleet(382, lead: 129, govt: 128, linkSyst: -1))
        col.add(fleet(383, lead: 129, govt: 128, linkSyst: -1))
        let galaxy = Galaxy(game: NovaGame(col))
        func escalate(escorts: Int) -> Int? {
            let w = world(galaxy)
            for _ in 0..<escorts {
                let e = galaxy.makeShip(128)!
                e.brain = AIBrain(aiType: .wimpyTrader, govt: 128)
                e.brain?.leaderID = World.playerEntityID
                w.addNPC(e)
            }
            let spawner = Spawner(galaxy: galaxy, table: SpawnTable(averageShips: 0, systemID: 500))
            for _ in 0..<60 { spawner.maintainOriginal(w) }
            let lead = w.npcs.first { $0.brain?.fleetID != nil }
            if lead != nil { XCTAssertEqual(lead?.brain?.aiType, .interceptor) }
            return lead?.brain?.fleetID
        }
        XCTAssertNil(escalate(escorts: 0))
        XCTAssertEqual(escalate(escorts: 1), 382)    // 120 tons
        XCTAssertEqual(escalate(escorts: 2), 383)    // 240 tons
    }

    func testRevengePersAmbushesOneArrivalInTenAfterADomination() {
        var col = ResourceCollection()
        col.add(ship(128))
        var person = [UInt8](repeating: 0, count: 400)
        put16(&person, 0, -1); put16(&person, 2, -1); put16(&person, 4, 3); put16(&person, 10, 128)
        col.add(Resource(type: NovaType.pers, id: OriginalSpawnRules.revengePersID, name: "Revenge", data: Data(person)))
        let galaxy = Galaxy(game: NovaGame(col))
        var ambushes = 0
        let arrivals = 3000
        for seed in 1...arrivals {
            let w = world(galaxy, seed: UInt32(seed))
            w.dominatedStellars = [200]
            Spawner(galaxy: galaxy, table: SpawnTable(averageShips: 0, systemID: 500)).populate(w)
            if let s = w.npcs.first(where: { $0.personID == OriginalSpawnRules.revengePersID }) {
                ambushes += 1
                XCTAssertEqual(s.brain?.behaviorOverride, .attackPlayer)
            }
        }
        XCTAssertEqual(Double(ambushes) / Double(arrivals), 0.1, accuracy: 0.03)
    }

    // MARK: Mission ships (AI-14)

    func testMissionShipPlacement() {
        let galaxy = dudeOnlyGalaxy()
        let w = world(galaxy)
        w.systemContext = SystemContext(bodies: [
            StellarBody(id: 128, position: Vec2(400, -300), radius: 40, canLand: true),
            StellarBody(id: 129, position: Vec2(-900, 50), radius: 40, canLand: true)])
        // ShipStart −2: exactly on this system's second nav stellar.
        for id in w.spawnMissionShips(missionID: 1, dudeID: 128, count: 2, goal: .destroy,
                                      arrival: .populate, navStellarIndex: 1) {
            XCTAssertEqual(w.ship(id: id)?.position, Vec2(-900, 50))
        }
        // ShipStart 1: a jump-in at the original radius, ±256 px.
        for id in w.spawnMissionShips(missionID: 2, dudeID: 128, count: 3, goal: .destroy, arrival: .hyperspace) {
            let d = w.ship(id: id)!.position.length
            XCTAssertLessThanOrEqual(abs(d - OriginalSpawnRules.jumpInRadius), 256 * 2.0.squareRoot())
        }
        // An escort objective sits within ±256 px of the origin.
        for id in w.spawnMissionShips(missionID: 3, dudeID: 128, count: 3, goal: .escort, arrival: .populate) {
            let p = w.ship(id: id)!.position
            XCTAssertLessThanOrEqual(max(abs(p.x), abs(p.y)), 256)
        }
        // A rescue wreck: a third of its armor less one, no shields.
        for id in w.spawnMissionShips(missionID: 4, dudeID: 128, count: 1, goal: .rescue, arrival: .populate) {
            let ship = w.ship(id: id)!
            XCTAssertEqual(ship.armor, Double(Float(ship.maxArmor) * 0.33 - 1), accuracy: 1e-4)
            XCTAssertEqual(ship.shield, 0)
        }
    }

    /// AI-14: a ShipStart-1 batch waits out its rearm delay in raw calls, then
    /// jumps in from the previous system's side; auxiliary ships report their
    /// arrival; ShipStart 2 enters its cloak at once.
    func testDelayedMissionJumpInComesFromThePreviousSystemSide() {
        let galaxy = dudeOnlyGalaxy()
        let w = world(galaxy)
        w.previousSystemBearing = .pi / 2          // the previous system lies along +x
        XCTAssertEqual(w.missionRearmDelay(goal: .escort, behavior: .protectPlayer), 30)
        let delay = w.missionRearmDelay(goal: .destroy, behavior: .standard)
        XCTAssertTrue((100...199).contains(delay))
        w.scheduleMissionArrival(missionID: 5, dudeID: 128, count: 3, goal: .destroy,
                                 auxiliary: false, delayCalls: 30)
        w.scheduleMissionArrival(missionID: 6, dudeID: 128, count: 2, auxiliary: true, delayCalls: 30)
        XCTAssertTrue(w.hasPendingMissionArrival(missionID: 5))
        var calls = 0, sawAux = false
        while w.missionShips(missionID: 5).isEmpty && calls < 200 {
            w.step(1.0 / 30.0)
            calls += w.rawCallsThisStep
            if w.events.contains(where: { if case .missionAuxShipsArrived(6, 2) = $0 { return true }; return false }) {
                sawAux = true
            }
        }
        XCTAssertTrue((30...32).contains(calls), "30 maintenance ticks, counted in raw calls (\(calls))")
        XCTAssertTrue(sawAux)
        for ship in w.missionShips(missionID: 5) {
            XCTAssertGreaterThan(ship.position.x, OriginalSpawnRules.jumpInRadius - 400,
                                 "from the previous system's side, ±256 px")
            XCTAssertLessThanOrEqual(abs(ship.position.y), 300)
        }
        let cloaked = w.spawnMissionShips(missionID: 7, dudeID: 128, count: 1, arrival: .populate, startsCloaked: true)
        XCTAssertEqual(w.ship(id: cloaked[0])?.cloakEngaged, true)
    }

    /// AI-31: a scooping miner (hull Flags3 0x0002 with a scoop) heads for a
    /// box adrift (state 0x11) and scoops it into its hold.
    func testScoopingMinerCollectsAFreeflightBox() {
        var col = ResourceCollection()
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 0, 20)        // cargo
        put16(&b, 4, 200)       // accel
        put16(&b, 6, 300)       // speed
        put16(&b, 8, 30)        // turn
        put16(&b, 10, 300)      // fuel
        put16(&b, 14, 120)      // armor
        put16(&b, 66, 1)        // InherentAI
        put16(&b, 1830, 0x0002) // Flags3: scoops
        col.add(Resource(type: NovaType.ship, id: 128, name: "Miner", data: Data(b)))
        let galaxy = Galaxy(game: NovaGame(col))
        let w = world(galaxy)
        let miner = try! XCTUnwrap(galaxy.makeLoadedShip(128, at: Vec2(0, 0), includeDefaultItems: false))
        miner.brain = AIBrain(aiType: .wimpyTrader, govt: independentGovt)
        miner.hasMiningScoop = true
        miner.cargoCapacity = 20
        w.addNPC(miner)
        w.spawnFreeflightObject(at: Vec2(300, 0), cargoType: 2, spriteSet: 0)
        var sawDebris = false
        for _ in 0..<(30 * 30) {
            w.step(1.0 / 30.0)
            if w.originalAI.record(for: miner.entityID)?.state == OriginalAIState.debris { sawDebris = true }
            if miner.cargo[2] == 1 { break }
        }
        XCTAssertTrue(sawDebris, "a box adrift sends the scooper to state 0x11")
        XCTAssertEqual(miner.cargo[2], 1, "it scoops the box into its hold")
        XCTAssertTrue(w.freeflightObjects.isEmpty)
    }

    /// AI-39: a përs replaced by its mission's escort ship isn't linked to
    /// the player until the next jump (known bug #119).
    func testPersReplacementEscortLinksOnlyAtTheNextJump() {
        let galaxy = dudeOnlyGalaxy()
        do {
            let w = world(galaxy)
            let pers = Ship(name: "Pers", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
            pers.personID = 700
            pers.shipTypeID = 128
            pers.position = Vec2(321, -45)
            let pid = w.addNPC(pers)
            let id = w.replaceWithMissionShip(entityID: pid, missionID: 9, dudeID: 128, goal: .escort,
                                              behavior: .protectPlayer)
            let ship = w.ship(id: try! XCTUnwrap(id))
            XCTAssertNil(w.ship(id: pid), "the përs ship is gone")
            XCTAssertEqual(ship?.position, Vec2(321, -45))
            XCTAssertNotEqual(ship?.brain?.leaderID, World.playerEntityID)
        }
    }

    /// 0x00440aa0: released mission ships stay in the system, untagged, and a
    /// ship flying in a group leaves it for its class's default AI.
    func testReleasedMissionShipsStayWithTheirDefaultAI() {
        let w = world(dudeOnlyGalaxy())
        let ids = w.spawnMissionShips(missionID: 7, dudeID: 128, count: 2, goal: .escort, arrival: .populate)
        XCTAssertEqual(ids.count, 2)
        let escort = w.ship(id: ids[0])!
        escort.brain?.leaderID = World.playerEntityID
        escort.brain?.aiType = .warship
        XCTAssertEqual(w.releaseMissionShips(missionID: 7) { _ in .wimpyTrader }.sorted(), ids.sorted())
        XCTAssertTrue(w.missionShips(missionID: 7).isEmpty)
        XCTAssertNotNil(w.ship(id: ids[1]), "still in the system")
        XCTAssertNil(escort.brain?.leaderID)
        XCTAssertEqual(escort.brain?.aiType, .wimpyTrader)
    }
}

