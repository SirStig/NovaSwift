import Foundation
import NovaSwiftKit

/// A stellar as the original AI sees it: its nav slot, map position and the
/// flags the travel picker reads.
struct OriginalAIStellar {
    let id: Int
    /// Engine position (+y up).
    let position: Vec2
    /// `spöb` X/Y as stored (+y down), for the picker's literal `< 1000` test.
    let mapX: Int
    let mapY: Int
    /// `spöb` Flags 0x20.
    let uninhabited: Bool
    /// `spöb` Flags2 0x1000 / 0x2000.
    let hypergate: Bool
    let wormhole: Bool
    let government: Int
    var isGate: Bool { hypergate || wormhole }
}

/// The hull fields the AI reads, decoded once per ship.
struct OriginalAIHull {
    var flags = 0
    var flags2 = 0
    var flags3 = 0
    var mass = 0
    /// `shïp.Speed`, the class base top speed.
    var speed = 0
    var crew = 0
    var strength = 0
    /// `shïp.InherentAI`, the class default behavior.
    var inherentAI = 1
    /// `EscortType` as the loader stores it: 0 fighter, 1 medium, 2 warship, 3 freighter.
    var escortClass = 0
    var inherentCombatGovt = -1
    var fuelCapacity = 0
}

/// Everything the original AI needs from the simulation, kept narrow so the
/// pieces other fidelity batches are still building can be rewired in one
/// place. Each remaining `TODO(batch N)` names the batch whose work replaces
/// the interim answer.
protocol OriginalAIHost {
    /// Every live ship in slot order: the player first, then NPCs by entity id.
    var ships: [Ship] { get }
    var player: Ship { get }
    func ship(_ id: Int) -> Ship?
    /// `NovaRandom_Range(n)` on the game's one generator.
    func random(_ n: Int) -> Int
    var stellars: [OriginalAIStellar] { get }
    func hull(of ship: Ship) -> OriginalAIHull
    func govt(_ id: Int) -> GovtRes?
    /// `Government_AreGovtsAllied` 0x0046bc90 (`GovtRelations.allied`): the
    /// same government, or either lists one of the other's classes as an ally.
    func areAllied(_ a: Int, _ b: Int) -> Bool
    /// `Government_AreGovtsHostileOrXenophobic` 0x0046bdf0
    /// (`GovtRelations.hostileOrXenophobic`).
    func areHostile(_ a: Int, _ b: Int) -> Bool
    /// `Ship_CanShipEngageTargetUnderCloakRules` (0x00464a90) without the
    /// state-0x15 arm, which the AI applies itself.
    func canDetect(_ subject: Ship, by observer: Ship) -> Bool
    /// Rank privilege "won't auto-attack" for this government.
    func rankForbidsAutoAttack(_ govt: Int) -> Bool
    /// The player's IFF scrambler fools this government.
    func iffScrambled(_ govt: Int) -> Bool
    /// The near-player reputation ladder of 0x0040e020 (AI-05) on the
    /// player's reputation in the current system.
    func reputationFlagsPlayer(govt: Int) -> Bool
    /// `system_reputation[player_system]` (EC-02).
    var playerReputationHere: Int { get }
    /// The current system's owning government, −1 independent.
    var systemGovernment: Int { get }
    /// pêrs Flags 0x0001 with its grudge latched (AI-07).
    func holdsGrudge(_ ship: Ship) -> Bool
    /// `Weapon_HasAnyFireableNonSecondaryWeapon` (0x00415c10): a MassDmg > 0
    /// weapon without wëap Flags2 0x1000.
    func hasLethalWeapon(_ ship: Ship) -> Bool
    /// `Weapon_ClassifyShipWeaponAmmoReadiness`: 0 all ready, 1 some ammo out,
    /// 2 nothing can fire.
    func ammoReadiness(_ ship: Ship) -> Int
    func maxWeaponRange(_ ship: Ship) -> Double
    /// Whether any of `ship`'s guided weapons can intercept `target` from here
    /// (the bank walk inside 0x00410f20).
    func hasInterceptingGuidedBank(_ ship: Ship, against target: Ship) -> Bool
    /// The wëap 0x81 envelope `Ship_IssueEscortOrders` probes (range + 32).
    var escortProbeRange: Double { get }
    /// Jump spin-up length in 60 Hz ticks, and the hull's duration multiplier
    /// (FL-04).
    var jumpCueTicks60: Double { get }
    func jumpMultiplier(_ ship: Ship) -> Double
    func canJump(_ ship: Ship) -> Bool
    /// `Ship_CheckSpecialLoadoutCapability` (0x0046d080): skips the brake.
    func fastJump(_ ship: Ship) -> Bool
    var playerJumpTimer: Double { get }
    var playerCombatRating: Int { get }
    var classZeroStrength: Int { get }
    /// The player's hull's inherent combat government.
    var playerInherentGovt: Int { get }
    /// The asteroid the miners chase (`g_asteroid_states[0]`).
    var firstAsteroid: (position: Vec2, velocity: Vec2)? { get }
    /// AI-31: live freeflight boxes (DAT_0073548b and the 64-entry scan).
    var freeflightPositions: [Vec2] { get }
    func isMissionAttacker(_ ship: Ship) -> Bool
    /// The ship flies the port's driftless formation model (the
    /// `formationFlying` enhancement), which reads `ControlIntent.thrust`.
    func fliesPortFormationModel(_ ship: Ship) -> Bool

    /// The heading (degrees) the pursuit / strafe modes aim along:
    /// `Ship_AimWeaponPredictive` (0x0043b740) with `bank`, which leads only a
    /// projectile bank (unguided, turret, rocket, quadrant); otherwise the
    /// straight bearing.
    func leadBearingDeg(_ ship: Ship, target: Ship, bank: Int?) -> Double
    /// An allied reinforcement countdown is running in this system (AI-13).
    func reinforcementInbound(alliedWith govt: Int) -> Bool

    // Effects.
    /// Pull the trigger for the banks the AI-02 selectors arm for `fire`;
    /// returns the forward bank armed, if any.
    func steerFire(_ ship: Ship, _ fire: OriginalAIFire, intent: inout ControlIntent) -> Int?
    func scanPlayer(by ship: Ship)
    func board(_ victim: Ship, by ship: Ship)
    func depart(_ ship: Ship, viaGate gateID: Int?)
    func tryAssistanceEncounter(_ ship: Ship, odds: Double)
    func transferFuel(to ship: Ship, amount: Double)
    func repairAboveDisable(_ ship: Ship)
}

/// The original AI's view of a live `World`.
struct WorldAIHost: OriginalAIHost {
    unowned let world: World
    let ai: OriginalAI

    var ships: [Ship] { world.allShips }
    var player: Ship { world.player }
    func ship(_ id: Int) -> Ship? { world.ship(id: id) }
    func random(_ n: Int) -> Int { world.rng.range(n) }
    var stellars: [OriginalAIStellar] { ai.stellars(of: world) }
    func hull(of ship: Ship) -> OriginalAIHull { ai.hull(of: ship, world: world) }
    func govt(_ id: Int) -> GovtRes? { id >= govtResourceBase ? world.diplomacy?.govt(id) : nil }

    func areAllied(_ a: Int, _ b: Int) -> Bool {
        if a == b { return true }
        guard let dip = world.diplomacy else { return false }
        return GovtRelations.allied(a, b, govts: dip.govts)
    }

    func areHostile(_ a: Int, _ b: Int) -> Bool {
        guard let dip = world.diplomacy else { return false }
        return GovtRelations.hostileOrXenophobic(a, b, govts: dip.govts)
    }

    func canDetect(_ subject: Ship, by observer: Ship) -> Bool { world.canDetect(subject, by: observer) }

    func rankForbidsAutoAttack(_ govt: Int) -> Bool {
        world.diplomacy?.rankProtectedGovts.contains(govt) ?? false
    }

    func iffScrambled(_ govt: Int) -> Bool {
        let scrambled = world.player.iffScramblerClasses
        guard !scrambled.isEmpty else { return false }
        if scrambled.contains(-1) { return true }
        guard let classes = self.govt(govt)?.classes else { return false }
        return !scrambled.isDisjoint(with: classes)
    }

    /// AI-05: Batch 3's ladder (`Diplomacy.reputationLadderFlagsPlayer`) on
    /// the player's reputation in the current system. The caller applies
    /// Flags 0x0040, rank privilege and the IFF scrambler itself.
    func reputationFlagsPlayer(govt id: Int) -> Bool {
        guard govt(id) != nil else { return false }
        return world.diplomacy?.reputationLadderFlagsPlayer(id) ?? false
    }

    var playerReputationHere: Int { world.diplomacy?.reputationHere ?? 0 }
    var systemGovernment: Int { world.diplomacy?.currentSystemGovernment ?? world.systemContext.systemGovt }

    /// AI-07: `World.applyHit` latches the grudge on any player hit on a
    /// përs with Flags 0x0001; only such a përs honours it.
    func holdsGrudge(_ ship: Ship) -> Bool {
        guard let pid = ship.personID, ship.personFlags & 0x0001 != 0 else { return false }
        return world.playerPersGrudges.contains(pid)
    }

    /// `Weapon_HasAnyFireableNonSecondaryWeapon` as Batch 2/3 ported it.
    func hasLethalWeapon(_ ship: Ship) -> Bool { AIBrain.hasLethalWeapon(ship) }

    func ammoReadiness(_ ship: Ship) -> Int {
        let mounts = ship.weapons.filter { $0.spec.guidance != .bay && !$0.spec.isPointDefense }
        guard !mounts.isEmpty else { return 2 }
        let dry = mounts.filter { $0.ammo == 0 }.count
        if dry == mounts.count { return 2 }
        return dry > 0 ? 1 : 0
    }

    func maxWeaponRange(_ ship: Ship) -> Double {
        ship.weapons.filter { $0.spec.guidance != .bay }.map(\.spec.range).max() ?? 0
    }

    func hasInterceptingGuidedBank(_ ship: Ship, against target: Ship) -> Bool {
        let d = target.position - ship.position
        let d2 = d.x * d.x + d.y * d.y
        return ship.weapons.contains { m in
            m.spec.guidance == .guided && m.ammo != 0 && m.cooldown <= 0
                && d2 * 0.95 <= m.spec.range * m.spec.range
        }
    }

    var escortProbeRange: Double { ai.escortProbeRange(world) }

    var jumpCueTicks60: Double { ai.jumpCueTicks60(world) }

    func jumpMultiplier(_ ship: Ship) -> Double {
        PlayerHyperjump.durationMultiplier(hullFlags: hull(of: ship).flags)
    }

    func canJump(_ ship: Ship) -> Bool { ship.fuel >= ShipFuel.perJump }

    /// shïp Flags2 0x0020 or a ModType-37 outfit, the hull's DefaultItems
    /// included for an NPC (`ShipLoadout.instantJump`).
    func fastJump(_ ship: Ship) -> Bool { ship.instantJump || ship.hullFlags2 & 0x0020 != 0 }

    var playerJumpTimer: Double {
        guard let jump = world.playerJump else { return 0 }
        return jump.phase == .spinUp ? max(1, jump.timer) : 0
    }

    var playerCombatRating: Int { world.livePlayerCombatRating }
    var classZeroStrength: Int { world.classZeroStrength }

    var playerInherentGovt: Int { hull(of: world.player).inherentCombatGovt }

    var firstAsteroid: (position: Vec2, velocity: Vec2)? {
        world.asteroids.first.map { ($0.position, $0.velocity) }
    }

    var freeflightPositions: [Vec2] { world.freeflightObjects.map(\.position) }

    func isMissionAttacker(_ ship: Ship) -> Bool { ship.brain?.behaviorOverride == .attackPlayer }

    func fliesPortFormationModel(_ ship: Ship) -> Bool {
        !ship.inertialess && ship.fliesInertialess(world.tuning)
    }

    /// AI-02: each request runs its selector (`NPCWeaponSelection`); the
    /// original keeps one active forward bank, so guided beats direct beats
    /// unguided beats the general fallback, and the turret selector arms its
    /// own bank beside it. `World.fireWeapons` then serves exactly those
    /// mounts.
    func steerFire(_ ship: Ship, _ fire: OriginalAIFire, intent: inout ControlIntent) -> Int? {
        guard !fire.isEmpty else { return nil }
        let target = ship.currentTargetID.flatMap { world.ship(id: $0) }
        var forward: Int?
        if let target {
            if fire.contains(.guided) { forward = world.npcGuidedBank(for: ship, target: target) }
            if forward == nil, fire.contains(.direct) {
                forward = world.npcDirectFireBank(for: ship, target: target, allowGuided: false)
            }
        }
        if forward == nil, fire.contains(.unguided) { forward = world.npcUnguidedBank(for: ship, target: target) }
        if forward == nil, fire.contains(.general) { forward = world.npcGeneralBank(for: ship) }
        var mounts = Set([forward].compactMap { $0 })
        if fire.contains(.turret), let target, let turret = world.npcTurretBank(for: ship, target: target) {
            mounts.insert(turret)
        }
        guard !mounts.isEmpty else { return nil }
        intent.npcMounts = (intent.npcMounts ?? []).union(mounts)
        intent.firePrimary = true
        return forward
    }

    func leadBearingDeg(_ ship: Ship, target: Ship, bank: Int?) -> Double {
        let straight = OriginalAI.bearingDeg(ship.position, target.position)
        guard let bank, ship.weapons.indices.contains(bank) else { return straight }
        let spec = ship.weapons[bank].spec
        switch spec.guidance {
        case .unguided, .turret, .rocket, .frontQuadrant, .rearQuadrant, .pointDefense: break
        default: return straight
        }
        var deg = world.leadAngle(from: ship.position, shooterVel: ship.velocity, target: target, spec: spec)
            * 180 / .pi
        deg = deg.truncatingRemainder(dividingBy: 360)
        return deg < 0 ? deg + 360 : deg
    }

    func reinforcementInbound(alliedWith govt: Int) -> Bool {
        world.spawner?.reinforcementInbound(alliedWith: govt, world: world) ?? false
    }

    /// `Ship_ScanPlayerForContraband` (0x00401800): EC-15's trigger
    /// (`Contraband.scanFires`: SmugPenalty ≠ 0, then `Rand(100) ≤ 75`). The
    /// findings, fine and SmugPenalty flood are `ContrabandScan` (EC-15), run
    /// by the host on the `.shipScanned` event.
    func scanPlayer(by ship: Ship) {
        guard let g = govt(ship.government),
              Contraband.scanFires(smugglePenalty: g.smugglePenalty, rand100: { random(100) }) else { return }
        world.reportScan(scannerID: ship.entityID, targetID: World.playerEntityID, at: ship.position)
    }

    /// AI-29: `Boarding_BoardShipAndTransferCargo` 0x00412550 (`World.npcBoard`).
    func board(_ victim: Ship, by ship: Ship) {
        world.npcBoard(victim, by: ship)
    }

    func depart(_ ship: Ship, viaGate gateID: Int?) {
        ship.wantsToDepart = true
        ship.departsInPlace = true
        ship.brain?.departViaGateID = gateID
    }

    /// AI-13: `Government_TryTriggerGovtAssistanceEncounter` (0x00413610) on
    /// the system's reinforcement fleet (`Spawner.requestAssistance`).
    func tryAssistanceEncounter(_ ship: Ship, odds: Double) {
        world.spawner?.requestAssistance(govt: ship.government, odds: odds, forced: false, world: world)
    }

    func transferFuel(to ship: Ship, amount: Double) { ship.fuel += amount }

    /// The mode-0xf repair arm adds 1 armor at a time until the ship is no
    /// longer disabled, all in one frame.
    func repairAboveDisable(_ ship: Ship) {
        guard ship.isAlive, !ship.heldDisabled else { return }
        while ship.disabled { ship.armor += 1 }
    }
}
