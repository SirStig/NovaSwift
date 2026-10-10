import Foundation

/// Escort commands (`escort_command_code`).
public enum OriginalEscortCommand {
    public static let formation = 0
    public static let defend = 1
    public static let attack = 2
    public static let returnToHangar = 3
    public static let hold = 4
}

/// Squads: NPC-fleet escort orders, the escort supervisor, leadership
/// succession, formation geometry and the cloak triggers.
extension OriginalAI {

    // MARK: Player orders (Ship_CommandPlayerEscortGroup 0x0045c880)

    /// The port's command-window orders map onto the original's: Aggressive →
    /// Attack, Defensive → Defend, Hold → Hold Position, Evasive (no original
    /// counterpart) → Formation, all to every category.
    func commandPlayerEscorts(_ order: EscortOrder, world: World) {
        let command: Int
        switch order {
        case .aggressive: command = OriginalEscortCommand.attack
        case .defensive: command = OriginalEscortCommand.defend
        case .hold: command = OriginalEscortCommand.hold
        case .evasive: command = OriginalEscortCommand.formation
        }
        commandPlayerEscortGroup(category: nil, command: command, world: world)
    }

    /// `Ship_CommandPlayerEscortGroup` (0x0045c880): give `command` to the
    /// player's escorts of EscortType `category` (0 fighters, 1 medium, 2
    /// warships, 3 freighters; nil every ship, group keys 1–5). Each escort
    /// keeps its own order. Return to Hangar only reaches carried fighters;
    /// any other escort is sent back to Formation instead (if it isn't there
    /// already). Attack copies the player's target unless it flies in the
    /// player's squad. A fighter heading home is turned around by any other
    /// order. Something changed → the HUD reads "New escort orders assigned:
    /// <group> <action>" (STR# 2002 #134–#159) for 250 frames; the text is
    /// returned too.
    @discardableResult
    public func commandPlayerEscortGroup(category: Int?, command: Int, world: World) -> String? {
        let F = OriginalEscortCommand.self
        let host = WorldAIHost(world: world, ai: self)
        // The order keys first set the standing order of the category, or of
        // all four (0x0044b120), which every escort of that EscortType then
        // copies each frame (0x004048a0).
        if let category, (0..<4).contains(category) {
            categoryCommand[category] = command
        } else if category == nil {
            categoryCommand = [command, command, command, command]
        }
        var changed = false
        var reported = command
        // Chatter: one acknowledging escort, picked as the loop goes (the
        // first speaker, then each later one on a coin flip).
        var chatterGovt = -2, chatterVoice = -1
        var voiced = false
        for ship in world.npcs where ship.isAlive && leader(of: ship) == World.playerEntityID {
            let rec = ensureRecord(ship, host: host)
            let hull = host.hull(of: ship)
            if let category, hull.escortClass != category { continue }
            let muted = hull.flags2 & 0x0010 != 0
            var thisChanged = false
            if command != rec.playerOrder {
                rec.escortCommandPending = true
                if rec.behavior == 5 {
                    rec.playerOrder = command
                    thisChanged = true
                } else if command == F.returnToHangar {
                    if rec.playerOrder != F.formation {
                        rec.playerOrder = F.formation
                        reported = F.formation
                        thisChanged = true
                    }
                } else {
                    rec.playerOrder = command
                    thisChanged = true
                }
                if thisChanged && !muted { voiced = true }
            }
            // The port's wing-order readout follows the original order.
            switch rec.playerOrder {
            case F.attack: ship.brain?.escortOrder = .aggressive
            case F.defend: ship.brain?.escortOrder = .defensive
            case F.hold: ship.brain?.escortOrder = .hold
            default: ship.brain?.escortOrder = .evasive
            }
            if rec.playerOrder == F.attack, let targetID = world.player.currentTargetID,
               targetID != rec.primary, !world.isPlayerFleetMember(targetID) {
                rec.primary = targetID
                thisChanged = true
            }
            if command != F.returnToHangar, rec.behavior == 5, rec.state == OriginalAIState.returnToLeader {
                rec.primary = nil
                rec.secondary = .none
                if chatterGovt < -1 || host.random(2) == 0 {
                    chatterVoice = rec.voice
                    chatterGovt = hull.attributesGovt
                }
                thisChanged = true
            }
            if thisChanged { changed = true }
            if changed, !muted, chatterGovt < -1 || host.random(2) == 0 {
                chatterGovt = hull.attributesGovt
                chatterVoice = rec.voice
            }
        }
        guard changed else { return nil }
        defer {
            // The acknowledgement (category 0, or 1 for an Attack on a ship
            // outside the squad) once the readout is up.
            if voiced {
                var chatterCategory = 0
                if reported == F.attack, let t = world.player.currentTargetID.flatMap({ world.ship(id: $0) }),
                   leader(of: t) != World.playerEntityID {
                    chatterCategory = 1
                }
                world.queueCombatChatter(category: chatterCategory, govt: max(-1, chatterGovt), voice: chatterVoice)
            }
        }
        guard let list = world.galaxy?.game.stringList(2002) else { return nil }
        func s(_ i: Int) -> String { list.string(at: i) ?? "" }
        let group: String
        switch category {
        case 0?: group = s(135)
        case 1?: group = s(136)
        case 2?: group = s(137)
        case 3?: group = s(138)
        default: group = s(139)
        }
        let jumping = world.playerJump != nil
        let action: Int
        switch reported {
        case F.returnToHangar: action = jumping ? 150 : 155
        case F.formation: action = jumping ? 151 : 156
        case F.hold: action = jumping ? 152 : 157
        case F.defend: action = jumping ? 153 : 158
        default:
            let target = world.player.currentTargetID.flatMap { world.ship(id: $0) }
            let ownTarget = target.map { leader(of: $0) == World.playerEntityID } ?? true
            action = jumping || ownTarget ? 154 : 159
        }
        let text = s(134) + group + " " + s(action)
        world.postOverlayMessage(text, frames: 250)
        return text
    }

    // MARK: NPC-fleet orders (Ship_IssueEscortOrders 0x004152e0)

    /// Orders per follower category [fighter, medium, warship, freighter],
    /// from the leader's disposition, shields, target and odds.
    func escortOrders(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) -> [Int] {
        let F = OriginalEscortCommand.self
        var commands = [F.returnToHangar, F.returnToHangar, F.returnToHangar, F.returnToHangar]
        let shield = ship.shield, maxShield = ship.maxShield
        if rec.behavior < 3 {
            commands = [shield < maxShield * 0.66 ? F.defend : F.attack, F.defend, F.defend, F.formation]
        } else {
            var targetDisabled = false
            var withinProbe = false
            if let pid = rec.primary, let target = host.ship(pid) {
                // Both range probes read the literal wëap index 1, so "the
                // target outranges the leader" never holds; the envelope only
                // decides the fighters at high shields.
                let locked = records[pid].map { $0.primary == ship.entityID && $0.state == OriginalAIState.attack } ?? false
                if locked {
                    let reach = Int(host.escortProbeRange)
                    withinProbe = Self.axisDistanceSquared(ship.position, target.position) <= reach * reach
                }
                targetDisabled = target.disabled
            }
            if targetDisabled && rec.state == OriginalAIState.board {
                commands = [F.returnToHangar, F.returnToHangar, F.returnToHangar, F.formation]
            } else {
                if shield < maxShield * 0.33 {
                    commands[0] = targetDisabled ? F.attack : F.defend
                    commands[1] = targetDisabled ? F.attack : F.defend
                    commands[2] = F.defend
                } else if shield < maxShield * 0.66 {
                    commands[0] = targetDisabled ? F.attack : F.defend
                    commands[1] = F.attack
                    commands[2] = F.defend
                } else {
                    commands[0] = !targetDisabled && withinProbe ? F.defend : F.attack
                    commands[1] = F.attack
                    commands[2] = rec.odds >= 0 && rec.odds < 0.5 ? F.attack : F.formation
                }
                commands[3] = F.formation
            }
        }
        let state = rec.state
        if ![OriginalAIState.retreat, OriginalAIState.attack, OriginalAIState.board,
             OriginalAIState.disengaged].contains(state) {
            commands = [F.returnToHangar, F.returnToHangar, F.returnToHangar, F.returnToHangar]
        }
        if state == OriginalAIState.retreat {
            if rec.mode == OriginalAIMode.jumpSpinUp || rec.mode == OriginalAIMode.brake {
                commands = [F.returnToHangar, F.returnToHangar, F.returnToHangar, F.returnToHangar]
            } else {
                commands[0] = F.defend
                commands[1] = F.defend
            }
        }
        return commands
    }

    func issueEscortOrders(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        let commands = escortOrders(rec, ship: ship, host: host)
        for other in host.ships where !other.isPlayer && other.entityID != ship.entityID {
            guard leader(of: other) == ship.entityID, let o = records[other.entityID], o.behavior > 4 else { continue }
            let category = host.hull(of: other).escortClass
            guard (0..<4).contains(category) else { continue }
            o.escortCommand = commands[category]
            o.escortCommandPending = true
        }
    }

    // MARK: Escort supervisor (Ship_UpdateEscortAI 0x004048a0)

    func escortSupervisor(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        let S = OriginalAIState.self, F = OriginalEscortCommand.self
        guard rec.state != S.yield else { return }
        let hull = host.hull(of: ship)
        let leaderID = leader(of: ship)
        if leaderID != World.playerEntityID, rec.state == S.refuel || rec.state == S.repair { return }

        func releaseToDefault() {
            setLeader(ship, nil)
            rec.behavior = hull.inherentAI
            rec.state = S.idle
            rec.mode = OriginalAIMode.idle
            rec.jumpTimer = -1
        }
        guard let leaderID, let leaderShip = host.ship(leaderID), leaderShip.isAlive else {
            releaseToDefault()
            return
        }
        let leaderRec = records[leaderID]

        if leaderShip.isPlayer {
            // A player escort outside a mission fleet flies for no government,
            // and keeps a chatter voice of 0 or 1.
            if ship.missionID == nil { ship.government = independentGovt }
            if rec.voice != 0 && rec.voice != 1 { rollVoice(rec, hull: hull, host: host) }
        }

        // The leader is preparing to jump: mirror its destination and follow
        // its spin-up (state 0x0B). An inertialess escort jumps on its own.
        let leaderJump = leaderShip.isPlayer ? host.playerJumpTimer : (leaderRec?.jumpTimer ?? 0)
        let npcFollowMode = !leaderShip.isPlayer
            && (leaderRec?.mode == OriginalAIMode.jumpSpinUp || leaderRec?.mode == OriginalAIMode.squadJumpHold)
        let npcJumpPrep = !leaderShip.isPlayer && leaderRec?.state == S.departJump
            && leaderRec?.mode == OriginalAIMode.brake
        if npcFollowMode || npcJumpPrep || leaderJump > 0 {
            rec.secondary = leaderRec?.secondary ?? .none
            rec.primary = nil
            if !leaderShip.isPlayer && ship.isInertialessNow {
                setLeader(ship, nil)
                rec.behavior = hull.inherentAI
                rec.state = S.departJump
                rec.mode = OriginalAIMode.jumpSpinUp
                rec.jumpTimer = 0
                return
            }
            rec.state = S.squadJump
        }

        if let pid = rec.primary {
            let t = host.ship(pid)
            if t == nil || !t!.isAlive || (t!.disabled && rec.escortCommand != F.attack) { rec.primary = nil }
        }

        if leaderShip.isPlayer {
            // The standing order of this escort's category; −1 is Formation,
            // and Return only holds for a carried fighter that was ordered.
            let category = hull.escortClass
            rec.playerOrder = (0..<4).contains(category) ? categoryCommand[category] : -1
            if rec.playerOrder == -1 { rec.playerOrder = F.formation }
            if rec.playerOrder == F.returnToHangar, rec.behavior != 5 || !rec.escortCommandPending {
                rec.playerOrder = F.formation
            }
            rec.escortCommand = rec.playerOrder
        } else if leader(of: leaderShip) == World.playerEntityID, let sub = leaderRec {
            // A wingman of one of the player's escorts mirrors its orders.
            if sub.escortCommand == F.defend || sub.escortCommand == F.attack {
                rec.escortCommand = sub.state == S.escortStation ? F.returnToHangar : sub.escortCommand
            } else {
                rec.escortCommand = F.returnToHangar
            }
        }

        // Hulls that run when dry (Flags2 0x0080) downgrade attack orders.
        if rec.escortCommand == F.defend || rec.escortCommand == F.attack, hull.flags2 & 0x0080 != 0 {
            let readiness = host.ammoReadiness(ship)
            if readiness != 0 {
                if rec.behavior == 5 {
                    rec.escortCommand = F.returnToHangar
                } else if readiness == 2 {
                    rec.escortCommand = F.formation
                }
            }
        }

        if rec.state == S.squadJump {
            rec.primary = nil
            return
        }

        switch rec.escortCommand {
        case F.defend, F.attack:
            rec.jumpTimer = -1
            rec.maneuverTimer = -1
            let defend = rec.escortCommand == F.defend
            if defend, let pid = rec.primary, let t = host.ship(pid) {
                // Defend drops a target beyond 408375 px² (≈ 639 px) of the leader.
                let d = t.position - leaderShip.position
                if d.x * d.x + d.y * d.y > 408_375 { rec.primary = nil } else { rec.state = S.attack }
            }
            if rec.primary == nil {
                rec.primary = bestAssistTarget(ship, radius: defend ? 0x226 : -1, host: host)
                if !defend { rec.secondary = .none }
                // A player fighter or medium escort calls out its new target,
                // one time in three (chatter category 1).
                if leaderShip.isPlayer, rec.primary != nil, host.chatterIdle,
                   hull.escortClass < 2, hull.flags2 & 0x0010 == 0, host.random(3) == 0 {
                    host.queueChatter(category: 1, govt: hull.attributesGovt, voice: rec.voice)
                }
            }
            if rec.primary == nil {
                rec.state = S.escortStation
                rec.secondary = .ship(leaderID)
            } else {
                rec.state = S.attack
            }
        case F.hold:
            rec.primary = nil
            rec.secondary = .none
            rec.state = S.park
        case F.returnToHangar where rec.behavior == 5:
            rec.state = S.returnToLeader
            rec.primary = nil
            rec.secondary = .ship(leaderID)
        default:
            // Formation: hold station; keep (or pick) a ship pressing the
            // squad only as a turret target, while it is inside the class's
            // stock weapon envelope (0x00411600 with bank −1).
            rec.jumpTimer = -1
            rec.maneuverTimer = -1
            if let pid = rec.primary, let t = host.ship(pid), !host.withinStockWeaponRange(ship, of: t) {
                rec.primary = nil
            }
            if rec.primary == nil { randomTargetPressingLeader(rec, ship: ship, host: host) }
            rec.state = S.escortStation
            rec.secondary = .ship(leaderID)
            if rec.primary == leaderID { rec.primary = nil }
            if rec.primary != nil, !leaderShip.isPlayer { rec.fire.formUnion([.direct, .turret]) }
        }
    }

    // MARK: Squad-leader pass (Frame_TickSystems scope 6, 0x004186b0)

    func tickLeaderFlags(_ host: OriginalAIHost) {
        var snapshot: [Int: Int] = [:]
        for ship in host.ships where !ship.isPlayer {
            if let l = leader(of: ship) { snapshot[ship.entityID] = l }
            if let rec = records[ship.entityID] {
                rec.isSquadLeader = false
                rec.resolvedLeader = nil
            }
        }
        for ship in host.ships where !ship.isPlayer && ship.isAlive {
            guard let rec = records[ship.entityID], rec.behavior > 4, let l = leader(of: ship) else { continue }
            if l != World.playerEntityID {
                reacquireSquadLeader(rec, ship: ship, snapshot: snapshot, host: host)
                if let nl = leader(of: ship), nl != World.playerEntityID { records[nl]?.isSquadLeader = true }
            }
            var resolved: Int?
            if rec.primary != nil && rec.state == OriginalAIState.attack { resolved = rec.swarmMate }
            rec.resolvedLeader = resolved ?? leader(of: ship)
        }
    }

    /// `Ship_ReacquireSquadLeader` (0x004156a0): when the leader is gone or
    /// disabled the heaviest live sibling takes over; with none, the ship
    /// reverts to its class AI in state 0x13.
    func reacquireSquadLeader(_ rec: OriginalAIShipState, ship: Ship, snapshot: [Int: Int], host: OriginalAIHost) {
        guard let stale = leader(of: ship), stale != World.playerEntityID else { return }
        if let l = host.ship(stale), l.isAlive, !l.disabled { return }
        var replacement: Ship?
        var replacementMass = 0
        for c in host.ships where !c.isPlayer && c.isAlive && !c.disabled && snapshot[c.entityID] == stale {
            let mass = host.hull(of: c).mass
            if replacement == nil || mass > replacementMass {
                replacement = c
                replacementMass = mass
            }
        }
        let hull = host.hull(of: ship)
        guard let replacement else {
            setLeader(ship, nil)
            rec.behavior = hull.inherentAI
            rec.state = OriginalAIState.disengaged
            rec.mode = OriginalAIMode.idle
            rec.jumpTimer = 0
            return
        }
        if replacement.entityID == ship.entityID {
            rec.behavior = hull.inherentAI
            rec.jumpTimer = 0
            let old = records[stale]
            let oldGovt = host.ship(stale)?.government ?? -1
            if ship.government < govtResourceBase || ship.government != oldGovt || old == nil {
                switch rec.state {
                case OriginalAIState.returnToLeader, OriginalAIState.escortStation, OriginalAIState.playerStation:
                    rec.state = OriginalAIState.idle
                    rec.mode = OriginalAIMode.idle
                case OriginalAIState.squadJump:
                    rec.state = OriginalAIState.departJump
                    rec.mode = OriginalAIMode.jumpSpinUp
                default:
                    if rec.primary == nil || rec.state == OriginalAIState.scanApproach
                        || rec.state == OriginalAIState.refuel {
                        rec.state = OriginalAIState.idle
                    } else {
                        rec.state = OriginalAIState.attack
                    }
                    rec.mode = OriginalAIMode.idle
                }
            } else if let old {
                rec.primary = old.primary
                rec.secondary = old.secondary
                rec.state = old.state
                rec.mode = old.mode
            }
            setLeader(ship, nil)
            return
        }
        setLeader(ship, replacement.entityID)
        if rec.behavior == 5 { rec.behavior = 6 }
        if rec.jumpTimer < 0 { rec.state = OriginalAIState.disengaged }
    }

    // MARK: Formation (0x00413990 / 0x00413b60 / 0x00414390)

    /// The wedge slot table: (lateral, forward) in units of the spacing, for
    /// slots 2–21; the follower count's parity picks the variant of slots
    /// 4–8. Beyond slot 21 everyone sits on the leader.
    static func wedgeSlot(_ slot: Int, spacing v: Double, evenCount: Bool) -> (lateral: Double, forward: Double) {
        switch slot {
        case 2: return (-v, -v)
        case 3: return (v, -v)
        case 4: return evenCount ? (0, -2 * v) : (-2 * v, -2 * v)
        case 5: return evenCount ? (-2 * v, -2 * v) : (2 * v, -2 * v)
        case 6: return evenCount ? (2 * v, -2 * v) : (-v, -3 * v)
        case 7: return evenCount ? (-v, -3 * v) : (v, -3 * v)
        case 8: return evenCount ? (v, -3 * v) : (0, -2 * v)
        case 9: return (-3 * v, -3 * v)
        case 10: return (3 * v, -3 * v)
        case 11: return (0, -4 * v)
        case 12: return (-2 * v, -4 * v)
        case 13: return (2 * v, -4 * v)
        case 14: return (-4 * v, -4 * v)
        case 15: return (4 * v, -4 * v)
        case 16: return (-v, -5 * v)
        case 17: return (v, -5 * v)
        case 18: return (-3 * v, -5 * v)
        case 19: return (3 * v, -5 * v)
        case 20: return (-5 * v, -5 * v)
        case 21: return (5 * v, -5 * v)
        default: return (0, 0)
        }
    }

    /// Spacing `clamp(trunc(max sprite span × 0.7), 24, 60)`; offsets turn
    /// with the leader's truncated heading.
    func updateEscortFormations(leader: Ship, host: OriginalAIHost) {
        let followers = host.ships.filter { s in
            !s.isPlayer && s.isAlive && s.entityID != leader.entityID
                && records[s.entityID]?.resolvedLeader == leader.entityID
        }
        guard !followers.isEmpty else { return }
        var span = leader.radius * 2
        for f in followers { span = max(span, f.radius * 2) }
        let v = Double(min(max(Int(span * 0.7), 24), 60))
        let even = (followers.count + 1) % 2 == 0
        let headingDeg = Double(Int(Self.headingDeg(leader)))
        let forwardDir = Vec2.heading(headingDeg * .pi / 180)
        let lateralDir = Vec2.heading((headingDeg + 90) * .pi / 180)
        for (i, f) in followers.enumerated() {
            let slot = Self.wedgeSlot(i + 2, spacing: v, evenCount: even)
            records[f.entityID]?.formationOffset = leader.position + forwardDir * slot.forward + lateralDir * slot.lateral
        }
    }

    /// Creep onto the wedge offset per axis at thrust × 10 px/tick with an
    /// 8 px deadzone, slowed while ionized; never during a jump.
    func moveTowardFormationOffset(_ rec: OriginalAIShipState, ship: Ship, ticks: Double) {
        guard rec.jumpTimer <= 0, rec.resolvedLeader != nil, let offset = rec.formationOffset else { return }
        var step = Flight(ship).thrust * 10
        if ship.ionIntensity > 0 { step *= 1 - min(ship.ionIntensity, 0.8) }
        ship.position = Self.creep(ship.position, toward: offset, step: step * ticks, deadzone: 8)
    }

    // MARK: Cloak (Ship_UpdateShipCloakStateFromTraits 0x00411d00)

    func updateCloak(_ rec: OriginalAIShipState, ship: Ship, host: OriginalAIHost) {
        guard ship.hasCloak else { return }
        if ship.disabled || (ship.cloakFuelPerSec > 0 && ship.fuel <= 0)
            || (ship.cloakShieldPerSec > 0 && ship.shield <= 0) {
            ship.cloakEngaged = false
            return
        }
        let flags = host.hull(of: ship).flags2
        let s = rec.state, m = rec.mode
        var enter = false
        if flags & 0x0100 != 0, ship.weapons.contains(where: { $0.cooldown > $0.spec.reloadSeconds }) { enter = true }
        if flags & 0x0200 != 0, s == OriginalAIState.retreat
            || (s == OriginalAIState.asteroid && m == OriginalAIMode.scriptedManeuver) { enter = true }
        if flags & 0x0400 != 0, m == OriginalAIMode.jumpSpinUp || s == OriginalAIState.arrival
            || s == OriginalAIState.squadJump { enter = true }
        if flags & 0x0800 != 0, [OriginalAIState.travel, OriginalAIState.park, OriginalAIState.gateEntry,
                                 OriginalAIState.scanApproach, OriginalAIState.escortStation].contains(s) { enter = true }
        if flags & 0x1000 != 0, ship.isCloaked {
            if s == OriginalAIState.attack, let pid = rec.primary, let t = host.ship(pid),
               !Self.inBox(ship.position, t.position, 165) { enter = true }
            if s == OriginalAIState.asteroid, m != OriginalAIMode.scriptedMatch { enter = true }
        }
        if flags & 0x2000 != 0, s == OriginalAIState.idle { enter = true }
        if rec.behavior > 4, m == OriginalAIMode.velocityMatch, let l = leader(of: ship),
           host.ship(l)?.isCloaked == true { enter = true }
        ship.cloakEngaged = enter
    }

    // MARK: Damage (Ship_ApplyDamageToShip's AI arm)

    /// A hit on an NPC: it adds the damage to its hostility and turns on the
    /// attacker (and so does its squad leader); a hit from the player makes it
    /// hostile to the player. A defense ship away from home counts an attacker
    /// nearer than half the home distance 30×.
    /// `Government_PropagateHostilityFromAttack` (0x004102e0), responder arm:
    /// a warship or interceptor not already attacking goes to state 4 on the
    /// attacker. `World.propagateHostilityFromPlayerAttack` picks the
    /// responders (AI-06).
    func joinAttack(_ responder: Ship, attackerID: Int) {
        guard let rec = records[responder.entityID], (3...4).contains(rec.behavior),
              rec.state != OriginalAIState.attack else { return }
        rec.state = OriginalAIState.attack
        rec.primary = attackerID
        mirror(rec, responder)
    }

    /// AI-06's propagation to allied responders runs beside this arm
    /// (`World.propagateHostilityFromPlayerAttack` → `joinAttack`).
    func noteHit(_ victim: Ship, attackerID: Int, shield: Double, armor: Double, world: World) {
        guard !victim.isPlayer, victim.isAlive, let rec = records[victim.entityID] else { return }
        let host = WorldAIHost(world: world, ai: self)
        let attacker = world.ship(id: attackerID)
        if rec.jumpTimer > 0 { return }
        if let l = leader(of: victim), l != World.playerEntityID, (records[l]?.jumpTimer ?? 0) > 0 { return }
        if let attacker, let vl = leader(of: victim), leader(of: attacker) == vl { return }
        if let attacker, !attacker.isPlayer, rec.mode == OriginalAIMode.boardHold { return }

        let damage = Int16(truncatingIfNeeded: Int(armor)) &+ Int16(truncatingIfNeeded: Int(shield))
        var retargeted = false
        if rec.defenseHome == nil {
            retargeted = true
            // Already lined up on a much nearer target: keep it.
            if let pid = rec.primary, rec.state == OriginalAIState.attack, let primary = world.ship(id: pid),
               let attacker {
                let off = abs(Self.deltaDeg(from: Self.headingDeg(victim), to: Double(rec.desiredHeadingDeg)))
                let dp = primary.position - victim.position, da = attacker.position - victim.position
                if off < 45, (dp.x * dp.x + dp.y * dp.y) / 4 < da.x * da.x + da.y * da.y { retargeted = false }
            }
            if retargeted {
                rec.hostility = rec.hostility &+ max(0, damage)
                if attacker != nil { rec.primary = attackerID }
                if let l = leader(of: victim), l != World.playerEntityID, let lr = records[l], lr.defenseHome == nil {
                    lr.hostility = lr.hostility &+ max(0, damage)
                    if attacker != nil { lr.primary = attackerID }
                }
            }
        } else if let attacker, let home = rec.defenseHome,
                  let homePos = host.stellars.first(where: { $0.id == home })?.position {
            let dh = homePos - victim.position, da = attacker.position - victim.position
            if da.x * da.x + da.y * da.y < (dh.x * dh.x + dh.y * dh.y) / 2 {
                rec.hostility = rec.hostility &+ max(0, damage) &* 30
                rec.primary = attackerID
                retargeted = true
            }
        }
        guard retargeted else { return }
        if attackerID == World.playerEntityID { setHostileToPlayer(rec, ship: victim, host: host) }
        if rec.maneuverTimer > 20 { rec.maneuverTimer = 20 }
        if attackerID == World.playerEntityID, rec.defenseHome == nil {
            if rec.state == OriginalAIState.refuel || rec.state == OriginalAIState.repair {
                rec.state = OriginalAIState.idle
            }
            rec.primary = World.playerEntityID
        }
    }
}
