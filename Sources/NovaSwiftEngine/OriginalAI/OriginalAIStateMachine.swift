import Foundation

/// `Ship_UpdateShipAiState` (0x00405590): each state picks this frame's
/// control mode, and a few states finish themselves (arrivals, gate entry,
/// fuel transfer, scans).
extension OriginalAI {

    /// The ship's class turn in degrees per tick (`Maneuver × 0.1`).
    static func turnDeg(_ ship: Ship) -> Double {
        ship.effectiveTurnRate * 180 / .pi / OriginalClock.ticksPerSecond
    }

    static func velocityPerTick(_ ship: Ship) -> Vec2 {
        ship.velocity * (1 / OriginalClock.ticksPerSecond)
    }

    /// Both velocity axes under 0.35 px/tick.
    static func stopped(_ ship: Ship) -> Bool {
        let v = velocityPerTick(ship)
        return abs(v.x) < 0.35 && abs(v.y) < 0.35
    }

    /// Within 1000 px of the system centre (0, 0).
    static func nearCentre(_ ship: Ship) -> Bool {
        ship.position.x * ship.position.x + ship.position.y * ship.position.y <= 1_000_000
    }

    static func damp(_ ship: Ship, _ k: Double) {
        ship.velocity = ship.velocity * k
        ship.throttleSpeed *= k
    }

    func updateState(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost, ticks: Double) {
        let S = OriginalAIState.self, M = OriginalAIMode.self

        if rec.state == S.yield {
            if rec.maneuverTimer <= 0 {
                rec.state = S.idle
                rec.mode = M.idle
            } else {
                rec.fire = []
                rec.primary = nil
                rec.secondary = .none
                rec.mode = M.brake
                return
            }
        }

        // A positive maneuver timer suspends every state but 0x0a and 0x0e.
        if rec.maneuverTimer > 0, rec.state != S.escortStation, rec.state != S.coast { return }

        if let pid = rec.primary, !(host.ship(pid)?.isAlive ?? false) { rec.primary = nil }

        if rec.state != S.squadJump && rec.state != S.departJump && rec.state != S.retreat { rec.jumpTimer = 0 }
        if rec.jumpTimer > 0 {
            if leader(of: ship) == World.playerEntityID {
                rec.state = S.squadJump
            } else {
                rec.state = rec.primary == nil ? S.departJump : S.retreat
            }
        }

        if rec.behavior == 5, rec.state == S.squadJump, !host.canJump(ship) {
            rec.state = S.returnToLeader
            rec.primary = nil
            rec.secondary = leader(of: ship).map(OriginalAIRef.ship) ?? .none
        }

        // Mission ShipBehav 0: always attack the player once under way.
        if host.isMissionAttacker(ship), ![S.squadJump, S.arrival, S.gateEmerge].contains(rec.state) {
            if !host.player.disabled || host.hasLethalWeapon(ship) {
                if canEngage(host.player, by: ship, host: host) { setHostileToPlayer(rec, ship: ship, host: host) }
            } else {
                rec.enterDeparture(clock60: clock60)
            }
        }

        // A target hidden by its cloak: warships wait with bounded patience,
        // traders leave.
        if let pid = rec.primary, rec.state == S.attack || rec.state == S.board, let target = host.ship(pid) {
            if !canEngage(target, by: ship, host: host) {
                if rec.behavior > 2 {
                    rec.mode = M.brake
                    rec.jumpTimer = 0
                    rec.secondary = .none
                    if !(rec.patience > 0) {
                        rec.patience = Double(host.random(100) + 100)
                    } else {
                        rec.patience -= ticks
                        if rec.patience <= 0 {
                            rec.primary = nil
                            rec.state = S.idle
                            rec.mode = M.idle
                            rec.patience = -1
                        }
                    }
                    return
                }
                if host.canJump(ship) { rec.enterDeparture(clock60: clock60) } else { rec.state = S.park }
                return
            }
            rec.patience = -1
        }

        // 0x01 · Travel: fly to the stellar, damp × 0.98 to a stop, then
        // coast 300–499 ticks (100–174 for Flags3 0x0002) before the next leg.
        if rec.state == S.travel, rec.secondary != .none {
            let stellar = rec.secondary.stellarID.flatMap { id in host.stellars.first { $0.id == id } }
            if stellar == nil || stellar!.isGate {
                rec.state = S.gateEntry
            } else if let stellar {
                rec.jumpTimer = 0
                let range = (9 - min(Self.turnDeg(ship), 8)) * 8 + 32
                if !Self.inBox(ship.position, stellar.position, range) {
                    rec.mode = M.travel
                } else if !Self.stopped(ship) {
                    rec.mode = M.brake
                    Self.damp(ship, 0.98)
                } else {
                    ship.velocity = Vec2()
                    ship.throttleSpeed = 0
                    rec.jumpDestination = stellar.id
                    rec.mode = M.idle
                    rec.state = S.idle
                    let routeLimited = host.hull(of: ship).flags3 & 0x0002 != 0
                    rec.maneuverTimer = Double(routeLimited ? host.random(0x4b) + 100 : host.random(200) + 300)
                }
            }
        }

        // 0x14 · Gate entry: approach, then a 16-tick fade and the transfer.
        // Followers go through the gate with their leader.
        if rec.state == S.gateEntry, let gateID = rec.secondary.stellarID {
            let gate = host.stellars.first { $0.id == gateID }
            rec.jumpTimer = 0
            let gatePos = gate?.position ?? Vec2()
            let quarter = ((host as? WorldAIHost)?.world.systemContext.bodies.first { $0.id == gateID }?.radius ?? 75) / 2
            if !Self.inBox(ship.position, gatePos, quarter.rounded(.towardZero)) {
                rec.mode = M.travel
                rec.maneuverTimer = -1
            } else {
                let finished = rec.mode == M.gateHandoff && rec.maneuverTimer <= 0
                let starting = rec.mode != M.gateHandoff
                ship.velocity = Vec2()
                ship.throttleSpeed = 0
                rec.mode = M.gateHandoff
                if starting || !(rec.maneuverTimer >= 0) || rec.maneuverTimer > 16 { rec.maneuverTimer = 16 }
                if starting {
                    for other in host.ships where !other.isPlayer && other.isAlive && leader(of: other) == ship.entityID {
                        guard let o = records[other.entityID] else { continue }
                        setLeader(other, nil)
                        o.behavior = min(rec.behavior, 3)
                        o.defenseHome = nil
                        o.hostility = -1
                        o.primary = nil
                        o.secondary = rec.secondary
                        o.state = S.gateEntry
                        o.mode = M.idle
                    }
                }
                if finished { host.depart(ship, viaGate: gateID) }
            }
            return
        }

        // 0x15 · Gate emergence: after the 60-tick hold, fall into the arrival.
        if rec.state == S.gateEmerge {
            rec.mode = M.idle
            rec.primary = nil
            guard rec.maneuverTimer <= 0 else { return }
            rec.maneuverTimer = -1
            rec.state = S.arrival
            rec.secondary = .none
        }

        // 0x02 · Departure: brake, thrust out of the 1000 px centre, then spin
        // up in place.
        if rec.state == S.departJump {
            if Self.nearCentre(ship) {
                rec.mode = M.departCentre
            } else if host.fastJump(ship) || Self.stopped(ship) {
                rec.mode = M.jumpSpinUp
            } else {
                rec.mode = M.brake
            }
            if !ship.disabled { host.tryAssistanceEncounter(ship, odds: rec.odds) }
            return
        }

        // 0x0B · Squad jump: hold formation through the leader's spin-up.
        if rec.state == S.squadJump {
            if let leaderID = leader(of: ship) {
                if leaderID == World.playerEntityID {
                    if host.playerJumpTimer <= 0 {
                        rec.standDown()
                    } else {
                        rec.primary = nil
                        rec.secondary = .none
                        rec.mode = M.squadJumpHold
                    }
                } else if let l = records[leaderID] {
                    // The original stages the leader into departure before
                    // testing it, so only its control mode can divert the escort.
                    l.state = S.departJump
                    if l.mode == M.brake || l.mode == M.jumpSpinUp {
                        rec.secondary = l.secondary
                        rec.primary = nil
                        rec.mode = M.squadJumpHold
                    } else {
                        rec.standDown()
                    }
                } else {
                    rec.standDown()
                }
            } else {
                rec.primary = nil
                rec.secondary = .none
                rec.state = S.departJump
                rec.mode = M.jumpSpinUp
            }
            return
        }

        // 0x0E · Coast after boarding: slides 0.7 px/tick along the nose.
        if rec.state == S.coast {
            rec.primary = nil
            rec.secondary = .none
            rec.mode = M.idle
            ship.position += Vec2.heading(ship.angle) * (ticks * 0.7)
            if rec.maneuverTimer <= 0 { rec.state = S.idle }
            return
        }

        // 0x05 · A fighter returning to its carrier.
        if rec.state == S.returnToLeader, let leaderID = leader(of: ship), rec.defenseHome == nil,
           let leaderShip = host.ship(leaderID) {
            rec.secondary = .ship(leaderID)
            let range = Double(Int16(truncatingIfNeeded: max(100, Int((10 - Self.turnDeg(ship)) * 50))))
            rec.mode = Self.inBox(ship.position, leaderShip.position, range) ? M.follow : M.formationHold
            if !canEngage(leaderShip, by: ship, host: host) { rec.mode = M.brake }
            ship.recallToCarrier = true
            return
        }

        // 0x0A · Escort station: velocity-match inside 300 px, formation
        // approach to 600 px, pursuit beyond.
        if rec.state == S.escortStation, let leaderID = leader(of: ship), rec.defenseHome == nil,
           let leaderShip = host.ship(leaderID) {
            rec.secondary = .ship(leaderID)
            if !canEngage(leaderShip, by: ship, host: host) {
                rec.mode = Self.inBox(ship.position, leaderShip.position, 300) ? M.brake : M.holdAtDistance
                return
            }
            if !Self.inBox(ship.position, leaderShip.position, 600) {
                rec.mode = M.holdAtDistance
            } else if !Self.inBox(ship.position, leaderShip.position, 300) {
                rec.mode = M.formationHold
            } else {
                rec.mode = M.velocityMatch
            }
            return
        }

        if rec.state == S.park {
            rec.jumpTimer = 0
            rec.mode = M.brake
            return
        }

        // 0x07 · Scan approach: within 100 px per axis the scan completes.
        if rec.state == S.scanApproach {
            guard let pid = rec.primary, rec.maneuverTimer <= 0 else {
                rec.state = S.idle
                rec.mode = M.idle
                return
            }
            guard let target = host.ship(pid), target.isAlive else {
                rec.standDown()
                return
            }
            if !Self.inBox(ship.position, target.position, 100) {
                rec.mode = M.holdAtDistance
                return
            }
            rec.standDown()
            if target.isPlayer { host.scanPlayer(by: ship) }
            return
        }

        // 0x08 · Arrival: hold the sentinel; the movement override ends it.
        if rec.state == S.arrival {
            rec.jumpTimer = -999
            rec.mode = M.arrivalSlowdown
            return
        }

        // 0x09 · Fuel transfer: hold at trunc((10 − turn) × 15) px, stop, then
        // feed 1 unit a tick until the customer passes 100.
        if rec.state == S.refuel {
            guard let pid = rec.primary, let target = host.ship(pid) else { return }
            let keep = ((10 - Self.turnDeg(ship)) * 15).rounded(.towardZero)
            rec.mode = M.formationHold
            if !Self.inBox(ship.position, target.position, keep) {
                rec.mode = M.formationHold
            } else if !Self.stopped(ship) {
                rec.mode = M.brake
            } else {
                ship.velocity = Vec2()
                ship.throttleSpeed = 0
                if target.fuel > 100 {
                    rec.standDown()
                } else {
                    host.transferFuel(to: target, amount: 1.0 * ticks)
                }
            }
            return
        }

        // 0x0F · Repair a disabled target: approach, match, then the mode-0xf
        // arm repairs it.
        if rec.state == S.repair, let pid = rec.primary {
            guard let target = host.ship(pid), target.isAlive, target.disabled else {
                rec.standDown()
                return
            }
            rec.secondary = .ship(pid)
            var range = Double(Int16(truncatingIfNeeded: Int((10 - Self.turnDeg(ship)) * 30 + 50)))
            if ship.isInertialessNow { range *= 4 }
            rec.mode = Self.inBox(ship.position, target.position, range) ? M.boardHold : M.formationHold
            return
        }

        if rec.state == S.asteroid {
            if let rock = host.firstAsteroid {
                let threshold = ((10 - Self.turnDeg(ship)) * 15).rounded(.towardZero)
                rec.mode = Self.inBox(ship.position, rock.position, threshold) ? M.scriptedMatch : M.scriptedManeuver
            } else {
                rec.mode = M.brake
            }
            return
        }
        if rec.state == S.debris {
            rec.mode = M.freeflightAnchor
            return
        }

        if rec.state == S.stellarAttack {
            rec.mode = Self.stopped(ship) ? M.stellarAim : M.brake
            Self.damp(ship, 0.98)
            return
        }

        if rec.state == S.retreat || rec.state == S.attack {
            updateCombatState(rec, ship: ship, host: host)
            return
        }

        // 0x0C · Holding near the player.
        if rec.state == S.playerStation {
            rec.jumpTimer = 0
            rec.primary = nil
            rec.secondary = .ship(World.playerEntityID)
            let player = host.player
            let outer = (10 - Self.turnDeg(ship)) * 30
            let inner = (10 - Self.turnDeg(ship)) * 60
            if host.playerJumpTimer > 0 {
                rec.state = S.squadJump
            } else if !canEngage(player, by: ship, host: host) {
                rec.mode = M.brake
            } else if !Self.inBox(ship.position, player.position, outer) {
                rec.mode = Self.inBox(ship.position, player.position, inner) ? M.formationHold : M.holdAtDistance
            } else {
                rec.mode = M.velocityMatch
            }
            return
        }

        if rec.state == S.board {
            updateBoardingState(rec, ship: ship, host: host)
            return
        }

        if rec.state == S.idle { rec.mode = M.idle }
    }

    /// States 3 (retreat) and 4 (attack).
    private func updateCombatState(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        let S = OriginalAIState.self, M = OriginalAIMode.self
        let entry = rec.state
        guard let pid = rec.primary, let target = host.ship(pid) else {
            rec.state = S.idle
            rec.mode = M.idle
            if entry == S.retreat { rec.hostility = 0 }
            return
        }
        let dx = abs(ship.position.x - target.position.x)
        let dy = abs(ship.position.y - target.position.y)
        let sameSide = ship.government >= govtResourceBase && leader(of: ship) != World.playerEntityID
            && target.government >= govtResourceBase && host.areAllied(ship.government, target.government)
            && leader(of: target) != World.playerEntityID

        if entry == S.retreat {
            if rec.jumpTimer > 0 {
                if Self.nearCentre(ship) {
                    rec.jumpTimer = 0
                    rec.mode = M.departCentre
                } else {
                    rec.mode = M.jumpSpinUp
                }
            } else if dx < 251 && dy < 251 && rec.mode != M.jumpSpinUp {
                // Too close to jump: head away from the attacker.
                rec.mode = M.strafeAway
                if sameSide {
                    rec.standDown()
                    return
                }
                host.tryAssistanceEncounter(ship, odds: rec.odds)
            } else if Self.nearCentre(ship) || !host.canJump(ship) {
                rec.mode = M.departCentre
            } else if host.fastJump(ship) || Self.stopped(ship) {
                rec.mode = M.jumpSpinUp
            } else {
                rec.mode = M.brake
            }
            return
        }

        if sameSide {
            rec.state = S.idle
            rec.mode = M.idle
            return
        }
        // A ship never attacks its own squad.
        if let leaderID = leader(of: ship) {
            let targetLeader = leader(of: target)
            let grand = targetLeader.flatMap { host.ship($0) }.flatMap { leader(of: $0) }
            let ourGrand = host.ship(leaderID).flatMap { leader(of: $0) }
            let ourGreat = ourGrand.flatMap { host.ship($0) }.flatMap { leader(of: $0) }
            let grandMatch = grand != nil && (targetLeader == grand || ourGreat == grand)
            if pid == leaderID || leaderID == targetLeader || grandMatch {
                rec.standDown()
                return
            }
        }
        if !target.isAlive {
            rec.primary = nil
            rec.hostility = 0
            rec.state = S.idle
            rec.mode = M.idle
            return
        }
        let standoff = host.hull(of: ship).flags2 & 0x0002 != 0
        if dx > 165 || dy > 165 {
            if !standoff {
                if targetCanOutrun(rec, ship: ship, host: host) {
                    if rec.behavior < 3 {
                        rec.state = S.retreat
                        rec.mode = M.strafeAway
                    } else {
                        rec.mode = M.combatBrake
                    }
                } else if !followsSwarmMate(rec, ship: ship, host: host), rec.mode != M.boost {
                    rec.mode = M.strafe
                }
            } else {
                // Standoff hulls (Flags2 0x0002) hold 0.85 × their longest
                // reach, halved against a disabled target.
                let reach = Int(Int16(truncatingIfNeeded: Int(min(host.maxWeaponRange(ship), 0x7fff))))
                var hold = Int(Double(reach) * 0.85)
                if target.disabled { hold = Int(Double(hold) * 0.5) }
                rec.mode = Double(hold) < dx || Double(hold) < dy ? M.strafe : M.combatBrake
            }
        } else if !standoff {
            if rec.mode != M.evasiveBreak { rec.mode = M.pursuit }
        } else {
            rec.mode = M.strafeAway
        }
        // Carrier launches run in `World.updateFighterBays` for any NPC
        // carrier with a target.
        if !ship.disabled { host.tryAssistanceEncounter(ship, odds: rec.odds) }
    }

    /// State 0x0D: closing on a disabled ship to board it.
    private func updateBoardingState(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        let S = OriginalAIState.self, M = OriginalAIMode.self
        rec.jumpTimer = 0
        guard let pid = rec.primary, rec.maneuverTimer <= 0, let target = host.ship(pid) else {
            rec.state = S.idle
            rec.mode = M.idle
            return
        }
        if let leaderID = leader(of: ship), pid == leaderID || leader(of: target) == leaderID {
            rec.standDown()
            return
        }
        if !target.isAlive {
            rec.standDown()
            rec.hostility = 0
            return
        }
        rec.secondary = .none
        let dx = abs(ship.position.x - target.position.x)
        let dy = abs(ship.position.y - target.position.y)
        if !target.disabled {
            if dx > 165 || dy > 165 {
                if targetCanOutrun(rec, ship: ship, host: host) {
                    rec.mode = rec.behavior < 3 ? M.strafeAway : M.combatBrake
                } else if rec.mode != M.boost {
                    rec.mode = M.strafe
                }
            } else if rec.mode != M.evasiveBreak && rec.mode != M.boost {
                rec.mode = M.pursuit
            }
        } else if !isBoarded(pid) || rec.maneuverTimer > 0 {
            rec.secondary = .ship(pid)
            var range = (10 - Self.turnDeg(ship)) * 30
            if ship.isInertialessNow { range *= 4 }
            if dx > range || dy > range {
                rec.mode = dx > range * 2 || dy > range * 2 ? M.holdAtDistance : M.formationHold
            } else {
                rec.mode = M.boardHold
            }
        } else {
            rec.standDown()
        }
    }
}
