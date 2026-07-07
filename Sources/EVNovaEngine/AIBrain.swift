import Foundation
import EVNovaKit

/// What an NPC is currently doing. Transitions are driven by `AIBrain.think`
/// from perception (nearest hostile), health, and disposition (`AIType`).
public enum AIState: String, Sendable {
    case spawning      // just arrived; pick an initial goal
    case traveling     // trader heading to a planet
    case patrolling    // warship roaming, watching for hostiles
    case attacking     // engaged with a target
    case fleeing       // hurt / outmatched; running for the hyperspace edge
    case departing     // leaving the system (heading to the jump edge)
    case escorting     // sticking with a fleet leader
}

/// The decision-maker for one NPC ship. Each frame it perceives the world,
/// updates its `state`, and returns a `ControlIntent` — the very same struct the
/// player's input produces. It never touches physics directly; the world steps
/// the ship from the intent, so NPCs and the player obey identical flight rules.
///
/// Fidelity note: the branches mirror EV Nova's dispositions — wimpy traders bolt
/// at the first threat, brave traders trade blows then run when hurt, warships
/// hunt hostiles, interceptors press the attack, and escorts fight for their
/// flagship. Government relations decide who counts as a hostile.
public final class AIBrain {
    public var aiType: AIType
    public var state: AIState = .spawning
    public var homeGovt: Int
    /// Current combat target (entity id).
    public var targetID: Int?
    /// Set true when the player damages this ship — it will fight back even if
    /// its government is otherwise neutral.
    public var provokedByPlayer = false
    /// Fleet leader to escort, if any.
    public var leaderID: Int?

    // Tunables (world units).
    public var scanRange: Double = 1500
    /// A steady wander/travel destination for non-combat states.
    var destination: Vec2?
    var stateClock: Double = 0
    var repathClock: Double = 0

    public init(aiType: AIType, govt: Int) {
        self.aiType = aiType
        self.homeGovt = govt
    }

    // MARK: Perception

    /// Is `other` an enemy of this ship right now?
    func isHostile(_ me: Ship, _ other: Ship, _ world: World) -> Bool {
        guard other.isAlive, other.entityID != me.entityID else { return false }
        if other.isPlayer {
            if provokedByPlayer { return true }
            return world.diplomacy?.isHostileToPlayer(me.government) ?? false
        }
        // NPC vs NPC.
        return world.diplomacy?.areEnemies(me.government, other.government) ?? false
    }

    /// Nearest hostile within scan range, if any.
    func nearestHostile(_ me: Ship, _ world: World) -> Ship? {
        var best: Ship?
        var bestDist = scanRange
        for other in world.allShips where isHostile(me, other, world) {
            let d = (other.position - me.position).length
            if d < bestDist { bestDist = d; best = other }
        }
        return best
    }

    /// This ship's longest weapon reach (0 if unarmed).
    func weaponRange(_ me: Ship) -> Double {
        me.weapons.map { $0.spec.range }.max() ?? 0
    }

    // MARK: Decide

    public func think(ship me: Ship, world: World, dt: Double) -> ControlIntent {
        stateClock += dt
        repathClock -= dt

        // Validate / refresh combat target.
        if let tid = targetID, let t = world.ship(id: tid), t.isAlive,
           (t.position - me.position).length < scanRange * 1.5 {
            // keep it
        } else {
            targetID = nil
        }

        let threat = world.ship(id: targetID ?? -999) ?? nearestHostile(me, world)
        let armed = weaponRange(me) > 0

        // Retreat conditions by disposition.
        let govt = world.diplomacy?.govt(me.government)
        let warshipRetreat = (govt?.warshipsRetreat ?? false) && me.shieldFraction < 0.25
        let traderHurt = me.armorFraction < 0.4

        switch aiType {
        case .wimpyTrader:
            if threat != nil { enter(.fleeing) }
        case .braveTrader:
            if let th = threat, armed, !traderHurt { targetID = th.entityID; enter(.attacking) }
            else if threat != nil && traderHurt { enter(.fleeing) }
            else if threat != nil && !armed { enter(.fleeing) }
        case .warship, .interceptor:
            if warshipRetreat { enter(.fleeing) }
            else if let th = threat, armed { targetID = th.entityID; enter(.attacking) }
        case .unknown:
            if let th = threat, armed { targetID = th.entityID; enter(.attacking) }
        }

        // If an escort and its leader is alive, prefer escorting/adopting target.
        if let lid = leaderID {
            if let leader = world.ship(id: lid), leader.isAlive {
                if state != .attacking && state != .fleeing { enter(.escorting) }
                // Adopt the leader's target when it has one.
                if state != .fleeing, let lt = leader.currentTargetID,
                   let lts = world.ship(id: lt), isHostile(me, lts, world), armed {
                    targetID = lt; enter(.attacking)
                }
            } else {
                leaderID = nil   // leader gone — act on our own disposition
            }
        }

        // First goal after spawning.
        if state == .spawning {
            enter(aiType.isTrader ? .traveling : .patrolling)
        }

        // Drop out of combat if the target is gone.
        if state == .attacking && (targetID == nil || threat == nil) {
            enter(aiType.isTrader ? .traveling : .patrolling)
        }

        me.currentTargetID = (state == .attacking) ? targetID : nil

        switch state {
        case .attacking:  return attack(me, world)
        case .fleeing:    return flee(me, world)
        case .traveling:  return travel(me, world)
        case .patrolling: return patrol(me, world, dt)
        case .departing:  return depart(me, world)
        case .escorting:  return escort(me, world)
        case .spawning:   return ControlIntent()
        }
    }

    private func enter(_ s: AIState) {
        guard s != state else { return }
        state = s
        stateClock = 0
        if s == .traveling || s == .patrolling { destination = nil }
        if s == .fleeing || s == .departing { /* set outbound below */ }
    }

    // MARK: Behaviors

    /// Close to weapon range, lead the target, and fire when lined up.
    private func attack(_ me: Ship, _ world: World) -> ControlIntent {
        guard let tid = targetID, let target = world.ship(id: tid), target.isAlive else {
            enter(aiType.isTrader ? .traveling : .patrolling)
            return ControlIntent()
        }
        var intent = ControlIntent()
        let toTarget = target.position - me.position
        let dist = toTarget.length
        let range = max(120, weaponRange(me))

        // Lead the target so shots and nose end up where it will be.
        let projSpeed = me.weapons.first?.spec.projectileSpeed ?? 600
        let lead = dist / max(1, projSpeed)
        let aimPoint = target.position + target.velocity * lead
        let desired = (aimPoint - me.position).angle
        intent.desiredHeading = desired

        let aimError = abs(angleDelta(from: me.angle, to: desired))
        // Interceptors crowd the target; warships hold at a comfortable range.
        let standoff = aiType == .interceptor ? range * 0.5 : range * 0.7
        if dist > standoff {
            // Thrust when roughly pointed the right way, so we actually close.
            if aimError < .pi / 2 { intent.thrust = true }
        } else if dist < standoff * 0.6 {
            // Too close — ease off the throttle (simple strafing feel).
            intent.thrust = false
        }
        // Fire when the target is within reach and in the firing arc.
        if dist <= range && aimError < 0.22 {
            intent.firePrimary = true
        }
        return intent
    }

    /// Run from the nearest threat toward the hyperspace edge, then jump out.
    private func flee(_ me: Ship, _ world: World) -> ControlIntent {
        var intent = ControlIntent()
        me.wantsToDepart = true
        let threat = nearestHostile(me, world)
        // Outbound direction: away from the system centre, biased away from threat.
        var out = (me.position - world.systemContext.center)
        if out.length < 1 { out = Vec2(0, 1) }
        if let th = threat {
            let away = me.position - th.position
            out = (out.normalized + away.normalized)
        }
        intent.desiredHeading = out.angle
        if abs(angleDelta(from: me.angle, to: out.angle)) < .pi / 2 { intent.thrust = true }
        // Once clear of pursuers and near the edge, this becomes a plain depart.
        if threat == nil { enter(.departing) }
        return intent
    }

    /// Head for the system edge and leave.
    private func depart(_ me: Ship, _ world: World) -> ControlIntent {
        me.wantsToDepart = true
        var out = me.position - world.systemContext.center
        if out.length < 1 { out = Vec2(0, 1) }
        return seek(me, to: me.position + out.normalized * world.systemContext.jumpRadius)
    }

    /// Trader travel: fly to a planet, "land", then leave the system.
    private func travel(_ me: Ship, _ world: World) -> ControlIntent {
        if destination == nil {
            destination = pickPlanet(world) ?? edgePoint(me, world)
        }
        guard let dest = destination else { return depart(me, world) }
        let intent = arrive(me, to: dest, slowRadius: 220)
        if (dest - me.position).length < 160 {
            // Arrived (landed) — off to hyperspace.
            destination = nil
            enter(.departing)
        }
        return intent
    }

    /// Warship patrol: loiter around waypoints, watching for hostiles.
    private func patrol(_ me: Ship, _ world: World, _ dt: Double) -> ControlIntent {
        if destination == nil || repathClock <= 0 || (destination! - me.position).length < 200 {
            destination = pickPatrolPoint(me, world)
            repathClock = 6
        }
        return arrive(me, to: destination ?? me.position, slowRadius: 160)
    }

    /// Escort: keep formation near the leader.
    private func escort(_ me: Ship, _ world: World) -> ControlIntent {
        guard let lid = leaderID, let leader = world.ship(id: lid), leader.isAlive else {
            leaderID = nil
            enter(aiType.isTrader ? .traveling : .patrolling)
            return ControlIntent()
        }
        // Sit off the leader's flank.
        let offset = Vec2(sin(Double(me.entityID)) * 120, cos(Double(me.entityID)) * 120)
        let station = leader.position + offset
        if (station - me.position).length < 90 { return ControlIntent() }
        return arrive(me, to: station, slowRadius: 140)
    }

    // MARK: Steering primitives (each returns a ControlIntent)

    /// Face a point and thrust toward it (no slowing).
    private func seek(_ me: Ship, to point: Vec2) -> ControlIntent {
        var intent = ControlIntent()
        let desired = (point - me.position).angle
        intent.desiredHeading = desired
        if abs(angleDelta(from: me.angle, to: desired)) < .pi / 2 { intent.thrust = true }
        return intent
    }

    /// Face a point, thrust while far, and coast/brake within `slowRadius`.
    private func arrive(_ me: Ship, to point: Vec2, slowRadius: Double) -> ControlIntent {
        var intent = ControlIntent()
        let to = point - me.position
        let dist = to.length
        let desired = to.angle
        intent.desiredHeading = desired
        let aligned = abs(angleDelta(from: me.angle, to: desired)) < .pi / 2
        if dist > slowRadius {
            if aligned { intent.thrust = true }
        } else {
            // Inside the slow zone: gently brake by facing our velocity's reverse.
            if me.velocity.length > me.stats.maxSpeed * 0.25 {
                intent.desiredHeading = (me.velocity * -1).angle
                if abs(angleDelta(from: me.angle, to: intent.desiredHeading!)) < .pi / 3 {
                    intent.thrust = true
                }
            }
        }
        return intent
    }

    // MARK: Waypoint helpers

    private func pickPlanet(_ world: World) -> Vec2? {
        let landable = world.systemContext.bodies.filter { $0.canLand }
        guard !landable.isEmpty else { return world.systemContext.bodies.first?.position }
        var rng = world.rng
        let choice = landable[rng.int(in: 0...(landable.count - 1))]
        world.rng = rng
        return choice.position
    }

    private func pickPatrolPoint(_ me: Ship, _ world: World) -> Vec2 {
        var rng = world.rng
        let r = world.systemContext.jumpRadius * 0.6
        let p = Vec2(rng.double(in: -r...r), rng.double(in: -r...r)) + world.systemContext.center
        world.rng = rng
        return p
    }

    private func edgePoint(_ me: Ship, _ world: World) -> Vec2 {
        var out = me.position - world.systemContext.center
        if out.length < 1 { out = Vec2(0, 1) }
        return world.systemContext.center + out.normalized * world.systemContext.jumpRadius
    }
}
