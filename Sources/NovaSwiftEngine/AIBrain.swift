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
    /// Last frame's leader velocity, kept so an escort can feed the leader's own
    /// *acceleration* forward into its station-keeping — moving with the leader the
    /// instant it thrusts/turns rather than lagging and snatching a correction a
    /// frame later. Nil until the first escorting frame / after the leader is lost.
    private var prevLeaderVel: Vec2?
    /// Rate-limited copy of the leader's heading, used only to orient the
    /// formation wedge (see `escort()`). AI ships fly inertialess, so a
    /// fighting leader's `angle` *is* its instantaneous aim direction — it can
    /// snap through a full circle within a second while dogfighting. Locking
    /// the wedge straight to that raw angle swings the trailing station point
    /// around the leader just as fast, and an escort chasing a swinging point
    /// traces the same loop ("launch a fighter, it circles forever" bug). This
    /// tracks `leader.angle` at a bounded turn rate instead, so the wedge holds
    /// a stable orientation through a dogfight and only reorients at a normal
    /// flight pace when the leader is actually changing course. Nil until the
    /// first escorting frame / after the leader is lost.
    private var formationHeading: Double?
    /// Standing order for a player escort (`leaderID == 0`). Ignored by ordinary
    /// NPC-fleet escorts, which always behave as `.defensive`.
    public var escortOrder: EscortOrder = .defensive
    /// Set once this assist run has docked with the player and delivered
    /// fuel/repairs — reset every time `beginAssisting()` starts a new run.
    public var assistDelivered = false

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
    /// - `.attackStellars` — no ship-vs-stellar combat exists in this engine yet,
    ///   so this currently falls through to the ship's normal AI (documented
    ///   stub, not silently equivalent to `.standard`).
    public var behaviorOverride: MissionShipBehavior = .standard

    // Tunables (world units).
    public var scanRange: Double = 1500
    /// A steady wander/travel destination for non-combat states. Readable
    /// (but engine-only writable) so the in-game AI debug overlay can draw the
    /// line each ship is steering along — its current "path".
    public internal(set) var destination: Vec2?
    /// The stellar object id a trader is travelling to / landing on. Exposed
    /// read-only for the same AI debug overlay.
    public internal(set) var destSpob: Int?
    /// Set at spawn for a trader that lifted off a planet and is *leaving* the
    /// system (cargo delivered, heading out) rather than hopping to another port.
    /// Consumed the first time the brain resolves its post-spawn goal, so the ship
    /// heads for the edge and jumps out — the visible outbound half of planet
    /// traffic. Only meaningful for trader dispositions.
    var spawnOutbound = false
    /// The pad this ship launched from, for a ship spawned via the `.planet`
    /// origin — consumed the first time `pickPlanetBody` resolves a travel
    /// destination, so it never re-selects the body it just left as its very
    /// first stop (which read as an instant re-land at spawn) while ordinary
    /// later returns to that port are unaffected.
    var spawnOriginSpobID: Int?
    /// Seconds this trader will loiter parked beside the pad in `.docked` before
    /// it lifts off and departs. Rolled once on touchdown so dwell times vary
    /// ship-to-ship; -1 means "not yet rolled".
    var dockDwell: Double = -1
    /// A fixed point just outside the planet surface the docked trader holds
    /// station on — set once on touchdown from where the ship pulled up. Holding
    /// a fixed spot (not the planet centre, which the ship can never reach) is
    /// what lets it actually brake to a standstill instead of orbiting.
    var dockPoint: Vec2?
    /// The hypergate this ship decided to use for its current departure, once
    /// `depart()` has rolled that decision (see `pickDepartureGate`) — nil means
    /// either "not decided yet" (checked via `departureGateChecked`) or "decided
    /// to use the open edge instead." Read by `World`'s despawn sweep so a
    /// gate departure fires `.shipDepartedViaGate` (the gate visibly opens) at
    /// the gate instead of `.shipDeparted` at the system edge.
    var departViaGateID: Int?
    private var departureGateChecked = false
    /// The body index the last patrol standoff waypoint was taken off, so the
    /// beat never picks the same planet twice in a row (that consecutive repeat
    /// is what read as "circling one spot"). `nil` = no body leg yet / last leg
    /// was a deep-space sweep.
    var lastPatrolBodyIndex: Int?
    var stateClock: Double = 0
    var repathClock: Double = 0
    /// "name [id]" tag for logging, refreshed at the top of every `think()` so
    /// state-transition/fallback logs can identify which ship they're about.
    private var shipTag = "NPC"
    /// Log-on-change: whether we currently have a valid firing solution on
    /// our target (in range + aimed) — flips are exactly the "why didn't my
    /// weapon fire" moments for AI-controlled ships.
    private var hadFiringSolution: Bool?
    /// Whether this ship is flying the engine's driftless (inertialess) model
    /// this frame (`Ship.fliesInertialess`), cached at the top of `think` so the
    /// steering primitives — which only take `me`, not the world/tuning — can
    /// exploit the no-drift model (a driftless hull brakes by cutting throttle,
    /// with no need to rotate to retrograde first). Refreshed every frame.
    private var inertialessNow = false
    /// This frame's tick length, cached at the top of `think` so `stoppingPoint`
    /// can add a physically-real one-tick correction instead of a flat
    /// percentage margin. Defaults to the sim's fixed step in case anything
    /// ever reads it before a `think()` call sets it for real.
    private var currentDt: Double = 1.0 / 30.0
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
    /// Authority "tour of duty": seconds a warship/interceptor will keep policing
    /// this system before it jumps out and is replaced by fresh traffic. Bible: a
    /// warship "seeks out and attacks his enemies, or jumps out if there aren't
    /// any." Without this, local-authority patrols/orbits loiter forever — which
    /// pins the population and stops any new ships from arriving (the "9 identical
    /// ships circling forever, nothing comes or goes" bug). Randomized per ship on
    /// first idle so departures stagger; -1 means "not yet rolled".
    var dutyRemaining: Double = -1

    /// `pêrs.Aggress` (1 close … 3 far): how close this ship presses its attack
    /// standoff distance. Set by `Spawner` when this brain is promoted to a
    /// named `pêrs`; nil for ordinary NPCs (falls back to `aiType`'s default).
    public var personAggression: Int?
    /// `pêrs.Coward`: percent of shields at which this ship flees a fight,
    /// overriding the fixed 25% warship-retreat threshold. Set by `Spawner`
    /// alongside `personAggression`.
    public var personCoward: Int?

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
        // A cloaked ship this brain can't detect is off the table entirely — it
        // can't be acquired as a target, and a target that cloaks is dropped.
        guard world.canDetect(other, by: me) else { return false }
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
            // wherever they meet (pêrs.Flags 0x0001).
            if let pid = me.personID, world.playerPersGrudges.contains(pid) { return true }
            if isIFFScrambled(me, world) { return false }
            return world.diplomacy?.isHostileToPlayer(me.government) ?? false
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

    /// `oütf` ModType 48 (IFF scrambler), player-only per the Bible: while the
    /// player carries one whose class matches this ship's government (or
    /// `-1` for "every government"), that government is "fooled into
    /// thinking the player is a friendly ship and will not attack without
    /// provocation" — this only suppresses the *default* diplomacy check;
    /// genuine provocation (a real hit, or a person's grudge) already
    /// returned `true` above before this ever runs.
    private func isIFFScrambled(_ me: Ship, _ world: World) -> Bool {
        let scrambled = world.player.iffScramblerClasses
        guard !scrambled.isEmpty else { return false }
        if scrambled.contains(-1) { return true }
        guard let classes = world.diplomacy?.govt(me.government)?.classes else { return false }
        return !scrambled.isDisjoint(with: classes)
    }

    /// Nearest hostile within scan range, if any.
    func nearestHostile(_ me: Ship, _ world: World) -> Ship? {
        var best: Ship?
        // Sensor reach shrinks with system interference (sÿst.Interference),
        // net of this ship's anti-interference outfits.
        var bestDist = world.effectiveSensorRange(scanRange, for: me)
        for other in world.allShips where isHostile(me, other, world) {
            let d = (other.position - me.position).length
            if d < bestDist { bestDist = d; best = other }
        }
        return best
    }

    /// This ship's real firing mounts — every weapon except fighter bays
    /// (`wëap` Guidance 99), which sit in `Ship.weapons` so the player can
    /// select/fire one as a secondary but don't shoot a "shot" of their own;
    /// their `speed`/`duration` fields (borrowed for the launched fighter, not
    /// a projectile) would otherwise pollute range/lead-time perception below
    /// with a bogus huge "range" and skew NPC carrier engagement distance.
    private func firingWeapons(_ me: Ship) -> [WeaponMount] {
        me.weapons.filter { $0.spec.guidance != .bay }
    }

    /// This ship's longest weapon reach (0 if unarmed).
    func weaponRange(_ me: Ship) -> Double {
        firingWeapons(me).map { $0.spec.range }.max() ?? 0
    }

    /// This ship's shortest weapon reach — used to decide how close to actually
    /// close, so a ship carrying a long-range missile *and* a short-range beam
    /// doesn't sit at missile range and leave its beam permanently out of
    /// reach. Falls back to `weaponRange` when every mount shares one range.
    func minWeaponRange(_ me: Ship) -> Double {
        let ranges = firingWeapons(me).map { $0.spec.range }.filter { $0 > 0 }
        return ranges.min() ?? weaponRange(me)
    }

    /// True once every ammo-*using* weapon mount is dry (`ammo == 0`). Ships
    /// that carry only unlimited-ammo weapons (`ammo == -1`, e.g. most guns
    /// and beams) never trigger this — there's nothing to run dry on. Fighter
    /// bays are excluded: an empty bay isn't "out of ammo" in the fleeing
    /// sense this drives, it's just between launch cycles.
    func outOfAmmo(_ me: Ship) -> Bool {
        let ammoMounts = firingWeapons(me).filter { $0.ammo >= 0 }
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
            // Never treat the PLAYER as an "aggressor" here via `currentTargetID`:
            // it's set the instant they *select* a ship in the UI, with no combat
            // implied, whereas an NPC only sets it while actively attacking. Reading
            // a bare player selection as an attack made police interceptors jump an
            // idle, clean player merely for targeting a neutral (the "Federation
            // ships attack me for no reason" bug). Genuine player aggression is
            // still caught below via each victim's `provokedByPlayer` — set only by
            // an actual hit (`World.applyHit`), which can't be triggered by
            // targeting alone.
            if aggressor.isPlayer { continue }
            guard let victimID = aggressor.currentTargetID, victimID != me.entityID,
                  let victim = world.ship(id: victimID), victim.isAlive, !victim.disabled,
                  victim.government != aggressor.government,
                  !isHostile(me, victim, world) else { continue }
            let d = (aggressor.position - me.position).length
            if d < bestDist { bestDist = d; best = aggressor }
        }
        // The player is a genuine aggressor once they've actually landed a hit on
        // some non-enemy ship nearby (`provokedByPlayer`) — the local authority
        // steps in against the player directly, same as it would against an NPC
        // pirate caught mid-attack.
        if world.player.isAlive {
            for victim in world.allShips
            where victim.entityID != me.entityID && victim.isAlive && !victim.disabled
                && victim.brain?.provokedByPlayer == true && !isHostile(me, victim, world) {
                let d = (world.player.position - me.position).length
                if d < bestDist { bestDist = d; best = world.player }
            }
        }
        return best
    }

    /// Whether `target` (the leader's `currentTargetID`) represents a real
    /// fight worth an escort/fighter joining, rather than a bare UI selection.
    /// An NPC leader only ever sets `currentTargetID` via its own attack
    /// decision (see the `aiType` switch in `think`), so it's always trusted.
    /// A PLAYER leader's selection carries no combat intent on its own — Tab or
    /// a click locks any ship, hostile or not, exactly the same concern
    /// `pickPirateInterventionTarget` already guards against — so for a player
    /// leader this additionally requires the target to have actually traded
    /// fire with the fleet (`provokedByPlayer`, set symmetrically in
    /// `World.applyHit`) or to be currently targeting the leader itself.
    private func isGenuineEngagementTarget(_ target: Ship, leader: Ship) -> Bool {
        guard leader.isPlayer else { return true }
        return target.brain?.provokedByPlayer == true || target.currentTargetID == leader.entityID
    }

    /// The ship a *defensive* escort should engage this frame, or nil to hold
    /// formation. Defensive escorts fight only reactively — they never start a
    /// fight with a neutral or a government-enemy that hasn't touched the fleet
    /// (the "my escorts attack for no reason" complaint). In priority order:
    ///   • a ship the leader is genuinely fighting (`isGenuineEngagementTarget`),
    ///   • any hostile actively attacking the leader, or
    ///   • the hostile currently attacking us, when we're personally under fire.
    private func defensiveEngagementTarget(_ me: Ship, leader: Ship, threat: Ship?, world: World) -> Ship? {
        // The leader's own fight comes first.
        if let lt = leader.currentTargetID, let lts = world.ship(id: lt),
           lts.isAlive, !lts.disabled, isHostile(me, lts, world),
           isGenuineEngagementTarget(lts, leader: leader) {
            return lts
        }
        // Anyone actively shooting at the leader — an NPC only sets
        // `currentTargetID` while attacking, so this is a real assault, not a
        // bare selection.
        for other in world.allShips
        where other.entityID != me.entityID && other.isAlive && !other.disabled
              && other.currentTargetID == leader.entityID && isHostile(me, other, world) {
            return other
        }
        // Anyone shooting at us.
        if personallyUnderFire(me, world), let th = threat, isHostile(me, th, world) {
            return th
        }
        return nil
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
        // Anyone with a leader idles back onto its leader's wing — it has a job.
        // Without this, a ship that had just finished a kill fell through to its
        // disposition's idle goal and flew off across the system (or started a
        // patrol beat) instead of reforming; escorts and carrier fighters visibly
        // peeled away after every kill.
        if let lid = leaderID, world.ship(id: lid)?.isAlive == true { return .escorting }
        if aiType.isTrader { return .traveling }
        guard isSystemAuthority(me, world) else { return .traveling }
        return aiType == .interceptor ? .orbiting : .patrolling
    }

    /// True if some hostile is *personally* engaging this ship right now — it
    /// hit me directly (`provokedByPlayer`, set only by a real hit in
    /// `World.applyHit`, never by mere targeting) or an NPC hostile currently
    /// has me as its own target. `MaxOdds`/`favorableOdds` is the Bible's
    /// "won't *pick* a fight it can't win" check (Appendix II: "before picking
    /// a fight..."); it was never meant to also stop a ship already under fire
    /// from defending itself, which just reads as "shot at and does nothing."
    /// A ship this outmatched can still break off via `warshipRetreat` once
    /// its shields drop below its coward threshold — this only guarantees it
    /// fights back in the meantime instead of sitting passive.
    func personallyUnderFire(_ me: Ship, _ world: World) -> Bool {
        if provokedByPlayer { return true }
        return world.allShips.contains { other in
            other.entityID != me.entityID && other.isAlive && !other.disabled
                && other.currentTargetID == me.entityID && isHostile(me, other, world)
        }
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
        inertialessNow = me.fliesInertialess(world.tuning)
        currentDt = dt

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
        // Retreat is a *shield* percentage (Bible: warships run "below 25%
        // shields"; `pêrs.Coward` overrides the percent) — but only for hulls
        // that actually have shields. A shieldless hull (most fighters) has
        // `shieldFraction == 0` by definition, which read a brand-new, full-hull
        // ship as "below 25% shields" and sent it fleeing the instant it
        // launched, forever. Guard on `maxShield > 0` so a shieldless ship is
        // judged fit to fight, not perpetually routed.
        let cowardThreshold = personCoward.map { Double($0) / 100.0 } ?? 0.25
        let warshipRetreat = (govt?.warshipsRetreat ?? false)
            && me.maxShield > 0 && me.shieldFraction < cowardThreshold
        // Bible: "AI ships of this type will run away/dock if out of ammo for
        // all ammo-using weapons" (`shïp.Flags2` 0x0080) — checked regardless
        // of disposition; dock (head to a planet) if nothing's chasing us,
        // otherwise run for the edge.
        let ammoExhausted = me.fleeWhenOutOfAmmo && outOfAmmo(me)

        // Only *free*, leaderless ships act on their raw `aiType` disposition
        // here. A ship flying under a leader — an NPC-fleet escort, a
        // carrier-launched fighter, or the player's own wing — is governed
        // entirely by its escort order below. Running this generic brain for
        // them is what made a "defensive" escort autonomously pick fights with
        // any government-enemy in sight and, worse, break off and run for the
        // hyperspace edge on its own. Escorts don't do either in EV Nova.
        if leaderID == nil {
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
                } else if warshipRetreat, state != .departing {
                    // Break off when badly hurt — but only into a fresh flee, not
                    // back out of an in-progress departure. `flee()` promotes a
                    // pursuer-free run to `.departing`; without this guard a still-
                    // hurt ship would be yanked `departing -> fleeing` every frame
                    // while `flee()` shoved it `fleeing -> departing` right back,
                    // an infinite per-frame oscillation that flooded the log.
                    enter(.fleeing)
                } else if let th = threat, armed,
                         state == .attacking || personallyUnderFire(me, world) || favorableOdds(me, world) {
                    targetID = th.entityID; enter(.attacking)
                } else if armed, isSystemAuthority(me, world),
                          favorableOdds(me, world), let culprit = pickPirateInterventionTarget(me, world) {
                    // No direct threat of our own — but someone's picking on a
                    // non-enemy while we're watching. Only the local authority
                    // steps in (it's *their* space to police), and only when the
                    // odds favor it — so interventions stay occasional, not a
                    // system-wide brawl every time two ships tangle. The Bible
                    // scopes unprovoked "piracy police" watching to interceptors,
                    // but any government warship defends its own territory once
                    // it notices a hostile actively attacking someone there —
                    // pirates are everyone's enemy, and a system's patrols
                    // shouldn't stand by while they maul a visitor.
                    targetID = culprit.entityID; enter(.attacking)
                }
            case .unknown:
                if let th = threat, armed { targetID = th.entityID; enter(.attacking) }
            }
        }

        // Mission "always attack the player" ships lock the player and engage
        // regardless of the base disposition above (a trader-hull assassin still
        // hunts, rather than fleeing per its `düde` AIType) — as long as it's
        // armed and can currently see the player.
        if behaviorOverride == .attackPlayer, armed,
           world.player.isAlive, world.canDetect(world.player, by: me) {
            targetID = 0; enter(.attacking)
        }

        // If an escort and its leader is alive, prefer escorting/adopting target,
        // honoring its own standing order. Ordinary NPC-fleet escorts are never
        // assigned anything but the default `.defensive`, so this only actually
        // changes behavior for carrier-launched fighters (`.aggressive`, set by
        // `World.launchFighter`) and the player's own escort wing (set via the
        // escort command window).
        if let lid = leaderID {
            if let leader = world.ship(id: lid), leader.isAlive {
                // Follow the leader down or out. An NPC leader that is landing or
                // leaving the system takes its whole wing with it (EV Nova fleets
                // land / jump together) instead of the escorts peeling off to fly the
                // system solo the instant the leader vanishes. Checked before the
                // escort-order switch below (which would otherwise re-assert
                // `.escorting` every frame). The escort keeps its own copy of the
                // landing spob / depart intent, so it completes the manoeuvre even
                // after the leader has despawned and `leaderID` is cleared. Only NPC
                // leaders (those with a brain) trigger this — a player-led wing is
                // handled by the host when the player lands.
                if let lb = leader.brain {
                    if (lb.state == .landing || lb.state == .docked || leader.wantsToLand),
                       let sid = lb.destSpob ?? leader.landingSpob {
                        destSpob = sid
                        if state != .landing && state != .docked { enter(.landing) }
                        return state == .docked ? dock(me, world) : land(me, world)
                    }
                    if lb.state == .departing || leader.wantsToDepart {
                        if state != .departing { enter(.departing) }
                        return depart(me, world)
                    }
                }
                switch escortOrder {
                case .hold:
                    // Hold position: don't follow or fight; coast to a stop.
                    targetID = nil
                    me.currentTargetID = nil
                    return ControlIntent()
                case .evasive:
                    // Avoid combat: hold formation and never engage. An escort
                    // never breaks off to run for the hyperspace edge — in EV Nova
                    // your wing stays with you, it doesn't flee the system.
                    if state != .escorting { enter(.escorting) }
                case .aggressive:
                    // Adopt the leader's genuine target, else hunt the nearest
                    // hostile. A player leader's `currentTargetID` is only trusted
                    // as an attack order once it's a genuine fight, not a bare UI
                    // selection (see `isGenuineEngagementTarget`).
                    let leaderTarget = leader.currentTargetID.flatMap { world.ship(id: $0) }
                    let mark = (leaderTarget.map { isGenuineEngagementTarget($0, leader: leader) } ?? false)
                        ? leaderTarget : threat
                    if armed, let m = mark, isHostile(me, m, world) {
                        targetID = m.entityID; enter(.attacking)
                    } else if state != .attacking {
                        enter(.escorting)
                    }
                case .defensive:
                    // Reactive defense only: engage a ship the leader is genuinely
                    // fighting, or one that's actively attacking the leader or us —
                    // never a neutral or a mere government-enemy just passing by.
                    // That autonomous fight-picking (via the disposition brain,
                    // now gated off for escorts) is exactly what read as "my
                    // escorts attack ships for no reason." Hold formation
                    // otherwise; never flee.
                    if armed, let mark = defensiveEngagementTarget(me, leader: leader, threat: threat, world: world) {
                        targetID = mark.entityID; enter(.attacking)
                    } else if state != .attacking {
                        enter(.escorting)
                    }
                }
            } else {
                leaderID = nil   // leader gone — act on our own disposition
            }
        }

        // First goal after spawning. A trader that lifted off a planet outbound
        // heads straight for the edge and jumps out (the visible "leaving" half of
        // planet traffic); everyone else falls to their disposition's idle goal.
        if state == .spawning {
            if spawnOutbound && aiType.isTrader {
                enter(.departing)
            } else {
                enter(defaultIdleState(me, world))
            }
            spawnOutbound = false
        }

        // Drop out of combat if the target is gone. Re-resolves `targetID`
        // fresh here rather than reusing the pre-switch `threat` snapshot —
        // `threat` only tracks ordinary diplomatic hostiles, so it's nil for
        // a piracy-police intervention target the switch just picked this
        // same frame, which would otherwise immediately undo it.
        if state == .attacking, targetID == nil || world.ship(id: targetID ?? -999)?.isAlive != true {
            enter(defaultIdleState(me, world))
        }

        // Interceptors are the "piracy police": the Bible has *interceptors*
        // (not warships) "buzz incoming ships to scan them for illegal cargo."
        // Holding orbit, one will now and then peel off to fly over and scan a
        // passing ship — the player first. Restricting this to interceptors, and
        // latching the player scan to once per system visit (`World.playerScanned`,
        // checked in `pickScanTarget`), is what stops the "half the system keeps
        // scanning me" pile-up: in the original you get buzzed by about one ship
        // each time you enter. Not while escorting a leader, and never chain-scanning.
        if aiType == .interceptor, state == .orbiting, armed, scanCooldown <= 0,
           leaderID == nil, isSystemAuthority(me, world),
           let mark = pickScanTarget(me, world) {
            scanTargetID = mark.entityID
            scanReported = false
            enter(.scanning)
        }

        // Tour of duty: a local-authority warship/interceptor doesn't police one
        // system forever. With no fight to be had, after a (randomized, staggered)
        // stretch it jumps out — Bible: a warship "jumps out if there aren't any"
        // enemies. Departing drops the population below target, so the spawner
        // trickles in fresh arrivals: the coming-and-going that makes a system feel
        // alive instead of the same handful of hulls looping in place. A fight
        // re-rolls the clock so a ship that just defended the system doesn't bolt
        // the instant the shooting stops.
        if leaderID == nil, aiType == .warship || aiType == .interceptor,
           isSystemAuthority(me, world) {
            if threat != nil {
                dutyRemaining = -1
            } else if state == .patrolling || state == .orbiting {
                if dutyRemaining < 0 { dutyRemaining = world.rng.double(in: 55...135) }
                dutyRemaining -= dt
                if dutyRemaining <= 0 { enter(.departing) }
            }
        }

        me.currentTargetID = (state == .attacking) ? targetID : nil

        // Cloak-capable ships raise the cloak to slip away when fleeing, and drop
        // it otherwise (it bleeds fuel/shields). The `World` cloak step handles
        // the fade and forced-off-when-empty.
        if me.hasCloak { me.cloakEngaged = (state == .fleeing) }

        switch state {
        case .attacking:  return attack(me, world)
        case .fleeing:    return flee(me, world)
        case .traveling:  return travel(me, world)
        case .landing:    return land(me, world)
        case .docked:     return dock(me, world)
        case .patrolling: return patrol(me, world, dt)
        case .orbiting:   return orbit(me, world, dt)
        case .scanning:   return scan(me, world)
        case .departing:  return depart(me, world)
        case .escorting:  return escort(me, world, dt)
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
        // Closing distance is driven by the *shortest*-range mount, not the
        // longest: a ship should close enough to bring every weapon it carries
        // (including a short-range beam) into play, rather than parking at its
        // longest weapon's reach and leaving shorter mounts unusable.
        let closeRange = max(120, minWeaponRange(me))

        // Lead the target so shots and nose end up where it will be.
        let projSpeed = firingWeapons(me).first?.spec.projectileSpeed ?? 600
        let lead = dist / max(1, projSpeed)
        let aimPoint = target.position + target.velocity * lead
        let desired = (aimPoint - me.position).angle
        intent.desiredHeading = desired

        let aimError = abs(angleDelta(from: me.angle, to: desired))
        // Interceptors crowd the target; warships hold at a comfortable range.
        // A named pêrs's `Aggress` (1 close … 3 far) overrides that default.
        let standoffFromRange: Double
        if let aggress = personAggression {
            let factor = aggress <= 1 ? 0.4 : (aggress == 2 ? 0.7 : 1.0)
            standoffFromRange = closeRange * factor
        } else {
            standoffFromRange = aiType == .interceptor ? closeRange * 0.5 : closeRange * 0.7
        }
        // Never target a station-keeping distance inside the two hulls' combined
        // radii, plus a real gap — a standoff derived purely from weapon range
        // could come out smaller than `me.radius + target.radius` for anything
        // bigger than a small fighter, so "correctly" holding it still meant
        // sitting on top of the target: overlapping its hull and blocking a
        // fixed-forward primary (the player's) from ever tracking/hitting it.
        let hullFloor = me.radius + target.radius + 30
        let standoff = max(standoffFromRange, hullFloor)
        // Brake *before* the standoff line, not at it — the same braking-distance
        // math `moveTo` uses for arrivals (`0.5 * closingSpeed² / accel`). Cutting
        // thrust only once `dist <= standoff` ignored momentum: the nose stays
        // pinned on the target for aiming, so under the driftless AI flight model
        // its velocity keeps steering onto that heading and coasts on inward for
        // several frames while decelerating — for a ship closing fast (or a big,
        // slow-decelerating hull) that overshoot was enough to sail right through
        // the standoff radius and overlap the target. Folding in closing speed
        // (relative, so a moving target is handled too) makes the ship start
        // coasting early enough to actually settle at the bubble's edge.
        let rel = me.velocity - target.velocity
        let closingSpeed = rel.dot(toTarget.normalized)     // >0 closing in, <0 opening out
        // Room needed to bleed the closing speed before the bubble, with a margin
        // and a turn-in allowance: a Newtonian hull must first swing its nose off
        // the target and round to retrograde before it can decelerate at all, so it
        // has to commit to braking earlier than the pure `v²/2a` distance.
        let accel = max(me.stats.acceleration, 1)
        let brakeDist = closingSpeed > 0
            ? (0.5 * closingSpeed * closingSpeed / accel + closingSpeed * (1.2 / max(me.stats.turnRate, 0.4))) * 1.1
            : 0
        // Below this closing speed the range is effectively held — stop braking and
        // let the guns bear rather than fighting a few px/s of drift forever.
        let brakeReleaseSpeed = me.stats.maxSpeed * 0.08 + 8
        if dist > standoff + brakeDist {
            // Outside the bubble (with room to stop): press in, nose already on the
            // lead point so the guns bear as we close.
            if aimError < .pi / 2 {
                intent.thrust = true
                // Interceptors light the afterburner to run a fleeing quarry down
                // when it's far and we're pointed dead at it.
                if aiType == .interceptor && dist > range * 1.5
                    && aimError < 0.5 && canBurn(me) { intent.afterburner = true }
            }
        } else if closingSpeed > brakeReleaseSpeed {
            // Inside the braking line and still barreling in. Coasting here — the old
            // driftless assumption — just sails a Newtonian hull straight through the
            // bubble into the target's face, where it wheels 180° and bounces back
            // out: the combat "spin". Instead bleed the closing speed with a real
            // flip-and-burn: swing to retrograde and thrust against the approach.
            // This is the reverse-and-fire posture — the hull ends up facing roughly
            // away while its momentum still carries it, turrets/beam-turrets firing
            // through it (they aim independently) and the fixed guns re-bearing the
            // instant the closing speed is spent and it snaps back to aiming below.
            intent.desiredHeading = (rel * -1).angle
            if Vec2.heading(me.angle).dot((rel * -1).normalized) > cosThrustCone {
                intent.thrust = true
            }
        } else if dist < hullFloor {
            // Genuinely about to overlap the target's hull — open the range: nose
            // away, thrust out. Only near-overlap forces this active retreat; a ship
            // merely inside its *preferred* standoff but clear of the hull just
            // trades fire in place. Turrets keep firing through it; fixed mounts hold.
            intent.desiredHeading = (me.position - target.position).angle
            intent.thrust = true
        }
        // Else: in the standoff band, closing slowly — hold the nose on the target
        // and trade fire. Its own residual drift and the target's motion keep the
        // engagement moving instead of two ships parked nose to nose.
        // Fire when the target is within reach and in the firing arc — except
        // turrets/beam-turrets, which `World.fireAngle` already aims straight at
        // the target regardless of hull heading, so gating the *intent* to fire
        // on hull alignment defeats the entire point of carrying one (an AI ship
        // with only a turret would then never fire unless pointed at its target).
        let hasOmniWeapon = firingWeapons(me).contains { $0.spec.isTurret }
        let inFiringSolution = dist <= range && (hasOmniWeapon || aimError < 0.22)
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

    /// Head for the system edge and leave — or, if this ship rolls in favor of
    /// it (mirroring `Spawner.emergenceGate`'s government preference), head for
    /// a hypergate and transit through it instead. Rolled once per departure
    /// and cached (`departureGateChecked`), not re-rolled every tick.
    private func depart(_ me: Ship, _ world: World) -> ControlIntent {
        me.wantsToDepart = true
        if !departureGateChecked {
            departureGateChecked = true
            departViaGateID = pickDepartureGate(me, world)?.id
        }
        if let gateID = departViaGateID,
           let gate = world.systemContext.bodies.first(where: { $0.id == gateID }) {
            return seek(me, to: gate.position)
        }
        var out = me.position - world.systemContext.center
        if out.length < 1 { out = Vec2(0, 1) }
        return seek(me, to: me.position + out.normalized * world.systemContext.jumpRadius)
    }

    /// Mirrors `Spawner.emergenceGate`'s government preference, but for a
    /// *departing* ship deciding whether to use a hypergate instead of flying
    /// out to the open edge. Without this, AI ships never actually transit a
    /// gate — they only ever emerge from one as a spawn cosmetic — so a gate
    /// never visibly opens for anyone but the player.
    private func pickDepartureGate(_ me: Ship, _ world: World) -> StellarBody? {
        guard let dip = world.diplomacy, let g = dip.govt(me.government), !g.avoidsHypergates
        else { return nil }
        let gates = world.systemContext.bodies.filter { $0.isHypergate }
        guard !gates.isEmpty else { return nil }
        let chancePercent = g.prefersHypergates ? 35 : 4
        guard world.rng.int(in: 0...99) < chancePercent else { return nil }
        let owned = gates.filter { $0.government == me.government }
        let pool = owned.isEmpty ? gates : owned
        return pool[world.rng.int(in: 0...(pool.count - 1))]
    }

    /// Trader travel: pick a planet and cruise toward it, then hand off to a
    /// landing approach. With nowhere to land, just cross the system and leave.
    private func travel(_ me: Ship, _ world: World) -> ControlIntent {
        if destination == nil {
            if let body = pickPlanetBody(me, world) {
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

    /// Final approach: coast in beside the pad, then park. Rather than diving into
    /// the spaceport and vanishing, the trader pulls up next to the planet and hands
    /// off to `.docked`, where it sits idle for a while before lifting off again.
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
        // Park when we're over the pad and slow — or give up circling and set down
        // anyway after a while, so no trader gets stuck orbiting.
        if (dist < body.radius + 40 && slowEnough) || stateClock > 14 {
            enter(.docked)
            return dock(me, world)
        }
        return arrive(me, to: body.position, slowRadius: max(160, body.radius + 120))
    }

    /// Parked beside the pad: engines idle, holding station near the planet for a
    /// randomized dwell, then lift off and depart. The trader never disappears —
    /// it's a visible ship sitting at the port. If it drifts off the pad it eases
    /// back; otherwise it brakes to a dead stop and waits.
    private func dock(_ me: Ship, _ world: World) -> ControlIntent {
        guard let sid = destSpob,
              let body = world.systemContext.bodies.first(where: { $0.id == sid }) else {
            // Port gone (system swapped out from under us) — just leave.
            destination = nil; destSpob = nil; dockPoint = nil; dockDwell = -1
            enter(.departing)
            return depart(me, world)
        }
        if dockDwell < 0 { dockDwell = world.rng.double(in: 8...16) }
        // Pin the spot we park on the first frame here: a fixed point just off the
        // planet surface, in the direction the ship pulled up from. We steer to
        // *this*, not the planet centre — a ship told to arrive at the centre can
        // never reach it (the planet's in the way), so it would thrust in and
        // orbit forever at speed instead of ever coming to rest.
        if dockPoint == nil {
            let away = me.position - body.position
            let dir = away.length > 1 ? away.normalized : Vec2(0, 1)
            dockPoint = body.position + dir * (body.radius + 50)
        }
        // Lift off once we've loitered long enough.
        if stateClock > dockDwell {
            destination = nil; destSpob = nil; dockPoint = nil; dockDwell = -1
            enter(.departing)
            return depart(me, world)
        }
        // Arrive onto the fixed park point and hold it — `moveTo` brakes the ship
        // to a stop within tolerance and then issues no thrust, so the trader sits
        // still beside the pad for the dwell.
        return arrive(me, to: dockPoint ?? body.position, slowRadius: 120)
    }

    /// Warship patrol: fly a steady beat from one stellar object to the next — a
    /// believable circuit of the system. No random cross-system yanks: the
    /// "check the player out" behavior now lives in the dedicated `.scanning`
    /// state, so a patrol on its beat reads as *on duty*, not wandering in
    /// circles. Repaths only when it actually reaches a waypoint (or a long
    /// safety timeout), not every few seconds.
    private func patrol(_ me: Ship, _ world: World, _ dt: Double) -> ControlIntent {
        // Repath as soon as we get near the current waypoint — no braking radius,
        // so the ship *flies the beat* at cruise past each planet and moves on to
        // the next, tracing a continuous circuit. The old `arrive(slowRadius:)`
        // coasted the ship to a near-stop over each body, which read as "picked a
        // point and circles it forever" — exactly the behavior being fixed.
        if destination == nil || repathClock <= 0 || (destination! - me.position).length < 300 {
            destination = pickPatrolPoint(me, world)
            repathClock = 22
        }
        return seek(me, to: destination ?? me.position)
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

    /// Escort: hold a numbered slot in a tight triangle wing off the leader,
    /// rotated to the leader's heading. The leader flies the point; escorts fill
    /// the triangle's rows front-to-back — row 1 is a single ship dead astern,
    /// row 2 flanks it, row 3 widens further, and so on — so the formation reads
    /// as a solid wedge whose interior fills in as more escorts join, rather than
    /// just its two raked edges. It holds this while the leader cruises (matching
    /// its heading and keeping pace) instead of braking every time it catches up,
    /// and always squares its nose to the leader's heading once parked on station
    /// so a stopped/slow leader doesn't leave escorts facing a stale direction.
    /// They only leave this to attack when the leader actually engages (handled
    /// in `think`), then fall straight back into the wing.
    private func escort(_ me: Ship, _ world: World, _ dt: Double) -> ControlIntent {
        guard let lid = leaderID, let leader = world.ship(id: lid),
              leader.isAlive, !leader.disabled else {
            let tag = shipTag, leaderDesc = leaderID.map(String.init) ?? "nil"
            Log.ai.debug("\(tag) escort leader [\(leaderDesc)] gone — reverting to own disposition")
            leaderID = nil
            prevLeaderVel = nil
            formationHeading = nil
            enter(defaultIdleState(me, world))
            return ControlIntent()
        }
        // Orient the wedge along the leader's actual *course* (velocity direction)
        // while it's moving, not its raw nose angle. A leader's heading can snap
        // around as it dogfights (aiming) without going anywhere; chasing that
        // swings every slot point and the whole wing loops after them. Its course
        // only turns as fast as it physically maneuvers, so tracking that lets the
        // wedge follow a hard turn promptly — a tight wing through the turn — while
        // ignoring stationary nose-swing. Fall back to the nose angle when nearly
        // stopped (course is meaningless there). Then chase the target at a bounded
        // rate; `angleDelta` gives the shortest signed turn so it always closes the
        // short way around.
        let wedgeTarget = Self.wingHeading(for: leader)
        let maxWedgeTurnPerSec = 3.0   // ~172°/sec — follows real course changes tightly
        if let h = formationHeading {
            let delta = angleDelta(from: h, to: wedgeTarget)
            let step = max(-maxWedgeTurnPerSec * dt, min(maxWedgeTurnPerSec * dt, delta))
            formationHeading = h + step
        } else {
            formationHeading = wedgeTarget
        }
        let wedgeHeading = formationHeading ?? wedgeTarget
        // Slot → world-space station point (shared with spawn-time placement —
        // see `formationStation` below, which a freshly spawned escort uses to
        // appear already on station instead of having to fly here).
        let station = Self.formationStation(leaderPosition: leader.position, leaderRadius: leader.radius,
                                            heading: wedgeHeading, slot: formationSlot, escortRadius: me.radius)
        let posErr = station - me.position

        // Velocity-matching formation controller. The desired velocity is the
        // leader's own velocity (feed-forward: keep pace with a cruising leader)
        // plus a proportional pull toward the slot (close any positional gap).
        //
        // This replaces an earlier pure-pursuit-toward-the-slot-point approach,
        // which had a fatal flaw against a *turning* leader: the slot point
        // orbits the leader as it wheels, and a pursuer aimed straight at the
        // current slot (no lead term) settles into a fixed-radius lag orbit,
        // trailing forever without ever converging — the reported "launch a
        // fighter and it flies off and circles a random point forever" bug.
        // Folding the leader's velocity in as feed-forward makes the controller
        // converge: with the gap closed, `desiredVel` reduces to the leader's
        // velocity and the escort simply flies alongside on station.
        //
        // EV Nova escorts "ignore their own speed and maneuverability to hold
        // formation" (they stay on your tail no matter how fast you fly), so the
        // correction term is allowed to demand well above the hull's own top
        // speed; `formationBoost` is scaled to whatever `desiredVel` needs so
        // the limit lift actually delivers it.
        //
        // Acceleration feed-forward: anticipate the leader's velocity *change*,
        // not just its current velocity. Without it the controller is purely
        // reactive — the leader thrusts, the escort lags a frame, then snatches a
        // correction: the residual station-keeping wobble the driftless-AI
        // shortcut used to paper over. Derive the leader's acceleration from its
        // per-frame velocity delta and bias the target velocity forward over a
        // short reaction horizon, so the wing moves *with* the leader the instant
        // it thrusts or turns. `prevLeaderVel` is nil on the first escorting frame
        // and after the leader is lost, so the term is simply skipped then.
        var leaderAccelFF = Vec2()
        if let prev = prevLeaderVel, dt > 0 {
            leaderAccelFF = (leader.velocity - prev) * (formationAccelLookahead / dt)
        }
        prevLeaderVel = leader.velocity
        let desiredVel = leader.velocity + leaderAccelFF + posErr * formationPullGain
        let desiredSpeed = desiredVel.length
        var intent = ControlIntent()

        // Formation glue — EV Nova's actual escort cheat, and the only model that
        // can satisfy both halves of what a wing is supposed to do at once. Every
        // other flight model here couples the nose to the motion (a Newtonian hull
        // thrusts along its nose; a driftless hull's velocity is *steered onto* its
        // nose — see `Ship.step`), so an escort with any station-keeping error to
        // work off must point at the error to correct it. That's the whole reason
        // a wing's noses wander off the leader's heading whenever it's not already
        // perfectly parked, and no amount of tuning the aim fixes it: pointing at
        // the slot and pointing where the leader points are simply different
        // directions, and a coupled model can only ever have one of them.
        //
        // The Bible's "escorts ignore their own speed and maneuverability to hold
        // formation" is a licence to stop pretending: while holding station an
        // escort drives its *velocity* straight at what the formation controller
        // asks for and its *heading* straight at the wedge — independently, with
        // limits lifted past its own hull's and past the leader's. So the nose is
        // always right, the slot is always held however hard the leader maneuvers,
        // and a fighter reeling in from a fight does exactly the thing the wing is
        // remembered for: comes in hot, swings its nose around onto the leader's
        // heading, and *drifts* the rest of the way in — translating onto the mark
        // while already square, decelerating smoothly to nothing as the gap closes
        // (`desiredVel` shrinks with the position error, so the arrival is a clean
        // exponential settle: no braking to compute, no overshoot to correct, no
        // micro-adjust to hunt).
        //
        // Skipped under `.off`, which is explicitly the "everyone obeys identical
        // physics" mode — there escorts fly Newtonian through `moveTo` below and
        // wear the consequences.
        if world.tuning.aiInertialess != .off {
            // Cheated caps keyed to the *leader*, not this hull: whatever it can
            // do, its wing can do harder. Speed covers a leader that simply
            // outruns us (plus headroom to close a gap); the turn rate also has
            // to beat `maxWedgeTurnPerSec` since that's how fast the wedge itself
            // can swing, and the nose has to be able to catch it.
            let glueSpeedCap = max(me.stats.maxSpeed, leader.stats.maxSpeed) * formationGlueSpeedCheat
            var glueVel = desiredVel
            if glueVel.length > glueSpeedCap { glueVel = glueVel.normalized * glueSpeedCap }
            let glueTurnRate = max(me.stats.turnRate, leader.stats.turnRate, maxWedgeTurnPerSec)
                * formationGlueTurnCheat
            me.formationGlue = Ship.FormationGlue(targetVelocity: glueVel,
                                                  targetHeading: wedgeHeading,
                                                  turnRate: glueTurnRate,
                                                  response: formationGlueResponse)
            return intent
        }

        // Parked on station (stopped leader, sitting on the mark): `desiredVel`
        // is near zero, whose angle is pure noise — chasing it is what makes a
        // parked escort's nose twitch. Square up to the wedge heading and coast.
        let parkThreshold = max(6, me.stats.maxSpeed * 0.04)
        if desiredSpeed < parkThreshold {
            intent.desiredHeading = wedgeHeading
            me.formationBoost = 1.0
            return intent
        }

        if inertialessNow {
            // Inertialess hull: velocity tracks the nose, so it realises a target
            // velocity by facing it and ramping speed. Bang-bang on magnitude
            // (thrust while under the target), gated on rough alignment so it
            // never accelerates off-axis while still swinging onto heading.
            intent.desiredHeading = desiredVel.angle
            if me.velocity.length < desiredSpeed,
               Vec2.heading(me.angle).dot(desiredVel.normalized) > cosThrustCone {
                intent.thrust = true
            }
        } else {
            // Newtonian hull: pointing at `desiredVel` and only ever *adding* speed
            // can't slow a ship carrying momentum, so it overshoots its slot and
            // orbits forever (the residual formation wobble). Reuse the proven
            // flip-and-burn arrival primitive instead: `moveTo` brakes onto the
            // station point accounting for the turn time a sluggish hull needs to
            // swing retrograde, matches the slot's velocity (the leader's own
            // velocity plus the acceleration feed-forward), and eases the nose
            // onto the wedge heading as it converges — no separate arrived-snap
            // needed, `moveTo` owns the whole heading story now.
            let slotVel = leader.velocity + leaderAccelFF
            let (cmd, _) = moveTo(me, toward: station, matching: slotVel,
                                  arriveRadius: max(40, me.radius + 20),
                                  arriveSpeed: max(12, me.stats.maxSpeed * 0.08),
                                  finalHeading: wedgeHeading)
            intent = cmd
        }
        // Lift the hull's caps enough to actually reach `desiredSpeed`
        // (`World.step` applies `topSpeed *= 1 + boost`), scaled to the demand
        // with a floor so gentle station-keeping still gets some help and a
        // ceiling (3× top speed) so it closes fast without teleporting.
        let speedRatio = desiredSpeed / max(me.stats.maxSpeed, 1)
        me.formationBoost = min(2.0, max(0.4, speedRatio - 1))
        return intent
    }

    /// Proportional gain (1/sec) pulling a formation escort toward its slot:
    /// a positional gap of `g` px adds `g × gain` px/sec toward the slot on top
    /// of matching the leader's velocity. High enough to hold a tight wing
    /// through hard turns, low enough not to overshoot into oscillation.
    private var formationPullGain: Double { 2.5 }

    /// Reaction horizon (seconds) for the formation acceleration feed-forward:
    /// the leader's measured acceleration is projected this far ahead and added to
    /// the escort's target velocity, so the wing anticipates the leader's course
    /// change instead of chasing the gap it opens. Long enough to kill the lag
    /// wobble, short enough not to over-anticipate into an oscillation of its own.
    private var formationAccelLookahead: Double { 0.25 }

    /// How hard a glued escort's velocity chases what the formation controller
    /// asks for, as an exponential rate (1/sec): each tick it closes
    /// `1 - exp(-response·dt)` of the gap, so it converges smoothly and is
    /// frame-rate independent. Must stay several times quicker than
    /// `formationPullGain` — that's the rate the *position* error decays at, and
    /// a velocity loop that isn't clearly faster than the position loop it
    /// serves lags it into overshoot, which is the station-keeping hunt this
    /// whole model exists to kill. At 10 vs 2.5 the velocity settles in ~0.1s
    /// against the position's ~0.4s: a hard burn, well past any real hull's
    /// acceleration, which is exactly the cheat intended.
    private var formationGlueResponse: Double { 10.0 }

    /// Ceiling on a glued escort's speed, as a multiple of the faster of its own
    /// and its leader's top speed. Above 1 purely so it can *close* a gap faster
    /// than it cruises — a fighter reeling in from a fight comes in hot rather
    /// than trailing forever at cruise.
    private var formationGlueSpeedCheat: Double { 3.0 }

    /// Ceiling on a glued escort's turn rate, as a multiple of the fastest of its
    /// own hull, its leader's, and the wedge's own swing rate. Above 1 so the
    /// nose can *close* an alignment gap (a fighter swinging around off a fight),
    /// not merely match the wedge's rate and trail it forever.
    private var formationGlueTurnCheat: Double { 2.0 }

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
        // Arrival (slowRadius > 0): decelerate onto the point and stop there via the
        // stopping-point steering, so even a heavy hull brakes in time instead of
        // sailing past and looping back. The caller's `slowRadius` becomes the
        // "close enough to park" tolerance.
        if slowRadius > 0 {
            let tol = max(18, slowRadius * 0.22)
            return moveTo(me, toward: point, matching: Vec2(),
                          arriveRadius: tol, arriveSpeed: me.stats.maxSpeed * 0.05).intent
        }
        // Cruise (slowRadius == 0): run for the point at speed without braking —
        // used to walk a patrol circuit or head for the jump edge. Aim at the point,
        // leading out our own cross-track drift so we hold a straight line instead of
        // arcing, and burn only when the nose is lined up.
        var intent = ControlIntent()
        let toTarget = point - me.position
        let dist = toTarget.length
        guard dist > 1 else { intent.desiredHeading = me.angle; return intent }
        let dir = toTarget * (1 / dist)
        let along = me.velocity.dot(dir)
        let crossVel = me.velocity - dir * along
        let aim = toTarget - crossVel * min(0.8, dist / max(me.stats.maxSpeed, 1))
        let aimDir = aim.length > 1 ? aim.normalized : dir
        intent.desiredHeading = aimDir.angle
        if along < me.stats.maxSpeed, Vec2.heading(me.angle).dot(aimDir) > cosThrustCone {
            intent.thrust = true
        }
        return intent
    }

    /// Cosine of the half-angle a ship must have its nose within before it fires the
    /// main thruster while steering — it lines up with where it wants to go *first*,
    /// so thrust pushes it along its heading rather than off to the side (EV Nova
    /// ships rotate to face, then accelerate). ~35°.
    private var cosThrustCone: Double { 0.819 }

    /// Ease a heading from `a` toward `b` by weight `t` (0 = stay at `a`, 1 =
    /// land exactly on `b`), always turning the short way around. Shared by
    /// `moveTo`'s final-heading blend and `wingHeading`'s course/nose ease so
    /// the two don't drift out of sync on technique.
    private func blendedHeading(from a: Double, toward b: Double, weight t: Double) -> Double {
        a + t * angleDelta(from: a, to: b)
    }

    /// How far out (as a multiple of `arriveRadius`/`arriveSpeed`) `moveTo`
    /// starts easing onto a caller-supplied `finalHeading` — wide enough that
    /// the nose is already close to aligned by the time position/velocity
    /// actually converge, so there's no visible last-tick snap. Tunable by
    /// feel if formation approaches still read as snapping late or wandering
    /// early.
    private var headingBlendApproachFactor: Double { 3.0 }

    /// Rotate-to-face + flip-and-burn steering — EV Nova's actual flight feel, and
    /// the fix for heavy hulls that used to drift past a mark and orbit it. The core
    /// is the **stopping point**: where this ship would coast to rest relative to a
    /// (possibly moving) target if it began braking *now* — counting both the runway
    /// eaten while it rotates around to face retrograde and the distance it then
    /// needs to decelerate. Steering toward the target measured *from* that stopping
    /// point makes one rule cover the whole trip: while the projected stop falls
    /// short, the aim points ahead (burn toward the target); the instant it would
    /// overshoot, the aim flips to point back (turn around and brake). Baking the
    /// turn-around time into the distance is what makes a sluggish hull start braking
    /// early enough to settle onto the mark. Returns the intent and whether the ship
    /// has arrived (within `arriveRadius` and slower than `arriveSpeed` relative to
    /// the target) so a caller can e.g. square up its heading once parked.
    ///
    /// `finalHeading`, when supplied, is the heading this ship should be facing
    /// once it arrives (e.g. a formation's wedge heading). Rather than leaving
    /// the caller to snap the nose over once `arrived` flips true — which reads
    /// as a last-frame jerk even though position/velocity converged smoothly —
    /// `moveTo` eases the commanded heading from the kinematic burn/brake aim
    /// onto `finalHeading` continuously as both position and relative-speed
    /// error shrink, so the ship is already close to its final facing by the
    /// time it actually settles.
    private func moveTo(_ me: Ship, toward targetPos: Vec2, matching targetVel: Vec2,
                        arriveRadius: Double, arriveSpeed: Double,
                        finalHeading: Double? = nil) -> (intent: ControlIntent, arrived: Bool) {
        var cmd = ControlIntent()
        let relPos = targetPos - me.position
        let relVel = me.velocity - targetVel
        let dist = relPos.length
        let relSpeed = relVel.length

        // Command the caller's final heading (through the usual deadzone) once
        // arrived; a no-op when the caller didn't supply one.
        func squareUp() {
            guard let finalHeading else { return }
            if abs(angleDelta(from: me.angle, to: finalHeading)) > 0.03 {
                cmd.desiredHeading = finalHeading
            }
        }

        // Parked: close to the target and nearly matching its velocity. Under
        // Newtonian flight, coasting now holds station — no thrust needed.
        if dist < arriveRadius, relSpeed < arriveSpeed {
            squareUp()
            return (cmd, true)
        }
        // Driftless (inertialess) hull: don't do a flip-and-burn. Its velocity
        // tracks the nose, so rotating to retrograde to brake would just swing
        // its motion around — instead keep the nose on the target and cut the
        // throttle inside braking distance, letting it coast cleanly onto the
        // mark. Braking is measured against the *relative* velocity so a moving
        // target (a formation slot on a cruising leader) is handled too; the
        // ship only stops thrusting when it's actually closing on the target.
        if inertialessNow {
            guard dist > 0.0001 else { squareUp(); return (cmd, true) }
            let dir = relPos * (1 / dist)
            cmd.desiredHeading = dir.angle
            let closingSpeed = relVel.dot(dir)          // >0 when moving toward the target
            let brakeDist = 0.5 * closingSpeed * closingSpeed / max(me.stats.acceleration, 1)
            let needToClose = closingSpeed <= 0 || dist > brakeDist + arriveRadius
            if needToClose, dir.dot(Vec2.heading(me.angle)) > cosThrustCone { cmd.thrust = true }
            return (cmd, false)
        }
        let stop = stoppingPoint(me, relativeVelocity: relVel)
        let aim = targetPos - stop
        let facing = Vec2.heading(me.angle)
        // The aim direction is ill-defined when the aim vector is tiny (we're
        // essentially on the mark) — chasing its noisy angle is exactly what makes
        // a near-parked ship twitch its nose every frame. Below a floor, hold
        // heading and don't thrust; treat it as arrived.
        if aim.length < max(6, arriveRadius * 0.5) {
            squareUp()
            return (cmd, true)
        }
        // Near the mark with only a mild overshoot: don't wheel ~180° to retrograde
        // to scrub off a few px/s — that hard flip *is* the "spins over and over to
        // correct" wobble the player sees. Hold the current heading and coast the
        // last stretch in; it's close and slow, so it bleeds onto the mark and the
        // arrived checks above catch it next frames. Only a genuine sail-well-past
        // (fast, or far beyond the mark) still earns the flip-and-burn below.
        // `aim · relPos < 0` means the projected stop overshoots the target.
        // Only needed when there's no `finalHeading` to ease onto below — with
        // one, the blend already absorbs a mild overshoot's flip into the ease,
        // so this early-out would just delay converging onto the target facing.
        if finalHeading == nil, aim.dot(relPos) < 0, dist < arriveRadius * 2.5, relSpeed < arriveSpeed * 2.5 {
            return (cmd, false)
        }
        let aimDir = aim.normalized
        var targetHeadingAngle = aimDir.angle
        if let finalHeading {
            // Continuous ease from the kinematic burn/brake aim onto the target
            // facing as both position and relative-speed error shrink through a
            // band `headingBlendApproachFactor`x wider than the arrival
            // tolerances — smoothstep so the ease itself has no kink at the
            // band edges.
            let approach = headingBlendApproachFactor
            let distFrac = 1 - min(1, max(0, (dist - arriveRadius) / (arriveRadius * (approach - 1))))
            let speedFrac = 1 - min(1, max(0, (relSpeed - arriveSpeed) / (arriveSpeed * (approach - 1))))
            let raw = min(distFrac, speedFrac)
            let t = raw * raw * (3 - 2 * raw)
            targetHeadingAngle = blendedHeading(from: aimDir.angle, toward: finalHeading, weight: t)
        }
        // Heading deadzone: only issue a turn when the nose is off by more than a
        // hair, so micro-errors don't drive a constant stream of tiny corrections.
        if abs(angleDelta(from: me.angle, to: targetHeadingAngle)) > 0.03 {
            cmd.desiredHeading = targetHeadingAngle
        }
        if aimDir.dot(facing) > cosThrustCone { cmd.thrust = true }
        return (cmd, false)
    }

    /// Where `me` coasts to rest *relative to a target* if it starts braking now:
    /// its position, plus the forward runway eaten while it rotates around to face
    /// straight retrograde, plus the deceleration distance once pointed there.
    /// Folding in the *relative* velocity handles a moving target (formation,
    /// intercept) for free. Zero offset when already stopped relative to the target.
    private func stoppingPoint(_ me: Ship, relativeVelocity relVel: Vec2) -> Vec2 {
        let v = relVel.length
        guard v > 0.0001 else { return me.position }
        let vHat = relVel * (1 / v)
        let facing = Vec2.heading(me.angle)
        let dot = max(-1, min(1, (vHat * -1).dot(facing)))
        let turnAngle = acos(dot)                       // radians to swing round to retrograde
        let turnTime = turnAngle / max(me.stats.turnRate, 0.05)
        let brakeDist = 0.5 * v * v / max(me.stats.acceleration, 1)
        // One tick of continued closing at the current relative speed: `think`
        // only re-evaluates this once per fixed tick, so there's an unavoidable
        // one-tick lag between "the stop is now exact" and thrust actually
        // changing to reflect it — without it, the ship sails a beat past the
        // mark, flips 180° to claw back, overshoots that, and hunts. Anchored to
        // this tick's own length rather than a flat percentage of the whole
        // projected distance, so it doesn't over-correct a short hop or
        // under-correct a long one (the old flat 12% scaled with `turnTime`,
        // which has no real reason to affect how big the tick-lag margin is).
        let tickMargin = v * currentDt
        return me.position + vHat * (v * turnTime + brakeDist + tickMargin)
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
    private func pickPlanetBody(_ me: Ship, _ world: World) -> StellarBody? {
        let landable = world.systemContext.bodies.filter { $0.canLand }
        guard !landable.isEmpty else { return nil }
        // A ship fresh off a launch shouldn't immediately pick the very pad it
        // just left as its first travel destination — with `me.position` still
        // sitting right by that body, the nearest-body weighting below would
        // otherwise select it almost every time, and `travel()` would read the
        // ~0 distance as "already arrived" and land it again the same tick.
        // One-shot: consumed here regardless of outcome, so later, ordinary
        // returns to this same port are unaffected.
        let originID = spawnOriginSpobID
        spawnOriginSpobID = nil
        let pool = (originID != nil && landable.count > 1)
            ? landable.filter { $0.id != originID }
            : landable
        guard pool.count > 1 else { return pool.first ?? landable[0] }
        // Bias toward a *nearer* landable body so the trader's run from its jump-in
        // point reads as a purposeful line to the closest port rather than a random
        // cross-system drift — but keep it a weighted roll, not strict nearest, so
        // traffic still spreads across a system's planets. Weight ∝ 1/(distance),
        // softened by a floor so the far ones aren't impossible.
        let weights = pool.map { body -> Double in
            let d = (body.position - me.position).length
            return 1.0 / max(1.0, d / 1000.0)
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return pool[world.rng.int(in: 0...(pool.count - 1))] }
        var roll = world.rng.double(in: 0...total)
        for (i, w) in weights.enumerated() {
            roll -= w
            if roll <= 0 { return pool[i] }
        }
        return pool[pool.count - 1]
    }

    /// The next stop on a patrol beat. Rather than walking the bodies in strict
    /// index order — which, for planets arranged in a ring around the star, just
    /// traced that ring and read as "flying in circles" — a patrol now sweeps the
    /// *whole system volume* with varied, non-sequential legs:
    ///   • ~half the time it flies a standoff pass off a **randomly chosen** body
    ///     (never the same one twice running), checking in on a planet/station;
    ///   • ~half the time it strikes out to a **deep-space** point at a random
    ///     bearing and distance, covering the empty quadrants, outskirts and jump
    ///     lanes a planet circuit never touches.
    /// Leg length varies naturally with the random distance, so the ship isn't
    /// forever making the same short hop. Flown at cruise (`seek`), so it reads as
    /// a ship on a beat, not one orbiting a mark. Scanning traffic is a separate
    /// deliberate state.
    private func pickPatrolPoint(_ me: Ship, _ world: World) -> Vec2 {
        let ctx = world.systemContext
        let stops = ctx.bodies

        // A deep-space sweep point: random bearing, distance a good fraction of the
        // system out from centre so the patrol ranges wide instead of hugging one
        // radius. Also the fallback for empty / single-body systems, where a body
        // leg would just re-pick the same spot.
        func deepSpacePoint() -> Vec2 {
            lastPatrolBodyIndex = nil
            let angle = world.rng.double(in: 0...(2 * .pi))
            let reach = max(ctx.jumpRadius, 2000)
            let dist = world.rng.double(in: (reach * 0.35)...(reach * 0.95))
            return ctx.center + Vec2.heading(angle) * dist
        }

        // Prefer a body standoff on ~half of legs, but only when there's a body
        // *other than* the one we just visited to head to (so a lone-planet system
        // never circles that planet).
        let wantsBody = world.rng.int(in: 0...1) == 0
        let candidates = stops.indices.filter { $0 != lastPatrolBodyIndex }
        guard wantsBody, !candidates.isEmpty else { return deepSpacePoint() }

        let idx = candidates[world.rng.int(in: 0...(candidates.count - 1))]
        lastPatrolBodyIndex = idx
        let b = stops[idx]
        // Stand off the body's *outer* face (away from system centre) so the pass
        // sweeps past it rather than diving at it.
        let outward = b.position - ctx.center
        let dir = outward.length < 1 ? Vec2(0, 1) : outward.normalized
        return b.position + dir * (b.radius + 200)
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
        // only once per system visit (`World.playerScanned`, latched when the
        // scan lands). In the original you get buzzed by about one interceptor
        // each time you enter a system, not repeatedly the whole time you loiter.
        if player.isAlive, toPlayer < reach, !world.playerScanned,
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
