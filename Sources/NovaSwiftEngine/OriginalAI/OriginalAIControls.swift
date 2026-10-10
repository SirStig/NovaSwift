import Foundation

/// `Ship_ApplyShipAiControls` (0x00408150) turns the control mode into a
/// desired heading (whole degrees), a thrust command and a desired speed, and
/// arms weapon groups; `integrate` then applies the thrust the way
/// `Ship_HandleShip` (0x00433050) does. Speeds here are px/tick.
extension OriginalAI {

    /// Effective top speed, thrust and turn in the original's per-tick units.
    struct Flight {
        let maxSpeed: Double
        let thrust: Double
        let turnDeg: Double

        init(_ ship: Ship) {
            maxSpeed = ship.effectiveMaxSpeed / OriginalClock.ticksPerSecond
            thrust = ship.effectiveAcceleration / (OriginalClock.ticksPerSecond * OriginalClock.ticksPerSecond)
            turnDeg = OriginalAI.turnDeg(ship)
        }
    }

    func applyControls(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost, ticks: Double) {
        let M = OriginalAIMode.self
        let f = Flight(ship)
        rec.thrustCommand = 0
        if rec.desiredSpeed >= 0 { rec.desiredSpeed = f.maxSpeed }
        let current = Self.headingDeg(ship)
        rec.desiredHeadingDeg = Int(current)
        func delta() -> Double { abs(Self.deltaDeg(from: current, to: Double(rec.desiredHeadingDeg))) }
        func thrust(_ k: Double = 1, desired: Double = 0) {
            rec.thrustCommand = f.thrust * k
            rec.desiredSpeed = desired
        }
        let disabled = ship.disabled
        let v = Self.velocityPerTick(ship)
        let target = rec.primary.flatMap { host.ship($0) }

        switch rec.mode {
        case M.idle:
            escortFire(rec, ship: ship, host: host)

        case M.gateHandoff:
            break

        case M.freeflightAnchor:
            // Steer for the nearest box (truncated squared distance); thrust
            // inside turn + 15°, else bleed each axis by 1.75 × thrust per
            // tick. No box: mode 0.
            var best: Vec2?
            var bestD = 0
            for p in host.freeflightPositions {
                let d = Int(Self.truncatedDistanceSquared(ship.position, p))
                if best == nil || d < bestD { best = p; bestD = d }
            }
            guard let box = best else { rec.mode = M.idle; break }
            rec.desiredHeadingDeg = Int(Self.bearingDeg(ship.position, box))
            if delta() < f.turnDeg + 15 {
                rec.thrustCommand = f.thrust
            } else {
                let bleed = f.thrust * 1.75 * ticks
                var vt = Self.velocityPerTick(ship)
                for axis in 0..<2 {
                    var c = axis == 0 ? vt.x : vt.y
                    if bleed <= c { c -= bleed } else if -bleed < c { c = 0 } else { c += bleed }
                    if axis == 0 { vt.x = c } else { vt.y = c }
                }
                ship.velocity = vt * OriginalClock.ticksPerSecond
            }

        case M.stellarAim:
            if !disabled, let id = rec.secondary.stellarID, let s = host.stellars.first(where: { $0.id == id }) {
                rec.desiredHeadingDeg = Int(Self.bearingDeg(ship.position, s.position))
                if delta() < f.turnDeg + 15 { rec.fire.insert(.general) }
            }
            rec.desiredSpeed = 0

        case M.swarm:
            guard !disabled else { break }
            guard let mateID = rec.swarmMate, let mate = host.ship(mateID) else {
                rec.mode = M.idle
                break
            }
            let lead = mate.position + Vec2.heading(mate.angle) * (f.maxSpeed * 15)
            rec.desiredHeadingDeg = Int(Self.bearingDeg(ship.position, lead))
            if delta() < f.turnDeg + 20 { rec.thrustCommand = f.thrust }
            if rec.state == OriginalAIState.attack, rec.primary != nil { rec.fire.insert(.guided) }

        case M.brake:
            guard !disabled else { break }
            if abs(v.x) < 0.35 && abs(v.y) < 0.35 {
                Self.damp(ship, 0.95)
                rec.mode = M.idle
                break
            }
            if !ship.inertialess {
                rec.desiredHeadingDeg = Self.wrapDeg(Int(Self.bearingDeg(Vec2(), v) + 180))
                if delta() < f.turnDeg + 1 {
                    if abs(v.x) >= 1.75 || abs(v.y) >= 1.75 {
                        rec.thrustCommand = f.thrust
                    } else {
                        rec.thrustCommand = f.thrust * 0.5
                        Self.damp(ship, 0.94)
                    }
                } else if rec.state == OriginalAIState.refuel {
                    Self.damp(ship, 0.94)
                }
            } else {
                rec.thrustCommand = -f.thrust * 0.5
            }
            escortFire(rec, ship: ship, host: host)

        case M.travel:
            guard !disabled else { break }
            var point = ship.position
            switch rec.secondary {
            case let .stellar(id): point = host.stellars.first { $0.id == id }?.position ?? point
            case let .ship(id): point = host.ship(id)?.position ?? point
            case .none: break
            }
            rec.desiredHeadingDeg = Int(Self.bearingDeg(ship.position, point))
            if delta() < f.turnDeg + 5 {
                rec.thrustCommand = f.thrust
                rec.desiredSpeed = Self.inBox(ship.position, point, 499.999) ? f.maxSpeed * 0.25 : 0
            }

        case M.departCentre:
            guard !disabled else { break }
            rec.desiredHeadingDeg = Int(Self.bearingDeg(Vec2(), ship.position))
            if delta() < f.turnDeg + 3 { thrust() }

        case M.jumpSpinUp:
            guard !disabled else { break }
            rec.desiredHeadingDeg = Int(Self.bearingDeg(Vec2(), ship.position))
            if rec.jumpTimer <= 0 {
                rec.jumpTimer = 1
                rec.modeStart60 = clock60
            }
            rec.jumpTimer += ticks
            // The spin-up lasts the "Warp up" cue at the hull's multiplier
            // (FL-04), timed from alignment.
            if clock60 - rec.modeStart60 >= host.jumpCueTicks60 / host.jumpMultiplier(ship) {
                rec.jumpTimer = 0
                rec.thrustCommand = 0
                rec.desiredSpeed = 0
                host.depart(ship, viaGate: nil)
            }

        case M.squadJumpHold:
            guard !disabled else { break }
            squadJumpHold(rec, ship: ship, host: host, flight: f, ticks: ticks)

        case M.strafeAway:
            guard !disabled, let target else { break }
            if rec.swarmMate != nil { moveTowardFormationOffset(rec, ship: ship, ticks: ticks) }
            // The original reverses the bearing helper's arguments here: the
            // ship heads away from its target.
            rec.desiredHeadingDeg = Int(Self.bearingDeg(target.position, ship.position))
            if delta() < f.turnDeg + 20 { thrust() }
            if rec.state == OriginalAIState.retreat || rec.state == OriginalAIState.attack { rec.fire.insert(.turret) }
            let d = target.position - ship.position
            if rec.afterburnerLatch && (abs(d.x) < 165 || abs(d.y) < 165) { rec.mode = M.boost }

        case M.pursuit:
            guard !disabled, let target else { break }
            pursuit(rec, ship: ship, target: target, host: host, flight: f)

        case M.evasiveBreak:
            guard !disabled, let target else { break }
            rec.desiredHeadingDeg = rec.evasiveHeadingDeg
            thrust(1.5)
            if Self.inBox(ship.position, target.position, 164.999) { rec.fire.insert(.turret) }
            if !ship.inertialess {
                if abs(Self.deltaDeg(from: current, to: Double(rec.evasiveHeadingDeg))) < f.turnDeg * 3 {
                    rec.mode = M.pursuit
                }
            } else if !Self.inBox(ship.position, target.position, 165) {
                rec.mode = M.pursuit
            }

        case M.boost:
            guard !disabled, let target else { break }
            rec.thrustCommand = f.thrust * 2.75
            rec.desiredSpeed = f.maxSpeed * 1.8
            rec.desiredHeadingDeg = Int(Self.bearingDeg(ship.position, target.position))
            if rec.swarmMate != nil { moveTowardFormationOffset(rec, ship: ship, ticks: ticks) }
            let close = Self.inBox(ship.position, target.position, 164.999)
            if close {
                rec.fire.insert(.turret)
                if delta() < f.turnDeg * 3 { rec.fire.insert(.direct) }
            } else if delta() < f.turnDeg * 3 {
                rec.fire.insert(.guided)
            }
            if close || host.random(100) == 0 { rec.mode = M.pursuit }

        case M.strafe:
            guard !disabled, let target else { break }
            if rec.swarmMate != nil { moveTowardFormationOffset(rec, ship: ship, ticks: ticks) }
            let bearing = Self.bearingDeg(ship.position, target.position)
            // AI-02: lead with the live bank (`Ship_AimWeaponPredictive`).
            rec.desiredHeadingDeg = Int(host.leadBearingDeg(ship, target: target, bank: rec.activeBank))
            if delta() < f.turnDeg * 3 { rec.fire.formUnion([.direct, .turret]) }
            if delta() < f.turnDeg * 4 {
                thrust()
                rec.fire.insert(.guided)
            }
            let d = target.position - ship.position
            if rec.afterburnerLatch, abs(d.x) > 82, abs(d.y) > 82,
               abs(Self.deltaDeg(from: current, to: bearing)) < 31 {
                rec.mode = M.boost
            }

        case M.follow:
            follow(rec, ship: ship, host: host, flight: f, ticks: ticks)

        case M.holdAtDistance, M.formationHold:
            guard !disabled else { break }
            guard let id = rec.primary ?? rec.secondary.shipID, let goal = host.ship(id) else { break }
            if rec.mode == M.formationHold, rec.swarmMate != nil {
                moveTowardFormationOffset(rec, ship: ship, ticks: ticks)
            }
            let bearing = Self.bearingDeg(ship.position, goal.position)
            if !Self.inBox(ship.position, goal.position, 200) {
                rec.desiredHeadingDeg = Int(bearing)
            } else if abs(Self.bearingDeg(Vec2(), v) - bearing) > 15 {
                let dv = Vec2.heading(bearing * .pi / 180) * f.maxSpeed - v
                if abs(dv.x) > 0.35 || abs(dv.y) > 0.35 {
                    rec.desiredHeadingDeg = Int(Self.bearingDeg(Vec2(), dv))
                }
            }
            if delta() < f.turnDeg + 1 {
                rec.thrustCommand = f.thrust
                if rec.mode == M.formationHold, Self.inBox(ship.position, goal.position, 100) {
                    rec.desiredSpeed = f.maxSpeed * 0.5
                } else {
                    rec.desiredSpeed = 0
                }
            }
            escortFire(rec, ship: ship, host: host)

        case M.velocityMatch:
            guard !disabled, let id = rec.secondary.shipID, let goal = host.ship(id) else { break }
            velocityMatch(rec, ship: ship, goal: goal, flight: f, ticks: ticks)
            if rec.secondary != .none { escortFire(rec, ship: ship, host: host) }

        case M.boardHold:
            guard !disabled, let id = rec.secondary.shipID, let goal = host.ship(id) else { break }
            boardHold(rec, ship: ship, goal: goal, host: host, flight: f, ticks: ticks)

        case M.combatBrake:
            guard !disabled, let target else { break }
            if !Self.stopped(ship) {
                if !ship.inertialess {
                    rec.desiredHeadingDeg = Self.wrapDeg(Int(Self.bearingDeg(Vec2(), v) + 180))
                    if delta() < f.turnDeg + 1 { rec.thrustCommand = f.thrust }
                } else {
                    rec.thrustCommand = -f.thrust
                }
            } else {
                Self.damp(ship, 0.95)
                rec.desiredHeadingDeg = Int(Self.bearingDeg(ship.position, target.position))
                if delta() < f.turnDeg * 3 { rec.fire.formUnion([.direct, .guided]) }
                rec.fire.insert(.turret)
            }

        case M.arrivalSlowdown:
            if rec.desiredSpeed >= 0 { rec.desiredSpeed = -50 }
            rec.thrustCommand = -1.165

        case M.scriptedManeuver:
            guard !disabled, let rock = host.firstAsteroid else { break }
            rec.desiredHeadingDeg = Int(Self.bearingDeg(ship.position, rock.position))
            if delta() < f.turnDeg + 15 { rec.thrustCommand = f.thrust }

        case M.scriptedMatch:
            guard !disabled, let rock = host.firstAsteroid else { break }
            let step = f.thrust * 1.5 * ticks
            var vel = v
            let tv = rock.velocity * (1 / OriginalClock.ticksPerSecond)
            func ramp(_ a: Double, _ goal: Double) -> Double {
                if a < goal + step { return goal - step < a ? goal : a + step }
                return a - step
            }
            vel = Vec2(ramp(vel.x, tv.x), ramp(vel.y, tv.y))
            ship.velocity = vel * OriginalClock.ticksPerSecond
            // The ship also creeps toward the rock until within 150 px on each
            // axis, then is pushed out of an 80 px window around it
            // (0x00408150, B-7).
            func creep(_ pos: Double, _ goal: Double) -> Double {
                var p = pos
                if goal + 150 < p { p -= step } else if p < goal - 150 { p += step }
                if goal < p, p < goal + 80 { p += step } else if p < goal, goal - 80 < p { p -= step }
                return p
            }
            ship.position = Vec2(creep(ship.position.x, rock.position.x), creep(ship.position.y, rock.position.y))
            rec.desiredHeadingDeg = Int(Self.rockLeadBearingDeg(ship: ship, rock: rock, bank: rec.activeBank))
            if delta() < f.turnDeg + 10 {
                rec.primary = nil
                rec.fire.insert(.unguided)
            }

        default:
            break
        }
    }

    /// `Ship_AimWeaponLeadVelocity` (0x0043b8c0): the bearing to the rock,
    /// led by `dist / Speed` ticks of relative velocity when the active bank
    /// is an unguided, turret, quadrant or point-defense weapon; the plain
    /// bearing with no bank.
    static func rockLeadBearingDeg(ship: Ship, rock: (position: Vec2, velocity: Vec2), bank: Int?) -> Double {
        let straight = bearingDeg(ship.position, rock.position)
        guard let bank, ship.weapons.indices.contains(bank) else { return straight }
        let spec = ship.weapons[bank].spec
        switch spec.guidance {
        case .unguided, .turret, .frontQuadrant, .rearQuadrant, .pointDefense: break
        default: return straight
        }
        let rawSpeed = spec.speedPerTick * 100
        guard rawSpeed > 0 else { return straight }
        let rel = rock.position - ship.position
        let t = rel.length / rawSpeed
        let dv = (rock.velocity - ship.velocity) * (1 / OriginalClock.ticksPerSecond)
        return bearingDeg(ship.position, rock.position + dv * t)
    }

    // MARK: Mode bodies

    private func pursuit(_ rec: OriginalAIShipState, ship: Ship, target: Ship, host: OriginalAIHost, flight f: Flight) {
        let M = OriginalAIMode.self
        let current = Self.headingDeg(ship)
        let bearing = Self.bearingDeg(ship.position, target.position)
        // AI-02: lead with the live bank (`Ship_AimWeaponPredictive`).
        rec.desiredHeadingDeg = Int(host.leadBearingDeg(ship, target: target, bank: rec.activeBank))
        rec.fire.insert(.turret)
        let delta = abs(Self.deltaDeg(from: current, to: Double(rec.desiredHeadingDeg)))
        if delta < f.turnDeg + 15 {
            rec.thrustCommand = f.thrust
            rec.desiredSpeed = 0
        }
        let dx = abs(ship.position.x - target.position.x)
        let dy = abs(ship.position.y - target.position.y)
        if delta < f.turnDeg * 3 {
            rec.fire.insert(.direct)
            let targetSpeed = target.velocity.length / OriginalClock.ticksPerSecond
            let ourSpeed = ship.velocity.length / OriginalClock.ticksPerSecond
            if ship.inertialess, dx < 100, dy < 100, targetSpeed < ourSpeed { rec.desiredSpeed = targetSpeed }
        }
        if dx < 165 || dy < 165 || !ship.inertialess {
            // A light fighter meeting a head-on target breaks ± 135°. Against
            // the player it needs the combat-rating gate; otherwise half the
            // time it skips the gate.
            let allowed: Bool
            if target.isPlayer {
                allowed = ratingGate(host)
            } else if host.random(2) == 0 {
                allowed = true
            } else {
                allowed = ratingGate(host)
            }
            let hull = host.hull(of: ship)
            if allowed, hull.inherentAI > 2, hull.mass < 200, dx < 123, dy < 123 {
                let smallerFirst = target.entityID < ship.entityID
                    || (ship.entityID < target.entityID && hull.mass < host.hull(of: target).mass)
                let facingBack = (bearing + 180).truncatingRemainder(dividingBy: 360)
                if smallerFirst, abs(Self.deltaDeg(from: current, to: bearing)) < 31,
                   abs(Self.deltaDeg(from: Self.headingDeg(target), to: facingBack)) < 31 {
                    rec.mode = M.evasiveBreak
                    let offset = ship.entityID & 1 == 0 ? 135 : -135
                    rec.evasiveHeadingDeg = Self.wrapDeg(Int(current) + offset)
                    rec.desiredHeadingDeg = Self.wrapDeg(Int(current))
                }
            }
        }
        if rec.afterburnerLatch, dx > 82, dy > 82, abs(Self.deltaDeg(from: current, to: bearing)) < 31 {
            rec.mode = M.boost
        }
    }

    /// `NovaAi_PlayerCombatRatingGate` (0x0046b330): passes with chance rising
    /// from 0 at 256 rating points to 1 at 1599.
    func ratingGate(_ host: OriginalAIHost) -> Bool {
        host.random(0x540) + 0x100 <= host.playerCombatRating
    }

    private func follow(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost, flight f: Flight, ticks: Double) {
        let S = OriginalAIState.self
        guard let id = rec.secondary.shipID, !ship.disabled, let goal = host.ship(id) else {
            rec.state = S.idle
            rec.mode = OriginalAIMode.idle
            return
        }
        guard goal.isAlive else {
            rec.behavior = host.hull(of: ship).inherentAI
            rec.state = S.idle
            return
        }
        rec.desiredHeadingDeg = Int(Self.bearingDeg(ship.position, goal.position))
        if abs(Self.deltaDeg(from: Self.headingDeg(ship), to: Double(rec.desiredHeadingDeg))) < f.turnDeg + 1 {
            rec.thrustCommand = f.thrust
            rec.desiredSpeed = 0
        }
        // Outside the escort sprite span the ship creeps onto its leader at
        // thrust × 10 per tick; inside, the carrier recovers it
        // (`World.updateFighterBays` docks a recalled fighter within 75 px).
        if !Self.inBox(ship.position, goal.position, 75) {
            let step = f.thrust * 10 * ticks
            if let leaderID = leader(of: ship), leaderID > 0, let lead = host.ship(leaderID) {
                ship.position = Self.creep(ship.position, toward: lead.position, step: step, deadzone: step)
            }
            rec.desiredSpeed -= step
        }
    }

    /// Per-axis creep toward `goal`: each axis moves `step` while more than
    /// `deadzone` away.
    static func creep(_ p: Vec2, toward goal: Vec2, step: Double, deadzone: Double) -> Vec2 {
        var out = p
        if out.x <= goal.x - deadzone { out.x += step } else if goal.x + deadzone <= out.x { out.x -= step }
        if out.y <= goal.y - deadzone { out.y += step } else if goal.y + deadzone <= out.y { out.y -= step }
        return out
    }

    private func velocityMatch(_ rec: OriginalAIShipState, ship: Ship, goal: Ship, flight f: Flight, ticks: Double) {
        let v = Self.velocityPerTick(ship)
        let gv = Self.velocityPerTick(goal)
        let rel = v - gv
        if ship.inertialess || (abs(rel.x) < 0.525 && abs(rel.y) < 0.525) {
            ship.velocity = goal.velocity
            let goalHeading = Self.headingDeg(goal), current = Self.headingDeg(ship)
            let delta = abs(remainder(goalHeading.rounded(.towardZero) - current.rounded(.towardZero), 360))
            let window = 25.0
            if delta < 1 || window <= delta {
                rec.desiredHeadingDeg = Int(goalHeading)
            } else {
                let signed = remainder(goalHeading.rounded(.towardZero) - current.rounded(.towardZero), 360)
                rec.desiredHeadingDeg = Self.wrapDeg(Int(current) + (signed < 0 ? -1 : 1))
            }
            if rec.state == OriginalAIState.scanApproach {
                let anchor = goal.position + Vec2.heading((goalHeading + 135) * .pi / 180) * 48
                let step = f.thrust * 10 * ticks
                ship.position = Self.creep(ship.position, toward: anchor, step: step, deadzone: step)
            } else {
                moveTowardFormationOffset(rec, ship: ship, ticks: ticks)
            }
        } else {
            rec.desiredHeadingDeg = Self.wrapDeg(Int(Self.bearingDeg(Vec2(), rel) + 180))
            if abs(Self.deltaDeg(from: Self.headingDeg(ship), to: Double(rec.desiredHeadingDeg))) < f.turnDeg + 1 {
                rec.thrustCommand = f.thrust * 0.66
                rec.desiredSpeed = 0
            }
            if abs(rel.x) < 1.75 || abs(rel.y) <= 1.75 {
                ship.velocity = (gv + rel * 0.94) * OriginalClock.ticksPerSecond
            }
        }
    }

    private func boardHold(_ rec: OriginalAIShipState, ship: Ship, goal: Ship, host: OriginalAIHost,
                           flight f: Flight, ticks: Double) {
        let v = Self.velocityPerTick(ship)
        let gv = Self.velocityPerTick(goal)
        let rel = v - gv
        if abs(rel.x) >= 0.525 || abs(rel.y) >= 0.525 {
            if !ship.inertialess {
                rec.desiredHeadingDeg = Self.wrapDeg(Int(Self.bearingDeg(Vec2(), rel) + 180))
                if abs(Self.deltaDeg(from: Self.headingDeg(ship), to: Double(rec.desiredHeadingDeg))) < f.turnDeg + 1 {
                    rec.thrustCommand = f.thrust
                    rec.desiredSpeed = 0
                }
                if abs(rel.x) < 1.75 || abs(rel.y) <= 1.75 {
                    ship.velocity = (gv + rel * 0.95) * OriginalClock.ticksPerSecond
                }
            } else {
                rec.desiredSpeed = 0
                ship.throttleSpeed = max(0, ship.throttleSpeed - OriginalClock.perSecond(f.thrust * ticks))
            }
            return
        }
        rec.desiredHeadingDeg = Int(Self.headingDeg(goal))
        ship.velocity = goal.velocity
        if !Self.inBox(ship.position, goal.position, 3) {
            ship.position += Vec2.heading(Self.bearingDeg(ship.position, goal.position) * .pi / 180) * ticks
            return
        }
        // Within 3 px: latch the victim and pause 100–179 ticks before the
        // boarding; a repairing ship instead lifts it back above the line.
        if rec.maneuverTimer <= 0 {
            if rec.state != OriginalAIState.coast {
                setBoarded(goal.entityID, true)
                rec.maneuverTimer = Double(host.random(0x50) + 100)
            }
        } else if rec.maneuverTimer <= 100, rec.state == OriginalAIState.repair {
            setBoarded(goal.entityID, false)
            host.repairAboveDisable(goal)
        }
    }

    private func squadJumpHold(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost, flight f: Flight,
                               ticks: Double) {
        guard let leaderID = leader(of: ship), let leaderShip = host.ship(leaderID) else { return }
        let leaderHeading = Self.headingDeg(leaderShip)
        let leaderRec = records[leaderID]
        let leaderDesired = leaderRec?.desiredHeadingDeg ?? Int(leaderHeading)
        let leaderJump = leaderShip.isPlayer ? host.playerJumpTimer : (leaderRec?.jumpTimer ?? 0)
        rec.desiredHeadingDeg = Int(leaderHeading)
        if leaderJump > 1 {
            if rec.jumpTimer > 30, !leaderShip.isPlayer {
                // Released: the escort jumps out on its own.
                rec.desiredHeadingDeg = leaderDesired
                setLeader(ship, nil)
                rec.behavior = host.hull(of: ship).inherentAI
                rec.state = OriginalAIState.departJump
                rec.mode = OriginalAIMode.jumpSpinUp
                return
            }
            let leaderDelta = abs(remainder(Double(leaderDesired) - leaderHeading.rounded(.towardZero), 360))
            if leaderDelta < 11 {
                rec.secondary = leaderRec?.secondary ?? .none
                if rec.jumpTimer == 0 {
                    rec.jumpTimer = 1
                    rec.modeStart60 = clock60
                }
                Self.damp(ship, 0.95)
                rec.thrustCommand = 0
                rec.desiredSpeed = -4
                rec.jumpTimer += ticks / OriginalClock.rawCallTickScale
            } else if leaderDelta <= f.turnDeg {
                rec.maneuverTimer = 180
            } else {
                rec.desiredHeadingDeg = leaderDesired
                rec.jumpTimer = -4
            }
        } else {
            ship.velocity = leaderShip.velocity
            if rec.swarmMate != nil { moveTowardFormationOffset(rec, ship: ship, ticks: ticks) }
        }
    }

    // MARK: Ship_HandleShip movement

    /// Apply this frame's thrust command and the jump ramp, count the coast
    /// timer down, and hand `Ship.step` the heading to turn to.
    func integrate(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost, ticks: Double) -> ControlIntent {
        var intent = ControlIntent()
        let f = Flight(ship)
        let holdsCourse = rec.maneuverTimer > 0 && rec.state != OriginalAIState.yield
        if !holdsCourse {
            intent.desiredHeading = Double(rec.desiredHeadingDeg) * .pi / 180
        }

        if !holdsCourse, rec.thrustCommand > 0, host.fliesPortFormationModel(ship) {
            intent.thrust = true
        } else if !holdsCourse, rec.thrustCommand != 0 {
            let step = rec.thrustCommand * ticks
            let desired = rec.desiredSpeed
            if desired == 0 {
                if rec.jumpTimer <= 0 { applyThrust(ship, step: step, cap: f.maxSpeed) }
            } else if desired > 0 {
                applyThrust(ship, step: step, cap: desired)
            } else {
                // The arrival override (0x00433050): each raw call sets the
                // velocity to heading × |desired| (moved × the 0.63 frame
                // scale), then adds |command| to desired with no frame scale.
                // The step flies at the first call's speed and counts the
                // calls it held, so the slide and the speed left at hand-back
                // (the last call's) match the original at its 21 ms floor.
                var threshold = f.maxSpeed
                if let leaderID = leader(of: ship), let lead = host.ship(leaderID) {
                    threshold = min(threshold, Flight(lead).maxSpeed)
                }
                let calls = rec.arrivalCallPhase + ticks / OriginalClock.rawCallTickScale
                let n = Int(calls.rounded(.down))
                rec.arrivalCallPhase = calls - Double(n)
                let first = abs(rec.desiredSpeed)
                var last = first
                var crossed = false
                for _ in 0..<max(n, 0) {
                    last = abs(rec.desiredSpeed)
                    rec.desiredSpeed += abs(rec.thrustCommand)
                    if rec.desiredSpeed >= -threshold { crossed = true; break }
                }
                let speed = OriginalClock.perSecond(crossed ? last : first)
                if ship.inertialess {
                    ship.throttleSpeed = speed
                } else {
                    ship.velocity = Vec2.heading(ship.angle) * speed
                }
                if crossed {
                    rec.resetTargets()
                    if ship.inertialess {
                        rec.desiredSpeed = threshold
                        ship.velocity = Vec2()
                    }
                    if leader(of: ship) == nil { rec.maneuverTimer = Double(host.random(30) + 30) }
                }
            }
        }

        // The departure ramp: once aligned the position (not the velocity)
        // steps along the nose by the cue's progress, capped at 50 px/tick.
        if rec.jumpTimer > 0,
           [OriginalAIState.departJump, OriginalAIState.retreat, OriginalAIState.squadJump].contains(rec.state),
           rec.mode == OriginalAIMode.jumpSpinUp || rec.mode == OriginalAIMode.squadJumpHold, !ship.disabled {
            Self.damp(ship, pow(0.8, ticks / OriginalClock.rawCallTickScale))
            let off = abs(Self.deltaDeg(from: Self.headingDeg(ship), to: Double(rec.desiredHeadingDeg)))
            if off > f.turnDeg * ticks {
                rec.modeStart60 = clock60
            } else {
                let mult = host.jumpMultiplier(ship)
                let offset = leader(of: ship) == World.playerEntityID ? 45.0 : 35.0
                let progress = (clock60 - rec.modeStart60) * mult / (host.jumpCueTicks60 * 0.01) - offset / mult
                let stepPx = min(max(progress, 0), 50)
                if stepPx > 0 { ship.position += Vec2.heading(ship.angle) * (stepPx * ticks) }
            }
        }

        if rec.maneuverTimer > 0 { rec.maneuverTimer = max(0, rec.maneuverTimer - ticks) }
        return intent
    }

    /// A per-axis clamped thrust step (`Math_AddPolarVelocityWithClamp`), or
    /// the scalar speed of an inertialess hull.
    private func applyThrust(_ ship: Ship, step: Double, cap: Double) {
        if ship.inertialess {
            ship.throttleSpeed = min(max(ship.throttleSpeed + OriginalClock.perSecond(step), 0),
                                     OriginalClock.perSecond(cap))
        } else {
            ship.addPolarVelocityWithClamp(heading: ship.angle, step: OriginalClock.perSecond(step),
                                           max: OriginalClock.perSecond(cap))
        }
    }
}
