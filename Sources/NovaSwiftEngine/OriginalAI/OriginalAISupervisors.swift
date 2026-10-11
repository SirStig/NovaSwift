import Foundation
import NovaSwiftKit

/// The behavior supervisors `Ship_UpdateShipAI` dispatches to: they choose the
/// state; the state machine chooses the control mode.
extension OriginalAI {

    private func busyElsewhere(_ rec: OriginalAIShipState) -> Bool {
        rec.state == OriginalAIState.refuel || rec.state == OriginalAIState.repair
            || rec.state == OriginalAIState.yield
    }

    /// Whether the ship last stopped at a stellar still in this system.
    private func stillAtStellar(_ rec: OriginalAIShipState, host: OriginalAIHost) -> Bool {
        rec.jumpDestination >= 0 && host.stellars.contains { $0.id == rec.jumpDestination }
    }

    /// Jump out when the hull can, else park.
    func departOrPark(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        if host.canJump(ship) {
            rec.enterDeparture(clock60: clock60)
        } else {
            rec.state = OriginalAIState.park
        }
    }

    /// `NovaAi_ReacquireTravelOrSettle`, the idle ladder every disposition
    /// shares: pick a random nav stellar and travel to it; once stopped at
    /// one, jump out (or park without fuel).
    func reacquireTravelOrSettle(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        let atStellar = stillAtStellar(rec, host: host)
        if !atStellar {
            rec.secondary = selectTravelStellar(ship, host: host, strict: false, plainOnly: false)
                .map(OriginalAIRef.stellar) ?? .none
        }
        if rec.secondary == .none {
            departOrPark(rec, ship: ship, host: host)
        } else if !atStellar {
            rec.state = OriginalAIState.travel
        } else {
            departOrPark(rec, ship: ship, host: host)
        }
    }

    // MARK: 1 · Wimpy trader (0x00402860)

    func wimpyTrader(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        guard !busyElsewhere(rec) else { return }
        if rec.state == OriginalAIState.idle {
            if stillAtStellar(rec, host: host) {
                departOrPark(rec, ship: ship, host: host)
            } else {
                rec.secondary = selectTravelStellar(ship, host: host, strict: false, plainOnly: false)
                    .map(OriginalAIRef.stellar) ?? .none
                if rec.secondary == .none {
                    departOrPark(rec, ship: ship, host: host)
                } else {
                    rec.state = OriginalAIState.travel
                }
            }
        }
        // Traders never look for a fight: only damage taken escalates them.
        if rec.hostility > 0, rec.primary != nil {
            if leader(of: ship) == World.playerEntityID {
                rec.state = OriginalAIState.escortStation
                rec.secondary = .ship(World.playerEntityID)
            } else {
                rec.state = OriginalAIState.retreat
            }
        }
        if rec.state == OriginalAIState.retreat { distressCall(ship, host: host) }
    }

    // MARK: 2 · Brave trader (0x00402bd0)

    func braveTrader(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        guard !busyElsewhere(rec) else { return }
        if rec.state == OriginalAIState.idle {
            reacquireTravelOrSettle(rec, ship: ship, host: host)
        }
        if rec.hostility > 0, let pid = rec.primary, let target = host.ship(pid) {
            // Fights back only inside a 1251 px box (0x4e3), else runs.
            let d = target.position - ship.position
            if abs(d.x) < 1251 && abs(d.y) < 1251 && rec.jumpTimer <= 0 {
                rec.state = OriginalAIState.attack
            } else if leader(of: ship) == World.playerEntityID {
                rec.state = OriginalAIState.escortStation
                rec.secondary = .ship(World.playerEntityID)
            } else {
                rec.state = OriginalAIState.retreat
            }
        }
        if rec.state == OriginalAIState.retreat {
            distressCall(ship, host: host)
            host.tryAssistanceEncounter(ship, odds: rec.odds)
        } else if rec.state == OriginalAIState.attack, let pid = rec.primary, pid != World.playerEntityID,
                  (records[pid]?.behavior ?? 0) > 2 {
            // Fighting back against a warship: call for help too.
            distressCall(ship, host: host)
        }
    }

    // MARK: Government arrival window, shared by 3 and 4

    /// Inside the arrival window `(−900, 0]` of the jump timer: a government
    /// that never attacks the player (Flags 0x0040) drops a player threat; one
    /// that always does (0x0004) turns on an engageable player.
    private func governmentArrivalWindow(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        guard rec.jumpTimer > -900, rec.jumpTimer <= 0, let g = host.govt(ship.government) else { return }
        if g.flags1 & 0x0004 == 0 {
            if g.flags1 & 0x0040 != 0, isThreatToPlayerSquad(rec, ship: ship, host: host) {
                rec.primary = nil
                rec.state = OriginalAIState.idle
            }
        } else if !isThreatToPlayerSquad(rec, ship: ship, host: host),
                  canEngage(host.player, by: ship, host: host) {
            setHostileToPlayer(rec, ship: ship, host: host)
            rec.hostility = 1
        }
    }

    /// The low-shield odds retreat (warships with govt Flags 0x0010,
    /// interceptors with 0x0100): below half shields with odds above MaxOdds,
    /// doubled while an allied reinforcement fleet is cooling down.
    private func oddsRetreat(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost, govtFlag: UInt16) {
        guard rec.primary != nil, rec.state == OriginalAIState.attack,
              let g = host.govt(ship.government), g.flags1 & govtFlag != 0 else { return }
        guard Double(ship.shield) < ship.maxShield * 0.5, rec.odds >= 0 else { return }
        // AI-13: the threshold doubles while an allied ReinfFleet's
        // countdown runs.
        let threshold = host.reinforcementInbound(alliedWith: ship.government) ? g.maxOddsRatio * 2 : g.maxOddsRatio
        if threshold < rec.odds { rec.state = OriginalAIState.retreat }
    }

    // MARK: 3 · Warship (0x00402e50)

    func warship(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        guard !busyElsewhere(rec) else { return }
        governmentArrivalWindow(rec, ship: ship, host: host)

        if rec.mode == OriginalAIMode.jumpSpinUp, rec.state != OriginalAIState.departJump,
           rec.state != OriginalAIState.squadJump {
            rec.state = OriginalAIState.departJump
        }

        if rec.state == OriginalAIState.idle {
            if rec.primary == nil {
                if rec.jumpTimer <= 0 {
                    acquirePrimaryTarget(rec, ship: ship, host: host)
                    if rec.primary == nil {
                        reacquireTravelOrSettle(rec, ship: ship, host: host)
                    } else {
                        rec.state = OriginalAIState.attack
                    }
                    // The original runs the ladder a second time when the
                    // first pass left no target.
                    if rec.primary == nil { reacquireTravelOrSettle(rec, ship: ship, host: host) }
                }
            } else if rec.jumpTimer <= 0 {
                rec.state = OriginalAIState.attack
            }
        }

        if rec.hostility > 0, rec.primary != nil, rec.state != OriginalAIState.scanApproach,
           rec.state != OriginalAIState.retreat, rec.jumpTimer <= 0 {
            rec.state = OriginalAIState.attack
        }

        if [OriginalAIState.travel, OriginalAIState.gateEntry, OriginalAIState.departJump].contains(rec.state) {
            if rec.primary == nil {
                if rec.jumpTimer <= 0 {
                    acquirePrimaryTarget(rec, ship: ship, host: host)
                    if rec.primary != nil { rec.state = OriginalAIState.attack }
                }
            } else if rec.jumpTimer <= 0 {
                rec.state = OriginalAIState.attack
            }
        }

        if rec.state == OriginalAIState.park {
            rec.primary = nil
            acquirePrimaryTarget(rec, ship: ship, host: host)
            if rec.primary == nil {
                let fightersOut = host.ships.contains { other in
                    other.isAlive && leader(of: other) == ship.entityID && !other.disabled
                        && records[other.entityID]?.behavior == 5 && records[other.entityID]?.defenseHome == nil
                }
                if !fightersOut { rec.state = OriginalAIState.idle }
            }
        }

        // An armed warship keeps shooting a disabled target; one with only
        // disabling weapons gives up on it.
        if let pid = rec.primary, rec.state == OriginalAIState.attack {
            let target = host.ship(pid)
            if target == nil || !target!.isAlive || (target!.disabled && !host.hasLethalWeapon(ship)) {
                rec.state = OriginalAIState.idle
                rec.primary = nil
            }
        }

        oddsRetreat(rec, ship: ship, host: host, govtFlag: 0x0010)
        cowardiceAndAmmo(rec, ship: ship, host: host)

        if rec.state == OriginalAIState.departJump, !host.canJump(ship) {
            rec.secondary = selectTravelStellar(ship, host: host, strict: false, plainOnly: false)
                .map(OriginalAIRef.stellar) ?? .none
            rec.state = rec.secondary == .none ? OriginalAIState.park : OriginalAIState.travel
        }

        if rec.state == OriginalAIState.attack, host.ammoReadiness(ship) == 2 {
            rec.standDown()
        }
    }

    /// The shield / përs-cowardice / ammo-out disengage of 0x00402e50.
    private func cowardiceAndAmmo(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        guard rec.primary != nil, rec.state != OriginalAIState.scanApproach,
              rec.state != OriginalAIState.retreat else { return }
        if rec.jumpTimer <= 0 { rec.state = OriginalAIState.attack }

        let maxShield = ship.maxShield
        var threshold = -0x7fff
        if let coward = ship.brain?.personCoward, ship.personID != nil {
            threshold = Int((Double(coward) * 0.01 * maxShield).rounded())
        } else if ship.personID == nil {
            if rec.cadence == 1 { threshold = Int((maxShield * 0.3).rounded()) }
            if rec.cadence == 2 { threshold = Int((maxShield * 0.15).rounded()) }
        }
        let retreatable = rec.state != OriginalAIState.departJump && rec.state != OriginalAIState.retreat
            && rec.state != OriginalAIState.squadJump
        if ship.shield < Double(threshold), leader(of: ship) == nil,
           let g = host.govt(ship.government), g.flags1 & 0x0010 != 0, retreatable {
            rec.state = OriginalAIState.retreat
        }
        if host.hull(of: ship).flags2 & 0x0080 != 0, host.ammoReadiness(ship) != 0,
           rec.state != OriginalAIState.departJump, rec.state != OriginalAIState.retreat,
           rec.state != OriginalAIState.squadJump {
            rec.state = OriginalAIState.retreat
        }
    }

    // MARK: 4 · Interceptor (0x00403de0)

    func interceptor(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        guard rec.state != OriginalAIState.yield,
              rec.state != OriginalAIState.refuel, rec.state != OriginalAIState.repair else { return }
        governmentArrivalWindow(rec, ship: ship, host: host)

        if rec.hostility > 0, rec.primary != nil,
           ![OriginalAIState.retreat, OriginalAIState.scanApproach,
             OriginalAIState.refuel, OriginalAIState.repair].contains(rec.state), rec.jumpTimer <= 0 {
            rec.state = OriginalAIState.attack
        }

        if let cached = rec.cachedScanTarget, !(host.ship(cached)?.isAlive ?? false) {
            rec.cachedScanTarget = nil
        }

        if [OriginalAIState.idle, OriginalAIState.travel, OriginalAIState.gateEntry].contains(rec.state),
           rec.maneuverTimer <= 0 {
            if rec.primary == nil {
                acquirePrimaryTarget(rec, ship: ship, host: host)
                if rec.primary != nil, rec.jumpTimer <= 0 { rec.state = OriginalAIState.attack }
            } else if rec.jumpTimer <= 0, let pid = rec.primary, host.ship(pid)?.isAlive == true, rec.hostility > 0 {
                rec.state = OriginalAIState.attack
            }

            if rec.primary == nil {
                // A uniformly random same-system ship to scan — the player is
                // just one candidate — excluding interceptors and the last mark.
                let candidates = host.ships.filter { other in
                    other.entityID != ship.entityID && other.isAlive && other.entityID != rec.cachedScanTarget
                        && records[other.entityID]?.behavior != 4
                        && canEngage(other, by: ship, host: host)
                }
                if !candidates.isEmpty {
                    let pick = candidates[slotPick(count: candidates.count, host: host)]
                    rec.primary = pick.entityID
                    rec.cachedScanTarget = pick.entityID
                    rec.state = OriginalAIState.scanApproach
                    if pick.isPlayer { scanWarning(ship, host: host) }
                }
            }

            if rec.primary == nil, rec.state == OriginalAIState.idle {
                rec.jumpDestination = -2
                if let stellar = selectTravelStellar(ship, host: host, strict: false, plainOnly: true) {
                    rec.secondary = .stellar(stellar)
                    rec.state = OriginalAIState.travel
                } else {
                    departOrPark(rec, ship: ship, host: host)
                }
            }
        }

        oddsRetreat(rec, ship: ship, host: host, govtFlag: 0x0100)

        if let pid = rec.primary, rec.state == OriginalAIState.attack,
           let target = host.ship(pid), target.disabled, !host.hasLethalWeapon(ship) {
            rec.primary = nil
            rec.state = OriginalAIState.idle
        }

        if host.hull(of: ship).flags2 & 0x0080 != 0, host.ammoReadiness(ship) != 0,
           ![OriginalAIState.departJump, OriginalAIState.retreat, OriginalAIState.squadJump].contains(rec.state) {
            rec.state = OriginalAIState.retreat
        }

        if let pid = rec.primary, rec.state == OriginalAIState.scanApproach,
           let target = host.ship(pid), !canEngage(target, by: ship, host: host) {
            rec.standDown()
        }

        // While closing to scan, a real contact takes over; otherwise the
        // scan mark is kept.
        if let saved = rec.primary, ship.government >= govtResourceBase,
           rec.state == OriginalAIState.scanApproach {
            acquirePrimaryTarget(rec, ship: ship, host: host)
            if rec.primary == nil {
                rec.primary = saved
                rec.state = OriginalAIState.scanApproach
            }
        }
    }

    /// The original draws `Rand(0x40)` slots until one is eligible, which is
    /// uniform over the eligible set. The port draws once over the list.
    func slotPick(count: Int, host: OriginalAIHost) -> Int {
        guard count > 1 else { return 0 }
        return host.random(count)
    }

    // MARK: 3 · Plunderer (0x004038b0, govt Flags 0x1000)

    func plunderer(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        guard rec.state != OriginalAIState.yield else { return }
        if let pid = rec.primary, !(host.ship(pid)?.isAlive ?? false) {
            rec.primary = nil
            rec.state = OriginalAIState.idle
        }

        if rec.state == OriginalAIState.idle || (rec.primary == nil && rec.state != OriginalAIState.coast) {
            rec.primary = nil
            selectNearestDisabledForBoarding(rec, ship: ship, host: host)
            if rec.primary == nil { acquirePrimaryTarget(rec, ship: ship, host: host) }
            if rec.primary == nil {
                if !stillAtStellar(rec, host: host) {
                    if rec.secondary == .none {
                        rec.secondary = selectTravelStellar(ship, host: host, strict: false, plainOnly: false)
                            .map(OriginalAIRef.stellar) ?? .none
                        if rec.secondary == .none {
                            departOrPark(rec, ship: ship, host: host)
                        } else {
                            rec.state = OriginalAIState.travel
                        }
                    } else {
                        departOrPark(rec, ship: ship, host: host)
                    }
                } else {
                    departOrPark(rec, ship: ship, host: host)
                }
            } else if let target = host.ship(rec.primary!) {
                rec.state = capturable(target, host: host) ? OriginalAIState.board : OriginalAIState.attack
            }
        }

        if let pid = rec.primary, rec.state == OriginalAIState.board || rec.state == OriginalAIState.attack,
           let target = host.ship(pid) {
            if capturable(target, host: host) {
                if !isBoarded(pid) {
                    rec.state = OriginalAIState.board
                } else {
                    rec.state = OriginalAIState.attack
                    // Yield to a competitor already boarding the same victim.
                    let competitor = host.ships.contains { other in
                        guard other.entityID != ship.entityID, other.entityID != pid, !other.isPlayer,
                              other.isAlive, !other.disabled, leader(of: other) != World.playerEntityID,
                              let o = records[other.entityID], o.primary == pid else { return false }
                        return o.state == OriginalAIState.board || o.mode == OriginalAIMode.combatBrake
                    }
                    if competitor {
                        rec.state = OriginalAIState.yield
                        rec.mode = OriginalAIMode.idle
                        rec.primary = nil
                        rec.secondary = .none
                        rec.hostility = 0
                        rec.maneuverTimer = 120
                    }
                }
            } else {
                rec.state = OriginalAIState.attack
            }
        }

        // The approach finished (mode 0xf) and the pause ran out: board.
        if rec.state == OriginalAIState.attack, rec.mode == OriginalAIMode.boardHold,
           let victimID = rec.secondary.shipID, rec.maneuverTimer <= 0, let victim = host.ship(victimID) {
            rec.maneuverTimer = 100
            rec.state = OriginalAIState.coast
            rec.mode = OriginalAIMode.idle
            rec.defenseHome = nil
            host.board(victim, by: ship)
            rec.primary = nil
            rec.secondary = .none
        }

        if rec.state == OriginalAIState.attack, let pid = rec.primary, let target = host.ship(pid),
           target.disabled, host.hull(of: target).inherentAI > 2, !target.isPlayer,
           !host.hasLethalWeapon(ship) || host.ammoReadiness(ship) == 2 {
            rec.state = OriginalAIState.idle
            rec.primary = nil
        }

        if rec.state == OriginalAIState.attack || rec.state == OriginalAIState.board,
           host.ammoReadiness(ship) == 2 {
            rec.standDown()
        }
    }

    /// The player, or a hull of trader AI (< 3) with a crew, can be captured.
    private func capturable(_ target: Ship, host: OriginalAIHost) -> Bool {
        let hull = host.hull(of: target)
        let kind = target.isPlayer || hull.inherentAI < 3
        return kind && hull.crew > 0
    }

    /// `Ship_SelectNearestDisabledShipForBoarding` (0x00412330).
    func selectNearestDisabledForBoarding(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        let lethal = host.hasLethalWeapon(ship)
        var best: Ship?
        var bestD = 0.0
        for c in host.ships where c.entityID != ship.entityID {
            guard leader(of: c) != ship.entityID, c.isAlive, !isBoarded(c.entityID),
                  c.disabled, c.missionID == nil else { continue }
            let hull = host.hull(of: c)
            let lowAI = (records[c.entityID]?.behavior ?? hull.inherentAI) < 3 || hull.inherentAI < 3
                || c.formerWingRole != nil
            guard c.isPlayer || lowAI || lethal, hull.crew > 0 else { continue }
            if leader(of: c) != World.playerEntityID, host.areAllied(ship.government, c.government) { continue }
            let d = c.position - ship.position
            let d2 = (d.x * d.x + d.y * d.y).rounded(.towardZero)
            if best == nil || d2 < bestD { best = c; bestD = d2 }
        }
        if let best {
            rec.primary = best.entityID
            rec.state = OriginalAIState.board
            rec.mode = OriginalAIMode.idle
        }
    }

    // MARK: Defense fleet (0x00405120)

    func defenseFleet(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        guard rec.state != OriginalAIState.yield else { return }
        var best: Ship?
        var bestD = -1.0
        // Nearest player-side ship within 6000 px first, then anywhere.
        for pass in 0..<2 where best == nil {
            for c in host.ships where c.isAlive {
                guard c.isPlayer || leader(of: c) == World.playerEntityID,
                      canEngage(c, by: ship, host: host) else { continue }
                let d = c.position - ship.position
                let d2 = d.x * d.x + d.y * d.y
                if pass == 0 && !(d2 <= 36_000_000) { continue }
                if best != nil && !(d2 < bestD) { continue }
                bestD = d2.rounded(.towardZero)
                best = c
            }
        }
        rec.maneuverTimer = 0
        rec.secondary = .none
        if let pid = rec.primary, !(host.ship(pid).map { canEngage($0, by: ship, host: host) } ?? false) {
            rec.primary = nil
        }
        if rec.primary == nil {
            if let best {
                rec.primary = best.entityID
                rec.state = OriginalAIState.attack
            } else if let home = rec.defenseHome {
                rec.secondary = .stellar(home)
                rec.state = OriginalAIState.travel
            }
        }
        if let pid = rec.primary, pid != World.playerEntityID, let p = host.ship(pid),
           leader(of: p) != World.playerEntityID {
            if let best {
                rec.primary = best.entityID
            } else {
                rec.standDown()
            }
        }
    }

    // MARK: Asteroid miner (0x00402980)

    func asteroidMiner(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        guard rec.state != OriginalAIState.yield else { return }
        let hull = host.hull(of: ship)
        let destroys = hull.flags3 & 0x0001 != 0
        let scoops = hull.flags3 & 0x0002 != 0
        guard rec.hostility < 1 || rec.primary == nil else {
            rec.state = OriginalAIState.retreat
            distressCall(ship, host: host)
            return
        }
        var wander = !destroys && !scoops
        if destroys && rec.state != OriginalAIState.departJump {
            if host.firstAsteroid != nil {
                rec.state = OriginalAIState.asteroid
            } else {
                rec.primary = nil
                rec.secondary = .none
                rec.state = OriginalAIState.park
            }
        }
        if scoops {
            if !ship.hasMiningScoop {
                wander = true
            } else if ship.cargoUsed < max(1, ship.cargoCapacity) {
                // Boxes adrift (OS-11): go and scoop them (state 0x11).
                if !host.freeflightPositions.isEmpty {
                    rec.state = OriginalAIState.debris
                } else if destroys {
                    rec.state = OriginalAIState.asteroid
                } else {
                    wander = true
                }
            } else {
                rec.enterDeparture(clock60: clock60)
            }
        }
        if wander {
            if rec.maneuverTimer > 0 {
                rec.secondary = .none
                rec.state = OriginalAIState.idle
            } else {
                if rec.secondary == .none {
                    rec.secondary = nearestTravelStellar(ship, excluding: rec.jumpDestination, host: host)
                        .map(OriginalAIRef.stellar) ?? .none
                }
                if rec.secondary == .none || rec.state == OriginalAIState.departJump
                    || rec.state == OriginalAIState.retreat {
                    departOrPark(rec, ship: ship, host: host)
                } else {
                    rec.state = OriginalAIState.travel
                    if let s = rec.secondary.stellarID { rec.jumpDestination = s }
                }
            }
        }
    }
}

// MARK: - Broadcasts (AI-32)

extension OriginalAI {

    /// `Ship_ShowPlayerInterceptTauntIfEligible` (0x004112c0), in truth a
    /// distress call: a non-përs ship whose government (and hull inherent
    /// government) lacks flags_secondary 0x08, that likes the player and is
    /// not attacking them, uncloaked, with the player alive and no overlay
    /// message up, flashes "<class>: <STR# 5003 line>" for 240 frames. Ships
    /// call it every tick they retreat; the overlay gate keeps it to one.
    func distressCall(_ ship: Ship, host: OriginalAIHost) {
        guard ship.personID == nil, let world = (host as? WorldAIHost)?.world,
              world.overlayTicks < 1, let game = world.galaxy?.game else { return }
        if let g = host.govt(ship.government), g.flags2 & 0x0008 != 0 { return }
        let inherent = host.hull(of: ship).inherentCombatGovt
        if inherent >= govtResourceBase, let g = host.govt(inherent), g.flags2 & 0x0008 != 0 { return }
        guard likesPlayer(ship, host: host, world: world), !isAttacking(ship, host.player, host: host),
              host.player.isAlive, ship.cloakLevel <= 0 else { return }
        let line = game.stringList(5003)?.string(at: host.random(20) + 1) ?? ""
        // The distress call sounds snd 154 (0x004112c0).
        world.postOverlayMessage(Self.broadcastName(ship, game: game) + ":  " + line, frames: 240, beep: 154)
    }

    /// The interceptor's scan warning (0x00403de0): picking the player as its
    /// scan mark while the player carries mission cargo whose ScanMask
    /// matches the interceptor's government, with no overlay up, it flashes
    /// "<class>: <pilot>, prepare to be scanned!" (STR# 2002 #381–#383) for
    /// 400 frames.
    func scanWarning(_ ship: Ship, host: OriginalAIHost) {
        guard let world = (host as? WorldAIHost)?.world, world.overlayTicks < 0,
              let game = world.galaxy?.game, let g = host.govt(ship.government),
              Contraband.matches(world.missionCargoScanMask, g.scanMask) else { return }
        let list = game.stringList(2002)
        let line = list?.string(at: 381 + host.random(3)) ?? ""
        // The scan warning sounds snd 154 (0x00403de0).
        world.postOverlayMessage(Self.broadcastName(ship, game: game) + ":  " + world.pilotName + ", " + line + "!",
                                 frames: 400, beep: 154)
    }

    /// The class name a broadcast speaks with (shïp +0x6c), or a mission
    /// ship's ShipName.
    static func broadcastName(_ ship: Ship, game: NovaGame) -> String {
        if ship.missionID != nil, let name = ship.displayName, !name.isEmpty { return name }
        return game.ship(ship.shipTypeID)?.name ?? ship.name
    }
}

