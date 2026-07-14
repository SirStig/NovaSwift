import Foundation
import NovaSwiftKit

/// Abstract control input. Touch, keyboard, game controllers **and the NPC AI**
/// all translate into this; the simulation only ever reads `ControlIntent`, never
/// raw input. An NPC's `AIBrain` produces exactly the same struct a player's
/// fingers do — that symmetry is what lets one flight model drive every ship.
public struct ControlIntent: Equatable {
    public var turnLeft = false
    public var turnRight = false
    public var thrust = false
    public var reverse = false      // reverse thrust / brake-to-stop assist
    public var afterburner = false  // burn fuel for a speed / accel boost
    public var firePrimary = false
    public var fireSecondary = false
    /// Absolute heading (radians, compass) to rotate toward — used by mouse,
    /// analog-stick aiming, and the AI. When set, it drives turning unless a
    /// discrete turnLeft/turnRight is also active (discrete input wins).
    public var desiredHeading: Double?
    /// Multiplier on this frame's turn budget — the player's "Turn sensitivity"
    /// setting. 1 = the hull's native turn rate. Left at 1 for NPCs (the AI never
    /// sets it), so it only ever affects the player's ship.
    public var turnScale: Double = 1
    public init() {}

    /// OR-merge several input sources into one intent (keyboard + touch +
    /// controller + mouse). Discrete turns win; otherwise the first supplied
    /// `desiredHeading` is used.
    public static func combined(_ sources: ControlIntent...) -> ControlIntent {
        var r = ControlIntent()
        for s in sources {
            r.turnLeft = r.turnLeft || s.turnLeft
            r.turnRight = r.turnRight || s.turnRight
            r.thrust = r.thrust || s.thrust
            r.reverse = r.reverse || s.reverse
            r.afterburner = r.afterburner || s.afterburner
            r.firePrimary = r.firePrimary || s.firePrimary
            r.fireSecondary = r.fireSecondary || s.fireSecondary
            if r.desiredHeading == nil { r.desiredHeading = s.desiredHeading }
        }
        // Two input sources disagreeing on turn direction cancel out in
        // `Ship.step` (net-zero turn) — this reads to a player as "turning is
        // broken" with nothing else to go on, so flag it. Log on change only:
        // this is a per-frame computed property (`InputController.intent`) and
        // would otherwise flood the log while the conflict persists.
        if r.turnLeft && r.turnRight {
            if !loggedTurnConflict {
                loggedTurnConflict = true
                Log.physics.debug("ControlIntent.combined: turnLeft and turnRight both set across combined sources — they cancel out to a net-zero turn")
            }
        } else {
            loggedTurnConflict = false
        }
        return r
    }
    /// One-shot flag backing the conflicting-turn-input log above.
    private static var loggedTurnConflict = false
}

/// How widely the AI-inertialess flight model is applied on top of each hull's
/// own `shïp` Flags2 0x0040 / inertial-dampener flag.
///
/// EV Nova's NPC AI doesn't wrestle the same Newtonian momentum the player does —
/// its ships turn and their velocity tracks the nose far more tightly than a
/// human flying the identical hull, which is why AI traffic reads as *precise*
/// rather than drifty. Reproducing that here means letting AI-controlled ships
/// fly the engine's driftless (inertialess) model regardless of whether their
/// hull carries the real flag. The player keeps authentic Newtonian flight
/// (unless *their* hull/outfits set the flag), so the asymmetry the original had
/// is preserved.
public enum AIInertialessScope: Sendable {
    /// Off — only hulls/outfits with the real `shïp` Flags2 0x0040 flag (or an
    /// inertial-dampener outfit) fly driftless. Pure "everyone obeys identical
    /// physics" mode.
    case off
    /// Only ships flying in formation — fleet members and escorts (anything with
    /// a leader, plus the fleet flagship) — fly driftless. Kills the constant
    /// micro-correction wobble of a wing holding station without changing how
    /// lone traders/patrols fly.
    case formations
    /// Every AI-brained ship flies driftless — the classic EV Nova AI-flight
    /// feel, and the default. Turning points the ship *and* its motion together,
    /// so NPCs go where they aim without the momentum overshoot/wrong-direction
    /// drift a from-source flight AI wouldn't have.
    case all
}

/// Tuning that maps EV Nova's integer stat units into simulation units. Kept in
/// one place so flight feel can be adjusted without touching data decoding.
public struct FlightTuning {
    public var speedScale: Double      // stat → max px/sec
    public var accelScale: Double      // stat → px/sec²
    public var turnScale: Double       // stat → deg/sec
    public var dragPerSecond: Double   // gentle space drag so ships settle (0 = pure Newtonian)
    /// How broadly AI ships fly the engine's driftless (inertialess) model
    /// beyond their own hull flag — see `AIInertialessScope`. Defaults to `.all`
    /// (every NPC), matching EV Nova's precise AI flight.
    public var aiInertialess: AIInertialessScope = .all

    public static let `default` = FlightTuning(speedScale: 1.0, accelScale: 1.0,
                                               turnScale: 3.0, dragPerSecond: 0.0)
}

/// Derived, simulation-ready flight parameters for a ship.
public struct ShipStats {
    public let maxSpeed: Double        // px/sec
    public let acceleration: Double    // px/sec²
    public let turnRate: Double        // rad/sec
    public let rotationFrames: Int     // sprite frames for a full 360°

    public init(maxSpeed: Double, acceleration: Double, turnRate: Double, rotationFrames: Int = 36) {
        self.maxSpeed = maxSpeed
        self.acceleration = acceleration
        self.turnRate = turnRate
        self.rotationFrames = rotationFrames
    }

    /// Build from decoded ship stat integers (speed / accel / turnRate).
    public init(speed: Int, acceleration: Int, turnRate: Int,
                rotationFrames: Int = 36, tuning: FlightTuning = .default) {
        self.maxSpeed = Double(speed) * tuning.speedScale
        self.acceleration = Double(acceleration) * tuning.accelScale
        self.turnRate = Double(turnRate) * tuning.turnScale * .pi / 180.0
        self.rotationFrames = rotationFrames
    }
}

/// Identifies a ship in the world as belonging to another player in a co-op
/// session. `peerID` is the net transport's peer/player id (the same convention
/// as `NovaSwiftNet`'s `PeerID == playerID`); `name` is the pilot's display name
/// for nameplates and minimap blips. See `Ship.remotePlayer`.
public struct RemotePlayerInfo: Equatable {
    public var peerID: String
    public var name: String
    public init(peerID: String, name: String) {
        self.peerID = peerID
        self.name = name
    }
}

/// A moving ship in world space. `angle` is a compass heading in radians
/// (0 = up/north, increasing clockwise), matching EV Nova sprite frame 0.
///
/// Every ship — player or NPC — is a `Ship`. Combat state (shields/armor), a
/// faction (`government`), a weapon loadout, and an optional `brain` turn the
/// same body into an AI-controlled combatant. A `nil` brain means "driven from
/// the outside" — either the local player (`entityID == 0`) or, in co-op,
/// another player (`remotePlayer != nil`, fed from `World.remoteIntents`).
public final class Ship {
    public var position: Vec2
    public var velocity: Vec2
    public var angle: Double
    public let stats: ShipStats
    public let name: String

    /// Unique per-instance id assigned by the world (player == 0). Distinct from
    /// `shipTypeID`, which is the `shïp` resource id used for the sprite.
    public var entityID: Int = 0
    public var shipTypeID: Int = -1
    /// For a player escort, the id of its persistent `EscortRecord` in the pilot
    /// save (nil for ambient NPCs and the player). This is the stable link that
    /// survives system jumps — a fresh scene ship respawned from the roster
    /// carries the same `escortRecordID`, so per-escort commands (release, sell,
    /// upgrade) and "escort departed / destroyed" bookkeeping map back to the
    /// right record even though `entityID` is reassigned each spawn.
    public var escortRecordID: Int?
    /// This hull's death-explosion `snd` id (from `shïp`'s breakup/final
    /// explosion → `bööm`), or nil if it has none.
    public var explosionSoundID: Int?
    /// This hull's death-explosion `bööm` id (`shïp` final, falling back to
    /// breakup), or nil if it has none. Drives the real explosion sprite the
    /// renderer plays when the ship dies, not just the sound.
    public var explosionBoomID: Int?
    /// Faction/government. Drives who this ship will fight (see `Diplomacy`).
    public var government: Int = independentGovt
    /// Collision radius (px). Set from the sprite size where known.
    public var radius: Double = 16
    /// This hull's real weapon exit points (from its `shän`), or nil when the
    /// data has none — firing then falls back to a point just ahead of centre.
    public var exitPoints: ShipExitPoints?

    // Combat state.
    public var maxShield: Double = 100
    public var shield: Double = 100
    public var maxArmor: Double = 100
    public var armor: Double = 100
    public var shieldRechargePerSec: Double = 8
    public var armorRechargePerSec: Double = 0
    public var weapons: [WeaponMount] = []

    /// The `wëap` id of the secondary weapon the player has selected to fire on
    /// the secondary trigger (EV Nova fires only the *chosen* secondary, not all
    /// of them at once). nil = not yet chosen; `effectiveSecondaryID` then falls
    /// back to the first secondary fitted. Ignored for AI ships, which fire every
    /// group their brain triggers.
    public var selectedSecondaryID: Int?

    /// Distinct secondary weapons fitted, in mount order — the cycle the player's
    /// weapon-switch control steps through. Point-defense mounts fire themselves,
    /// so they aren't selectable.
    public var secondaryWeaponIDs: [Int] {
        weapons.filter { $0.spec.isSecondary && !$0.spec.isPointDefense }.map { $0.spec.id }
    }

    /// The secondary id actually used when the secondary trigger is held: the
    /// player's selection, or the first secondary fitted if none chosen yet.
    public var effectiveSecondaryID: Int? {
        selectedSecondaryID ?? secondaryWeaponIDs.first
    }

    /// The mount for the effective secondary (drives the HUD weapon readout).
    public var effectiveSecondaryMount: WeaponMount? {
        guard let id = effectiveSecondaryID else { return nil }
        return weapons.first { $0.spec.id == id && $0.spec.isSecondary }
    }

    /// Step the selected secondary to the next/previous fitted secondary,
    /// wrapping. No-op when the ship carries fewer than two secondaries.
    public func cycleSecondary(forward: Bool) {
        let ids = secondaryWeaponIDs
        guard !ids.isEmpty else { selectedSecondaryID = nil; return }
        let current = effectiveSecondaryID ?? ids[0]
        let idx = ids.firstIndex(of: current) ?? 0
        let n = ids.count
        selectedSecondaryID = ids[forward ? (idx + 1) % n : (idx - 1 + n) % n]
    }

    /// World-space muzzle for exit point `index` of `exitType`, given the ship's
    /// live position/heading — the real hardpoint the shot leaves from.
    public func muzzle(exitType: WeaponExitType, index: Int) -> Vec2 {
        let nose = radius + 4
        guard let ep = exitPoints, exitType != .center else {
            return position + Vec2.heading(angle) * nose
        }
        return position + ep.muzzleOffset(type: exitType, index: index, angle: angle, nose: nose)
    }

    /// Convenience: the muzzle for `mount`'s current exit cursor.
    public func muzzle(for mount: WeaponMount) -> Vec2 {
        muzzle(exitType: mount.spec.exitType, index: mount.exitCursor)
    }

    /// The exit-point index of `exitType` whose muzzle is closest to `target`
    /// (`wëap.Flags3` 0x0010). Falls back to 0 when the hull has ≤1 point of that
    /// type or declares none.
    public func closestExitIndex(exitType: WeaponExitType, to target: Vec2) -> Int {
        guard let ep = exitPoints else { return 0 }
        let n = ep.points(for: exitType).count
        guard n > 1 else { return 0 }
        var best = 0
        var bestD = Double.greatestFiniteMagnitude
        for i in 0..<n {
            let d = (muzzle(exitType: exitType, index: i) - target).length
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    /// EV Nova's `shïp.Strength` — relative combat power, used for the
    /// combat-odds check (`gövt.MaxOdds`) before an AI picks a fight.
    public var combatStrength: Double = 1
    /// Fraction of max armor at which a lethal hit disables this ship instead of
    /// destroying it outright. EV Nova: 33% by default, 10% if `shïp.Flags`
    /// bit 0x0010 is set. A one-time state transition, not a random roll —
    /// only ships not already disabled can cross it.
    public var disableArmorFraction: Double = 0.33
    /// `shïp.Flags2` 0x0080: "AI ships of this type will run away/dock if out
    /// of ammo for all ammo-using weapons."
    public var fleeWhenOutOfAmmo: Bool = false

    // Ionization: weapons can add `wëap.Ionization` charge on hit; once it
    // reaches `ionizeMax` the ship is "fully ionized" and "nearly immobilized"
    // (Bible) until the charge dissipates at `deionizePerSec`.
    public var ionCharge: Double = 0
    /// `shïp.IonizeMax` — 0 means this hull doesn't define the field (never
    /// considered ionized, rather than trivially "always ionized").
    public var ionizeMax: Double = 0
    public var deionizePerSec: Double = 0
    public var isIonized: Bool { ionizeMax > 0 && ionCharge >= ionizeMax }
    /// Ship-level jamming strength summed from fitted jammer outfits (`oütf`
    /// ModTypes 33-36). Stacks with the pilot government's inherent `InhJam1-4`
    /// when an incoming "turns away if jammed" guided shot rolls to keep lock.
    public var jamming: Int = 0
    /// Whether this ship auto-collects an asteroid's yield when it destroys the
    /// rock (`oütf` ModType 31 mining scoop, or `shïp.Flags3` 0x0002). Only the
    /// player's collection is surfaced (as a `.asteroidMined` event to the host).
    public var hasMiningScoop: Bool = false

    // Fuel — EV Nova's blue gauge. Spent by hyperspace jumps (100 per jump) and
    // by the afterburner; regenerates only if the hull/outfits grant it.
    public var maxFuel: Double = 0
    public var fuel: Double = 0
    public var fuelRegenPerSec: Double = 0
    /// Installed afterburner (nil = none).
    public var afterburner: Afterburner?
    /// True on frames the afterburner is actually burning (input + fuel present).
    public private(set) var afterburnerActive = false

    // Cargo hold: `cargoCapacity` tons total; `cargo` maps commodity id → tons.
    public var cargoCapacity: Int = 0
    public var cargo: [Int: Int] = [:]
    public var cargoUsed: Int { cargo.values.reduce(0, +) }
    public var cargoFree: Int { max(0, cargoCapacity - cargoUsed) }

    /// Credits aboard for plunder once disabled. -1 = not yet rolled; set to 0
    /// once the player has taken them, so re-boarding can't duplicate the haul.
    public var plunderCredits: Int = -1

    /// `shïp.Crew` — the crew complement, used on both sides of the EV Nova
    /// capture-odds math (attacker's crew vs. defender's crew × 10). See
    /// `World.captureChance`.
    public var crew: Int = 0
    /// Extra effective crew from marines outfits (positive `oütf` ModType 25).
    public var marineCrew: Int = 0
    /// Percentage points added to capture odds from negative-ModVal marines
    /// outfits (Bible: "-1 to -100 Increase the player's capture odds").
    public var captureOddsBonus: Int = 0

    /// A live fighter bay aboard a carrier: its immutable spec plus the running
    /// docked count, launch cooldown, and the set of currently-deployed fighter
    /// entity ids. `docked` starts full and is spent on launch, restored when a
    /// live fighter re-docks. See `World`'s fighter-bay handling.
    public final class FighterBay {
        public let spec: FighterBaySpec
        public var docked: Int
        public var launchCooldown: Double = 0
        public var deployed: Set<Int> = []
        public init(spec: FighterBaySpec) { self.spec = spec; self.docked = max(0, spec.capacity) }
    }
    /// Fighter bays fitted to this ship (empty for non-carriers).
    public var fighterBays: [FighterBay] = []

    // Cloaking (oütf ModType 17). `cloakFlags` are the OR'd device flags; the
    // rest is live state driven by `World`'s cloak step.
    public var cloakFlags: Int = 0
    public var cloakScannerFlags: Int = 0
    public var hasCloak: Bool { cloakFlags != 0 }
    /// Player/AI intent to be cloaked. Toggled by input (player) or the brain.
    public var cloakEngaged = false
    /// 0 = fully visible, 1 = fully cloaked; fades between when (dis)engaging.
    public var cloakLevel: Double = 0
    /// Substantially hidden — excluded from targeting/AI acquisition (unless the
    /// observer has a cloak scanner). Uses a high threshold so a ship mid-fade
    /// is still detectable.
    public var isCloaked: Bool { cloakLevel >= 0.99 }
    /// Fuel drained per second while cloaked (Bible bits 0x0010/20/40/80 = 1/2/4/8).
    public var cloakFuelPerSec: Double {
        Double((cloakFlags & 0x0010 != 0 ? 1 : 0) + (cloakFlags & 0x0020 != 0 ? 2 : 0)
             + (cloakFlags & 0x0040 != 0 ? 4 : 0) + (cloakFlags & 0x0080 != 0 ? 8 : 0))
    }
    /// Shield drained per second while cloaked (Bible bits 0x0100/200/400/800 = 1/2/4/8).
    public var cloakShieldPerSec: Double {
        Double((cloakFlags & 0x0100 != 0 ? 1 : 0) + (cloakFlags & 0x0200 != 0 ? 2 : 0)
             + (cloakFlags & 0x0400 != 0 ? 4 : 0) + (cloakFlags & 0x0800 != 0 ? 8 : 0))
    }
    /// 0x0002: a cloaked ship of this type still shows on radar.
    public var cloakVisibleOnRadar: Bool { cloakFlags & 0x0002 != 0 }
    /// 0x0004: engaging the cloak immediately drops shields to zero.
    public var cloakDropsShields: Bool { cloakFlags & 0x0004 != 0 }
    /// 0x0008: taking damage forces the cloak off.
    public var cloakDropsOnDamage: Bool { cloakFlags & 0x0008 != 0 }
    /// 0x1000: area cloak — ships in formation with this one are cloaked too.
    public var cloakIsArea: Bool { cloakFlags & 0x1000 != 0 }
    /// Cloak level shared onto this ship by an area-cloaking formation-mate
    /// (`cloakIsArea`), independent of any cloak device of its own. Maintained
    /// each frame by `World.stepCloak`.
    public var areaCloakLevel: Double = 0
    /// The stronger of this ship's own cloak and any area-cloak shared onto it
    /// by a formation-mate — what detection/rendering should actually use.
    public var effectiveCloakLevel: Double { max(cloakLevel, areaCloakLevel) }
    /// Substantially hidden by either its own cloak or a formation-mate's area
    /// cloak — the target-selection/radar/rendering-facing check.
    public var isEffectivelyCloaked: Bool { effectiveCloakLevel >= 0.99 }
    /// Anti-interference (oütf ModType 24): subtracted from the system's sensor
    /// static when computing this ship's effective sensor range.
    public var interferenceReduction: Int = 0
    /// Murk modifier (oütf ModType 28): added to/subtracted from the system's
    /// `sÿst.Murk` visual fog when computing this ship's effective murk.
    public var murkModifier: Int = 0
    /// ModType 11 (`escapePod`): if the player is flying this hull when
    /// destroyed, they eject and survive instead of a real game-over.
    public var hasEscapePod: Bool = false
    /// ModType 20 (`autoEject`): ignored without `hasEscapePod` — ejection
    /// itself is currently automatic either way, so this is tracked for
    /// completeness but doesn't change the outcome.
    public var hasAutoEject: Bool = false
    /// Set on a launched fighter: the entity id of the carrier it flew from, so
    /// it can dock back and be freed if the carrier dies. nil = not a fighter.
    public var carrierID: Int?
    /// `përs` id when this ship is a named character (5% spawn chance). Drives the
    /// target-display name and the ItemClass boarding-loot grant. nil = ordinary.
    public var personID: Int?

    /// Set when this ship was spawned *by a mission* (`mïsn` special/aux ship),
    /// tagged with the mission's resource id. Lets the world report goal progress
    /// (destroyed/disabled/…) back to the story layer and lets a mission clear
    /// its own ships when it ends (e.g. escorts that leave at a plot point). nil
    /// for all ambient `düde`/`flët` traffic.
    public var missionID: Int?
    /// This mission ship's objective from the player's side (`mïsn.ShipGoal`):
    /// what the player must *do* to it (destroy/disable/board/escort/…). Read by
    /// the world when the ship is destroyed/disabled to fire the matching
    /// `missionShipGoalReached` event. nil = not a mission ship, or no goal.
    public var missionShipGoal: MissionShipGoal?

    /// Set on a ship launched as a stellar's defense fleet (`spöb.DefenseDude`)
    /// during a Demand-Tribute fight — the `spöb` id it's defending. The
    /// domination flow counts these to know when a planet's defenders are cleared.
    /// nil for everything else.
    public var spobDefenderOf: Int?
    /// Outfit ids this hulk still owes the player as `përs` boarding loot; nil =
    /// not yet rolled, empty = already taken. See `World.takePlunderOutfits`.
    public var plunderOutfits: [Int]?
    /// True once this fighter has been told to return to its carrier (low on
    /// ammo/health, or the carrier left combat) — it heads home to dock.
    public var recallToCarrier = false

    /// Whether the ship has enough fuel for one hyperspace jump.
    public var canJump: Bool { fuel >= ShipFuel.perJump }
    /// Spend one jump's fuel; returns false and spends nothing if too low.
    @discardableResult
    public func consumeJumpFuel() -> Bool {
        guard fuel >= ShipFuel.perJump else { return false }
        fuel -= ShipFuel.perJump
        return true
    }
    /// Load up to `tons` of commodity `id` into the hold; returns tons added.
    @discardableResult
    public func loadCargo(_ id: Int, tons: Int) -> Int {
        let n = min(max(0, tons), cargoFree)
        if n > 0 { cargo[id, default: 0] += n }
        return n
    }
    /// Remove up to `tons` of commodity `id`; returns tons removed.
    @discardableResult
    public func unloadCargo(_ id: Int, tons: Int) -> Int {
        let have = cargo[id] ?? 0
        let n = min(max(0, tons), have)
        if n > 0 { let left = have - n; cargo[id] = left > 0 ? left : nil }
        return n
    }

    // AI state.
    public var brain: AIBrain?

    /// Co-op **client-side mirror of an NPC** the authority owns: a `brain == nil`
    /// ship whose entire state (position/velocity/health) is set from the
    /// authority's `WorldSnapshot` each update and coasts on its last velocity
    /// between them. Unlike `remotePlayer` it's not a player, so it gets no
    /// nameplate/player-blip and never warns about a missing brain — it's a passive
    /// visual/collision proxy for the shared world. Only ever set on a client whose
    /// own spawner is paused (`spawningPaused`); false for the authority's real
    /// AI/ambient NPCs and everything in single-player.
    public var networkMirror = false

    /// Non-nil marks this ship as **another player's ship** in a co-op session —
    /// not AI, not the local player. Such a ship carries `brain == nil` (it isn't
    /// AI-driven) and is stepped from an externally-supplied `ControlIntent` the
    /// net layer publishes into `World.remoteIntents[entityID]` each frame (see
    /// `World.step`). The stored value carries the owning peer + display name so
    /// the renderer can draw a nameplate and the HUD a minimap blip. Nil for the
    /// local player and every AI/ambient NPC, so single-player is untouched.
    public var remotePlayer: RemotePlayerInfo?
    /// The entity this ship is currently aiming at (for turrets / guided shots
    /// and HUD). Set by the brain each think().
    public var currentTargetID: Int?
    /// Indices into `weapons` of `loopSound` beam mounts currently held down —
    /// drives `.beamLoopStart`/`.beamLoopStop` so the renderer plays one real
    /// continuous loop per mount instead of retriggering a one-shot every
    /// reload tick (up to 10×/sec) while the trigger is held.
    var activeBeamLoopMounts: Set<Int> = []
    /// The brain requests hyperspace departure; the world despawns it past the
    /// system edge.
    public var wantsToDepart = false
    /// The brain has flown this ship into a stellar object to land; the world
    /// removes it (into the planet) and fires a `shipLanded` event.
    public var wantsToLand = false
    /// The stellar object being landed on (paired with `wantsToLand`).
    public var landingSpob: Int?

    // Hyperspace entry over-speed: a ship tearing in from hyperspace briefly
    // travels above its cruise cap, then bleeds down to normal speed — that
    // decelerating inrush is what "warping in" looks like. `entryOverspeed` is
    // the extra px/sec allowed on top of the normal cap right now; it decays by
    // `entryOverspeedDecayPerSec` each second back to zero (set on a hyperspace
    // arrival, otherwise 0 and inert). Applied in `step` before the speed clamp.
    public var entryOverspeed: Double = 0
    public var entryOverspeedDecayPerSec: Double = 0

    /// A drifting hulk: armor was knocked out but the ship wasn't destroyed. It
    /// carries no thrust or weapons and other ships leave it be; further damage
    /// finishes it off. Set by the world's damage handler.
    public var disabled = false
    /// Idle tumble (rad/sec) applied to a disabled hulk so it drifts believably.
    public var disableSpin: Double = 0
    /// Seconds a hulk has been drifting; the world eventually clears cold wrecks.
    public var disabledClock: Double = 0

    /// True if the player dealt the hit that dropped this ship to 0 armor —
    /// read once by `despawnDepartedAndDead` to attribute `Diplomacy.recordKill`
    /// to the player specifically (an NPC-vs-NPC kill shouldn't touch the
    /// player's legal record).
    public var killedByPlayer = false

    /// Debug/cheat only: when set, `applyDamage` is a no-op — shields and armor
    /// never drop and the ship can't be destroyed or disabled by weapon fire.
    /// The debug suite drives this on the player ship for "god mode"; nothing in
    /// normal gameplay ever sets it, so it's inert unless a developer flips it.
    public var invulnerable = false

    /// Formation-flight limit lift (0…1), requested by an escort's AI *this frame*.
    /// EV Nova escorts "ignore their own speed and maneuverability restraints to
    /// stay in formation" — so while holding station this scales up the ship's turn
    /// rate, acceleration, and top speed (see `Ship.step`) enough to pin the wing to
    /// any leader, however sluggish the hull. It still turns and thrusts frame to
    /// frame, so it reads as flying, not teleporting. `Ship.step` reads and clears
    /// it each frame; 0 for everything not currently holding formation.
    var formationBoost: Double = 0

    /// EV Nova's inertialess flight (`shïp` Flags2 0x0040, or the inertial-dampener
    /// outfit ModType 38): the ship has no momentum — its velocity tracks the nose
    /// with no lateral drift. Set at build time from the hull/outfits.
    public var inertialess = false
    /// The throttle-driven target speed for an inertialess hull (its velocity chases
    /// `heading × throttleSpeed`). Unused by inertial ships.
    var throttleSpeed: Double = 0

    // Diagnostics: last known-good motion state (NaN/Infinity guard) and
    // one-shot flags so we log state *transitions*, never every frame.
    private var lastFinitePosition = Vec2()
    private var loggedFuelEmpty = false
    private var loggedCanJump: Bool?
    private var loggedNoBrain = false

    public var isPlayer: Bool { entityID == 0 }
    /// Any human-driven ship in a co-op session: the local player (`isPlayer`) or
    /// another player's ship (`remotePlayer != nil`). Used to gate player-vs-player
    /// damage on the session's PvP rule.
    public var isPlayerControlled: Bool { isPlayer || remotePlayer != nil }
    public var isAlive: Bool { armor > 0 }
    /// 0…1 overall health, shields included, for morale/retreat decisions.
    public var healthFraction: Double {
        let maxTotal = maxShield + maxArmor
        return maxTotal > 0 ? (shield + armor) / maxTotal : 0
    }
    public var armorFraction: Double { maxArmor > 0 ? armor / maxArmor : 0 }
    public var shieldFraction: Double { maxShield > 0 ? shield / maxShield : 0 }

    public init(name: String, stats: ShipStats, position: Vec2 = Vec2(), angle: Double = 0) {
        self.name = name
        self.stats = stats
        self.position = position
        self.velocity = Vec2()
        self.angle = angle
        self.lastFinitePosition = position
    }

    /// The sprite frame index (0..<rotationFrames) for the current heading.
    public var spriteFrame: Int {
        let n = stats.rotationFrames
        guard n > 0 else { return 0 }
        let twoPi = 2 * Double.pi
        var a = angle.truncatingRemainder(dividingBy: twoPi)
        if a < 0 { a += twoPi }
        return Int((a / twoPi * Double(n)).rounded()) % n
    }

    // MARK: Combat helpers

    /// Apply damage the authentic EV Nova way: energy damage hits shields only,
    /// mass damage hits armor only, and **the hull can't be touched until the
    /// shields are knocked down** (Nova Bible, `wëap` MassDmg/EnergyDmg). The one
    /// exception is a shield-penetrating weapon (`wëap` Flags 0x0020, `piercing`),
    /// whose mass damage reaches armor even through live shields. Returns true if
    /// the hit destroyed the ship.
    @discardableResult
    public func applyDamage(shield dmgShield: Double, armor dmgArmor: Double,
                            piercing: Bool = false) -> Bool {
        // God mode (debug suite): swallow every hit whole — no shield/armor loss,
        // never reports a kill. Kept as the very first check so no damage math or
        // side effect runs for an invulnerable ship.
        if invulnerable { return false }
        // Whether shields were up *before* this shot lands decides hull exposure:
        // the very shot that empties the shields does NOT also bleed into armor —
        // only a later hit, arriving with shields already at zero, damages the
        // hull. A shield-penetrating weapon ignores that gate for its armor damage.
        let shieldsWereUp = shield > 0
        if dmgShield > 0 { shield = max(0, shield - dmgShield) }
        if dmgArmor > 0, piercing || !shieldsWereUp {
            armor = max(0, armor - dmgArmor)
        }
        return armor <= 0
    }

    func regen(_ dt: Double) {
        if shield < maxShield { shield = min(maxShield, shield + shieldRechargePerSec * dt) }
        if armor < maxArmor && armorRechargePerSec > 0 {
            armor = min(maxArmor, armor + armorRechargePerSec * dt)
        }
        if fuel < maxFuel && fuelRegenPerSec > 0 {
            fuel = min(maxFuel, fuel + fuelRegenPerSec * dt)
        }
        if ionCharge > 0 { ionCharge = max(0, ionCharge - deionizePerSec * dt) }
        logFuelTransitions()
    }

    /// Log-on-change fuel/jump-capability transitions — called after anything
    /// that can move `fuel` (afterburner drain in `step`, regen here). Cheap
    /// per-call comparison against stored previous state, not per-frame spam.
    private func logFuelTransitions() {
        let shipName = name, shipID = entityID
        if fuel <= 0 {
            if !loggedFuelEmpty {
                loggedFuelEmpty = true
                Log.physics.debug("Ship \(shipName) [\(shipID)] fuel depleted (0)")
            }
        } else {
            loggedFuelEmpty = false
        }
        let nowCanJump = canJump
        if loggedCanJump != nowCanJump {
            loggedCanJump = nowCanJump
            let curFuel = fuel
            Log.physics.debug("Ship \(shipName) [\(shipID)] canJump -> \(nowCanJump) (fuel=\(curFuel))")
        }
    }

    /// NaN/Infinity guard. A silent non-finite position or velocity presents
    /// with no other symptom than "ship won't move" or "ship flies off
    /// forever" — this is the single most valuable physics log there is. Logs
    /// loudly and recovers to the last known-good position rather than let a
    /// NaN silently propagate through the whole simulation.
    private func guardFiniteMotion() {
        if position.x.isFinite, position.y.isFinite,
           velocity.x.isFinite, velocity.y.isFinite {
            lastFinitePosition = position
            return
        }
        let shipName = name, shipID = entityID
        let badPos = position, badVel = velocity
        Log.physics.error("Ship \(shipName) [\(shipID)] non-finite motion detected — position=(\(badPos.x), \(badPos.y)) velocity=(\(badVel.x), \(badVel.y)); resetting to last known-good position and zeroing velocity")
        position = lastFinitePosition
        velocity = Vec2()
    }

    /// One-shot: an NPC with no `AIBrain` drifts under zero control input
    /// forever — exactly the "NPC just sits there" symptom. Called by
    /// `World.step` the first time it finds a brainless, living NPC.
    func logNoBrainOnce() {
        guard !loggedNoBrain else { return }
        loggedNoBrain = true
        let shipName = name, shipID = entityID
        Log.ai.debug("NPC \(shipName) [\(shipID)] has no AIBrain attached — will drift with zero control input")
    }

    /// Whether this ship flies the engine's driftless (inertialess) model right
    /// now. Its own hull/outfit flag (`inertialess`) always wins; on top of that,
    /// an AI-controlled ship (one with a `brain`) may fly driftless per the
    /// `FlightTuning.aiInertialess` scope, reproducing EV Nova's precise NPC
    /// flight. A player ship (no brain) without the hull flag always flies
    /// Newtonian, so the player/AI asymmetry the original had is preserved.
    func fliesInertialess(_ tuning: FlightTuning) -> Bool {
        if inertialess { return true }
        guard let brain = brain else { return false }
        switch tuning.aiInertialess {
        case .off:        return false
        case .formations: return brain.leaderID != nil || brain.isFleetMember
        case .all:        return true
        }
    }

    func step(_ dt: Double, intent: ControlIntent, tuning: FlightTuning) {
        // Fully ionized: "nearly immobilized" (Bible) — no active turning or
        // thrust until the charge dissipates below `ionizeMax`. Existing
        // momentum still coasts (drag/speed-clamp/position below still run).
        let controllable = !isIonized

        // Formation-flight limit lift: while an escort is holding station its AI
        // asks to ignore its own turn/accel/speed caps (EV Nova's escort behavior),
        // by a generous but finite factor so the wing pins to any leader yet still
        // visibly rotates and thrusts. Consumed each frame.
        let boost = formationBoost
        formationBoost = 0
        let effectiveTurnRate = stats.turnRate * (1 + 6 * boost)

        let maxTurn = effectiveTurnRate * dt * max(0.05, intent.turnScale)
        if controllable, intent.turnLeft || intent.turnRight {
            if intent.turnLeft { angle -= maxTurn }
            if intent.turnRight { angle += maxTurn }
        } else if controllable, let target = intent.desiredHeading {
            // Rotate toward the target heading, clamped to this frame's turn budget.
            let twoPi = 2 * Double.pi
            var delta = (target - angle).truncatingRemainder(dividingBy: twoPi)
            if delta > .pi { delta -= twoPi }
            if delta < -.pi { delta += twoPi }
            angle += max(-maxTurn, min(maxTurn, delta))
        }

        // Base accel / top speed, lifted by formation flight, then the afterburner
        // on top. EV Nova's afterburner is a held control that drains fuel.
        var accel = stats.acceleration * (1 + 5 * boost)
        var topSpeed = stats.maxSpeed * (1 + 1.0 * boost)
        afterburnerActive = false
        if controllable, intent.afterburner, let ab = afterburner, fuel > 0 {
            afterburnerActive = true
            accel *= ab.accelMultiplier
            topSpeed *= ab.speedMultiplier
            fuel = max(0, fuel - ab.fuelPerSecond * dt)
            logFuelTransitions()
        }
        // Hyperspace-entry over-speed: allow briefly exceeding cruise, decaying to
        // zero, so a jump-in eases down to cruise rather than snapping.
        if entryOverspeed > 0 {
            topSpeed += entryOverspeed
            entryOverspeed = max(0, entryOverspeed - entryOverspeedDecayPerSec * dt)
        }

        let heading = Vec2.heading(angle)
        if fliesInertialess(tuning) {
            // No inertia (shïp Flags2 0x40 / inertial-dampener outfit, or an AI ship
            // flying the `FlightTuning.aiInertialess` model): the ship has no lateral
            // momentum — its motion tracks the nose. A throttle scalar ramps up under
            // thrust, brakes under reverse, and bleeds off when idle.
            if controllable {
                if intent.thrust { throttleSpeed += accel * dt }
                else if intent.reverse { throttleSpeed -= accel * dt }
                else { throttleSpeed -= accel * dt }          // coast to a stop when idle
            }
            throttleSpeed = min(max(throttleSpeed, 0), topSpeed)
            // Rebuild velocity each frame from two independent parts, so the ship
            // never visibly slews (pointing one way while drifting another): its
            // *direction* rotates to follow the heading at this frame's own turn
            // budget — the same rate the nose just turned — so facing and motion stay
            // locked even through a hard turn; its *magnitude* ramps toward the
            // throttle target at up to 2×accel. Any momentum that isn't along the nose
            // (a hyperspace tear-in seeds velocity along the nose already, but a
            // knockback or fighter-launch inheriting a carrier's drift won't) is
            // steered onto the heading over a few frames rather than snapped. This is
            // the tight, driftless "goes exactly where it points" flying EV Nova's
            // inertialess hulls have. Drag/overspeed don't apply.
            let speed = velocity.length
            let velDir = speed > 1e-6 ? velocity * (1 / speed) : heading
            let twoPi = 2 * Double.pi
            var toNose = (angle - velDir.angle).truncatingRemainder(dividingBy: twoPi)
            if toNose > .pi { toNose -= twoPi }
            if toNose < -.pi { toNose += twoPi }
            let steered = Vec2.heading(velDir.angle + max(-maxTurn, min(maxTurn, toNose)))
            let dSpeed = throttleSpeed - speed
            let maxDv = accel * dt * 2
            let newSpeed = abs(dSpeed) <= maxDv ? throttleSpeed : speed + (dSpeed > 0 ? maxDv : -maxDv)
            velocity = steered * max(0, newSpeed)
        } else {
            if controllable, intent.thrust { velocity += heading * (accel * dt) }
            if controllable, intent.reverse { velocity += heading * (-stats.acceleration * 0.5 * dt) }
            if tuning.dragPerSecond > 0 {
                let k = max(0, 1 - tuning.dragPerSecond * dt)
                velocity = velocity * k
            }
            // Clamp to max speed (raised while the afterburner is lit / entering).
            let speed = velocity.length
            if speed > topSpeed, speed > 0 {
                velocity = velocity.normalized * topSpeed
            }
        }
        position += velocity * dt
        guardFiniteMotion()
    }
}

/// The live game simulation. Owns the player ship, the NPC ships, and their
/// projectiles, and advances everything deterministically from the current
/// `intent` (player) and each NPC's `brain`. Rendering reads state and drains
/// `events`; it never mutates the simulation.
public final class World {
    /// The player ship's fixed entity id. Escorts carry this as their `leaderID`.
    public static let playerEntityID = 0

    public var player: Ship
    public var intent = ControlIntent()

    /// Per-frame control input for **remote-player ships** (co-op), keyed by the
    /// ship's `entityID`. The net layer publishes each co-located friend's latest
    /// `ControlIntent` here before `step`; the sim drives their `brain == nil`,
    /// `remotePlayer != nil` ship from it exactly as it drives the local player
    /// from `intent`. An entity with no entry this frame coasts on an empty intent
    /// (a dropped/late packet reads as "no input", not a stall). Empty in
    /// single-player, so the AI/NPC path is completely unaffected. Prune entries
    /// for departed remote ships via `removeShip`, which clears them.
    public var remoteIntents: [Int: ControlIntent] = [:]

    /// Co-op: when true, the system's own `spawner` is held (no new ambient/AI
    /// ships are populated). Set on a **client** while it mirrors a co-located
    /// authority's world — the client shows the authority's NPCs (injected as
    /// `networkMirror` ships from snapshots) instead of populating its own, so the
    /// two players share one cast. False everywhere else, so single-player and the
    /// authority populate normally.
    public var spawningPaused = false

    /// Co-op PvP gate (host-set from `SessionRules.allowPvP`). When false (the
    /// default and the "safe" preset), players can't damage each other even when
    /// aiming at one another — the classic help-me-fight co-op. When true (full
    /// stakes), a player's weapons hit other players for real. Only affects
    /// player-vs-player **direct** hits; player-vs-NPC and NPC-vs-anyone are unchanged.
    public var pvpAllowed = false
    /// Co-op `SessionRules.friendlyFire`: whether a player's **area/splash** damage
    /// also catches other players (on top of `pvpAllowed`, which gates direct hits).
    /// Off ⇒ your blast weapons never singe an ally even in a PvP session.
    public var friendlyFireAllowed = false
    /// Co-op `SessionRules.pvpDamageReal`: when false, a player-vs-player hit still
    /// *registers* (flash/cloak-drop) but deals **zero** damage — a friendly spar.
    public var pvpDamageReal = true
    /// Co-op `SessionRules.deathReal`: when false, a **player-controlled** ship
    /// can't be destroyed — its armor is floored at 1 so it survives, however hard
    /// it's hit (by anyone). True (default) = normal, ships can die.
    public var playerDeathReal = true

    public var tuning: FlightTuning
    public var combatTuning: CombatTuning
    /// Set once the player's death has been reported via `.playerDestroyed`,
    /// so a `World` that keeps stepping with 0 armor (the app hasn't reacted
    /// yet) doesn't re-report it every frame.
    private var playerDeathReported = false

    /// Live NPC ships (does not include the player).
    public private(set) var npcs: [Ship] = []
    public private(set) var projectiles: [Projectile] = []
    /// Live beam segments the renderer mirrors each frame. Continuous beams are
    /// welded to their shooter (geometry recomputed every step); pulse beams are
    /// brief flashes. See `refreshActiveBeams`.
    public private(set) var activeBeams: [ActiveBeam] = []
    /// Transient render/audio events produced this step; drain after `step`.
    public private(set) var events: [WorldEvent] = []

    /// Append a world event. Exists so code in sibling files (e.g.
    /// `Domination.swift`) can emit without `events`' file-private setter.
    func emit(_ event: WorldEvent) { events.append(event) }

    /// Diplomacy table (governments & player standing). Optional so a bare
    /// physics world still works; when nil, nobody is hostile.
    public var diplomacy: Diplomacy?
    /// The system's stellar geometry (planets, jump radius) for AI navigation.
    public var systemContext = SystemContext()
    /// Catalog used to instantiate NPC ships & weapons. Optional for physics-only.
    public var galaxy: Galaxy?
    /// Populates and refreshes the NPC population.
    public var spawner: Spawner?

    /// Optional profiling sink for the game loop's stress/perf instrumentation.
    /// When set (only while the debug suite is attached), `step` reports how long
    /// each of its sub-phases took, in seconds, keyed by phase name (`"sim.ai"`,
    /// `"sim.projectiles"`, …). Nil in normal play, and every timing call is
    /// gated on it, so this costs nothing when the suite is off. See
    /// `FrameProfiler` on the app side, which is the sink this feeds.
    public var profiler: ((_ phase: String, _ seconds: Double) -> Void)?
    /// Running total of sub-phase time measured in the current `step`, so the
    /// unattributed remainder can be reported as `"sim.other"`.
    private var profMeasuredNs: UInt64 = 0

    /// Time a sub-phase of `step` and forward it to `profiler`, accumulating its
    /// cost so `step` can also report the un-timed remainder. A straight passthrough
    /// (no timing, no allocation) when no profiler is attached.
    @inline(__always)
    private func prof(_ name: String, _ body: () -> Void) {
        guard let profiler else { body(); return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        let dtn = DispatchTime.now().uptimeNanoseconds &- t0
        profMeasuredNs &+= dtn
        profiler(name, Double(dtn) / 1_000_000_000)
    }

    // MARK: Domination (Demand Tribute)

    /// The player's combat rating (`PlayerState.combatRating`), synced by the
    /// host. Gates whether a planet takes a tribute demand seriously or just
    /// laughs it off — see `demandTribute`. 0 by default (a fresh pilot).
    public var playerCombatRating: Int = 0
    /// Stellars the player has already dominated, synced by the host from
    /// persistent pilot state (`PlayerState.dominatedStellars`) plus any this
    /// world dominates during play. Read so a demand on an already-owned planet
    /// is a no-op, and so the host can persist a new conquest.
    public var dominatedStellars: Set<Int> = []
    /// How much combat rating a planet demands *per defending ship* before it
    /// will take a tribute demand seriously (below the threshold it laughs the
    /// player off). An engine tunable — stock EV Nova has no rating gate at all
    /// (the only real gate is defeating the defense fleet), so this is a
    /// deliberate addition; a tougher planet (more defenders) needs a higher
    /// rating. Set to 0 to disable the rating gate entirely.
    public var tributeRatingPerDefender: Int = 2
    /// Live Demand-Tribute contests in this system, keyed by `spöb` id. Tracks
    /// how many defenders a planet still has to launch and its wave size, so the
    /// world can relaunch waves as they're destroyed until the pool is exhausted.
    var stellarDefenses: [Int: StellarDefense] = [:]

    /// Live asteroids (real `röid` rocks, from the system's `sÿst.Asteroids`/
    /// `AstTypes` fields). Stationary — see `Asteroid`'s doc comment.
    public private(set) var asteroids: [Asteroid] = []

    public var rng = SplitMix64(seed: 0xE7_0A_5EED)
    private var nextEntityID = 1
    private var nextAsteroidID = 1

    /// Time before any authority ship will pick the player as a scan mark
    /// again. Each `AIBrain`'s own `scanCooldown` only throttles that one
    /// ship, so a busy system with several patrols could otherwise chain-scan
    /// the player back-to-back as each ship's individual cooldown expired.
    /// Set on every player scan; checked by `AIBrain.pickScanTarget`.
    public var playerScanCooldown: Double = 0
    /// Latched true the first time an authority ship scans the player this system
    /// visit. A fresh `World` is built on each system entry, so this resets
    /// naturally per visit — giving the original's "you get buzzed by about one
    /// ship each time you enter," not a repeating cooldown that lets a busy system
    /// re-scan you every minute you loiter. Checked by `AIBrain.pickScanTarget`.
    public var playerScanned = false

    public init(player: Ship, tuning: FlightTuning = .default,
                combatTuning: CombatTuning = .default) {
        self.player = player
        self.tuning = tuning
        self.combatTuning = combatTuning
        player.entityID = 0
        refreshRoster()
    }

    // MARK: Roster

    /// Every live ship, player first. Handy for AI perception. Refreshed once
    /// per `step()` by `refreshRoster()` rather than recomputed on each access —
    /// this is read many times per frame (every NPC's perception, every
    /// projectile/beam hit-scan), and rebuilding `[player] + npcs` on every one
    /// of those reads was a real per-frame allocation cost with several ships
    /// in a fight.
    public private(set) var allShips: [Ship] = []
    private var shipByID: [Int: Ship] = [:]

    /// Rebuild the cached roster + id index. Call after anything that can add
    /// or remove ships this frame (spawner, despawn) and before any code reads
    /// `allShips`/`ship(id:)`.
    private func refreshRoster() {
        allShips = [player] + npcs
        shipByID = Dictionary(uniqueKeysWithValues: allShips.map { ($0.entityID, $0) })
    }

    /// O(1) id → ship lookup (was a linear scan over `npcs`, called from
    /// several hot per-frame sites: AI target validation, fire-weapons target
    /// lookup, guided-projectile steering).
    public func ship(id: Int) -> Ship? { shipByID[id] }

    /// How a new NPC came into being, so the renderer can play the right effect:
    /// a mid-system populate (no effect), a hyperspace jump-in (warp streak at the
    /// edge), or a lift-off from a planet (grows out of the stellar).
    public enum ArrivalMode { case populate, hyperspace, launch, gate(spobID: Int) }

    /// Add an NPC, assigning it a fresh entity id. Returns the id.
    @discardableResult
    public func addNPC(_ ship: Ship, arrival: ArrivalMode = .populate) -> Int {
        ship.entityID = nextEntityID
        nextEntityID += 1
        npcs.append(ship)
        switch arrival {
        case .populate:
            events.append(.shipArrived(entityID: ship.entityID, at: ship.position, fromHyperspace: false))
        case .hyperspace:
            // A hyperspace jump-in isn't a standing start: the ship tears in along
            // its inbound heading well above cruise, then its AI brakes down to
            // normal speed. That physical inrush — not just a fade/scale pop — is
            // what reads as "warping in." Capped so a very fast hull doesn't shoot
            // clear across the system before it can slow.
            let inbound = Vec2(sin(ship.angle), cos(ship.angle))
            let entrySpeed = min(ship.stats.maxSpeed * 2.4, 3200)
            ship.velocity = inbound * entrySpeed
            // Seed the inertialess throttle to match, so a driftless AI arrival
            // rides its inbound momentum in and eases down rather than snapping
            // to cruise on the first frame (harmless for Newtonian hulls, which
            // ignore `throttleSpeed`).
            ship.throttleSpeed = entrySpeed
            // Let the speed cap start at the entry speed and bleed back to cruise
            // over ~1.3s, so the ship visibly rushes in and slows down.
            ship.entryOverspeed = max(0, entrySpeed - ship.stats.maxSpeed)
            ship.entryOverspeedDecayPerSec = ship.entryOverspeed / 1.3
            events.append(.shipArrived(entityID: ship.entityID, at: ship.position, fromHyperspace: true))
        case .launch:
            events.append(.shipLaunched(entityID: ship.entityID, at: ship.position))
        case let .gate(spobID):
            // Emerge from a hypergate: a gentle outward push (like a launch, not a
            // hyperspace tear-in) along the gate's emerge heading, then the
            // renderer plays the gate open→emerge→close beat.
            let outward = Vec2(sin(ship.angle), cos(ship.angle))
            ship.velocity = outward * min(ship.stats.maxSpeed * 0.6, 180)
            events.append(.shipEmergedFromGate(entityID: ship.entityID, gateSpobID: spobID, at: ship.position))
        }
        refreshRoster()
        return ship.entityID
    }

    /// Inject another player's ship into this system for co-op. It's an ordinary
    /// world `Ship` with **no brain** (so the AI never drives it) tagged with
    /// `remotePlayer`, added through the same `addNPC` seam as any arrival — so it
    /// gets an entity id, shows up in `allShips`/`ship(id:)`, takes and deals
    /// damage, and renders like any other ship, but is steered each frame from
    /// `remoteIntents[id]` (published by the net layer) instead of a brain. Returns
    /// the assigned entity id; keep it to route that peer's `InputFrame`s and to
    /// `removeShip` them when they leave the system. Build `ship` from the friend's
    /// real loadout (hull + outfits) exactly as you build the local player.
    @discardableResult
    public func spawnRemotePlayer(_ ship: Ship, info: RemotePlayerInfo,
                                  arrival: ArrivalMode = .hyperspace) -> Int {
        ship.brain = nil
        ship.remotePlayer = info
        return addNPC(ship, arrival: arrival)
    }

    /// Every remote-player ship currently in the system (co-op). Drives nameplates
    /// and minimap blips; empty in single-player.
    public var remotePlayerShips: [Ship] { npcs.filter { $0.remotePlayer != nil } }

    /// Inject a **client-side mirror of the authority's NPC** (co-op). A `brain ==
    /// nil`, `networkMirror` ship added through the same `addNPC` seam as any other
    /// — it renders, collides, and can be targeted like a real ship, but its state
    /// is driven entirely by the authority's snapshots (see `networkMirror`).
    /// Returns the assigned entity id; keep it to update/remove the mirror as
    /// snapshots arrive. Build `ship` from the reported hull so it sprites right.
    @discardableResult
    public func spawnNetworkMirror(_ ship: Ship, arrival: ArrivalMode = .populate) -> Int {
        ship.brain = nil
        ship.networkMirror = true
        return addNPC(ship, arrival: arrival)
    }

    /// Remove the system's real AI/ambient NPCs — everything that isn't a co-op
    /// mirror (`remotePlayer`/`networkMirror`). Called when a **client** starts
    /// mirroring a co-located authority's world, so its own populated cast gives
    /// way to the authority's (which then streams in as `networkMirror` ships).
    /// Silent: no departure events/effects, since these ships aren't leaving the
    /// fiction, they're being replaced by the shared world.
    public func removeAINPCs() {
        let survivors = npcs.filter { $0.remotePlayer != nil || $0.networkMirror }
        guard survivors.count != npcs.count else { return }
        for gone in npcs where gone.remotePlayer == nil && !gone.networkMirror {
            clearTarget(gone.entityID)
            stopAllBeamLoops(for: gone)
            remoteIntents[gone.entityID] = nil
        }
        npcs = survivors
        refreshRoster()
    }

    /// Co-op: spawn a **visual-only** echo of an authority's in-flight shot so a
    /// client sees enemy/ally fire, without simulating its damage (that's
    /// authoritative — see `Projectile.visualOnly`). Renders exactly like a real
    /// shot (`world.projectiles` is what the scene draws). `ownerID` is carried so a
    /// client can skip echoing its *own* shots (which it already fired locally).
    public func spawnVisualProjectile(position: Vec2, velocity: Vec2, facing: Double, life: Double,
                                      ownerID: Int, weaponID: Int, graphicSpinID: Int?,
                                      spinShots: Bool, translucentShots: Bool) {
        let p = Projectile(position: position, velocity: velocity, life: life,
                           shieldDamage: 0, armorDamage: 0, blastRadius: 0,
                           ownerID: ownerID, ownerGovt: independentGovt, homing: false,
                           turnRate: 0, speed: velocity.length, targetID: nil,
                           facing: facing, graphicSpinID: graphicSpinID, spinShots: spinShots,
                           weaponID: weaponID, translucentShots: translucentShots)
        p.visualOnly = true
        projectiles.append(p)
    }

    /// Remove all visual-only echoes (co-op client) — called before re-seeding them
    /// from a fresh snapshot. Leaves real, simulated shots untouched.
    public func clearVisualProjectiles() {
        projectiles.removeAll { $0.visualOnly }
    }

    /// Co-op: spawn a **visual-only** echo of an authority's beam segment so a
    /// client sees enemy/ally beam weapons. Drawn straight from `from`→`to`; never
    /// refreshed or life-counted (see `refreshActiveBeams`). `shooterID` is carried
    /// so a client can skip echoing its own beams.
    public func spawnVisualBeam(shooterID: Int, weaponID: Int, from: Vec2, to: Vec2, hit: Bool,
                                width: Double, color: (r: Double, g: Double, b: Double)?) {
        let beam = ActiveBeam(shooterID: shooterID, mountIndex: 0, weaponID: weaponID,
                              from: from, to: to, hit: hit, continuous: false,
                              life: .infinity, width: width, color: color)
        beam.visualOnly = true
        activeBeams.append(beam)
    }

    /// Remove all visual-only beam echoes (co-op client), before re-seeding from a
    /// fresh snapshot. Leaves real beams untouched.
    public func clearVisualBeams() {
        activeBeams.removeAll { $0.visualOnly }
    }

    /// Co-op: replay an authority's explosion as a one-shot effect on a client, so
    /// its scene plays the same boom/sound. Appends to this frame's `events` (which
    /// the scene drains) — call it **after** `step` (step clears events at its
    /// start), i.e. from the post-step sync flush.
    public func emitVisualExplosion(at position: Vec2, radius: Double, boomID: Int?) {
        events.append(.explosion(at: position, radius: radius, soundID: nil, boomID: boomID))
    }

    /// Test seam: inject a real (simulated) projectile into the world. Not used by
    /// gameplay — the sim spawns shots through `fireWeapons`.
    func testInjectProjectile(_ projectile: Projectile) {
        projectiles.append(projectile)
    }

    /// A government patrol/interceptor completed a scan pass on another ship.
    /// Called from `AIBrain.scan` when it closes to scan range; the renderer
    /// turns it into a visible scan sweep. Purely cosmetic in this engine —
    /// there's no contraband/ScanMask system yet to key consequences off.
    public func reportScan(scannerID: Int, targetID: Int, at: Vec2) {
        if targetID == 0 { playerScanCooldown = 60; playerScanned = true }
        events.append(.shipScanned(scannerID: scannerID, targetID: targetID, at: at))
    }

    public func drainEvents() -> [WorldEvent] {
        let e = events
        events.removeAll(keepingCapacity: true)
        return e
    }

    /// Remove every NPC from the simulation at once, cleanly: stop any beam
    /// loops they were sounding, drop any target locks pointed at them, and
    /// refresh the roster. Unlike the per-frame despawn path this emits no
    /// wreck/depart effects — it's a hard reset of the population, used by the
    /// in-game debug suite's performance stress test to clear the field before
    /// (and after) flooding it with a controlled fleet. Live projectiles are
    /// left to expire on their own.
    public func removeAllNPCs() {
        for npc in npcs {
            stopAllBeamLoops(for: npc)
            clearTarget(npc.entityID)
        }
        npcs.removeAll()
        refreshRoster()
    }

    // MARK: Mission ships (mïsn special/aux ships)

    /// Spawn a mission's special or auxiliary ships into the *current* system.
    /// This is the engine seam the story layer drives when a `mïsn` with a ship
    /// objective becomes active and its `ShipSystem`/`AuxShipSystem` resolves to
    /// the system the player is in: it places `count` ships of dude `dudeID`
    /// (drawn from the dude's weighted ship table and given its real hull loadout,
    /// exactly like ambient traffic), tags each with `missionID`/`goal`, and
    /// applies the mission's `ShipBehav` AI override. The caller (story layer) is
    /// responsible for only calling this when the mission's ship system matches
    /// the live world — the engine is single-system and doesn't know the galaxy
    /// map. Returns the placed entity ids.
    ///
    /// - `goal`: the player-side objective (`mïsn.ShipGoal`) — drives the
    ///   `missionShipGoalReached` events. `.rescue` starts the ships disabled
    ///   (the classic "protect this crippled freighter" setup).
    /// - `behavior`: the `ShipBehav` AI override (attack/protect the player).
    ///   `.protectPlayer` wires each ship as a player escort so the existing
    ///   escort logic makes it defend the player.
    @discardableResult
    public func spawnMissionShips(missionID: Int, dudeID: Int, count: Int,
                                  goal: MissionShipGoal = .none,
                                  behavior: MissionShipBehavior = .standard,
                                  government: Int? = nil,
                                  arrival: ArrivalMode = .hyperspace) -> [Int] {
        guard count > 0, let galaxy = galaxy, let dude = galaxy.game.dude(dudeID) else { return [] }
        var placed: [Int] = []
        for i in 0..<count {
            let roll = rng.int(in: 0...9999)
            guard let shipID = dude.pickShip(roll: roll) else { continue }
            let govt = government ?? (dude.govt >= 128 ? dude.govt : nil)
            let (pos, ang) = missionSpawnPose(arrival: arrival)
            guard let ship = galaxy.makeLoadedShip(shipID, government: govt, at: pos, angle: ang,
                                                   skillRoll: rng.double(in: -1...1)) else { continue }
            let brain = AIBrain(aiType: dude.aiType, govt: ship.government)
            brain.behaviorOverride = behavior
            if behavior == .protectPlayer {
                // Fly as one of the player's escorts — the escort logic then makes
                // it hold formation and adopt the player's target.
                brain.leaderID = World.playerEntityID
                brain.escortOrder = .defensive
                brain.formationSlot = i
            }
            ship.brain = brain
            ship.missionID = missionID
            ship.missionShipGoal = goal
            // A rescue objective's ship starts as a helpless drifting hulk the
            // player must protect/tow — same disabled state a crippled ship holds.
            var mode = arrival
            if goal == .rescue {
                ship.disabled = true
                ship.armor = max(1, ship.maxArmor * 0.02)
                ship.shield = 0
                ship.disableSpin = rng.double(in: -0.5...0.5)
                mode = .populate   // it's adrift in-system, not warping in
            }
            placed.append(addNPC(ship, arrival: mode))
        }
        if !placed.isEmpty {
            events.append(.missionShipsSpawned(missionID: missionID, entityIDs: placed))
        }
        return placed
    }

    /// Remove every ship tagged with `missionID` from the system — the seam for
    /// "the mission's escorts leave at a plot point" or a cancelled/failed
    /// mission clearing its ships. Not a kill: no wreck, no legal-record hit,
    /// just a clean exit (emits `missionShipsDespawned`, and a per-ship
    /// `shipDeparted` so the renderer can streak them out). Returns the ids
    /// removed.
    @discardableResult
    public func despawnMissionShips(missionID: Int) -> [Int] {
        let leaving = npcs.filter { $0.missionID == missionID }
        guard !leaving.isEmpty else { return [] }
        var removedIDs: [Int] = []
        for npc in leaving {
            events.append(.shipDeparted(entityID: npc.entityID, at: npc.position, heading: npc.angle))
            clearTarget(npc.entityID)
            stopAllBeamLoops(for: npc)
            removedIDs.append(npc.entityID)
        }
        let removing = Set(removedIDs)
        npcs.removeAll { removing.contains($0.entityID) }
        refreshRoster()
        events.append(.missionShipsDespawned(missionID: missionID, entityIDs: removedIDs))
        return removedIDs
    }

    /// Remove a single NPC from the world by entity id, sending it off with a
    /// warp-out (used when a player escort is released/departs — it flies off the
    /// same way an escort peeling away would). No-op for the player (id 0) or an
    /// unknown id.
    public func removeShip(entityID: Int) {
        guard entityID != Self.playerEntityID, let ship = shipByID[entityID] else { return }
        events.append(.shipDeparted(entityID: entityID, at: ship.position, heading: ship.angle))
        clearTarget(entityID)
        stopAllBeamLoops(for: ship)
        remoteIntents[entityID] = nil   // no orphaned input for a departed remote player
        npcs.removeAll { $0.entityID == entityID }
        refreshRoster()
    }

    /// Live mission ships currently in the system, optionally filtered to one
    /// mission. Lets the story layer poll objective ships (position, health,
    /// disabled/alive) without holding its own entity-id bookkeeping.
    public func missionShips(missionID: Int? = nil) -> [Ship] {
        npcs.filter { $0.missionID != nil && (missionID == nil || $0.missionID == missionID) }
    }

    /// A spawn position + facing for a mission ship. Edge/hyperspace arrivals come
    /// in at the jump ring pointed inward (same as ambient jump-ins); everything
    /// else scatters just inside the system so an already-present ship (a rescue
    /// hulk, an observed convoy) isn't stuck out at the rim.
    private func missionSpawnPose(arrival: ArrivalMode) -> (Vec2, Double) {
        let ctx = systemContext
        let bearing = rng.double(in: 0...(2 * .pi))
        switch arrival {
        case .hyperspace, .gate:
            let pos = ctx.center + Vec2(sin(bearing), cos(bearing)) * ctx.spawnRadius
            return (pos, (ctx.center - pos).angle)
        case .populate, .launch:
            let r = rng.double(in: 300...(ctx.jumpRadius * 0.6))
            let pos = ctx.center + Vec2(sin(bearing), cos(bearing)) * r
            return (pos, (ctx.center - pos).angle)
        }
    }

    // MARK: Asteroids

    /// Scatter `count` real asteroids of the enabled `typeIDs` (a system's
    /// `sÿst.Asteroids`/`AstTypes`) around `systemContext.center`, in the same
    /// interior scatter band `Spawner` uses for ship placement
    /// (`300...(jumpRadius*0.6)`, `Spawner.swift`). Call once after
    /// `systemContext`/`galaxy` are set. Each rock picks a uniformly-random
    /// enabled type — the Bible's `AstTypes` only says which types are
    /// enabled, not a weighting — and looks up its real stats/sprite geometry.
    public func populateAsteroids(typeIDs: [Int], count: Int) {
        guard count > 0, !typeIDs.isEmpty, let game = galaxy?.game else { return }
        let minRadius = 300.0
        let maxRadius = max(minRadius + 1, systemContext.jumpRadius * 0.6)
        for _ in 0..<count {
            let typeID = typeIDs[rng.int(in: 0...(typeIDs.count - 1))]
            let bearing = rng.double(in: 0...(2 * Double.pi))
            let dist = rng.double(in: minRadius...maxRadius)
            let position = systemContext.center + Vec2.heading(bearing) * dist
            if let a = spawnAsteroid(typeID: typeID, at: position, game: game) {
                asteroids.append(a)
            }
        }
    }

    /// Build one asteroid of `typeID` at `position` with a random initial spin
    /// phase, looking up its real `röid` stats and `spïn` sprite geometry (for
    /// the physical radius). Returns nil if the type's data can't be resolved.
    private func spawnAsteroid(typeID: Int, at position: Vec2, game: NovaGame) -> Asteroid? {
        guard let roid = game.roid(typeID) else { return nil }
        let radius = game.spin(typeID + 672).map { Double($0.tileWidth) / 2 } ?? 24
        let angle = rng.double(in: 0...(2 * Double.pi))
        let a = Asteroid(id: nextAsteroidID, roidTypeID: typeID, position: position, angle: angle,
                         roid: roid, radius: radius, hpScale: combatTuning.hpScale)
        nextAsteroidID += 1
        return a
    }

    /// Destroy an asteroid: explosion effect, and — per its real `FragType1/2`/
    /// `FragCount` — spawn smaller sub-asteroids at the same position (±50%
    /// count, per the Bible). A "Huge" type naturally shrinks into whatever its
    /// own `FragType` points at (e.g. "Big"/"Medium"); no invented scale factor.
    private func destroyAsteroid(_ rock: Asteroid, killerID: Int = -1) {
        rock.isAlive = false
        let rockBoomSound = rock.explosionBoomID.flatMap { galaxy?.game.boom($0)?.soundID }
        events.append(.explosion(at: rock.position, radius: max(20, rock.radius * 1.2),
                                 soundID: rockBoomSound, boomID: rock.explosionBoomID))
        if rock.partCount > 0 {
            events.append(.asteroidDebris(at: rock.position, color: rock.partColor, count: rock.partCount))
        }
        // Mining: if the player destroyed this rock with a mining scoop fitted, it
        // scoops the röid's YieldType/YieldQty (±50%) yield. The host clamps the
        // amount to the player's free cargo space (the engine doesn't track cargo).
        if killerID == player.entityID, player.hasMiningScoop,
           rock.yieldType >= 0, rock.yieldType <= 5, rock.yieldQty > 0 {
            let q = rng.int(in: max(1, rock.yieldQty - rock.yieldQty / 2)...(rock.yieldQty + rock.yieldQty / 2))
            events.append(.asteroidMined(cargoType: rock.yieldType, quantity: q, at: rock.position))
        }
        let fragTypes = [rock.fragType1, rock.fragType2].filter { $0 >= 128 }
        guard !fragTypes.isEmpty, rock.fragCount > 0, let game = galaxy?.game else { return }
        let n = rng.int(in: max(0, rock.fragCount - rock.fragCount / 2)...(rock.fragCount + rock.fragCount / 2))
        for _ in 0..<n {
            let typeID = fragTypes[rng.int(in: 0...(fragTypes.count - 1))]
            if let frag = spawnAsteroid(typeID: typeID, at: rock.position, game: game) {
                asteroids.append(frag)
            }
        }
    }

    // MARK: Step

    public func step(_ dt: Double) {
        // Frame-profiler bookkeeping: capture the whole-step span up front so the
        // time not covered by a named sub-phase below can be reported as
        // `"sim.other"`. Both are no-ops when no profiler is attached.
        profMeasuredNs = 0
        let profStepT0 = profiler != nil ? DispatchTime.now().uptimeNanoseconds : 0

        events.removeAll(keepingCapacity: true)
        playerScanCooldown = max(0, playerScanCooldown - dt)

        prof("sim.spawn") {
            if !spawningPaused { spawner?.update(dt, world: self) }   // paused on a co-op client (mirrors the authority)
            updateStellarDefenses()   // relaunch tribute-defense waves as they're cleared
            refreshRoster()
        }

        // Player: outside intent. Once dead, stop honouring the controls entirely —
        // no firing, and freeze the wreck in place (zero velocity, empty intent) so
        // it doesn't keep flying under live input (looking alive) while the death /
        // explosion sequence plays out and the app returns to the menu.
        prof("sim.player") {
            if player.isAlive {
                fireWeapons(from: player, intent: intent)
                player.step(dt, intent: intent, tuning: tuning)
            } else {
                player.velocity = Vec2()
                player.step(dt, intent: ControlIntent(), tuning: tuning)
            }
            wrapIntoSystem(player)
        }

        // NPCs: each brain decides an intent. Disabled hulks don't think — they
        // just tumble and bleed off speed until they cool and drift away. This
        // loop (AI think + fire + physics for every NPC) is the sim's dominant
        // cost under a crowded fight, so it gets its own profiler phase.
        prof("sim.ai") {
            for npc in npcs where npc.isAlive {
                if npc.disabled {
                    npc.disabledClock += dt
                    npc.velocity = npc.velocity * max(0, 1 - 0.35 * dt)
                    npc.angle += npc.disableSpin * dt
                    npc.position += npc.velocity * dt
                    wrapIntoSystem(npc)
                    continue
                }
                let npcIntent: ControlIntent
                if let brain = npc.brain {
                    npcIntent = brain.think(ship: npc, world: self, dt: dt)
                } else if npc.remotePlayer != nil {
                    // Another player's ship: driven from the outside, just like the
                    // local player, from the intent the net layer published this
                    // frame. A missing entry = no input this frame (coast), never a
                    // warning — remote input is expected to have gaps.
                    npcIntent = remoteIntents[npc.entityID] ?? ControlIntent()
                } else if npc.networkMirror {
                    // Client-side mirror of the authority's NPC: its state is set
                    // from snapshots; here it just coasts on its last velocity
                    // between them. No intent, no missing-brain warning.
                    npcIntent = ControlIntent()
                } else {
                    npc.logNoBrainOnce()
                    npcIntent = ControlIntent()
                }
                fireWeapons(from: npc, intent: npcIntent)
                npc.step(dt, intent: npcIntent, tuning: tuning)
                wrapIntoSystem(npc)
            }
        }

        // Cooldowns & regen (hulks recover nothing).
        prof("sim.regen") {
            for s in allShips {
                for w in s.weapons { w.tick(dt) }
                if !s.disabled { s.regen(dt) }
            }
        }

        // Fighter bays: carriers deploy fighters in combat; fighters dock back.
        prof("sim.bays") { updateFighterBays(dt) }
        // Cloaking devices: fade in/out and drain fuel/shield.
        prof("sim.cloak") { stepCloak(dt) }

        // Asteroids don't move (see `Asteroid`'s doc comment) — they only spin.
        prof("sim.asteroids") {
            for rock in asteroids where rock.isAlive {
                rock.angle += rock.angularVelocityDegPerSec * .pi / 180.0 * dt
            }
        }

        prof("sim.pointDefense") { runPointDefense() }
        prof("sim.projectiles") { stepProjectiles(dt) }
        prof("sim.despawn") { despawnDepartedAndDead() }
        // Ships have moved this step; weld continuous beams to their new
        // positions/headings and expire pulse-beam flashes.
        prof("sim.beams") { refreshActiveBeams(dt) }
        reportPlayerDeathIfNeeded()

        // Whatever time in `step` wasn't inside a named phase above (event reset,
        // roster bookkeeping, death report) — so the sim phases sum to the real
        // `step` cost with no silent gap.
        if let profiler {
            let totalNs = DispatchTime.now().uptimeNanoseconds &- profStepT0
            profiler("sim.other", Double(totalNs &- min(totalNs, profMeasuredNs)) / 1_000_000_000)
        }
    }

    /// The player's own death is otherwise invisible to `despawnDepartedAndDead`
    /// (which only ever looks at `npcs`) — report it exactly once via
    /// `.playerDestroyed`, alongside the same explosion effect an NPC kill
    /// gets, so the app can run its escape-pod-or-game-over reaction.
    private func reportPlayerDeathIfNeeded() {
        guard !playerDeathReported, !player.isAlive else { return }
        playerDeathReported = true
        // Since the dead player is no longer stepped through `fireWeapons`, its own
        // continuous-fire (beam) loop would never get its natural stop — emit it now
        // so the player's weapon loop doesn't keep sounding into the menu.
        stopAllBeamLoops(for: player)
        events.append(.explosion(at: player.position, radius: max(24, player.radius * 1.5),
                                 soundID: player.explosionSoundID, boomID: player.explosionBoomID))
        events.append(.playerDestroyed(hadEscapePod: player.hasEscapePod))
    }

    /// Toroidal wrap: EV Nova's systems are a fixed finite size — fly off one edge
    /// and you reappear on the opposite side ("no walls, but you roll over"). Folds
    /// a ship's position back into the `±wrapExtent` box around `systemContext.center`,
    /// on the x and y axes independently. Idempotent for in-bounds ships (the guard
    /// skips them entirely), so it only ever acts the frame a ship actually crosses
    /// an edge — the player's camera then hard-cuts to the far side, exactly the
    /// teleport-to-the-other-side the wrap should look like. NPCs heading out to jump
    /// despawn at `jumpRadius` (< `wrapExtent`), so they never wrap.
    private func wrapIntoSystem(_ ship: Ship) {
        let ext = systemContext.wrapExtent
        guard ext > 0 else { return }
        let rel = ship.position - systemContext.center
        guard abs(rel.x) > ext || abs(rel.y) > ext else { return }
        let span = 2 * ext
        func fold(_ v: Double) -> Double {
            var r = (v + ext).truncatingRemainder(dividingBy: span)
            if r < 0 { r += span }
            return r - ext
        }
        ship.position = systemContext.center + Vec2(fold(rel.x), fold(rel.y))
    }

    /// Guidance 9/10 mounts (`WeapRes.isPointDefense`): "fires automatically at
    /// incoming guided weapons and nearby ships" (Bible) — a targeting loop
    /// independent of the ship's own `currentTargetID`. Simplified to an
    /// instant intercept (destroys the incoming shot outright) rather than
    /// simulating a PD sub-projectile chasing it down; a shot's `Durability`
    /// (hits-to-kill) isn't modeled.
    private func runPointDefense() {
        for ship in allShips where ship.isAlive && !ship.disabled {
            for mount in ship.weapons where mount.spec.isPointDefense {
                guard mount.ready else { mount.logBlockedIfNeeded(for: ship); continue }
                let incoming = projectiles.filter { p in
                    p.alive && p.homing && p.vulnerableToPD
                        && canHit(owner: p.ownerID, ownerGovt: p.ownerGovt, victim: ship)
                        && (p.position - ship.position).length <= mount.spec.range
                }
                guard let target = incoming.min(by: {
                    ($0.position - ship.position).length < ($1.position - ship.position).length
                }) else { continue }
                mount.didFire(shots: 1)
                events.append(.weaponFired(shooterID: ship.entityID, at: ship.position,
                                           heading: (target.position - ship.position).angle,
                                           soundID: mount.spec.fireSoundID))
                // `wëap.Durability`: a tough guided shot soaks up N PD hits before
                // it's destroyed. 0 (the default) ⇒ shot down by this single hit.
                if target.pdDurability > 0 {
                    target.pdDurability -= 1
                    events.append(.explosion(at: target.position, radius: 6, soundID: nil, boomID: nil))
                } else {
                    target.alive = false
                    events.append(.explosion(at: target.position, radius: 10, soundID: nil, boomID: nil))
                    Log.combat.debug("\(ship.name) [\(ship.entityID)] point defense shot down an incoming projectile")
                }
            }
        }
    }

    // MARK: Weapons

    private func fireWeapons(from ship: Ship, intent: ControlIntent) {
        let primary = intent.firePrimary
        let secondary = intent.fireSecondary
        let anyTrigger = primary || secondary
        // NPCs only ever set `firePrimary`; let them fire every weapon group they
        // carry (guns AND missiles) whenever their brain wants to shoot.
        let isAI = ship.brain != nil
        updateBeamLoops(for: ship, primary: primary, secondary: secondary, isAI: isAI)
        guard anyTrigger, ship.isAlive else { return }
        let target = ship.currentTargetID.flatMap { self.ship(id: $0) }
        // `wëap.Flags3` 0x0020 (exclusive): while any exclusive weapon on this ship
        // is firing or still reloading, none of its *other* weapons may fire.
        let exclusiveBusy = ship.weapons.contains { $0.spec.isExclusive && $0.cooldown > 0 }

        for (mountIndex, mount) in ship.weapons.enumerated() {
            let spec = mount.spec
            // Point-defense mounts fire themselves via `runPointDefense`.
            if spec.isPointDefense { continue }
            // Exclusive lock: a non-exclusive weapon holds while an exclusive one
            // is mid-cycle (the exclusive weapon itself still fires when ready).
            if exclusiveBusy && !spec.isExclusive { continue }
            // Fire-group gating: guns on the primary trigger, missiles/rockets on
            // the secondary. NPCs fire everything on whichever trigger their AI
            // held. The player fires only the *selected* secondary, not every
            // secondary at once (EV Nova's secondary-weapon selection).
            let triggered: Bool
            if isAI {
                triggered = anyTrigger
            } else if spec.isSecondary {
                triggered = secondary && spec.id == ship.effectiveSecondaryID
            } else {
                triggered = primary
            }
            guard triggered else { continue }
            // Reload not ready / dry on ammo: the classic invisible "why didn't
            // my weapon fire" bug. Logged once per block-reason transition.
            guard mount.ready else {
                mount.logBlockedIfNeeded(for: ship)
                continue
            }
            // An AI's firing intent is a single blended trigger built from its
            // *longest*-range weapon (see `AIBrain.attack`), so a ship carrying
            // e.g. a long-range missile alongside a short-range beam would hold
            // at missile range and still fire the beam — which visibly falls
            // short of the target every time. Gate each mount by its own real
            // range so only weapons that can actually reach fire.
            if isAI, let target, spec.range > 0 {
                let engageDist = (target.position - ship.position).length
                guard engageDist <= spec.range * 1.05 else { continue }
            }
            // Seeker 0x0020: this guided weapon refuses to fire while its own
            // ship is fully ionized.
            if spec.cantFireWhileIonized && ship.isIonized { continue }
            // Flags3 0x0004: hold fire while a previous shot of this same weapon
            // is still aloft (owned by this ship).
            if spec.cantRefireUntilShotEnds,
               projectiles.contains(where: { $0.alive && $0.ownerID == ship.entityID && $0.weaponID == spec.id }) {
                continue
            }
            // AmmoType ≤ -1000: a fuel-burning weapon can't fire without the fuel.
            if spec.fuelPerShot > 0 && ship.fuel < spec.fuelPerShot { continue }

            // A group fires ONE barrel per event (cycling exit points) — unless
            // it has the "fire simultaneously" flag, which volleys all `count`.
            let barrels = max(1, mount.count)
            let shots = spec.fireSimultaneously ? barrels : 1
            var fired = 0
            for k in 0..<shots {
                // Flags3 0x0010: fire from the exit point closest to the target
                // (when there is one), rather than cycling the exit cursor.
                let exitIndex: Int
                if spec.firesFromClosestExit, let target {
                    exitIndex = ship.closestExitIndex(exitType: spec.exitType, to: target.position)
                } else {
                    exitIndex = spec.fireSimultaneously ? k : mount.exitCursor
                }
                let muzzle = ship.muzzle(exitType: spec.exitType, index: exitIndex)
                // Nil = can't fire (turret/quadrant with no target in arc): hold fire.
                guard var aim = fireAngle(for: spec, ship: ship, muzzle: muzzle, target: target) else { continue }
                if spec.accuracyRadians > 0 && !spec.firesAtFixedAngle {
                    aim += rng.double(in: -spec.accuracyRadians...spec.accuracyRadians)
                }
                if spec.isBeam {
                    fireBeam(from: ship, mount: mount, mountIndex: mountIndex, spec: spec, aim: aim, target: target)
                } else {
                    spawnProjectile(spec: spec, muzzle: muzzle, aim: aim,
                                    ownerID: ship.entityID, ownerGovt: ship.government,
                                    ownerVelocity: ship.velocity,
                                    targetID: spec.homes ? ship.currentTargetID : nil,
                                    subDepth: 0)
                    events.append(.weaponFired(shooterID: ship.entityID, at: muzzle, heading: aim, soundID: spec.fireSoundID))
                    // Recoil kicks the firing ship backward, opposite the shot,
                    // scaled down by its own mass (radius proxy) — same knockback
                    // model as projectile impact on a target.
                    if spec.recoil > 0 {
                        ship.velocity += Vec2(-cos(aim), -sin(aim)) * (spec.recoil * 6.0 / max(4, ship.radius))
                    }
                }
                fired += 1
                if !spec.fireSimultaneously { mount.exitCursor = (mount.exitCursor + 1) % barrels }
            }
            // Only spend the reload/ammo if a shot actually left (a turret with no
            // target produces `fired == 0` and stays ready).
            if fired > 0 {
                mount.didFire(shots: fired)
                // AmmoType ≤ -1000: burn fuel per shot instead of drawing ammo.
                if spec.fuelPerShot > 0 {
                    ship.fuel = max(0, ship.fuel - spec.fuelPerShot * Double(fired))
                }
                // AmmoType == -999: the firing ship self-destructs. Zeroing armor
                // makes it not-alive; the despawn / player-death path finalizes it
                // (explosion + shipDestroyed), same as any other kill.
                if spec.selfDestructsOnFire {
                    ship.shield = 0
                    ship.armor = 0
                }
            }
        }
    }

    /// The world angle a weapon fires at this frame given its guidance, or nil if
    /// it can't fire (turret/quadrant with no target in arc). Mirrors EV Nova /
    /// NovaJS: turrets and in-arc quadrant guns lead the moving target; guided,
    /// rockets, and plain guns fire along the hull heading (the projectile does
    /// any homing itself).
    private func fireAngle(for spec: WeaponSpec, ship: Ship, muzzle: Vec2, target: Ship?) -> Double? {
        switch spec.guidance {
        case .turret, .beamTurret:
            guard let t = target else { return nil }
            return leadAngle(from: muzzle, shooterVel: ship.velocity, target: t,
                             shotSpeed: spec.projectileSpeed, instantHit: spec.isBeam)
        case .frontQuadrant, .rearQuadrant:
            let base = spec.guidance == .rearQuadrant ? ship.angle + .pi : ship.angle
            guard let t = target else { return base }
            let q = quadrant(source: ship.position, facing: ship.angle, target: t.position)
            let inArc = (spec.guidance == .frontQuadrant && q == .front)
                     || (spec.guidance == .rearQuadrant && q == .rear)
            return inArc ? leadAngle(from: muzzle, shooterVel: ship.velocity, target: t,
                                     shotSpeed: spec.projectileSpeed, instantHit: false) : base
        default:
            // guided / rocket / plain gun / plain beam: along the hull heading.
            return ship.angle
        }
    }

    enum FireQuadrant { case front, sides, rear }
    private func quadrant(source: Vec2, facing: Double, target: Vec2) -> FireQuadrant {
        let rel = abs(angleDelta(from: facing, to: (target - source).angle))
        if rel < .pi / 4 { return .front }
        if rel > 3 * .pi / 4 { return .rear }
        return .sides
    }

    /// First-order intercept ("lead"): the world angle to fire a shot of
    /// `shotSpeed` so it meets a moving target. Falls back to aiming straight at
    /// the target when there's no real solution (or the shot is an instant-hit
    /// beam). Ported from NovaJS `guidance.ts` `firstOrderWithFallback`.
    private func leadAngle(from origin: Vec2, shooterVel: Vec2, target: Ship,
                           shotSpeed: Double, instantHit: Bool) -> Double {
        let straight = (target.position - origin).angle
        guard !instantHit, shotSpeed > 0 else { return straight }
        let pos = (target.position - origin) * (1.0 / shotSpeed)
        let vel = (target.velocity - shooterVel) * (1.0 / shotSpeed)
        let a = vel.dot(vel) - 1
        let b = 2 * pos.dot(vel)
        let c = pos.dot(pos)
        var time: Double?
        if abs(a) < 1e-9 {
            if abs(b) > 1e-9 { let t = -c / b; if t >= 0 { time = t } }
        } else {
            let det = b * b - 4 * a * c
            if det >= 0 {
                let s = det.squareRoot()
                time = [(-s - b) / (2 * a), (s - b) / (2 * a)].filter { $0 >= 0 }.sorted().first
            }
        }
        guard let t = time else { return straight }
        return (pos + vel * t).angle
    }

    /// Build and register a projectile (primary shot or submunition). Movement
    /// follows guidance: guided homes inertialessly, rockets accelerate from the
    /// owner's velocity, everything else inherits the owner's velocity plus the
    /// muzzle vector.
    @discardableResult
    private func spawnProjectile(spec: WeaponSpec, muzzle: Vec2, aim: Double,
                                 ownerID: Int, ownerGovt: Int, ownerVelocity: Vec2,
                                 targetID: Int?, subDepth: Int) -> Projectile {
        let dir = Vec2.heading(aim)
        let homing = spec.homes
        let accelerating = spec.accelerates
        let vel: Vec2
        if homing { vel = dir * spec.projectileSpeed }
        else if accelerating { vel = ownerVelocity }
        else { vel = ownerVelocity + dir * spec.projectileSpeed }
        let life = spec.range / max(1, spec.projectileSpeed)
        let p = Projectile(position: muzzle, velocity: vel, life: life,
                           shieldDamage: spec.shieldDamage, armorDamage: spec.armorDamage,
                           blastRadius: spec.blastRadius, ownerID: ownerID, ownerGovt: ownerGovt,
                           homing: homing, turnRate: spec.turnRate, speed: spec.projectileSpeed,
                           targetID: homing ? targetID : nil,
                           vulnerableToPD: spec.vulnerableToPD, ionization: spec.ionization,
                           accelerating: accelerating, facing: aim,
                           decayPerSec: spec.decayPerSec, proxRadius: spec.proxRadius,
                           proxSafetyRemaining: spec.proxSafetySeconds, proxHitAll: spec.proxHitAll,
                           detonateOnExpire: spec.detonateOnExpire, impact: spec.impact,
                           submunition: spec.submunition, subDepth: subDepth,
                           explosionBoomID: spec.explosionBoomID,
                           graphicSpinID: spec.graphicSpinID, spinShots: spec.spinShots,
                           confusedByInterference: spec.confusedByInterference,
                           turnsAwayIfJammed: spec.turnsAwayIfJammed,
                           penetratesShields: spec.penetratesShields,
                           weaponID: spec.id, pdDurability: spec.durability,
                           translucentShots: spec.translucentShots)
        projectiles.append(p)
        return p
    }

    /// Nearest hittable ship to `pos` (for submunitions that seek the nearest
    /// valid target). Skips the owner and its own faction.
    private func nearestHostile(to pos: Vec2, ownerID: Int, ownerGovt: Int) -> Ship? {
        var best: Ship?
        var bestD = Double.greatestFiniteMagnitude
        for other in allShips where other.isAlive {
            guard canHit(owner: ownerID, ownerGovt: ownerGovt, victim: other) else { continue }
            let d = (other.position - pos).length
            if d < bestD { bestD = d; best = other }
        }
        return best
    }

    /// Start/stop a real audio loop for each `loopSound` beam mount as its
    /// ship's trigger is held/released — independent of the reload tick, so a
    /// continuous-fire beam sounds like one sustained loop rather than a
    /// one-shot sample retriggered up to 10×/sec while held. Also creates/removes
    /// the persistent `ActiveBeam` whose geometry `refreshActiveBeams` welds to
    /// the ship every frame.
    private func updateBeamLoops(for ship: Ship, primary: Bool, secondary: Bool, isAI: Bool) {
        for (idx, mount) in ship.weapons.enumerated() where mount.spec.isBeam && mount.spec.loopSound {
            // A continuous beam loops while its own fire group's trigger is held.
            let held = isAI ? (primary || secondary) : (mount.spec.isSecondary ? secondary : primary)
            let looping = ship.activeBeamLoopMounts.contains(idx)
            if held && ship.isAlive {
                if !looping {
                    ship.activeBeamLoopMounts.insert(idx)
                    events.append(.beamLoopStart(shooterID: ship.entityID, mountIndex: idx,
                                                 soundID: mount.spec.fireSoundID))
                    spawnActiveBeam(for: ship, mount: mount, mountIndex: idx, continuous: true)
                }
            } else if looping {
                ship.activeBeamLoopMounts.remove(idx)
                events.append(.beamLoopStop(shooterID: ship.entityID, mountIndex: idx))
                removeActiveBeam(shooterID: ship.entityID, mountIndex: idx)
            }
        }
    }

    /// Stop any beam loops still active on `ship` — called wherever a ship
    /// stops being simulated (disabled, destroyed, landed, departed) since
    /// `fireWeapons` (the only other place loops stop) won't run for it again.
    private func stopAllBeamLoops(for ship: Ship) {
        guard !ship.activeBeamLoopMounts.isEmpty else { return }
        for idx in ship.activeBeamLoopMounts {
            events.append(.beamLoopStop(shooterID: ship.entityID, mountIndex: idx))
            removeActiveBeam(shooterID: ship.entityID, mountIndex: idx)
        }
        ship.activeBeamLoopMounts.removeAll()
    }

    /// Instant-hit beam fired this reload tick: apply damage along the ray from
    /// the mount's real exit point. Continuous beams keep their persistent
    /// `ActiveBeam` (refreshed each frame); pulse beams get a brief flash beam
    /// and their own fire sound.
    private func fireBeam(from ship: Ship, mount: WeaponMount, mountIndex: Int,
                          spec: WeaponSpec, aim: Double, target: Ship?) {
        let origin = ship.muzzle(for: mount)
        let dir = Vec2.heading(aim)
        let cast = beamCast(from: origin, dir: dir, range: spec.range, owner: ship)
        if let h = cast.hitShip {
            applyHit(to: h, shield: spec.shieldDamage, armor: spec.armorDamage, ownerID: ship.entityID,
                     ionization: spec.ionization, piercing: spec.penetratesShields, weaponID: spec.id)
            // Tractor beam (negative Impact): pull the target toward the firing
            // ship each time the beam connects, more strongly on lighter hulls.
            if spec.isTractorBeam {
                let pull = (ship.position - h.position).normalized * (-spec.impact * 3.0 / max(4, h.radius))
                h.velocity += pull
            }
        } else if let rock = cast.hitAsteroid {
            applyAsteroidHit(rock, shield: spec.shieldDamage, armor: spec.armorDamage, shooterID: ship.entityID)
        }
        let hit = cast.hitShip != nil || cast.hitAsteroid != nil
        if !spec.loopSound {
            // Pulse beam: a short-lived flash welded to the exit point. Continuous
            // beams instead keep the persistent ActiveBeam from updateBeamLoops.
            if let existing = activeBeams.first(where: { $0.shooterID == ship.entityID && $0.mountIndex == mountIndex && !$0.continuous }) {
                existing.from = origin; existing.to = cast.end; existing.hit = hit
                existing.life = 0.08
            } else {
                activeBeams.append(ActiveBeam(shooterID: ship.entityID, mountIndex: mountIndex,
                                              weaponID: spec.id, from: origin, to: cast.end, hit: hit,
                                              continuous: false, life: 0.08,
                                              width: spec.beamWidth, color: spec.beamColor))
            }
        }
        // Telemetry/audio event (renderer draws geometry from `activeBeams`, not
        // this). `loopSound` beams get their audio from beamLoopStart/Stop, so
        // they carry no one-shot id here.
        events.append(.beam(shooterID: ship.entityID, mountIndex: mountIndex, from: origin, to: cast.end,
                            hit: hit, soundID: spec.loopSound ? nil : spec.fireSoundID))
    }

    /// Raycast a beam of `range` px from `origin` along unit `dir`: the nearest
    /// hittable ship or asteroid, and the clipped endpoint.
    private func beamCast(from origin: Vec2, dir: Vec2, range: Double, owner: Ship)
        -> (end: Vec2, hitShip: Ship?, hitAsteroid: Asteroid?) {
        var bestT = range
        var hitShip: Ship?
        var hitAsteroid: Asteroid?
        for other in allShips where other.entityID != owner.entityID && other.isAlive {
            if !canHit(owner: owner.entityID, ownerGovt: owner.government, victim: other) { continue }
            let rel = other.position - origin
            let along = rel.dot(dir)
            guard along > 0, along <= range else { continue }
            let perp = (rel - dir * along).length
            if perp <= other.radius + 4 && along < bestT {
                bestT = along; hitShip = other; hitAsteroid = nil
            }
        }
        for rock in asteroids where rock.isAlive {
            let rel = rock.position - origin
            let along = rel.dot(dir)
            guard along > 0, along <= range else { continue }
            let perp = (rel - dir * along).length
            if perp <= rock.radius + 4 && along < bestT {
                bestT = along; hitAsteroid = rock; hitShip = nil
            }
        }
        let end = (hitShip != nil || hitAsteroid != nil) ? origin + dir * bestT : origin + dir * range
        return (end, hitShip, hitAsteroid)
    }

    /// Create the persistent beam segment for a continuous mount (geometry is
    /// filled in immediately and refreshed every frame by `refreshActiveBeams`).
    private func spawnActiveBeam(for ship: Ship, mount: WeaponMount, mountIndex: Int, continuous: Bool) {
        guard !activeBeams.contains(where: { $0.shooterID == ship.entityID && $0.mountIndex == mountIndex }) else { return }
        let beam = ActiveBeam(shooterID: ship.entityID, mountIndex: mountIndex,
                              weaponID: mount.spec.id, from: ship.position, to: ship.position, hit: false,
                              continuous: continuous, life: .infinity,
                              width: mount.spec.beamWidth, color: mount.spec.beamColor)
        activeBeams.append(beam)
        refreshBeam(beam)
    }

    private func removeActiveBeam(shooterID: Int, mountIndex: Int) {
        activeBeams.removeAll { $0.shooterID == shooterID && $0.mountIndex == mountIndex }
    }

    /// Recompute a continuous beam's geometry from its live shooter, so the beam
    /// stays welded to the moving, turning ship and re-clips to whatever it's
    /// now pointing at.
    private func refreshBeam(_ beam: ActiveBeam) {
        guard let ship = ship(id: beam.shooterID), ship.isAlive,
              beam.mountIndex < ship.weapons.count else { return }
        let mount = ship.weapons[beam.mountIndex]
        let spec = mount.spec
        let origin = ship.muzzle(for: mount)
        // Beams track the current target; otherwise they fire straight ahead.
        var aim = ship.angle
        if let tID = ship.currentTargetID, let t = self.ship(id: tID), t.isAlive {
            aim = (t.position - origin).angle
        }
        let cast = beamCast(from: origin, dir: Vec2.heading(aim), range: spec.range, owner: ship)
        beam.from = origin
        beam.to = cast.end
        beam.hit = cast.hitShip != nil || cast.hitAsteroid != nil
    }

    /// Advance all live beams once per step: weld continuous beams to their
    /// shooters (dropping any whose loop ended or shooter vanished) and count
    /// pulse beams down.
    private func refreshActiveBeams(_ dt: Double) {
        guard !activeBeams.isEmpty else { return }
        activeBeams.removeAll { beam in
            if beam.visualOnly { return false }   // co-op echo: left as-is, replaced by the next snapshot
            if beam.continuous {
                guard let ship = ship(id: beam.shooterID), ship.isAlive,
                      ship.activeBeamLoopMounts.contains(beam.mountIndex) else { return true }
                refreshBeam(beam)
                return false
            } else {
                beam.life -= dt
                return beam.life <= 0
            }
        }
    }

    /// Weapon → asteroid damage. Asteroids have no shields, so shield+armor
    /// damage both come off `hp` (scaled the same way ship armor is via
    /// `combatTuning`). Not modeling the wëap "x10 mass damage to asteroids"
    /// flag — that bit isn't decoded on `WeaponSpec` anywhere in this engine
    /// yet, so every weapon currently does its normal damage to rock.
    private func applyAsteroidHit(_ rock: Asteroid, shield: Double, armor: Double, shooterID: Int) {
        rock.hp -= (shield + armor) * combatTuning.damageScale
        if rock.hp <= 0 { destroyAsteroid(rock, killerID: shooterID) }
    }

    // MARK: Projectiles

    private func stepProjectiles(_ dt: Double) {
        // Submunitions spawned this frame are collected and appended after the
        // loop so we don't mutate `projectiles` while iterating it.
        var spawned: [Projectile] = []
        for p in projectiles where p.alive {
            // Co-op visual echo (client): fly straight on its velocity and expire,
            // no collision/damage/submunitions — the real shot lives on the
            // authority and its damage rides ship-health sync.
            if p.visualOnly {
                p.facing = p.velocity.angle
                p.position += p.velocity * dt
                p.life -= dt
                if p.life <= 0 { p.alive = false }
                continue
            }
            p.proxSafetyRemaining = max(0, p.proxSafetyRemaining - dt)

            // Movement by guidance.
            if p.homing {
                // Seeker 0x0010 "turns away if jammed": each second in flight,
                // an at-risk shot has a chance (equal to its target's
                // government's summed InhJam1-4, clamped 0-100%) to lose lock
                // entirely — an engine reading of the four jam types as one
                // combined jam strength, since the Bible doesn't specify how
                // a weapon picks among them.
                if p.turnsAwayIfJammed, let tid = p.targetID, let t = ship(id: tid) {
                    // Combined jam = target government's inherent InhJam1-4 plus the
                    // target ship's own fitted jammer outfits (ModTypes 33-36).
                    let govtJam = diplomacy?.govt(t.government)?.jamming.reduce(0, +) ?? 0
                    let jam = max(0, min(100, govtJam + t.jamming))
                    if jam > 0, rng.double(in: 0...1) < (Double(jam) / 100) * dt {
                        p.targetID = nil
                    }
                }
                // Steer the heading toward the first-order intercept, then fly
                // inertialessly at cruise speed along it (EV Nova guided shots
                // don't drift — they point where they're going).
                if let tid = p.targetID, let t = ship(id: tid), t.isAlive {
                    let lead = leadAngle(from: p.position, shooterVel: p.velocity, target: t,
                                         shotSpeed: p.speed, instantHit: false)
                    var d = angleDelta(from: p.facing, to: lead)
                    // Seeker 0x0008 "confused by sensor interference": the
                    // same range-degrading curve `effectiveSensorRange` uses
                    // for AI perception, applied to steering rate instead.
                    let turnRate = p.confusedByInterference
                        ? p.turnRate * max(0, 1 - Double(systemInterference) / 100)
                        : p.turnRate
                    let maxTurn = turnRate * dt
                    d = max(-maxTurn, min(maxTurn, d))
                    p.facing += d
                }
                p.velocity = Vec2.heading(p.facing) * p.speed
            } else if p.accelerating {
                // Rocket: accelerate forward up to cruise speed (reach it in ~0.5s).
                let along = Vec2.heading(p.facing)
                p.velocity += along * (p.speed / 0.5 * dt)
                if p.velocity.length > p.speed { p.velocity = p.velocity.normalized * p.speed }
            } else {
                p.facing = p.velocity.angle
            }
            // Remember where the shot was so collision can sweep the whole path it
            // covered this frame, not just its endpoint — a fast shot moves many
            // times a small ship's radius per frame and would otherwise tunnel
            // clean through it (the "shots pass through and never hit" bug).
            let prevPos = p.position
            p.position += p.velocity * dt

            // Power decay: the shot loses damage the longer it flies.
            if p.decayPerSec > 0 {
                p.shieldDamage = max(0, p.shieldDamage - p.decayPerSec * dt)
                p.armorDamage = max(0, p.armorDamage - p.decayPerSec * dt)
            }

            p.life -= dt
            if p.life <= 0 {
                p.alive = false
                detonate(p, at: p.position, directHit: nil, expired: true, spawned: &spawned)
                continue
            }

            // Collision — direct hit, or within the proximity radius once armed.
            guard p.proxSafetyRemaining <= 0 else { continue }
            let reach = p.proxRadius
            var struck: Ship?
            for other in allShips where other.isAlive {
                guard canHit(owner: p.ownerID, ownerGovt: p.ownerGovt, victim: other) else { continue }
                // Swept distance: shortest gap between the ship and the segment the
                // shot travelled this frame, so a high-velocity round still connects
                // with a small hull it flew past between samples.
                let dist = Self.segmentPointDistance(prevPos, p.position, other.position)
                if dist <= other.radius {
                    struck = other; break
                }
                // Proximity fuse: detonate near a valid ship. When the shot only
                // arms on its own target, ignore proximity to anyone else.
                if reach > 0 && dist <= other.radius + reach {
                    if p.proxHitAll || p.targetID == nil || p.targetID == other.entityID {
                        struck = other; break
                    }
                }
            }
            if let h = struck {
                p.alive = false
                detonate(p, at: p.position, directHit: h, expired: false, spawned: &spawned)
                continue
            }

            for rock in asteroids where rock.isAlive {
                if Self.segmentPointDistance(prevPos, p.position, rock.position) <= rock.radius + reach {
                    applyAsteroidHit(rock, shield: p.shieldDamage, armor: p.armorDamage, shooterID: p.ownerID)
                    p.alive = false
                    detonate(p, at: p.position, directHit: nil, expired: false, spawned: &spawned)
                    break
                }
            }
        }
        projectiles.append(contentsOf: spawned)
        projectiles.removeAll { !$0.alive }
        asteroids.removeAll { !$0.isAlive }
    }

    /// Shortest distance from point `c` to the line segment `a`→`b`. Backs swept
    /// projectile collision so a shot that jumps past a small ship between frames
    /// is still caught (no tunnelling through fast-moving or small targets).
    static func segmentPointDistance(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
        let ab = b - a
        let len2 = ab.x * ab.x + ab.y * ab.y
        guard len2 > 1e-9 else { return (c - a).length }
        var t = ((c - a).x * ab.x + (c - a).y * ab.y) / len2
        t = max(0, min(1, t))
        return (c - (a + ab * t)).length
    }

    /// Resolve a shot ending: apply its direct/blast damage and knockback, emit
    /// the explosion effect, and launch any submunitions. `expired` distinguishes
    /// end-of-life (which only detonates flak / expiry-submunition shots) from a
    /// real hit.
    private func detonate(_ p: Projectile, at pos: Vec2, directHit: Ship?, expired: Bool,
                          spawned: inout [Projectile]) {
        if let h = directHit {
            applyHit(to: h, shield: p.shieldDamage, armor: p.armorDamage, ownerID: p.ownerID,
                     ionization: p.ionization, piercing: p.penetratesShields, weaponID: p.weaponID)
            if p.impact > 0 {
                // Knockback along the shot's travel, inversely ∝ target size
                // (a proxy for mass — heavier hulls barely budge).
                h.velocity += p.velocity.normalized * (p.impact * 6.0 / max(4, h.radius))
            }
        }
        // Blast splash to everyone else in radius.
        if p.blastRadius > 0 {
            let ownerIsPlayer = ship(id: p.ownerID)?.isPlayerControlled == true
            for splash in allShips where splash.isAlive && splash.entityID != directHit?.entityID {
                guard canHit(owner: p.ownerID, ownerGovt: p.ownerGovt, victim: splash) else { continue }
                // Co-op friendly fire: a player's blast only catches another player
                // when friendly fire is enabled (direct hits already pass canHit's
                // pvp gate; this is the extra splash-only guard).
                if ownerIsPlayer, splash.isPlayerControlled, !friendlyFireAllowed { continue }
                if (splash.position - pos).length <= p.blastRadius {
                    applyHit(to: splash, shield: p.shieldDamage * 0.5, armor: p.armorDamage * 0.5,
                             ownerID: p.ownerID, ionization: p.ionization * 0.5,
                             piercing: p.penetratesShields, weaponID: p.weaponID)
                }
            }
        }
        // Explosion effect (skip a silent end-of-life fizzle for a plain shot
        // that isn't flak and has no blast).
        let shouldExplode = directHit != nil || p.blastRadius > 0 || p.detonateOnExpire || p.explosionBoomID != nil
        if shouldExplode {
            let boomSound = p.explosionBoomID.flatMap { galaxy?.game.boom($0)?.soundID }
            let radius = p.blastRadius > 0 ? p.blastRadius : 12
            events.append(.explosion(at: pos, radius: max(8, radius), soundID: boomSound,
                                     boomID: p.explosionBoomID))
        }
        // Submunitions: split into child weapons on detonation (and on expiry
        // when `subIfExpire`), capped by the recursion limit.
        if let sub = p.submunition, sub.count > 0, p.subDepth <= sub.limit,
           !(expired && !sub.ifExpire), let subSpec = galaxy?.weaponSpec(sub.weaponID) {
            for _ in 0..<sub.count {
                var aim = p.facing
                var subTarget = p.targetID
                if sub.fireAtNearest, let near = nearestHostile(to: pos, ownerID: p.ownerID, ownerGovt: p.ownerGovt) {
                    aim = subSpec.guidance == .guided ? aim : (near.position - pos).angle
                    subTarget = near.entityID
                }
                if sub.thetaRadians > 0 {
                    aim += rng.double(in: -sub.thetaRadians...sub.thetaRadians)
                }
                let child = spawnProjectile(spec: subSpec, muzzle: pos, aim: aim,
                                            ownerID: p.ownerID, ownerGovt: p.ownerGovt,
                                            ownerVelocity: Vec2(), targetID: subTarget,
                                            subDepth: p.subDepth + 1)
                // `spawnProjectile` appended to `projectiles`; move it to the
                // deferred list so we don't process it again this same frame.
                if projectiles.last === child { projectiles.removeLast(); spawned.append(child) }
            }
        }
    }

    /// Whether a shot from `owner` (faction `ownerGovt`) may damage `victim`.
    /// No self-hits and no friendly fire between the same government.
    private func canHit(owner: Int, ownerGovt: Int, victim: Ship) -> Bool {
        if victim.entityID == owner { return false }
        // Player-vs-player: co-op partners carry a shared government (so they'd
        // normally be un-hittable allies), so PvP is gated by the session rule
        // instead of that government — regardless of faction, one player can only
        // damage another when the host has enabled PvP.
        if victim.isPlayerControlled, let ownerShip = ship(id: owner), ownerShip.isPlayerControlled {
            return pvpAllowed
        }
        // Same government doesn't shoot itself (independents are fair game).
        if ownerGovt != independentGovt && victim.government == ownerGovt { return false }
        return true
    }

    private func applyHit(to ship: Ship, shield: Double, armor: Double, ownerID: Int,
                          ionization: Double = 0, piercing: Bool = false, weaponID: Int = -1) {
        // Difficulty: scale only the damage the *player* takes (Easy softens,
        // Hard sharpens); NPC-vs-NPC combat is untouched.
        var shield = shield, armor = armor
        if ship.isPlayer, combatTuning.playerDamageScale != 1.0 {
            shield *= combatTuning.playerDamageScale
            armor  *= combatTuning.playerDamageScale
        }
        // Co-op sparring (`pvpDamageReal` off): a player-vs-player hit still lands
        // (flash, cloak drop below) but deals no health damage.
        if !pvpDamageReal, ship.isPlayerControlled,
           let ownerShip = self.ship(id: ownerID), ownerShip.isPlayerControlled {
            shield = 0; armor = 0
        }
        let hadShield = ship.shield > 0
        // Per-hit logging isn't gated like everything else in this file (no
        // "log on change/transition" here — every hit is its own event), and
        // splash damage can call this several times in the same instant for a
        // clustered group. Destroy/disable transitions already get their own
        // log lines below/at despawn, so a routine chip-damage hit doesn't
        // need one too — this was real, uncapped log volume that scaled
        // directly with how many ships were fighting.
        _ = ship.applyDamage(shield: shield, armor: armor, piercing: piercing)
        // Co-op no-death (`deathReal` off): a player-controlled ship can't be
        // destroyed — floor its armor so it survives however hard it's hit.
        if !playerDeathReal, ship.isPlayerControlled, ship.armor < 1 { ship.armor = 1 }
        // Cloak flag 0x0008: taking damage forces the cloak off.
        if ship.cloakEngaged, ship.cloakDropsOnDamage { ship.cloakEngaged = false }
        if ionization > 0, ship.ionizeMax > 0 {
            ship.ionCharge = min(ship.ionizeMax, ship.ionCharge + ionization)
        }
        events.append(hadShield ? .shieldHit(at: ship.position, weaponID: weaponID)
                                 : .armorHit(at: ship.position, weaponID: weaponID))

        // Player fire provokes the victim into fighting back. Per the Bible
        // (Appendix II §2.1), `ShootPenalty` is "currently ignored" in the
        // real game — shooting alone never dents legal record; only the
        // disable/kill/board/smuggling outcomes below do (`recordDisable`/
        // `recordKill`, `Diplomacy.swift`).
        if ownerID == 0 && !ship.isPlayer {
            ship.brain?.provokedByPlayer = true
        }
        // NPC fire on player: let the player's would-be attacker be remembered.
        if !ship.isPlayer, ship.brain?.targetID == nil, ownerID != 0 {
            // (no-op hook for future player-side AI/escorts)
        }

        // EV Nova disables a ship the moment its armor crosses a fixed threshold
        // (`shïp.Flags` 0x0010 → 10%, otherwise 33% of max armor) — a one-time
        // deterministic state transition, not a random roll. Once already
        // disabled, further damage that zeroes armor is a real kill (handled by
        // `isAlive`/`despawnDepartedAndDead`, not here). No **player-controlled**
        // ship is disabled this way (the local player's death is the app's; a
        // co-op remote player dies or is floored by `deathReal`, never a hulk).
        if !ship.isPlayerControlled, !ship.disabled, ship.armor <= ship.maxArmor * ship.disableArmorFraction {
            ship.disabled = true
            ship.armor = max(1, ship.maxArmor * 0.02)   // a sliver — still "alive"
            ship.shield = 0
            ship.disableSpin = rng.double(in: -0.5...0.5)
            ship.wantsToDepart = false
            ship.currentTargetID = nil
            ship.brain?.targetID = nil
            clearTarget(ship.entityID)               // everyone stops shooting it
            stopAllBeamLoops(for: ship)               // a hulk doesn't fire — stop its beam loop
            events.append(.shipDisabled(entityID: ship.entityID, at: ship.position))
            // A mission "disable this ship" objective is met the instant it's
            // crippled (a later kill doesn't un-meet it). Board/rescue objectives
            // also need the ship disabled first, so report those here too and let
            // the story layer decide what the disable means for each.
            if let mid = ship.missionID, let goal = ship.missionShipGoal,
               goal == .disable || goal == .board || goal == .rescue {
                events.append(.missionShipGoalReached(missionID: mid, entityID: ship.entityID,
                                                       goal: goal, byPlayer: ownerID == 0))
            }
            Log.combat.debug("\(ship.name) [\(ship.entityID)] disabled (armor at/below \(Int(ship.disableArmorFraction * 100))% threshold) — now a drifting hulk")
            if ownerID == 0, let dip = diplomacy {
                dip.recordDisable(of: ship.government)
            }
            // A named person the player just crippled holds a grudge from now on.
            if ownerID == 0, let pid = ship.personID {
                playerPersGrudges.insert(pid)
                events.append(.personGrudge(personID: pid))
            }
        } else if ownerID == 0 && !ship.isPlayer && !ship.isAlive {
            // Zeroed an already-disabled hulk's sliver of armor — a real kill,
            // finalized by `despawnDepartedAndDead` once per frame. Remember
            // it was the player's doing so that pass can credit `recordKill`.
            ship.killedByPlayer = true
        }
    }

    // MARK: Despawn

    private func despawnDepartedAndDead() {
        var survivors: [Ship] = []
        for npc in npcs {
            if !npc.isAlive {
                if npc.killedByPlayer, let dip = diplomacy {
                    dip.recordKill(of: npc.government, shipStrength: Int(npc.combatStrength))
                }
                // A named person the player destroyed won't appear again.
                if npc.killedByPlayer, let pid = npc.personID {
                    events.append(.personDefeated(personID: pid))
                }
                events.append(.explosion(at: npc.position, radius: max(24, npc.radius * 1.5),
                                         soundID: npc.explosionSoundID, boomID: npc.explosionBoomID))
                events.append(.shipDestroyed(entityID: npc.entityID, shipTypeID: npc.shipTypeID,
                                             at: npc.position))
                // A destroyed mission ship meets a "destroy" (or "chase off",
                // which a kill satisfies) objective. `disable`/`board`/`rescue`
                // already fired when it was crippled; don't double-report those.
                if let mid = npc.missionID, let goal = npc.missionShipGoal,
                   goal == .destroy || goal == .chaseOff {
                    events.append(.missionShipGoalReached(missionID: mid, entityID: npc.entityID,
                                                          goal: goal, byPlayer: npc.killedByPlayer))
                }
                // An escort/rescue ship the player was supposed to keep alive just
                // died → a loss, so the story layer can fail the mission.
                if let mid = npc.missionID, let goal = npc.missionShipGoal,
                   goal == .escort || goal == .rescue {
                    events.append(.missionShipLost(missionID: mid, goal: goal))
                }
                Log.combat.debug("\(npc.name) [\(npc.entityID)] destroyed (shipTypeID=\(npc.shipTypeID))")
                // Clear any targeting of the dead ship.
                clearTarget(npc.entityID)
                stopAllBeamLoops(for: npc)
                continue
            }
            // Landed on a stellar object → vanished into the spaceport (no wreck).
            if npc.wantsToLand, let sid = npc.landingSpob {
                events.append(.shipLanded(entityID: npc.entityID, spobID: sid, at: npc.position))
                clearTarget(npc.entityID)
                stopAllBeamLoops(for: npc)
                continue
            }
            // Departed past the system edge → gone to hyperspace. A ship that
            // rolled in favor of a hypergate departure (`AIBrain.pickDepartureGate`)
            // instead transits there, so the gate visibly opens for it too.
            if npc.wantsToDepart {
                if let gateID = npc.brain?.departViaGateID,
                   let gate = systemContext.bodies.first(where: { $0.id == gateID }) {
                    let d = (npc.position - gate.position).length
                    if d <= gate.radius + 40 {
                        events.append(.shipDepartedViaGate(entityID: npc.entityID, gateSpobID: gateID,
                                                           at: npc.position))
                        clearTarget(npc.entityID)
                        stopAllBeamLoops(for: npc)
                        continue
                    }
                } else {
                    let d = (npc.position - systemContext.center).length
                    if d >= systemContext.jumpRadius {
                        events.append(.shipDeparted(entityID: npc.entityID, at: npc.position,
                                                    heading: npc.angle))
                        clearTarget(npc.entityID)
                        stopAllBeamLoops(for: npc)
                        continue
                    }
                }
            }
            // A cold hulk that's drifted long enough is quietly retired.
            if npc.disabled && npc.disabledClock > 25 {
                clearTarget(npc.entityID)
                stopAllBeamLoops(for: npc)
                continue
            }
            survivors.append(npc)
        }
        npcs = survivors
        refreshRoster()
        // Player death is left to the app (respawn / game-over UI).
    }

    private func clearTarget(_ id: Int) {
        if player.currentTargetID == id { player.currentTargetID = nil }
        for s in npcs where s.currentTargetID == id {
            s.currentTargetID = nil
            s.brain?.targetID = nil
        }
    }

    // MARK: Player target-lock

    /// Range (px) within which the player can lock a target — matches the
    /// default positional-audio falloff range, a reasonable "nearby" radius.
    public static let targetLockRange: Double = 3000

    /// Lock the nearest eligible ship within range (`hostileOnly` narrows to
    /// ships `diplomacy` considers hostile to the player). Reuses
    /// `player.currentTargetID`, so locking a target also makes the player's
    /// guided weapons track it. Returns the newly-locked ship, if any.
    @discardableResult
    public func selectNearestTarget(hostileOnly: Bool) -> Ship? {
        let candidates = npcs.filter { npc in
            npc.isAlive && !npc.disabled && canDetect(npc, by: player)
                && (!hostileOnly || diplomacy?.isHostileToPlayer(npc.government) == true)
        }
        guard let nearest = candidates.min(by: {
            ($0.position - player.position).length < ($1.position - player.position).length
        }), (nearest.position - player.position).length <= Self.targetLockRange else {
            return nil
        }
        player.currentTargetID = nearest.entityID
        events.append(.targetAcquired(entityID: nearest.entityID))
        return nearest
    }

    /// Drop the player's current target lock, if any.
    public func clearPlayerTarget() {
        player.currentTargetID = nil
    }

    // MARK: Player escorts

    /// Ships currently under the player's command (captured or hired), i.e. AI
    /// ships whose fleet leader is the player.
    public var playerEscorts: [Ship] {
        npcs.filter { $0.isAlive && $0.brain?.leaderID == Self.playerEntityID }
    }

    /// Issue a standing order to the whole escort wing.
    public func setPlayerEscortOrder(_ order: EscortOrder) {
        for e in playerEscorts { e.brain?.escortOrder = order }
    }

    /// The current wing order (the most common one among escorts), or nil when
    /// the player has none — for the command window's selected state.
    public var playerEscortOrder: EscortOrder? {
        let orders = playerEscorts.compactMap { $0.brain?.escortOrder }
        guard let first = orders.first else { return nil }
        return orders.allSatisfy { $0 == first } ? first : nil
    }

    // MARK: Cloaking & sensors (oütf ModType 17/24/30; sÿst Interference)

    /// `pêrs` ids the player has wronged — those characters attack on sight
    /// wherever they appear (`pêrs.Flags 0x0001` grudge). Synced from the pilot
    /// by the host; read by the AI's hostility test.
    public var playerPersGrudges: Set<Int> = []
    /// Host gate for whether a `pêrs` may appear now — evaluates its `ActiveOn`
    /// NCB test and "not already defeated" against live pilot state (the engine
    /// can't evaluate NCB itself). Default: always eligible.
    public var persSpawnEligible: (Int) -> Bool = { _ in true }

    /// Host gate for whether a fleet with a non-blank `flët.AppearOn` may spawn
    /// now (the `Spawner` only calls this for fleets that *have* an `AppearOn`
    /// control-bit test — a blank one is always eligible). The engine can't
    /// evaluate NCB itself, so it defers to the host, which evaluates the fleet's
    /// `AppearOn` expression against live pilot control bits. Default: **not**
    /// eligible — a fresh game with no story layer wired must not spawn
    /// story/late-campaign fleets (rebels, war task forces) that gate on bits
    /// no one has set yet. When `NovaSwiftStory` is wired in, it replaces this
    /// with a real evaluator. Mirrors `persSpawnEligible` but with the opposite
    /// default, because a gated fleet appearing early is a visible spoiler while
    /// a gated `pêrs` merely appearing is harmless.
    public var fleetSpawnEligible: (Int) -> Bool = { _ in false }

    /// Host gate for whether a ship class with a non-blank `shïp.AppearOn` may be
    /// spawned by a düde now (Bible: "Ships of this type will not show up in dude
    /// resources if this expression evaluates to false"). The `Spawner` only calls
    /// this for hulls that *have* an `AppearOn` test; the engine can't evaluate
    /// NCB, so it defers to the host. Default: eligible — unlike a whole gated
    /// fleet, one gated hull in a düde's ship mix is a minor spoiler, and a false
    /// default would thin out düde spawns before the story layer wires a real
    /// evaluator (which replaces this with an `AppearOn`-against-pilot-bits check).
    public var shipSpawnEligible: (Int) -> Bool = { _ in true }

    /// The current system's sensor static (`sÿst.Interference`, 0-100). Set when
    /// the world is built for a system; degrades effective sensor range.
    public var systemInterference: Int = 0
    /// The current system's visual murk (`sÿst.Murk`, 0-100; <0 also hides the
    /// starfield). Set when the world is built for a system; the app draws a
    /// fog whose depth tracks `effectiveMurk(for:)`. No gameplay effect.
    public var systemMurk: Int = 0

    /// `base` sensor range reduced by the effective interference `observer`
    /// experiences: `base × (1 − netInterference/100)`, where net interference
    /// is the system's static minus the observer's anti-interference outfits.
    /// At 100 net interference the range is zero (complete sensor blackout, per
    /// the Bible's 0-100 endpoints; the linear curve between them is this
    /// engine's reading of "how thick the static is").
    public func effectiveSensorRange(_ base: Double, for observer: Ship) -> Double {
        let net = max(0, min(100, systemInterference - observer.interferenceReduction))
        return base * (1 - Double(net) / 100)
    }

    /// `systemMurk` net of `observer`'s ModType-28 murk outfits, capped at the
    /// documented 100 max. Not clamped below 0: per the Bible, a negative
    /// value is "equivalent to zero murk but also hides the starfield" — a
    /// distinct visual state from 0, not just an extra-clear one.
    public func effectiveMurk(for observer: Ship) -> Int {
        min(100, systemMurk - observer.murkModifier)
    }

    /// Whether `observer` can detect (and therefore target) `target`, accounting
    /// for cloaking. A cloaked target is hidden unless the observer carries a
    /// cloak scanner able to target cloaked ships (ModType 30 bit 0x0008).
    /// Non-cloaked targets pass here; range/interference gating is separate.
    public func canDetect(_ target: Ship, by observer: Ship) -> Bool {
        guard target.isEffectivelyCloaked else { return true }
        return observer.cloakScannerFlags & 0x0008 != 0
    }

    /// A ship's formation key: an escort's is its leader's entity id; a leader
    /// (or any lone ship) is its own key. Two ships sharing a key fly together
    /// — the grouping `cloakIsArea` (0x1000) shares a cloak across.
    private func formationKey(_ s: Ship) -> Int { s.brain?.leaderID ?? s.entityID }

    /// Fade cloaks in/out and drain their fuel/shield upkeep. A cloak forced off
    /// (out of fuel/shields) simply disengages and fades back to visible.
    private func stepCloak(_ dt: Double) {
        let baseFade = 1.0 / 1.2                    // full fade in ~1.2s
        for s in allShips where s.hasCloak {
            let rate = baseFade * (s.cloakFlags & 0x0001 != 0 ? 2 : 1)   // 0x0001 = faster fading
            if s.cloakEngaged {
                if s.cloakLevel == 0, s.cloakDropsShields { s.shield = 0 }   // 0x0004
                s.cloakLevel = min(1, s.cloakLevel + rate * dt)
                if s.cloakFuelPerSec > 0 { s.fuel = max(0, s.fuel - s.cloakFuelPerSec * dt) }
                if s.cloakShieldPerSec > 0 { s.shield = max(0, s.shield - s.cloakShieldPerSec * dt) }
                if (s.cloakFuelPerSec > 0 && s.fuel <= 0) || (s.cloakShieldPerSec > 0 && s.shield <= 0) {
                    s.cloakEngaged = false                                   // can't power it — drop cloak
                }
            } else if s.cloakLevel > 0 {
                s.cloakLevel = max(0, s.cloakLevel - rate * dt)
            }
        }

        // Area cloak (0x1000): ships flying with an area-cloaking ship share
        // its cloak level for detection/rendering, without needing a cloak of
        // their own — recomputed fresh each step from the current formations.
        var groupCloak: [Int: Double] = [:]
        for s in allShips where s.hasCloak && s.cloakIsArea && s.cloakLevel > 0 {
            let key = formationKey(s)
            groupCloak[key] = max(groupCloak[key] ?? 0, s.cloakLevel)
        }
        for s in allShips {
            s.areaCloakLevel = groupCloak[formationKey(s)] ?? 0
        }
    }

    /// Toggle the player's cloaking device (no-op if the player has no cloak).
    public func togglePlayerCloak() {
        guard player.hasCloak else { return }
        player.cloakEngaged.toggle()
    }

    // MARK: Fighter bays (wëap Guidance 99)

    /// Whether `carrier` is currently engaged (has a live hostile target) — the
    /// condition under which EV Nova carriers auto-deploy their fighters.
    private func carrierInCombat(_ carrier: Ship) -> Bool {
        guard let tid = carrier.currentTargetID, let t = ship(id: tid) else { return false }
        return t.isAlive && !t.disabled
    }

    /// Per-frame fighter-bay processing: carriers in combat launch fighters up to
    /// each bay's capacity (throttled by the bay's launch interval); deployed
    /// fighters that run out of ammo, get badly hurt, or whose carrier has left
    /// combat return and dock (restoring the bay); a carrier's death orphans its
    /// still-flying fighters (they become independent ships of the same govt).
    private func updateFighterBays(_ dt: Double) {
        guard galaxy != nil else { return }   // fighters are spawned via the galaxy

        // Launch pass over a snapshot (launching appends to `npcs`).
        for carrier in allShips where !carrier.fighterBays.isEmpty && carrier.isAlive && !carrier.disabled {
            let inCombat = carrierInCombat(carrier)
            for bay in carrier.fighterBays {
                bay.launchCooldown = max(0, bay.launchCooldown - dt)
                // Drop dead/orphaned fighters from the roster.
                bay.deployed = bay.deployed.filter { ship(id: $0)?.carrierID == carrier.entityID }
                if inCombat, bay.docked > 0, bay.launchCooldown <= 0,
                   let fighter = launchFighter(from: carrier, bay: bay) {
                    bay.docked -= 1
                    bay.deployed.insert(fighter.entityID)
                    bay.launchCooldown = Double(bay.spec.launchIntervalFrames) / 30.0
                }
            }
        }

        // Recall & dock pass — collect removals, apply after iterating.
        var docked: Set<Int> = []
        for f in npcs where f.carrierID != nil && f.isAlive {
            guard let carrier = ship(id: f.carrierID!), carrier.isAlive, !carrier.disabled else {
                // Carrier gone: the fighter is orphaned — it keeps fighting for
                // its government but has no bay to return to.
                f.carrierID = nil; f.recallToCarrier = false; f.brain?.leaderID = nil
                continue
            }
            if !f.recallToCarrier {
                let outOfAmmo = !f.weapons.isEmpty && f.weapons.allSatisfy { $0.ammo == 0 }
                if outOfAmmo || f.healthFraction < 0.3 || !carrierInCombat(carrier) {
                    f.recallToCarrier = true
                }
            }
            if f.recallToCarrier,
               (f.position - carrier.position).length <= carrier.radius + f.radius + 30 {
                if let bay = carrier.fighterBays.first(where: { $0.deployed.contains(f.entityID) }) {
                    bay.deployed.remove(f.entityID)
                    bay.docked = min(bay.spec.capacity, bay.docked + 1)
                }
                docked.insert(f.entityID)
            }
        }
        if !docked.isEmpty {
            for id in docked { clearTarget(id) }
            npcs.removeAll { docked.contains($0.entityID) }
        }
    }

    /// Launch one fighter from `carrier`'s `bay`: a real sub-ship of the bay's
    /// fighter class, allied to the carrier and ordered to hunt its enemies.
    private func launchFighter(from carrier: Ship, bay: Ship.FighterBay) -> Ship? {
        guard let galaxy else { return nil }
        let pos = carrier.position + Vec2.heading(carrier.angle) * (carrier.radius + 20)
        guard let fighter = galaxy.makeLoadedShip(bay.spec.fighterShipID, government: carrier.government,
                                                  at: pos, angle: carrier.angle) else { return nil }
        let brain = fighter.brain ?? AIBrain(aiType: .interceptor, govt: carrier.government)
        fighter.brain = brain
        brain.leaderID = carrier.entityID
        brain.escortOrder = .aggressive
        // Distinct slots so a bay's fighters fan out into their own formation
        // positions behind the carrier instead of converging on the same spot.
        brain.formationSlot = allShips.filter { $0.brain?.leaderID == carrier.entityID }.count
        brain.provokedByPlayer = carrier.isPlayer ? false : (carrier.brain?.provokedByPlayer ?? false)
        fighter.carrierID = carrier.entityID
        fighter.velocity = carrier.velocity
        _ = addNPC(fighter, arrival: .launch)
        return fighter
    }

    /// Player command: launch every docked fighter from the player's own bays
    /// right now, bypassing the ambient auto-launch's combat gate/cooldown —
    /// an explicit "scramble" isn't throttled the way passive combat launches are.
    public func playerLaunchFighters() {
        for bay in player.fighterBays {
            while bay.docked > 0, let fighter = launchFighter(from: player, bay: bay) {
                bay.docked -= 1
                bay.deployed.insert(fighter.entityID)
            }
        }
    }

    /// Player command: recall every fighter currently flying from the
    /// player's own bays — they head back and dock regardless of whether the
    /// player is still in combat (the ambient auto-recall only docks once
    /// combat ends).
    public func playerRecallFighters() {
        for f in npcs where f.carrierID == World.playerEntityID {
            f.recallToCarrier = true
        }
    }

    // MARK: Boarding / plunder

    /// What a disabled ship yields when boarded — its name, credits aboard, the
    /// cargo in its hold, and the odds of capturing it (nil = uncapturable).
    public struct BoardingManifest {
        public let shipID: Int
        public let name: String
        public let credits: Int
        public let cargo: [(commodity: Int, tons: Int)]
        public let captureChance: Int?   // percent, nil = can't be captured
        /// Outfit ids this hulk grants as `përs` ItemClass loot (empty for an
        /// ordinary ship, or a person whose grant roll came up empty).
        public var grantedOutfits: [Int] = []
    }

    /// The plunder a disabled ship offers, or nil if `shipID` isn't a boardable
    /// (alive + disabled) hulk. Deterministic per ship so re-opening the dialog
    /// shows the same haul.
    public func boardingManifest(for shipID: Int) -> BoardingManifest? {
        guard let s = ship(id: shipID), s !== player, s.isAlive, s.disabled else { return nil }
        let cargo = s.cargo.filter { $0.value > 0 }
            .map { (commodity: $0.key, tons: $0.value) }
            .sorted { $0.commodity < $1.commodity }
        return BoardingManifest(shipID: shipID, name: personName(s) ?? s.name,
                                credits: rolledPlunderCredits(s), cargo: cargo,
                                captureChance: captureChance(of: s),
                                grantedOutfits: rolledPlunderOutfits(s))
    }

    /// The `përs` character name for a ship, if it's a named person.
    private func personName(_ s: Ship) -> String? {
        guard let pid = s.personID else { return nil }
        return galaxy?.game.pers(pid)?.name
    }

    /// The `përs` ItemClass boarding loot for `s`, rolled once (deterministically
    /// from its identity) and cached. Empty for an ordinary ship.
    private func rolledPlunderOutfits(_ s: Ship) -> [Int] {
        if s.plunderOutfits == nil {
            guard let pid = s.personID, let pers = galaxy?.game.pers(pid) else { s.plunderOutfits = []; return [] }
            let seed = UInt64(bitPattern: Int64(s.entityID &* 2_654_435_761)) ^ UInt64(bitPattern: Int64(pid &+ 1))
            s.plunderOutfits = galaxy?.game.personBoardingGrant(pers, seed: seed == 0 ? 1 : seed) ?? []
        }
        return s.plunderOutfits ?? []
    }

    /// Take the `përs` outfit loot from a boarded hulk (clearing it so it can't be
    /// taken twice). The host adds these outfit ids to the pilot.
    public func takePlunderOutfits(from shipID: Int) -> [Int] {
        guard let s = ship(id: shipID) else { return [] }
        let loot = rolledPlunderOutfits(s)
        s.plunderOutfits = []
        return loot
    }

    /// Total effective crew the player brings to a boarding action — the sum EV
    /// Nova's capture math puts on the attacker's side: the player ship's own
    /// `Crew`, its marines outfits' bonus crew, and the `Crew` of every escort
    /// under the player's command.
    public var playerBoardingCrew: Int {
        player.crew + player.marineCrew + playerEscorts.reduce(0) { $0 + $1.crew }
    }

    /// Capture odds (percent) for the player taking disabled hulk `target`, or
    /// nil if it can't be captured. EV Nova's documented formula:
    ///   odds = (attackerCrew / (targetCrew × 10)) × 100
    ///        + the player's marines odds bonus (negative-ModVal ModType-25)
    ///        + 10 if the player's Strength exceeds 5× the target's Strength
    /// clamped to 1…75%. The defender's ×10 crew advantage is why capture is hard
    /// without marines or escorts. The ±5% random jitter is applied at the moment
    /// of the attempt (`attemptCapture`), not here, so a *displayed* chance is
    /// stable while the roll still varies.
    public func captureChance(of target: Ship) -> Int? {
        guard target.crew > 0 else { return nil }   // nothing to overpower
        let ratio = Double(playerBoardingCrew) / Double(target.crew * 10) * 100
        var odds = Int(ratio.rounded()) + player.captureOddsBonus
        if player.combatStrength > target.combatStrength * 5 { odds += 10 }
        return min(75, max(1, odds))
    }

    /// Board disabled hulk `shipID`: emit `.shipBoarded` and return its plunder
    /// manifest (credits/cargo/capture odds). The canonical "player docks with
    /// the hulk" entry point — the host then calls `takePlunderCredits` /
    /// `takePlunderCargo` / `attemptCapture` off the returned manifest. Returns
    /// nil (emitting nothing) if the ship isn't a boardable hulk.
    @discardableResult
    public func board(shipID: Int) -> BoardingManifest? {
        guard let manifest = boardingManifest(for: shipID), let s = ship(id: shipID) else { return nil }
        events.append(.shipBoarded(entityID: s.entityID, at: s.position))
        // A `rescue` mission ship starts pre-disabled and is completed by
        // *boarding* it (tow/rescue the derelict) — not by the disable transition
        // that fires the other goals (it never gets an `applyHit` disable, so that
        // path never ran for it). Report the goal met now. (`board` goals already
        // fired on disable, so they're intentionally not re-reported here.)
        if let mid = s.missionID, s.missionShipGoal == .rescue {
            events.append(.missionShipGoalReached(missionID: mid, entityID: s.entityID,
                                                  goal: .rescue, byPlayer: true))
        }
        return manifest
    }

    /// Credits aboard a hulk, rolled once (deterministically from its identity +
    /// toughness) and cached on the ship.
    private func rolledPlunderCredits(_ s: Ship) -> Int {
        if s.plunderCredits < 0 {
            var h = UInt64(bitPattern: Int64(s.entityID &+ 1)) &* 0x9E3779B97F4A7C15
            h ^= UInt64(bitPattern: Int64(s.shipTypeID &+ 7)) &* 0xD1B54A32D192ED03
            let value = max(40, Int((s.maxArmor + s.maxShield) / 2))
            s.plunderCredits = value / 2 + Int(h % UInt64(max(1, value)))
        }
        return s.plunderCredits
    }

    /// Take the credits aboard a hulk (zeroing them so they can't be re-taken).
    public func takePlunderCredits(from shipID: Int) -> Int {
        guard let s = ship(id: shipID) else { return 0 }
        let c = rolledPlunderCredits(s)
        s.plunderCredits = 0
        return c
    }

    /// Move a hulk's cargo into the player's hold, limited by free space, and
    /// return what was actually taken (commodity id → tons).
    @discardableResult
    public func takePlunderCargo(from shipID: Int) -> [(commodity: Int, tons: Int)] {
        guard let s = ship(id: shipID) else { return [] }
        var taken: [(commodity: Int, tons: Int)] = []
        for (commodity, tons) in s.cargo.sorted(by: { $0.key < $1.key }) where tons > 0 {
            let room = player.cargoFree
            guard room > 0 else { break }
            let move = min(tons, room)
            player.cargo[commodity, default: 0] += move
            s.cargo[commodity]! -= move
            if s.cargo[commodity]! <= 0 { s.cargo[commodity] = nil }
            taken.append((commodity, move))
        }
        return taken
    }

    /// Attempt to capture a hulk given a 0–99 `roll` (supplied by the caller so
    /// the outcome is reproducible for a given roll). The base chance is jittered
    /// by ±5% (world RNG, per the Bible) before the roll is compared. On success
    /// the ship joins the player's escort wing and a `.shipCaptured` event fires.
    public func attemptCapture(shipID: Int, roll: Int) -> Bool {
        guard let s = ship(id: shipID), s !== player, s.isAlive, s.disabled,
              let chance = captureChance(of: s) else { return false }
        let effective = min(75, max(1, chance + rng.int(in: -5...5)))
        guard roll < effective else { return false }
        recruitEscort(s)
        events.append(.shipCaptured(entityID: s.entityID, shipTypeID: s.shipTypeID, at: s.position))
        return true
    }

    /// Recruit `ship` as a player escort — ally it to the player, clear any
    /// hostility, and place it in the formation under a defensive order. Assigns
    /// the next free formation slot and gives it a brain if it somehow lacked one.
    public func recruitEscort(_ ship: Ship) {
        let brain = ship.brain ?? AIBrain(aiType: .warship, govt: player.government)
        ship.brain = brain
        ship.government = player.government
        brain.leaderID = Self.playerEntityID
        brain.escortOrder = .defensive
        brain.provokedByPlayer = false
        brain.formationSlot = playerEscorts.filter { $0.entityID != ship.entityID }.count
        ship.disabled = false
        ship.currentTargetID = nil
    }

    /// Lock a specific ship by id (click-to-select). Unlike
    /// `selectNearestTarget`, this allows disabled hulks (still valid targets
    /// for boarding) and has no range gate — if it's on screen, it's
    /// selectable.
    @discardableResult
    public func selectTarget(id: Int) -> Ship? {
        guard let ship = npcs.first(where: { $0.entityID == id }), ship.isAlive else { return nil }
        player.currentTargetID = id
        events.append(.targetAcquired(entityID: id))
        return ship
    }

    /// Apply a paid "Request Assistance" ally's delivery once it docks with
    /// the player: one jump's worth of fuel, and armor topped up to a safe
    /// floor if it's currently lower (never reduced if already healthier).
    public func deliverAssistance(from shipID: Int) {
        player.fuel = min(player.maxFuel, player.fuel + ShipFuel.perJump)
        let safeArmor = player.maxArmor * 0.4
        if player.armor < safeArmor { player.armor = safeArmor }
        events.append(.assistanceDelivered(entityID: shipID))
    }
}

// MARK: - Small vector angle helpers used across the AI/combat code

extension Vec2 {
    /// Compass heading (0 = north/up, clockwise) of this vector.
    public var angle: Double { atan2(x, y) }
    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
}

/// Shortest signed turn (radians) from heading `a` to heading `b`, in −π…π.
public func angleDelta(from a: Double, to b: Double) -> Double {
    let twoPi = 2 * Double.pi
    var d = (b - a).truncatingRemainder(dividingBy: twoPi)
    if d > .pi { d -= twoPi }
    if d < -.pi { d += twoPi }
    return d
}
