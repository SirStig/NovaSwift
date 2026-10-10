import Foundation

/// The original's high-level AI states, `ai_state_code` 0x00–0x16
/// (`Ship_UpdateShipAiState` 0x00405590). The names describe what each state
/// does; the numbers are what the original stores and compares, so the port
/// keeps them as plain integers.
public enum OriginalAIState {
    public static let idle = 0x00
    /// Travel to a stellar, stop, coast, then pick again or jump out.
    public static let travel = 0x01
    /// Brake, then spin up a hyperjump in place (mode 3/1/4).
    public static let departJump = 0x02
    /// Retreat from the primary target, then jump out.
    public static let retreat = 0x03
    /// Attack the primary target.
    public static let attack = 0x04
    /// A carried fighter returns to its carrier.
    public static let returnToLeader = 0x05
    /// Brake to a stop and sit.
    public static let park = 0x06
    /// An interceptor closes on a scan target.
    public static let scanApproach = 0x07
    /// Arrival slowdown after a jump-in.
    public static let arrival = 0x08
    /// Fuel transfer to the primary target (comm-window assistance).
    public static let refuel = 0x09
    /// Escort holding station on its leader.
    public static let escortStation = 0x0a
    /// Squad jump: follows the leader's spin-up.
    public static let squadJump = 0x0b
    /// Holding near the player (player-oriented assist).
    public static let playerStation = 0x0c
    /// Closing on a disabled ship to board it.
    public static let board = 0x0d
    /// Timed coast after boarding.
    public static let coast = 0x0e
    /// Repairing a disabled target (comm-window assistance).
    public static let repair = 0x0f
    /// Scripted asteroid manoeuvre (miners).
    public static let asteroid = 0x10
    /// Freeflight-anchor pick-up (miners).
    public static let debris = 0x11
    /// Mission stellar attack staging.
    public static let stellarAttack = 0x12
    /// Disengaged; returns to idle at about 1/100 per tick.
    public static let disengaged = 0x13
    /// Hypergate / wormhole entry.
    public static let gateEntry = 0x14
    /// Hypergate / wormhole emergence hold.
    public static let gateEmerge = 0x15
    /// Yielding a boarding victim / defunct cleanup.
    public static let yield = 0x16
}

/// The original's per-frame control modes, `ai_control_mode` 0x00–0x17
/// (`Ship_ApplyShipAiControls` 0x00408150). Unrelated to the state with the
/// same number.
public enum OriginalAIMode {
    public static let idle = 0x00
    public static let brake = 0x01
    public static let travel = 0x02
    public static let departCentre = 0x03
    public static let jumpSpinUp = 0x04
    public static let strafeAway = 0x05
    public static let pursuit = 0x06
    public static let strafe = 0x07
    public static let follow = 0x08
    public static let holdAtDistance = 0x09
    public static let arrivalSlowdown = 0x0a
    public static let formationHold = 0x0b
    public static let velocityMatch = 0x0c
    public static let squadJumpHold = 0x0d
    public static let combatBrake = 0x0e
    public static let boardHold = 0x0f
    public static let evasiveBreak = 0x10
    public static let boost = 0x11
    public static let swarm = 0x12
    public static let scriptedManeuver = 0x13
    public static let scriptedMatch = 0x14
    public static let freeflightAnchor = 0x15
    public static let stellarAim = 0x16
    public static let gateHandoff = 0x17
}

/// `ai_secondary_target_slot`: the original stores either a ship slot or a
/// stellar resource id in it.
public enum OriginalAIRef: Equatable, Sendable {
    case none
    case ship(Int)
    case stellar(Int)

    var shipID: Int? {
        if case let .ship(id) = self { return id }
        return nil
    }

    public var stellarID: Int? {
        if case let .stellar(id) = self { return id }
        return nil
    }
}

/// Weapon groups the controls arm this frame. The original arms one bank per
/// request through its selectors (0x0040d470 direct fire, 0x0040d220 guided,
/// 0x0040ce00 turret, 0x0040d910 general, 0x0040d7e0 unguided).
struct OriginalAIFire: OptionSet {
    let rawValue: Int
    static let direct = OriginalAIFire(rawValue: 1)
    static let guided = OriginalAIFire(rawValue: 2)
    static let turret = OriginalAIFire(rawValue: 4)
    static let general = OriginalAIFire(rawValue: 8)
    static let unguided = OriginalAIFire(rawValue: 16)
}

/// One ship's original AI fields: the subset of `ShipState` the AI reads and
/// writes. Positions and speeds stay in the engine's units on the `Ship`;
/// the speeds held here are the original's px/tick.
public final class OriginalAIShipState {
    public let entityID: Int
    /// `ai_behavior_code`: 1–4 the Bible AI types, 5 a carried fighter, 6 an
    /// escort.
    public internal(set) var behavior: Int
    public internal(set) var state = OriginalAIState.idle
    public internal(set) var mode = OriginalAIMode.idle
    /// `primary_target_ship_slot`, as an entity id.
    public internal(set) var primary: Int?
    public internal(set) var secondary: OriginalAIRef = .none
    /// `ai_hostility_accumulator`: damage taken since the ship last stood
    /// down, a signed 16-bit field that wraps.
    public internal(set) var hostility: Int16 = 0
    /// `random_ai_render_cadence`: the per-ship aggression level. `Rand(3) ^ 2`
    /// (2, 3 or 0) for ordinary ships, 2 for escorts, përs Aggress clamped to
    /// 1, 2 or 4. Drives the player-acquisition box (× 600 px) and the shield
    /// retreat threshold.
    public internal(set) var cadence: Int
    /// `ai_maneuver_timer_ms`, in ticks despite its name: while positive the
    /// ship coasts without turning or thrusting.
    var maneuverTimer: Double = 0
    /// `hyperspace_jump_timer`. −999 marks a fresh arrival.
    var jumpTimer: Double = 0
    /// `ai_mode_start_time_ms`: the 60 Hz clock when the jump spin-up began.
    var modeStart60: Double = 0
    var desiredHeadingDeg = 0
    /// `ai_desired_speed` (px/tick). Negative is the arrival override.
    var desiredSpeed: Double = 0
    /// `ai_forward_thrust_cmd` (px/tick²).
    var thrustCommand: Double = 0
    /// The fraction of a raw call carried between steps by the arrival
    /// override, which the original advances once per raw call.
    var arrivalCallPhase: Double = 0
    var evasiveHeadingDeg = 0
    /// `jump_destination_stellar_id`: the stellar the ship last stopped at, −2
    /// for none.
    var jumpDestination = -2
    /// `ai_cached_target_ship_slot`: an interceptor's last scan target.
    var cachedScanTarget: Int?
    var swarmMate: Int?
    /// `escort_command_code`: 0 Formation, 1 Defend, 2 Attack, 3 Return, 4 Hold.
    public internal(set) var escortCommand = -1
    var escortCommandPending = false
    /// `+0xc90a`: the order the player last gave this escort (0 Formation by
    /// default), kept per ship as the original does.
    public internal(set) var playerOrder = 0
    /// Scope-6 flag: some ship holds this one as its squad leader.
    var isSquadLeader = false
    var resolvedLeader: Int?
    /// This follower's wedge position, rewritten by its leader each frame.
    var formationOffset: Vec2?
    /// `ai_odds_score` (0x004133f0): hostile over allied strength.
    var odds: Double = 0
    /// Patience while a cloaked target can't be engaged.
    var patience: Double = -1
    /// `+0xBD`, from `Ship_CanShipUseAfterburner` at spawn: gates mode-0x11
    /// boosts.
    var afterburnerLatch = false
    /// `defense_fleet_home_stellar_id`.
    var defenseHome: Int?
    /// `boarded_target_latch` on a victim.
    var boarded = false
    var fire = OriginalAIFire()
    /// `active_weapon_bank_slot` (+0x72): the forward bank the AI-02
    /// selectors last armed. It persists until a selector arms another, and
    /// the pursuit / strafe aim leads with it.
    var activeBank: Int?
    /// The `AIBrain.state` last written by the mirror, to notice outside writes.
    var mirroredState: AIState?

    init(entityID: Int, behavior: Int, cadence: Int) {
        self.entityID = entityID
        self.behavior = behavior
        self.cadence = cadence
    }

    /// `Ship_EnterShipAiState0x02_ClearPrimaryTarget` (0x00410670).
    func enterDeparture(clock60: Double) {
        state = OriginalAIState.departJump
        if jumpTimer < 0 { jumpTimer = 0 }
        primary = nil
        modeStart60 = clock60
    }

    /// `Ship_ResetShipPrimaryAndSecondaryTargets` (0x00410dd0).
    func resetTargets() {
        if state != OriginalAIState.refuel && state != OriginalAIState.repair {
            state = OriginalAIState.idle
            mode = OriginalAIMode.idle
        }
        secondary = .none
        jumpTimer = 0
        thrustCommand = 0
        desiredSpeed = 0
    }

    func standDown() {
        state = OriginalAIState.idle
        mode = OriginalAIMode.idle
        primary = nil
        secondary = .none
    }
}
