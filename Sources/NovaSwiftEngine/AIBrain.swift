import Foundation
import NovaSwiftKit

/// What an NPC is currently doing. Transitions are driven by `AIBrain.think`
/// from perception (nearest hostile), health, and disposition (`AIType`).
/// A standing order the player issues to their escorts (the EV Nova escort
/// command window). Drives how a `leaderID == 0` ship behaves in `think`.
public enum EscortOrder: String, Sendable, CaseIterable, Identifiable {
    case aggressive   // hunt the player's target / any nearby hostile
    case defensive    // fly formation, adopt the player's target, fight back
    case evasive      // avoid combat; flee threats, otherwise keep formation
    case hold         // stop and hold position; don't follow or engage
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .aggressive: return "Aggressive"
        case .defensive:  return "Defensive"
        case .evasive:    return "Evasive"
        case .hold:       return "Hold Position"
        }
    }
}

public enum AIState: String, Sendable {
    case spawning      // just arrived; pick an initial goal
    case traveling     // trader heading to a planet
    case landing       // trader on final approach, diving into the spaceport
    case patrolling    // warship roaming, watching for hostiles
    /// Interceptor idle default: holds a slow orbit near a stellar object,
    /// buzzing passing ships, instead of walking the warship patrol beat.
    case orbiting
    /// Local authority (system-govt / allied police) closing on a ship to run a
    /// scan pass over it, then peeling back to its patrol/orbit.
    case scanning
    case attacking     // engaged with a target
    case fleeing       // hurt / outmatched; running for the hyperspace edge
    case departing     // leaving the system (heading to the jump edge)
    case escorting     // sticking with a fleet leader
    /// Answering the player's paid "Request Assistance" hail: fly to the
    /// player, dock and deliver fuel/repairs, then optionally help fight
    /// whatever the player currently has targeted before moving on.
    case assisting
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
    /// Fleet leader to escort, if any. A `leaderID` of `World.playerEntityID`
    /// (0) marks a ship as one of the *player's* escorts — commanded via
    /// `escortOrder`.
    public var leaderID: Int?
    /// This escort's slot in the leader's formation (0-based), for tidy wings.
    public var formationSlot = 0
    /// Standing order for a player escort (`leaderID == 0`). Ignored by ordinary
    /// NPC-fleet escorts, which always behave as `.defensive`.
    public var escortOrder: EscortOrder = .defensive
    /// Set once this assist run has docked with the player and delivered
    /// fuel/repairs — reset every time `beginAssisting()` starts a new run.
    public var assistDelivered = false

    // Tunables (world units).
    public var scanRange: Double = 1500
    /// A steady wander/travel destination for non-combat states. Readable
    /// (but engine-only writable) so the in-game AI debug overlay can draw the
    /// line each ship is steering along — its current "path".
    public internal(set) var destination: Vec2?
    /// The stellar object id a trader is travelling to / landing on. Exposed
    /// read-only for the same AI debug overlay.
    public internal(set) var destSpob: Int?
    /// Which stop on the patrol beat we're heading to next.
    var patrolIndex = 0
    var stateClock: Double = 0
    var repathClock: Double = 0
    /// "name [id]" tag for logging, refreshed at the top of every `think()` so
    /// state-transition/fallback logs can identify which ship they're about.
    private var shipTag = "NPC"
    /// Log-on-change: whether we currently have a valid firing solution on
    /// our target (in range + aimed) — flips are exactly the "why didn't my
    /// weapon fire" moments for AI-controlled ships.
    private var hadFiringSolution: Bool?
    /// Slow rotation used to walk an interceptor's holding-pattern orbit.
    var orbitAngle: Double = 0
    /// The ship this authority vessel is currently flying over to scan.
    var scanTargetID: Int?
    /// Set once the current scan pass has been reported (so we emit the world
    /// scan event exactly once per pass), reset when a new pass begins.
    private var scanReported = false
    /// Time before this ship will look to scan another passing vessel — keeps
    /// patrols from chain-scanning everything in sight.
    var scanCooldown: Double = 0

    public init(aiType: AIType, govt: Int) {
        self.aiType = aiType
        self.homeGovt = govt
    }

    /// Start (or restart) a paid assist run: fly to the player and dock. Called
    /// from the app layer when the player accepts a "Request Assistance" hail.
    public func beginAssisting() {
        assistDelivered = false
        state = .assisting
        stateClock = 0
    }

    // MARK: Perception

    /// Is `other` an enemy of this ship right now? Disabled hulks are helpless and
    /// no longer count as threats or targets.
    func isHostile(_ me: Ship, _ other: Ship, _ world: World) -> Bool {
        guard other.isAlive, !other.disabled, other.entityID != me.entityID else { return false }
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

    /// True once every ammo-*using* weapon mount is dry (`ammo == 0`). Ships
    /// that carry only unlimited-ammo weapons (`ammo == -1`, e.g. most guns
    /// and beams) never trigger this — there's nothing to run dry on.
    func outOfAmmo(_ me: Ship) -> Bool {
        let ammoMounts = me.weapons.filter { $0.ammo >= 0 }
        guard !ammoMounts.isEmpty else { return false }
        return ammoMounts.allSatisfy { $0.ammo == 0 }
    }

    /// Interceptor-only "piracy police" perception: the Bible has interceptors
    /// "attacking any ship that fires on or attempts to board another,
    /// non-enemy ship while the interceptor is watching." (Boarding isn't
    /// modeled in this engine, so this checks active targeting only.) Finds
    /// the nearest ship currently targeting some third ship that ISN'T one of
    /// *my* enemies — i.e. an ordinary ship picking a fight it shouldn't.
    func pickPirateInterventionTarget(_ me: Ship, _ world: World) -> Ship? {
        var best: Ship?
        var bestDist = scanRange
        for aggressor in world.allShips
        where aggressor.entityID != me.entityID && aggressor.isAlive && !aggressor.disabled {
            guard let victimID = aggressor.currentTargetID, victimID != me.entityID,
                  let victim = world.ship(id: victimID), victim.isAlive, !victim.disabled,
                  victim.government != aggressor.government,
                  !isHostile(me, victim, world) else { continue }
            let d = (aggressor.position - me.position).length
            if d < bestDist { bestDist = d; best = aggressor }
        }
        return best
    }

    /// Is this ship the local authority — i.e. does it belong to the government
    /// that controls this system, or an ally of it? Only the local authority
    /// runs the patrol beat / scans traffic; a foreign warship passing through
    /// doesn't police someone else's space. When the system is unowned
    /// (`independentGovt`), anyone armed may patrol.
    func isSystemAuthority(_ me: Ship, _ world: World) -> Bool {
        let sg = world.systemContext.systemGovt
        guard sg >= 128 else { return true }
        if me.government == sg { return true }
        return world.diplomacy?.areAllied(me.government, sg) ?? false
    }

    /// Where a disposition idles when it has nothing better to do. Traders
    /// always travel to a planet. Warships/interceptors only *patrol* (or hold
    /// orbit and scan) when they're the local authority; a foreign combat ship
    /// with no fight to join just crosses the system like a trader and leaves,
    /// so patrols read as "this government's police," not a free-for-all.
    private func defaultIdleState(_ me: Ship, _ world: World) -> AIState {
        if aiType.isTrader { return .traveling }
        guard isSystemAuthority(me, world) else { return .traveling }
        return aiType == .interceptor ? .orbiting : .patrolling
    }

    /// EV Nova's combat-odds check (`gövt.MaxOdds`): before picking a fight, a
    /// government-minded ship weighs the summed `shïp.Strength` of nearby
    /// enemies (scaled 30%-100% by each ship's current shield fraction)
    /// against the summed strength of nearby friends (itself included). A
    /// `MaxOdds` of 100 means "won't fight unless as strong or stronger";
    /// 200 tolerates being outnumbered 2-to-1, etc. Ships with no government
    /// entry (independents) always fight — Nova only gates this for ships
    /// that belong to a government with the field set.
    func favorableOdds(_ me: Ship, _ world: World) -> Bool {
        guard let dip = world.diplomacy, let gov = dip.govt(me.government) else { return true }
        // A MaxOdds of 0 means the field isn't in play for this government (no
        // stock/plugin data sets it to a real threshold) — don't let an unset
        // field make every ship of that govt permanently passive.
        guard gov.maxOdds > 0 else { return true }
        func power(_ s: Ship) -> Double { s.combatStrength * (0.3 + 0.7 * s.shieldFraction) }
        var enemyStrength = 0.0
        var friendlyStrength = power(me)
        for other in world.allShips where other.entityID != me.entityID && other.isAlive && !other.disabled {
            if isHostile(me, other, world) {
                enemyStrength += power(other)
            } else if other.government == me.government || dip.areAllied(me.government, other.government) {
                friendlyStrength += power(other)
            }
        }
        guard enemyStrength > 0 else { return true }
        let tolerated = friendlyStrength * (Double(gov.maxOdds) / 100.0)
        return enemyStrength <= tolerated
    }

    // MARK: Decide

    public func think(ship me: Ship, world: World, dt: Double) -> ControlIntent {
        shipTag = "\(me.name) [\(me.entityID)]"
        stateClock += dt
        repathClock -= dt
        scanCooldown -= dt

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
        // Bible: "AI ships of this type will run away/dock if out of ammo for
        // all ammo-using weapons" (`shïp.Flags2` 0x0080) — checked regardless
        // of disposition; dock (head to a planet) if nothing's chasing us,
        // otherwise run for the edge.
        let ammoExhausted = me.fleeWhenOutOfAmmo && outOfAmmo(me)

        switch aiType {
        case .wimpyTrader:
            if threat != nil { enter(.fleeing) }
        case .braveTrader:
            if ammoExhausted {
                enter(threat != nil ? .fleeing : .traveling)
            } else if let th = threat, armed, (th.position - me.position).length <= weaponRange(me) {
                // Bible: "fights back when attacked, but runs away when his
                // attacker is out of range" — not a hull-% threshold.
                targetID = th.entityID; enter(.attacking)
            } else if threat != nil {
                enter(.fleeing)
            }
        case .warship, .interceptor:
            if ammoExhausted {
                enter(threat != nil ? .fleeing : .traveling)
            } else if warshipRetreat { enter(.fleeing) }
            else if let th = threat, armed, state == .attacking || favorableOdds(me, world) {
                targetID = th.entityID; enter(.attacking)
            } else if aiType == .interceptor, armed, isSystemAuthority(me, world),
                      favorableOdds(me, world), let culprit = pickPirateInterventionTarget(me, world) {
                // No direct threat of our own — but someone's picking on a
                // non-enemy while we're watching. Only the local authority
                // steps in (it's *their* space to police), and only when the
                // odds favor it — so interventions stay occasional, not a
                // system-wide brawl every time two ships tangle.
                targetID = culprit.entityID; enter(.attacking)
            }
        case .unknown:
            if let th = threat, armed { targetID = th.entityID; enter(.attacking) }
        }

        // If an escort and its leader is alive, prefer escorting/adopting target.
        // Player escorts (leaderID == 0) additionally obey their standing order.
        if let lid = leaderID {
            if let leader = world.ship(id: lid), leader.isAlive {
                let isPlayerEscort = (lid == World.playerEntityID)
                let order: EscortOrder = isPlayerEscort ? escortOrder : .defensive
                switch order {
                case .hold:
                    // Hold position: don't follow or fight; coast to a stop.
                    targetID = nil
                    me.currentTargetID = nil
                    return ControlIntent()
                case .evasive:
                    // Keep formation, but run from any real threat rather than engage.
                    if threat != nil { enter(.fleeing) }
                    else if state != .attacking { enter(.escorting) }
                case .aggressive:
                    // Adopt the leader's target, else hunt the nearest hostile.
                    let mark = leader.currentTargetID.flatMap { world.ship(id: $0) } ?? threat
                    if armed, let m = mark, isHostile(me, m, world) {
                        targetID = m.entityID; enter(.attacking)
                    } else if state != .attacking && state != .fleeing {
                        enter(.escorting)
                    }
                case .defensive:
                    if state != .attacking && state != .fleeing { enter(.escorting) }
                    // Adopt the leader's target when it has one.
                    if state != .fleeing, let lt = leader.currentTargetID,
                       let lts = world.ship(id: lt), isHostile(me, lts, world), armed {
                        targetID = lt; enter(.attacking)
                    }
                }
            } else {
                leaderID = nil   // leader gone — act on our own disposition
            }
        }

        // First goal after spawning.
        if state == .spawning {
            enter(defaultIdleState(me, world))
        }

        // Drop out of combat if the target is gone. Re-resolves `targetID`
        // fresh here rather than reusing the pre-switch `threat` snapshot —
        // `threat` only tracks ordinary diplomatic hostiles, so it's nil for
        // a piracy-police intervention target the switch just picked this
        // same frame, which would otherwise immediately undo it.
        if state == .attacking, targetID == nil || world.ship(id: targetID ?? -999)?.isAlive != true {
            enter(defaultIdleState(me, world))
        }

        // Local authority on its idle beat (patrolling or holding orbit) will,
        // now and then, break off to fly over and scan a passing ship — the
        // player first. This is what makes police "check you out" instead of
        // ignoring you. Not while escorting a leader, and never chain-scanning.
        if (state == .patrolling || state == .orbiting), armed, scanCooldown <= 0,
           leaderID == nil, isSystemAuthority(me, world),
           let mark = pickScanTarget(me, world) {
            scanTargetID = mark.entityID
            scanReported = false
            enter(.scanning)
        }

        me.currentTargetID = (state == .attacking) ? targetID : nil

        switch state {
        case .attacking:  return attack(me, world)
        case .fleeing:    return flee(me, world)
        case .traveling:  return travel(me, world)
        case .landing:    return land(me, world)
        case .patrolling: return patrol(me, world, dt)
        case .orbiting:   return orbit(me, world, dt)
        case .scanning:   return scan(me, world)
        case .departing:  return depart(me, world)
        case .escorting:  return escort(me, world)
        case .assisting:  return assist(me, world)
        case .spawning:   return ControlIntent()
        }
    }

    private func enter(_ s: AIState) {
        guard s != state else { return }
        let tag = shipTag, from = state
        Log.ai.debug("\(tag) AI state \(from.rawValue) -> \(s.rawValue)")
        state = s
        stateClock = 0
        if s == .traveling || s == .patrolling || s == .orbiting { destination = nil }
        if s == .fleeing || s == .departing { /* set outbound below */ }
    }

    // MARK: Behaviors

    /// True if the ship has a working afterburner and enough fuel to justify a
    /// burn (we leave a reserve so ships don't strand themselves bone-dry).
    private func canBurn(_ me: Ship) -> Bool {
        me.afterburner != nil && me.fuel > me.maxFuel * 0.15
    }

    /// Close to weapon range, lead the target, and fire when lined up.
    private func attack(_ me: Ship, _ world: World) -> ControlIntent {
        guard let tid = targetID, let target = world.ship(id: tid),
              target.isAlive, !target.disabled else {
            // No valid target to press the attack on — this is the "NPC just
            // stops fighting/sits there" fallback path.
            let tag = shipTag, fallback = aiType.isTrader ? "traveling" : "patrolling"
            Log.ai.debug("\(tag) attack target invalid or gone — falling back to \(fallback)")
            enter(defaultIdleState(me, world))
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
            if aimError < .pi / 2 {
                intent.thrust = true
                // Interceptors light the afterburner to run a fleeing quarry down
                // when it's far and we're pointed dead at it.
                if aiType == .interceptor && dist > range * 1.5
                    && aimError < 0.5 && canBurn(me) { intent.afterburner = true }
            }
        } else if dist < standoff * 0.6 {
            // Too close — ease off the throttle (simple strafing feel).
            intent.thrust = false
        }
        // Fire when the target is within reach and in the firing arc.
        let inFiringSolution = dist <= range && aimError < 0.22
        if hadFiringSolution != inFiringSolution {
            hadFiringSolution = inFiringSolution
            let tag = shipTag
            Log.ai.debug("\(tag) firing solution \(inFiringSolution ? "acquired" : "lost") on target [\(tid)] (dist=\(Int(dist)) range=\(Int(range)) aimError=\(aimError, format: .fixed(precision: 2)))")
        }
        if inFiringSolution {
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
        if abs(angleDelta(from: me.angle, to: out.angle)) < .pi / 2 {
            intent.thrust = true
            // Panic burn: when running and pointed away, empty the tank to escape.
            if canBurn(me) { intent.afterburner = true }
        }
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

    /// Trader travel: pick a planet and cruise toward it, then hand off to a
    /// landing approach. With nowhere to land, just cross the system and leave.
    private func travel(_ me: Ship, _ world: World) -> ControlIntent {
        if destination == nil {
            if let body = pickPlanetBody(world) {
                destSpob = body.id
                destination = body.position
            } else {
                enter(.departing)
                return depart(me, world)
            }
        }
        guard let dest = destination else { return depart(me, world) }
        // Begin the landing dive once we're on the doorstep.
        if (dest - me.position).length < 340 { enter(.landing) }
        return arrive(me, to: dest, slowRadius: 260)
    }

    /// Final approach: settle onto the pad, then dock. Setting `wantsToLand` lets
    /// the world remove the ship into the spaceport and fire a `shipLanded` event.
    private func land(_ me: Ship, _ world: World) -> ControlIntent {
        guard let sid = destSpob,
              let body = world.systemContext.bodies.first(where: { $0.id == sid }) else {
            let tag = shipTag, spobDesc = destSpob.map(String.init) ?? "nil"
            Log.ai.debug("\(tag) landing target spob \(spobDesc) no longer resolves — aborting approach")
            destination = nil; destSpob = nil
            enter(defaultIdleState(me, world))
            return ControlIntent()
        }
        let dist = (body.position - me.position).length
        let slowEnough = me.velocity.length < me.stats.maxSpeed * 0.35
        // Touch down when we're over the pad and slow — or give up circling and
        // set down anyway after a while, so no trader gets stuck orbiting.
        if (dist < body.radius + 40 && slowEnough) || stateClock > 14 {
            me.landingSpob = sid
            me.wantsToLand = true
            return ControlIntent()
        }
        return arrive(me, to: body.position, slowRadius: max(160, body.radius + 120))
    }

    /// Warship patrol: fly a steady beat from one stellar object to the next — a
    /// believable circuit of the system. No random cross-system yanks: the
    /// "check the player out" behavior now lives in the dedicated `.scanning`
    /// state, so a patrol on its beat reads as *on duty*, not wandering in
    /// circles. Repaths only when it actually reaches a waypoint (or a long
    /// safety timeout), not every few seconds.
    private func patrol(_ me: Ship, _ world: World, _ dt: Double) -> ControlIntent {
        if destination == nil || repathClock <= 0 || (destination! - me.position).length < 240 {
            destination = pickPatrolPoint(me, world)
            repathClock = 14
        }
        return arrive(me, to: destination ?? me.position, slowRadius: 180)
    }

    /// Interceptor idle default: hold a slow, wide orbit around the nearest
    /// stellar object — the Bible's "parks in orbit around a planet if he can't
    /// find any [enemies]." The old random "buzz a passing ship" leg is gone;
    /// scanning traffic is now the deliberate `.scanning` state, so orbit is
    /// just a calm holding pattern.
    private func orbit(_ me: Ship, _ world: World, _ dt: Double) -> ControlIntent {
        // Advance slowly around a fixed hub so the path is a smooth ring, not a
        // twitchy re-pick every few seconds.
        orbitAngle += 0.6 * dt
        let ctx = world.systemContext
        let hub = ctx.bodies.min(by: {
            ($0.position - me.position).length < ($1.position - me.position).length
        })
        let center = hub?.position ?? ctx.center
        let radius = (hub?.radius ?? 200) + 320
        destination = center + Vec2(sin(orbitAngle), cos(orbitAngle)) * radius
        return arrive(me, to: destination ?? me.position, slowRadius: 150)
    }

    /// Scanning pass: the local authority flies over a ship to look it over,
    /// then peels back to its beat. Closes to a scan range, fires the world's
    /// (cosmetic) scan event once, holds a beat alongside, then resumes.
    private func scan(_ me: Ship, _ world: World) -> ControlIntent {
        guard let tid = scanTargetID, let target = world.ship(id: tid),
              target.isAlive, !target.disabled else {
            scanTargetID = nil
            enter(defaultIdleState(me, world))
            return ControlIntent()
        }
        let dist = (target.position - me.position).length
        let scanCompleteRange = 240.0
        if dist < scanCompleteRange {
            if !scanReported {
                scanReported = true
                stateClock = 0
                world.reportScan(scannerID: me.entityID, targetID: tid, at: target.position)
                Log.ai.debug("\(self.shipTag) scanned [\(tid)] (\(target.name))")
            }
            // Hold formation alongside briefly, then break off.
            if stateClock > 1.5 {
                scanTargetID = nil
                scanCooldown = 22
                enter(defaultIdleState(me, world))
            }
            return arrive(me, to: target.position, slowRadius: 260)
        }
        // Give up if the mark runs and we can't close in reasonable time.
        if stateClock > 12 {
            scanTargetID = nil
            scanCooldown = 18
            enter(defaultIdleState(me, world))
            return ControlIntent()
        }
        // Lead the target a touch so we actually intercept rather than tail-chase.
        let lead = target.velocity * 0.5
        return arrive(me, to: target.position + lead, slowRadius: 200)
    }

    /// Escort: hold a numbered slot in a tight triangle wing off the leader,
    /// rotated to the leader's heading. The leader flies the point; escorts fill
    /// alternating left/right rows stepping back and out, so the group flies as a
    /// crisp delta, not a swarm — and holds it while the leader cruises (matching
    /// its heading and keeping pace) instead of braking every time it catches up.
    /// They only leave this to attack when the leader actually engages (handled
    /// in `think`), then fall straight back into the wing.
    private func escort(_ me: Ship, _ world: World) -> ControlIntent {
        guard let lid = leaderID, let leader = world.ship(id: lid),
              leader.isAlive, !leader.disabled else {
            let tag = shipTag, leaderDesc = leaderID.map(String.init) ?? "nil"
            Log.ai.debug("\(tag) escort leader [\(leaderDesc)] gone — reverting to own disposition")
            leaderID = nil
            enter(defaultIdleState(me, world))
            return ControlIntent()
        }
        // Slot → (side, rank): even slots to the right, odd to the left, each
        // successive rank stepping one notch further back and out — the two
        // trailing edges of a triangle with the leader at its apex.
        let side: Double = (formationSlot % 2 == 0) ? 1 : -1
        let rank = Double(formationSlot / 2 + 1)
        let lateral = side * 72 * rank   // right of the leader (+) / left (−)
        let behind = -64 * rank          // trailing the leader
        // Leader frame: forward = (sin a, cos a); right = (cos a, −sin a).
        let fwd = Vec2(sin(leader.angle), cos(leader.angle))
        let right = Vec2(cos(leader.angle), -sin(leader.angle))
        let station = leader.position + fwd * behind + right * lateral
        let toStation = station - me.position
        let d = toStation.length
        let leaderMoving = leader.velocity.length > leader.stats.maxSpeed * 0.12

        // On station: lock to the leader's heading so the wing points as one. If
        // the leader is under way, keep thrusting to hold pace (a purely braking
        // `arrive` would sag out of formation the moment the leader accelerates).
        if d < 46 {
            var intent = ControlIntent()
            intent.desiredHeading = leader.angle
            if leaderMoving, abs(angleDelta(from: me.angle, to: leader.angle)) < .pi / 2,
               me.velocity.length < leader.velocity.length { intent.thrust = true }
            return intent
        }
        // Off station: while the leader is moving, aim a bit ahead of the slot so
        // we close the gap and keep up rather than tail-chasing a moving point.
        if leaderMoving {
            return seek(me, to: station + leader.velocity * 0.4)
        }
        return arrive(me, to: station, slowRadius: 120)
    }

    /// Fly to the player and dock to deliver the paid assist (fuel/repairs,
    /// applied once via `World.deliverAssistance`). After delivering: if the
    /// player currently has a hostile ship targeted and we're armed, pitch in
    /// against it (reusing `attack()` wholesale — once that target is gone,
    /// `.attacking`'s own cleanup releases us back to our own business);
    /// otherwise linger briefly, then depart.
    private func assist(_ me: Ship, _ world: World) -> ControlIntent {
        let player = world.player
        if !assistDelivered {
            let dist = (player.position - me.position).length
            if dist < 90 {
                world.deliverAssistance(from: me.entityID)
                assistDelivered = true
                stateClock = 0
            }
            return arrive(me, to: player.position, slowRadius: 140)
        }
        if weaponRange(me) > 0, let tid = player.currentTargetID, let target = world.ship(id: tid),
           target.isAlive, !target.disabled,
           world.diplomacy?.isHostileToPlayer(target.government) == true,
           (target.position - me.position).length <= scanRange {
            targetID = tid
            enter(.attacking)
            return attack(me, world)
        }
        if stateClock > 4 { enter(.departing) }
        return arrive(me, to: player.position, slowRadius: 200)
    }

    // MARK: Steering primitives (each returns a ControlIntent)

    /// Steering — the one primitive behind every non-combat navigation state.
    /// Flight here is pure Newtonian (no drag), so naive "point the nose at the
    /// target and thrust" lets a ship with any built-up momentum slide off-course
    /// and loop back to re-correct — the drift the player sees. An earlier version
    /// of this fix steered along the raw *difference* between the velocity we want
    /// and the velocity we have, but that blends two independently-changing
    /// quantities (our shrinking distance and our own thrust-shifted velocity)
    /// into one heading — close to a target, that blend swings fast enough that
    /// the turn-rate-limited nose can never catch it and just spins in place
    /// (confirmed against real ship stats: an Argosy-class hull span 500°+ of
    /// nose rotation approaching a planet while its velocity barely turned at
    /// all — "angled one way, flying towards another"). Two stable, slow-changing
    /// headings instead of one jumpy blended one:
    ///
    ///   • normally: aim at the point, nudged opposite our own cross-track drift
    ///     so the path straightens instead of curving in — a smooth, position-
    ///     driven aim that only shifts as fast as we actually move;
    ///   • badly overshooting an arrival (closing much faster than this range
    ///     calls for): aim retrograde — straight opposite our *current* velocity
    ///     — a heading that only drifts as fast as thrust itself changes it, so
    ///     the brake is a clean flip-and-burn instead of a chase.
    private func navigate(_ me: Ship, to point: Vec2, slowRadius: Double = 0) -> ControlIntent {
        var intent = ControlIntent()
        let toTarget = point - me.position
        let dist = toTarget.length
        guard dist > 1 else { intent.desiredHeading = me.angle; return intent }
        let dir = toTarget * (1 / dist)
        let cruise = me.stats.maxSpeed
        let along = me.velocity.dot(dir)   // speed component closing on the point
        let speed = me.velocity.length

        // A sluggish turner can't just start braking at a fixed distance — the
        // 180° flip to point retrograde itself eats runway (it coasts forward the
        // whole time it's turning), so a slow-turning hull needs to start easing
        // off much further out than a nimble one or it'll still be mid-turn when
        // it reaches the point. Budget the flip's coast distance plus the actual
        // braking distance, and widen the slow zone to whichever of that or the
        // caller's `slowRadius` is bigger — so the desired-speed taper below
        // actually gives it enough room to execute. Sized off `cruise`, the
        // ship's fixed top speed, not the current (shrinking-as-we-brake) `along`
        // — basing it on a live, decelerating value would shrink the zone as we
        // slow down, which can flag us as "out of the zone" again mid-brake and
        // flip straight back to full-cruise thrust: an oscillation that repeatedly
        // re-triggers the flip, the actual cause of the endless-spin bug.
        let flipTime = Double.pi / max(me.stats.turnRate, 0.05)
        let stopDistance = cruise * flipTime + (cruise * cruise) / (2 * max(me.stats.acceleration, 1))
        let effectiveSlowRadius = slowRadius > 0 ? max(slowRadius, stopDistance) : 0
        let desiredSpeed = (effectiveSlowRadius > 0 && dist < effectiveSlowRadius)
            ? cruise * (dist / effectiveSlowRadius) : cruise

        if effectiveSlowRadius > 0, dist < effectiveSlowRadius, along > desiredSpeed + cruise * 0.15, speed > cruise * 0.1 {
            let retro = (me.velocity * -1).angle
            intent.desiredHeading = retro
            if abs(angleDelta(from: me.angle, to: retro)) < .pi / 2 { intent.thrust = true }
            return intent
        }

        let crossVel = me.velocity - dir * along
        let aim = toTarget - crossVel * 0.6
        let heading = aim.length > 1 ? aim.angle : dir.angle
        intent.desiredHeading = heading
        let deadband = cruise * 0.03    // ignore trivial shortfalls so we don't jitter on course
        if along < desiredSpeed - deadband, abs(angleDelta(from: me.angle, to: heading)) < .pi / 2 {
            intent.thrust = true
        }
        return intent
    }

    /// Head for a point at cruise (no arrival slowdown), steering momentum so we
    /// track the line rather than drift off it.
    private func seek(_ me: Ship, to point: Vec2) -> ControlIntent {
        navigate(me, to: point)
    }

    /// Fly to a point and settle onto it, braking smoothly inside `slowRadius`
    /// so the ship arrives instead of wheeling around the waypoint in little loops.
    private func arrive(_ me: Ship, to point: Vec2, slowRadius: Double) -> ControlIntent {
        navigate(me, to: point, slowRadius: slowRadius)
    }

    // MARK: Waypoint helpers

    /// A landable, inhabited stellar object for a trader to head for — nil if
    /// the system has none, in which case `travel()` departs instead of
    /// picking an uninhabited rock/deep-space stellar to "land" on (AI should
    /// only ever land on inhabited planets/stations; `canLand` already encodes
    /// both — see `StellarBody`'s doc comment).
    private func pickPlanetBody(_ world: World) -> StellarBody? {
        let landable = world.systemContext.bodies.filter { $0.canLand }
        guard !landable.isEmpty else { return nil }
        return landable[world.rng.int(in: 0...(landable.count - 1))]
    }

    /// The next stop on a patrol beat: the following stellar object in the
    /// system, walked in order so a patrol traces a believable circuit of the
    /// system's planets rather than picking random points (which read as aimless
    /// circling). Scanning traffic is a separate deliberate state now.
    private func pickPatrolPoint(_ me: Ship, _ world: World) -> Vec2 {
        let ctx = world.systemContext
        let stops = ctx.bodies
        if !stops.isEmpty {
            patrolIndex = (patrolIndex + 1) % stops.count
            let b = stops[patrolIndex]
            // A small fixed standoff off the body, not a big random jitter, so
            // the waypoint is stable and the ship doesn't wander around it.
            let off = Vec2(world.rng.double(in: -110...110), world.rng.double(in: -110...110))
            return b.position + off
        }
        // Empty system: loiter somewhere inside the jump radius.
        let r = ctx.jumpRadius * 0.5
        return ctx.center + Vec2(world.rng.double(in: -r...r), world.rng.double(in: -r...r))
    }

    /// Who this authority ship should fly over and scan, if anyone. The player
    /// is the priority mark (that's the "police check you out" beat the player
    /// actually notices); otherwise the nearest passing non-hostile ship of a
    /// *different* government (you don't scan your own side). `nil` when nothing
    /// worth scanning is close enough.
    private func pickScanTarget(_ me: Ship, _ world: World) -> Ship? {
        let ctx = world.systemContext
        let reach = min(scanRange, ctx.jumpRadius * 0.7)
        let player = world.player
        let toPlayer = (player.position - me.position).length
        // Prefer the player when reasonably close and not already hostile — but
        // not if some other authority ship scanned them recently (`World.playerScanCooldown`),
        // so a busy system doesn't chain-scan the player the moment each ship's
        // own cooldown expires.
        if player.isAlive, toPlayer < reach, world.playerScanCooldown <= 0,
           world.diplomacy?.isHostileToPlayer(me.government) != true, !provokedByPlayer {
            return player
        }
        // Otherwise the nearest neutral ship of another government.
        var best: Ship?
        var bestDist = reach
        for other in world.allShips
        where other.entityID != me.entityID && !other.isPlayer && other.isAlive
              && !other.disabled && other.government != me.government
              && !isHostile(me, other, world) {
            let d = (other.position - me.position).length
            if d < bestDist { bestDist = d; best = other }
        }
        return best
    }
}
