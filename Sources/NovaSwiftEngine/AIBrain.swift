import Foundation
import NovaSwiftKit

/// A standing order the player issues to their escorts (the EV Nova escort
/// command window).
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

/// What an NPC is currently doing, as the rest of the engine and the app read
/// it. `OriginalAI` mirrors its own state machine onto this.
public enum AIState: String, Sendable {
    case spawning      // just arrived; pick an initial goal
    case traveling     // trader heading to a planet
    case landing       // trader on final approach, coasting to the pad
    /// Parked alongside a planet, engines idle. EV Nova traders don't vanish
    /// into a spaceport — they pull up beside the pad, sit still for a spell,
    /// then throttle back up and leave the system. This is that dwell.
    case docked
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

/// One NPC's shared AI fields — disposition, state, target, leader, formation
/// slot, escort order and mission behaviour — that the engine and the app read
/// in one place. The decisions themselves are `OriginalAI`'s (its own per-ship
/// record lives in `OriginalAIShipState`); this class keeps only the fields it
/// mirrors and the helpers it shares.
public final class AIBrain {
    public var aiType: AIType
    public var state: AIState = .spawning
    public var homeGovt: Int
    /// Current combat target (entity id).
    public var targetID: Int?
    /// Set true when this ship trades fire with the player OR any of the
    /// player's escorts/fighters — it will fight back against the whole fleet
    /// even if its government is otherwise neutral. Despite the name, this is
    /// shared fleet-wide provocation, not literally "only the player's own
    /// shots": `World.applyHit` sets it symmetrically on whichever side of a
    /// fight (fleet member or outsider) isn't already part of the fleet, and
    /// `isHostile` reads an outsider's flag from every fleet member, not just
    /// the one ship that actually pulled the trigger.
    public var provokedByPlayer = false
    /// Fleet leader to escort, if any. A `leaderID` of `World.playerEntityID`
    /// (0) marks a ship as one of the *player's* escorts — commanded via
    /// `escortOrder`.
    public var leaderID: Int?
    /// This escort's slot in the leader's formation (0-based), for tidy wings.
    public var formationSlot = 0
    /// True for ships that belong to a spawned `flët` — the flagship as well as
    /// its escorts. Lets `FlightTuning.aiInertialess == .formations` cover a
    /// whole formation (including the lead, which has no `leaderID`), not just
    /// the escorts holding station on it.
    public var isFleetMember = false
    /// The `flët` resource id this ship spawned as part of, if any. Lets the
    /// `Spawner` count distinct fleets in-system and avoid re-picking a fleet
    /// type that's already present, so a system shows variety instead of the
    /// same formation over and over.
    public var fleetID: Int?
    /// Standing order for a player escort (`leaderID == 0`). Ignored by ordinary
    /// NPC-fleet escorts, which always behave as `.defensive`.
    public var escortOrder: EscortOrder = .defensive

    /// Mission `ShipBehav` override (Nova Bible; docs/AI_GROUND_TRUTH.md §6
    /// item 12). `.standard` (the default) leaves the ship on its normal
    /// disposition; the others replace who it treats as friend/foe. Set by
    /// `World.spawnMissionShips` on a mission's special ships:
    /// - `.attackPlayer`  — the player is always hostile, whatever the govt;
    ///   the ship locks the player and engages.
    /// - `.protectPlayer` — the player is never hostile; the ship is wired as
    ///   one of the player's escorts (`leaderID = playerEntityID`) at spawn, so
    ///   the existing escort logic makes it defend the player. Nothing extra is
    ///   needed here beyond the friend/foe flip.
    /// - `.attackStellars` — the original AI's 0x004053c0 directive takes the
    ///   ship to state 0x12 against a hostile destroyable stellar, else flies
    ///   it as a warship (`OriginalAI.stellarAttackDirective`).
    public var behaviorOverride: MissionShipBehavior = .standard

    /// The hypergate this ship is leaving through, set by the original AI's
    /// travel pick — nil for the open edge. Read by `World`'s despawn sweep so a
    /// gate departure fires `.shipDepartedViaGate` (the gate visibly opens) at
    /// the gate instead of `.shipDeparted` at the system edge.
    var departViaGateID: Int?

    /// `pêrs.Aggress` (1 close … 3 far): how close this ship presses its attack
    /// standoff distance. Set by `Spawner` when this brain is promoted to a
    /// named `pêrs`; nil for ordinary NPCs (falls back to `aiType`'s default).
    public var personAggression: Int?
    /// `pêrs.Coward`: percent of shields at which this ship flees a fight,
    /// replacing the cadence retreat thresholds. Set by
    /// `Spawner` alongside `personAggression`.
    public var personCoward: Int?

    /// The original's per-ship cadence field (ship +0xc8cc). Ordinary NPCs
    /// roll `Rand(3) XOR 2` ∈ {2, 3, 0}; a ship escorting a class gets 2; a
    /// përs its Aggress clamped to 1, 2 or 4. It sizes the player-acquisition
    /// box (`cadence × 600` px per axis) and the shield-retreat threshold
    /// (1 → 30 %, 2 → 15 %, anything else never) — AI-05, AI-20, AI-21.
    public var cadence = 2

    /// The cadence a `përs` with `aggress` gets: 1 and 2 as given, 3 or more
    /// clamped to 4 (anything below 1 to 1).
    public static func cadence(forAggress aggress: Int) -> Int {
        aggress >= 3 ? 4 : max(1, aggress)
    }

    public init(aiType: AIType, govt: Int) {
        self.aiType = aiType
        self.homeGovt = govt
    }

    /// Start (or restart) a paid assist run. Called from the app layer when
    /// the player accepts a "Request Assistance" hail.
    public func beginAssisting() {
        state = .assisting
    }

    // MARK: Perception (player-facing hostility test)

    /// Is `other` an enemy of this ship right now? A disabled hulk still is to a
    /// ship carrying a lethal weapon, which finishes it off (AI-04); a
    /// disable-only ship leaves it be.
    func isHostile(_ me: Ship, _ other: Ship, _ world: World) -> Bool {
        guard other.isAlive, other.entityID != me.entityID else { return false }
        guard !other.disabled || Self.hasLethalWeapon(me) else { return false }
        // A cloaked ship this brain can't detect is off the table entirely — it
        // can't be acquired as a target, and a target that cloaks is dropped.
        guard world.canTarget(other, by: me) else { return false }
        if other.isPlayer {
            // Mission ShipBehav overrides trump ordinary diplomacy toward the
            // player: an "attack the player" ship is always hostile, a "protect
            // the player" ship never is (see AIBrain.behaviorOverride).
            switch behaviorOverride {
            case .attackPlayer:  return true
            case .protectPlayer: return false
            case .standard, .attackStellars: break
            }
            // A ship flying in the player's own fleet never reads the player as
            // an enemy, whatever provocation or government disposition it may be
            // carrying — you hired it (or launched it), it doesn't shoot you.
            if world.isPlayerFleetMember(me.entityID) { return false }
            if provokedByPlayer { return true }
            // A named person the player has wronged holds a grudge and attacks
            // wherever they meet — only one whose përs Flags carry 0x0001 (AI-07).
            if let pid = me.personID, me.personFlags & 0x0001 != 0,
               world.playerPersGrudges.contains(pid) { return true }
            return flagsPlayer(me, player: other, world)
        }
        // The player's escorts/fighters share the player's enemies and vice
        // versa: whichever side of a fight *isn't* a fleet member gets
        // `provokedByPlayer` set on it (symmetrically, in `World.applyHit`),
        // so every OTHER fleet member reads it as hostile too — not just the
        // one ship that actually traded fire with it. Membership follows the
        // whole chain of command (`World.isPlayerFleetMember`), so a fighter off
        // one of your carriers is on your side of this test rather than reading
        // as an outsider to the fleet it belongs to.
        let meIsFleet = world.isPlayerFleetMember(me.entityID)
        let otherIsFleet = world.isPlayerFleetMember(other.entityID)
        if meIsFleet != otherIsFleet {
            let outsider = meIsFleet ? other : me
            if outsider.brain?.provokedByPlayer == true { return true }
        }
        // NPC vs NPC.
        return world.diplomacy?.areEnemies(me.government, other.government) ?? false
    }

    /// The player-hostility arm of `Ship_AcquirePrimaryTargetForShip`
    /// 0x0040e020 (AI-05), for an unprovoked ship. An independent ship never
    /// takes it. A xenophobe sees the player anywhere (bar its own system with
    /// a good record). Everyone else needs the player inside its acquisition
    /// box — `cadence × 600` px on each axis, so a cadence-0 ship never picks
    /// the player up this way — and then the government's reputation ladder
    /// to fire (`Diplomacy.reputationFlagsPlayer`). Rank privilege and the
    /// IFF-scrambler latch clear all of it inside `Diplomacy`.
    func flagsPlayer(_ me: Ship, player: Ship, _ world: World) -> Bool {
        guard let dip = world.diplomacy, me.government != independentGovt,
              let gov = dip.govt(me.government) else { return false }
        if gov.alwaysAttacksPlayer { return true }
        if gov.xenophobic { return dip.xenophobeTargetsPlayer(me.government) }
        let reach = Double(cadence * 600)
        let d = player.position - me.position
        return abs(d.x) <= reach && abs(d.y) <= reach && dip.reputationFlagsPlayer(me.government)
    }

    // MARK: Helpers shared with the original AI

    /// `Weapon_HasAnyFireableNonSecondaryWeapon` 0x00415c10: a primary that
    /// does mass (armor) damage, isn't disable-only, and has ammo to fire.
    static func hasLethalWeapon(_ ship: Ship) -> Bool {
        ship.weapons.contains {
            $0.spec.guidance != .bay && !$0.spec.isSecondary && $0.spec.armorDamage > 0
                && !$0.spec.disablesOnly && $0.ammo != 0
        }
    }


    /// The wing's raw (unsmoothed) facing target for a given leader: its course
    /// (velocity direction) while moving at a meaningful clip, else its nose
    /// angle. Orienting on course rather than raw heading keeps the wedge from
    /// swinging with a leader's stationary aim-turning in combat; see `escort`'s
    /// `formationHeading` smoothing, which chases this at a bounded turn rate.
    /// Also the first-frame fallback used to place a freshly spawned escort
    /// directly on station (no prior `formationHeading` to smooth from yet).
    ///
    /// Eases between nose and course over a band around 15% of top speed
    /// rather than hard-flipping there: a leader accelerating away from or
    /// braking to a stop crosses that speed every launch/landing, and a hard
    /// ternary yanked the whole wedge's target heading in one frame right when
    /// escorts are also settling onto station — exactly the kind of snap this
    /// is meant to avoid.
    public static func wingHeading(for leader: Ship) -> Double {
        let speedFrac = leader.velocity.length / max(leader.stats.maxSpeed, 1)
        let lo = 0.08, hi = 0.22   // band centered on the old 0.15 cutoff
        let raw = min(1, max(0, (speedFrac - lo) / (hi - lo)))
        let t = raw * raw * (3 - 2 * raw)
        let delta = angleDelta(from: leader.angle, to: leader.velocity.angle)
        return leader.angle + t * delta
    }

    /// World-space station point for formation `slot` off `leaderPosition`,
    /// facing `heading` — the pure math behind `escort`'s wedge formation,
    /// factored out so spawn-time placement (`GameScene.spawnRosterEscort`) can
    /// put a freshly joined escort directly on its slot instead of warping in
    /// somewhere random and flying over.
    public static func formationStation(leaderPosition: Vec2, leaderRadius: Double,
                                        heading: Double, slot: Int, escortRadius: Double) -> Vec2 {
        // Slot → (row, column). EV Nova's escort wing is a filled wedge/triangle
        // whose tip is the *leader itself*: the leader is the lone apex (row 0), so
        // the escorts start at row 1 — the first two flank behind the leader, row 2
        // has three, row 3 four, and so on, each row one wider and one step further
        // back. Triangular numbering: escort row r (starting at 1) holds r+1 ships,
        // so slot s falls in the row whose running total first exceeds it.
        var remaining = slot
        var row = 1                      // leader is the tip (row 0); escorts begin at row 1
        while remaining > row {          // row r holds r+1 ships (row 1 = 2, row 2 = 3, …)
            remaining -= (row + 1)
            row += 1
        }
        let rowCap = row + 1
        let col = remaining              // 0..<rowCap within this row
        // Spacing is escort-to-escort — neighbours in a row sit just clear of each
        // other, rows stacked close — so it keys off the *escort's* own hull, not
        // the leader's; only the first row's distance clears the (possibly big)
        // leader. Tight, but scaling with ship size, so a wing of freighters packs
        // proportionally looser than a wing of fighters. Floors guard degenerate
        // zero-radius data.
        let lateralSpacing = max(20, escortRadius * 2 + 6)
        let depthSpacing = max(24, escortRadius * 2 + 8)
        let firstRowGap = leaderRadius + escortRadius + 10
        let lateral = (Double(col) - Double(rowCap - 1) / 2.0) * lateralSpacing  // right of the leader (+) / left (−)
        let behind = -(firstRowGap + depthSpacing * Double(row - 1))             // trailing the leader (row 1 sits one clearance back)
        // Wedge frame: forward = (sin a, cos a); right = (cos a, −sin a).
        let fwd = Vec2(sin(heading), cos(heading))
        let right = Vec2(cos(heading), -sin(heading))
        return leaderPosition + fwd * behind + right * lateral
    }
}
