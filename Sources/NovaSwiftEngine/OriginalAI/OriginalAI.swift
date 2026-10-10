import Foundation
import NovaSwiftKit

/// The original EV Nova NPC AI: a two-level state machine. Each frame a
/// behavior supervisor (wimpy trader, brave trader, warship, interceptor,
/// escort, defense fleet, miner, plunderer) picks an `ai_state_code`; the state
/// machine (`Ship_UpdateShipAiState` 0x00405590) turns it into one of 24
/// control modes; the controls (`Ship_ApplyShipAiControls` 0x00408150) turn
/// the mode into a heading, a thrust and a desired speed, which
/// `Ship_HandleShip` (0x00433050) integrates.
///
/// This is the only NPC brain. The original's fields live in an
/// `OriginalAIShipState` per ship; the shared ones (squad leader, target) are
/// mirrored onto the ship's `AIBrain` so the rest of the engine and the app
/// keep reading one place.
///
/// Every roll draws `NovaRandom_Range` from the world's one generator.
public final class OriginalAI {
    public private(set) var records: [Int: OriginalAIShipState] = [:]
    private var hulls: [Int: OriginalAIHull] = [:]
    private var stellarCache: (ids: [Int], value: [OriginalAIStellar])?
    private var persFlagCache: [Int: Int] = [:]
    /// Perception results reused within one step: acquisition asks for the
    /// same ships' strength once per candidate.
    var strengthCache: [Int: Int] = [:]
    var pressingCache: [Int: Bool] = [:]
    /// The spaceflight frame counter (`spaceflight_frame_counter`).
    public private(set) var frame = 0
    /// The original's 60 Hz tick clock, for jump spin-up timing.
    public private(set) var clock60: Double = 0
    /// `g_target_category_command`: the player's standing order per escort
    /// category (fighter, medium, warship, freighter). −1 is the startup value
    /// and reads as Formation.

    public init() {}

    public func record(for entityID: Int) -> OriginalAIShipState? { records[entityID] }

    /// The player's `+0xb9` boarded latch: the player has no AI record, but
    /// a boarder latches it like any victim's (0x00408150 mode 0x0f), so the
    /// boarding goes ahead and the player isn't boarded twice this visit.
    var playerBoardedLatch = false

    func isBoarded(_ id: Int) -> Bool {
        id == World.playerEntityID ? playerBoardedLatch : (records[id]?.boarded ?? false)
    }

    func setBoarded(_ id: Int, _ value: Bool) {
        if id == World.playerEntityID { playerBoardedLatch = value } else { records[id]?.boarded = value }
    }

    // MARK: Frame

    /// The once-per-step passes that run before any NPC thinks: arrivals,
    /// the disabled guard, the scope-6 squad-leader pass, formation offsets
    /// and the odds scores.
    func beginStep(_ world: World, dt: Double) {
        let host = WorldAIHost(world: world, ai: self)
        frame &+= 1
        clock60 += dt * 60
        strengthCache.removeAll(keepingCapacity: true)
        pressingCache.removeAll(keepingCapacity: true)
        let live = Set(world.allShips.map(\.entityID))
        records = records.filter { live.contains($0.key) }
        hulls = hulls.filter { live.contains($0.key) }

        for event in world.events {
            switch event {
            case let .shipEmergedFromGate(id, gateID, _):
                if let ship = world.ship(id: id), ship.brain != nil {
                    enterGateEmergence(ensureRecord(ship, host: host), ship: ship, gateID: gateID, host: host)
                }
            default:
                break
            }
        }
        // AI-12: the player's escorts coming out of the player's gate hold
        // `Rand(20) + 15` ticks instead of 60 (0x00457580).
        for (id, entry) in world.escortGateEmergences {
            guard let ship = world.ship(id: id), ship.brain != nil else { continue }
            let rec = ensureRecord(ship, host: host)
            enterGateEmergence(rec, ship: ship, gateID: entry.gateID, host: host)
            rec.maneuverTimer = entry.hold
        }
        world.escortGateEmergences.removeAll()

        for ship in world.npcs where ship.isAlive && ship.disabled {
            guard let rec = records[ship.entityID] else { continue }
            // The disabled auto-guard (0x00401000): a crippled ship drops its
            // targets and stands down. A player escort keeps its place in
            // the wing.
            if ship.brain?.leaderID != World.playerEntityID { ship.brain?.leaderID = nil }
            rec.primary = nil
            rec.secondary = .none
            rec.hostility = 0
            rec.state = OriginalAIState.idle
            rec.mode = OriginalAIMode.idle
            mirror(rec, ship)
        }

        for ship in world.npcs where ship.brain != nil && ship.isAlive {
            _ = ensureRecord(ship, host: host)
        }
        tickLeaderFlags(host)
        for leader in host.ships where leader.isPlayer || (records[leader.entityID]?.isSquadLeader ?? false) {
            updateEscortFormations(leader: leader, host: host)
        }
        for ship in world.npcs where ship.isAlive {
            guard let rec = records[ship.entityID] else { continue }
            rec.odds = combatOdds(ship, host: host)
        }
    }

    /// One NPC's frame: the dispatcher, the state machine, the controls and
    /// the movement they command. Returns the intent `Ship.step` flies.
    func think(ship: Ship, world: World, dt: Double) -> ControlIntent {
        let host = WorldAIHost(world: world, ai: self)
        let rec = ensureRecord(ship, host: host)
        bridgeOutsideWrites(rec, ship: ship, host: host)
        let ticks = dt * OriginalClock.ticksPerSecond
        rec.fire = []
        update(rec, ship: ship, host: host, ticks: ticks)
        var intent = integrate(rec, ship: ship, host: host, ticks: ticks)
        // Mirror first so the selectors and `World.fireWeapons` see this
        // frame's target.
        mirror(rec, ship)
        if let bank = host.steerFire(ship, rec.fire, intent: &intent) { rec.activeBank = bank }
        return intent
    }

    // MARK: Dispatcher (Ship_UpdateShipAI 0x00401000)

    /// `g_ai_update_period` (`DAT_00591184`): 1 while the averaged frame scale
    /// is ≤ 1.0, then 2 up to 1.3, 4 up to 1.7, 8 above.
    static func updatePeriod(averageScale: Double) -> Int {
        if averageScale <= 1.0 { return 1 }
        if averageScale <= 1.3 { return 2 }
        if averageScale <= 1.7 { return 4 }
        return 8
    }

    /// Whether the heavy decision skips this frame (0x00401242): only for a
    /// busy ship, on frames outside its instance's phase.
    static func throttles(state: Int, mode: Int, frame: Int, instance: Int, period: Int) -> Bool {
        guard period > 1 else { return false }
        if [0x00, 0x0f, 0x11, 0x14].contains(mode) { return false }
        if [0x00, 0x08, 0x09, 0x0f, 0x12].contains(state) { return false }
        return frame % period != instance % period
    }

    func update(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost, ticks: Double) {
        if rec.maneuverTimer <= 0 { updateCloak(rec, ship: ship, host: host) }

        let arrivalSentinel = rec.jumpTimer < -900
        let entryMode = rec.mode
        let jumpControl = entryMode == OriginalAIMode.jumpSpinUp || entryMode == OriginalAIMode.squadJumpHold
        var ordinary = false
        var skipHeavy = false

        if arrivalSentinel {
            rec.state = OriginalAIState.arrival
            rec.mode = OriginalAIMode.arrivalSlowdown
        } else if jumpControl {
            // State 0x0B leaves the squad jump when its reason goes away.
            if rec.state == OriginalAIState.squadJump, let leaderID = leader(of: ship) {
                if leaderID == World.playerEntityID {
                    if host.player.disabled { abortSquadJump(rec) }
                } else if rec.jumpTimer <= 1, let leaderShip = host.ship(leaderID),
                          !leaderShip.disabled, records[leaderID]?.state == OriginalAIState.attack {
                    abortSquadJump(rec)
                }
            }
        } else {
            ordinary = true
            if rec.state == OriginalAIState.arrival { rec.state = OriginalAIState.idle }
            if rec.isSquadLeader, frame % 8 == (ship.entityID % 64) >> 3 {
                issueEscortOrders(rec, ship: ship, host: host)
            }
            if rec.state == OriginalAIState.disengaged {
                // About 1/100 per tick back to idle; otherwise the heavy AI
                // sits this frame out.
                let n = ticks > 0 ? Int(100 / ticks) : 100
                if host.random(n) == 0 {
                    rec.state = OriginalAIState.idle
                } else {
                    skipHeavy = true
                }
            } else if Self.throttles(state: rec.state, mode: rec.mode, frame: frame, instance: ship.entityID,
                                     period: Self.updatePeriod(averageScale: ticks)) {
                skipHeavy = true
            }
        }

        if !skipHeavy {
            if ordinary && rec.state != OriginalAIState.gateEmerge {
                if !swarmMateStillValid(rec, ship: ship, host: host) { findSwarmMate(rec, ship: ship, host: host) }
                runSupervisor(rec, ship: ship, host: host)
            }
            updateState(rec, ship: ship, host: host, ticks: ticks)
        }
        applyControls(rec, ship: ship, host: host, ticks: ticks)
    }

    private func abortSquadJump(_ rec: OriginalAIShipState) {
        rec.standDown()
        rec.jumpTimer = 0
    }

    func runSupervisor(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        let hull = host.hull(of: ship)
        if ship.missionID != nil, ship.brain?.behaviorOverride == .attackStellars {
            stellarAttackDirective(rec, ship: ship, host: host)
        } else if rec.defenseHome != nil {
            defenseFleet(rec, ship: ship, host: host)
        } else if hull.flags3 & 0x0003 != 0, leader(of: ship) == nil {
            asteroidMiner(rec, ship: ship, host: host)
        } else {
            switch rec.behavior {
            case 1: wimpyTrader(rec, ship: ship, host: host)
            case 2: braveTrader(rec, ship: ship, host: host)
            case 3:
                if let g = host.govt(ship.government), g.flags1 & 0x1000 != 0 {
                    plunderer(rec, ship: ship, host: host)
                } else {
                    warship(rec, ship: ship, host: host)
                }
            case 4: interceptor(rec, ship: ship, host: host)
            case 5...: escortSupervisor(rec, ship: ship, host: host)
            default: break
            }
        }
    }

    /// `Mission_UpdateShipMissionStellarAttackDirective` 0x004053c0, for a
    /// mission ship with ShipBehav 2: the first standing destroyable stellar
    /// of a hostile or xenophobic government, and the first ready planet-type
    /// weapon that isn't a beam, put the ship in state 0x12 against it.
    /// Without both it drops a 0x12 attack and flies as a warship, whatever
    /// its own AI type.
    func stellarAttackDirective(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        guard !ship.disabled, ship.isAlive, rec.state != OriginalAIState.yield else { return }
        let target = host.stellars.first { s in
            host.stellarAttackable(s.id) && host.areHostile(s.government, ship.government)
        }
        let weapon = ship.weapons.contains { mount in
            let g = mount.spec.guidance.rawValue
            return mount.spec.isPlanetTypeWeapon && !mount.spec.isBeam && mount.count > 0 && mount.ready
                && g != WeaponGuidance.beam.rawValue && g != WeaponGuidance.beamTurret.rawValue && g < 8
        }
        if let target, weapon {
            rec.primary = nil
            rec.secondary = .stellar(target.id)
            rec.state = OriginalAIState.stellarAttack
            return
        }
        if rec.state == OriginalAIState.stellarAttack {
            rec.primary = nil
            rec.secondary = .none
            rec.state = OriginalAIState.idle
            rec.mode = OriginalAIMode.idle
        }
        warship(rec, ship: ship, host: host)
    }

    // MARK: Records

    func ensureRecord(_ ship: Ship, host: OriginalAIHost) -> OriginalAIShipState {
        if let rec = records[ship.entityID] { return rec }
        let behavior = Self.initialBehavior(ship, hull: host.hull(of: ship))
        // The cadence is seeded at spawn (0x0041bf32 / 0x00422400): the
        // Spawner leaves `Rand(3) XOR 2` on a dude, 2 on a class-spawned
        // escort, a përs its Aggress clamped to 1, 2 or 4. A brainless ship
        // has no spawn draw; it gets the dude roll here.
        let cadence: Int
        if let brain = ship.brain {
            cadence = brain.personAggression.map(AIBrain.cadence(forAggress:)) ?? brain.cadence
        } else {
            cadence = behavior >= 5 ? 2 : host.random(3) ^ 2
        }
        let rec = OriginalAIShipState(entityID: ship.entityID, behavior: behavior, cadence: cadence)
        rec.defenseHome = ship.spobDefenderOf
        rec.afterburnerLatch = canUseAfterburner(ship, host: host)
        records[ship.entityID] = rec
        // `World.addNPC(.hyperspace)` marks a jump-in with an entry over-speed.
        if ship.entryOverspeed > 0 { enterArrival(rec, ship: ship, host: host) }
        return rec
    }

    static func initialBehavior(_ ship: Ship, hull: OriginalAIHull) -> Int {
        if ship.carrierID != nil { return 5 }
        if ship.brain?.leaderID != nil { return 6 }
        let raw = ship.brain?.aiType.rawValue ?? 0
        if (1...4).contains(raw) { return raw }
        return (1...4).contains(hull.inherentAI) ? hull.inherentAI : 1
    }

    /// `Ship_CanShipUseAfterburner` (0x0046b260), rolled once at spawn.
    func canUseAfterburner(_ ship: Ship, host: OriginalAIHost) -> Bool {
        let hull = host.hull(of: ship)
        if hull.flags & 0x0400 != 0 { return false }
        if let pid = ship.personID, let world = (host as? WorldAIHost)?.world,
           persFlags(pid, world: world) & 0x0002 != 0 {
            return true
        }
        if hull.flags & 0x0040 != 0 { return true }
        if hull.flags & 0x0020 != 0 {
            let roll = host.random(0x540)
            return roll + 0x100 <= host.playerCombatRating / max(1, host.classZeroStrength)
        }
        return false
    }

    func hull(of ship: Ship, world: World) -> OriginalAIHull {
        if let h = hulls[ship.entityID] { return h }
        var h = OriginalAIHull()
        h.flags = ship.hullFlags
        h.flags2 = ship.hullFlags2
        h.mass = Int(ship.massTons)
        h.speed = Int(ship.stats.maxSpeed / FlightTuning.original.speedScale)
        h.crew = ship.crew
        h.strength = Int(ship.combatStrength)
        if let res = world.galaxy?.game.ship(ship.shipTypeID) {
            h.flags = Int(res.flags)
            h.flags2 = Int(res.flags2)
            h.flags3 = Int(res.flags3)
            h.mass = res.mass
            h.speed = res.speed
            h.crew = res.crew
            h.strength = res.strength
            h.inherentAI = res.inherentAI
            h.escortClass = res.escortClass
            h.inherentCombatGovt = res.inherentCombatGovt
            h.fuelCapacity = res.fuelCapacity
        } else {
            h.inherentAI = ship.brain?.aiType.rawValue ?? 1
            h.escortClass = h.inherentAI < 3 ? 3 : h.mass < 50 ? 0 : h.mass < 200 ? 1 : 2
        }
        hulls[ship.entityID] = h
        return h
    }

    func stellars(of world: World) -> [OriginalAIStellar] {
        let ids = world.systemContext.bodies.map(\.id)
        if let cache = stellarCache, cache.ids == ids { return cache.value }
        let value = world.systemContext.bodies.map { body -> OriginalAIStellar in
            let spob = world.galaxy?.game.spob(body.id)
            return OriginalAIStellar(
                id: body.id, position: body.position,
                mapX: Int(body.position.x.rounded()), mapY: Int((-body.position.y).rounded()),
                uninhabited: spob.map { $0.isUninhabited } ?? !body.canLand,
                hypergate: body.isHypergate, wormhole: body.isWormhole, government: body.government)
        }
        stellarCache = (ids, value)
        return value
    }

    private var cachedCue: Double?
    private var cachedProbe: Double?

    /// The "Warp up" cue length (FL-04), decoded once.
    func jumpCueTicks60(_ world: World) -> Double {
        if let c = cachedCue { return c }
        let c = world.galaxy?.hyperspaceCueTicks60 ?? PlayerHyperjump.defaultCueTicks60
        cachedCue = c
        return c
    }

    /// wëap 0x81's reach + 32, the envelope `Ship_IssueEscortOrders` probes.
    func escortProbeRange(_ world: World) -> Double {
        if let p = cachedProbe { return p }
        let p = (world.galaxy?.weaponSpec(0x81)?.range ?? 350) + 32
        cachedProbe = p
        return p
    }

    func persFlags(_ id: Int, world: World) -> Int {
        if let f = persFlagCache[id] { return f }
        let f = Int(world.galaxy?.game.pers(id)?.flags ?? 0)
        persFlagCache[id] = f
        return f
    }

    // MARK: Arrival

    /// A hyperspace jump-in (`0x00410e20`): placed on the polar entry radius
    /// facing the system centre, then state 8 with the −999 sentinel slides it
    /// in along its heading at 50 px/tick, the override easing by 1.165 per
    /// tick (mode 0x0a) until it is down to its top speed.
    func enterArrival(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        rec.state = OriginalAIState.arrival
        rec.mode = OriginalAIMode.arrivalSlowdown
        rec.jumpTimer = -999
        rec.desiredSpeed = -50
        // AI-12: the Spawner owns the placement (`Rand(360)` bearing at
        // `OriginalSpawnRules.jumpInRadius`, escorts ±150 px off their lead,
        // mission ships ±256 px), so the AI keeps the pose it was given.
        ship.entryOverspeed = 0
        ship.entryOverspeedDecayPerSec = 0
        ship.velocity = Vec2.heading(ship.angle) * OriginalClock.perSecond(50)
        ship.throttleSpeed = OriginalClock.perSecond(50)
    }

    /// `Ship_EnterShipAiState0x15_EmergeFromHypergate` (0x004159e0): a 60-tick
    /// hold at the gate, then the state-8 slide at 30 px/tick (15 for a
    /// player escort).
    func enterGateEmergence(_ rec: OriginalAIShipState, ship: Ship, gateID: Int, host: OriginalAIHost) {
        rec.state = OriginalAIState.gateEmerge
        rec.mode = OriginalAIMode.idle
        rec.primary = nil
        rec.secondary = .stellar(gateID)
        rec.maneuverTimer = 60
        rec.jumpTimer = 0
        rec.jumpDestination = host.hull(of: ship).fuelCapacity >= 1 ? gateID : -2
        rec.desiredSpeed = leader(of: ship) == World.playerEntityID ? -15 : -30
        rec.thrustCommand = -3
        ship.velocity = Vec2()
        ship.throttleSpeed = 0
    }

    // MARK: Mirror

    func mirror(_ rec: OriginalAIShipState, _ ship: Ship) {
        ship.brain?.targetID = rec.primary
        ship.currentTargetID = rec.primary
        let mapped = Self.brainState(rec.state)
        ship.brain?.state = mapped
        rec.mirroredState = mapped
    }

    static func brainState(_ code: Int) -> AIState {
        switch code {
        case OriginalAIState.travel, OriginalAIState.gateEntry: return .traveling
        case OriginalAIState.departJump: return .departing
        case OriginalAIState.retreat: return .fleeing
        case OriginalAIState.attack, OriginalAIState.board, OriginalAIState.stellarAttack: return .attacking
        case OriginalAIState.returnToLeader, OriginalAIState.escortStation,
             OriginalAIState.squadJump, OriginalAIState.playerStation: return .escorting
        case OriginalAIState.park: return .orbiting
        case OriginalAIState.scanApproach: return .scanning
        case OriginalAIState.arrival, OriginalAIState.gateEmerge: return .spawning
        case OriginalAIState.refuel, OriginalAIState.repair: return .assisting
        default: return .patrolling
        }
    }

    /// The app still drives two things through `AIBrain.state`: sending a
    /// përs away after a hail (`.departing`) and an accepted assistance request
    /// (`.assisting`). Translate those into the original's states.
    private func bridgeOutsideWrites(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        guard let brain = ship.brain, let mirrored = rec.mirroredState, brain.state != mirrored else { return }
        switch brain.state {
        case .departing:
            rec.enterDeparture(clock60: clock60)
        case .assisting:
            beginAssistance(rec, repair: host.player.disabled)
        default:
            break
        }
    }

    // MARK: Squad helpers

    func leader(of ship: Ship) -> Int? { ship.brain?.leaderID }

    func setLeader(_ ship: Ship, _ id: Int?) { ship.brain?.leaderID = id }
}
