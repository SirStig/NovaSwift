import Foundation
import NovaSwiftKit

// MARK: - Fuel & ammunition plunder
//
// The EV Nova "Plunder Dialog" (`DLOG`/`DITL` #1011) offers six actions, whose
// labels are the six consecutive `STR#` 150 entries "Cargo · Credits · Ammo ·
// Energy · Capture Ship · Demand Tribute". Cargo, Credits, Capture and the
// `përs` ItemClass loot are handled in `World`'s main boarding section; the two
// remaining resource siphons — **Energy** (the hulk's jump fuel) and **Ammo**
// (its weapon ammunition) — live here so they can be added without editing the
// heavily-trafficked `World.swift`. All four entry points share the same
// "is this a boardable hulk?" guard the rest of the boarding code uses (alive +
// disabled + not the player), so they're safe to call on any entity id.
extension World {

    /// Boarding credits (`Boarding_BuildOptions` 0x00484230): `v =
    /// trunc(base / 1000) × factor` (the quotient kept to 16 bits); over 2 the
    /// haul is `trunc((Rand(trunc(v)) + v) × 1000)`, otherwise `trunc(v × 1000)`.
    /// A düde's Booty 0x40 uses the hull's Cost at × 0.025 and a floor of 1000;
    /// a person uses its Credits at × 0.5 with no floor. Below 1 means none.
    public static func bootyCredits(base: Int, factor: Double, floorAt1000: Bool, rand: (Int) -> Int) -> Int {
        let v = Double(Int(Int16(truncatingIfNeeded: base / 1000))) * factor
        var credits: Int
        if v > 2 {
            let n = Int(Float(v))
            credits = Int((Float(rand(n)) + Float(v)) * 1000)
        } else {
            credits = Int(v * 1000)
        }
        if floorAt1000 { credits = max(1000, credits) }
        return max(0, credits)
    }

    /// Record a düde-spawned ship's Booty (the boarding cargo roll reads it)
    /// and set the credits it carries when its Booty has 0x40.
    func assignBootyCredits(_ ship: Ship, dude: DudeRes) {
        ship.dudeBooty = Int(dude.flags)
        guard dude.flags & 0x0040 != 0, let hull = galaxy?.game.ship(ship.shipTypeID) else { return }
        ship.plunderCredits = Self.bootyCredits(base: hull.cost, factor: 0.025, floorAt1000: true) { rng.range($0) }
    }

    /// The plunder window's self-destruct risk (`NovaUi_RunBoardingPlunderWindow`
    /// 0x00482940): seeded at `15 + rand(26)`, multiplied after each loot action
    /// (cargo × 2, credits × 1.25, ammo × 2, fuel × 1.5, truncated); the next
    /// press then blows the hulk up when `rand(100) ≤ panic`. Leaving clears it.
    public struct PlunderPanic: Sendable, Equatable {
        public private(set) var panic: Int
        public private(set) var armed = false

        public enum Loot: Sendable { case cargo, credits, ammo, fuel }

        public init(rand: (Int) -> Int) { panic = 15 + rand(26) }

        public mutating func looted(_ loot: Loot) {
            let factor: Double
            switch loot {
            case .cargo, .ammo: factor = 2
            case .credits: factor = 1.25
            case .fuel: factor = 1.5
            }
            panic = Int(Double(panic) * factor)
            armed = true
        }

        /// The roll at the next press after a loot action: true when the hulk
        /// self-destructs.
        public mutating func rollsSelfDestruct(rand: (Int) -> Int) -> Bool {
            defer { armed = false }
            return armed && rand(100) <= panic
        }
    }

    /// Blow a boarded hulk up (the plunder self-destruct, or the capture's
    /// one-in-ten "Oops"): its shields and armor drop to zero.
    public func selfDestructHulk(_ shipID: Int) {
        guard let s = ship(id: shipID), s !== player, s.isAlive else { return }
        s.shield = 0
        s.armor = 0
    }

    /// Jump fuel the boarded hulk `shipID` offers, in fuel units (100 = one
    /// hyperjump): `Boarding_BuildOptions` 0x00484230 rolls `rand(fuel / 10) ×
    /// 10` of the hull's fuel capacity, not what the hulk has left (EC-18).
    /// Rolled once per hulk; 0 if it isn't a boardable hulk.
    public func fuelAboard(_ shipID: Int) -> Double {
        guard let s = ship(id: shipID), s !== player, s.isAlive, s.disabled else { return 0 }
        if s.plunderFuelRoll == nil {
            let capacity = galaxy?.game.ship(s.shipTypeID)?.fuelCapacity ?? 0
            s.plunderFuelRoll = capacity < 1 ? 0 : rng.range(capacity / 10) * 10
        }
        return Double(s.plunderFuelRoll ?? 0)
    }

    /// Take the boarded hulk's fuel roll, cut to the player's room
    /// (`trunc(capacity − fuel)`), and return the units transferred. The roll
    /// is spent (0x00482940).
    @discardableResult
    public func takePlunderFuel(from shipID: Int) -> Double {
        let offered = Int(fuelAboard(shipID))
        guard offered >= 1, let s = ship(id: shipID) else { return 0 }
        s.plunderFuelRoll = 0
        let take = min(offered, Int(max(0, player.maxFuel - player.fuel)))
        guard take >= 1 else { return 0 }
        player.fuel += Double(take)
        return Double(take)
    }

    /// `Weapon_HasMatchingWeaponAmmoCarried` (0x00469230): the hulk bank
    /// qualifies when the player has a mounted bank drawing the same AmmoType
    /// pool; the first player bay met ends the scan with whether that bay's
    /// AmmoType equals the bank's.
    private func plunderBankQualifies(_ bank: WeaponMount) -> Bool {
        guard bank.ammo > 0, bank.spec.guidance != .bay,
              (0...255).contains(bank.spec.ammoTypeRaw) else { return false }
        for mine in player.weapons {
            if mine.spec.guidance == .bay { return mine.spec.ammoTypeRaw == bank.spec.ammoTypeRaw }
            if mine.spec.ammoTypeRaw == bank.spec.ammoTypeRaw { return true }
        }
        return false
    }

    /// The one hulk bank whose rounds the boarding offers, picked at random
    /// among the qualifying ones once per hulk (0x00484230); nil if none.
    private func plunderAmmoBank(_ s: Ship) -> WeaponMount? {
        if let id = s.plunderAmmoBankID {
            return s.weapons.first { $0.spec.id == id && $0.ammo > 0 }
        }
        let eligible = s.weapons.filter { plunderBankQualifies($0) }
        guard !eligible.isEmpty else { return nil }
        let pick = eligible[rng.range(eligible.count)]
        s.plunderAmmoBankID = pick.spec.id
        return pick
    }

    /// The ammo outfit (ModType 3, the lowest id) that feeds `bank`'s pool.
    private func plunderAmmoOutfit(for bank: WeaponMount) -> OutfRes? {
        guard let game = galaxy?.game else { return nil }
        let target = bank.spec.ammoTypeRaw + 128
        return game.outfits().sorted { $0.id < $1.id }.first {
            $0.firstSlot.type == OutfitModType.ammunition.rawValue && $0.firstSlot.value == target
        }
    }

    /// How many of the offered bank's rounds the player can take: one round
    /// at a time while free mass covers the ammo outfit's Mass and the
    /// player's count stays under its Max (0x00482940).
    private func plunderAmmoRoom(bank: WeaponMount, freeMass: Int) -> Int {
        guard let outfit = plunderAmmoOutfit(for: bank),
              let mine = player.weapons.first(where: { $0.spec.ammoTypeRaw == bank.spec.ammoTypeRaw && $0.ammo >= 0 })
        else { return 0 }
        var rounds = 0, owned = mine.ammo, free = freeMass
        while rounds < bank.ammo, free >= outfit.mass,
              outfit.maxInstallable <= 0 || owned < outfit.maxInstallable {
            rounds += 1; owned += 1; free -= outfit.mass
        }
        return rounds
    }

    /// Ammunition the boarding offers from disabled hulk `shipID` (one bank's
    /// rounds, limited by `freeMass`). 0 if it isn't a boardable hulk.
    public func ammoAboard(_ shipID: Int, freeMass: Int = .max) -> Int {
        guard let s = ship(id: shipID), s !== player, s.isAlive, s.disabled,
              let bank = plunderAmmoBank(s) else { return 0 }
        return plunderAmmoRoom(bank: bank, freeMass: freeMass)
    }

    /// Move the offered bank's rounds into the player's matching pool and
    /// return the rounds taken. Decrements the hulk's rounds so re-boarding
    /// can't duplicate them.
    @discardableResult
    public func takePlunderAmmo(from shipID: Int, freeMass: Int = .max) -> Int {
        guard let s = ship(id: shipID), s !== player, s.isAlive, s.disabled,
              let bank = plunderAmmoBank(s) else { return 0 }
        let take = plunderAmmoRoom(bank: bank, freeMass: freeMass)
        guard take > 0 else { return 0 }
        var credited = Set<ObjectIdentifier>()
        for mine in player.weapons where mine.spec.ammoTypeRaw == bank.spec.ammoTypeRaw && mine.ammo >= 0 {
            // Mounts sharing a pool see the credit once.
            let key = mine.pool.map(ObjectIdentifier.init) ?? ObjectIdentifier(mine)
            if credited.insert(key).inserted { mine.ammo += take }
        }
        bank.ammo -= take
        return take
    }
}

// MARK: - An NPC boarding a ship (AI-29)

extension World {

    /// The boarding party's strength (`Boarding_BoardShipAndTransferCargo`
    /// 0x00412550): `trunc(boarderCrew × 100 / (victimCrew × 2))` (victim crew
    /// at least 1), shifted by the negative-ModVal marines on both sides (the
    /// boarder's raise it, the victim's lower it), plus `10 − Rand(21)`,
    /// clamped to [10, 100]. It scales the credits a boarded player loses.
    public static func npcBoardingRatio(boarderCrew: Int, boarderOddsBonus: Int,
                                        victimCrew: Int, victimOddsBonus: Int,
                                        rand: (Int) -> Int) -> Int {
        let ratio = Float(boarderCrew) * 100 / (Float(max(1, victimCrew)) * 2)
        var r = Int(ratio) + boarderOddsBonus - victimOddsBonus
        r += 10 - rand(21)
        return min(100, max(10, r))
    }

    /// Credits a boarded player loses: `trunc(credits × ratio × 30 × 0.01 × 0.01)`.
    public static func npcBoardingCreditsTaken(playerCredits: Int, ratio: Int) -> Int {
        let taken = Float(max(0, playerCredits)) * Float(ratio * 30) * 0.01 * 0.01
        return max(0, Int(taken))
    }

    /// Move cargo from a victim's hold to the boarder's, the original's way:
    /// while the boarder has room and the victim has cargo, pick one of the six
    /// commodity slots at random and take as much of it as fits, never more in
    /// all than the victim's capacity. Returns what moved.
    public static func npcBoardingCargoTransfer(victimCargo: inout [Int: Int], victimCapacity: Int,
                                                boarderFree: Int, rand: (Int) -> Int) -> [Int: Int] {
        var free = boarderFree
        var aboard = min(victimCapacity, (0..<6).reduce(0) { $0 + max(0, victimCargo[$1] ?? 0) })
        var taken = 0
        var moved: [Int: Int] = [:]
        while free > 0, aboard > 0 {
            let slot = rand(6)
            let have = victimCargo[slot] ?? 0
            guard have > 0 else { continue }
            var n = min(have, free)
            if n + taken > victimCapacity { n = victimCapacity - taken }
            n = max(0, n)
            if n == 0 { break }
            victimCargo[slot] = have - n == 0 ? nil : have - n
            moved[slot, default: 0] += n
            aboard -= n; free -= n; taken += n
        }
        return moved
    }

    /// `ship` boards the disabled `victim` (AI-29). An NPC victim's cargo moves
    /// into the boarder's hold and its credits are gone. A boarded player is
    /// left to the host: `.playerBoarded(byShipID:ratio:)` carries the party's
    /// strength, and the host applies `resolvePlayerBoarding` to the pilot.
    ///
    /// The capture arm (0x00412550): a non-mission NPC victim boarded at a
    /// ratio of 41 or more is taken on `Rand(101) ≤ ratio × 0.5` — it joins
    /// the boarder's wing (its government, behavior 6, no përs) with a
    /// 150-tick coast, no shields and two-thirds of its armor, and every ship
    /// that had it as a target stands down. A captured player escort is
    /// announced ("Escort stolen!" / "Fighter stolen!").
    func npcBoard(_ victim: Ship, by ship: Ship) {
        guard victim.isAlive else { return }
        let ratio = Self.npcBoardingRatio(
            boarderCrew: ship.crew + ship.marineCrew, boarderOddsBonus: ship.captureOddsBonus,
            victimCrew: victim.crew + victim.marineCrew, victimOddsBonus: victim.captureOddsBonus) { rng.range($0) }
        if victim.isPlayer {
            emit(.shipBoarded(entityID: victim.entityID, at: victim.position))
            emit(.playerBoarded(byShipID: ship.entityID, ratio: ratio))
            return
        }
        var cargo = victim.cargo
        let moved = Self.npcBoardingCargoTransfer(victimCargo: &cargo, victimCapacity: victim.cargoCapacity,
                                                  boarderFree: ship.cargoFree) { rng.range($0) }
        victim.cargo = cargo
        for (slot, n) in moved.sorted(by: { $0.key < $1.key }) { ship.cargo[slot, default: 0] += n }
        victim.plunderCredits = 0

        guard victim.missionID == nil, ratio >= 41 else { return }
        guard Double(rng.range(101)) <= Double(ratio) * 0.5 else { return }
        let wasPlayers = victim.brain?.leaderID == Self.playerEntityID || victim.escortRecordID != nil
        if wasPlayers {
            for other in npcs where other.isAlive && other.currentTargetID == victim.entityID {
                other.currentTargetID = nil
                other.brain?.targetID = nil
                originalAI.standDown(other)
            }
        }
        let fighter = victim.carrierID == Self.playerEntityID
        victim.brain?.leaderID = ship.entityID
        victim.carrierID = nil
        victim.escortRecordID = nil
        victim.government = ship.government
        victim.personID = nil
        victim.personFlags = 0
        victim.shield = 0
        victim.disabled = false   // drops a held (derelict) disable; the armor decides now
        victim.armor = Double(Float(victim.maxArmor) * Float(0.66))
        originalAI.joinWing(victim, coastTicks: 150)
        emit(.shipCapturedByNPC(entityID: victim.entityID, byShipID: ship.entityID,
                                stolenLine: wasPlayers ? (fighter ? 169 : 168) : nil))
    }

    /// The host's half of a boarded player (AI-29): take cargo from the pilot's
    /// hold into the boarder's and the credits `npcBoardingCreditsTaken` says.
    /// Returns the cargo and credits lost; the caller writes them to the pilot.
    public func resolvePlayerBoarding(byShipID boarderID: Int, ratio: Int,
                                      playerCargo: [Int: Int], playerCargoCapacity: Int,
                                      playerCredits: Int) -> (cargo: [Int: Int], credits: Int) {
        guard let boarder = ship(id: boarderID) else { return ([:], 0) }
        var cargo = playerCargo
        let moved = Self.npcBoardingCargoTransfer(victimCargo: &cargo, victimCapacity: playerCargoCapacity,
                                                  boarderFree: boarder.cargoFree) { rng.range($0) }
        for (slot, n) in moved {
            boarder.cargo[slot, default: 0] += n
            player.cargo[slot] = max(0, (player.cargo[slot] ?? 0) - n)
        }
        let credits = Self.npcBoardingCreditsTaken(playerCredits: playerCredits, ratio: ratio)
        boarder.plunderCredits = max(0, boarder.plunderCredits) + credits
        return (moved, credits)
    }
}
