import XCTest
import Foundation
import NovaSwiftKit
import NovaSwiftEngine
@testable import NovaSwiftStory

/// Batch 4 of FIDELITY_PLAN.md: the original's trade center, landing gates,
/// shipyard pricing, outfit resale, escort cap, refuelling, bribes, the bar's
/// racing bet and the tribble cadence. Expected numbers come from the plan's
/// exe readings; the shipyard rounding table was run through the original
/// function (0x0049d640) under the oracle.
final class EconomyFidelityTests: XCTestCase {

    // MARK: Builders

    private func spob(_ id: Int, govt: Int = -1, flags: UInt32 = 0x02 | 0x04 | 0x08, tech: Int = 5,
                      minStatus: Int = 0, fee: Int = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 1102)
        Bytes.i32(&b, 6, Int(Int32(bitPattern: flags)))
        Bytes.i16(&b, 12, tech)
        Bytes.i16(&b, 20, govt)
        Bytes.i16(&b, 22, minStatus)
        Bytes.i16(&b, 24, 1000)
        Bytes.i32(&b, 564, fee)
        return Resource(type: NovaType.spob, id: id, name: "Spob \(id)", data: Data(b))
    }

    private func system(_ id: Int, govt: Int, spobs: [Int]) -> Resource {
        var b = [UInt8](repeating: 0, count: 160)
        for i in 0..<16 { Bytes.i16(&b, 4 + i * 2, -1); Bytes.i16(&b, 36 + i * 2, -1) }
        for (i, s) in spobs.enumerated() { Bytes.i16(&b, 36 + i * 2, s) }
        for i in 0..<8 { Bytes.i16(&b, 68 + i * 2, -1) }
        Bytes.i16(&b, 102, govt)
        return Resource(type: NovaType.syst, id: id, name: "System \(id)", data: Data(b))
    }

    private func govt(_ id: Int, flags1: Int = 0, classes: [Int] = [], allies: [Int] = [],
                      initialRecord: Int = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 176)
        Bytes.i16(&b, 2, flags1)
        Bytes.i16(&b, 20, initialRecord)
        for i in 0..<4 {
            Bytes.i16(&b, 24 + i * 2, i < classes.count ? classes[i] : -1)
            Bytes.i16(&b, 32 + i * 2, i < allies.count ? allies[i] : -1)
            Bytes.i16(&b, 40 + i * 2, -1)
        }
        return Resource(type: NovaType.govt, id: id, name: "Govt \(id)", data: Data(b))
    }

    private func rank(_ id: Int, govt: Int, priceMod: Int, flags: Int = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 152)
        Bytes.i16(&b, 2, govt)
        Bytes.i16(&b, 4, priceMod)
        Bytes.i16(&b, 22, flags)
        return Resource(type: NovaType.rank, id: id, name: "Rank \(id)", data: Data(b))
    }

    private func junk(_ id: Int, soldAt: [Int] = [], boughtAt: [Int] = [], price: Int, flags: Int = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 676)
        for i in 0..<8 {
            Bytes.i16(&b, i * 2, i < soldAt.count ? soldAt[i] : -1)
            Bytes.i16(&b, 16 + i * 2, i < boughtAt.count ? boughtAt[i] : -1)
        }
        Bytes.i16(&b, 32, price)
        Bytes.i16(&b, 34, flags)
        return Resource(type: NovaType.junk, id: id, name: "Junk \(id)", data: Data(b))
    }

    private func oops(_ id: Int, stellar: Int, commodity: Int, delta: Int, duration: Int = 5, freq: Int = 100) -> Resource {
        var b = [UInt8](repeating: 0, count: 282)
        Bytes.i16(&b, 0, stellar)
        Bytes.i16(&b, 2, commodity)
        Bytes.i16(&b, 4, delta)
        Bytes.i16(&b, 6, duration)
        Bytes.i16(&b, 8, freq)
        return Resource(type: NovaType.oops, id: id, name: "Oops \(id)", data: Data(b))
    }

    private func pricedShip(_ id: Int, cost: Int, tech: Int, mass: Int = 50, cargo: Int = 10,
                            inherentAI: Int = 4, hireRandom: Int = 0) -> Resource {
        let r = shipResource(id: id, cargo: cargo, freeMass: 20)
        var b = [UInt8](r.data)
        Bytes.i16(&b, 46, tech)
        Bytes.i32(&b, 48, cost)
        Bytes.i16(&b, 62, mass)
        Bytes.i16(&b, 66, inherentAI)
        Bytes.i16(&b, 906, hireRandom)
        return Resource(type: NovaType.ship, id: id, name: r.name, data: Data(b))
    }

    private func flagged(_ r: Resource, outfitFlags: Int) -> Resource {
        var b = [UInt8](r.data)
        Bytes.i16(&b, 12, outfitFlags)
        return Resource(type: r.type, id: r.id, name: r.name, data: Data(b))
    }

    // MARK: EC-09 · shipyard price

    func testScaledPurchasePriceMatchesTheOriginal() {
        // (price, rank scale, item tech, stellar tech) → 0x0049d640 under the oracle.
        let table: [(Int, Float, Int, Int, Int)] = [
            (14000, 1.0, 3, 5, 13100), (14000, 1.0, 5, 3, 14000), (14000, 0.9, 1, 1, 12500),
            (14000, 0.81, 1, 1, 11300), (99, 1.0, 1, 5, 99), (100, 1.0, 1, 5, 88),
            (101, 1.0, 1, 1, 100), (105, 1.0, 1, 1, 100), (9999, 1.0, 1, 1, 9990),
            (10001, 1.0, 1, 1, 10000), (10050, 1.0, 1, 1, 10000), (99999, 1.0, 1, 1, 99900),
            (100001, 1.0, 1, 1, 100000), (123456, 1.0, 1, 1, 123000), (2500000, 0.9, 2, 5, 2047000),
            (5, 0.1, 1, 1, 1), (1, 0.5, 1, 1, 1), (0, 1.0, 1, 1, 0), (3500, 1.0, 6, 9, 3500),
            (3500, 1.0, 1, 6, 3500), (3500, 1.0, 2, 5, 3180), (12345, 1.1, 1, 1, 13500), (777, 0.9, 1, 1, 690),
        ]
        for (price, scale, item, stellar, expected) in table {
            XCTAssertEqual(LandedServices.scaledPurchasePrice(price, scale: scale, itemTech: item, stellarTech: stellar),
                           expected, "\(price) × \(scale), tech \(item) at \(stellar)")
        }
    }

    func testRankScaleIsTheProductOfAlliedRanksAndSkipsOutfits() {
        let game = makeGame([
            govt(130, classes: [1]), govt(131, classes: [2], allies: [1]), govt(132, classes: [3]),
            rank(200, govt: 130, priceMod: 90), rank(201, govt: 131, priceMod: 90), rank(202, govt: 132, priceMod: 50),
            pricedShip(128, cost: 14000, tech: 1),
            outfitResource(id: 300, name: "Gun", mass: 1, cost: 1000),
        ])
        var state = PlayerState(credits: 100_000)
        state.activeRanks = [200, 201, 202]
        let diplomacy = Galaxy(game: game).makeDiplomacy()
        let scale = LandedServices.rankPriceScale(state, stellarGovt: 130, game: game, diplomacy: diplomacy)
        XCTAssertEqual(scale, Float(0.81), accuracy: 1e-6, "two allied 0.9 ranks multiply; the unallied one is ignored")
        XCTAssertEqual(LandedServices.shipPrice(game.ship(128)!, scale: scale, stellarTech: 1), 11300)
        XCTAssertEqual(LandedServices.rankPriceScale(state, stellarGovt: -1, game: game, diplomacy: diplomacy), 1)
        XCTAssertEqual(PilotEconomy.effectiveCost(state, game.outfit(300)!, galaxy: Galaxy(game: game)), 1000,
                       "rank PriceMod never reaches outfits")
    }

    func testTradeInIsAQuarterOfTheHullAndHalfTheNonPersistentOutfits() {
        let game = makeGame([
            pricedShip(128, cost: 10000, tech: 1),
            outfitResource(id: 300, name: "Gun", mass: 1, cost: 1000),
            flagged(outfitResource(id: 301, name: "Permit", cost: 50000), outfitFlags: 0x0004),
        ])
        var state = PlayerState(credits: 0)
        state.outfits = [300: 3, 301: 1]
        XCTAssertEqual(LandedServices.rawTradeInValue(state, game: game), 2500 + 1500,
                       "the permit stays with the pilot, so it isn't credited")
        XCTAssertEqual(PilotEconomy.tradeInValue(state, game: game), 4000)
    }

    func testHirePriceIsATenthOfTheScaledPrice() {
        let game = makeGame([pricedShip(128, cost: 14000, tech: 3)])
        XCTAssertEqual(PilotEconomy.escortHirePrice(game.ship(128)!, scale: 1, stellarTech: 5), 1310)
    }

    // MARK: EC-03 · trade center

    private func tradeGame(extra: [Resource] = []) -> NovaGame {
        var strings: [UInt8] = [0, 6]
        for s in ["75", "350", "750", "900", "200", "550"] { strings.append(UInt8(s.utf8.count)); strings += Array(s.utf8) }
        // Medical (index 2) Low at 130, High at 131; flags: exchange + nibbles.
        let medicalLow: UInt32 = 0x02 | (1 << 20)
        let medicalHigh: UInt32 = 0x02 | (4 << 20)
        return makeGame([
            Resource(type: NovaType.strList, id: 4004, data: Data(strings)),
            govt(140), system(128, govt: 140, spobs: [130, 131]),
            spob(130, govt: 140, flags: medicalLow), spob(131, govt: 140, flags: medicalHigh),
        ] + extra)
    }

    func testCommodityScaleFollowsReputationAndDomination() {
        let game = tradeGame()
        var state = PlayerState(credits: 0)
        state.systemReputation = [128: -10]
        let low = LandedServices.tradeRows(at: game.spob(130)!, state: state, game: game)
        XCTAssertEqual(low.first { $0.cargoID == 2 }?.price, 681, "trunc(750 / 1.1) with a negative record")
        state.dominate(131)
        let high = LandedServices.tradeRows(at: game.spob(131)!, state: state, game: game)
        XCTAssertEqual(high.first { $0.cargoID == 2 }?.price, 1125, "dominated: trunc(750 × 1.5)")
        state.systemReputation = [128: 10]
        let normal = LandedServices.tradeRows(at: game.spob(130)!, state: state, game: game)
        XCTAssertEqual(normal.first { $0.cargoID == 2 }?.price, 600)
    }

    func testJunkRowsTakeTheHighestQualifyingJunkEachWay() {
        let game = tradeGame(extra: [
            junk(400, boughtAt: [130], price: 100), junk(401, boughtAt: [130], price: 200),
            junk(402, soldAt: [130], price: 300), junk(403, soldAt: [999], price: 400),
        ])
        let rows = LandedServices.tradeRows(at: game.spob(130)!, state: PlayerState(), game: game)
        let junkRows = rows.filter { $0.cargoID >= 128 }
        XCTAssertEqual(junkRows.map(\.cargoID), [401, 402])
        XCTAssertEqual(junkRows.map(\.price), [250, 240], "BoughtAt × 1.25, SoldAt / 1.25, unfloored")
    }

    func testAnActiveDisasterReplacesThePrice() {
        let game = tradeGame(extra: [oops(500, stellar: 131, commodity: 2, delta: -800)])
        var state = PlayerState()
        state.activeDisasters = [500: state.date.adding(days: 3)]
        let rows = LandedServices.tradeRows(at: game.spob(131)!, state: state, game: game)
        XCTAssertEqual(rows.first { $0.cargoID == 2 }?.price, 5, "base + delta, floored at 5; the High tier is ignored")
        XCTAssertEqual(LandedServices.tradeRows(at: game.spob(130)!, state: state, game: game)
                        .first { $0.cargoID == 2 }?.price, 600, "only the named stellar")
    }

    func testRandomStellarDisasterPicksOneStellar() {
        let game = tradeGame(extra: [oops(500, stellar: -1, commodity: 2, delta: 100)])
        let engine = StoryEngine(game: game, player: PlayerState())
        engine.evaluateDisasters()
        guard let picked = engine.player.disasterStellars?[500] else { return XCTFail("no stellar picked") }
        XCTAssertTrue([130, 131].contains(picked))
        let other = picked == 130 ? 131 : 130
        let hit = LandedServices.tradeRows(at: game.spob(picked)!, state: engine.player, game: game)
        let missed = LandedServices.tradeRows(at: game.spob(other)!, state: engine.player, game: game)
        XCTAssertEqual(hit.first { $0.cargoID == 2 }?.price, 850)
        XCTAssertNotEqual(missed.first { $0.cargoID == 2 }?.price, 850)
    }

    // MARK: AI-13 / AI-15 · system defenses on the daily tick

    func testDailyTickCountsDownReinforcementDaysAndRegrowsDominatedGarrisons() {
        var b = [UInt8](repeating: 0, count: 1102)
        Bytes.i16(&b, 28, 300)    // DefenseDude
        Bytes.i16(&b, 30, 10)     // DefCount: 10 at once
        var col = ResourceCollection()
        col.add(Resource(type: NovaType.spob, id: 140, name: "Fort", data: Data(b)))
        let game = NovaGame(col)
        var state = PlayerState()
        state.reinforcementRetriggerDays = [500: 2]
        state.stellarGarrisons = [140: 3]
        state.dominate(140)
        let engine = StoryEngine(game: game, player: state)
        engine.tickSystemDefenses()
        XCTAssertEqual(engine.player.reinforcementRetriggerDays?[500], 1)
        engine.tickSystemDefenses()
        XCTAssertNil(engine.player.reinforcementRetriggerDays, "spent delays drop out")
        for _ in 0..<20_000 { engine.tickSystemDefenses() }
        XCTAssertEqual(engine.player.stellarGarrisons?[140], 10, "1 in 450 a day, up to DefCount")
    }

    // MARK: EC-04 / EC-05 · landing

    func testLandingClearanceFollowsTheOriginalOrder() {
        let game = makeGame([
            govt(140), system(128, govt: 140, spobs: [130, 131, 132, 133]),
            spob(130, govt: 140, minStatus: 32767), spob(131, govt: 140, minStatus: 50),
            spob(132, govt: 140, minStatus: -32767, fee: 50), spob(133, govt: 140, minStatus: 0),
            rank(200, govt: 140, priceMod: 100, flags: 0x0200),
        ])
        func clearance(_ id: Int, _ state: PlayerState) -> LandedServices.LandingClearance {
            LandedServices.landingClearance(spob: game.spob(id)!, system: 128, state: state, game: game,
                                            diplomacy: nil, contributedBits: 0)
        }
        var state = PlayerState(credits: 10)
        XCTAssertEqual(clearance(130, state), .denied, "MinStatus 32767 is never landable")
        XCTAssertEqual(clearance(131, state), .denied)
        XCTAssertEqual(clearance(132, state), .cannotPayFee(50))
        XCTAssertEqual(clearance(133, state), .granted)
        state.systemReputation = [128: -1]
        XCTAssertEqual(clearance(133, state), .denied)
        let mission = ActiveMission(missionID: 128, acceptedDate: state.date, deadline: nil,
                                    cargoPickedUp: false, shipObjectivesRemaining: 0, travelSpobID: 133)
        state.activeMissions = [mission]
        XCTAssertEqual(clearance(133, state), .granted, "an active mission's destination is landable")
        state.activeMissions = []
        state.activeRanks = [200]
        XCTAssertEqual(clearance(130, state), .granted, "AlwaysLand")
        state.activeRanks = []
        state.dominate(132)
        XCTAssertEqual(clearance(132, state), .granted, "a dominated stellar waives the fee")
        XCTAssertEqual(LandedServices.landingFee(spob: game.spob(132)!, state: state), 0)
        XCTAssertEqual(LandedServices.landingFee(spob: game.spob(132)!, state: PlayerState()), 50)
    }

    // MARK: EC-23 · refuel

    func testRefuelIsOneCreditAUnitAndPartial() {
        let paid = LandedServices.refuel(fuel: 200.7, capacity: 300, credits: 30, dominated: false, uninhabited: false)
        XCTAssertEqual(paid?.fuel, 230)
        XCTAssertEqual(paid?.cost, 30)
        let free = LandedServices.refuel(fuel: 200.7, capacity: 300, credits: 0, dominated: true, uninhabited: false)
        XCTAssertEqual(free?.fuel, 300)
        XCTAssertEqual(free?.cost, 0)
        XCTAssertNil(LandedServices.refuel(fuel: 0, capacity: 300, credits: 999, dominated: false, uninhabited: true))
    }

    // MARK: EC-07 / EC-13 / EC-14 · outfits

    func testOutfitResaleIsHalfExceptThisVisitsPurchases() {
        let game = makeGame([shipResource(id: 128, cargo: 10, freeMass: 20),
                             outfitResource(id: 300, name: "Gun", mass: 1, cost: 1001)])
        let galaxy = Galaxy(game: game)
        let gun = game.outfit(300)!
        var state = PlayerState(credits: 10_000)
        state.outfits = [300: 1]
        let atOpen = state.outfits[300]
        XCTAssertTrue(PilotEconomy.buyOutfit(&state, gun, galaxy: galaxy))
        XCTAssertEqual(state.credits, 8999)
        XCTAssertTrue(PilotEconomy.sellOutfit(&state, gun, galaxy: galaxy, ownedAtOpen: atOpen))
        XCTAssertEqual(state.credits, 10_000, "the unit bought this visit refunds in full")
        XCTAssertTrue(PilotEconomy.sellOutfit(&state, gun, galaxy: galaxy, ownedAtOpen: atOpen))
        XCTAssertEqual(state.credits, 10_500, "an older unit sells for trunc(1001 × 0.5)")
        let unsellable = flagged(outfitResource(id: 301, name: "Licence", cost: 10), outfitFlags: 0x0008)
        state.outfits = [301: 1]
        XCTAssertFalse(PilotEconomy.canSellOutfit(state, OutfRes(unsellable)))
    }

    func testAmmoNeedsALauncher() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10, freeMass: 50),
            { () -> Resource in
                var b = [UInt8](weaponResource(id: 400, name: "Launcher").data)
                Bytes.i16(&b, 108, 4)                       // MaxAmmo
                return Resource(type: NovaType.weapon, id: 400, name: "Launcher", data: Data(b))
            }(),
            outfitResource(id: 300, name: "Launcher", mass: 1, cost: 10, installsWeapon: 400),
            outfitResource(id: 301, name: "Missile", cost: 1, ammoFor: 400),
        ])
        let galaxy = Galaxy(game: game)
        var state = PlayerState(credits: 10_000)
        XCTAssertFalse(PilotEconomy.canBuyOutfit(state, game.outfit(301)!, galaxy: galaxy), "no launcher, no ammo")
        state.outfits = [300: 2]
        XCTAssertEqual(PilotEconomy.buyOutfit(&state, game.outfit(301)!, count: 20, galaxy: galaxy), 8,
                       "MaxAmmo 4 × 2 launchers")
    }

    func testMassAndPriceScaledOutfitsHaveFloors() {
        var b = [UInt8](outfitResource(id: 300, name: "Armor", mass: 10, cost: 100).data)
        Bytes.i16(&b, 12, 0x0400 | 0x0200)
        let o = OutfRes(Resource(type: NovaType.outfit, id: 300, name: "Armor", data: Data(b)))
        XCTAssertEqual(o.effectiveMass(shipMass: 50), 10, "a 50 t hull pays the base mass, not half")
        XCTAssertEqual(o.effectiveMass(shipMass: 300), 30)
        XCTAssertEqual(o.effectiveCost(shipMass: 0), 100, "never below the base cost")
        XCTAssertEqual(o.effectiveCost(shipMass: 3), 300)
    }

    // MARK: EC-11 / EC-19 · stock and escorts

    func testDailyStockRollIsSharedByEveryPort() {
        let game = makeGame([spob(130), spob(131)] + (0..<40).map { i -> Resource in
            var b = [UInt8](outfitResource(id: 300 + i, name: "O\(i)", cost: 10).data)
            Bytes.i16(&b, 1008, 50)   // BuyRandom
            Bytes.i16(&b, 4, 1)       // TechLevel
            return Resource(type: NovaType.outfit, id: 300 + i, name: "O\(i)", data: Data(b))
        })
        for day in 0..<5 {
            let a = game.outfitsSold(at: game.spob(130)!, day: day).map(\.id)
            let b = game.outfitsSold(at: game.spob(131)!, day: day).map(\.id)
            XCTAssertEqual(a, b, "day \(day)")
            XCTAssertTrue(a.count > 0 && a.count < 40)
        }
        let owned = game.outfitsSold(at: game.spob(130)!, day: 1, owned: Set(300..<340)).count
        XCTAssertEqual(owned, 40, "owned items skip the roll")
    }

    func testEscortCapCountsSixNonMissionEscorts() {
        var state = PlayerState(credits: 0)
        for i in 0..<6 { state.registerEscort(shipType: 128, name: "E\(i)", origin: .hired, hireFee: 0, dailyFee: 0) }
        XCTAssertFalse(PilotEconomy.canAddEscort(state), "a 7th hire is refused")
        var withMission = PlayerState(credits: 0)
        for i in 0..<5 { withMission.registerEscort(shipType: 128, name: "E\(i)", origin: .hired, hireFee: 0, dailyFee: 0) }
        withMission.registerEscort(shipType: 128, name: "M", origin: .hired, hireFee: 0, dailyFee: 0, missionID: 900)
        XCTAssertTrue(PilotEconomy.canAddEscort(withMission), "mission escorts don't count")
    }

    func testHiringRedrawsTheClassForTheDay() {
        let game = makeGame([pricedShip(128, cost: 1000, tech: 1, hireRandom: 50)])
        let ship = game.ship(128)!
        // Find a day the class is on offer, hire it, and check the redraw is
        // what decides the rest of that day.
        guard let day = (0..<200).first(where: { NovaGame.hireable(ship, day: $0) }) else { return XCTFail() }
        var state = PlayerState(credits: 10_000)
        XCTAssertTrue(PilotEconomy.hireEscort(&state, ship, day: day))
        XCTAssertEqual(state.credits, 10_000 - 100)
        XCTAssertEqual(PilotEconomy.escortAvailableToday(state, ship, day: day),
                       NovaGame.hireable(ship, day: day, redraw: 1))
    }

    // MARK: EC-10 · crime revokes ranks

    /// 0x00466fc0: a crime against an allied government revokes its
    /// non-permanent ranks with Flags 0x0040, and those with 0x0004 only for a
    /// disable or a kill; a permanent rank and an unrelated government's stay.
    func testCrimeRevokesCrimeSensitiveAlliedRanks() {
        let game = makeGame([govtResource(id: 128, classes: [1], allies: [2]),
                             govtResource(id: 129, classes: [2]),
                             govtResource(id: 130, classes: [3]),
                             ownedSystemResource(id: 128, govt: 128),
                             rankResource(id: 200, govt: 129, flags: 0x0040),
                             rankResource(id: 201, govt: 129, flags: 0x0004),
                             rankResource(id: 202, govt: 129, flags: 0x0040 | 0x0008),
                             rankResource(id: 203, govt: 130, flags: 0x0040),
                             rankResource(id: 204, govt: 128, flags: 0x0004)])
        var state = PlayerState(shipType: 128, currentSystem: 128)
        state.activeRanks = [200, 201, 202, 203, 204]
        XCTAssertEqual(state.revokeRanks(forCrime: .board, against: 128, game: game), [200])
        XCTAssertEqual(state.activeRanks, [201, 202, 203, 204])
        XCTAssertEqual(state.revokeRanks(forCrime: .kill, against: 128, game: game, missionShip: true), [],
                       "a mission ship's victim changes nothing")
        XCTAssertEqual(state.revokeRanks(forCrime: .kill, against: 128, game: game), [201, 204])
        XCTAssertEqual(state.activeRanks, [202, 203])
    }

    // MARK: EC-21 · fleet cargo

    func testFreighterEscortsPoolCargo() {
        let game = makeGame([pricedShip(128, cost: 1, tech: 1, cargo: 10),
                             pricedShip(129, cost: 1, tech: 1, cargo: 50, inherentAI: 1),
                             pricedShip(130, cost: 1, tech: 1, cargo: 70, inherentAI: 4)])
        var state = PlayerState(shipType: 128)
        state.registerEscort(shipType: 129, name: "Freighter", origin: .hired, hireFee: 0, dailyFee: 0)
        state.registerEscort(shipType: 130, name: "Warship", origin: .hired, hireFee: 0, dailyFee: 0)
        XCTAssertEqual(PilotEconomy.cargoCapacity(state, galaxy: Galaxy(game: game)), 60)
    }

    /// A departing freighter takes `trunc(tons × holds / fleet)` of each
    /// non-mission stack (0x00469810); mission cargo stays.
    func testDepartingFreighterTakesItsShareOfTheCargo() {
        let game = makeGame([pricedShip(128, cost: 1, tech: 1, cargo: 50),
                             pricedShip(129, cost: 1, tech: 1, cargo: 30, inherentAI: 1),
                             pricedShip(130, cost: 1, tech: 1, cargo: 20, inherentAI: 2)])
        var state = PlayerState(shipType: 128)
        state.registerEscort(shipType: 129, name: "A", origin: .hired)
        state.registerEscort(shipType: 130, name: "B", origin: .hired)
        state.cargo = [0: 45, 3: 9, 1001: 3]
        // Fleet 50 + 30 + 20 = 100; the 30 t freighter leaves: ratio 0.3.
        PilotEconomy.transferCargoToEscort(&state, recipientHolds: 30, missionCargo: [3: 4],
                                          galaxy: Galaxy(game: game))
        XCTAssertEqual(state.cargo[0], 45 - 13)
        XCTAssertEqual(state.cargo[3], 4 + (5 - 1), "mission tons are untouched")
        XCTAssertEqual(state.cargo[1001], 3, "trunc(3 × 0.3) = 0")
    }

    /// An unpaid freighter defects with its share of the hold, and one dialog
    /// (STR# 2002 #302) says so.
    func testDefectingFreighterTakesCargo() {
        var strs = [String](repeating: "", count: 303)
        strs[301] = "Due to lack of pay, one of your escorts has defected."
        let game = makeGame([pricedShip(128, cost: 1, tech: 1, cargo: 50),
                             pricedShip(129, cost: 1000, tech: 1, cargo: 50, inherentAI: 1),
                             stringListResource(2002, strs)])
        var state = PlayerState(shipType: 128)
        state.credits = 5
        state.registerEscort(shipType: 129, name: "Hauler", origin: .hired, dailyFee: 10)
        state.cargo = [2: 40]
        let svc = LoggingGameServices()
        let eng = StoryEngine(game: game, player: state, services: svc)
        XCTAssertEqual(eng.processEscortPayroll(periods: 1), 1)
        XCTAssertEqual(eng.player.cargo[2], 20)
        XCTAssertTrue(eng.player.escortWing.isEmpty)
        XCTAssertTrue(svc.log.contains { $0.contains("has defected") })
    }

    // MARK: EC-22 · escort sale and upgrade marks

    private func upgradable(_ r: Resource, to target: Int, cost: Int, sell: Int = 0) -> Resource {
        var b = [UInt8](r.data)
        Bytes.i16(&b, 1832, target)
        Bytes.i32(&b, 1834, cost)
        Bytes.i32(&b, 1838, sell)
        return Resource(type: r.type, id: r.id, name: r.name, data: Data(b))
    }

    /// Sale and upgrade are exclusive marks processed when leaving a shipyard
    /// stellar (0x004229d0): sales first, then affordable upgrades; an
    /// unaffordable upgrade stays marked; two transactions cost one day.
    func testEscortMarksAreProcessedAtAShipyard() {
        var strs = [String](repeating: "", count: 301)
        strs[31] = "credit"; strs[32] = "credits"
        strs[297] = "escort was"; strs[298] = "escorts were"
        strs[299] = "sold for a profit of"; strs[300] = "upgraded at a cost of"
        let game = makeGame([pricedShip(128, cost: 1, tech: 1),
                             upgradable(pricedShip(129, cost: 20_000, tech: 1), to: 130, cost: 5_000),
                             pricedShip(130, cost: 90_000, tech: 1),
                             upgradable(pricedShip(131, cost: 1, tech: 1), to: 130, cost: 1_000_000),
                             spob(200, flags: 0x02 | 0x08), spob(201, flags: 0x02),
                             stringListResource(2002, strs),
                             stringListResource(137, (1...38).map { $0 >= 29 ? ["one", "two"][min($0 - 29, 1)] : "" })])
        var state = PlayerState(shipType: 128)
        state.credits = 3_000
        let a = state.registerEscort(shipType: 129, name: "A", origin: .captured)
        let b = state.registerEscort(shipType: 129, name: "B", origin: .captured)
        let c = state.registerEscort(shipType: 131, name: "C", origin: .captured)
        let h = state.registerEscort(shipType: 129, name: "H", origin: .hired)
        XCTAssertFalse(PilotEconomy.requestEscortSale(&state, recordID: h.id), "hired escorts can't be sold")
        XCTAssertNotNil(PilotEconomy.requestEscortUpgrade(&state, recordID: a.id, game: game))
        XCTAssertTrue(PilotEconomy.requestEscortSale(&state, recordID: a.id))
        XCTAssertNil(state.escort(id: a.id)?.pendingUpgradeTo, "a sale mark clears the upgrade mark")
        XCTAssertNotNil(PilotEconomy.requestEscortUpgrade(&state, recordID: b.id, game: game))
        XCTAssertNotNil(PilotEconomy.requestEscortUpgrade(&state, recordID: c.id, game: game))

        XCTAssertEqual(PilotEconomy.processEscortFleetAtStellar(&state, spob: game.spob(201)!, game: game),
                       PilotEconomy.EscortFleetPass(), "no shipyard, nothing happens")
        let pass = PilotEconomy.processEscortFleetAtStellar(&state, spob: game.spob(200)!, game: game)
        XCTAssertEqual(pass.soldIDs, [a.id])
        XCTAssertEqual(pass.saleCredits, 2_000, "EscSellValue 0 → 10 % of cost")
        XCTAssertEqual(pass.upgradedIDs, [b.id], "the sale pays for B's upgrade")
        XCTAssertEqual(state.credits, 3_000 + 2_000 - 5_000)
        XCTAssertEqual(state.escort(id: b.id)?.shipType, 130)
        XCTAssertNotNil(state.escort(id: c.id)?.pendingUpgradeTo, "unaffordable: stays marked")
        var days = SpaceportVisitDays()
        days.escortsSoldOrUpgraded = pass.transactions
        XCTAssertEqual(days.departureDays, 2)
        XCTAssertEqual(PilotEconomy.escortFleetPassText(pass, game: game),
                       "One escort was sold for a profit of 2,000 credits.\n\nOne escort was upgraded at a cost of 5,000 credits.")
    }

    // MARK: EC-24 · tribbles

    func testTribblesBreedOnTheFrameCadenceAndPerishablesNeedThem() {
        let game = makeGame([shipResource(id: 128, cargo: 20, freeMass: 0),
                             junk(400, price: 10, flags: 0x1), junk(401, price: 10, flags: 0x2)])
        let galaxy = Galaxy(game: game)
        var state = PlayerState(shipType: 128)
        state.cargo = [400: 5]
        var events = 0
        for frame in 1...1025 where PilotEconomy.junkCargoEventDue(frame: frame) {
            events += 1
            PilotEconomy.runJunkCargoEvent(&state, galaxy: galaxy)
        }
        XCTAssertEqual(events, 5)
        XCTAssertEqual(state.cargo[400], 10, "+1 t per event")
        state.cargo = [401: 5]
        PilotEconomy.runJunkCargoEvent(&state, galaxy: galaxy)
        XCTAssertEqual(state.cargo[401], 5, "with no tribble aboard a perishable never rots (user ruling)")
        state.cargo = [400: 1, 401: 5]
        PilotEconomy.runJunkCargoEvent(&state, galaxy: galaxy)
        XCTAssertEqual(state.cargo, [400: 2, 401: 4])
        state.cargo = [400: 15, 401: 5]
        PilotEconomy.runJunkCargoEvent(&state, galaxy: galaxy)
        XCTAssertEqual(state.cargo, [400: 15, 401: 5], "a full hold stops both")
    }

    // MARK: EC-25 / EC-26

    func testPlanetaryBribeFormula() {
        let lowest = LandedServices.planetaryBribeCost(credits: 2_000_000, govtFlags: 0) { _ in 0 }
        let highest = LandedServices.planetaryBribeCost(credits: 2_000_000, govtFlags: 0) { $0 - 1 }
        XCTAssertEqual([lowest, highest], [3000, 4000])
        XCTAssertEqual(LandedServices.planetaryBribeCost(credits: 2_000_000, govtFlags: 0x8000) { _ in 0 }, 4000,
                       "× 1.5 = 4500, floored to 4000")
        XCTAssertEqual(LandedServices.planetaryBribeCost(credits: 2_000, govtFlags: 0) { _ in 0 }, 1000,
                       "capped at a third of the credits, then clamped up to 1000")
        XCTAssertEqual(LandedServices.planetaryBribeCost(credits: 2_000_000_000, govtFlags: 0) { $0 - 1 }, 900_000)
    }

    func testRaceBetQuirkAndPayout() {
        var bet = LandedServices.RaceBet()
        var rolls = [2]
        let first = bet.race(pick: 2, wager: 1000) { _ in rolls.removeFirst() }
        XCTAssertEqual(first.winner, 2)
        XCTAssertEqual(first.payout, 4000, "a win pays four times the wager")
        // The first roll repeats last race's winner: the re-roll can match
        // neither it nor the pick, so the bet is lost.
        rolls = [2, 2, 1, 3]
        let second = bet.race(pick: 1, wager: 1000) { _ in rolls.removeFirst() }
        XCTAssertEqual(second.winner, 3)
        XCTAssertEqual(second.payout, 0)
        XCTAssertEqual(LandedServices.RaceBet.standardWager(credits: 400), 400)
        XCTAssertEqual(LandedServices.RaceBet.maxPromptedWager(credits: 50_000), 10_000)
    }

    // MARK: UI-09 / EC-25 · stellar comm window

    private func commGame() -> NovaGame {
        func list(_ id: Int, _ strings: [String]) -> Resource {
            var b: [UInt8] = [UInt8(strings.count >> 8), UInt8(strings.count & 0xff)]
            for s in strings { b.append(UInt8(s.utf8.count)); b += Array(s.utf8) }
            return Resource(type: NovaType.strList, id: id, data: Data(b))
        }
        let s3002 = (1...50).map { "s3002-\($0)" }
        let s3000 = (1...50).map { "s3000-\($0)" }
        return makeGame([
            list(3002, s3002), list(3000, s3000),
            govt(140, flags1: 0x4000), govt(141, flags1: 0x8000), system(128, govt: 140, spobs: [130, 131, 132]),
            spob(130, govt: 140, minStatus: 50), spob(131, govt: 141, minStatus: 0),
            spob(132, govt: 140, flags: 0x20),
        ])
    }

    func testStellarCommOpensOnlyForInhabitedWorlds() {
        let game = commGame()
        var latch = -1
        XCTAssertNil(StellarComm.open(spob: game.spob(132)!, system: 128, state: PlayerState(), game: game,
                                      diplomacy: nil, bribeLatch: &latch, rand: { _ in 0 }),
                     "an uninhabited stellar answers only \"No response.\"")
        XCTAssertEqual(latch, -1)
        let comm = StellarComm.open(spob: game.spob(131)!, system: 128, state: PlayerState(), game: game,
                                    diplomacy: nil, bribeLatch: &latch, rand: { _ in 0 })!
        XCTAssertFalse(comm.denied)
        XCTAssertEqual(comm.openingText(spob: game.spob(131)!, state: PlayerState(), game: game), "s3002-1Spob 131.")
        XCTAssertEqual(comm.greetings(spob: game.spob(131)!, state: PlayerState(), game: game), .reply("s3000-46"))
    }

    func testPlanetaryBribeNeedsTheLatchAndEndsOnRefusal() {
        let game = commGame()
        let spob = game.spob(130)!
        var state = PlayerState(credits: 2_000_000)
        var latch = -1
        var comm = StellarComm.open(spob: spob, system: 128, state: state, game: game, diplomacy: nil,
                                    bribeLatch: &latch, rand: { $0 == 100 ? 31 : 0 })!
        XCTAssertTrue(comm.denied, "a record of 0 is under MinStatus 50")
        XCTAssertEqual(latch, 31)
        XCTAssertTrue(comm.bribable, "latch > 30 and the government takes bribes (0x4000)")
        XCTAssertEqual(comm.status(spob: spob, system: 128, state: state, game: game)?.hostile, false,
                       "Forbidden, not Hostile, at a reputation of 0")
        guard case let .offerBribe(_, price) = comm.greetings(spob: spob, state: state, game: game) else {
            return XCTFail("expected a bribe offer")
        }
        XCTAssertEqual(price, 3000)
        XCTAssertEqual(comm.settleBribe(paid: false, price: price, spob: spob, state: &state, game: game, bribeLatch: &latch),
                       .refused("s3002-31"))
        XCTAssertEqual(latch, 0, "no further bribe until the next jump")
        XCTAssertEqual(comm.bribePrice, 4000)
        let again = StellarComm.open(spob: spob, system: 128, state: state, game: game, diplomacy: nil,
                                     bribeLatch: &latch, rand: { _ in 0 })!
        XCTAssertFalse(again.bribable)
        XCTAssertEqual(again.greetings(spob: spob, state: state, game: game), .reply("s3002-46"))
    }

    func testPaymentWindowHaggle() {
        var window = PaymentWindow(price: 8000) { _ in 35 }
        XCTAssertTrue(window.haggleWorks)
        XCTAssertEqual(window.press(.haggle), .open)
        XCTAssertEqual(window.price, 6000)
        XCTAssertEqual(window.press(.haggle), .refused, "a second haggle ends the deal")
        var stubborn = PaymentWindow(price: 8000) { _ in 36 }
        XCTAssertEqual(stubborn.press(.haggle), .refused)
        var odd = PaymentWindow(price: 4321) { _ in 0 }
        XCTAssertEqual(odd.press(.haggle), .open)
        XCTAssertEqual(odd.price, 3200, "trunc(4321 × 0.75) = 3240, rounded down to the hundred")
    }

    // MARK: EC-17 / EC-18 · capture and boarding

    func testTakingCommandOfAPrizeKeepsOnlyPersistentOutfits() {
        let game = makeGame([
            shipResource(id: 128, cargo: 10, freeMass: 20),
            shipResource(id: 129, cargo: 10, freeMass: 20, defaultItems: [(id: 302, count: 1)]),
            outfitResource(id: 300, name: "Gun", mass: 1, cost: 10),
            flagged(outfitResource(id: 301, name: "Permit", cost: 10), outfitFlags: 0x0004),
            outfitResource(id: 302, name: "Booster", cost: 10),
        ])
        var state = PlayerState(shipType: 128)
        state.outfits = [300: 2, 301: 1]
        XCTAssertTrue(PilotEconomy.takeCommandOfCapturedHull(&state, hull: 129, game: game))
        XCTAssertEqual(state.outfits, [301: 1, 302: 1], "the new hull's defaults plus persistent items")
        XCTAssertEqual(state.escortWing.map(\.shipType), [128])
        for i in 0..<6 { state.registerEscort(shipType: 128, name: "E\(i)", origin: .hired) }
        XCTAssertFalse(PilotEconomy.takeCommandOfCapturedHull(&state, hull: 128, game: game),
                       "a full wing can't keep the old hull")
    }

    func testBootyCreditsAndPlunderPanic() {
        XCTAssertEqual(World.bootyCredits(base: 50_000, factor: 0.025, floorAt1000: true) { _ in 0 }, 1250)
        XCTAssertEqual(World.bootyCredits(base: 10_000, factor: 0.025, floorAt1000: true) { _ in 0 }, 1000,
                       "v = 0.25 → 250, floored at 1000")
        XCTAssertEqual(World.bootyCredits(base: 200_000, factor: 0.025, floorAt1000: true) { $0 - 1 }, 9000,
                       "v = 5 → (rand(5) + 5) × 1000")
        XCTAssertEqual(World.bootyCredits(base: 1_500, factor: 0.5, floorAt1000: false) { _ in 0 }, 500)
        var panic = World.PlunderPanic { _ in 0 }
        XCTAssertEqual(panic.panic, 15)
        XCTAssertFalse(panic.rollsSelfDestruct { _ in 0 }, "no risk before anything is taken")
        panic.looted(.cargo); XCTAssertEqual(panic.panic, 30)
        panic.looted(.credits); XCTAssertEqual(panic.panic, 37)
        panic.looted(.fuel); XCTAssertEqual(panic.panic, 55)
        XCTAssertTrue(panic.rollsSelfDestruct { _ in 55 })
        XCTAssertFalse(panic.rollsSelfDestruct { _ in 0 }, "one roll per loot action")
    }
}
