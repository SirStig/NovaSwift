import Foundation
import NovaSwiftKit

/// Target acquisition and the perception predicates it is built from. Most
/// gates are per-axis boxes; distances that rank candidates are
/// `floor|dx|² + floor|dy|²`.
extension OriginalAI {

    /// `floor|dx|² + floor|dy|²` (the acquisition metric of 0x0040e020).
    static func axisDistanceSquared(_ a: Vec2, _ b: Vec2) -> Int {
        let dx = Int(abs(a.x - b.x)), dy = Int(abs(a.y - b.y))
        return dx * dx + dy * dy
    }

    /// Both axes within `r`.
    static func inBox(_ a: Vec2, _ b: Vec2, _ r: Double) -> Bool {
        abs(a.x - b.x) <= r && abs(a.y - b.y) <= r
    }

    // MARK: Predicates

    /// `Ship_CanShipEngageTargetUnderCloakRules` (0x00464a90): `subject` can
    /// be engaged by `observer` unless it is emerging from a gate or hidden by
    /// a cloak the observer can't see through.
    func canEngage(_ subject: Ship, by observer: Ship, host: OriginalAIHost) -> Bool {
        if records[subject.entityID]?.state == OriginalAIState.gateEmerge { return false }
        return host.canDetect(subject, by: observer)
    }

    /// `Ship_IsEnemyOfShip` (0x004101d0).
    func isEnemy(_ ship: Ship, _ other: Ship, host: OriginalAIHost) -> Bool {
        guard ship.entityID != other.entityID, ship.isAlive, other.isAlive else { return false }
        let a = ship.government, b = other.government
        guard a >= govtResourceBase, b >= govtResourceBase, a != b else { return false }
        if host.areHostile(a, b) { return true }
        if let gb = host.govt(b), gb.xenophobic, !host.areAllied(a, b) { return true }
        return false
    }

    private static let disengagedStates: Set<Int> = [0x07, 0x09, 0x0f, 0x0a, 0x0b, 0x05, 0x0c, 0x12]

    /// `Ship_IsThreatToPlayerSquad` (0x0040f6d0): pressing the player or one
    /// of the player's escorts.
    func isThreatToPlayerSquad(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) -> Bool {
        guard ship.isAlive, rec.maneuverTimer <= 0, !ship.disabled, let target = rec.primary else { return false }
        if Self.disengagedStates.contains(rec.state) { return false }
        if target == World.playerEntityID { return true }
        return host.ship(target).map { leader(of: $0) == World.playerEntityID } ?? false
    }

    /// `Ship_IsThreatToPlayerSquad` for `ship` in a live world. A ship the
    /// original AI doesn't run is no threat.
    public func isThreatToPlayerSquad(_ ship: Ship, world: World) -> Bool {
        guard let rec = records[ship.entityID] else { return false }
        return isThreatToPlayerSquad(rec, ship: ship, host: WorldAIHost(world: world, ai: self))
    }

    /// `Ship_IsShipAcquirableAsTarget(candidate, acquirer)` (0x0040faa0):
    /// whether `acquirer` is attacking `candidate` (or one of its squad).
    func isAttacking(_ acquirer: Ship, _ candidate: Ship, host: OriginalAIHost) -> Bool {
        guard acquirer.isAlive, !acquirer.disabled else { return false }
        if leader(of: acquirer) == candidate.entityID { return false }
        if acquirer.isPlayer {
            if host.rankForbidsAutoAttack(candidate.government) { return false }
            guard let rec = records[candidate.entityID] else { return false }
            return isThreatToPlayerSquad(rec, ship: candidate, host: host)
        }
        guard let rec = records[acquirer.entityID] else { return false }
        let stateOK = !Self.disengagedStates.contains(rec.state)
        guard stateOK, let target = rec.primary else { return false }
        if target == candidate.entityID { return true }
        return host.ship(target).map { leader(of: $0) == candidate.entityID && $0.isAlive } ?? false
    }

    /// `Ship_ShouldShipKeepPressingTarget` (0x0040f780).
    func keepsPressing(_ ship: Ship, host: OriginalAIHost) -> Bool {
        if let cached = pressingCache[ship.entityID] { return cached }
        let result = computeKeepsPressing(ship, host: host)
        pressingCache[ship.entityID] = result
        return result
    }

    private func computeKeepsPressing(_ ship: Ship, host: OriginalAIHost) -> Bool {
        guard ship.isAlive, !ship.disabled, !ship.isPlayer, let rec = records[ship.entityID] else { return false }
        guard leader(of: ship) != World.playerEntityID, let target = rec.primary else { return false }
        guard canEngage(host.player, by: ship, host: host) else { return false }
        if rec.defenseHome != nil { return true }
        let coasting = rec.maneuverTimer > 0
        let engaged = !Self.disengagedStates.contains(rec.state)
        if !coasting && engaged {
            if target == World.playerEntityID { return true }
            if let t = host.ship(target), leader(of: t) == World.playerEntityID { return true }
        }
        guard engaged else { return false }
        for other in host.ships where !other.isPlayer && leader(of: other) == ship.entityID {
            guard other.isAlive, !other.disabled, let o = records[other.entityID], o.maneuverTimer <= 0,
                  let ot = o.primary else { continue }
            if ot == World.playerEntityID { return true }
            if let t = host.ship(ot), leader(of: t) == World.playerEntityID { return true }
        }
        return false
    }

    /// `Ship_IsThreatenedByEnemyOfShip` (0x00410110).
    func isThreatenedByEnemy(_ ship: Ship, of context: Ship, host: OriginalAIHost) -> Bool {
        if ship.isPlayer {
            return host.ships.contains { other in
                !other.isPlayer && other.entityID != context.entityID && other.isAlive
                    && keepsPressing(other, host: host) && isEnemy(context, other, host: host)
            }
        }
        if keepsPressing(ship, host: host) { return true }
        return host.ships.contains { c in
            !c.isPlayer && c.isAlive && c.entityID != context.entityID && c.entityID != ship.entityID
                && isAttacking(c, ship, host: host) && isEnemy(context, c, host: host)
        }
    }

    // MARK: Strength and odds

    /// `Ship_ComputePerceivedCombatStrengthAgainstShip` (0x00411800): class
    /// Strength × shields clamped to 25–100 %, plus every supporter's Strength
    /// × its own clamped shields, doubled while that supporter is threatened.
    func perceivedStrength(_ ship: Ship, host: OriginalAIHost) -> Int {
        if let cached = strengthCache[ship.entityID] { return cached }
        let result = computePerceivedStrength(ship, host: host)
        strengthCache[ship.entityID] = result
        return result
    }

    private func computePerceivedStrength(_ ship: Ship, host: OriginalAIHost) -> Int {
        func ratio(_ s: Ship, fallback: Double) -> Double {
            let r = s.maxShield > 0 ? s.shield / s.maxShield : fallback
            return min(1, max(0.25, r))
        }
        let base = ratio(ship, fallback: ship.shield)
        var total = Int(Double(host.hull(of: ship).strength) * base)
        var scratch = base
        let selfLeaderGovt = ship.isPlayer ? host.playerInherentGovt : ship.government
        for c in host.ships where c.entityID != ship.entityID && c.isAlive {
            let strength = host.hull(of: c).strength
            var support = 0
            if leader(of: c) == ship.entityID {
                support = strength
            } else if host.areAllied(selfLeaderGovt, c.government) {
                support = strength
            }
            if c.maxShield > 0 { scratch = c.shield / c.maxShield }
            scratch = min(1, max(0.25, scratch))
            if support > 0, isThreatenedByEnemy(c, of: ship, host: host) {
                support = Int(Int16(truncatingIfNeeded: support * 2))
            }
            total = Int(Double(Int(Int16(truncatingIfNeeded: total))) + Double(support) * scratch)
        }
        return total
    }

    /// `Ship_UpdateShipCombatOddsScore` (0x004133f0): hostile over allied
    /// class Strength in the system, the player counted at their hull's
    /// Strength × clamp(rating / (class-0 Strength × 0x1900), 1, 2).
    func combatOdds(_ ship: Ship, host: OriginalAIHost) -> Double {
        var allied = host.hull(of: ship).strength
        var hostile = 0
        if isAttacking(host.player, ship, host: host) {
            let divisor = max(1, host.classZeroStrength * 0x1900)
            let scale = min(2, max(1, Double(host.playerCombatRating / divisor)))
            hostile = Int(Double(host.hull(of: host.player).strength) * scale)
        }
        for other in host.ships where !other.isPlayer && other.entityID != ship.entityID {
            guard other.isAlive, !other.disabled else { continue }
            let s = host.hull(of: other).strength
            if host.areAllied(other.government, ship.government) {
                allied = Int(Int16(truncatingIfNeeded: allied + s))
                continue
            }
            let o = records[other.entityID]
            if host.areHostile(other.government, ship.government)
                || (o?.primary == ship.entityID && o?.state == OriginalAIState.attack) {
                hostile = Int(Int16(truncatingIfNeeded: hostile + s))
            }
        }
        if allied == 0 { allied = 1 }
        return Double(hostile) / Double(allied)
    }

    // MARK: Hostility to the player

    /// `Ship_SetShipHostileToPlayer` (0x00410700).
    func setHostileToPlayer(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        if [OriginalAIState.departJump, OriginalAIState.retreat, OriginalAIState.squadJump].contains(rec.state),
           rec.mode == OriginalAIMode.jumpSpinUp || rec.mode == OriginalAIMode.squadJumpHold {
            rec.mode = OriginalAIMode.idle
        }
        rec.state = OriginalAIState.attack
        rec.secondary = .none
        rec.primary = World.playerEntityID
    }

    // MARK: Acquisition (Ship_AcquirePrimaryTargetForShip 0x0040e020)

    func acquirePrimaryTarget(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        // Keep a live target while attacking or retreating, at any distance.
        if let pid = rec.primary, rec.state == OriginalAIState.retreat || rec.state == OriginalAIState.attack,
           host.ship(pid)?.isAlive == true {
            return
        }
        let player = host.player
        if host.holdsGrudge(ship), canEngage(player, by: ship, host: host) {
            setHostileToPlayer(rec, ship: ship, host: host)
            return
        }
        if host.isMissionAttacker(ship), canEngage(player, by: ship, host: host) {
            setHostileToPlayer(rec, ship: ship, host: host)
            return
        }
        if host.ammoReadiness(ship) == 2 { return }

        let govt = host.govt(ship.government)

        // Join an allied ship's fight when its target fits MaxOdds.
        if let g = govt, !g.xenophobic, rec.behavior < 5 {
            for ally in host.ships where !ally.isPlayer && ally.entityID != ship.entityID && ally.isAlive {
                guard ally.government >= govtResourceBase, let a = records[ally.entityID],
                      let target = a.primary, let t = host.ship(target),
                      a.state == OriginalAIState.retreat || a.state == OriginalAIState.attack,
                      host.areAllied(ship.government, ally.government) else { continue }
                if target == World.playerEntityID || leader(of: t) == World.playerEntityID,
                   host.rankForbidsAutoAttack(ship.government) { continue }
                guard canEngage(t, by: ship, host: host) else { continue }
                let theirs = perceivedStrength(t, host: host)
                let ours = perceivedStrength(ship, host: host)
                if Double(theirs) > Double(ours) * g.maxOddsRatio { continue }
                rec.primary = target
                rec.state = OriginalAIState.attack
                return
            }
        }

        let lethal = host.hasLethalWeapon(ship)

        if let g = govt {
            var flagged = Set<Int>()
            let maxOdds = g.maxOddsRatio
            if !g.xenophobic {
                let radius = Double(Int16(truncatingIfNeeded: rec.cadence * 600))
                let playerNear = !host.rankForbidsAutoAttack(ship.government)
                    && Self.inBox(ship.position, player.position, radius)
                    && canEngage(player, by: ship, host: host) && player.isAlive
                if playerNear, g.flags1 & 0x0040 == 0, host.reputationFlagsPlayer(govt: ship.government) {
                    flagged.insert(World.playerEntityID)
                }
                // A 1-in-50 roll flags a player whose hull's inherent
                // government is hostile to this one.
                let inherent = host.playerInherentGovt
                if leader(of: ship) != World.playerEntityID, ship.missionID == nil, inherent >= govtResourceBase,
                   host.areHostile(ship.government, inherent), host.random(0x32) == 0,
                   player.isAlive, canEngage(player, by: ship, host: host) {
                    flagged.insert(World.playerEntityID)
                }
            } else {
                // Xenophobes scan everything in the system.
                var xeno = Set<Int>()
                for c in host.ships where c.isAlive && !c.disabled && canEngage(c, by: ship, host: host) {
                    if c.isPlayer {
                        // In its own system a reputation of 1 or more keeps
                        // the peace (AI-05, `system_reputation[player_system]`).
                        if g.flags1 & 0x0040 == 0, !host.rankForbidsAutoAttack(ship.government),
                           ship.government != host.systemGovernment || host.playerReputationHere < 1 {
                            xeno.insert(c.entityID)
                        }
                        continue
                    }
                    guard c.entityID != ship.entityID, leader(of: c) != ship.entityID,
                          records[c.entityID]?.defenseHome == nil,
                          !host.areAllied(ship.government, c.government),
                          isEnemy(ship, c, host: host) else { continue }
                    xeno.insert(c.entityID)
                }
                let ours = Double(Int(Int16(truncatingIfNeeded: perceivedStrength(ship, host: host))))
                xeno = xeno.filter { id in
                    guard let c = host.ship(id) else { return false }
                    return !(ours * maxOdds < Double(Int(Int16(truncatingIfNeeded: perceivedStrength(c, host: host)))))
                }
                if let best = nearest(xeno, to: ship, host: host) {
                    rec.primary = best
                    if best == World.playerEntityID { setHostileToPlayer(rec, ship: ship, host: host) }
                }
                flagged.formUnion(xeno)
            }

            if host.iffScrambled(ship.government) || host.rankForbidsAutoAttack(ship.government) {
                flagged.remove(World.playerEntityID)
            }

            // The common tail: every engageable enemy (a disabled one only
            // while this ship carries a lethal weapon), filtered by MaxOdds;
            // a squad leader prefers the heaviest, then the nearest.
            for c in host.ships where !c.isPlayer && c.entityID != ship.entityID {
                guard canEngage(c, by: ship, host: host), c.isAlive,
                      lethal || !c.disabled, isEnemy(ship, c, host: host) else { continue }
                flagged.insert(c.entityID)
            }
            if !flagged.isEmpty {
                let ours = Double(Int(Int16(truncatingIfNeeded: perceivedStrength(ship, host: host))))
                var passing: [Ship] = []
                var heaviest = -1
                for id in flagged.sorted() {
                    guard let c = host.ship(id) else { continue }
                    let theirs = Double(Int(Int16(truncatingIfNeeded: perceivedStrength(c, host: host))))
                    if ours * maxOdds < theirs { continue }
                    passing.append(c)
                    if rec.isSquadLeader { heaviest = max(heaviest, host.hull(of: c).mass) }
                }
                var bestDist = -1
                for c in passing {
                    if heaviest >= 0, host.hull(of: c).mass != heaviest { continue }
                    let d = Self.axisDistanceSquared(ship.position, c.position)
                    if bestDist < 0 || d < bestDist {
                        rec.primary = c.entityID
                        bestDist = d
                    }
                }
                if rec.primary == World.playerEntityID { setHostileToPlayer(rec, ship: ship, host: host) }
            }

            // Otherwise retaliate against the nearest ship attacking us.
            if rec.primary == nil {
                var bestDist = -1
                for c in host.ships where c.entityID != ship.entityID && c.isAlive {
                    guard canEngage(c, by: ship, host: host), isAttacking(c, ship, host: host) else { continue }
                    let d = Self.axisDistanceSquared(ship.position, c.position)
                    if bestDist < 0 || d < bestDist {
                        bestDist = d
                        rec.primary = c.entityID
                    }
                }
            }
        }

        // An escort with nothing to do picks the nearest ship attacking it.
        if rec.behavior == 6, rec.primary == nil {
            var best: Int?
            var bestDist = -1
            for c in host.ships where !c.isPlayer && c.isAlive && c.entityID != ship.entityID {
                if c.entityID == leader(of: ship) { continue }
                guard isAttacking(c, ship, host: host) else { continue }
                let d = Self.axisDistanceSquared(ship.position, c.position)
                if bestDist < 0 || d < bestDist { bestDist = d; best = c.entityID }
            }
            if let best {
                rec.primary = best
                rec.state = OriginalAIState.attack
            }
        }
    }

    private func nearest(_ ids: Set<Int>, to ship: Ship, host: OriginalAIHost) -> Int? {
        var best: Int?
        var bestDist = -1
        for id in ids.sorted() {
            guard let c = host.ship(id) else { continue }
            let d = Self.axisDistanceSquared(ship.position, c.position)
            if bestDist < 0 || d < bestDist { bestDist = d; best = id }
        }
        return best
    }

    // MARK: Travel stellars

    /// `Stellar_SelectRandomAdjacentTravelStellar` (0x0040c790): a uniformly
    /// random nav stellar that is inhabited, not hostile and passes the literal
    /// `x < 1000 && y < 1000` map test (no lower bound). A government with
    /// Flags2 0x80 / 0x40 always takes a wormhole / hypergate when one exists.
    /// `plainOnly` (interceptors) excludes gates.
    func selectTravelStellar(_ ship: Ship, host: OriginalAIHost, strict: Bool, plainOnly: Bool) -> Int? {
        let stellars = Array(host.stellars.prefix(16))
        guard !stellars.isEmpty else { return nil }
        let active = stellars.map { $0.mapX < 1000 && $0.mapY < 1000 }
        let uninhabited = stellars.map { $0.uninhabited && !$0.isGate }
        let hostile = stellars.map { s in
            ship.government >= govtResourceBase && s.government >= govtResourceBase
                && host.areHostile(ship.government, s.government)
        }
        let gate1000 = stellars.map(\.hypergate)
        let gate2000 = stellars.map(\.wormhole)
        var eligible = 0, plain = 0, count1000 = 0, count2000 = 0
        for i in stellars.indices {
            if gate1000[i], active[i], !hostile[i] { count1000 += 1 }
            if gate2000[i], active[i], !hostile[i] { count2000 += 1 }
            if active[i], !uninhabited[i], !hostile[i] {
                eligible += 1
                if !gate1000[i] && !gate2000[i] { plain += 1 }
            }
        }
        let flags2 = host.govt(ship.government).map { Int($0.flags2) } ?? 0
        let mask20 = flags2 & 0x20 != 0
        let prefer1000 = flags2 & 0x40 != 0
        let prefer2000 = flags2 & 0x80 != 0

        func pick(_ accept: (Int) -> Bool) -> Int? {
            // Rejection sampling over the 16 nav slots, as the original; the
            // bound guards contradictory data the original would spin on.
            for _ in 0..<0x100 {
                let slot = host.random(16)
                if slot < stellars.count, accept(slot) { return stellars[slot].id }
            }
            return stellars.indices.first(where: accept).map { stellars[$0].id }
        }

        if plainOnly {
            guard plain >= 1 else { return nil }
            return pick { active[$0] && !gate1000[$0] && !gate2000[$0] && !hostile[$0] && !uninhabited[$0] }
        }
        if prefer2000 && count2000 > 0 {
            return pick { active[$0] && gate2000[$0] && !hostile[$0] }
        }
        if prefer1000 && count1000 > 0 {
            return pick { active[$0] && gate1000[$0] && !hostile[$0] }
        }
        if eligible < 1 || !strict || mask20 || (plain < 1 && count1000 < 1) {
            if eligible < 1 || (plain < 1 && (count1000 < 1 || mask20)) { return nil }
            return pick { i in
                active[i] && !uninhabited[i] && !hostile[i] && (!gate2000[i] || prefer2000) && (!gate1000[i] || !mask20)
            }
        }
        return pick { active[$0] && !uninhabited[$0] && !hostile[$0] && !gate2000[$0] }
    }

    /// `Stellar_FindNearestAdjacentTravelStellar` (0x0040cc10), the miners'
    /// wander target.
    func nearestTravelStellar(_ ship: Ship, excluding: Int, host: OriginalAIHost) -> Int? {
        var best: Int?
        var bestD = 0.0
        for s in host.stellars.prefix(16) where !s.isGate && s.id != excluding {
            if ship.government >= govtResourceBase, s.government >= govtResourceBase,
               host.areHostile(ship.government, s.government) { continue }
            let d = s.position - ship.position
            let d2 = d.x * d.x + d.y * d.y
            if best == nil || d2 < bestD { best = s.id; bestD = d2 }
        }
        return best
    }

    // MARK: Swarming (shïp Flags2 0x0001)

    /// `Ship_FindSwarmMate` (0x00411c20): the first lower-slot swarming hull
    /// sharing this ship's target and its government or leader.
    func findSwarmMate(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        rec.swarmMate = nil
        guard ship.entityID > 1 else { return }
        for other in host.ships where !other.isPlayer && other.entityID < ship.entityID && other.isAlive {
            guard host.hull(of: other).flags2 & 0x0001 != 0,
                  records[other.entityID]?.primary == rec.primary else { continue }
            let sameGovt = ship.government == other.government && ship.government >= govtResourceBase
            let sameLeader = leader(of: ship) != nil && leader(of: ship) == leader(of: other)
            if sameGovt || sameLeader {
                rec.swarmMate = other.entityID
                return
            }
        }
    }

    /// `Ship_IsSwarmMateStillValid` (0x00411b40). A non-swarming hull reports
    /// valid so its cache is left alone.
    func swarmMateStillValid(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) -> Bool {
        guard host.hull(of: ship).flags2 & 0x0001 != 0 else { return true }
        guard let mate = rec.swarmMate, mate > 0, mate < ship.entityID, let other = host.ship(mate),
              other.isAlive, host.hull(of: other).flags2 & 0x0001 != 0,
              records[mate]?.primary == rec.primary else { return false }
        let sameGovt = ship.government == other.government && ship.government >= govtResourceBase
        let sameLeader = leader(of: ship) != nil && leader(of: ship) == leader(of: other)
        return sameGovt || sameLeader
    }

    /// `Ship_ShouldFollowSwarmMate` (0x00411ae0).
    func followsSwarmMate(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) -> Bool {
        guard host.hull(of: ship).flags2 & 0x0001 != 0, rec.defenseHome == nil else { return false }
        if let mate = rec.swarmMate, mate > 0, mate != leader(of: ship) {
            rec.mode = OriginalAIMode.swarm
            return true
        }
        return false
    }

    // MARK: Pursuit

    /// `Ship_CanTargetOutrunShooter` (0x00410f20): a target retreating (or
    /// the player) moving away faster than this ship.
    func targetCanOutrun(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) -> Bool {
        guard let pid = rec.primary, let target = host.ship(pid), target.isAlive else { return false }
        if !target.isPlayer, records[pid]?.state != OriginalAIState.retreat { return false }
        let ourHull = host.hull(of: ship), theirHull = host.hull(of: target)
        guard ourHull.mass >= 100 else { return false }
        let rel = (target.velocity - ship.velocity) * (1 / OriginalClock.ticksPerSecond)
        if abs(rel.x) <= 0.35 && abs(rel.y) <= 0.35 { return false }
        let relBearing = Int(Self.bearingDeg(Vec2(), rel))
        let away = Int(Self.bearingDeg(target.position, ship.position))
        // The original subtracts the integer bearings without wrapping.
        if abs(relBearing - away) < 90 { return false }
        // The class base speeds, before skill variance.
        let ourSpeed = ourHull.speed, theirSpeed = theirHull.speed
        return host.hasInterceptingGuidedBank(ship, against: target) ? ourSpeed < theirSpeed : ourSpeed <= theirSpeed
    }

    // MARK: Escort targets

    /// `Ship_ScoreAssistTargetForShip` (0x00412090): `candidate` as a target
    /// for `helper`, 0 if ineligible, otherwise smaller is better.
    func assistScore(_ candidate: Ship, helper: Ship, radius: Int, host: OriginalAIHost) -> Int {
        guard let helperLeaderID = leader(of: helper), let helperLeader = host.ship(helperLeaderID) else { return 0 }
        let candLeader = leader(of: candidate)
        guard candidate.entityID != helper.entityID, candidate.entityID != candLeader,
              candidate.entityID != helperLeaderID, candLeader != helperLeaderID || candLeader == nil,
              candidate.isAlive, canEngage(candidate, by: helper, host: host) else { return 0 }
        if candidate.disabled, (records[candidate.entityID]?.escortCommand ?? -1) != 2 { return 0 }
        let context = helperLeaderID == World.playerEntityID
            ? keepsPressing(candidate, host: host)
            : isAttacking(candidate, helperLeader, host: host)
        guard context else { return 0 }
        let toLeader = Self.truncatedDistanceSquared(helperLeader.position, candidate.position)
        if radius > 0, toLeader > Double(radius * radius) { return 0 }
        var score = Int(Self.truncatedDistanceSquared(helper.position, candidate.position) + (radius > 0 ? toLeader : 0))
        let cc = host.hull(of: candidate).escortClass, hc = host.hull(of: helper).escortClass
        if cc != hc {
            score = (score + 1) / 2
            if cc == 0 && hc == 2 { score = (score + 1) / 2 }
        }
        return max(score, 1)
    }

    static func truncatedDistanceSquared(_ a: Vec2, _ b: Vec2) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y).rounded(.towardZero)
    }

    /// `Ship_FindBestAssistTargetForShip` (0x00412030): radius 0x226 (550 px)
    /// for Defend, −1 (unlimited) for Attack.
    func bestAssistTarget(_ helper: Ship, radius: Int, host: OriginalAIHost) -> Int? {
        var best: Int?
        var bestScore = Int.max
        for c in host.ships {
            let s = assistScore(c, helper: helper, radius: radius, host: host)
            if s > 0 && s < bestScore { bestScore = s; best = c.entityID }
        }
        return best
    }

    /// `Ship_EnterShipAiState0x04_TargetRandomRelativeToSquadLeader`
    /// (0x00410900): a uniformly random same-system ship pressing the leader's
    /// squad. A formation escort uses it only to pick a turret target.
    func randomTargetPressingLeader(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        let leaderID = leader(of: ship)
        let leaderShip = leaderID.flatMap { host.ship($0) }
        let candidates = host.ships.filter { c in
            guard c.entityID != ship.entityID, c.entityID != leaderID, c.isAlive, !c.disabled else { return false }
            if c.isPlayer { return leaderShip.map { keepsPressing($0, host: host) } ?? false }
            if leaderID == World.playerEntityID { return keepsPressing(c, host: host) }
            return leaderShip.map { isAttacking(c, $0, host: host) } ?? false
        }
        guard !candidates.isEmpty else {
            rec.primary = nil
            return
        }
        rec.secondary = .none
        rec.primary = candidates[slotPick(count: candidates.count, host: host)].entityID
        rec.state = OriginalAIState.attack
    }

    /// `Ship_EscortFireAtUnprovokedTarget` (0x00411540): an escort keeps its
    /// turrets on a live, enabled primary target.
    func escortFire(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        guard rec.behavior >= 5, let pid = rec.primary else { return }
        guard let target = host.ship(pid), target.isAlive, !target.disabled else {
            rec.primary = nil
            return
        }
        rec.fire.insert(.turret)
    }

    // MARK: Geometry

    /// Compass bearing (0 = up, clockwise) from `a` to `b`, in degrees [0, 360).
    static func bearingDeg(_ a: Vec2, _ b: Vec2) -> Double {
        let d = b - a
        if d.x == 0 && d.y == 0 { return 0 }
        var deg = atan2(d.x, d.y) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    static func headingDeg(_ ship: Ship) -> Double {
        var deg = (ship.angle * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        return deg
    }

    /// Signed shortest angle from `from` to `to`, degrees in [−180, 180].
    static func deltaDeg(from: Double, to: Double) -> Double {
        remainder(to - from, 360)
    }

    static func wrapDeg(_ deg: Int) -> Int {
        let d = deg % 360
        return d < 0 ? d + 360 : d
    }
}
