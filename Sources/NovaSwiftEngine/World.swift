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
    /// The self-destruct command is held (Alt-−, UI-15): the player tick arms
    /// and runs the countdown while it stays down. Ignored for NPCs.
    public var selfDestruct = false
    /// Absolute heading (radians, compass) to rotate toward — used by mouse,
    /// analog-stick aiming, and the AI. When set, it drives turning unless a
    /// discrete turnLeft/turnRight is also active (discrete input wins).
    public var desiredHeading: Double?
    /// The exact mounts an NPC's trigger serves this frame, when its AI chose
    /// them (the original AI's control modes asking the AI-02 selectors for a
    /// particular kind of bank). nil leaves the choice to
    /// `World.npcSelectedMounts`. Ignored for the player.
    public var npcMounts: Set<Int>?
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
            r.selfDestruct = r.selfDestruct || s.selfDestruct
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
/// The original flies an NPC inertialess only when its hull has Flags2 0x0040
/// (`Ship_HandleShip` 0x00433050), which is `.off`. The wider scopes are the
/// port's own formation model, kept behind the `formationFlying` enhancement.
public enum AIInertialessScope: Sendable {
    /// Only hulls/outfits with the real `shïp` Flags2 0x0040 flag (or an
    /// inertial-dampener outfit) fly driftless. The original.
    case off
    /// Ships flying in formation — fleet members and escorts (anything with a
    /// leader, plus the fleet flagship) — also fly driftless. Kills the
    /// micro-correction wobble of a wing holding station.
    case formations
    /// Every AI-brained ship flies driftless.
    case all
}

/// Tuning that maps EV Nova's integer stat units into simulation units, plus
/// the switches that select the port's own flight behaviours. Kept in one place
/// so flight feel can be adjusted without touching data decoding.
public struct FlightTuning {
    public var speedScale: Double      // stat → max px/sec
    public var accelScale: Double      // stat → px/sec²
    public var turnScale: Double       // stat → deg/sec
    public var dragPerSecond: Double   // gentle space drag so ships settle (0 = pure Newtonian)
    /// How broadly AI ships fly the driftless model beyond their own hull flag.
    /// `.off` in the original; `.formations` under the `formationFlying`
    /// enhancement.
    public var aiInertialess: AIInertialessScope = .off

    /// The original's loader and runtime scales (0x004bd3c0, 0x004640a0,
    /// 0x004642e0): top speed `Speed/100` px/tick, thrust `Accel/10000 × 2.0`
    /// px/tick², turn `Maneuver × 0.1` deg/tick. At 30 ticks/s that is 0.30 ×
    /// Speed px/s, 0.18 × Accel px/s² and 3 × Maneuver deg/s.
    public static let original = FlightTuning(speedScale: 0.30, accelScale: 0.18,
                                              turnScale: 3.0, dragPerSecond: 0.0)

    public static let `default` = original

    public init(speedScale: Double, accelScale: Double, turnScale: Double, dragPerSecond: Double) {
        self.speedScale = speedScale
        self.accelScale = accelScale
        self.turnScale = turnScale
        self.dragPerSecond = dragPerSecond
    }

    /// The flight model a set of enhancement toggles selects.
    public init(enhancements e: GameplayEnhancements) {
        self = .original
        aiInertialess = e.formationFlying ? .formations : .off
    }
}

/// Derived, simulation-ready flight parameters for a ship.
public struct ShipStats {
    public let maxSpeed: Double        // px/sec
    public let acceleration: Double    // px/sec²
    public let turnRate: Double        // rad/sec
    public let rotationFrames: Int     // sprite frames for a full 360°
    /// The player's turn step in whole degrees per tick: `trunc` of
    /// `Maneuver × 0.1 + Σ ModType-9 count × ModVal × 0.01`, floored to 1 for a
    /// hull with any Maneuver (0x00463e70, then the truncating conversion at
    /// 0x0044c8d7). NPCs turn at the unrounded `turnRate`.
    public let playerTurnDegPerTick: Int

    public init(maxSpeed: Double, acceleration: Double, turnRate: Double, rotationFrames: Int = 36) {
        self.maxSpeed = maxSpeed
        self.acceleration = acceleration
        self.turnRate = turnRate
        self.rotationFrames = rotationFrames
        let degPerTick = turnRate * 180 / .pi / OriginalClock.ticksPerSecond
        self.playerTurnDegPerTick = degPerTick > 0 ? max(1, Int((degPerTick + 1e-9).rounded(.down))) : 0
    }

    /// Build from decoded ship stat integers (speed / accel / Maneuver).
    /// `turnBonus` is the summed ModType-9 `count × ModVal`, in hundredths of a
    /// degree per tick (ten to one Maneuver point).
    public init(speed: Int, acceleration: Int, turnRate: Int, turnBonus: Int = 0,
                rotationFrames: Int = 36, tuning: FlightTuning = .default) {
        self.maxSpeed = Double(speed) * tuning.speedScale
        self.acceleration = Double(acceleration) * tuning.accelScale
        // Turn in hundredths of a degree per tick keeps the truncation exact.
        // A rate below 1°/tick is floored to 1 when the hull's own rate is at
        // least 1 (Maneuver ≥ 10); the player's truncated step floors for any
        // positive Maneuver.
        let hundredths = turnRate * 10 + turnBonus
        let unrounded = turnRate >= 10 && hundredths < 100 ? 100 : max(0, hundredths)
        self.turnRate = Double(unrounded) / 10 * tuning.turnScale * .pi / 180.0
        self.rotationFrames = rotationFrames
        self.playerTurnDegPerTick = turnRate > 0 ? max(1, hundredths / 100) : max(0, hundredths / 100)
    }

    /// The same stats with top speed and thrust scaled (skill variance).
    func scaled(speedAndThrust k: Double) -> ShipStats {
        ShipStats(maxSpeed: maxSpeed * k, acceleration: acceleration * k, turnRate: turnRate,
                  rotationFrames: rotationFrames, playerTurnDegPerTick: playerTurnDegPerTick)
    }

    private init(maxSpeed: Double, acceleration: Double, turnRate: Double,
                 rotationFrames: Int, playerTurnDegPerTick: Int) {
        self.maxSpeed = maxSpeed
        self.acceleration = acceleration
        self.turnRate = turnRate
        self.rotationFrames = rotationFrames
        self.playerTurnDegPerTick = playerTurnDegPerTick
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

    /// Render-interpolation snapshot: this ship's `position`/`angle` as of the end
    /// of the *previous* fixed sim tick. The renderer draws the ship at
    /// `lerp(renderPrevPosition, position, alpha)` where `alpha` is how far the
    /// current display frame sits into the next tick — so with a fixed 30 Hz sim,
    /// a 60/120 Hz display shows smooth, gliding motion instead of 30 Hz steps.
    /// Seeded to the spawn pose so a brand-new ship never lerps in from the origin.
    /// Purely presentational; the simulation never reads these.
    public var renderPrevPosition: Vec2
    public var renderPrevAngle: Double

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
    /// of them at once). nil = none selected (`+0x72 == −1`, B-1): the trigger
    /// fires nothing until the player cycles to one. Ignored for AI ships,
    /// which fire every group their brain triggers.
    public var selectedSecondaryID: Int?

    /// Distinct secondary weapons fitted, in mount order — the cycle the player's
    /// weapon-switch control steps through. Point-defense mounts fire themselves,
    /// so they aren't selectable.
    public var secondaryWeaponIDs: [Int] {
        weapons.filter {
            // WP-27: a bank with wëap Flags 0x0002 and guidance below 9 or 99
            // (a bay), in bank (weapon id) order — never point defense.
            let g = $0.spec.guidance
            guard $0.spec.isSecondary, g.rawValue < 9 || g == .bay else { return false }
            // `wëap.Flags2` 0x0800: "Don't allow this weapon to be selected or
            // displayed if it is out of ammo" — the cycle skips a bank that
            // can't fire (`Weapon_CanFireWeaponBank`, 0x0044bf50).
            if $0.spec.hiddenWhenOutOfAmmo, !canFireBank($0) { return false }
            return true
        }.map { $0.spec.id }
    }

    /// The secondary id the secondary trigger fires: the player's selection,
    /// or none.
    public var effectiveSecondaryID: Int? { selectedSecondaryID }

    /// The mount for the effective secondary (drives the HUD weapon readout).
    public var effectiveSecondaryMount: WeaponMount? {
        guard let id = effectiveSecondaryID else { return nil }
        return weapons.first { $0.spec.id == id && $0.spec.isSecondary }
    }

    /// Clear the secondary selection (the original's "S"; the key is UI-15).
    public func clearSecondary() { selectedSecondaryID = nil }

    /// Step the selected secondary (0x0044bf50): from the current bank (or
    /// from "none", so forward lands on the first and backward on the last),
    /// to the next eligible one in weapon-id order, wrapping. Nothing happens
    /// with no eligible secondary.
    public func cycleSecondary(forward: Bool) {
        let ids = secondaryWeaponIDs
        guard !ids.isEmpty else { return }
        guard let current = selectedSecondaryID else {
            selectedSecondaryID = forward ? ids.first : ids.last
            return
        }
        if forward {
            selectedSecondaryID = ids.first { $0 > current } ?? ids.first
        } else {
            selectedSecondaryID = ids.last { $0 < current } ?? ids.last
        }
    }

    /// The player's per-tick auto-clear (0x0044b120): a selected bank with
    /// wëap Flags 0x0800 that can't fire drops the selection.
    func autoClearSecondary() {
        guard let id = selectedSecondaryID,
              let mount = weapons.first(where: { $0.spec.id == id }) else { return }
        if mount.spec.flags.persistentSmoke, !canFireBank(mount) { selectedSecondaryID = nil }
    }

    /// `Weapon_CanFireWeaponBank` (0x00468990), without the reload: an NPC
    /// never fires a Flags2 0x0100 weapon; a cloaked ship only a Flags2 0x4000
    /// one; a Flags2 0x0080 weapon needs a key-carried ship aboard; a bay
    /// needs a docked fighter; an ammo weapon (AmmoType 0–255) a round — the
    /// player's from the shared pool, an NPC's from its own bank; a fuel
    /// weapon (AmmoType ≤ −1000) `(|AmmoType| − 1000) × 0.1` fuel.
    public func canFireBank(_ mount: WeaponMount) -> Bool {
        let spec = mount.spec
        if !isPlayerControlled && spec.aiWontUse { return false }
        if isCloaked && !spec.firesWhileCloaked { return false }
        if spec.requiresKeyCarriedAboard && !carriesKeyShip { return false }
        if spec.guidance == .bay {
            return (fighterBays.first { $0.spec.bayWeaponID == spec.id }?.docked ?? mount.ammo) >= 1
        }
        let t = spec.ammoTypeRaw
        if (0...255).contains(t) { return mount.ammo != 0 }
        if t <= -1000 { return fuel >= Double(abs(t) - 1000) * 0.1 }
        return true
    }

    /// World-space muzzle for exit point `index` of `exitType`, given the ship's
    /// live position/heading — the real hardpoint the shot leaves from.
    public func muzzle(exitType: WeaponExitType, index: Int) -> Vec2 {
        let nose = radius + 4
        guard let ep = exitPoints else {
            return position + Vec2.heading(angle) * nose
        }
        // ExitType −1 leaves from the hull centre; the offsets rotate with the
        // sprite frame's whole-degree heading, not the continuous one (B-12).
        if exitType == .center { return position }
        let frames = max(1, stats.rotationFrames)
        let frameDeg = Double((spriteFrame % frames) * 360 / frames)
        return position + ep.muzzleOffset(type: exitType, index: index, angle: frameDeg * .pi / 180, nose: nose)
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
    /// Fraction of max armor below which this ship is disabled: 33.333 %, or
    /// 10 % with `shïp.Flags` 0x0010 (`Ship_IsShipDisabled` 0x004687b0 tests
    /// `armor × 100 < maxArmor × 33.333`). See `disabled`.
    public var disableArmorFraction: Double = Ship.standardDisableFraction
    /// `armor × 100 < maxArmor × 33.333` (0x00575808), and 10.0 (0x005757f8)
    /// with hull Flags 0x0010.
    public static let standardDisableFraction = 0.33333
    public static let lowDisableFraction = 0.10
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
    /// Ion charge shed per second: `shïp.Deionize` per 1/30 s tick (a hull
    /// whose Deionize is 0 sheds a full 1.0 per tick — see `ShipRes.deionizePerTick`).
    public var deionizePerSec: Double = 0
    /// Fully ionized: the charge has reached the capacity. Only Seeker 0x0020
    /// weapons care (they won't fire).
    public var isIonized: Bool { ionizeMax > 0 && ionCharge >= ionizeMax }
    /// `Ship_GetIonizationIntensity` (0x0046c160) capped at 0.7: how much of
    /// its thrust (and its turn while coasting) and top speed the charge
    /// takes away.
    public var ionIntensity: Double {
        guard ionizeMax > 0, ionCharge > 0 else { return 0 }
        return min(0.7, ionCharge / ionizeMax)
    }
    /// The tint the hull glows while ionized, set from the `IonizeColor` of
    /// whatever last landed ion charge on it (Bible: "the color that a ship hit
    /// by this weapon will appear after being sufficiently ionized"). Nil → the
    /// renderer's default bluish glow. Reset to nil once the charge dissipates.
    public var ionizeColor: (r: Double, g: Double, b: Double)?
    /// Per-type jamming strength from fitted jammer outfits (`oütf` ModTypes
    /// 33-36) — four values, one per jammer type. Stacks with the pilot
    /// government's inherent `InhJam1-4`, and is weighed against each incoming
    /// seeker's own `wëap.JamVuln1-4` rather than applied as a blanket ECM
    /// rating. Always four entries.
    public var jamming: [Int] = [0, 0, 0, 0]
    /// Overrides the hull name on the target display — `mïsn.ShipName` for a
    /// mission's special ships ("the *Kestrel*" rather than "Fed Destroyer").
    /// Nil for ordinary traffic. `name` itself is `let` (it identifies the hull
    /// in logs), so the display override lives separately.
    public var displayName: String?
    /// A second line shown under this ship's name on the target display —
    /// `mïsn.ShipSubtitle` for a mission's special ships. Nil for ordinary
    /// traffic, which shows only its hull/government line.
    public var displaySubtitle: String?
    /// The hull's raw `shïp.TurnRate` integer, kept alongside the converted
    /// `stats.turnRate` because two Bible rules are written in raw units — the
    /// "don't fire at ships with turn rate > 3" weapon flag being the one the
    /// sim reads. 0 for a synthetic ship with no backing resource.
    public var rawTurnRate: Int = 0
    /// The hull's `shïp.KeyCarried` ship type (`< 128` = none) and whether one is
    /// currently aboard. Bible: a `wëap.Flags2` 0x0080 weapon only fires while a
    /// key-carried ship is still docked, and the `shän` `keyCarried` extra sprite
    /// set shows when none are.
    public var keyCarriedShipID: Int = -1
    /// `Weapon_HasLoadedLaunchBayAmmo` (0x00464670): the hull declares a
    /// key-carried type and a bay still has one docked. False without a
    /// KeyCarried, so a Flags2 0x0080 weapon on such a hull never fires (B-9).
    public var carriesKeyShip: Bool {
        guard keyCarriedShipID >= 128 else { return false }
        return fighterBays.contains { $0.spec.fighterShipID == keyCarriedShipID && $0.docked > 0 }
    }
    /// This ship's total jam strength per type: its own fitted jammers plus its
    /// government's inherent `InhJam1-4`, each clamped to 0...100.
    public func combinedJamming(govtJamming: [Int]?) -> [Int] {
        (0..<4).map { i in
            let g = (govtJamming?.count ?? 0) > i ? govtJamming![i] : 0
            let s = jamming.count > i ? jamming[i] : 0
            return max(0, min(100, g + s))
        }
    }
    /// Whether this ship auto-collects an asteroid's yield when it destroys the
    /// rock (`oütf` ModType 31 mining scoop, or `shïp.Flags3` 0x0002). Only the
    /// player's collection is surfaced (as a `.asteroidMined` event to the host).
    public var hasMiningScoop: Bool = false
    /// `oütf` ModType 49 (repair system): "will occasionally repair the ship
    /// when it's disabled" — not player-restricted, so an NPC hull stocked
    /// with one benefits too. See `World`'s disabled-hulk tick.
    public var hasRepairSystem: Bool = false
    /// `Ship_CheckSpecialLoadoutCapability` (0x0046d080) for a jump: shïp
    /// Flags2 0x0020 or a ModType-37 fast-jump outfit (the hull's DefaultItems
    /// count for an NPC, OS-01). The jump skips its brake.
    public var instantJump: Bool = false
    /// `oütf` ModType 13 (density scanner): reveals a targeted ship's cargo
    /// hold contents in the targeting readout. Bible ModVal is "ignored" —
    /// ownership alone is what matters.
    public var hasDensityScanner: Bool = false
    /// `oütf` ModType 44 (reinforcement inhibitor), player-only per the Bible:
    /// the `gövt.Class1-4` values this ship's fitted inhibitors block from
    /// calling reinforcements while it's in-system (`-1` = every government).
    /// Only ever non-empty on `World.player` — copied generically from
    /// `Loadout` like any other fitted-outfit effect, but nothing sets it for
    /// NPCs since they're never built with a player-outfit inhibitor.
    public var reinforcementInhibitorClasses: Set<Int> = []
    /// `oütf` ModType 48 (IFF scrambler), player-only per the Bible: the
    /// `gövt.Class1-4` values fooled into treating this ship as friendly
    /// (`-1` = every government). See `reinforcementInhibitorClasses`.
    public var iffScramblerClasses: Set<Int> = []
    /// `oütf` ModType 43 (paint), player-only per the Bible: a custom hull
    /// tint (0...1 RGB) from a fitted paint outfit. Nil = fly the hull's
    /// stock/government tint instead.
    public var paintColor: (r: Double, g: Double, b: Double)?
    /// `shïp.Flags3` 0x0020: the hull ignores stellar gravity *and* survives
    /// deadly stellars (0x0046e120 / 0x0046e210 both read this one bit).
    public var hullShieldsStellars: Bool = false
    /// A fitted `oütf` ModType 41 (gravityResist). Only the player's counts.
    public var hasGravityResistOutfit: Bool = false
    /// A fitted `oütf` ModType 42 (stellarResist). Only the player's counts.
    public var hasStellarResistOutfit: Bool = false

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
    /// The `Booty` flags of the düde this ship spawned from (0 for any other
    /// ship): the boarding cargo roll reads them (EC-18).
    public var dudeBooty: Int = 0
    /// The boarding cargo and fuel rolls (`Boarding_BuildOptions` 0x00484230),
    /// made once when first boarded; nil = not rolled yet.
    public var plunderCargoRoll: (commodity: Int, tons: Int)??
    public var plunderFuelRoll: Int?
    /// The hulk bank (wëap id) a boarding offers ammunition from, rolled once (B-11).
    var plunderAmmoBankID: Int?

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
    /// 0 = fully visible, 1 = fully cloaked: the original's fade progress
    /// 0…32 over 32 (OS-04).
    public var cloakLevel: Double = 0
    /// "Cloaked" — can't fire, can't be targeted, off radar
    /// (`Ship_IsShipCloakVisibilityThresholdActive` 0x0046c7a0): past 24/32
    /// while fading in, until under 8/32 while fading out, past 16/32 at rest.
    public var isCloaked: Bool { Ship.cloakHides(level: cloakLevel, engaged: cloakEngaged) }
    static func cloakHides(level: Double, engaged: Bool) -> Bool {
        let progress = level * 32
        if engaged && level < 1 { return progress > 24 }
        if !engaged && level > 0 { return progress >= 8 }
        return progress > 16
    }
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
    /// Hidden by either its own cloak or a formation-mate's area cloak — the
    /// target-selection/radar/rendering-facing check.
    public var isEffectivelyCloaked: Bool { isCloaked || areaCloakLevel * 32 > 16 }
    /// Anti-interference (oütf ModType 24): subtracted from the system's sensor
    /// static when computing this ship's effective sensor range.
    public var interferenceReduction: Int = 0
    /// Murk modifier (oütf ModType 28): added to/subtracted from the system's
    /// `sÿst.Murk` visual fog when computing this ship's effective murk.
    public var murkModifier: Int = 0
    /// An owned ModType-11 escape pod: the player may eject (Alt+X) while
    /// disabled or during the death sequence (OS-02).
    public var hasEscapePod: Bool = false
    /// An owned ModType-20 auto-eject: a destroyed player with a pod ejects
    /// on their own once half the death sequence has run.
    public var hasAutoEject: Bool = false
    /// Set on a launched fighter: the entity id of the carrier it flew from, so
    /// it can dock back and be freed if the carrier dies. nil = not a fighter.
    public var carrierID: Int?
    /// `përs` id when this ship is a named character (5% spawn chance). Drives the
    /// target-display name and the ItemClass boarding-loot grant. nil = ordinary.
    public var personID: Int?
    /// The `përs` Flags of `personID` (0 for an ordinary ship). 0x0001: a hit
    /// from the player makes it hold a grudge (AI-07).
    public var personFlags = 0
    /// The `düde` this ship was spawned from (ship +0x78), nil for fleet,
    /// përs and fighter ships. The comm window's greeting reads its
    /// InfoTypes (AI-43).
    public var dudeID: Int?

    /// Set when this ship was spawned *by a mission* (`mïsn` special/aux ship),
    /// tagged with the mission's resource id. Lets the world report goal progress
    /// (destroyed/disabled/…) back to the story layer and lets a mission clear
    /// its own ships when it ends (e.g. escorts that leave at a plot point). nil
    /// for all ambient `düde`/`flët` traffic.
    public var missionID: Int?
    /// This mission ship's objective from the player's side (`mïsn.ShipGoal`):
    /// what the player must *do* to it (destroy/disable/board/escort/…). Read by
    /// the world when the ship is destroyed/disabled/boarded to fire the matching
    /// `missionShipGoalReached` event. nil = not a mission ship, or no goal.
    public var missionShipGoal: MissionShipGoal?
    /// Whether this ship has already reported its board/rescue objective. Keep
    /// the goal itself intact (rescue ships use it during boarding cleanup),
    /// while reopening plunder cannot count the same ship a second time.
    /// The host can also observe this transition when boarding outside a tick.
    public fileprivate(set) var missionBoardingGoalReported = false
    /// A mission's auxiliary ship (`AuxShipDude`, owner +0x8a), not one of its
    /// special ships. Survivors go back to the mission's aux budget when the
    /// player leaves the system (0x0041ad50).
    public var missionAuxiliary = false

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
    /// The original AI's in-place departure (a jump spin-up or a gate entry)
    /// finished: the world removes the ship wherever it is.
    public var departsInPlace = false
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

    /// A drifting hulk: no thrust, no weapons, no regeneration. Derived every
    /// time it is read, as `Ship_IsShipDisabled` (0x004687b0) is: armor below
    /// `disableArmorFraction` of max, so repairing above the line (or
    /// regenerating, for a hull that does) brings a ship back. A dead ship
    /// (armor ≤ 0) also reads disabled. Two arms hold a ship disabled whatever
    /// its armor: a government with Flags 0x0800 (derelicts) and an un-boarded
    /// rescue-mission ship; `heldDisabled` carries both, and setting
    /// `disabled` writes it. A stellar's defense ship is never disabled by
    /// armor — it fights until destroyed.
    public var disabled: Bool {
        get {
            if heldDisabled { return true }
            if !isPlayer, spobDefenderOf != nil { return false }
            return armor < maxArmor * disableArmorFraction
        }
        set { heldDisabled = newValue }
    }
    /// See `disabled`: the derelict-government / rescue-ship arms (and a test seam).
    public var heldDisabled = false
    /// Debris puffs this hull still has to shed (shïp PodCount); nil until the
    /// first one is due (0x00433050, ship+0xc908).
    var debrisPodsLeft: Int?
    /// The player's post-disable window (`DAT_0073549c`): set to 300 ticks when
    /// the player is disabled, it counts down one tick per tick and holds off
    /// the repair system until it runs out (OS-07).
    public var recentlyHitTicks: Double = -1

    /// True if the player dealt the hit that dropped this ship to 0 armor —
    /// read once by `despawnDepartedAndDead` to attribute `Diplomacy.recordKill`
    /// to the player specifically (an NPC-vs-NPC kill shouldn't touch the
    /// player's legal record).
    public var killedByPlayer = false
    /// True if the killing hit counts as the player's for the legal record and
    /// combat rating (`World.isCreditedToPlayer`): the player or a direct
    /// escort, against anything but a defense ship or a derelict.
    public var killCredited = false
    /// `shïp.Mass` in tons: knockback divides by it, and hulls of 100 t or
    /// more blast on death (WP-13). 0 = a synthetic ship with no backing hull.
    public var massTons: Double = 0
    /// `shïp.Flags` 0x0400, a planet-type ship: only planet-type weapons
    /// (`wëap` Flags2 0x0400) hit it, and weapon impact never pushes it.
    public var isPlanetTypeShip = false
    /// The turret tracking rating of the hull's class (WP-26): 80 fighter,
    /// 90 medium ship, 100 warship or freighter (`shïp.EscortType`, else
    /// inferred). 100 for a synthetic ship.
    public var turretRating = 100
    /// The government whose `InhJam1-4` the hull carries (`shïp.InherentGovt`).
    public var inherentJamGovt = -1
    /// The hull's inherent *combat* government (`shïp.InherentGovt`), −1 for
    /// none. On the player's hull it drives the 1-in-50 "you fly their enemy's
    /// ship" hostility roll and the stellar batteries' grudge (AI-05).
    public var inherentCombatGovt = -1
    /// shïp 895 (class index 0x2ff): the escape pod, which no shot can hit.
    public static let escapePodShipID = 895

    /// Non-nil once this NPC's armor has hit 0: counts up the seconds spent
    /// playing out its wreck-explosion sequence before `despawnDepartedAndDead`
    /// actually removes it from `npcs`. Lets a dying NPC linger on screen the
    /// same way the player's own death sequence lingers before its wreck is
    /// hidden, instead of vanishing the instant its armor reaches 0.
    public var deathTimer: Double? = nil
    /// B-6: the dying-carrier escape roll has been made and the banks cleared.
    var dyingBaysCleared = false

    /// How long this hull's death sequence runs (`Ship_UpdateVisualState`
    /// 0x00428340): the timer starts at `DeathDelay` (× 3 for the player) and
    /// counts down one per raw call to the finale at 2. A hull with no data
    /// (a synthetic ship) uses the port's earlier 1.8 s.
    var deathSequenceDuration: Double {
        guard deathDelayTicks > 0 else { return 1.8 }
        let start = deathDelayTicks * (isPlayer ? 3 : 1)
        return max(0, start - 2) * OriginalClock.rawCallSeconds
    }

    /// Debug/cheat only: when set, `applyDamage` is a no-op — shields and armor
    /// never drop and the ship can't be destroyed or disabled by weapon fire.
    /// The debug suite drives this on the player ship for "god mode"; nothing in
    /// normal gameplay ever sets it, so it's inert unless a developer flips it.
    public var invulnerable = false

    /// Top-speed multiplier the world applies this step: 1.5 for the player and
    /// the player's direct escorts when the pilot is not on Strict Play
    /// (`Ship_ComputeShipEffectiveMaxSpeed` 0x004642e0), otherwise 1.
    public internal(set) var topSpeedFactor: Double = 1
    /// The ship this NPC is velocity-matched to, if any. A matched NPC flies at
    /// a third of its top speed and turn rate, and its thrust takes ×0.333
    /// instead of the usual ×2.0 (0x004640a0 / 0x004642e0 / 0x00463e70). Set
    /// by the AI that matches velocities.
    public var velocityMatchTargetID: Int?
    /// Ticks left before a beam lock (`velocityMatchTargetID` set by a tractor
    /// beam hit, +0xc8dc) lapses; refreshed on every hit (0x0042f270).
    var beamLockTicksLeft: Double = 0
    /// True while the system holds any stellar with gravity; it stops the
    /// player's afterburner widening the speed caps (0x0043adb0).
    var inGravityPull = false
    /// The player's per-axis speed caps (px/s), maintained by the afterburner.
    var speedCapX: Double = 0
    var speedCapY: Double = 0

    private var velocityMatched: Bool {
        guard let id = velocityMatchTargetID else { return false }
        return id != entityID && !isPlayerControlled
    }
    /// Top speed with the strict-play and velocity-match multipliers, px/s.
    public var effectiveMaxSpeed: Double {
        stats.maxSpeed * (velocityMatched ? 0.333 : 1) * topSpeedFactor
    }
    /// Thrust with the velocity-match multiplier, px/s². `stats.acceleration`
    /// already carries the usual ×2.0, which a matched ship swaps for ×0.333.
    public var effectiveAcceleration: Double {
        velocityMatched ? stats.acceleration * (0.333 / 2.0) : stats.acceleration
    }
    /// NPC turn rate with the velocity-match multiplier, rad/s.
    var effectiveTurnRate: Double { stats.turnRate * (velocityMatched ? 0.333 : 1) }
    /// The player's whole-degree turn step per tick.
    var playerTurnStep: Int { stats.playerTurnDegPerTick }

    /// EV Nova's inertialess flight (`shïp` Flags2 0x0040, or the inertial-dampener
    /// outfit ModType 38): the ship has no momentum — its velocity tracks the nose
    /// with no lateral drift. Set at build time from the hull/outfits.
    public var inertialess = false
    /// This NPC has a leader and its AI sits in velocity-match / station-hold
    /// (control mode 0x0C): `Outfit_ShipIsInertialess` (0x0046df70) then says
    /// no, so it flies Newtonian and feels gravity (D-2). Set each step by the
    /// world after the AI decides.
    var velocityMatchLed = false
    /// The inertialess answer the flight, gravity and AI-state code see.
    var isInertialessNow: Bool { inertialess && !velocityMatchLed }
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
        return maxTotal > 0 ? (max(0, shield) + max(0, armor)) / maxTotal : 0
    }
    /// Armor and shields can go below zero (a killing blow, a broken shield's
    /// −10 % floor); the fractions read 0 there.
    public var armorFraction: Double { maxArmor > 0 ? max(0, armor) / maxArmor : 0 }
    public var shieldFraction: Double { maxShield > 0 ? max(0, shield) / maxShield : 0 }

    public init(name: String, stats: ShipStats, position: Vec2 = Vec2(), angle: Double = 0) {
        self.name = name
        self.stats = stats
        self.position = position
        self.velocity = Vec2()
        self.angle = angle
        self.lastFinitePosition = position
        self.renderPrevPosition = position
        self.renderPrevAngle = angle
    }

    /// Behavior 5, a carried fighter (AI-41, OQ B3/B7): × 1.333 maximum
    /// shield and armor, float-rounded as the original stores them, and × 1.333
    /// shield regeneration (not armor). This pool is the whole of the
    /// community's "fighters take 75 % damage".
    func applyCarriedFighterScale(keepingLevels: Bool = false) {
        guard preFighterScale == nil else { return }
        preFighterScale = (maxShield, maxArmor, shieldRechargePerSec)
        maxShield = Double(Float(maxShield * 1.333))
        maxArmor = Double(Float(maxArmor * 1.333))
        shieldRechargePerSec *= 1.333
        if !keepingLevels { shield = maxShield; armor = maxArmor }
    }

    /// Leaving behavior 5 (a disabled fighter dropping out of the wing) takes
    /// the × 1.333 back off: the original computes the pools from the live
    /// behavior every time (0x00463550 / 0x004637a0). Current levels stay,
    /// clamped to the smaller pools.
    func removeCarriedFighterScale() {
        guard let pre = preFighterScale else { return }
        preFighterScale = nil
        maxShield = pre.maxShield; maxArmor = pre.maxArmor; shieldRechargePerSec = pre.shieldRegen
        shield = min(shield, maxShield); armor = min(armor, maxArmor)
    }

    /// The pools before the carried-fighter × 1.333, while it applies.
    var preFighterScale: (maxShield: Double, maxArmor: Double, shieldRegen: Double)?

    /// A ship that was in the player's wing and dropped out when it was
    /// disabled (`+0xc8de`, AI-38): it still remembers whether it flew as a
    /// bay fighter or an escort, so a repair system or the player boarding it
    /// brings it back. nil for every other ship.
    public enum FormerWingRole: Sendable { case fighter, escort }
    public var formerWingRole: FormerWingRole?

    /// A përs with a negative `ShieldMod`: its shield and armor are refilled
    /// to full every call (`Ship_HandleShip` 0x00433050), so only a single
    /// hit bigger than both can stop it.
    public var refillsDefensesEveryTick = false

    /// Per-exit-type firing quadrant cursors (WP-25), started at random.
    var exitQuadrants: [WeaponExitType: Int] = [:]

    /// Set when a deadly stellar destroyed this ship: it's gone at once, with
    /// no death sequence (WP-25).
    var diesInstantly = false
    /// The hull the player ejected from (OS-02). If it was already dying, the
    /// host's player death sequence plays its explosions.
    public var wreckOfPlayer = false

    /// The hull fields the combat model reads straight off `shïp`.
    func applyHullTraits(_ res: ShipRes) {
        massTons = Double(max(0, res.mass))
        isPlanetTypeShip = res.flags & 0x0400 != 0
        turretRating = [80, 90, 100, 100][max(0, min(3, res.escortClass))]
        inherentJamGovt = res.inherentAttributesGovt
        inherentCombatGovt = res.inherentCombatGovt
        hullFlags = Int(res.flags)
        hullFlags2 = Int(res.flags2)
        deathDelayTicks = Double(max(0, res.deathDelay))
    }

    /// Raw `shïp.Flags` / `Flags2`, for the rules that read single bits
    /// (turret blind arcs, untargetable hulls, cloak fade rate …).
    public var hullFlags = 0
    public var hullFlags2 = 0
    /// `shïp.DeathDelay` in ticks: how long the death sequence runs (× 3 for
    /// the player) before the hull is gone (WP-13).
    public var deathDelayTicks: Double = 0

    /// The sprite frame index (0..<rotationFrames) for the current heading:
    /// `trunc(heading° × frames / 360)`, as the original picks it.
    public var spriteFrame: Int {
        SpriteFrames.headingFrame(angle: angle, frames: stats.rotationFrames)
    }

    // MARK: Combat helpers

    /// One hit's damage, as `Ship_ApplyDamageToShip` (0x004192d0) applies it:
    /// energy comes off the shields; once the shields are at or below zero
    /// (this hit's energy included) the mass damage comes off the armor, and
    /// the shields bottom out at −10 % of their maximum, so a broken shield
    /// has to regenerate past zero before it absorbs again. A shield-piercing
    /// weapon (`wëap` Flags 0x0020) applies its mass damage alone, never
    /// touching the shields. A non-lethal hit (`wëap` Flags2 0x1000, or an AI
    /// in its disable-only state) that would take positive armor to zero or
    /// below leaves exactly 1. Armor simply subtracts, so one hit can take a
    /// healthy ship straight past the disable line to destroyed. Returns true
    /// if the hit destroyed the ship.
    @discardableResult
    public func applyDamage(shield dmgShield: Double, armor dmgArmor: Double,
                            piercing: Bool = false, nonLethal: Bool = false) -> Bool {
        // God mode (debug suite): swallow every hit whole.
        if invulnerable { return false }
        func hitArmor() {
            guard dmgArmor > 0 else { return }
            if nonLethal, armor > 0, armor - dmgArmor <= 0 {
                armor = 1
            } else {
                armor -= dmgArmor
            }
        }
        if piercing {
            hitArmor()
        } else {
            if dmgShield > 0 { shield -= dmgShield }
            if shield <= 0 {
                hitArmor()
                shield = max(shield, -maxShield * 0.1)
            }
        }
        return armor <= 0
    }

    func regen(_ dt: Double) {
        // A dead ship (armor at 0, wreck lingering out its death sequence)
        // never regens anything — a nonzero `armorRechargePerSec` ship would
        // otherwise be able to heal itself back above 0 and un-die mid-sequence.
        guard armor > 0 else { return }
        if shield < maxShield { shield = min(maxShield, shield + shieldRechargePerSec * dt) }
        if armor < maxArmor && armorRechargePerSec > 0 {
            armor = min(maxArmor, armor + armorRechargePerSec * dt)
        }
        if !isPlayer { regenFuel(dt) }
        logFuelTransitions()
    }

    /// Fuel regeneration (FL-07). A negative rate ("fuel sucking") drains.
    /// The player's runs even while disabled — the original has no gate there.
    func regenFuel(_ dt: Double) {
        guard fuelRegenPerSec != 0, armor > 0 else { return }
        if fuelRegenPerSec > 0, fuel < maxFuel {
            fuel = min(maxFuel, fuel + fuelRegenPerSec * dt)
        } else if fuelRegenPerSec < 0, fuel > 0 {
            fuel = max(0, fuel + fuelRegenPerSec * dt)
        }
    }

    /// Bleed off ionization. Unlike `regen`, this is not a system the ship has to
    /// power — it's an externally applied charge dissipating on its own — so it
    /// runs even for a disabled hulk, whose glow would otherwise stay frozen
    /// (and pulsing) at full strength forever.
    /// The charge also drags the ship toward `(1 − I) ×` its top speed,
    /// 0.025 px/tick per tick on each axis (`Ship_HandleShip` 0x00433050 /
    /// the player's 0x0045073f).
    func deionize(_ dt: Double) {
        guard ionCharge > 0 else { return }
        ionCharge = max(0, ionCharge - deionizePerSec * dt)
        if ionCharge == 0 { ionizeColor = nil; return }   // glow fades with the charge
        let cap = (1 - ionIntensity) * effectiveMaxSpeed
        let step = OriginalClock.perSecond(0.025) * dt * OriginalClock.ticksPerSecond
        var v = velocity
        if v.x > cap { v.x -= step }
        if v.x < -cap { v.x += step }
        if v.y > cap { v.y -= step }
        if v.y < -cap { v.y += step }
        velocity = v
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
        if isInertialessNow { return true }
        guard let brain = brain else { return false }
        switch tuning.aiInertialess {
        case .off:        return false
        case .formations:
            // A ship actively fighting flies Newtonian so it can brake, kite and
            // reverse-and-fire (see `attack()`); the driftless glue is only for
            // *holding formation*. So a fleet flagship or an escort that peels off to
            // engage wrestles momentum like any lone combatant, and reverts to the
            // glued formation model only once it falls back into station.
            if brain.state == .attacking { return false }
            return brain.leaderID != nil || brain.isFleetMember
        case .all:        return true
        }
    }

    /// Flight for one fixed step. The player (and a co-op player) flies the
    /// original's player tick (`Ship_HandlePlayerShipCore` 0x0044aa70): a
    /// truncated whole-degree turn, the reverse key's turn-to-retrograde, the
    /// afterburner and its decaying per-axis speed caps. Every other ship flies
    /// `Ship_HandleShip` (0x00433050): an unrounded turn that snaps onto its
    /// desired heading, and thrust clamped per axis to its top speed.
    ///
    /// `rawCalls` is how many of the original's 21 ms loop calls this step
    /// spans (`RawCallCadence`); the afterburner push and the cap decay run
    /// once per call, unscaled, as they do in the original.
    func step(_ dt: Double, intent: ControlIntent, tuning: FlightTuning, rawCalls: Int = 1) {
        // Ionization never takes the controls away; it weakens them (WP-11):
        // thrust × (1 − I), and turning × (1 − I) while not thrusting, where
        // I = min(0.7, charge / capacity). The speed damping is `deionize`'s.
        let controllable = true
        let ion = ionIntensity
        let ionTurn = ion > 0 && !intent.thrust ? 1 - ion : 1

        let manual = isPlayerControlled
        let ticks = dt * OriginalClock.ticksPerSecond
        let accel = effectiveAcceleration * (1 - ion)
        let topSpeed = effectiveMaxSpeed

        // MARK: Turn
        let continuousTurn = effectiveTurnRate * dt * ionTurn
        // The player turns a whole number of degrees per tick (`trunc` of the
        // turn rate, 0x0044c8d7), so Maneuver 25 turns like 20.
        let quantized = manual
        let playerStep = ionTurn < 1
            ? Double(Int((stats.turnRate * 180 / .pi / OriginalClock.ticksPerSecond * ionTurn + 1e-9).rounded(.down)))
            : Double(playerTurnStep)
        let turnStep = quantized ? playerStep * ticks * .pi / 180 : continuousTurn
        // Reverse (0x0044fff0): a non-inertialess ship turns to face the
        // reverse of its velocity, once either axis moves at ≥ 0.05 px/tick.
        // It overrides the turn keys and face-target; below the threshold the
        // other heading inputs keep driving the turn.
        var autoHeading = intent.desiredHeading
        var turnKeysLive = true
        if manual, controllable, intent.reverse, !isInertialessNow {
            let gate = OriginalClock.perSecond(0.05)
            if abs(velocity.x) >= gate || abs(velocity.y) >= gate {
                autoHeading = OriginalMath.bearingRadians(of: velocity) + .pi
                turnKeysLive = false
            }
        }
        if controllable, turnKeysLive, intent.turnLeft || intent.turnRight {
            if intent.turnLeft { angle -= turnStep }
            if intent.turnRight { angle += turnStep }
        } else if controllable, let target = autoHeading {
            let delta = angleDelta(from: angle, to: target)
            if quantized {
                // The player's auto-turn steps a whole turn step and stops,
                // without snapping, once within one step of the heading.
                if abs(delta) > turnStep { angle += delta > 0 ? turnStep : -turnStep }
            } else {
                angle += max(-turnStep, min(turnStep, delta))
            }
        }

        // MARK: Afterburner
        // The player's afterburner (ModType 15) engages while held with fuel
        // for at least one tick's burn. NPCs never burn: the burn rate is 0
        // for every ship but the player (`Ship_GetShipFuelBurnRate` 0x0046e060).
        afterburnerActive = false
        if controllable, manual, intent.afterburner, let ab = afterburner, fuel > 0,
           ab.fuelPerSecond / OriginalClock.ticksPerSecond <= fuel {
            afterburnerActive = true
            fuel = max(0, fuel - ab.fuelPerSecond * dt)
            logFuelTransitions()
        }
        let playerBurn = afterburnerActive && manual
        let widen = playerBurn && !inGravityPull

        // Hyperspace-entry over-speed: allow briefly exceeding cruise, decaying to
        // zero, so a jump-in eases down to cruise rather than snapping.
        let overspeeding = entryOverspeed > 0
        if overspeeding {
            entryOverspeed = max(0, entryOverspeed - entryOverspeedDecayPerSec * dt)
        }
        let cruise = topSpeed + entryOverspeed

        // MARK: Speed caps (player)
        // While burning outside a gravity pull both per-axis caps sit at 1.8 ×
        // top speed (0x00575610); after release each decays by thrust × 0.4 per
        // raw call (0x00575680) back down to top speed.
        if manual {
            if widen {
                speedCapX = cruise * 1.8
                speedCapY = cruise * 1.8
            } else {
                let decay = OriginalClock.perSecond(OriginalClock.perTickSquared(accel) * 0.4) * Double(rawCalls)
                if speedCapX > cruise { speedCapX -= decay }
                if speedCapY > cruise { speedCapY -= decay }
            }
            speedCapX = max(speedCapX, cruise)
            speedCapY = max(speedCapY, cruise)
        }

        let dirDeg = wholeDegreeHeading
        if isInertialessNow {
            // MARK: Inertialess hull (shïp Flags2 0x0040 / ModType 38)
            // Thrust and reverse move a scalar speed that has no idle decay;
            // the velocity then steers toward heading × speed by at most
            // 4 × thrust per tick on each axis (0x0043b020).
            if controllable {
                if intent.thrust { throttleSpeed = min(throttleSpeed + accel * dt, cruise) }
                if intent.reverse { throttleSpeed = max(0, throttleSpeed - accel * dt) }
            }
            if playerBurn {
                let push = OriginalClock.perSecond(OriginalClock.perTickSquared(accel) * 2.75)
                throttleSpeed = min(throttleSpeed + push * Double(rawCalls), topSpeed * 1.8)
            }
            throttleSpeed = min(throttleSpeed, manual ? speedCapX : cruise)
            let target = Vec2.heading(dirDeg) * throttleSpeed
            let maxDv = 4 * accel * dt
            velocity = Vec2(velocity.x + max(-maxDv, min(maxDv, target.x - velocity.x)),
                            velocity.y + max(-maxDv, min(maxDv, target.y - velocity.y)))
        } else if fliesInertialess(tuning) {
            // MARK: Formation driftless (formationFlying enhancement)
            // The port's own model: a throttle that bleeds off when idle, and a
            // velocity whose direction follows the nose at this frame's turn budget.
            if controllable {
                if intent.thrust { throttleSpeed += accel * dt }
                else { throttleSpeed -= accel * dt }
            }
            throttleSpeed = min(max(throttleSpeed, 0), cruise)
            let heading = Vec2.heading(angle)
            let speed = velocity.length
            let velDir = speed > 1e-6 ? velocity * (1 / speed) : heading
            let toNose = angleDelta(from: velDir.angle, to: angle)
            let steered = Vec2.heading(velDir.angle + max(-continuousTurn, min(continuousTurn, toNose)))
            let dSpeed = throttleSpeed - speed
            let maxDv = accel * dt * 2
            let newSpeed = abs(dSpeed) <= maxDv ? throttleSpeed : speed + (dSpeed > 0 ? maxDv : -maxDv)
            velocity = steered * max(0, newSpeed)
        } else {
            // MARK: Newtonian
            // Thrust adds along the heading, each axis capped at its share of
            // top speed (`Math_AddPolarVelocityWithClamp` 0x0043b4e0), so a turn
            // under thrust can leave the net speed a little above top speed.
            if controllable, intent.thrust {
                addPolarVelocityWithClamp(heading: dirDeg, step: accel * dt,
                                          max: widen ? cruise * 1.8 : cruise)
            }
            if tuning.dragPerSecond > 0 {
                velocity = velocity * max(0, 1 - tuning.dragPerSecond * dt)
            }
            if manual {
                // The player's per-axis box cap (0x0044d05b), then the
                // afterburner's own push: per raw call, thrust × 2.75 on each
                // axis still inside its 1.8 × top-speed share, else × 0.99.
                velocity = Vec2(max(-speedCapX, min(speedCapX, velocity.x)),
                                max(-speedCapY, min(speedCapY, velocity.y)))
                if playerBurn {
                    let dir = Vec2.heading(dirDeg)
                    let push = dir * OriginalClock.perSecond(OriginalClock.perTickSquared(accel) * 2.75)
                    let bound = dir * (topSpeed * 1.8)
                    func tail(_ thrust: Double, _ bound: Double, _ v: Double) -> Double {
                        (thrust > 0 && v < bound) || (thrust <= 0 && bound < v) ? v + thrust : v * 0.99
                    }
                    for _ in 0..<rawCalls {
                        velocity = Vec2(tail(push.x, bound.x, velocity.x), tail(push.y, bound.y, velocity.y))
                    }
                }
            }
            if overspeeding {
                // An arrival's decaying over-speed is a magnitude limit of the
                // port's own.
                let speed = velocity.length
                if speed > cruise, speed > 0 { velocity = velocity.normalized * cruise }
            }
        }
        position += velocity * dt
        guardFiniteMotion()
    }

    /// One axis-clamped thrust step (`Math_AddPolarVelocityWithClamp`
    /// 0x0043b4e0): each axis gains its share of `step` only while below its
    /// share of `max`; it never pulls an existing component back.
    func addPolarVelocityWithClamp(heading: Double, step: Double, max: Double) {
        let dir = Vec2.heading(heading)
        func axis(_ cap: Double, _ delta: Double, _ cur: Double) -> Double {
            if delta <= 0 || cap <= 0 {
                if delta < 0 && cap < 0 { return cap < cur ? cur + delta : cur }
                return cur + delta
            }
            return cur < cap ? cur + delta : cur
        }
        velocity = Vec2(axis(dir.x * max, dir.x * step, velocity.x),
                        axis(dir.y * max, dir.y * step, velocity.y))
    }

    /// The heading the original's polar tables see: whole degrees, truncated.
    var wholeDegreeHeading: Double {
        var deg = angle * 180 / .pi
        deg = deg.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        return (deg + 1e-9).rounded(.down) * .pi / 180   // 30° stored as 29.999… is still 30
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
    /// The player's opt-in non-original behaviours (Settings ▸ Enhancements).
    /// All off by default; systems that gate an invented behaviour read it here.
    public var enhancements = GameplayEnhancements()
    /// The pilot's Strict Play option. Off (the original's default), the player
    /// and the player's direct escorts fly at 1.5 × top speed (FL-03).
    public var strictPlay = false
    /// The player's engaged hyperspace jump (FL-04), nil in normal flight. While
    /// it runs the jump flies the player and the weapons stay cold; once it
    /// reaches `.fired` the host swaps systems, and on `.collapsed` it clears it.
    public var playerJump: PlayerHyperjump?
    /// The original's raw 21 ms calls inside this step (see `RawCallCadence`):
    /// how many times a per-call rule runs.
    public private(set) var rawCallsThisStep = 0
    private var cadence = RawCallCadence()
    /// The original's raw-call counter (`DAT_00597992`), advanced each step.
    private(set) var rawCallCounter = 0
    /// The 32 fading debris-puff slots (0x005914ac).
    public internal(set) var debrisPuffs = [DebrisPuff](repeating: DebrisPuff(), count: 32)
    /// Live beam records (`Shot_UpdateBeamHitQueue`).
    private var beamRecords: [BeamRecord] = []
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
    /// Seconds since the player died, and whether its death sequence has run
    /// out (blast fired, pilot lost) or been cut short by an eject (OS-02).
    private(set) var playerDeathElapsed: Double = 0
    private(set) var playerDeathSequenceOver = false
    var playerDeathEjected = false
    var playerDeathReportedForEject: Bool { playerDeathReported }
    /// OS-02: the eject command for this step, the pod's remaining flight
    /// (nil when not in the pod), and whether it has landed (the host's cue
    /// to respawn the pilot).
    var ejectRequested = false
    /// UI-15: the self-destruct countdown in 30 Hz ticks, −1 when disarmed
    /// (`DAT_00735498`).
    public internal(set) var selfDestructCountdown: Double = -1
    public internal(set) var escapePodTicksLeft: Double?
    public internal(set) var escapePodLanded = false

    /// Live NPC ships (does not include the player).
    public private(set) var npcs: [Ship] = []
    public private(set) var projectiles: [Projectile] = []
    /// Live beam segments the renderer mirrors each frame. Continuous beams are
    /// welded to their shooter (geometry recomputed every step); pulse beams are
    /// brief flashes. See `refreshActiveBeams`. The setter is module-internal
    /// (not file-private) so a sibling file's firing pass (e.g.
    /// `StellarWeapons.swift`) can append a pulse flash too.
    public internal(set) var activeBeams: [ActiveBeam] = []
    /// Transient render/audio events produced this step; drain after `step`.
    public private(set) var events: [WorldEvent] = []

    /// Append a world event. Exists so code in sibling files (e.g.
    /// `Domination.swift`) can emit without `events`' file-private setter.
    func emit(_ event: WorldEvent) { events.append(event) }

    /// Trigger a self-contained explosion effect (sprite + sound + screen
    /// shake) at a point — the same rendering the normal projectile/beam hit
    /// pipeline uses, exposed for app-layer code that damages a ship directly
    /// via `Ship.applyDamage` outside that pipeline (e.g. an outfit-driven
    /// hazard like a nonlethal-bomb self-destruct) and still wants the hit to
    /// read as one.
    public func emitExplosion(at position: Vec2, radius: Double, soundID: Int? = nil, boomID: Int? = nil) {
        events.append(.explosion(at: position, radius: radius, soundID: soundID, boomID: boomID))
    }

    /// Diplomacy table (governments & player standing). Optional so a bare
    /// physics world still works; when nil, nobody is hostile.
    public var diplomacy: Diplomacy?
    /// The system's stellar geometry (planets, jump radius) for AI navigation.
    public var systemContext = SystemContext() { didSet { pendingChatter = nil } }
    /// Catalog used to instantiate NPC ships & weapons. Optional for physics-only.
    public var galaxy: Galaxy?
    /// Populates and refreshes the NPC population.
    public var spawner: Spawner?
    /// The original NPC AI, which drives every brained NPC.
    public let originalAI = OriginalAI()
    /// Each animated stellar's current frame, pushed in by the renderer so the
    /// deadly-stellar pixel test uses the sprite on screen.
    public var stellarFrames: [Int: Int] = [:]
    /// `Frame_QueueCombatChatter`'s single slot (category, government, voice).
    var playerCloakWasEngaged = false
    var pendingChatter: (category: Int, govt: Int, voice: Int)?
    /// Set by the host while an escort chatter sound is still playing
    /// (`DAT_00591a8c`); a queued line waits for it.
    public var combatChatterPlaying = false

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
    /// Live Demand-Tribute contests in this system, keyed by `spöb` id. Tracks
    /// how many defenders a planet still has to launch and its wave size, so the
    /// world can relaunch waves as they're destroyed until the pool is exhausted.
    var stellarDefenses: [Int: StellarDefense] = [:]
    /// AI-14: mission batches waiting out their rearm delay.
    public internal(set) var pendingMissionArrivals: [PendingMissionArrival] = []
    /// AI-14: the bearing (world radians, `Vec2(sin, cos)`) from this
    /// system toward the one the player arrived from, nil when unknown (a
    /// ShipStart-1 batch then picks Rand(360)).
    public var previousSystemBearing: Double?
    /// AI-15: each stellar's persistent garrison (`spöb` id → ships left),
    /// seeded by the host from the pilot's save; absent = full `DefCount`.
    /// `garrisonSnapshot()` reads it back, survivors credited.
    public var stellarGarrisons: [Int: Int] = [:]
    /// Garrisons this visit set outright (domination, release).
    var touchedGarrisons: Set<Int> = []
    /// Reload state for each armed stellar's defense weapon (`spöb.Weapon`),
    /// keyed by `spöb` id and created lazily on first fire opportunity — see
    /// `updateStellarWeapons` (StellarWeapons.swift).
    var stellarWeaponMounts: [Int: WeaponMount] = [:]
    /// Live armor for each *destroyable* stellar in this system (`spöb.Strength`
    /// > 0), keyed by `spöb` id and seeded lazily on the first hit. Base-game
    /// stellars are all invulnerable, so this stays empty unless a plug-in or TC
    /// ships shootable planets — see `applyStellarHit` (StellarWeapons.swift).
    /// The host seeds it from the pilot and reads it back, since the original
    /// keeps a stellar's live Strength across visits (OS-13).
    public var stellarArmor: [Int: Double] = [:]
    /// Stellars destroyed by weapon fire *in this world*. The host drains this to
    /// fire `spöb.OnDestroy` and to schedule regeneration from `spöb.DeadTime`;
    /// it is also what keeps a downed stellar from being re-targeted before the
    /// host rebuilds the system without it.
    public internal(set) var stellarsDestroyedThisSession: Set<Int> = []

    /// Live asteroids (real `röid` rocks, from the system's `sÿst.Asteroids`/
    /// `AstTypes` fields): the drifting 16-rock field around the player.
    public private(set) var asteroids: [Asteroid] = []

    public var rng = NovaRandom(seed: 0xE70A_5EED as UInt32)
    /// `DAT_007d17ca`: `Rand(0x800)` rolled on each arrival or launch; −1
    /// once a stellar comm window has opened. Bounds which STR# 7500+ quote
    /// a ship's Greetings can pick (`Rand(roll % count + 1)`, AI-43).
    public var commQuoteRoll = 0
    private var nextEntityID = 1
    private var nextAsteroidID = 1

    /// Time before any authority ship will pick the player as a scan mark
    /// again. Each `AIBrain`'s own `scanCooldown` only throttles that one
    /// ship, so a busy system with several patrols could otherwise chain-scan
    /// the player back-to-back as each ship's individual cooldown expired.
    /// Set on every player scan.
    public var playerScanCooldown: Double = 0
    /// Latched true the first time an authority ship scans the player this system
    /// visit. A fresh `World` is built on each system entry, so this resets
    /// naturally per visit — giving the original's "you get buzzed by about one
    /// ship each time you enter," not a repeating cooldown that lets a busy system
    /// re-scan you every minute you loiter.
    public var playerScanned = false

    /// Governments with at least one ship the player's fleet has hit THIS
    /// system visit. Combat hostility/reinforcement-eligibility only —
    /// distinct from `Diplomacy.isHostileToPlayer`, which gates on the
    /// player's accumulated legal record (`CrimeTol`) instead. Attacking any
    /// one ship of a government immediately turns the whole government
    /// hostile in the system and reinforcement-eligible, independent of
    /// whether the legal-record threshold has been crossed — see
    /// `applyHit` (sets this + propagates `provokedByPlayer` to every other
    /// same-government ship present) and `Spawner.governmentUnderAttackAndOutmatched`
    /// (ORs this into its foe check). A fresh `World` is built on each system
    /// entry (see `allShips`/`refreshRoster` above), so this resets naturally
    /// per visit — no explicit reset needed.
    public var provokedGovernments: Set<Int> = []

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

    /// Snapshot every ship's current pose into its render-interpolation `prev`
    /// slot. The renderer calls this immediately before each fixed `step(_:)` so
    /// it can later draw ships at `lerp(renderPrevPosition, position, alpha)` and
    /// glide smoothly between 30 Hz sim ticks on a faster display. Presentational
    /// only — the sim never reads the snapshot. See `Ship.renderPrevPosition`.
    public func snapshotRenderState() {
        player.renderPrevPosition = player.position
        player.renderPrevAngle = player.angle
        for npc in npcs {
            npc.renderPrevPosition = npc.position
            npc.renderPrevAngle = npc.angle
        }
        for shot in projectiles {
            shot.renderPrevPosition = shot.position
        }
        for rock in asteroids { rock.renderPrevPosition = rock.position }
        for box in freeflightObjects { box.renderPrevPosition = box.position }
    }

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
            // AI-12: the original's arrival state (0x00410e20) starts a jump-in
            // at 50 px/tick along its inbound heading and lets the desired speed
            // climb back by 1.165 px/tick each raw call, so the ship brakes to
            // its cruise in about 27 ticks. The speed cap starts there and decays at
            // that rate.
            // A co-op peer's ship (no brain) keeps the port's capped inrush.
            let inbound = Vec2(sin(ship.angle), cos(ship.angle))
            let entrySpeed = ship.brain == nil ? min(ship.stats.maxSpeed * 2.4, 3200)
                : OriginalClock.perSecond(OriginalSpawnRules.jumpInSpeedPerTick)
            ship.velocity = inbound * entrySpeed
            // Seed the inertialess throttle to match, so a driftless arrival
            // rides its inbound momentum in rather than snapping to cruise.
            ship.throttleSpeed = entrySpeed
            ship.entryOverspeed = max(0, entrySpeed - ship.stats.maxSpeed)
            ship.entryOverspeedDecayPerSec = ship.brain == nil ? ship.entryOverspeed / 1.3
                : OriginalSpawnRules.arrivalBrakePerSecondSquared
            events.append(.shipArrived(entityID: ship.entityID, at: ship.position, fromHyperspace: true))
        case .launch:
            events.append(.shipLaunched(entityID: ship.entityID, at: ship.position))
        case let .gate(spobID):
            // AI-12: out of a gate (0x004159e0) the ship leaves along the gate's
            // emerge heading at 30 px/tick (15 for one attached to the player),
            // braking at the same 1.165 px/tick per raw call as a jump-in. The
            // original AI then holds it inside the gate (60 ticks, or the
            // `escortGateEmergences` hold) before the slide.
            let outward = Vec2(sin(ship.angle), cos(ship.angle))
            let attached = ship.brain?.leaderID == World.playerEntityID
            let exitSpeed = OriginalClock.perSecond(attached ? OriginalSpawnRules.gateExitSpeedPerTick / 2
                                                                  : OriginalSpawnRules.gateExitSpeedPerTick)
            ship.velocity = outward * exitSpeed
            ship.throttleSpeed = exitSpeed
            ship.entryOverspeed = max(0, exitSpeed - ship.stats.maxSpeed)
            ship.entryOverspeedDecayPerSec = OriginalSpawnRules.arrivalBrakePerSecondSquared
            events.append(.shipEmergedFromGate(entityID: ship.entityID, gateSpobID: spobID, at: ship.position))
        }
        applyDerelictGovtIfNeeded(ship)
        refreshRoster()
        return ship.entityID
    }

    /// AI-12: one of the player's escorts follows the player out of a gate
    /// (`Stellar_HandleStellarEntryAndExit` 0x00457580): it starts on the
    /// gate on the player's heading and holds inside for `Rand(20) + 15`
    /// ticks, not the usual 60, before sliding out at 15 px/tick.
    @discardableResult
    public func addEscortEmergingWithPlayer(_ ship: Ship, gateID: Int) -> Int {
        if let gate = systemContext.bodies.first(where: { $0.id == gateID }) {
            ship.position = Vec2(gate.position.x.rounded(.towardZero), gate.position.y.rounded(.towardZero))
        }
        ship.angle = player.angle
        let id = addNPC(ship, arrival: .gate(spobID: gateID))
        escortGateEmergences[id] = (gateID, Double(rng.range(20) + 15))
        return id
    }

    /// Ships following the player out of a gate, with the hold that replaces
    /// the usual 60 ticks; the original AI starts their emergence on its next
    /// step (the host adds them between steps, so the arrival event is gone).
    var escortGateEmergences: [Int: (gateID: Int, hold: Double)] = [:]

    /// Flash `text` across the HUD for `frames` 30 Hz ticks (a fleet Quote, a
    /// reinforcement warning).
    public func postOverlayMessage(_ text: String, frames: Int) {
        overlayTicks = frames
        events.append(.overlayMessage(text: text, frames: frames))
    }

    /// `DAT_00597a12`: the overlay message's remaining frames (raw calls),
    /// −1 when none is up. Distress calls wait for it to run down (AI-32).
    public internal(set) var overlayTicks = -1
    /// AI-32: `mïsn.ScanMask` of every mission whose cargo the player is
    /// carrying, OR'd (set by the host); an interceptor warns before
    /// scanning a matching government's player.
    public var missionCargoScanMask: UInt16 = 0
    /// The pilot's name, for broadcasts that address the player.
    public var pilotName = ""

    /// `gövt.Flags` 0x0800 — "Ships of this govt start out disabled (derelicts)."
    /// The base data's gövt #160 "Derelicts" is what every `Drifting Derelict`
    /// përs flies, and the designers pin those to fixed systems (Tichel, Gefjon,
    /// Sol…) as salvage waiting to be boarded. Without this they spawned as
    /// ordinary live ships — full shields, flying around, un-boardable — which is
    /// why Gefjon read as "a lot of derelicts flying around" instead of a
    /// Fed/pirate brawl with a few hulks drifting through it.
    ///
    /// Applied after the arrival mode so it also cancels a jump-in's inrush
    /// velocity: a hulk has no engines and never tears into a system.
    private func applyDerelictGovtIfNeeded(_ ship: Ship) {
        guard !ship.disabled, ship.government >= 128,
              galaxy?.game.govt(ship.government)?.startsDisabled == true else { return }
        // Disabled by its government whatever its armor, which stays real.
        ship.disabled = true
        ship.shield = 0
        ship.velocity = Vec2()
        ship.throttleSpeed = 0
        ship.entryOverspeed = 0
        ship.wantsToDepart = false
        ship.currentTargetID = nil
        ship.brain?.targetID = nil
        Log.world.debug("\(LogTag.ship(id: ship.entityID, name: ship.name)) spawned as a derelict (gövt \(ship.government) Flags 0x0800)")
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
                                width: Double, color: (r: Double, g: Double, b: Double)?,
                                coronaColor: (r: Double, g: Double, b: Double)? = nil,
                                coronaFalloff: Double = 0) {
        let beam = ActiveBeam(shooterID: shooterID, mountIndex: 0, weaponID: weaponID,
                              from: from, to: to, hit: hit, continuous: false,
                              life: .infinity, width: width, color: color,
                              coronaColor: coronaColor, coronaFalloff: coronaFalloff)
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

    /// Test seam: run one ship's fire control outside a step.
    func testFire(_ ship: Ship, primary: Bool) {
        var intent = ControlIntent()
        intent.firePrimary = primary
        fireWeapons(from: ship, intent: intent)
    }

    /// Test seam: drop one plain rock of integrity `hp` into the field.
    func testRock(at position: Vec2, hp: Double) -> Asteroid? {
        var d = [UInt8](repeating: 0, count: 24)
        d[1] = UInt8(max(1, min(255, Int(hp))))
        d[23] = 50
        let roid = RoidRes(Resource(type: NovaType.roid, id: 128, data: Data(d)))
        let rock = Asteroid(id: asteroids.count, roidTypeID: 128, position: position, angle: 0,
                            roid: roid, radius: 10, hpScale: 1)
        rock.hp = hp
        asteroids.append(rock)
        return rock
    }

    /// A government patrol/interceptor completed a scan pass on another ship;
    /// a scan of the player is the host's cue for the contraband findings
    /// (EC-15). `Ship_ScanPlayerForContraband` 0x00401800 drops the scan, after
    /// its roll, once the player's engaged jump is past the tunnel onset
    /// (jump progress > 0, not disabled) — settles Q-EC-11.
    public func reportScan(scannerID: Int, targetID: Int, at: Vec2) {
        if targetID == Self.playerEntityID, let jump = playerJump, !player.disabled, jump.progress > 0 { return }
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
    /// - Parameters:
    ///   - name: `mïsn.ShipName`, resolved — the name these special ships carry
    ///     on the target display instead of their bare hull type. Empty keeps
    ///     the hull name.
    ///   - subtitle: `mïsn.ShipSubtitle`, resolved — the line shown *beneath*
    ///     that name (e.g. "Federation Navy"). Empty shows none.
    public func spawnMissionShips(missionID: Int, dudeID: Int, count: Int,
                                  goal: MissionShipGoal = .none,
                                  behavior: MissionShipBehavior = .standard,
                                  government: Int? = nil,
                                  arrival: ArrivalMode = .hyperspace,
                                  navStellarIndex: Int? = nil,
                                  jumpBearing: Double? = nil,
                                  startsCloaked: Bool = false,
                                  preferredShipID: Int? = nil,
                                  auxiliary: Bool = false,
                                  name: String = "", subtitle: String = "") -> [Int] {
        guard count > 0, let galaxy = galaxy, let dude = galaxy.game.dude(dudeID) else { return [] }
        var placed: [Int] = []
        // AI-14: one jump-in bearing for the whole batch — the previous
        // system's direction when the host knows it, else Rand(360).
        var batchBearing: Double?
        switch arrival {
        case .hyperspace, .gate: batchBearing = jumpBearing ?? Double(rng.range(360)) * .pi / 180
        case .populate, .launch: break
        }
        for i in 0..<count {
            // A slot's locked hull (mïsn Flags 0x0800), or a përs
            // replacement's own hull, when the dude flies it; otherwise each
            // ship rolls among the dude's available hulls — a special ship
            // falls back to all of them (0x0041cf40), an auxiliary ship
            // doesn't spawn without one (0x0041c9f0).
            let preferred = preferredShipID.flatMap { id in dude.ships.contains { $0.shipID == id } ? id : nil }
            guard let shipID = preferred ?? missionHull(dude, allowUnavailable: !auxiliary) else { continue }
            // The dude's government, raw: one with none is independent.
            let govt = government ?? (dude.govt >= 128 ? dude.govt : independentGovt)
            var (pos, ang) = missionSpawnPose(arrival: arrival, bearing: batchBearing)
            // AI-14 (0x0041af90): an escort objective's ships sit within ±256 px
            // of the origin; a negative ShipStart puts them exactly on that nav
            // stellar of this system instead.
            if goal == .escort, batchBearing == nil {
                pos = Vec2(Double(rng.range(512) - 256), Double(rng.range(512) - 256))
            }
            if let nav = navStellarIndex, systemContext.bodies.indices.contains(nav) {
                pos = systemContext.bodies[nav].position
            }
            guard let ship = galaxy.makeLoadedShip(shipID, government: govt, at: pos, angle: ang,
                                                   skillScale: galaxy.skillVarianceScale(classOf: shipID, rng: &rng),
                                                   includeDefaultItems: false, defaultItemCapabilities: true) else { continue }
            // The dude's AI type, or the hull's InherentAI when it has none.
            let ai = dude.aiTypeRaw >= 1 ? dude.aiType
                : AIType(raw: galaxy.game.ship(shipID)?.inherentAI ?? dude.aiTypeRaw)
            let brain = AIBrain(aiType: ai, govt: ship.government)
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
            ship.missionAuxiliary = auxiliary
            ship.dudeID = dudeID
            // Mission ships take their düde's Booty credits too (EC-18).
            assignBootyCredits(ship, dude: dude)
            if !name.isEmpty { ship.displayName = name }
            if !subtitle.isEmpty { ship.displaySubtitle = subtitle }
            // A rescue objective's ship is held disabled, at its real armor,
            // until the player boards it (`Ship_IsShipDisabled`'s ShipGoal-5 arm).
            var mode = arrival
            if goal == .rescue {
                // AI-14: the wreck waits on a random heading at a third of its
                // armor (a tenth for hull Flags 0x10), less one point.
                ship.disabled = true
                ship.shield = 0
                ship.angle = Double(rng.range(360)) * .pi / 180
                let fraction = ship.disableArmorFraction == Ship.lowDisableFraction ? 0.1 : 0.33
                ship.armor = Double(Float(ship.maxArmor) * Float(fraction) - 1)
                mode = .populate   // it's adrift in-system, not warping in
            }
            placed.append(addNPC(ship, arrival: mode))
            // ShipStart 2 (0x0041af90): the ship enters its cloak state at once.
            if startsCloaked { ship.cloakEngaged = true }
        }
        if !placed.isEmpty {
            events.append(.missionShipsSpawned(missionID: missionID, entityIDs: placed))
        }
        return placed
    }

    /// `Dude_SelectShipTypeIndexFromDudeDef` 0x0046b4b0: `Rand(total)` over
    /// the dude's hulls whose AppearOn passes; with `allowUnavailable`, all of
    /// them when none does.
    func missionHull(_ dude: DudeRes, allowUnavailable: Bool) -> Int? {
        func pick(_ entries: [(Int, Int)]) -> Int? {
            let total = entries.reduce(0) { $0 + $1.1 }
            guard total > 0 else { return nil }
            return OriginalSpawnRules.cumulativePick(entries, roll: rng.range(total))
        }
        let available = dude.ships.filter { entry in
            guard let res = galaxy?.game.ship(entry.shipID) else { return false }
            return res.appearOn.isEmpty || shipSpawnEligible(entry.shipID)
        }.map { ($0.shipID, $0.prob) }
        if let id = pick(available) { return id }
        return allowUnavailable ? pick(dude.ships.map { ($0.shipID, $0.prob) }) : nil
    }

    /// Surviving auxiliary ships per mission (0x0041ad50): when the player
    /// leaves the system, each live aux ship of a still-active mission goes
    /// back to that mission's budget. Destroyed ones don't. Each ship is
    /// counted once: collecting clears its mark.
    public func collectSurvivingAuxiliaryShips() -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for npc in npcs where npc.missionAuxiliary && npc.isAlive {
            if let mid = npc.missionID { counts[mid, default: 0] += 1 }
            npc.missionAuxiliary = false
        }
        return counts
    }

    /// AI-39 (0x00454910): a përs whose accepted LinkMission has Flags 0x0040
    /// and a one-ship mission is replaced by the mission's ship — its own hull
    /// when the dude flies it — on the same pose, and the përs ship goes. The
    /// replacement is not linked to the player: the original only makes a
    /// ShipBehav-1 ship an escort when it builds a system, so it joins at the
    /// next jump (known bug #119).
    @discardableResult
    public func replaceWithMissionShip(entityID: Int, missionID: Int, dudeID: Int,
                                       goal: MissionShipGoal, behavior: MissionShipBehavior,
                                       name: String = "", subtitle: String = "") -> Int? {
        guard let old = ship(id: entityID), !old.isPlayer else { return nil }
        let ids = spawnMissionShips(missionID: missionID, dudeID: dudeID, count: 1, goal: goal,
                                    behavior: behavior == .protectPlayer ? .standard : behavior,
                                    arrival: .populate, preferredShipID: old.shipTypeID,
                                    name: name, subtitle: subtitle)
        guard let id = ids.first, let ship = ship(id: id) else { return nil }
        ship.position = old.position
        ship.velocity = old.velocity
        ship.angle = old.angle
        removeShip(entityID: entityID)
        return id
    }

    /// A mission batch waiting out its rearm delay in maintenance ticks (raw
    /// calls) before it jumps in (AI-14): ShipStart-1 goal ships
    /// (`Rand(100) + 100`, 30 for a ShipBehav-1 escort) and auxiliary ships
    /// (`Rand(70) + 70`).
    public struct PendingMissionArrival: Sendable {
        public let missionID: Int
        public let dudeID: Int
        public let count: Int
        public let goal: MissionShipGoal
        public let behavior: MissionShipBehavior
        public let auxiliary: Bool
        public let name: String
        public let subtitle: String
        public var callsLeft: Int
        /// The slot's locked hull (mïsn Flags 0x0800), if any.
        public var preferredShipID: Int? = nil
    }

    /// Queue a mission batch to jump in after `delayCalls` maintenance ticks.
    public func scheduleMissionArrival(missionID: Int, dudeID: Int, count: Int,
                                       goal: MissionShipGoal = .none,
                                       behavior: MissionShipBehavior = .standard,
                                       auxiliary: Bool, delayCalls: Int,
                                       preferredShipID: Int? = nil,
                                       name: String = "", subtitle: String = "") {
        guard count > 0 else { return }
        pendingMissionArrivals.append(PendingMissionArrival(
            missionID: missionID, dudeID: dudeID, count: count, goal: goal, behavior: behavior,
            auxiliary: auxiliary, name: name, subtitle: subtitle, callsLeft: max(0, delayCalls),
            preferredShipID: preferredShipID))
    }

    /// The original's ShipStart-1 rearm delay: 30 maintenance ticks for an
    /// escort that protects the player, else `Rand(100) + 100` (0x0043f8c0 /
    /// 0x00448910).
    public func missionRearmDelay(goal: MissionShipGoal, behavior: MissionShipBehavior) -> Int {
        behavior == .protectPlayer && goal == .escort ? 30 : rng.range(100) + 100
    }

    /// An arrival's auxiliary-ship timer, `Rand(0x46) + 0x46`.
    public func missionAuxDelay() -> Int { rng.range(0x46) + 0x46 }

    public func hasPendingMissionArrival(missionID: Int) -> Bool {
        pendingMissionArrivals.contains { $0.missionID == missionID }
    }

    /// Count the queued batches down by this step's raw calls and land the
    /// ones that are due, jumping in on the previous system's bearing (goal
    /// ships) or a random one (auxiliary ships).
    func tickPendingMissionArrivals() {
        guard !pendingMissionArrivals.isEmpty else { return }
        var due: [PendingMissionArrival] = []
        for i in pendingMissionArrivals.indices {
            pendingMissionArrivals[i].callsLeft -= rawCallsThisStep
            if pendingMissionArrivals[i].callsLeft <= 0 { due.append(pendingMissionArrivals[i]) }
        }
        pendingMissionArrivals.removeAll { $0.callsLeft <= 0 }
        for batch in due {
            let placed = spawnMissionShips(missionID: batch.missionID, dudeID: batch.dudeID, count: batch.count,
                                           goal: batch.goal, behavior: batch.behavior, arrival: .hyperspace,
                                           jumpBearing: batch.auxiliary ? nil : previousSystemBearing,
                                           preferredShipID: batch.preferredShipID,
                                           auxiliary: batch.auxiliary,
                                           name: batch.name, subtitle: batch.subtitle)
            if batch.auxiliary, !placed.isEmpty {
                events.append(.missionAuxShipsArrived(missionID: batch.missionID, count: placed.count))
            }
        }
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

    /// Release every ship tagged with `missionID`
    /// (`Mission_ClearMisnSlotAssignments` 0x00440aa0): the tag is cleared
    /// and a ship flying in a group (a mission escort, or a ship following
    /// another) leaves it for `aiType(shipTypeID)`, its class's default AI,
    /// with no target. The ships stay in the system; while the landing window
    /// owns the world the original removes them instead
    /// (`despawnMissionShips`). Returns the ids released.
    @discardableResult
    public func releaseMissionShips(missionID: Int, aiType: (Int) -> AIType) -> [Int] {
        var released: [Int] = []
        for npc in npcs where npc.missionID == missionID {
            npc.missionID = nil
            npc.missionShipGoal = nil
            if let brain = npc.brain, brain.leaderID != nil {
                brain.leaderID = nil
                brain.aiType = aiType(npc.shipTypeID)
                npc.currentTargetID = nil
            }
            released.append(npc.entityID)
        }
        if !released.isEmpty { refreshRoster() }
        return released
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
    private func missionSpawnPose(arrival: ArrivalMode, bearing: Double? = nil) -> (Vec2, Double) {
        // AI-14: a ShipStart-1 ship jumps in from the original radius with a
        // ±256 px scatter, facing the origin (the original takes the bearing
        // of the player's previous system; this engine doesn't know it, so the
        // bearing is random). Anything else is placed like any new ship slot,
        // over [-750, 750)² around the origin.
        switch arrival {
        case .hyperspace, .gate:
            let bearing = bearing ?? Double(rng.range(360)) * .pi / 180
            let pos = Vec2(sin(bearing), cos(bearing)) * OriginalSpawnRules.jumpInRadius
                + Vec2(Double(rng.range(512) - 256), Double(rng.range(512) - 256))
            return (pos, OriginalMath.bearingRadians(from: pos, to: Vec2()))
        case .populate, .launch:
            let span = 2 * OriginalSpawnRules.initialScatter
            let pos = Vec2(Double(rng.range(span) - OriginalSpawnRules.initialScatter),
                           Double(rng.range(span) - OriginalSpawnRules.initialScatter))
            return (pos, Double(rng.range(360)) * .pi / 180)
        }
    }

    // MARK: Asteroids

    /// Set up the system's asteroid field: `count` (`sÿst.Asteroids`, at most
    /// 16) rocks of the enabled `typeIDs` (`AstTypes`). The original keeps them
    /// in a 16-slot pool around the *player's viewport*, not the system
    /// (`Asteroid_InitSystem` 0x004216b0): they're scattered on the first step
    /// around wherever the player is, drift, and any rock that leaves the view
    /// is dropped and replaced at the edge, so the field travels with the player.
    public func populateAsteroids(typeIDs: [Int], count: Int) {
        asteroidTypeIDs = typeIDs
        asteroidFieldSize = typeIDs.isEmpty ? 0 : min(max(0, count), 16)
        asteroidFieldScattered = false
    }

    /// The asteroid types this system's field draws from.
    private var asteroidTypeIDs: [Int] = []
    /// `sÿst.Asteroids`, capped to the original's 16-slot pool.
    private var asteroidFieldSize = 0
    private var asteroidFieldScattered = false
    /// Half the visible playfield, px — the original's view centre offsets. The
    /// asteroid field scatters, recycles and re-enters relative to it. The host
    /// sets it from its window and zoom; the default is an 800×600 screen less
    /// the original's sidebar.
    public var viewportHalfExtent = Vec2(320, 300)

    /// One field rock at a random enabled type (`range(16)` until the type's
    /// `AstTypes` bit is set), spin and frame (`Asteroid_Spawn` 0x00421830 /
    /// `Asteroid_SpawnRecord` 0x00421e60): spin `(range(41) + 80) × 0.01 ×
    /// SpinRate`, reversed half the time.
    private func makeFieldAsteroid(typeID: Int?, at position: Vec2, velocity: Vec2) -> Asteroid? {
        guard let game = galaxy?.game else { return nil }
        let type: Int
        if let typeID {
            type = typeID
        } else {
            guard asteroidTypeIDs.contains(where: { (128..<144).contains($0) }) else { return nil }
            var k = 128 + rng.range(16)
            while !asteroidTypeIDs.contains(k) { k = 128 + rng.range(16) }
            type = k
        }
        guard let roid = game.roid(type) else { return nil }
        let radius = game.spin(type + 672).map { Double($0.tileWidth) / 2 } ?? 24
        let rock = Asteroid(id: nextAsteroidID, roidTypeID: type, position: position,
                            angle: Double(rng.range(36)) * 10 * .pi / 180,
                            roid: roid, radius: radius, hpScale: combatTuning.hpScale)
        nextAsteroidID += 1
        rock.velocity = velocity
        rock.angularVelocityDegPerSec *= Double(rng.range(41) + 80) * 0.01
        if rng.range(2) == 0 { rock.angularVelocityDegPerSec = -rock.angularVelocityDegPerSec }
        return rock
    }

    /// A drift of `(range(400) − 200) × 0.01` px/tick per axis, as px/s.
    private func fieldDrift() -> Vec2 {
        Vec2(OriginalClock.perSecond(Double(rng.range(400) - 200) * 0.01),
             OriginalClock.perSecond(Double(rng.range(400) - 200) * 0.01))
    }

    /// The first-step scatter: each rock within `(half + 128) / 2` of the
    /// player on each axis, with a fresh drift.
    private func scatterAsteroidField() {
        asteroidFieldScattered = true
        let w = Int(viewportHalfExtent.x) + 128, h = Int(viewportHalfExtent.y) + 128
        for _ in 0..<asteroidFieldSize {
            let offset = Vec2(Double(rng.range(w)) - Double(w) * 0.5,
                              Double(rng.range(h)) - Double(h) * 0.5)
            if let rock = makeFieldAsteroid(typeID: nil, at: player.position + offset, velocity: fieldDrift()) {
                asteroids.append(rock)
            }
        }
    }

    /// Move the field one step: drift and spin every rock, drop any that left
    /// the view (0x00436910), and — once per raw call while the pool is short —
    /// bring one in from outside the view, heading back toward the player
    /// (`Asteroid_Spawn(1)`).
    private func stepAsteroidField(_ dt: Double, rawCalls: Int) {
        if !asteroidFieldScattered, asteroidFieldSize > 0 { scatterAsteroidField() }
        let half = viewportHalfExtent
        for rock in asteroids where rock.isAlive {
            rock.position += rock.velocity * dt
            rock.angle += rock.angularVelocityDegPerSec * .pi / 180.0 * dt
            // The original tests the rock's sprite against the screen in screen
            // space (y down), with a lopsided margin: one sprite width past the
            // right/bottom edge, two past the left/top.
            let w = rock.radius * 2
            let dx = rock.position.x - player.position.x
            let dy = player.position.y - rock.position.y
            if dx > half.x + 32 + w / 2 || dx < -half.x - 1.5 * w - 32
                || dy > half.y + 32 + w / 2 || dy < -half.y - 1.5 * w - 32 {
                rock.isAlive = false
            }
        }
        asteroids.removeAll { !$0.isAlive }
        guard asteroidFieldSize > 0 else { return }
        for _ in 0..<rawCalls where asteroids.count < asteroidFieldSize {
            // Both axes land outside the view by the half-*height* (the
            // original's quirk), up to half again further, drifting inward.
            let c = max(half.y.rounded(.down), 2)
            let reach = Int((c / 2).rounded(.down))
            var screen = Vec2(), drift = Vec2()
            if rng.range(2) == 0 {
                screen.x = c + Double(rng.range(reach)); drift.x = Double(rng.range(200)) * -0.01
            } else {
                screen.x = -c - Double(rng.range(reach)); drift.x = Double(rng.range(200)) * 0.01
            }
            if rng.range(2) == 0 {
                screen.y = c + Double(rng.range(reach)); drift.y = Double(rng.range(200)) * -0.01
            } else {
                screen.y = -c - Double(rng.range(reach)); drift.y = Double(rng.range(200)) * 0.01
            }
            let position = player.position + Vec2(screen.x, -screen.y)
            let velocity = Vec2(OriginalClock.perSecond(drift.x), OriginalClock.perSecond(-drift.y))
            if let rock = makeFieldAsteroid(typeID: nil, at: position, velocity: velocity) {
                asteroids.append(rock)
            }
        }
    }

    /// Destroy an asteroid (`Asteroid_SpawnDestructionPackage` 0x00462550):
    /// explosion and debris, `trunc((range(101) + 50) × YieldQty × 0.01)`
    /// resource boxes of `YieldType` left drifting for a scoop to collect, and
    /// `range(FragCount) + FragCount / 2` fragments (so FragCount 1 yields none —
    /// an original quirk) of a random `FragType`, each taking a free pool slot.
    private func destroyAsteroid(_ rock: Asteroid, killerID: Int = -1) {
        rock.isAlive = false
        let rockBoomSound = rock.explosionBoomID.flatMap { galaxy?.game.boom($0)?.soundID }
        events.append(.explosion(at: rock.position, radius: max(20, rock.radius * 1.2),
                                 soundID: rockBoomSound, boomID: rock.explosionBoomID))
        if rock.partCount > 0 {
            events.append(.asteroidDebris(at: rock.position, color: rock.partColor, count: rock.partCount))
        }
        if rock.yieldQty > 0 {
            let boxes = (rng.range(101) + 50) * rock.yieldQty / 100
            let spriteSet = ((rock.roidTypeID - 128) >> 2) + 1
            for _ in 0..<boxes {
                spawnFreeflightObject(at: rock.position, cargoType: rock.yieldType, spriteSet: spriteSet)
            }
        }
        guard rock.fragCount > 0 else { return }
        let n = rng.range(rock.fragCount) + rock.fragCount / 2
        for _ in 0..<n {
            let a = rock.fragType1 >= 128 ? rock.fragType1 : nil
            let b = rock.fragType2 >= 128 ? rock.fragType2 : nil
            let type: Int
            switch (a, b) {
            case let (a?, b?): type = rng.range(2) == 0 ? a : b
            case let (a?, nil): type = a
            case let (nil, b?): type = b
            case (nil, nil): return
            }
            guard asteroids.filter(\.isAlive).count < 16 else { return }
            let drift = Vec2(OriginalClock.perSecond(Double(rng.range(200) - 100) * 0.01),
                             OriginalClock.perSecond(Double(rng.range(200) - 100) * 0.01))
            if let frag = makeFieldAsteroid(typeID: type, at: rock.position, velocity: drift) {
                asteroids.append(frag)
            }
        }
    }

    // MARK: Freeflight objects

    /// Live freeflight boxes (asteroid yields), at most 64.
    public private(set) var freeflightObjects: [FreeflightObject] = []
    private var nextFreeflightID = 1
    /// Whether the player's hold can take another ton — the host's answer, since
    /// the pilot's cargo lives outside the engine. With a scoop and room, the
    /// player collects boxes; otherwise boxes fly on through.
    public var playerHoldHasRoom: () -> Bool = { true }

    /// A box at `position` drifting off at `(range(81) + 60) × 0.002` px/tick on a
    /// `range(360)` heading, alive 300–499 ticks, spinning −1/0/0/+1 frames a tick.
    func spawnFreeflightObject(at position: Vec2, cargoType: Int, spriteSet: Int) {
        guard freeflightObjects.count < 64 else { return }
        let life = Double(rng.range(200) + 300) / OriginalClock.ticksPerSecond
        let frame = Double(rng.range(36))
        let spin = [-1, 0, 0, 1][rng.range(4)]
        let speed = Double(rng.range(81) + 60) * 0.2 * 0.01
        let heading = Double(rng.range(360)) * .pi / 180
        freeflightObjects.append(FreeflightObject(
            id: nextFreeflightID, position: position,
            velocity: Vec2.heading(heading) * OriginalClock.perSecond(speed),
            lifeRemaining: life, frame: frame, spin: spin,
            cargoType: cargoType, spriteSet: spriteSet))
        nextFreeflightID += 1
    }

    /// Jettisoned cargo (`Ship_SpawnFreeflightObjectForShip` 0x0041f800,
    /// UI-13): `count` pods from the spïn 500 set, each placed half the ship's
    /// width behind it, moving with the ship plus `(rand(40) + 30) / 100`
    /// px/tick on a heading `180 + rand(30) − rand(15)`° from its nose, alive
    /// 180–269 ticks. They carry no cargo: the original leaves the
    /// resource-box latch clear, so a scoop passes through them.
    public func spawnJettisonedPods(from ship: Ship, count: Int) {
        let back = ship.angle + .pi
        for _ in 0..<count {
            guard freeflightObjects.count < 64 else { return }
            let life = Double(rng.range(90) + 180) / OriginalClock.ticksPerSecond
            let frame = Double(rng.range(36))
            let spin = [-1, 0, 0, 1][rng.range(4)]
            let position = ship.position + Vec2.heading(back) * Double(ship.radius)
            let speed = Double(rng.range(40) + 30) / 100
            let jitter = Double(rng.range(30) - rng.range(15)) * .pi / 180
            let velocity = ship.velocity + Vec2.heading(back + jitter) * OriginalClock.perSecond(speed)
            freeflightObjects.append(FreeflightObject(
                id: nextFreeflightID, position: position, velocity: velocity,
                lifeRemaining: life, frame: frame, spin: spin, cargoType: -1, spriteSet: 0))
            nextFreeflightID += 1
        }
    }

    /// Drift, spin and age the boxes; a player with a mining scoop (ModType 31)
    /// and room in the hold collects one ton per box it touches (0x004374f0).
    private func stepFreeflightObjects(_ dt: Double) {
        guard !freeflightObjects.isEmpty else { return }
        let ticks = dt * OriginalClock.ticksPerSecond
        let scooping = player.isAlive && player.hasMiningScoop && playerHoldHasRoom()
        freeflightObjects.removeAll { box in
            box.position += box.velocity * dt
            box.frame = (box.frame + Double(box.spin) * ticks).truncatingRemainder(dividingBy: 36)
            if box.frame < 0 { box.frame += 36 }
            box.lifeRemaining -= dt
            if box.lifeRemaining < 0 { return true }
            if scooping, box.cargoType >= 0, (box.position - player.position).length < player.radius + 6 {
                events.append(.asteroidMined(cargoType: box.cargoType, quantity: 1, at: box.position))
                return true
            }
            // AI-31: an NPC miner in state 0x11 scoops a box it touches; a
            // commodity goes into its hold (junk only counts for the player).
            if let miner = npcs.first(where: { npc in
                npc.isAlive && !npc.disabled
                    && originalAI.record(for: npc.entityID)?.state == OriginalAIState.debris
                    && (box.position - npc.position).length < npc.radius + 6
            }) {
                if (0...5).contains(box.cargoType) { miner.cargo[box.cargoType, default: 0] += 1 }
                return true
            }
            return false
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
        latchPlayerOutfitGovernments()
        rawCallsThisStep = cadence.advance(dt)
        let rawCalls = rawCallsThisStep
        rawCallCounter &+= rawCalls
        tickDebrisPuffs(rawCalls: rawCalls)

        prof("sim.spawn") {
            if !spawningPaused { spawner?.update(dt, world: self) }   // paused on a co-op client (mirrors the authority)
            updateStellarDefenses()   // relaunch tribute-defense waves as they're cleared
            tickPendingMissionArrivals()   // AI-14 delayed mission jump-ins
            if overlayTicks > -1 { overlayTicks = max(-1, overlayTicks - rawCalls) }
            refreshRoster()
        }
        updateCombatChatter()

        // Player: outside intent. Once dead, stop honouring the controls entirely —
        // no firing, and freeze the wreck in place (zero velocity, empty intent) so
        // it doesn't keep flying under live input (looking alive) while the death /
        // explosion sequence plays out and the app returns to the menu.
        refreshFlightFactors()

        prof("sim.player") {
            if escapePodTicksLeft != nil {
                stepEscapePod(dt)
            } else if escapePodLanded {
                player.velocity = Vec2()   // waiting for the host's respawn
            } else if player.isAlive, var jump = playerJump {
                // Each spin-up tick pushes the leader's jump state to its
                // escorts, before the timer advances (0x00422340).
                if jump.phase == .spinUp { originalAI.syncSquadJump(world: self, leaderTimer: max(1, jump.timer)) }
                jump.tick(player, dt: dt)
                playerJump = jump
            } else if player.isAlive, player.disabled {
                // WP-03: a disabled player has no weapons, thrust or turn
                // keys — only the face-target auto-turn — and drifts × 0.995
                // per raw call (0x0044b240).
                var drift = ControlIntent()
                drift.desiredHeading = intent.desiredHeading
                fireWeapons(from: player, intent: ControlIntent())
                player.velocity = player.velocity * pow(0.995, Double(rawCalls))
                player.step(dt, intent: drift, tuning: tuning, rawCalls: rawCalls)
                tickRepairSystem(player, dt: dt)
            } else if player.isAlive {
                player.autoClearSecondary()
                fireWeapons(from: player, intent: intent)
                updateBeamLock(player, dt: dt)
                player.step(dt, intent: intent, tuning: tuning, rawCalls: rawCalls)
            } else {
                player.velocity = Vec2()
                player.step(dt, intent: ControlIntent(), tuning: tuning, rawCalls: rawCalls)
            }
            stepEjection()
            stepSelfDestruct(held: intent.selfDestruct, ticks: dt * OriginalClock.ticksPerSecond)
            recenterForWorldWrap()
        }

        // NPCs: each brain decides an intent. Disabled hulks don't think — they
        // just bleed off speed and drift. A hulk has no attitude control, so its
        // heading is frozen wherever it was when it died: it coasts nose-first
        // along its last course rather than turning.
        // This loop (AI think + fire + physics for every NPC) is the sim's
        // dominant cost under a crowded fight, so it gets its own profiler phase.
        prof("sim.ai") {
            originalAI.beginStep(self, dt: dt)
            for npc in npcs where npc.isAlive {
                if npc.refillsDefensesEveryTick { npc.shield = npc.maxShield; npc.armor = npc.maxArmor }
                if npc.disabled {
                    // A disabled hull's velocity (and an inertialess hull's
                    // speed) damps × 0.995 per raw call (0x00433050).
                    let damp = pow(0.995, Double(rawCalls))
                    npc.velocity = npc.velocity * damp
                    npc.throttleSpeed *= damp
                    npc.position += npc.velocity * dt
                    tickRepairSystem(npc, dt: dt)
                    continue
                }
                let npcIntent: ControlIntent
                if npc.brain != nil {
                    npcIntent = originalAI.think(ship: npc, world: self, dt: dt)
                    npc.velocityMatchLed = npc.brain?.leaderID != nil
                        && originalAI.record(for: npc.entityID)?.mode == OriginalAIMode.velocityMatch
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
                updateBeamLock(npc, dt: dt)
                npc.step(dt, intent: npcIntent, tuning: tuning, rawCalls: rawCalls)
            }
        }

        // Cooldowns, ion dissipation & regen (hulks *recover* nothing, but their
        // weapons still cool and their ion charge still bleeds away).
        prof("sim.regen") {
            for s in allShips {
                for w in s.weapons {
                    w.tick(dt)
                    // Seeker 0x0020 (B-2): the bank's reload is pinned at one
                    // tick while the ship is ionized — for the player at any
                    // charge (intensity > 0.0, 0x0044aa70), for an NPC once
                    // the whole-number intensity reaches 1 (0x00433050).
                    if w.spec.cantFireWhileIonized,
                       s.isPlayerControlled ? s.ionCharge > 0 : s.isIonized {
                        w.cooldown = 1 / OriginalClock.ticksPerSecond
                    }
                }
                s.deionize(dt)
                if !s.disabled { s.regen(dt) }
                if s.isPlayer { s.regenFuel(dt) }
            }
        }

        // Fighter bays: carriers deploy fighters in combat; fighters dock back.
        prof("sim.bays") { updateFighterBays(dt) }
        // Cloaking devices: fade in/out and drain fuel/shield.
        prof("sim.cloak") { stepCloak(dt) }

        prof("sim.asteroids") {
            stepAsteroidField(dt, rawCalls: rawCalls)
            stepFreeflightObjects(dt)
        }

        prof("sim.gravity") { applyStellarGravity(dt) }
        prof("sim.deadlyStellars") { checkDeadlyStellarCollisions() }
        prof("sim.stellarWeapons") { updateStellarWeapons(dt) }
        prof("sim.pointDefense") { runPointDefense(rawCalls: rawCalls) }
        prof("sim.projectiles") {
            stepBeamRecords(rawCalls: rawCalls)
            stepProjectiles(dt, rawCalls: rawCalls)
        }
        prof("sim.despawn") { despawnDepartedAndDead(dt) }
        // Ships have moved this step; weld continuous beams to their new
        // positions/headings and expire pulse-beam flashes.
        prof("sim.beams") { refreshActiveBeams(dt) }
        reportPlayerDeathIfNeeded(dt)

        // Whatever time in `step` wasn't inside a named phase above (event reset,
        // roster bookkeeping, death report) — so the sim phases sum to the real
        // `step` cost with no silent gap.
        if let profiler {
            let totalNs = DispatchTime.now().uptimeNanoseconds &- profStepT0
            profiler("sim.other", Double(totalNs &- min(totalNs, profMeasuredNs)) / 1_000_000_000)
        }
    }

    /// OS-07, the repair system (oütf ModType 49; `Frame_ShouldTriggerAutoRepairTick`
    /// 0x0046e540): a disabled ship that owns one (an NPC through its
    /// DefaultItems) rolls 1 in 500 a tick — once the player's 300-tick
    /// post-disable window has run out — and on success its armor jumps to
    /// `max/3 + 1` (`max/10 + 1` with hull Flags 0x0010), just above the
    /// disable line. The player hears and reads "repair systems engaged".
    func tickRepairSystem(_ ship: Ship, dt: Double) {
        let ticks = dt * OriginalClock.ticksPerSecond
        if ship.recentlyHitTicks >= 0 { ship.recentlyHitTicks -= ticks }
        guard ship.hasRepairSystem, ship.disabled, !ship.heldDisabled, ship.isAlive,
              ship.recentlyHitTicks < 0 else { return }
        let rolls = max(1, Int(ticks.rounded()))
        guard (0..<rolls).contains(where: { _ in rng.range(500) == 0 }) else { return }
        let fraction = ship.disableArmorFraction < Ship.standardDisableFraction ? 0.1 : 0.3333
        ship.armor = ship.maxArmor * fraction + 1
        events.append(.repairSystemEngaged(entityID: ship.entityID))
        if ship.formerWingRole != nil { rejoinWing(ship) }
        Log.combat.debug("\(ship.name) [\(ship.entityID)] repair system brought it back above the disable line")
    }

    /// `spöb.Gravity` (`Stellar_TickStellarGravityPull` 0x0043adb0 /
    /// `Ship_AccelerateShipTowardPoint` 0x0046e2f0): every tick each ship is
    /// pulled toward each stellar with gravity by `Gravity / max(d², 30)`
    /// px/tick, with `d` measured in hundreds of pixels. Negative values push.
    /// A ship is shielded by `shïp.Flags3` 0x0020, by flying inertialess, or —
    /// the player only — by a ModType-41 outfit (`Stellar_ShipHasGravityShielding`
    /// 0x0046e120). No code reads Flags3 0x0010, the Bible's "ignores gravity".
    /// No stock stellar sets Gravity.
    func applyStellarGravity(_ dt: Double) {
        let wells = systemContext.bodies.filter { $0.gravity != 0 }
        guard !wells.isEmpty else { return }
        let ticks = dt * OriginalClock.ticksPerSecond
        for ship in allShips where ship.isAlive && !hasGravityShielding(ship) {
            for body in wells {
                let rel = body.position - ship.position
                guard rel.x != 0 || rel.y != 0 else { continue }
                let hundreds = rel * 0.01
                let d2 = max(hundreds.x * hundreds.x + hundreds.y * hundreds.y, 30)
                let pullPerTick = Double(body.gravity) / d2 * ticks
                ship.velocity += rel.normalized * OriginalClock.perSecond(pullPerTick)
            }
        }
    }

    func hasGravityShielding(_ ship: Ship) -> Bool {
        ship.hullShieldsStellars || ship.fliesInertialess(tuning)
            || (ship.isPlayerControlled && ship.hasGravityResistOutfit)
    }

    /// `spöb.Flags2` 0x0100: a deadly stellar destroys every ship that touches
    /// it. Immune: `shïp.Flags3` 0x0020, or the player with a ModType-42 outfit
    /// (`Stellar_ShipImmuneToStellarCrash` 0x0046e210). No stock stellar sets
    /// the flag. Zeroing shield/armor lets the ordinary death pipeline later
    /// this tick handle the kill (explosion, events, escape pod).
    private func checkDeadlyStellarCollisions() {
        let deadly = systemContext.bodies.filter { $0.isDeadly }
        guard !deadly.isEmpty else { return }
        // Disabled hulks included, and the kill is instant (WP-25).
        for ship in allShips where ship.isAlive {
            if ship.hullShieldsStellars || (ship.isPlayerControlled && ship.hasStellarResistOutfit) { continue }
            for body in deadly where touchesDeadlyStellar(ship, body) {
                ship.shield = 0
                ship.armor = 0
                ship.diesInstantly = true
                Log.combat.debug("\(ship.name) [\(ship.entityID)] touched deadly stellar #\(body.id) — destroyed")
                break
            }
        }
    }

    /// `Stellar_ApplyDeadlyCollision` (0x0043aed0): the hull's and the stellar's
    /// sprite masks overlap (the stellar at its current animation frame, `stellarFrames`). Falls back to the
    /// bounding circles when either art is missing.
    private func touchesDeadlyStellar(_ ship: Ship, _ body: StellarBody) -> Bool {
        guard let galaxy, let hull = galaxy.hullCollisionMask(ship.shipTypeID),
              let stellar = galaxy.stellarCollisionMask(body.id) else {
            return (ship.position - body.position).length < body.radius + ship.radius
        }
        let a = ContactSprite.hull(hull.mask, frame: hull.frame(angle: ship.angle), at: ship.position)
        let b = ContactSprite.hull(stellar, frame: min(max(0, stellarFrames[body.id] ?? 0), stellar.frameCount - 1),
                                   at: body.position)
        return SpriteContact.boundsOverlap(a, b) && SpriteContact.masksOverlap(a, b)
    }

    /// The player's own death is otherwise invisible to `despawnDepartedAndDead`
    /// (which only ever looks at `npcs`) — report it exactly once via
    /// `.playerDestroyed`, alongside the same explosion effect an NPC kill
    /// gets, so the app can run its escape-pod-or-game-over reaction.
    private func reportPlayerDeathIfNeeded(_ dt: Double) {
        if playerDeathEjected {
            // Ejected mid-sequence: the wreck finishes dying as an NPC, and
            // the new craft starts with a clean slate.
            playerDeathEjected = false
            playerDeathReported = false
            playerDeathElapsed = 0
        }
        if playerDeathReported, !playerDeathSequenceOver {
            playerDeathElapsed += dt
            let timerTicks = player.deathDelayTicks * 3 - playerDeathElapsed / OriginalClock.rawCallSeconds
            if dyingCarrierEscapeDue(player, timerTicks: timerTicks) { dyingCarrierEscape(player) }
            if playerDeathElapsed >= player.deathSequenceDuration {
                // The finale: the hull blows (WP-13) and, with no eject, the
                // pilot is lost.
                playerDeathSequenceOver = true
                deathBlast(of: player)
                events.append(.playerDestroyed)
            }
        }
        guard !playerDeathReported, !player.isAlive else { return }
        playerDeathReported = true
        // Since the dead player is no longer stepped through `fireWeapons`, its own
        // continuous-fire (beam) loop would never get its natural stop — emit it now
        // so the player's weapon loop doesn't keep sounding into the menu.
        stopAllBeamLoops(for: player)
        events.append(.explosion(at: player.position, radius: max(24, player.radius * 1.5),
                                 soundID: player.explosionSoundID, boomID: player.explosionBoomID))
        events.append(.playerDying)
    }

    /// World wrap (`Ship_RecenterSpaceObjectsForWorldWrap` 0x0045baa0): once the
    /// player passes 15000 px from the origin on an axis, the player and every
    /// ship, shot and rock within 15000 px of them (per axis, before the move)
    /// shift 25000 px back along it. Stellars stay put, so the player reappears
    /// 10000 px out on the far side with the nearby fight carried along; ships
    /// left behind never wrap.
    private func recenterForWorldWrap() {
        func shift(_ v: Double) -> Double { v > 15000 ? -25000 : (v < -15000 ? 25000 : 0) }
        let delta = Vec2(shift(player.position.x), shift(player.position.y))
        guard delta.x != 0 || delta.y != 0 else { return }
        let origin = player.position
        func near(_ p: Vec2) -> Bool {
            abs((p.x - origin.x).rounded(.towardZero)) < 15000
                && abs((p.y - origin.y).rounded(.towardZero)) < 15000
        }
        for ship in npcs where near(ship.position) {
            ship.position += delta
            ship.renderPrevPosition += delta
        }
        for p in projectiles where near(p.position) {
            p.position += delta
            p.renderPrevPosition += delta
        }
        for rock in asteroids where near(rock.position) {
            rock.position += delta
            rock.renderPrevPosition += delta
        }
        for box in freeflightObjects where near(box.position) {
            box.position += delta
            box.renderPrevPosition += delta
        }
        player.position += delta
        player.renderPrevPosition += delta
        Log.physics.debug("World wrap: recentred by (\(delta.x), \(delta.y))")
    }

    /// Sets this step's strict-play speed bonus and gravity-pull latch on every
    /// ship before it flies.
    private func refreshFlightFactors() {
        let bonus = strictPlay ? 1.0 : 1.5
        let pull = systemContext.bodies.contains { $0.gravity != 0 }
        player.topSpeedFactor = bonus
        player.inGravityPull = pull
        for npc in npcs {
            let ledByPlayer = npc.isPlayerControlled || npc.brain?.leaderID == World.playerEntityID
            npc.topSpeedFactor = ledByPlayer ? bonus : 1
            npc.inGravityPull = pull
        }
    }

    /// `ship`'s top speed (px/s) as this world flies it, strict-play bonus
    /// included — what a hyperspace arrival hurls the player in at.
    public func effectiveMaxSpeed(of ship: Ship) -> Double {
        let ledByPlayer = ship.isPlayerControlled || ship.brain?.leaderID == World.playerEntityID
        let factor = ledByPlayer && !strictPlay ? 1.5 : 1
        return ship.stats.maxSpeed * factor
    }

    /// Point defense (`Weapon_SelectTurretTargetWithinArc` 0x0043a310), once per
    /// raw call per ship. Only the ship's first ready Guidance 9/10 bank fires.
    /// Its reach is `range × 1.5` (mode 9) or `BeamLength` (mode 10), outside
    /// the turret blind spots. It picks the nearest homing shot in its normal
    /// state, vulnerable to PD (no `wëap` Flags 0x0080), that is aimed at this
    /// ship or its squad leader; with none, the nearest ship whose hull has
    /// Flags2 0x0008 and is attacking this ship or its leader. Mode 9 fires a
    /// real PD round (see `isPointDefenseRound`), mode 10 queues a beam that
    /// bites `Mass + trunc(Energy / 2)` off the missile's durability per call.
    /// The bank's cooldown grows by `Reload / mounted`.
    private func runPointDefense(rawCalls: Int) {
        guard rawCalls > 0 else { return }
        for ship in allShips where ship.isAlive && !ship.disabled && !ship.isEffectivelyCloaked {
            for _ in 0..<rawCalls {
                guard let mount = ship.weapons.first(where: {
                    $0.spec.isPointDefense && $0.ready
                        && (!ship.isEffectivelyCloaked || $0.spec.firesWhileCloaked)
                }) else { break }
                let spec = mount.spec
                let reach = spec.guidance == .pointDefense
                    ? (Double(Int(spec.range)) * 1.5).rounded(.down) : spec.beamLength
                let leader = ship.brain?.leaderID
                var bestShot: Projectile?
                var bestShip: Ship?
                var bestD = Double.greatestFiniteMagnitude
                for p in projectiles where p.alive && !p.visualOnly && p.guidance == .guided
                    && p.guidanceState == 0 && p.vulnerableToPD {
                    guard let tid = p.targetID, tid == ship.entityID || tid == leader else { continue }
                    let d = (p.position - ship.position).length
                    guard d <= reach, d < bestD,
                          !turretBlind(ship, spec: spec, bearing: OriginalMath.bearingRadians(from: ship.position, to: p.position)) else { continue }
                    bestD = d; bestShot = p
                }
                if bestShot == nil {
                    for other in allShips where other.entityID != ship.entityID && other.entityID != leader
                        && other.isAlive && !other.disabled && other.hullFlags2 & 0x0008 != 0
                        && canDetect(other, by: ship) {
                        // "Attacking" in the original's sense (0x0040faa0): a ship
                        // closing in to scan, parking or escorting is not.
                        // Reading the bare target made a Fed destroyer's PD
                        // open fire on a Fed scout that merely scanned it.
                        let attacking: Bool
                        if other.isPlayer {
                            attacking = other.currentTargetID == ship.entityID
                                || (leader != nil && other.currentTargetID == leader)
                        } else {
                            attacking = originalAI.isEngagedAgainst(other, ship, leader: leader, world: self)
                        }
                        guard attacking else { continue }
                        let d = (other.position - ship.position).length
                        guard d <= reach, d < bestD,
                              !turretBlind(ship, spec: spec, bearing: OriginalMath.bearingRadians(from: ship.position, to: other.position)) else { continue }
                        bestD = d; bestShip = other
                    }
                }
                guard bestShot != nil || bestShip != nil else { break }
                let aimPoint = bestShot?.position ?? bestShip!.position
                if spec.guidance == .pointDefense {
                    var aim = OriginalMath.bearingRadians(from: ship.position, to: aimPoint)
                    if let target = bestShip {
                        aim = leadAngle(from: ship.position, shooterVel: ship.velocity, target: target,
                                        spec: spec)
                    }
                    aim = wholeDegrees(aim)
                    if spec.inaccuracyDegrees > 0 {
                        aim += Double(rng.range(2 * spec.inaccuracyDegrees) - spec.inaccuracyDegrees) * .pi / 180
                    }
                    let round = spawnProjectile(spec: spec, muzzle: ship.position, aim: aim,
                                                ownerID: ship.entityID, ownerGovt: ship.government,
                                                ownerVelocity: ship.velocity, targetID: nil,
                                                subDepth: 0, shooter: ship)
                    round.isPointDefenseRound = true
                    round.pointDefenseBite = spec.armorDamage + (spec.shieldDamage / 2).rounded(.down)
                } else {
                    queueBeam(from: ship, mountIndex: ship.weapons.firstIndex { $0 === mount } ?? 0,
                              spec: spec, targetShipID: bestShip?.entityID, targetShot: bestShot)
                }
                mount.cooldown += spec.reloadSeconds / Double(max(1, mount.count))
                events.append(.weaponFired(shooterID: ship.entityID, at: ship.position,
                                           heading: (aimPoint - ship.position).angle,
                                           soundID: spec.fireSoundID, weaponID: spec.id))
            }
        }
    }

    // MARK: Weapons

    private func fireWeapons(from ship: Ship, intent: ControlIntent) {
        let primary = intent.firePrimary
        let secondary = intent.fireSecondary
        let anyTrigger = primary || secondary
        // NPCs only ever set `firePrimary`; it fires the one forward bank and
        // the one turret bank their selectors armed (AI-02).
        let isAI = ship.brain != nil
        updateBeamLoops(for: ship, primary: primary, secondary: secondary, isAI: isAI)
        guard anyTrigger, ship.isAlive, !ship.disabled else { return }
        let target = ship.currentTargetID.flatMap { self.ship(id: $0) }
        // AI-03: an NPC shooting at the player reloads slower while the
        // player's combat rating is low.
        let reloadScale = isAI && ship.currentTargetID == World.playerEntityID
            ? Self.ratingFireRamp(rating: livePlayerCombatRating, classZeroStrength: classZeroStrength) : 1
        let npcBanks = isAI ? (intent.npcMounts ?? npcSelectedMounts(for: ship, target: target)) : []

        for (mountIndex, mount) in ship.weapons.enumerated() {
            let spec = mount.spec
            // Point-defense mounts fire themselves via `runPointDefense`.
            if spec.isPointDefense { continue }
            if isAI && spec.guidance != .bay && !npcBanks.contains(mountIndex) { continue }
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
            // Seeker 0x0020: the reload stays pinned while ionized (see regen).
            if spec.cantFireWhileIonized,
               ship.isPlayerControlled ? ship.ionCharge > 0 : ship.isIonized {
                mount.cooldown = 1 / OriginalClock.ticksPerSecond
                continue
            }
            // Reload not ready / dry on ammo: the classic invisible "why didn't
            // my weapon fire" bug. Logged once per block-reason transition.
            guard mount.ready else {
                mount.logBlockedIfNeeded(for: ship)
                continue
            }
            // NPC firing envelope (`Weapon_FireShipWeapons` 0x00414550): a beam
            // needs the target within `BeamLength + 32` px on both axes, a turret
            // or quadrant gun within `range + 32`; unguided guns, rockets and
            // homing launchers fire whenever the AI pulls the trigger.
            if isAI, let target, let envelope = Self.npcFireEnvelope(spec) {
                let d = target.position - ship.position
                guard abs(d.x) < envelope, abs(d.y) < envelope else { continue }
            }
            // Flags2 0x0100: "AI ships won't use this weapon" — player-only
            // ordnance an NPC may be carrying but will never actually fire.
            // (wëap Flags 0x0008 is only the AI's guided-bank track check,
            // `npcGuidedBank`; neither fire path reads it, B-4.)
            if isAI && spec.aiWontUse { continue }
            // Flags2 0x0080: a `KeyCarried`-linked weapon only works while at
            // least one ship of the carrier's key type is still aboard.
            if spec.requiresKeyCarriedAboard && !ship.carriesKeyShip { continue }
            // Flags2 0x4000 (inverted): firing an ordinary weapon drops the
            // ship's cloak. A cloaked ship holds fire with everything that
            // isn't explicitly cleared to fire cloaked, rather than decloaking
            // itself by accident.
            if ship.isCloaked && !spec.firesWhileCloaked { continue }
            // Flags3 0x0004: hold fire while a previous shot of this same weapon
            // is still aloft (owned by this ship).
            if spec.cantRefireUntilShotEnds,
               projectiles.contains(where: { $0.alive && $0.ownerID == ship.entityID && $0.weaponID == spec.id }) {
                continue
            }
            // AmmoType ≤ -1000: a fuel-burning weapon can't fire without the fuel.
            if spec.fuelPerShot > 0 && ship.fuel < spec.fuelPerShot { continue }

            // Fighter bays (`wëap` Guidance 99) don't fire projectiles — the
            // player's secondary trigger launches a docked fighter (OS-03).
            // NPC carriers launch through `updateFighterBays`.
            if spec.guidance == .bay {
                guard !isAI else { continue }
                launchPlayerBayFighter(from: ship, mount: mount)
                continue
            }

            // A Reload-0 weapon may fire on every raw call (WP-20).
            let volleys = spec.reloadSeconds <= 0 ? max(1, rawCallsThisStep) : 1
            var fired = 0
            var charged = 0
            for _ in 0..<volleys {
                guard mount.ready, canFireBank(ship, mount) else { break }
                // B-10: each simultaneous barrel re-checks CanFire, so a
                // volley never fires more rounds (or fuel shots) than remain.
                let shotsThisVolley = fireVolley(from: ship, mount: mount, mountIndex: mountIndex,
                                                 spec: spec, target: target,
                                                 limit: volleyAllowance(ship, mount))
                guard shotsThisVolley > 0 else { break }
                fired += shotsThisVolley
                charged += mount.didFire(shots: shotsThisVolley, reloadScale: reloadScale)
                if spec.reloadSeconds > 0 { break }
            }
            // Only spend the reload/ammo if a shot actually left (a turret with no
            // target produces `fired == 0` and stays ready).
            guard fired > 0 else { continue }
            applyRecoil(to: ship, spec: spec)
            // AmmoType ≤ -1000: burn fuel per shot instead of drawing ammo.
            if spec.fuelPerShot > 0 {
                ship.fuel = max(0, ship.fuel - spec.fuelPerShot * Double(charged))
            }
            // AmmoType == -999: the firing ship self-destructs. Zeroing armor
            // makes it not-alive; the despawn / player-death path finalizes it
            // (explosion + shipDestroyed), same as any other kill.
            if spec.selfDestructsOnFire {
                ship.shield = 0
                ship.armor = 0
            }
            // Flags3 0x0020 (exclusive): every other bank waits until this
            // one's cooldown plus two ticks (0x00575040).
            if spec.isExclusive {
                let hold = mount.cooldown + 2 / OriginalClock.ticksPerSecond
                for other in ship.weapons where other !== mount && other.cooldown < hold {
                    other.cooldown = hold
                }
            }
        }
    }

    /// One volley of `mount`: a single barrel, or every barrel for a
    /// fire-simultaneously weapon. Returns the shots that left.
    private func fireVolley(from ship: Ship, mount: WeaponMount, mountIndex: Int,
                            spec: WeaponSpec, target: Ship?, limit: Int = .max) -> Int {
        let barrels = max(1, mount.count)
        let shots = min(spec.fireSimultaneously ? barrels : 1, max(0, limit))
        var fired = 0
        for k in 0..<shots {
            // Flags3 0x0010: fire from the exit point closest to the target
            // (when there is one); otherwise the ship's own cursor for this
            // exit type, which starts on a random quadrant and steps +1 mod 4
            // per shot (`Weapon_SelectTurretQuadrant` 0x0046c320, WP-25).
            _ = k
            let exitIndex: Int
            if spec.firesFromClosestExit, let target {
                exitIndex = ship.closestExitIndex(exitType: spec.exitType, to: target.position)
                // The per-type cursor still steps: a shot stores best + 1
                // (0x0046c320), a beam advances its old cursor (0x00427a90).
                if spec.isBeam {
                    _ = nextExitQuadrant(ship, spec.exitType)
                } else if ship.exitPoints != nil, spec.exitType != .center {
                    ship.exitQuadrants[spec.exitType] = (exitIndex + 1) % 4
                }
            } else {
                exitIndex = nextExitQuadrant(ship, spec.exitType)
            }
            mount.exitCursor = exitIndex
            let muzzle = ship.muzzle(exitType: spec.exitType, index: exitIndex)
            // Nil = can't fire (turret/quadrant with no target in arc): hold fire.
            guard let aim = fireAngle(for: spec, ship: ship, muzzle: muzzle, target: target) else { continue }
            if spec.isBeam {
                let record = queueBeam(from: ship, mountIndex: mountIndex, spec: spec,
                                       targetShipID: spec.guidance == .beamTurret ? target?.entityID : nil,
                                       targetShot: nil, exitIndex: exitIndex)
                // Telemetry/audio (the renderer draws from `activeBeams`). The
                // fire sound goes once per volley, for every beam kind; wëap
                // Flags 0x0010 is applied by the mixer (0x00414550 / 0x00455150).
                events.append(.beam(shooterID: ship.entityID, mountIndex: mountIndex, from: muzzle,
                                    to: record?.lastEnd ?? muzzle + Vec2.heading(aim) * spec.beamLength,
                                    hit: record?.lastHit ?? false,
                                    soundID: fired == 0 ? spec.fireSoundID : nil, weaponID: spec.id))
            } else {
                let launchAim = parallelLaunchAim(aim, spec: spec, ship: ship, exitIndex: exitIndex)
                spawnProjectile(spec: spec, muzzle: muzzle, aim: launchAim,
                                ownerID: ship.entityID, ownerGovt: ship.government,
                                ownerVelocity: ship.velocity,
                                targetID: spec.homes ? ship.currentTargetID : nil,
                                subDepth: 0, shooter: ship)
                // One fire sound per volley, not per barrel (0x00414550).
                events.append(.weaponFired(shooterID: ship.entityID, at: muzzle, heading: launchAim,
                                           soundID: fired == 0 ? spec.fireSoundID : nil, weaponID: spec.id))
            }
            fired += 1
        }
        return fired
    }

    /// The ship's next exit quadrant for `type` (see `fireVolley`).
    private func nextExitQuadrant(_ ship: Ship, _ type: WeaponExitType) -> Int {
        let current = ship.exitQuadrants[type] ?? rng.range(4)
        ship.exitQuadrants[type] = (current + 1) % 4
        return current
    }

    /// A negative `Inaccuracy` is "parallel launch": no random spread, the shot
    /// leaves `|s|` degrees off the hull heading toward the side its exit point
    /// sits on (the class exit table's sign, 0x0041fd30). Returns `aim` as is
    /// otherwise.
    private func parallelLaunchAim(_ aim: Double, spec: WeaponSpec, ship: Ship, exitIndex: Int) -> Double {
        guard spec.inaccuracyDegrees < 0, let ep = ship.exitPoints else { return aim }
        let pts = ep.points(for: spec.exitType)
        guard !pts.isEmpty else { return aim }
        let x = pts[((exitIndex % pts.count) + pts.count) % pts.count].x
        guard x != 0 else { return aim }
        let offset = Double(-spec.inaccuracyDegrees) * .pi / 180
        return wholeDegrees(ship.angle) + (x > 0 ? offset : -offset)
    }

    /// The NPC firing envelope per axis for `spec`, or nil when it fires at
    /// any range (`Weapon_FireShipWeapons` 0x00414550).
    static func npcFireEnvelope(_ spec: WeaponSpec) -> Double? {
        switch spec.guidance {
        case .beam, .beamTurret: return spec.beamLength + 32
        case .turret, .frontQuadrant, .rearQuadrant: return (spec.range + 32).rounded(.down)
        default: return nil
        }
    }

    /// AI-03: the reload multiplier for an NPC whose target is the player,
    /// from the player's combat rating against class 0's Strength (×1.75 /
    /// 1.5 / 1.25 / 1.1 below Strength × 100 / 400 / 800 / 1600).
    static func ratingFireRamp(rating: Int, classZeroStrength: Int) -> Double {
        let s = classZeroStrength
        if rating < s * 100 { return 1.75 }
        if rating < s * 400 { return 1.5 }
        if rating < s * 800 { return 1.25 }
        if rating < s * 1600 { return 1.1 }
        return 1
    }

    /// The player's combat rating as it stands this instant: the host's
    /// synced value plus kills made since the last fold.
    public var livePlayerCombatRating: Int {
        CombatRatingRule.fold(playerCombatRating, adding: diplomacy?.combatRating ?? 0)
    }

    /// `shïp` 128's Strength — class 0, which the rating ramp is scaled by.
    var classZeroStrength: Int { galaxy?.game.ship(128)?.strength ?? 2 }

    /// The world angle a weapon fires at this frame given its guidance, or nil if
    /// it can't fire. Turrets (modes 3/4) and in-arc quadrant guns aim at the
    /// target (`Ship_AimWeaponPredictive` 0x0043b740 for projectiles); a turret
    /// whose bearing falls in a blind spot holds. A front-quadrant gun (7) with
    /// no target, or its target out of its 46° arc, dumb-fires along the nose
    /// for the player and holds for an NPC; a rear one (8) holds. Everything
    /// else fires along the whole-degree hull heading. The integer spread
    /// `rand(2s) − s` is added here, except for bombs (mode 5).
    private func fireAngle(for spec: WeaponSpec, ship: Ship, muzzle: Vec2, target: Ship?) -> Double? {
        let heading = wholeDegrees(ship.angle)
        var aim: Double
        switch spec.guidance {
        case .turret, .beamTurret:
            guard let t = target else { return nil }
            let bearing = OriginalMath.bearingRadians(from: ship.position, to: t.position)
            guard !turretBlind(ship, spec: spec, bearing: bearing) else { return nil }
            aim = spec.isBeam ? OriginalMath.bearingRadians(from: muzzle, to: t.position)
                              : leadAngle(from: muzzle, shooterVel: ship.velocity, target: t, spec: spec)
        case .frontQuadrant, .rearQuadrant:
            let rear = spec.guidance == .rearQuadrant
            let inArc: Bool
            if let t = target {
                let base = rear ? ship.angle + .pi : ship.angle
                inArc = abs(angleDelta(from: wholeDegrees(base), to: OriginalMath.bearingRadians(from: ship.position, to: t.position))) < 46 * .pi / 180
            } else {
                inArc = false
            }
            if let t = target, inArc {
                aim = leadAngle(from: muzzle, shooterVel: ship.velocity, target: t, spec: spec)
            } else if !rear && ship.brain == nil {
                aim = heading
            } else if !rear && target == nil {
                aim = heading
            } else {
                return nil
            }
        default:
            aim = heading
        }
        if spec.inaccuracyDegrees > 0, spec.guidance != .freefallBomb {
            aim += Double(rng.range(2 * spec.inaccuracyDegrees) - spec.inaccuracyDegrees) * .pi / 180
        }
        return aim
    }

    /// `Weapon_IsTargetBearingInTurretBlindSpot` (0x0046b360): a bearing under
    /// 46° from the nose is "front", under 136° "sides", else "rear"; the arc is
    /// blind if the weapon's Flags or the hull's Flags carry 0x1000 / 0x2000 /
    /// 0x4000 for it.
    func turretBlind(_ ship: Ship, spec: WeaponSpec, bearing: Double) -> Bool {
        let off = abs(angleDelta(from: wholeDegrees(ship.angle), to: wholeDegrees(bearing))) * 180 / .pi
        let bit = off < 46 ? 0x1000 : off < 136 ? 0x2000 : 0x4000
        let weaponBlind = bit == 0x1000 ? spec.flags.turretBlindFront
            : bit == 0x2000 ? spec.flags.turretBlindSides : spec.flags.turretBlindRear
        return weaponBlind || ship.hullFlags & bit != 0
    }

    enum FireQuadrant { case front, sides, rear }

    /// `angle` truncated to the whole degree the original stores.
    func wholeDegrees(_ angle: Double) -> Double {
        var deg = (angle * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        return (deg + 1e-9).rounded(.down) * .pi / 180
    }

    /// `Ship_AimWeaponPredictive` (0x0043b740): one-step lead. The shot's time
    /// to target is `distance / speed` (a rocket's `(d − 19.59 v) / v + 2.067`
    /// beyond 19.59 speeds, else `d / (0.316 v)`), and the aim point is the
    /// target moved that long at its velocity relative to the shooter's.
    /// Returns a whole-degree bearing.
    func leadAngle(from origin: Vec2, shooterVel: Vec2, target: Ship, spec: WeaponSpec) -> Double {
        let rel = target.position - origin
        let speed = spec.speedPerTick
        guard speed > 0 else { return OriginalMath.bearingRadians(of: rel) }
        let dist = rel.length
        let ticks: Double
        if spec.guidance == .rocket {
            ticks = dist > speed * 19.59 ? (dist - speed * 19.59) / speed + 2.066666666666667
                                         : dist / (speed * 0.316)
        } else {
            ticks = dist / speed
        }
        let relVelPerTick = (target.velocity - shooterVel) * (1 / OriginalClock.ticksPerSecond)
        return OriginalMath.bearingRadians(of: rel + relVelPerTick * ticks)
    }

    /// Kept for the stellar batteries' callers: lead with a raw shot speed.
    func leadAngle(from origin: Vec2, shooterVel: Vec2, target: Ship,
                   shotSpeed: Double, instantHit: Bool) -> Double {
        let rel = target.position - origin
        guard !instantHit, shotSpeed > 0 else { return OriginalMath.bearingRadians(of: rel) }
        let t = rel.length / shotSpeed
        return OriginalMath.bearingRadians(of: rel + (target.velocity - shooterVel) * t)
    }

    /// Build and register a projectile (`Shot_SpawnShotFromWeapon` 0x0041fd30).
    ///
    /// A ship's shot starts at its velocity plus `Speed` along `aim` — except
    /// the player's bombs (mode 5), which keep 0.8 × the ship's velocity, and
    /// the player's rockets (mode 6), which start at the ship's velocity and
    /// blend toward `Speed` in flight. A homing shot's velocity is replaced by
    /// its guidance every tick. A submunition (`subDepth > 0`) starts from
    /// rest, except a rocket, which keeps its parent's velocity. A bomb's
    /// spread is applied after its velocity, to the sprite alone. Modes 4 and 9
    /// roll the turret tracking roll (WP-26).
    @discardableResult
    func spawnProjectile(spec: WeaponSpec, muzzle: Vec2, aim: Double,
                         ownerID: Int, ownerGovt: Int, ownerVelocity: Vec2,
                         targetID: Int?, subDepth: Int, shooter: Ship? = nil) -> Projectile {
        let dir = Vec2.heading(aim)
        let homing = spec.homes
        let accelerating = spec.accelerates
        let ownerIsPlayer = shooter?.isPlayerControlled ?? false
        var vel = ownerVelocity
        if subDepth > 0 && spec.guidance != .rocket { vel = Vec2() }
        let skipsLaunchSpeed = ownerIsPlayer && subDepth == 0
            && (spec.guidance == .freefallBomb || spec.guidance == .rocket)
        if ownerIsPlayer && subDepth == 0 && spec.guidance == .freefallBomb { vel = vel * 0.8 }
        if !skipsLaunchSpeed { vel += dir * spec.projectileSpeed }
        if homing { vel = dir * spec.projectileSpeed }
        var facing = aim
        if spec.guidance == .freefallBomb, spec.inaccuracyDegrees > 0 {
            facing += Double(rng.range(2 * spec.inaccuracyDegrees) - spec.inaccuracyDegrees) * .pi / 180
        }
        let lifeTicks = spec.lifeTicks > 0 ? spec.lifeTicks : spec.range / max(1, spec.speedPerTick)
        let p = Projectile(position: muzzle, velocity: vel, life: lifeTicks / OriginalClock.ticksPerSecond,
                           shieldDamage: spec.shieldDamage, armorDamage: spec.armorDamage,
                           blastRadius: spec.blastRadius, ownerID: ownerID, ownerGovt: ownerGovt,
                           homing: homing, turnRate: spec.turnRate, speed: spec.projectileSpeed,
                           targetID: homing ? targetID : nil,
                           vulnerableToPD: spec.vulnerableToPD, ionization: spec.ionization,
                           accelerating: accelerating, facing: facing,
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
                           translucentShots: spec.translucentShots, flags: spec.flags)
        p.ionizeColor = spec.ionizeColor
        p.guidance = spec.guidance == .unguided && spec.isGuided ? .guided : spec.guidance
        p.lifeTicks = lifeTicks
        p.decayInterval = spec.decayTicks
        p.animFrameDelayTicks = spec.animFrameDelayTicks
        p.animFlags2 = spec.animFlags2
        p.headingDegrees = wholeDegrees(facing) * 180 / .pi
        p.turnDegreesPerTick = spec.turnDegreesPerTick
        p.hitsAnyShip = spec.hitsAnyShip
        p.subsOnExpire = !spec.noSubmunitionsOnExpire
        p.bigExplosion = spec.explosionIsBig
        p.expiryBlast = spec.detonateOnExpire && spec.blastRadius > 0 && !spec.isPlanetTypeWeapon
        // The shot's target slot: the shooter's primary target, a
        // submunition's own target.
        p.shotTargetID = subDepth == 0 ? (shooter?.currentTargetID ?? targetID) : targetID
        // A1: an NPC boarding, or locked on a target it hasn't disabled yet,
        // fires non-lethal shots (0x0041fd30).
        if let shooter, !spec.disablesOnly {
            p.nonLethal = originalAI.shotIsNonLethal(shooter: shooter, target: p.shotTargetID.flatMap { ship(id: $0) })
        } else {
            p.nonLethal = spec.disablesOnly
        }
        p.ownerLeaderID = shooter?.brain?.leaderID
        p.jamLocks = spec.jamVulnerability.map { $0 > 0 ? rng.range($0 + 1) : 0 }
        if let shooter, subDepth == 0,
           spec.guidance == .turret || spec.guidance == .pointDefense {
            p.turretRoll = shooter.turretRating < 1 ? rng.range(100) + 1 : rng.range(shooter.turretRating) + 1
        }
        // Seeker 0x0008 (WP-10): in an interference system a homing shot may
        // launch confused — `rand(100 / scale) + 1 ≤ Interference` latches the
        // weave (state 999). The scale is the steady 0.63.
        if p.guidance == .guided, spec.confusedByInterference {
            let bound = max(1, Int(100 / OriginalClock.rawCallTickScale))
            if rng.range(bound) + 1 <= systemInterference { p.guidanceState = 999 }
        }
        // The shot pool holds 128 (0x0041fd30 returns -1 with no free slot): a
        // shot that finds it full is simply not fired.
        if projectiles.count < OriginalRendering.shotPoolSize { projectiles.append(p) }
        return p
    }

    /// `Ship_FindNearestHittableWeaponTarget` (0x0046ba30): the first ship, in
    /// slot order, that the shot may hit and that has the smallest distance
    /// `trunc|dx|² + trunc|dy|²` held in an Int16 (so it wraps negative past
    /// ~181 px per axis); a strictly smaller value is needed to replace it.
    private func nearestHostile(to pos: Vec2, shot: Projectile) -> Ship? {
        var best: Ship?
        var bestD: Int16 = 0
        for other in allShips where other.isAlive {
            guard canShotHit(shot, other) else { continue }
            let dx = Int16(truncatingIfNeeded: Int(abs(other.position.x.rounded(.towardZero) - pos.x.rounded(.towardZero))))
            let dy = Int16(truncatingIfNeeded: Int(abs(other.position.y.rounded(.towardZero) - pos.y.rounded(.towardZero))))
            let d = dx &* dx &+ dy &* dy
            if best == nil || d < bestD { bestD = d; best = other }
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
            // A continuous beam loops while its own fire group's trigger is held —
            // and, same as `fireWeapons`'s own `triggered` gate, a player's secondary
            // beam only loops while it's the *selected* secondary. Without this a
            // fitted-but-unselected secondary beam mount would start its loop
            // sound/visual (and read as "hitting") on the raw secondary trigger
            // alone, while `fireWeapons` correctly never fires it at all.
            let spec = mount.spec
            let held: Bool
            if isAI {
                held = primary || secondary
            } else if spec.isSecondary {
                held = secondary && spec.id == ship.effectiveSecondaryID
            } else {
                held = primary
            }
            let looping = ship.activeBeamLoopMounts.contains(idx)
            // A fuel-burning ("energy") beam only sustains a real beam while the
            // ship has fuel for a shot. Out of energy but still holding the
            // trigger, EV Nova doesn't fire a steady beam — the weapon coughs:
            // it flickers on/off and the sound stutters, but deals no damage.
            // We reproduce that by duty-cycling the real loop (below), which also
            // stutters its sound; the fuel guard in `fireWeapons` already blocks
            // the damage-dealing `fireBeam` while dry.
            let hasFuel = spec.fuelPerShot <= 0 || ship.fuel >= spec.fuelPerShot
            let wantOn: Bool
            if held && ship.isAlive {
                if hasFuel {
                    wantOn = true
                } else if mount.cooldown <= 0 {
                    // Phase elapsed: flip the flicker and hold the new phase for
                    // a beat (short "on" flash, slightly longer "off" gap).
                    wantOn = !looping
                    mount.cooldown = wantOn ? Self.dryBeamFlickerOn : Self.dryBeamFlickerOff
                } else {
                    wantOn = looping   // mid-phase: hold until the cooldown drains
                }
            } else {
                wantOn = false
            }
            if wantOn {
                if !looping {
                    ship.activeBeamLoopMounts.insert(idx)
                    events.append(.beamLoopStart(shooterID: ship.entityID, mountIndex: idx,
                                                 soundID: spec.fireSoundID))
                    spawnActiveBeam(for: ship, mount: mount, mountIndex: idx, continuous: true)
                }
            } else if looping {
                ship.activeBeamLoopMounts.remove(idx)
                events.append(.beamLoopStop(shooterID: ship.entityID, mountIndex: idx))
                removeActiveBeam(shooterID: ship.entityID, mountIndex: idx)
            }
        }
    }

    /// Duty cycle for an out-of-energy beam's flicker: a short bright "on" flash
    /// then a slightly longer "off" gap (~6 stutters/sec). Only used while a
    /// fuel-burning beam is held with too little fuel to actually fire.
    private static let dryBeamFlickerOn: Double = 0.06
    private static let dryBeamFlickerOff: Double = 0.10

    /// Stop any beam loops still active on `ship` — called wherever a ship
    /// stops being simulated (disabled, destroyed, landed, departed) since
    /// `fireWeapons` (the only other place loops stop) won't run for it again.
    private func stopAllBeamLoops(for ship: Ship) {
        guard !ship.activeBeamLoopMounts.isEmpty else { return }
        for idx in ship.activeBeamLoopMounts.sorted() {   // stable event order
            events.append(.beamLoopStop(shooterID: ship.entityID, mountIndex: idx))
            removeActiveBeam(shooterID: ship.entityID, mountIndex: idx)
        }
        ship.activeBeamLoopMounts.removeAll()
    }

    /// Recoil (`Weapon_FireShipWeapons` 0x00414550 / the player's 0x00455150):
    /// once per volley, `Recoil / mass` px/tick added toward the hull's rear,
    /// per axis up to its base top speed. The player recoils only for a
    /// positive value; an NPC for any value but −1 (a negative one pushes it
    /// forward).
    private func applyRecoil(to ship: Ship, spec: WeaponSpec) {
        guard spec.recoil != 0, ship.massTons > 0 else { return }
        if ship.isPlayerControlled && spec.recoil < 0 { return }
        let step = OriginalClock.perSecond(spec.recoil / ship.massTons)
        ship.addPolarVelocityWithClamp(heading: wholeDegrees(ship.angle) + .pi, step: step,
                                       max: ship.stats.maxSpeed)
    }

    /// One queued beam (`Shot_QueueBeamHit` 0x00427a90 /
    /// `Shot_UpdateBeamHitQueue` 0x0042f270): every fire of a beam bank adds a
    /// record that lives `Count` raw calls (plus `16 − CoronaFalloff` fading
    /// calls when `Decay > 0`) and, on every call it touches a ship, deals the
    /// weapon's full mass and energy damage — so a beam whose Count exceeds its
    /// Reload stacks records (the original's "machine-gun beam").
    final class BeamRecord {
        let shooterID: Int
        let mountIndex: Int
        let spec: WeaponSpec
        /// A turret beam (mode 3) tracks this ship; a PD beam this shot.
        let targetShipID: Int?
        weak var targetShot: Projectile?
        let exitIndex: Int
        var callsLeft: Int
        var fadeCallsLeft: Int
        /// Visual for a pulse beam (nil for a looping beam, whose persistent
        /// `ActiveBeam` already shows).
        var visual: ActiveBeam?
        /// Where the last call's sweep ended, and whether it touched anything.
        var lastEnd = Vec2()
        var lastHit = false
        /// The record's non-lethal byte (+0x20), fixed when it is queued.
        var nonLethal = false
        init(shooterID: Int, mountIndex: Int, spec: WeaponSpec, targetShipID: Int?,
             targetShot: Projectile?, exitIndex: Int) {
            self.shooterID = shooterID; self.mountIndex = mountIndex; self.spec = spec
            self.targetShipID = targetShipID; self.targetShot = targetShot
            self.exitIndex = exitIndex
            callsLeft = max(1, Int(spec.lifeTicks)); fadeCallsLeft = spec.beamFadeCalls
        }
    }

    @discardableResult
    private func queueBeam(from ship: Ship, mountIndex: Int, spec: WeaponSpec,
                           targetShipID: Int?, targetShot: Projectile?, exitIndex: Int? = nil) -> BeamRecord? {
        guard beamRecords.count < Self.beamRecordLimit else { return nil }
        let record = BeamRecord(shooterID: ship.entityID, mountIndex: mountIndex, spec: spec,
                                targetShipID: targetShipID, targetShot: targetShot,
                                exitIndex: exitIndex ?? (mountIndex < ship.weapons.count ? ship.weapons[mountIndex].exitCursor : 0))
        // A1: the record's non-lethal byte (0x00427a90) — the weapon's own
        // Flags2 0x1000, or an NPC locked on its not-yet-disabled primary
        // target; never for a beam aimed at a shot.
        record.nonLethal = spec.disablesOnly
            || (targetShot == nil && originalAI.beamIsNonLethal(
                shooter: ship, target: ship.currentTargetID.flatMap { self.ship(id: $0) }))
        if !spec.loopSound || spec.isPointDefense {
            let visual = ActiveBeam(shooterID: ship.entityID, mountIndex: mountIndex, weaponID: spec.id,
                                    from: ship.position, to: ship.position, hit: false,
                                    continuous: false, life: .infinity,
                                    maxLife: Double(record.callsLeft + record.fadeCallsLeft) * OriginalClock.rawCallSeconds,
                                    width: spec.beamWidth, color: spec.beamColor,
                                    coronaColor: spec.coronaColor, coronaFalloff: spec.coronaFalloff)
            record.visual = visual
            activeBeams.append(visual)
        }
        beamRecords.append(record)
        runBeamRecord(record)
        return record
    }

    /// The original's 64-slot beam queue.
    static let beamRecordLimit = 64

    /// Advance every beam record by this step's raw calls.
    private func stepBeamRecords(rawCalls: Int) {
        guard !beamRecords.isEmpty else { return }
        for _ in 0..<rawCalls {
            for record in beamRecords where record.callsLeft > 0 || record.fadeCallsLeft > 0 {
                if record.callsLeft > 0 { record.callsLeft -= 1 } else { record.fadeCallsLeft -= 1 }
                if record.callsLeft > 0 || record.fadeCallsLeft > 0 { runBeamRecord(record) }
            }
        }
        beamRecords.removeAll { record in
            let done = record.callsLeft <= 0 && record.fadeCallsLeft <= 0
            if done, let visual = record.visual { activeBeams.removeAll { $0 === visual } }
            return done
        }
    }

    /// One raw call of a beam record: aim, sweep, and damage whatever it
    /// touches. While fading (`callsLeft == 0`) it draws but no longer hurts.
    private func runBeamRecord(_ record: BeamRecord) {
        guard let ship = ship(id: record.shooterID), ship.isAlive else {
            record.callsLeft = 0; record.fadeCallsLeft = 0; return
        }
        let spec = record.spec
        let origin = ship.muzzle(exitType: spec.exitType, index: record.exitIndex)
        var angle: Double
        if spec.guidance == .pointDefenseBeam {
            guard let shot = record.targetShot, shot.alive else {
                if let tid = record.targetShipID, let t = self.ship(id: tid), t.isAlive {
                    angle = OriginalMath.bearingRadians(from: origin, to: t.position)
                    return castAndHitBeam(record, ship: ship, origin: origin, angle: angle)
                }
                record.callsLeft = 0; record.fadeCallsLeft = 0; return
            }
            angle = OriginalMath.bearingRadians(from: origin, to: shot.position)
            record.visual?.from = origin
            record.visual?.to = shot.position
            record.visual?.hit = true
            guard record.callsLeft > 0 else { return }
            // A PD beam bites `Mass + trunc(Energy / 2)` out of the shot's
            // durability each call; the shot dies once it can't absorb more.
            if shot.pdDurability < 1 {
                shot.alive = false
                events.append(.explosion(at: shot.position, radius: 10, soundID: nil, boomID: nil))
                record.callsLeft = 0
            } else {
                shot.pdDurability -= Int(spec.armorDamage + (spec.shieldDamage / 2).rounded(.down))
            }
            return
        }
        if spec.guidance == .beamTurret {
            guard let tid = record.targetShipID, let t = self.ship(id: tid), t.isAlive else {
                record.callsLeft = 0; record.fadeCallsLeft = 0; return
            }
            angle = OriginalMath.bearingRadians(from: origin, to: t.position)
        } else {
            angle = spriteFrameHeading(ship)
        }
        if spec.inaccuracyDegrees > 0 {
            angle += Double(rng.range(2 * spec.inaccuracyDegrees) - spec.inaccuracyDegrees) * .pi / 180
        }
        castAndHitBeam(record, ship: ship, origin: origin, angle: angle)
    }

    private func castAndHitBeam(_ record: BeamRecord, ship: Ship, origin: Vec2, angle: Double) {
        let spec = record.spec
        let dir = Vec2.heading(angle)
        let cast = beamCast(from: origin, dir: dir, range: spec.beamLength, ownerID: ship.entityID,
                            ownerGovt: ship.government, planetTypeOnly: spec.isPlanetTypeWeapon)
        let hit = cast.hitShip != nil || cast.hitAsteroid != nil || cast.hitStellar != nil
        if let visual = record.visual { visual.from = origin; visual.to = cast.end; visual.hit = hit }
        record.lastEnd = cast.end
        record.lastHit = hit
        guard record.callsLeft > 0 else { return }
        if let body = cast.hitStellar {
            applyStellarHit(body, shield: spec.shieldDamage, armor: spec.armorDamage, ownerID: ship.entityID)
        } else if let h = cast.hitShip {
            if spec.impact < 0, h.entityID != ship.entityID {
                applyBeamLock(owner: ship, victim: h, impact: spec.impact, hitPoint: cast.end)
            }
            applyHit(to: h, shield: spec.shieldDamage, armor: spec.armorDamage, ownerID: ship.entityID,
                     ionization: spec.ionization, ionizeColor: spec.ionizeColor,
                     piercing: spec.penetratesShields, weaponID: spec.id,
                     disablesOnly: record.nonLethal,
                     impact: spec.impact, impactFrom: origin, hitPoint: cast.end)
        } else if let rock = cast.hitAsteroid {
            applyAsteroidHit(rock, shield: spec.shieldDamage, armor: spec.armorDamage,
                             tenTimes: spec.tenTimesVersusAsteroids, shooterID: ship.entityID,
                             impact: spec.impact, from: origin)
        }
    }

    /// A fixed beam points along the hull's *sprite frame*: the heading
    /// quantized to the sheet's rotation frames (0x0042f270).
    private func spriteFrameHeading(_ ship: Ship) -> Double {
        let frames = max(1, ship.stats.rotationFrames)
        return Double(ship.spriteFrame % frames) * (2 * .pi / Double(frames))
    }

    /// A beam's sweep (`Shot_UpdateBeamHitQueue` 0x0042f270) from `origin`
    /// along unit `dir`, `range` px long. A ship is a candidate when its
    /// *centre* lies within `w/2 + range` of the muzzle and within
    /// `w × 10 / 32` degrees of the beam's bearing, `w` being 0.66 × its sprite
    /// width — so a beam can slip past the edge of a large hull (the "beam
    /// holes" quirk), and the bearing test doesn't wrap at north. The nearest
    /// candidate is hit, and the beam ends 0.2 sprite widths short of its
    /// centre. Beams ignore government: they spare only the shooter's own
    /// escorts and leader (and the player's squad, for a player-squad
    /// shooter), the escape pod, and ships of the other planet-type class.
    /// Asteroids and destroyable stellars use a plain distance-to-ray test.
    /// The owner is passed as id + government so a stellar battery can cast
    /// too.
    func beamCast(from origin: Vec2, dir: Vec2, range: Double, ownerID: Int, ownerGovt: Int,
                  planetTypeOnly: Bool = false)
        -> (end: Vec2, hitShip: Ship?, hitAsteroid: Asteroid?, hitStellar: StellarBody?) {
        var bestT = range
        var hitShip: Ship?
        var hitAsteroid: Asteroid?
        var hitStellar: StellarBody?
        let shooter = ship(id: ownerID)
        let shooterInPlayerSquad = shooter.map { isPlayerFleetMember($0.entityID) } ?? false
        let beamDeg = Int((wholeDegrees(dir.angle) * 180 / .pi).rounded())
        var bestShipDist = Double.greatestFiniteMagnitude
        for other in allShips where other.entityID != ownerID && other.isAlive
            && other.shipTypeID != Ship.escapePodShipID && other.isPlanetTypeShip == planetTypeOnly {
            if let shooter {
                if other.brain?.leaderID == shooter.entityID { continue }
                if shooter.brain?.leaderID == other.entityID { continue }
                if shooterInPlayerSquad && isPlayerFleetMember(other.entityID) { continue }
                if other.isPlayerControlled, shooter.isPlayerControlled, !pvpAllowed { continue }
            }
            let w = (2 * other.radius * 0.66).rounded()
            let reach = w / 2 + range
            let rel = other.position - origin
            let d = rel.length
            guard d <= reach else { continue }
            let bearing = OriginalMath.bearing(from: origin, to: origin + rel)
            guard Double(abs(bearing - beamDeg)) <= (w * 10 / 32).rounded(.towardZero) else { continue }
            if d < bestShipDist { bestShipDist = d; hitShip = other }
        }
        if let h = hitShip { bestT = max(0, bestShipDist - 2 * h.radius * 0.2) }
        if !planetTypeOnly {
            for rock in asteroids where rock.isAlive {
                let rel = rock.position - origin
                let along = rel.dot(dir)
                guard along > 0, along <= range else { continue }
                let perp = (rel - dir * along).length
                if perp <= rock.radius + 4 && along < bestT {
                    bestT = along; hitAsteroid = rock; hitShip = nil; hitStellar = nil
                }
            }
        }
        // Only a planet-type beam can connect with a stellar (Bible, `wëap.Flags2`
        // 0x0400) — an ordinary beam sweeping across a planet must not damage it.
        if planetTypeOnly {
            for body in destroyableStellars {
                let rel = body.position - origin
                let along = rel.dot(dir)
                guard along > 0, along <= range else { continue }
                let perp = (rel - dir * along).length
                if perp <= body.radius + 4 && along < bestT {
                    bestT = along; hitStellar = body; hitShip = nil; hitAsteroid = nil
                }
            }
        }
        let anyHit = hitShip != nil || hitAsteroid != nil || hitStellar != nil
        let end = anyHit ? origin + dir * bestT : origin + dir * range
        return (end, hitShip, hitAsteroid, hitStellar)
    }

    /// Create the persistent beam segment for a continuous mount (geometry is
    /// filled in immediately and refreshed every frame by `refreshActiveBeams`).
    private func spawnActiveBeam(for ship: Ship, mount: WeaponMount, mountIndex: Int, continuous: Bool) {
        guard !activeBeams.contains(where: { $0.shooterID == ship.entityID && $0.mountIndex == mountIndex }) else { return }
        let beam = ActiveBeam(shooterID: ship.entityID, mountIndex: mountIndex,
                              weaponID: mount.spec.id, from: ship.position, to: ship.position, hit: false,
                              continuous: continuous, life: .infinity,
                              width: mount.spec.beamWidth, color: mount.spec.beamColor,
                              coronaColor: mount.spec.coronaColor, coronaFalloff: mount.spec.coronaFalloff)
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
        // The same aim the damaging records use (`runBeamRecord`), without the
        // per-call spread: a turret beam tracks its target, a fixed one lies
        // along the hull's sprite frame.
        let target: Ship? = ship.currentTargetID.flatMap { self.ship(id: $0) }.flatMap { $0.isAlive ? $0 : nil }
        let aim = spec.guidance == .beamTurret && target != nil
            ? OriginalMath.bearingRadians(from: origin, to: target!.position) : spriteFrameHeading(ship)
        let cast = beamCast(from: origin, dir: Vec2.heading(aim), range: spec.beamLength,
                            ownerID: ship.entityID, ownerGovt: ship.government,
                            planetTypeOnly: spec.isPlanetTypeWeapon)
        beam.from = origin
        beam.to = cast.end
        beam.hit = cast.hitShip != nil || cast.hitAsteroid != nil || cast.hitStellar != nil
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

    /// Weapon → asteroid (WP-18): the rock's integrity loses the weapon's
    /// *energy* damage (× 10 with `wëap` Flags2 0x8000); mass damage does
    /// nothing. It breaks once integrity goes below zero. A surviving rock is
    /// nudged by `impact / mass` px/tick — along the shot's own heading for a
    /// shot (A7, 0x00436ff0), else away from the hit — through the
    /// axis-clamped polar add, then each axis clamped to ±2 px/tick.
    func applyAsteroidHit(_ rock: Asteroid, shield: Double, armor: Double, tenTimes: Bool = false,
                          shooterID: Int, impact: Double = 0, from: Vec2? = nil, shotHeading: Double? = nil) {
        rock.hp -= shield * (tenTimes ? 10 : 1)
        if rock.hp < 0 {
            destroyAsteroid(rock, killerID: shooterID)
        } else if impact != 0, rock.mass > 0, let from {
            let heading = shotHeading.map(wholeDegrees) ?? OriginalMath.bearingRadians(from: from, to: rock.position)
            let dir = Vec2.heading(heading)
            let step = OriginalClock.perSecond(impact / rock.mass)
            let cap = OriginalClock.perSecond(2)
            func axis(_ capShare: Double, _ delta: Double, _ cur: Double) -> Double {
                if delta <= 0 || capShare <= 0 {
                    if delta < 0 && capShare < 0 { return capShare < cur ? cur + delta : cur }
                    return cur + delta
                }
                return cur < capShare ? cur + delta : cur
            }
            let v = Vec2(axis(dir.x * cap, dir.x * step, rock.velocity.x),
                         axis(dir.y * cap, dir.y * step, rock.velocity.y))
            rock.velocity = Vec2(max(-cap, min(cap, v.x)), max(-cap, min(cap, v.y)))
        }
    }

    /// A7 (0x00436ff0): a player's blast shot striking a rock also hits every
    /// ship within BlastRadius on both axes at full damage — not planet-type
    /// hulls, not a planet-type weapon, and the player only with wëap Flags
    /// 0x0100 clear. An NPC's shot never splashes here. The weapon's hit
    /// particles spray at the impact.
    func splashFromAsteroidHit(_ p: Projectile) {
        if (galaxy?.game.weapon(p.weaponID)?.hitParticles.count ?? 0) > 0 {
            emit(.armorHit(at: p.position, weaponID: p.weaponID))
        }
        guard p.ownerID == Self.playerEntityID, p.blastRadius > 0, !p.flags.isPlanetTypeWeapon else { return }
        let r = p.blastRadius.rounded(.towardZero)
        for s in allShips where s.isAlive && !s.isPlanetTypeShip {
            if s.entityID == p.ownerID && p.flags.blastSparesPlayer { continue }
            guard abs(s.position.x - p.position.x) <= r, abs(s.position.y - p.position.y) <= r else { continue }
            applyHit(to: s, shield: p.baseShieldDamage, armor: p.baseArmorDamage, ownerID: p.ownerID,
                     ionization: p.ionization, ionizeColor: p.ionizeColor,
                     piercing: p.penetratesShields, weaponID: p.weaponID,
                     disablesOnly: p.nonLethal, impact: p.impact, impactFrom: p.position)
        }
    }

    // MARK: Projectiles

    /// One step of every shot (`Shot_HandleShot` 0x00435830 with
    /// `Shot_UpdateShotGuidance` 0x00431530 and `Shot_ResolveCollisions`
    /// 0x00437e20). A shot lives `Count` ticks and decays a point of damage
    /// each time `Decay` ticks pass. Its guidance runs (`stepGuidance`), it
    /// moves, and then it may connect: a shot with a proximity fuse detonates
    /// within `trunc(ProxRadius + 0.333 × width)` of a ship it may hit (that
    /// pass also releases submunitions), and otherwise by touching one, which
    /// does not. Neither works before `ProxSafety` ticks have passed.
    private func stepProjectiles(_ dt: Double, rawCalls: Int) {
        // Submunitions spawned this frame are collected and appended after the
        // loop so we don't mutate `projectiles` while iterating it.
        var spawned: [Projectile] = []
        let ticks = dt * OriginalClock.ticksPerSecond
        for p in projectiles where p.alive {
            // Co-op visual echo (client): fly straight on its velocity and expire,
            // no collision/damage/submunitions — the real shot lives on the
            // authority and its damage rides ship-health sync.
            if p.visualOnly {
                if p.spinShots { advanceShotAnimation(p, rawCalls: rawCalls) }
                p.facing = p.velocity.angle
                p.position += p.velocity * dt
                p.life -= dt
                if p.life <= 0 { p.alive = false }
                continue
            }
            p.proxSafetyRemaining = max(0, p.proxSafetyRemaining - dt)
            p.ageTicks += ticks
            p.life -= dt
            // Decay: one point per `Decay` ticks, counted per raw call.
            if p.decayInterval > 0 {
                for _ in 0..<rawCalls {
                    p.decayTimer += OriginalClock.rawCallTickScale
                    if p.decayTimer > p.decayInterval { p.decayTimer = 0; p.decayPoints += 1 }
                }
            }
            p.shieldDamage = p.decayedShieldDamage
            p.armorDamage = p.decayedArmorDamage
            if p.life <= 0 {
                p.alive = false
                expire(p, spawned: &spawned)
                continue
            }
            // A homing shot whose target died goes inert (state 998): it flies
            // on and can hit nothing.
            if p.guidance == .guided, p.guidanceState == 0, let tid = p.targetID,
               ship(id: tid)?.isAlive != true {
                p.guidanceState = 998
                p.targetID = nil
            }
            stepGuidance(p, dt: dt, ticks: ticks, rawCalls: rawCalls)
            if p.spinShots { advanceShotAnimation(p, rawCalls: rawCalls) }
            // Remember where the shot was so collision can sweep the whole path it
            // covered this frame, not just its endpoint — a fast shot moves many
            // times a small ship's radius per frame and would otherwise tunnel
            // clean through it (the "shots pass through and never hit" bug).
            let prevPos = p.position
            p.position += p.velocity * dt

            guard p.guidanceState != 998, p.proxSafetyRemaining <= 0 else { continue }

            // Destroyable stellars (`spöb.Strength` > 0) are real targets — but
            // only for a planet-type weapon (`wëap.Flags2` 0x0400).
            if p.flags.isPlanetTypeWeapon,
               let body = destroyableStellarHit(from: prevPos, to: p.position, reach: p.proxRadius) {
                applyStellarHit(body, shield: p.shieldDamage, armor: p.armorDamage, ownerID: p.ownerID)
                p.alive = false
                explode(p, at: p.position)
                continue
            }

            // A point-defense round (mode 9) collides only with homing shots,
            // friend or foe (0x00438630): a shot with durability left loses the
            // round's bite, one without dies.
            if p.isPointDefenseRound {
                for m in projectiles where m.alive && m !== p && m.guidance == .guided && !m.visualOnly
                    && Self.segmentPointDistance(prevPos, p.position, m.position) <= 6 {
                    if m.pdDurability > 0 {
                        m.pdDurability -= Int(p.pointDefenseBite)
                    } else {
                        m.alive = false
                        events.append(.explosion(at: m.position, radius: 10, soundID: nil, boomID: nil))
                    }
                    p.alive = false
                    break
                }
                guard p.alive else { continue }
            }

            var struck: Ship?
            var byProximity = false
            if p.proxRadius > 0 {
                // A8: the fuse tests the shot's whole-pixel position against
                // each ship's, per axis (0x00437e20).
                for other in allShips where other.isAlive && canShotHit(p, other) {
                    let fuse = (p.proxRadius + 0.333 * hullFrameWidth(other)).rounded(.towardZero)
                    let dx = other.position.x.rounded(.towardZero) - p.position.x.rounded(.towardZero)
                    let dy = other.position.y.rounded(.towardZero) - p.position.y.rounded(.towardZero)
                    if dx * dx + dy * dy <= fuse * fuse {
                        struck = other; byProximity = true; break
                    }
                }
            }
            if struck == nil, !p.isPointDefenseRound {
                if galaxy == nil {
                    // No sprite data (hand-built test worlds): the round outline.
                    for other in allShips where other.isAlive && canShotHit(p, other) {
                        if Self.segmentPointDistance(prevPos, p.position, other.position) <= other.radius {
                            struck = other; break
                        }
                    }
                } else {
                    struck = spriteContact(p, from: prevPos, rawCalls: rawCalls)
                }
            }
            if let h = struck {
                p.alive = false
                resolveHit(p, on: h, linkedShots: byProximity, spawned: &spawned)
                continue
            }

            // Seeker 0x0001 "passes over asteroids": this shot ignores rocks
            // entirely rather than colliding with them. A planet-type weapon
            // likewise only cares about stellars.
            if !p.flags.passesOverAsteroids && !p.flags.isPlanetTypeWeapon {
                // A8: the proximity fuse trips on a rock whose centre is within
                // ProxRadius by whole pixels per axis — no rock radius — and
                // only Seeker 0x0001 turns it off (the original never reads
                // wëap Flags2 0x0004). A contact hit needs the rock itself.
                let prox = p.proxRadius.rounded(.towardZero)
                for rock in asteroids where rock.isAlive {
                    let dx = abs(rock.position.x - p.position.x).rounded(.towardZero)
                    let dy = abs(rock.position.y - p.position.y).rounded(.towardZero)
                    let fused = prox > 0 && dx * dx + dy * dy <= prox * prox
                    if fused || Self.segmentPointDistance(prevPos, p.position, rock.position) <= rock.radius {
                        splashFromAsteroidHit(p)
                        applyAsteroidHit(rock, shield: p.baseShieldDamage, armor: p.baseArmorDamage,
                                         tenTimes: p.flags.tenTimesVersusAsteroids, shooterID: p.ownerID,
                                         impact: p.impact, from: p.position, shotHeading: p.facing)
                        p.alive = false
                        explode(p, at: p.position)
                        break
                    }
                }
            }
        }
        projectiles.append(contentsOf: spawned.prefix(max(0, OriginalRendering.shotPoolSize - projectiles.count)))
        projectiles.removeAll { !$0.alive }
        asteroids.removeAll { !$0.isAlive }
    }

    /// A ship's frame width for the proximity fuse (`Sprite_GetFrameFullWidth`
    /// 0x00462390): its hull sprite's width, or its diameter without sprite data.
    func hullFrameWidth(_ ship: Ship) -> Double {
        if let hull = galaxy?.hullCollisionMask(ship.shipTypeID) { return Double(hull.mask.width) }
        return 2 * ship.radius
    }

    /// Steps a cycling shot sprite one frame per `animFrameDelayTicks`, per raw
    /// call (`Shot_HandleShot` 0x00435830). It wraps to frame 0, or holds on
    /// the last frame with `wëap.Flags2` 0x0002; with Flags2 0x0001 it shows
    /// frame 0 while ProxSafety runs (and with both bits restarts from there).
    func advanceShotAnimation(_ p: Projectile, rawCalls: Int) {
        guard let spin = p.graphicSpinID,
              let count = galaxy?.shotCollisionMask(spinID: spin)?.frameCount, count > 0 else { return }
        for _ in 0..<rawCalls {
            p.animElapsed += OriginalClock.rawCallTickScale
            if p.animFrameDelayTicks < 1 || p.animElapsed >= p.animFrameDelayTicks {
                p.animFrame += 1
                p.animElapsed = 0
            }
            if p.animFrame >= count { p.animFrame = p.animFlags2 & 0x0002 == 0 ? 0 : count - 1 }
            if p.animFlags2 & 0x0003 == 0x0003, p.proxSafetyRemaining > 0 { p.animFrame = 0 }
        }
    }

    /// The frame of a shot's sprite the original draws, and so collides with:
    /// the heading frame for a static sprite, the cycling frame for a spin shot.
    func shotSpriteFrame(_ p: Projectile, frameCount: Int) -> Int {
        guard frameCount > 1 else { return 0 }
        if !p.spinShots { return SpriteFrames.headingFrame(degrees: p.headingDegrees, frames: frameCount) }
        if p.animFlags2 & 0x0001 != 0, p.proxSafetyRemaining > 0 { return 0 }
        return min(max(0, p.animFrame), frameCount - 1)
    }

    /// Direct shot → ship contact (WP-17, `Ship_HandleSpritePairCollision`
    /// 0x004374f0). The original moves a shot and tests it once per raw call,
    /// at that call's position — no swept path, so a fast shot can skip past
    /// a small hull. At each of this step's raw-call positions every ship the
    /// shot may hit is tested in order: a hull frame ≤ 32 px wide by the
    /// strict bounding circle (0x00475be0), a wider one by the opaque pixels
    /// of both frames (0x00475c80). A ship with no sprite data falls back to
    /// the swept circle.
    func spriteContact(_ p: Projectile, from prev: Vec2, rawCalls: Int) -> Ship? {
        let shotMask = p.graphicSpinID.flatMap { galaxy?.shotCollisionMask(spinID: $0) }
        let shotFrame = shotMask.map { shotSpriteFrame(p, frameCount: $0.frameCount) } ?? 0
        let calls = max(1, rawCalls)
        let travel = p.position - prev
        for k in 1...calls {
            let pos = k == calls ? p.position : prev + travel * (Double(k) / Double(calls))
            let shot = ContactSprite.shot(shotMask, frame: shotFrame, at: pos)
            for other in allShips where other.isAlive && canShotHit(p, other) {
                guard let hull = galaxy?.hullCollisionMask(other.shipTypeID) else {
                    if k == calls, Self.segmentPointDistance(prev, p.position, other.position) <= other.radius {
                        return other
                    }
                    continue
                }
                let ship = ContactSprite.hull(hull.mask, frame: hull.frame(angle: other.angle), at: other.position)
                guard SpriteContact.boundsOverlap(ship, shot) else { continue }
                if SpriteContact.shotTouchesShip(ship: ship, shot: shot) { return other }
            }
        }
        return nil
    }

    /// `Shot_UpdateShotGuidance` (0x00431530) for one step.
    ///
    /// - A homing shot (mode 1) steers by pure pursuit — straight at its
    ///   target, no lead — but only once it is older than 15 raw calls (15 ×
    ///   the 0.63 tick scale); it then turns `GuidedTurn × 0.1`° a tick, and
    ///   only while the bearing is further off than one turn, so it holds
    ///   rather than overshooting. Its velocity is `Speed` along its heading
    ///   every tick. While its target jams it on any channel
    ///   (`jamScore > 100 − lock`), it flies straight but keeps the target
    ///   (Seeker 0x0010 instead turns it away); a Seeker 0x8000 shot then
    ///   turns on its owner at 1/500 per raw call. Losing sight of a cloaked
    ///   target also flattens the turn (1/1000 per raw call for 0x8000).
    ///   Seeker 0x4000 drops a target within 250 px that sits more than 45°
    ///   off the nose. Seeker 0x0002 lets an asteroid within 200 px per axis
    ///   and 16° of the nose steal the lock, 1 in 10 per raw call.
    /// - State 999 (interference, WP-10) weaves ±`GuidedTurn` a raw call on a
    ///   300-call phase once 15 ticks old.
    /// - A rocket (mode 6) blends its velocity `v = (95 v + 5 × Speed) / 100`
    ///   along its heading each raw call; a bomb (mode 5) turns its sprite 1°
    ///   a raw call toward its velocity.
    private func stepGuidance(_ p: Projectile, dt: Double, ticks: Double, rawCalls: Int) {
        func setHeading(_ deg: Double) {
            var d = deg.truncatingRemainder(dividingBy: 360)
            if d < 0 { d += 360 }
            p.headingDegrees = d
            p.facing = d * .pi / 180
        }
        func flyAtSpeed() { p.velocity = Vec2.heading(p.facing) * p.speed }
        func bearingDegrees(to point: Vec2) -> Double {
            (OriginalMath.bearingRadians(from: p.position, to: point) * 180 / .pi)
        }
        /// Signed shortest turn from heading to `target`, whole degrees.
        func delta(to target: Double) -> Double {
            var d = (target - p.headingDegrees.rounded(.down)).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            return d
        }
        switch p.guidance {
        case .guided:
            switch p.guidanceState {
            case 0:
                var turn = p.turnDegreesPerTick
                let target = p.targetID.flatMap { ship(id: $0) }
                let desired = target.map { bearingDegrees(to: $0.position) } ?? p.headingDegrees.rounded(.down)
                if p.ageTicks > 15 * OriginalClock.rawCallTickScale {
                    if let t = target {
                        let jam = jamScores(of: t)
                        if (0..<4).contains(where: { p.jamLocks[$0] > 0 && jam[$0] > 100 - p.jamLocks[$0] }) {
                            if turn > 0 { turn = p.turnsAwayIfJammed ? -turn : 0 }
                            if p.flags.mayAttackParentIfJammed, oneIn(500, rawCalls: rawCalls) {
                                retargetOwner(p)
                            }
                        }
                    }
                    if let t = p.targetID.flatMap({ ship(id: $0) }), let owner = ship(id: p.ownerID),
                       !canDetect(t, by: owner) {
                        turn = 0
                        if p.flags.mayAttackParentIfJammed, oneIn(1000, rawCalls: rawCalls) { retargetOwner(p) }
                    }
                    if p.flags.losesLockOffBoresight, let t = p.targetID.flatMap({ ship(id: $0) }) {
                        let rel = t.position - p.position
                        if abs(rel.x) < 250, abs(rel.y) < 250,
                           abs(angleDelta(from: p.facing, to: OriginalMath.bearingRadians(of: rel))) > 45 * .pi / 180 {
                            p.targetID = nil
                        }
                    }
                    let d = delta(to: desired)
                    if abs(turn) < abs(d) {
                        setHeading(p.headingDegrees + (d > 0 ? turn : -turn) * ticks)
                    }
                }
                flyAtSpeed()
                if p.flags.decoyedByAsteroids, oneIn(10, rawCalls: rawCalls),
                   let rock = asteroids.first(where: {
                       $0.isAlive && abs($0.position.x - p.position.x) < 200
                           && abs($0.position.y - p.position.y) < 200
                           && abs(delta(to: bearingDegrees(to: $0.position))) < 16
                   }) {
                    p.guidanceState = 1
                    p.decoyRock = rock
                    p.targetID = nil
                }
            case 999:
                if p.ageTicks > 15 {
                    for k in 0..<rawCalls {
                        let sign: Double = (rawCallCounter - rawCalls + 1 + k) % 300 < 150 ? -1 : 1
                        setHeading(p.headingDegrees + sign * p.turnDegreesPerTick)
                    }
                }
                flyAtSpeed()
                if p.flags.mayAttackParentIfJammed, oneIn(1000, rawCalls: rawCalls) {
                    retargetOwner(p)
                    p.guidanceState = 0
                }
            case 1:
                if let rock = p.decoyRock, rock.isAlive {
                    let desired = bearingDegrees(to: rock.position)
                    if p.ageTicks > 15 {
                        for _ in 0..<rawCalls {
                            let d = delta(to: desired)
                            if p.turnDegreesPerTick < abs(d) {
                                setHeading(p.headingDegrees + (d > 0 ? p.turnDegreesPerTick : -p.turnDegreesPerTick))
                            }
                        }
                    }
                } else {
                    p.decoyRock = nil
                }
                flyAtSpeed()
            default:
                break   // 998: inert, coasting on
            }
        case .rocket:
            let polar = Vec2.heading(p.facing) * p.speed
            for _ in 0..<rawCalls { p.velocity = (p.velocity * 95 + polar * 5) * 0.01 }
        case .freefallBomb:
            for _ in 0..<rawCalls {
                guard p.velocity.length > 0 else { break }
                let d = delta(to: bearingDegrees(to: p.position + p.velocity))
                if d != 0 { setHeading(p.headingDegrees + (d > 0 ? 1 : -1)) }
            }
        default:
            break
        }
    }

    /// A 1-in-`n` roll made once per raw call this step.
    private func oneIn(_ n: Int, rawCalls: Int) -> Bool {
        for _ in 0..<rawCalls where rng.range(n) == 0 { return true }
        return false
    }

    /// Seeker 0x8000: the shot turns on the ship that fired it.
    private func retargetOwner(_ p: Projectile) {
        guard let owner = ship(id: p.ownerID), owner.isAlive else { return }
        p.targetID = owner.entityID
        p.turnedOnParent = true
    }

    /// `Ship_GetShipJammingScore` (0x00464810), per channel: the hull's
    /// inherent government's InhJam plus the ship's jammer outfits (the
    /// player's once per owned def; an NPC's from its DefaultItems), halved
    /// for an NPC whose government has Flags 0x0080, clamped 0…100, and 0
    /// while disabled.
    func jamScores(of ship: Ship) -> [Int] {
        guard !ship.disabled else { return [0, 0, 0, 0] }
        let inherent = govtRes(ship.inherentJamGovt)?.jamming ?? []
        let halve = !ship.isPlayerControlled && (govtRes(ship.government)?.flags1 ?? 0) & 0x0080 != 0
        return (0..<4).map { ch in
            var v = (inherent.count > ch ? inherent[ch] : 0) + (ship.jamming.count > ch ? ship.jamming[ch] : 0)
            if halve { v = (v + (v < 0 ? 0 : 1)) >> 1 }
            return max(0, min(100, v))
        }
    }

    func govtRes(_ id: Int) -> GovtRes? {
        guard id >= 128 else { return nil }
        return diplomacy?.govt(id) ?? galaxy?.game.govt(id)
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

    /// A shot connects with `victim` (`Shot_ResolveShotCollisionHit`
    /// 0x00437780): its decayed damage and impact on the victim, then the
    /// blast — every *other* ship within `BlastRadius` on both axes takes the
    /// weapon's full undecayed damage and impact, whatever its government;
    /// only the shooter is spared, always if it is an NPC and the player only
    /// with `wëap` Flags 0x0100. Splash ionization falls off as `1 − d²/r²`. Submunitions
    /// launch only on a proximity-fuse hit.
    private func resolveHit(_ p: Projectile, on victim: Ship, linkedShots: Bool,
                            spawned: inout [Projectile]) {
        applyHit(to: victim, shield: p.shieldDamage, armor: p.armorDamage, ownerID: p.ownerID,
                 ionization: p.ionization, ionizeColor: p.ionizeColor,
                 piercing: p.penetratesShields, weaponID: p.weaponID,
                 disablesOnly: p.nonLethal || p.flags.disablesOnly,
                 impact: p.impact, impactFrom: p.position, hitPoint: p.position)
        blast(p, at: p.position, sparing: victim, expiry: false)
        explode(p, at: p.position)
        if linkedShots { spawnSubmunitions(p, at: p.position, spawned: &spawned) }
    }

    /// A shot reaching the end of its life: submunitions unless `wëap` Flags2
    /// 0x0020, and an area blast only with Flags 0x8000 (WP-07, WP-08).
    private func expire(_ p: Projectile, spawned: inout [Projectile]) {
        if p.subsOnExpire { spawnSubmunitions(p, at: p.position, spawned: &spawned) }
        if p.expiryBlast || (p.detonateOnExpire && p.lifeTicks == 0 && p.blastRadius > 0) {
            blast(p, at: p.position, sparing: nil, expiry: true)
            explode(p, at: p.position)
        } else if p.explosionBoomID != nil {
            explode(p, at: p.position)
        }
    }

    /// The area damage of a shot's blast (square, inclusive), at full
    /// undecayed damage and with its impact. An expiry blast also passes
    /// over planet-type ships.
    private func blast(_ p: Projectile, at pos: Vec2, sparing direct: Ship?, expiry: Bool) {
        guard p.blastRadius > 0 else { return }
        let r = p.blastRadius
        let ownerIsPlayer = ship(id: p.ownerID)?.isPlayerControlled == true
        for splash in allShips where splash.isAlive && splash !== direct {
            if splash.entityID == p.ownerID && (!ownerIsPlayer || p.flags.blastSparesPlayer) { continue }
            // Co-op friendly fire: a player's blast only catches another player
            // when friendly fire is enabled.
            if ownerIsPlayer, splash.isPlayerControlled, splash.entityID != p.ownerID,
               !friendlyFireAllowed { continue }
            if expiry && splash.isPlanetTypeShip { continue }
            let d = splash.position - pos
            guard abs(d.x) <= r, abs(d.y) <= r else { continue }
            let falloff = max(0, 1 - (d.x * d.x + d.y * d.y) / (r * r))
            applyHit(to: splash, shield: p.baseShieldDamage, armor: p.baseArmorDamage,
                     ownerID: p.ownerID, ionization: p.ionization * falloff, ionizeColor: p.ionizeColor,
                     piercing: p.penetratesShields, weaponID: p.weaponID,
                     disablesOnly: p.nonLethal || p.flags.disablesOnly,
                     impact: p.impact, impactFrom: pos)
        }
    }

    /// The shot's impact effect: an explosion for a weapon with a blast or a
    /// `bööm`, else just the hit spark `applyHit` already raised.
    private func explode(_ p: Projectile, at pos: Vec2) {
        guard p.blastRadius > 0 || p.explosionBoomID != nil else { return }
        let boomSound = p.explosionBoomID.flatMap { galaxy?.game.boom($0)?.soundID }
        let radius = p.blastRadius > 0 ? p.blastRadius : 12
        events.append(.explosion(at: pos, radius: max(8, radius), soundID: boomSound,
                                 boomID: p.explosionBoomID))
        if p.bigExplosion, p.blastRadius > 0 { events.append(.areaBlast(at: pos, blastRadius: Int(p.blastRadius))) }
    }

    /// `Shot_SpawnLinkedShotsOnImpact` (0x00420d30): `SubCount` children of
    /// `SubType`, while under `SubLimit` deep. A positive `SubTheta` spreads
    /// each child `rand(2θ) − θ` degrees; a negative one fans them evenly
    /// across `±|θ|`. Flags2 0x0010 aims them at the nearest ship.
    private func spawnSubmunitions(_ p: Projectile, at pos: Vec2, spawned: inout [Projectile]) {
        guard let sub = p.submunition, sub.count > 0, p.subDepth <= sub.limit,
              let subSpec = galaxy?.weaponSpec(sub.weaponID) else { return }
        let theta = Int((sub.thetaRadians * 180 / .pi).rounded())
        for i in 0..<sub.count {
            var aim = wholeDegrees(p.facing)
            var subTarget = p.targetID
            // A pointDefense (9) parent hands its own target down; otherwise
            // Flags2 0x0010 aims at the nearest hittable ship — for every
            // guidance — falling back to the parent's target (0x00420d30).
            if p.guidance != .pointDefense, sub.fireAtNearest {
                if let near = nearestHostile(to: pos, shot: p) ?? p.targetID.flatMap({ ship(id: $0) }) {
                    aim = OriginalMath.bearingRadians(from: pos, to: near.position)
                    subTarget = near.entityID
                }
            }
            if theta > 0 {
                aim += Double(rng.range(2 * theta) - theta) * .pi / 180
            } else if theta < 0, sub.count > 1 {
                let span = Double(-theta) * 2
                aim += (Double(theta) + span * Double(i) / Double(sub.count - 1)) * .pi / 180
            }
            let parentVelocity = subSpec.guidance == .rocket ? p.velocity : Vec2()
            let child = spawnProjectile(spec: subSpec, muzzle: pos, aim: aim,
                                        ownerID: p.ownerID, ownerGovt: p.ownerGovt,
                                        ownerVelocity: parentVelocity, targetID: subTarget,
                                        subDepth: p.subDepth + 1, shooter: ship(id: p.ownerID))
            // `spawnProjectile` appended to `projectiles`; move it to the
            // deferred list so we don't process it again this same frame.
            if projectiles.last === child { projectiles.removeLast(); spawned.append(child) }
        }
    }

    /// Whether `shot` may hit `victim` (`Weapon_CanWeaponHitTarget` 0x00426ef0),
    /// for both contact and proximity. Never its owner (unless a jammed
    /// seeker turned on it), an inert shot, or the escape pod. A homing shot
    /// hits only its target unless `wëap` Flags2 0x0008. A ship's shot spares
    /// its squad mates, ships of its own government, fellow defenders of the
    /// same stellar, and the victim's own squad root; a turret shot passes
    /// through a target rated below its tracking roll unless that target is
    /// disabled (WP-26). Player-squad shots pass through ships whose
    /// government is immune to the player (gövt Flags 0x0008) or never
    /// attacks the player (0x0040, against the player or a direct escort),
    /// and through the squad's second-level escorts. A planet-type weapon
    /// hits only planet-type ships, and an ordinary one never does. A
    /// stellar battery's shot hits only its target.
    func canShotHit(_ shot: Projectile, _ victim: Ship) -> Bool {
        guard victim.isAlive else { return false }
        if victim.entityID == shot.ownerID && !shot.turnedOnParent { return false }
        if shot.guidanceState == 998 || victim.shipTypeID == Ship.escapePodShipID { return false }
        if shot.guidance == .guided, !shot.hitsAnyShip, victim.entityID != shot.targetID { return false }
        if victim.isPlanetTypeShip != shot.flags.isPlanetTypeWeapon { return false }
        if shot.ownerID < 0 {
            // A stellar battery (WP-22).
            if let tid = shot.targetID ?? shot.batteryTargetID, tid != victim.entityID { return false }
            return true
        }
        let owner = ship(id: shot.ownerID)
        // A miner's shots (an NPC in state 0x10) never hit ships (0x00426ef0).
        if let owner, !owner.isPlayerControlled,
           originalAI.record(for: owner.entityID)?.state == OriginalAIState.asteroid { return false }
        // Player-vs-player: co-op partners are gated by the session rule.
        if victim.isPlayerControlled, owner?.isPlayerControlled == true, victim.entityID != shot.ownerID {
            return pvpAllowed
        }
        if let leader = shot.ownerLeaderID, victim.brain?.leaderID == leader { return false }
        // The player flies for no government in the original (its slot holds
        // −1), so this spares only an NPC's own government.
        if shot.ownerGovt >= 128, victim.government == shot.ownerGovt,
           owner?.isPlayerControlled != true { return false }
        if let stellar = owner?.spobDefenderOf, victim.spobDefenderOf == stellar { return false }
        if shot.turretRoll > 0, victim.turretRating < shot.turretRoll, !victim.disabled { return false }
        let ownerInPlayerSquad = isPlayerFleetMember(shot.ownerID)
        if ownerInPlayerSquad {
            if let lid = victim.brain?.leaderID, lid != World.playerEntityID,
               ship(id: lid)?.brain?.leaderID == World.playerEntityID { return false }
            if (govtRes(victim.government)?.flags1 ?? 0) & 0x0008 != 0 { return false }
        }
        if !victim.isPlayer, (govtRes(victim.government)?.flags1 ?? 0) & 0x0040 != 0,
           isCreditedToPlayer(shot.ownerID) { return false }
        if !shot.turnedOnParent, let owner, squadRoot(of: owner) == squadRoot(of: victim) { return false }
        return true
    }

    /// The top of a ship's chain of leaders (itself when it has none).
    func squadRoot(of ship: Ship) -> Int {
        var id = ship.entityID
        for _ in 0..<8 {
            guard let leader = self.ship(id: id)?.brain?.leaderID, leader != id else { return id }
            id = leader
        }
        return id
    }

    /// One hit landing on `ship` (`Ship_ApplyDamageToShip` 0x004192d0): the
    /// knockback, the damage itself (`Ship.applyDamage`), and the disable and
    /// kill transitions the hit causes.
    ///
    /// The legal penalties and combat rating are credited when the attacker is
    /// the player or one of the player's direct escorts, and the victim is not
    /// a stellar's defense ship: crossing the disable line costs `DisabPenalty`
    /// (a ship blown straight past it pays that too, as in the original), and
    /// the killing hit costs `KillPenalty` and earns `CombatRatingRule.points`
    /// unless the victim flies for a derelict government.
    ///
    /// - Parameters:
    ///   - nonLethal: `wëap` Flags2 0x1000 — armor stops at 1 instead of 0.
    ///   - impact / impactFrom: the weapon's `Impact` and where it struck from
    ///     (the shot's position, or the beam's source); 0 for no push.
    func applyHit(to ship: Ship, shield: Double, armor: Double, ownerID: Int,
                  ionization: Double = 0, ionizeColor: (r: Double, g: Double, b: Double)? = nil,
                  piercing: Bool = false, weaponID: Int = -1,
                  disablesOnly: Bool = false, impact: Double = 0, impactFrom: Vec2? = nil,
                  keepsAboveDisable: Bool = false, hitPoint: Vec2? = nil) {
        var shield = shield, armor = armor
        // Difficulty (an enhancement-type setting): scale only the damage the
        // *player* takes; 1.0, the default, is the original.
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
        if impact != 0, let from = impactFrom { applyKnockback(to: ship, impact: impact, from: from) }
        let wasDisabled = ship.disabled
        let wasAlive = ship.isAlive
        let hadShield = ship.shield > 0
        // Per-hit logging isn't gated like everything else in this file (no
        // "log on change/transition" here — every hit is its own event), and
        // splash damage can call this several times in the same instant for a
        // clustered group. Destroy/disable transitions get their own lines.
        // A1: an NPC hitting its own primary target while it (or its squad
        // leader) is boarding never destroys it (0x004192d0).
        let nonLethal = disablesOnly
            || (ownerID > 0 && self.ship(id: ownerID).map {
                originalAI.hitIsNonLethal(attacker: $0, victimID: ship.entityID) } == true)
        ship.applyDamage(shield: shield, armor: armor, piercing: piercing, nonLethal: nonLethal)
        originalAI.noteHit(ship, attackerID: ownerID, shield: shield, armor: armor, world: self)
        // A death blast never disables: past the line, armor is set back to
        // just above it (`max × 0.3333 + 1`, or `0.1` with hull Flags 0x0010).
        if keepsAboveDisable, !wasDisabled, ship.disabled, ship.isAlive {
            let fraction = ship.disableArmorFraction < Ship.standardDisableFraction ? 0.1 : 0.3333
            ship.armor = ship.maxArmor * fraction + 1
        }
        // Co-op no-death (`deathReal` off): a player-controlled ship can't be
        // destroyed — floor its armor so it survives however hard it's hit.
        if !playerDeathReal, ship.isPlayerControlled, ship.armor < 1 { ship.armor = 1 }
        // Cloak flag 0x0008: damage drops the cloak — only once it has fully
        // faded in, or while it is fading in (OS-04).
        if ship.cloakEngaged, ship.cloakDropsOnDamage { ship.cloakEngaged = false }
        if ionization > 0, ship.ionizeMax > 0 {
            // Charge accumulates uncapped (WP-11); intensity caps at 0.7.
            ship.ionCharge += ionization
            // Remember the hue to glow: this weapon's IonizeColor, or keep any
            // prior tint if this shot doesn't specify one (0 = "default bluish").
            ship.ionizeColor = ionizeColor ?? ship.ionizeColor
        }
        // A piercing hit never touches the shields, so it never flashes them.
        // The hit spray rises where the shot struck (WP-24).
        let at = hitPoint ?? ship.position
        events.append(hadShield && !piercing ? .shieldHit(at: at, weaponID: weaponID)
                                             : .armorHit(at: at, weaponID: weaponID))

        // Player-fleet fire (the player OR one of their escorts/fighters)
        // provokes the victim into fighting the whole fleet, not just
        // whichever ship actually shot it — see `AIBrain.provokedByPlayer`/
        // `isHostile`. Per the Bible (Appendix II §2.1), `ShootPenalty` is
        // "currently ignored" in the real game — shooting alone never dents
        // legal record; only the disable/kill/board/smuggling outcomes below
        // do (`recordDisable`/`recordKill`, `Diplomacy.swift`).
        if !isPlayerFleetMember(ship.entityID), isPlayerFleetMember(ownerID) {
            // Is this hit fresh player aggression, or return fire? A victim
            // that had already traded fire with the fleet (`provokedByPlayer`,
            // set by the reverse rule below when it shot first), is actively
            // targeting a fleet member, or belongs to a government at war
            // with the player, started (or is part of) this fight itself —
            // hitting it back is self-defense. Self-defense must NOT mark the
            // flip the victim's whole government hostile: defending
            // against one grudge-holder or mission assassin used to turn his
            // entire otherwise-neutral government (and then the local police,
            // and then THEIR government...) on the player — the cascading
            // "everyone attacks me for no reason" bug.
            let wasAlreadyFightingFleet = ship.brain?.provokedByPlayer == true
                || ship.currentTargetID.map(isPlayerFleetMember) == true
                || (diplomacy?.isHostileToPlayer(ship.government) ?? false)
            ship.brain?.provokedByPlayer = true
            if !wasAlreadyFightingFleet {
                // Unprovoked player aggression against a bystander: the
                // government counts as provoked in this system (the
                // reinforcement and stellar-battery triggers read it).
                if ship.government >= 128 { provokedGovernments.insert(ship.government) }
            }
            // AI-06: the player's own shot on the ship it was aimed at calls
            // the victim's friends in (`Government_PropagateHostilityFromAttack`
            // 0x004102e0).
            if ownerID == World.playerEntityID, player.currentTargetID == ship.entityID {
                propagateHostilityFromPlayerAttack(on: ship)
            }
        }
        // AI-07: any player hit on a përs with Flags 0x0001 makes it hold a grudge.
        if ownerID == World.playerEntityID, let pid = ship.personID, ship.personFlags & 0x0001 != 0,
           !playerPersGrudges.contains(pid) {
            playerPersGrudges.insert(pid)
            events.append(.personGrudge(personID: pid))
        }
        // The reverse: something that shoots a player-fleet member becomes
        // provoked (hostile) toward the whole fleet too — an escort fighting
        // back on its own no longer leaves the player and its other escorts
        // blind to the fact that this ship is now an enemy.
        if isPlayerFleetMember(ship.entityID), !isPlayerFleetMember(ownerID),
           let attacker = self.ship(id: ownerID) {
            attacker.brain?.provokedByPlayer = true
        }

        let credited = !ship.isPlayer && ship.spobDefenderOf == nil && isCreditedToPlayer(ownerID)
        if credited, !wasDisabled, ship.disabled {
            diplomacy?.recordDisable(of: ship.government, missionShip: ship.missionID != nil)
        }
        if wasAlive, !ship.isAlive {
            // The killing hit. `despawnDepartedAndDead` finalizes it next pass
            // and credits the kill from these flags.
            ship.killedByPlayer = ownerID == World.playerEntityID
            ship.killCredited = credited && !isDerelictGovernment(ship.government)
            originalAI.escortsSawKill(of: ship, world: self)
            return
        }
        if !wasDisabled, ship.disabled { didBecomeDisabled(ship, ownerID: ownerID) }
    }

    /// Whether `ownerID`'s hits count as the player's for the legal record and
    /// combat rating: the player, or a ship whose squad leader is the player.
    func isCreditedToPlayer(_ ownerID: Int) -> Bool {
        ownerID == World.playerEntityID || ship(id: ownerID)?.brain?.leaderID == World.playerEntityID
    }

    /// `gövt` Flags 0x0800 (`Government_IsShipGovernmentDerelict`).
    func isDerelictGovernment(_ govt: Int) -> Bool {
        govt >= 128 && galaxy?.game.govt(govt)?.startsDisabled == true
    }

    /// A ship just crossed the disable line and lives (`Ship_ApplyDamageToShip`'s
    /// disabled arm). The player gets the "disabled" overlay (STR# 2002 #287,
    /// shown by the host on `.shipDisabled`), a 300-tick post-disable window and
    /// its armor truncated to a whole number; the host fails Flags-0x0004
    /// missions. Everyone stops shooting the hulk.
    private func didBecomeDisabled(_ ship: Ship, ownerID: Int) {
        ship.wantsToDepart = false
        ship.currentTargetID = nil
        ship.brain?.targetID = nil
        clearTarget(ship.entityID)               // everyone stops shooting it
        stopAllBeamLoops(for: ship)               // a hulk doesn't fire — stop its beam loop
        if ship.isPlayer {
            ship.recentlyHitTicks = 300
            ship.armor = ship.armor.rounded(.down)
        }
        events.append(.shipDisabled(entityID: ship.entityID, at: ship.position))
        leaveWingWhenDisabled(ship)
        // The story counts every disabled mission ship (MS-11): it meets a
        // "disable" goal (a later kill doesn't un-meet it), and a disabled
        // escort fails its mission. Board/rescue objectives remain outstanding
        // until the player actually boards the hulk.
        if let mid = ship.missionID, let goal = ship.missionShipGoal,
           goal == .disable || goal == .escort {
            events.append(.missionShipGoalReached(missionID: mid, entityID: ship.entityID,
                                                   goal: goal, byPlayer: ownerID == 0))
        }
        Log.combat.notice("\(LogTag.ship(id: ship.entityID, name: ship.name)) disabled (armor below \(Int(ship.disableArmorFraction * 100))% of max) — now a drifting hulk")
    }

    /// Whether a përs's alive flag clears when its ship is destroyed
    /// (`Ship_UpdateVisualState` 0x00428340): slot 0x3fe (përs 1150) on a
    /// `Rand(8) == 0`; any other only without the escape-pod flag 0x0002.
    static func persDiesWithShip(_ persID: Int, flags: Int, rng: inout NovaRandom) -> Bool {
        if persID == 1150 { return rng.range(8) == 0 }
        return flags & 0x0002 == 0
    }

    /// OS-10: the governments an IFF scrambler or reinforcement inhibitor the
    /// player carries matches are latched for the rest of the session
    /// (`GovernmentLatches`), so selling the outfit later changes nothing.
    func latchPlayerOutfitGovernments() {
        let scramblers = player.iffScramblerClasses, inhibitors = player.reinforcementInhibitorClasses
        guard !scramblers.isEmpty || !inhibitors.isEmpty, let dip = diplomacy,
              latchedOutfitClasses != [scramblers, inhibitors] else { return }
        latchedOutfitClasses = [scramblers, inhibitors]
        dip.latches.latch(scramblerClasses: scramblers, inhibitorClasses: inhibitors,
                          govts: Array(dip.govts.values))
    }

    /// `Government_PropagateHostilityFromAttack` 0x004102e0 (AI-06): every
    /// warship or interceptor in the system that isn't already attacking
    /// turns on the player when its government is the victim's or allied with
    /// it (either way round), or is nosy (`Flags` 0x0002) — unless it is
    /// hostile to the victim, holds the player's no-attack rank privilege, is
    /// allied with the player's own government, or flies in the player's
    /// wing. A xenophobic victim calls only its own government; an
    /// independent victim only nosy governments; an independent responder
    /// answers any non-xenophobic victim. A victim of a derelict (`Flags`
    /// 0x0800) or ignored (0x0020) government calls nobody, and neither does
    /// the shareware Enforcer slot. There is no distance limit.
    func propagateHostilityFromPlayerAttack(on victim: Ship) {
        guard let dip = diplomacy, victim.personID != 1151 else { return }
        let govts = dip.govts
        let victimGovt = victim.government
        let vg = govts[victimGovt]
        if vg?.startsDisabled == true || vg?.ignoredWhenAttacked == true { return }
        for responder in npcs where responder.entityID != victim.entityID && responder.isAlive {
            guard let brain = responder.brain, brain.aiType.isWarship, brain.state != .attacking,
                  responder.personID != 1151, !isPlayerFleetMember(responder.entityID) else { continue }
            let rg = responder.government
            let nosy = govts[rg]?.nosy ?? false
            var eligible = true
            if rg != independentGovt, victimGovt != independentGovt {
                if GovtRelations.hostileOrXenophobic(rg, victimGovt, govts: govts) { continue }
                if vg?.xenophobic == true, rg != victimGovt { eligible = false }
                if dip.rankProtectedGovts.contains(rg) { eligible = false }
                if !GovtRelations.allied(rg, victimGovt, govts: govts), !nosy { eligible = false }
                if GovtRelations.allied(rg, player.government, govts: govts) { eligible = false }
            } else if rg != independentGovt {
                eligible = nosy
            } else if victimGovt != independentGovt {
                eligible = !(vg?.xenophobic ?? false)
            }
            guard eligible else { continue }
            brain.provokedByPlayer = true
            // The original AI reads the responder's own record: state 4 on
            // the attacker (0x004102e0).
            originalAI.joinAttack(responder, attackerID: World.playerEntityID)
        }
    }

    /// Weapon knockback (`Ship_ApplyDamageToShip` 0x004192d0): `impact / mass`
    /// px/tick along the bearing from where the shot struck to the ship, added
    /// per axis up to the hull's base top speed, then clamped per axis to its
    /// effective top speed (1.8 × for the player while the afterburner widens
    /// the caps). No push on a massless hull or one with shïp Flags 0x0400, nor
    /// during the player's hyperjump. A negative (tractor) impact is dropped
    /// within 50 px on either axis.
    func applyKnockback(to ship: Ship, impact: Double, from: Vec2) {
        guard ship.massTons > 0, !ship.isPlanetTypeShip, !(ship.isPlayer && playerJump != nil) else { return }
        // No push while any ship's jump timer runs (+0x50 > 0).
        if (originalAI.record(for: ship.entityID)?.jumpTimer ?? 0) > 0 { return }
        let rel = ship.position - from
        if impact < 0, abs(rel.x) < 50 || abs(rel.y) < 50 { return }
        guard rel.x != 0 || rel.y != 0 else { return }
        let step = OriginalClock.perSecond(impact / ship.massTons)
        ship.addPolarVelocityWithClamp(heading: OriginalMath.bearingRadians(from: from, to: ship.position),
                                       step: step, max: ship.stats.maxSpeed)
        let cap = ship.isPlayerControlled && ship.afterburnerActive && !ship.inGravityPull
            ? ship.effectiveMaxSpeed * 1.8 : ship.effectiveMaxSpeed
        ship.velocity = Vec2(max(-cap, min(cap, ship.velocity.x)), max(-cap, min(cap, ship.velocity.y)))
    }

    // MARK: Beam lock

    /// A tractor beam's hold on a ship (`Ship_HandleShip` 0x00433050): the
    /// lock lapses 30 ticks after the last hit, or at once when the locking
    /// ship is gone or disabled; meanwhile the ship's velocity is dragged
    /// toward the locker's (rest, for a self-lock) by a quarter of its thrust
    /// per tick on each axis.
    private func updateBeamLock(_ s: Ship, dt: Double) {
        guard let lockID = s.velocityMatchTargetID else { return }
        var target = Vec2()
        if lockID != s.entityID {
            guard let locker = ship(id: lockID), locker.isAlive, !locker.disabled else {
                s.velocityMatchTargetID = nil; s.beamLockTicksLeft = 0; return
            }
            target = locker.velocity
        }
        let ticks = dt * OriginalClock.ticksPerSecond
        s.beamLockTicksLeft -= ticks
        if s.beamLockTicksLeft <= 0 { s.velocityMatchTargetID = nil; return }
        if s.isPlayerControlled { return }
        let t = s.effectiveAcceleration / OriginalClock.ticksPerSecond * 0.25 * ticks
        func drag(_ v: Double, _ goal: Double) -> Double {
            if goal + t < v { return v - t }
            if v < goal - t { return v + t }
            return v
        }
        s.velocity = Vec2(drag(s.velocity.x, target.x), drag(s.velocity.y, target.y))
    }

    /// A tractor-beam hit (impact < 0) from `owner` on `victim` (0x0042f270):
    /// a victim whose three quarters mass fits the owner is held by the owner;
    /// a much heavier one holds the owner to itself.
    private func applyBeamLock(owner: Ship, victim: Ship, impact: Double, hitPoint: Vec2) {
        guard victim.massTons > 0, !victim.isPlanetTypeShip else { return }
        if victim.massTons * 0.75 <= owner.massTons {
            victim.velocityMatchTargetID = owner.entityID
            victim.beamLockTicksLeft = 30
        } else if owner.massTons > 0, !owner.isPlanetTypeShip {
            if owner.velocityMatchTargetID == nil { owner.velocityMatchTargetID = owner.entityID }
            owner.beamLockTicksLeft = 30
            // The light owner is dragged toward the heavy victim: its velocity
            // takes impact / mass along the bearing victim -> hit point with
            // the negative impact, i.e. toward the victim (oracle-checked sign,
            // 0x0043b670 / 0x0043b4a0), unless the hit is within 50 px of the
            // victim's centre on both axes.
            let toVictim = victim.position - hitPoint
            if abs(toVictim.x) >= 50 || abs(toVictim.y) >= 50 {
                let step = OriginalClock.perSecond(-impact / owner.massTons)
                owner.addPolarVelocityWithClamp(heading: toVictim.angle, step: step, max: owner.stats.maxSpeed)
                let cap = owner.effectiveMaxSpeed
                owner.velocity = Vec2(max(-cap, min(cap, owner.velocity.x)), max(-cap, min(cap, owner.velocity.y)))
            }
        }
    }

    // MARK: Despawn

    private func despawnDepartedAndDead(_ dt: Double) {
        var survivors: [Ship] = []
        var dyingCarriers: [Ship] = []
        defer { for carrier in dyingCarriers { dyingCarrierEscape(carrier) } }
        for npc in npcs {
            if !npc.isAlive {
                if npc.deathTimer == nil {
                    // The frame this NPC actually died: all the *gameplay*
                    // consequences (diplomacy, mission goals, targeting) fire
                    // right away, but the ship itself lingers as a frozen wreck
                    // for `deathSequenceDuration` — playing out a staggered
                    // multi-burst explosion just like the player's own death —
                    // instead of vanishing the instant its armor hit 0.
                    npc.deathTimer = 0
                    npc.velocity = Vec2()
                    // Piggyback the drifting-hulk render treatment (thruster/
                    // health-bar/shield-flare hidden) for the lingering wreck —
                    // harmless: everywhere `disabled` gates *behavior* also
                    // gates on `isAlive`, which is already false here.
                    npc.disabled = true
                    if npc.killCredited, let dip = diplomacy {
                        dip.recordKill(of: npc.government, shipStrength: Int(npc.combatStrength),
                                       missionShip: npc.missionID != nil)
                    }
                    // UI-17: a destroyed përs is gone for good, whoever killed
                    // it — unless its Flags carry 0x0002 (it ejected); the
                    // revenge përs 1150 dies only one time in eight.
                    if let pid = npc.personID, Self.persDiesWithShip(pid, flags: npc.personFlags, rng: &rng) {
                        events.append(.personDefeated(personID: pid))
                    }
                    if !npc.wreckOfPlayer {
                        events.append(.explosion(at: npc.position, radius: max(24, npc.radius * 1.5),
                                                 soundID: npc.explosionSoundID, boomID: npc.explosionBoomID))
                        events.append(.shipDying(entityID: npc.entityID, at: npc.position,
                                                 boomID: npc.explosionBoomID))
                    }
                    Log.combat.notice("\(LogTag.ship(id: npc.entityID, name: npc.name)) destroyed\(npc.killedByPlayer ? " by player" : "")")
                    // A destroyed mission ship meets a "destroy" (or "chase off",
                    // which a kill satisfies) objective. A kill is not a boarding
                    // or rescue, and disabling already reported its own goal.
                    if let mid = npc.missionID, let goal = npc.missionShipGoal,
                       goal == .destroy || goal == .chaseOff {
                        events.append(.missionShipGoalReached(missionID: mid, entityID: npc.entityID,
                                                              goal: goal, byPlayer: npc.killedByPlayer))
                    }
                    // Any other mission ship that dies is a loss the story
                    // counts (MS-11): it fails a disable, escort or
                    // not-yet-boarded board/rescue mission. A boarded one
                    // already met its goal.
                    if let mid = npc.missionID, let goal = npc.missionShipGoal,
                       goal != .destroy, goal != .chaseOff, goal != .none,
                       !npc.missionBoardingGoalReported {
                        events.append(.missionShipLost(missionID: mid, goal: goal))
                    }
                    Log.combat.debug("\(npc.name) [\(npc.entityID)] destroyed (shipTypeID=\(npc.shipTypeID))")
                    // Clear any targeting of the dead ship.
                    clearTarget(npc.entityID)
                    stopAllBeamLoops(for: npc)
                    survivors.append(npc)
                    continue
                }
                npc.deathTimer! += dt
                let timerTicks = npc.deathDelayTicks - npc.deathTimer! / OriginalClock.rawCallSeconds
                if dyingCarrierEscapeDue(npc, timerTicks: timerTicks) { dyingCarriers.append(npc) }
                if npc.deathTimer! < npc.deathSequenceDuration, !npc.diesInstantly {
                    // Still mid-explosion — keep the wreck around so its sprite
                    // stays on screen for the sequence to play over.
                    survivors.append(npc)
                    continue
                }
                // Sequence finished — the hull blows (WP-13) and is gone.
                deathBlast(of: npc)
                events.append(.shipDestroyed(entityID: npc.entityID, shipTypeID: npc.shipTypeID,
                                             at: npc.position))
                continue
            }
            // Landed on a stellar object → vanished into the spaceport (no wreck).
            if npc.wantsToLand, let sid = npc.landingSpob {
                events.append(.shipLanded(entityID: npc.entityID, spobID: sid, at: npc.position))
                clearTarget(npc.entityID)
                stopAllBeamLoops(for: npc)
                continue
            }
            // The original AI's jump finished where the ship stands (or its
            // gate entry faded out).
            if npc.wantsToDepart, npc.departsInPlace {
                if let gateID = npc.brain?.departViaGateID {
                    events.append(.shipDepartedViaGate(entityID: npc.entityID, gateSpobID: gateID, at: npc.position))
                } else {
                    events.append(.shipDeparted(entityID: npc.entityID, at: npc.position, heading: npc.angle))
                }
                clearTarget(npc.entityID)
                stopAllBeamLoops(for: npc)
                continue
            }
            // Departed past the system edge → gone to hyperspace. A ship that
            // rolled in favor of a hypergate departure (`AIBrain.departViaGateID`)
            // instead transits there, so the gate visibly opens for it too.
            if npc.wantsToDepart {
                // A chase-off mission ship leaving counts for its goal; it is
                // reported (as a `missionShipLost` with the chase-off goal)
                // by whichever exit below it takes.
                let chasedOff: WorldEvent? = npc.missionShipGoal == .chaseOff
                    ? npc.missionID.map { .missionShipLost(missionID: $0, goal: .chaseOff) } : nil
                if let gateID = npc.brain?.departViaGateID,
                   let gate = systemContext.bodies.first(where: { $0.id == gateID }) {
                    let d = (npc.position - gate.position).length
                    if d <= gate.radius + 40 {
                        events.append(.shipDepartedViaGate(entityID: npc.entityID, gateSpobID: gateID,
                                                           at: npc.position))
                        if let chasedOff { events.append(chasedOff) }
                        clearTarget(npc.entityID)
                        stopAllBeamLoops(for: npc)
                        continue
                    }
                } else {
                    let d = (npc.position - systemContext.center).length
                    if d >= systemContext.jumpRadius {
                        events.append(.shipDeparted(entityID: npc.entityID, at: npc.position,
                                                    heading: npc.angle))
                        if let chasedOff { events.append(chasedOff) }
                        clearTarget(npc.entityID)
                        stopAllBeamLoops(for: npc)
                        continue
                    }
                }
            }
            survivors.append(npc)
        }
        npcs = survivors
        refreshRoster()
        // Player death is left to the app (respawn / game-over UI).
    }

    /// The death blast at the end of a hull's death sequence (WP-13,
    /// `Ship_UpdateVisualState` 0x00428340): a hull of 100 t or more (not a
    /// planet-type ship) hits every other ship within `trunc(mass × 0.075 +
    /// 50)` px on both axes for `trunc(mass × 0.0375 + 25)` shield and armor
    /// damage with impact 750. The blast is non-lethal and can't disable: a
    /// ship it would push past the disable line is left just above it.
    func deathBlast(of dying: Ship) {
        guard dying.massTons >= 100, !dying.isPlanetTypeShip else { return }
        let radius = (dying.massTons * 0.075 + 50).rounded(.down)
        let damage = (dying.massTons * 0.0375 + 25).rounded(.down)
        for other in allShips where other !== dying && other.isAlive {
            let d = other.position - dying.position
            guard abs(d.x) <= radius, abs(d.y) <= radius else { continue }
            applyHit(to: other, shield: damage, armor: damage, ownerID: dying.entityID,
                     disablesOnly: true, impact: 750, impactFrom: dying.position,
                     keepsAboveDisable: true)
        }
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

    /// Whether `npc` would actually fight the player right now. Broader than the
    /// government-level `Diplomacy.isHostileToPlayer`: it runs the AI's own
    /// hostility test, so a ship provoked into attacking you, a `pêrs` holding a
    /// grudge, or a mission ship ordered to attack all count — while an IFF-
    /// scrambled or "protect the player" ship correctly doesn't. Your own
    /// escorts are never hostile, whatever their government.
    public func isEffectivelyHostileToPlayer(_ npc: Ship) -> Bool {
        guard !isPlayerFleetMember(npc.entityID) else { return false }
        guard let brain = npc.brain else {
            return diplomacy?.isHostileToPlayer(npc.government) == true
        }
        return brain.isHostile(npc, player, self)
    }

    /// Lock the nearest eligible ship within range (`hostileOnly` narrows to
    /// ships that would actually fight the player). Reuses
    /// `player.currentTargetID`, so locking a target also makes the player's
    /// guided weapons track it. Returns the newly-locked ship, if any.
    ///
    /// Closest-ship includes living disabled hulks so they can be found for
    /// boarding; closest-hostile excludes them because they cannot fight.
    /// Ships in the player's own fleet are never picked: snapping to an escort
    /// that flies in formation would crowd out other nearby contacts. Escorts
    /// stay reachable by clicking them or by Tab-cycling past every other ship.
    @discardableResult
    public func selectNearestTarget(hostileOnly: Bool) -> Ship? {
        let candidates = npcs.filter { npc in
            npc.isAlive && canTarget(npc, by: player)
                && !isPlayerFleetMember(npc.entityID)
                && (!hostileOnly || (!npc.disabled && isEffectivelyHostileToPlayer(npc)))
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

    /// The player themselves, or anyone under their command — used by `applyHit`
    /// to widen "provoked by the player" into "provoked by the player's whole
    /// fleet" (see `AIBrain.provokedByPlayer`/`isHostile`).
    ///
    /// Follows the whole chain of command, not just the first link: a fighter
    /// launched by one of your escort carriers has that *carrier* as its leader,
    /// so a one-level `leaderID == player` test read it as an outsider. Anything
    /// that then splashed it — including its own carrier's turrets — tripped
    /// `applyHit`'s "an outsider was hit by the player's fleet" rule, marked it
    /// `provokedByPlayer`, and `AIBrain.isHostile`'s fleet-vs-outsider check then
    /// had the fighter open fire on the carrier it launched from.
    public func isPlayerFleetMember(_ entityID: Int) -> Bool {
        var id = entityID
        // Cap the walk: a corrupted/cyclic leader chain must not hang the sim,
        // and no real fleet is anywhere near this deep.
        for _ in 0..<8 {
            if id == Self.playerEntityID { return true }
            guard let leader = ship(id: id)?.brain?.leaderID else { return false }
            id = leader
        }
        return false
    }

    /// Whether `ship` flies for the player — the escort-wing/fighter test used by
    /// the AI, the radar and the targeting hotkeys, so all three agree on who is
    /// "yours". The player themselves is not one of their own escorts.
    public func isPlayerEscort(_ ship: Ship) -> Bool {
        !ship.isPlayer && isPlayerFleetMember(ship.entityID)
    }

    /// Issue a standing order to the whole escort wing — including the fighters
    /// flying off your escorts' own bays, which fight under the same order as
    /// the wing they belong to.
    public func setPlayerEscortOrder(_ order: EscortOrder) {
        for npc in npcs where npc.isAlive && isPlayerEscort(npc) { npc.brain?.escortOrder = order }
        originalAI.commandPlayerEscorts(order, world: self)
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
    /// The scrambler / inhibitor classes last latched (`latchPlayerOutfitGovernments`).
    var latchedOutfitClasses: [Set<Int>] = []
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
    /// Whether boarding a board/rescue ship of mission `id` takes the
    /// original's stand-down branch (0x0045a3d0: mïsn Flags 0x0001 and a
    /// ShipCount of 1). The host answers from the mission data.
    public var missionBoardStandsDown: (Int) -> Bool = { _ in false }

    /// The current system's sensor static (`sÿst.Interference`, 0-100). Set when
    /// the world is built for a system; degrades effective sensor range.
    public var systemInterference: Int = 0
    /// The current system's visual murk (`sÿst.Murk`, 0-100; <0 also hides the
    /// starfield). Set when the world is built for a system; the app draws a
    /// fog whose depth tracks `effectiveMurk(for:)`. No gameplay effect.
    public var systemMurk: Int = 0
    /// The current system's backdrop tint (`sÿst.BkgndColor`, `0x00RRGGBB`;
    /// zero = pure black). Set when the world is built for a system; the app
    /// tints the space background and the murk fog with it — how nebula
    /// systems get their colored haze. No gameplay effect.
    public var systemBackgroundColor = NovaColor(r: 0, g: 0, b: 0)

    /// Sensor range under system interference. The original never shortens it
    /// (OS-05): interference only fills the player's radar with static now and
    /// then (`radarStaticChance`), and AI perception ignores it.
    public func effectiveSensorRange(_ base: Double, for observer: Ship) -> Double { base }

    /// The percent chance one radar refresh (at most every 250 ms) shows only
    /// static: the system's Interference less the observer's ModType-24
    /// anti-interference (clamped to ±100), clamped to 0…100 (0x0045d030,
    /// 0x0046abb0; OS-05).
    public func radarStaticChance(for observer: Ship) -> Int {
        max(0, min(100, systemInterference - max(-100, min(100, observer.interferenceReduction))))
    }

    /// `System_GetEffectiveMurkPercent` 0x0046c250: the system's murk (a
    /// negative one counts as 0) **plus** every owned ModType-28 outfit's
    /// ModVal × count, clamped to 0…100. A negative `systemMurk` also hides
    /// the starfield ("equivalent to zero murk but also hides the starfield");
    /// that reads the raw `systemMurk`, not this value.
    public func effectiveMurk(for observer: Ship) -> Int {
        max(0, min(100, max(systemMurk, 0) + observer.murkModifier))
    }

    /// Whether `observer` can detect (and therefore target) `target` through
    /// its cloak (`Ship_CanShipEngageTargetUnderCloakRules` 0x00464a90): an
    /// uncloaked ship always; a cloaked one only within 200 px on both axes of
    /// an observer with cloak-scanner bit 0x0002, or by the cloaker's own
    /// escorts.
    public func canDetect(_ target: Ship, by observer: Ship) -> Bool {
        guard target.isEffectivelyCloaked else { return true }
        if observer.brain?.leaderID == target.entityID { return true }
        let d = target.position - observer.position
        return observer.cloakScannerFlags & 0x0002 != 0 && abs(d.x) < 200 && abs(d.y) < 200
    }

    /// `shïp` Flags2 0x0010 / ModType 30 bit 0x0004: untargetable hulls (OS-12)
    /// — a ship with hull Flags2 0x0004 can't be targeted, cycled or picked
    /// unless the observer carries a scanner with bit 0x0004.
    public func canTarget(_ target: Ship, by observer: Ship) -> Bool {
        guard canDetect(target, by: observer) else { return false }
        return target.hullFlags2 & 0x0004 == 0 || observer.cloakScannerFlags & 0x0004 != 0
    }

    /// A ship's formation key: an escort's is its leader's entity id; a leader
    /// (or any lone ship) is its own key. Two ships sharing a key fly together
    /// — the grouping `cloakIsArea` (0x1000) shares a cloak across.
    private func formationKey(_ s: Ship) -> Int { s.brain?.leaderID ?? s.entityID }

    /// The cloak (OS-04, `Ship_UpdateVisualState` 0x00428340 and the upkeep
    /// in 0x00464db0 / 0x00465090 / 0x00467e80). The fade runs 0.75 of 32 a
    /// tick (1.5 with hull Flags2 0x0001; the device's own 0x0001 is never
    /// read). Engaged, it costs the device's fuel nibble (bits 0x00F0) and
    /// shield nibble (0x0F00) per second; the shield drain applies only while
    /// the shields hold at least a tick's worth, so the last points stay. With
    /// 0x0004 the player's shields are zeroed every tick, an NPC's only on
    /// engaging. It can't be held disabled, out of fuel (even by a device that
    /// burns none), or — for the player — while spinning up a jump unless the
    /// hull has Flags2 0x0400.
    private func stepCloak(_ dt: Double) {
        defer {
            if player.cloakEngaged != playerCloakWasEngaged {
                playerCloakWasEngaged = player.cloakEngaged
                emit(.playerCloakChanged(engaging: player.cloakEngaged))
            }
        }
        let ticks = dt * OriginalClock.ticksPerSecond
        for s in allShips where s.hasCloak {
            if s.cloakEngaged {
                let jumping = s.isPlayer && playerJump != nil && s.hullFlags2 & 0x0400 == 0
                if s.disabled || s.fuel <= 0 || jumping { s.cloakEngaged = false }
            }
            let rate = (s.hullFlags2 & 0x0001 != 0 ? 1.5 : 0.75) / 32 * ticks
            if s.cloakEngaged {
                if s.cloakDropsShields, s.isPlayer || s.cloakLevel == 0 { s.shield = 0 }
                s.cloakLevel = min(1, s.cloakLevel + rate)
                if s.cloakFuelPerSec > 0 { s.fuel = max(0, s.fuel - s.cloakFuelPerSec * dt) }
                let shieldDrain = s.cloakShieldPerSec * dt
                if shieldDrain > 0, s.shield >= shieldDrain { s.shield -= shieldDrain }
            } else if s.cloakLevel > 0 {
                s.cloakLevel = max(0, s.cloakLevel - rate)
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

    /// The carrier's target, when it has one in the system — the condition for
    /// launching (`Ship_LaunchShipFromCarrierBay` 0x0040d9a0).
    private func carrierTarget(_ carrier: Ship) -> Ship? {
        guard let tid = carrier.currentTargetID, let t = ship(id: tid), t.isAlive else { return nil }
        return t
    }

    /// Carried fighters (OS-03). An NPC carrier with a target launches from
    /// its first loaded bay whose cooldown has run out, restarting it at
    /// `Reload / mounted` (mounted bays, not loaded fighters: a quirk); the
    /// player launches through the secondary trigger (`launchPlayerBayFighter`).
    /// A carrier that stands down — no target — calls its fighters home, as
    /// the escort "recall" command does. A returning fighter docks within 75
    /// px of its carrier on both axes: the bay gains a fighter, and an empty
    /// bay's cooldown re-arms to a full Reload (`Ship_RecoverCarriedShipToBay`
    /// 0x00415ea0). A carrier's death orphans its flying fighters.
    private func updateFighterBays(_ dt: Double) {
        guard galaxy != nil else { return }   // fighters are spawned via the galaxy

        // Launch pass over a snapshot (launching appends to `npcs`).
        for carrier in allShips where !carrier.fighterBays.isEmpty && carrier.isAlive && !carrier.disabled {
            var nextFormationSlot = allShips.filter { $0.brain?.leaderID == carrier.entityID }.count
            for bay in carrier.fighterBays {
                bay.launchCooldown = max(0, bay.launchCooldown - dt)
                // Drop dead/orphaned fighters from the roster.
                bay.deployed = bay.deployed.filter { ship(id: $0)?.carrierID == carrier.entityID }
            }
            if !carrier.isPlayer, carrierTarget(carrier) != nil,
               let bay = carrier.fighterBays.first(where: { $0.docked > 0 && $0.launchCooldown <= 0 }),
               let fighter = launchFighter(from: carrier, bay: bay, formationSlot: nextFormationSlot) {
                nextFormationSlot += 1
                bay.docked -= 1
                bay.deployed.insert(fighter.entityID)
                bay.launchCooldown = bayReload(carrier, bay) / Double(bayMounted(carrier, bay))
            }
            // Keep the bay's WeaponMount ammo readout (the HUD's "Bay - N"
            // secondary-weapon display) in sync with the real docked count.
            for bay in carrier.fighterBays {
                if let mount = carrier.weapons.first(where: { $0.spec.id == bay.spec.bayWeaponID }) {
                    mount.ammo = bay.docked
                }
            }
            // Standing down calls the wing home (NPC carriers; the player
            // recalls by command or by jumping).
            if !carrier.isPlayer, carrierTarget(carrier) == nil {
                for bay in carrier.fighterBays {
                    for id in bay.deployed { ship(id: id)?.recallToCarrier = true }
                }
            }
        }

        // Dock pass — collect removals, apply after iterating.
        var docked: Set<Int> = []
        for f in npcs where f.carrierID != nil && f.isAlive {
            guard let carrier = ship(id: f.carrierID!), carrier.isAlive else {
                // Carrier gone for good: the fighter is orphaned — it keeps
                // fighting for its government but has no bay to return to.
                f.carrierID = nil; f.recallToCarrier = false; f.brain?.leaderID = nil
                continue
            }
            // A *disabled* carrier is a hulk, not a wreck: it can't take fighters
            // aboard while it's adrift, but its wing still belongs to it.
            guard !carrier.disabled, f.recallToCarrier else { continue }
            let d = f.position - carrier.position
            guard abs(d.x) < 75, abs(d.y) < 75 else { continue }
            if let bay = carrier.fighterBays.first(where: { $0.deployed.contains(f.entityID) })
                ?? carrier.fighterBays.first(where: { $0.spec.fighterShipID == f.shipTypeID }) {
                bay.deployed.remove(f.entityID)
                if bay.docked == 0 { bay.launchCooldown = max(bay.launchCooldown, bayReload(carrier, bay)) }
                bay.docked += 1
            }
            docked.insert(f.entityID)
        }
        if !docked.isEmpty {
            for id in docked { clearTarget(id) }
            npcs.removeAll { docked.contains($0.entityID) }
        }
    }

    /// A bay's `Reload` in seconds, and how many bay mounts it has.
    private func bayReload(_ carrier: Ship, _ bay: Ship.FighterBay) -> Double {
        Double(bay.spec.launchIntervalFrames) / OriginalClock.ticksPerSecond
    }
    private func bayMounted(_ carrier: Ship, _ bay: Ship.FighterBay) -> Int {
        max(1, carrier.weapons.first(where: { $0.spec.id == bay.spec.bayWeaponID })?.count ?? 1)
    }

    /// The player's secondary trigger on a fighter bay (OS-03): with a target
    /// in the system, launch one docked fighter; the bay then waits `Reload /
    /// mounted`.
    private func launchPlayerBayFighter(from ship: Ship, mount: WeaponMount) {
        let spec = mount.spec
        guard carrierTarget(ship) != nil,
              let bay = ship.fighterBays.first(where: { $0.spec.bayWeaponID == spec.id }),
              bay.docked > 0 else { mount.logBlockedIfNeeded(for: ship); return }
        let slot = allShips.filter { $0.brain?.leaderID == ship.entityID }.count
        guard let fighter = launchFighter(from: ship, bay: bay, formationSlot: slot) else { return }
        bay.docked -= 1
        bay.deployed.insert(fighter.entityID)
        mount.ammo = bay.docked   // `bay.docked` stays the single source of truth
        mount.cooldown = spec.reloadSeconds / Double(max(1, mount.count))
        events.append(.weaponFired(shooterID: ship.entityID, at: ship.position, heading: ship.angle,
                                   soundID: spec.fireSoundID, weaponID: spec.id))
    }

    /// Launch one fighter from `carrier`'s `bay` (`Weapon_SpawnShipFromCarrierBayWeapon`
    /// 0x0041e640): a behavior-5 escort of the carrier, so its maximum shield
    /// and armor and its shield regeneration are × 1.333 (AI-41). It starts at
    /// the carrier's centre with the carrier's velocity (A3), on the carrier's
    /// heading ± the bay's Inaccuracy, and gains the bay's `Speed / 100`
    /// px/tick along the whole-degree heading (per axis, up to its own top
    /// speed). It takes the carrier's target — except off the player's
    /// carrier — unless that target is in its own squad (A4).
    ///
    /// A fighter flies under whatever standing order its carrier's wing is on,
    /// so it fights exactly like the escorts around it.
    @discardableResult
    func launchFighter(from carrier: Ship, bay: Ship.FighterBay, formationSlot: Int) -> Ship? {
        guard let galaxy else { return nil }
        // Weapon_SpawnShipFromCarrierBayWeapon (0x0041e640) allocates with a reserve
        // of 8 (Ship_AllocateShipSlotInSystem 0x004254b0): a slot below 64 - 8 must
        // be free (slot 0 is the player), otherwise the launch fails silently.
        guard allShips.count < 64 - 8 else { return nil }
        let bayMount = carrier.weapons.first(where: { $0.spec.id == bay.spec.bayWeaponID })
        var heading = carrier.angle
        if let spec = bayMount?.spec, spec.inaccuracyDegrees > 0 {
            heading += Double(rng.range(2 * spec.inaccuracyDegrees) - spec.inaccuracyDegrees) * .pi / 180
        }
        // A launched fighter is AI-flown, so like any NPC its stats ignore its
        // hull's `DefaultItems` while its capabilities still read them.
        guard let fighter = galaxy.makeLoadedShip(bay.spec.fighterShipID, government: carrier.government,
                                                  at: carrier.position, angle: heading,
                                                  includeDefaultItems: false, defaultItemCapabilities: true) else { return nil }
        fighter.applyCarriedFighterScale()
        let brain = fighter.brain ?? AIBrain(aiType: .interceptor, govt: carrier.government)
        fighter.brain = brain
        brain.leaderID = carrier.entityID
        brain.escortOrder = carrier.isPlayer ? (playerEscortOrder ?? .defensive)
                                             : (carrier.brain?.escortOrder ?? .defensive)
        brain.formationSlot = formationSlot
        brain.provokedByPlayer = carrier.isPlayer ? false : (carrier.brain?.provokedByPlayer ?? false)
        fighter.carrierID = carrier.entityID
        var target = carrier.isPlayer ? nil : carrierTarget(carrier)
        if let t = target, t.entityID == carrier.entityID || t.brain?.leaderID == carrier.entityID {
            target = nil
        }
        fighter.currentTargetID = target?.entityID
        brain.targetID = target?.entityID
        fighter.velocity = carrier.velocity
        fighter.addPolarVelocityWithClamp(heading: wholeDegrees(heading),
                                          step: bayMount?.spec.projectileSpeed ?? 0,
                                          max: fighter.effectiveMaxSpeed)
        _ = addNPC(fighter, arrival: .launch)
        // The record starts clean (0x00402810), coasting for the bay's Count
        // ticks (wëap +2), holding the inherited target.
        let rec = originalAI.ensureRecord(fighter, host: WorldAIHost(world: self, ai: originalAI))
        rec.primary = target?.entityID
        rec.maneuverTimer = Double(galaxy.game.weapon(bay.spec.bayWeaponID)?.duration ?? 0)
        originalAI.rollVoice(rec, hull: originalAI.hull(of: fighter, world: self),
                             host: WorldAIHost(world: self, ai: originalAI))
        originalAI.noteFighterLaunched(fighter, world: self)
        return fighter
    }

    /// Player command: recall every fighter currently flying from the
    /// player's own bays — they head back and dock regardless of what they're
    /// doing (the ambient auto-recall otherwise only docks a fighter that's
    /// dry on ammo or badly hurt).
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
        let cargo = rolledPlunderCargo(s).map { [$0] } ?? []
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

    /// The crew and strength the player brings to a boarding action
    /// (`Boarding_BuildOptions` 0x00484230, EC-18): the player's class Crew and
    /// Strength, plus a tenth (truncated, one escort at a time) of each
    /// non-mission escort whose hull's InherentAI is above 2, plus the crew of
    /// positive marines outfits.
    public var playerBoardingForce: (crew: Int, strength: Int) {
        var crew = player.crew
        var strength = classStrength(player)
        for e in playerEscorts where e.missionID == nil {
            if let eh = galaxy?.game.ship(e.shipTypeID), eh.inherentAI <= 2 { continue }
            strength = Int(Double(strength) + Double(classStrength(e)) * 0.1)
            crew = Int(Double(crew) + Double(e.crew) * 0.1)
        }
        return (crew + player.marineCrew, strength)
    }

    /// A ship's class `Strength`, or its live combat strength when the hull
    /// isn't in the data.
    private func classStrength(_ s: Ship) -> Int {
        galaxy?.game.ship(s.shipTypeID)?.strength ?? Int(s.combatStrength)
    }

    /// Effective crew the player brings to a boarding action.
    public var playerBoardingCrew: Int { playerBoardingForce.crew }

    /// Capture odds (percent) for the player taking disabled hulk `target`, or
    /// nil if it can't be captured (`Boarding_BuildOptions` 0x00484230):
    ///   odds = trunc(crew / (targetCrew × 10) × 100)
    ///        + the negative-ModVal marines bonus
    ///        + 10 when the player's strength exceeds 5 × the target class's
    /// clamped to 1…75 %, and 0 for a derelict government (Flags 0x0800) or
    /// when the escort wing is full. The original's ±5 jitter is applied at the
    /// attempt (`attemptCapture`), so the displayed chance is stable.
    public func captureChance(of target: Ship) -> Int? {
        guard target.crew > 0 else { return nil }   // nothing to overpower
        let force = playerBoardingForce
        var odds = Int(Double(force.crew) / (Double(target.crew) * 10) * 100) + player.captureOddsBonus
        if classStrength(target) * 5 < force.strength { odds += 10 }
        odds = min(75, max(1, odds))
        if let g = diplomacy?.govt(target.government), g.flags1 & 0x0800 != 0 { return 0 }
        if !playerHasEscortRoom { return 0 }
        return odds
    }

    /// `Ship_CanPlayerHaveMoreEscorts` 0x00468920: fewer than six non-mission
    /// escorts.
    public var playerHasEscortRoom: Bool {
        // Bay fighters (behavior 5) are not escorts and never count.
        playerEscorts.filter { $0.carrierID != Self.playerEntityID && $0.missionID == nil }.count < 6
    }

    // MARK: Disabled escorts (AI-38, AI-41)

    /// `Ship_ApplyDamageToShip` (0x004192d0), disabled arm: a non-mission ship
    /// in the player's wing leaves it the moment it is disabled. It remembers
    /// it flew as a bay fighter or an escort (`+0xc8de`), takes its class's
    /// own AI, and a freighter escort (InherentAI < 3) first takes its share
    /// of the fleet's cargo (`.escortLeftWingDisabled`, the host's
    /// `Player_TransferCargoAndJunkToEscortByRatio` 0x00469810). A fighter
    /// drops its × 1.333 pools with its behavior.
    func leaveWingWhenDisabled(_ ship: Ship) {
        guard !ship.isPlayerControlled, ship.missionID == nil, ship.spobDefenderOf == nil,
              let brain = ship.brain, brain.leaderID == Self.playerEntityID else { return }
        let inherent = galaxy?.game.ship(ship.shipTypeID)?.inherentAI ?? 0
        let fighter = ship.carrierID == Self.playerEntityID
        ship.formerWingRole = fighter ? .fighter : .escort
        brain.leaderID = nil
        brain.aiType = AIType(raw: inherent)
        if fighter {
            for bay in player.fighterBays { bay.deployed.remove(ship.entityID) }
            ship.carrierID = nil
            ship.recallToCarrier = false
            ship.removeCarriedFighterScale()
        }
        events.append(.escortLeftWingDisabled(entityID: ship.entityID, freighter: !fighter && inherent < 3))
        Log.combat.notice("\(LogTag.ship(id: ship.entityID, name: ship.name)) disabled — left the player's wing")
    }

    /// A former escort or fighter rejoins (its repair system fired,
    /// `Ship_HandleShip` 0x00433050): leader the player again, shields 0, no
    /// target; a fighter as behavior 5 with its × 1.333 pools ("Fighter
    /// repaired.", STR# 2002 #128), an escort as behavior 6 ("Escort
    /// repaired.", #127). There is no wing-size check on this path.
    func rejoinWing(_ ship: Ship) {
        guard let role = ship.formerWingRole else { return }
        ship.formerWingRole = nil
        ship.shield = 0
        ship.currentTargetID = nil
        switch role {
        case .fighter:
            let brain = ship.brain ?? AIBrain(aiType: .interceptor, govt: player.government)
            ship.brain = brain
            brain.leaderID = Self.playerEntityID
            brain.targetID = nil
            brain.escortOrder = playerEscortOrder ?? .defensive
            ship.carrierID = Self.playerEntityID
            player.fighterBays.first { $0.spec.fighterShipID == ship.shipTypeID }?.deployed.insert(ship.entityID)
            ship.applyCarriedFighterScale(keepingLevels: true)
        case .escort:
            recruitEscort(ship)
        }
        events.append(.escortRejoined(entityID: ship.entityID, fighter: role == .fighter))
    }

    /// What boarding a disabled hulk does before any plunder window
    /// (`Player_HandleBoardTargetCommand` 0x0045a3d0), for a non-mission,
    /// non-përs ship:
    /// - a former escort, with room in the wing, is repaired back into it at
    ///   `max/3 + 1` armor (`max/10 + 1` with hull Flags 0x0010), bringing the
    ///   cargo it carried off back with it ("Escort repaired.", #127);
    /// - a former bay fighter, or any hulk of a class one of the player's bays
    ///   carries and has room for, goes straight into that bay ("Fighter
    ///   repaired." #128 / "Fighter captured." #129) — it is docked, so its
    ///   behavior-5 × 1.333 pools take effect when it is next launched.
    /// Returns nil when the boarding goes on to the plunder window.
    public enum BoardingRecovery: Equatable, Sendable {
        case escortRepaired(cargo: [Int: Int])
        case fighterRepaired
        case fighterCaptured
    }

    public func recoverOnBoarding(shipID: Int) -> BoardingRecovery? {
        guard let s = ship(id: shipID), s !== player, s.isAlive, s.disabled,
              s.missionID == nil, s.personID == nil else { return nil }
        if s.formerWingRole == .escort, playerHasEscortRoom {
            s.formerWingRole = nil
            s.armor = s.maxArmor * (s.disableArmorFraction < Ship.standardDisableFraction ? 0.1 : 0.3333) + 1
            let cargo = s.cargo
            s.cargo = [:]
            recruitEscort(s)
            events.append(.escortRejoined(entityID: s.entityID, fighter: false))
            return .escortRepaired(cargo: cargo)
        }
        guard s.formerWingRole != .escort, let bay = playerBayWithRoom(for: s.shipTypeID) else { return nil }
        let captured = s.formerWingRole == nil
        s.formerWingRole = nil
        if bay.docked == 0 { bay.launchCooldown = max(bay.launchCooldown, Double(bay.spec.launchIntervalFrames) / OriginalClock.ticksPerSecond) }
        bay.docked += 1
        if let mount = player.weapons.first(where: { $0.spec.id == bay.spec.bayWeaponID }) { mount.ammo = bay.docked }
        clearTarget(s.entityID)
        npcs.removeAll { $0 === s }
        events.append(.fighterRecoveredToBay(entityID: s.entityID, captured: captured))
        return captured ? .fighterCaptured : .fighterRepaired
    }

    /// `ShipClass_HasPlayerBayCapacityFor` (0x004694a0): a player bay that
    /// launches `shipTypeID` and holds fewer than its capacity, counting its
    /// fighters in flight.
    func playerBayWithRoom(for shipTypeID: Int) -> Ship.FighterBay? {
        player.fighterBays.first { bay in
            guard bay.spec.fighterShipID == shipTypeID else { return false }
            let flying = npcs.filter { $0.isAlive && $0.carrierID == Self.playerEntityID
                && $0.shipTypeID == shipTypeID && $0.missionID == nil }.count
            return bay.docked + flying < bay.spec.capacity
        }
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
        // Forcing entry onto a hulk is itself the crime (`BoardPenalty`),
        // independent of what's later taken or whether capture succeeds —
        // this is the only call site (`board` only ever fires for the
        // player; NPCs don't board). The revenge përs (slot 0x3fe, përs 1150)
        // and the shareware Enforcer slot after it are exempt
        // (`Player_HandleBoardTargetCommand` 0x0045a3d0).
        if s.personID != 1150 && s.personID != 1151 {
            diplomacy?.recordBoard(of: s.government, missionShip: s.missionID != nil)
        }
        // Boarding is the actual goal for both board and rescue missions. This
        // also handles ships that started disabled through their government,
        // without requiring a damage-induced disable transition. Report each
        // ship only once even if the player opens its plunder dialog again.
        if let mid = s.missionID, let goal = s.missionShipGoal,
           (goal == .board || goal == .rescue), !s.missionBoardingGoalReported {
            s.missionBoardingGoalReported = true
            // A boarded rescue ship is no longer held; its armor decides.
            if goal == .rescue { s.heldDisabled = false }
            // 0x0045a3d0's board/rescue branch: the ship coasts 100 calls and
            // every ship attacking it stands down (0x00415dc0).
            if missionBoardStandsDown(mid) {
                originalAI.setManeuverTimer(s, 100)
                originalAI.clearShipsTargeting(s, in: self)
            }
            events.append(.missionShipGoalReached(missionID: mid, entityID: s.entityID,
                                                  goal: goal, byPlayer: true))
        }
        return manifest
    }

    /// Credits aboard a hulk (EC-18): a düde ship with Booty 0x40 has them set
    /// at spawn (`assignBootyCredits`); a named person carries
    /// `bootyCredits(Credits, × 0.5)` with no floor; any other ship carries
    /// none. Rolled once and cached on the ship.
    private func rolledPlunderCredits(_ s: Ship) -> Int {
        if s.plunderCredits < 0 {
            if let pid = s.personID, let pers = galaxy?.game.pers(pid) {
                s.plunderCredits = Self.bootyCredits(base: pers.credits, factor: 0.5, floorAt1000: false) { rng.range($0) }
            } else {
                s.plunderCredits = 0
            }
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

    /// The cargo a boarded hulk offers (`Boarding_BuildOptions` 0x00484230,
    /// EC-18) — rolled from its düde's Booty, not from what its hold carries:
    /// one commodity drawn by `rand(7)` until it lands on a Booty bit
    /// (0x01 food … 0x20 equipment), in `rand(holds/2) + holds/2` tons of the
    /// hull's Holds. No Booty commodity bit (or no holds) means no cargo. The
    /// original's draw spins forever on Booty with only bits above 0x40; that
    /// case offers nothing here. Rolled once per hulk.
    private func rolledPlunderCargo(_ s: Ship) -> (commodity: Int, tons: Int)? {
        if let roll = s.plunderCargoRoll { return roll }
        var roll: (commodity: Int, tons: Int)?
        if s.dudeBooty & 0x3f != 0 {
            var commodity = rng.range(7)
            while commodity > 5 || s.dudeBooty & (1 << commodity) == 0 { commodity = rng.range(7) }
            let holds = galaxy?.game.ship(s.shipTypeID)?.cargoSpace ?? 0
            if holds >= 1 {
                let half = holds / 2
                let tons = rng.range(half) + half
                if tons >= 1 { roll = (commodity, tons) }
            }
        }
        s.plunderCargoRoll = .some(roll)
        return roll
    }

    /// Take a hulk's cargo roll into the player's hold, cut to the free space
    /// (`room`, the fleet's when the host knows it; else the player ship's),
    /// and return what was taken. The roll is spent either way — with no room
    /// the original still clears the option (0x00482940).
    @discardableResult
    public func takePlunderCargo(from shipID: Int, room: Int? = nil) -> [(commodity: Int, tons: Int)] {
        guard let s = ship(id: shipID), let roll = rolledPlunderCargo(s) else { return [] }
        s.plunderCargoRoll = .some(nil)
        let move = min(roll.tons, room ?? player.cargoFree)
        guard move >= 1 else { return [] }
        player.cargo[roll.commodity, default: 0] += move
        return [(roll.commodity, move)]
    }

    /// Attempt to capture a hulk given a 0–99 `roll` (supplied by the caller so
    /// the outcome is reproducible for a given roll). The base chance is jittered
    /// by ±5% (world RNG, per the Bible) before the roll is compared. On success
    /// a `.shipCaptured` event fires and the captured hull's type/name are
    /// returned; nil on failure. Deliberately does **not** decide what happens
    /// to the hulk — EV Nova offers a choice here ("use as escort" or "take
    /// command of it yourself"), so the caller commits via `recruitEscort`
    /// (join the wing) or its own flagship-swap logic (take command), using
    /// this same roll rather than re-rolling for each possible outcome.
    public func attemptCapture(shipID: Int, roll: Int) -> (shipTypeID: Int, name: String)? {
        guard let s = ship(id: shipID), s !== player, s.isAlive, s.disabled,
              let chance = captureChance(of: s), chance > 0 else { return nil }
        let effective = min(75, max(1, chance + 5 - rng.range(11)))
        guard roll <= effective else { return nil }
        events.append(.shipCaptured(entityID: s.entityID, shipTypeID: s.shipTypeID, at: s.position))
        Log.combat.notice("\(LogTag.ship(id: s.entityID, name: s.name)) captured (roll \(roll) < \(effective))")
        return (s.shipTypeID, personName(s) ?? s.name)
    }

    /// What a capture attempt comes to (0x00482940:426–530, #10).
    public enum CaptureOutcome: Equatable {
        /// The roll failed (STR# 2002 #125).
        case failed
        /// The crew scuttled the ship, one success in ten (#113).
        case selfDestructs
        /// No room for another escort: no capture at all (#124).
        case noRoom
        /// The player's hull has no crew to spare: it joins as an escort
        /// without asking.
        case joinsAsEscort(shipTypeID: Int, name: String)
        /// Ask: take command, or keep it as an escort (DLOG 1018).
        case offerChoice(shipTypeID: Int, name: String)
    }

    /// Roll and resolve a capture with the world's generator, in the
    /// original's order: `Rand(100)` against the odds, then `Rand(10) == 0`
    /// self-destructs, then the escort-room test, then the player's crew.
    public func resolveCapture(shipID: Int) -> CaptureOutcome {
        guard let cap = attemptCapture(shipID: shipID, roll: rng.range(100)) else { return .failed }
        if rng.range(10) == 0 { return .selfDestructs }
        guard playerHasEscortRoom else { return .noRoom }
        if player.crew < 1 { return .joinsAsEscort(shipTypeID: cap.shipTypeID, name: cap.name) }
        return .offerChoice(shipTypeID: cap.shipTypeID, name: cap.name)
    }

    /// The default name the Take Command prompt offers (STR# 2002 #119):
    /// the class name, a space and three `Rand(9) + 1` digits.
    public func capturedShipDefaultName(shipTypeID: Int) -> String {
        let base = galaxy?.game.ship(shipTypeID)?.name ?? ""
        let digits = (0..<3).map { _ in String(rng.range(9) + 1) }.joined()
        return base + " " + digits
    }

    /// Recruit an already-captured hulk (`attemptCapture` succeeded for
    /// `shipID`) into the player's escort wing — the "use as escort" outcome.
    public func recruitCapturedEscort(shipID: Int) {
        guard let s = ship(id: shipID) else { return }
        recruitEscort(s)
        // The prize keeps its boarded latch (+0xb9).
        originalAI.setBoarded(s.entityID, true)
    }

    /// The player leaves a hulk they boarded without capturing it: forcing
    /// entry dooms the ship rather than leaving it drifting forever — it's
    /// destroyed here (zeroed armor/shield lets the normal explosion/
    /// `.shipDestroyed` pipeline in `despawnDepartedAndDead` handle the rest
    /// next step) unless it's no longer a boardable disabled hulk, which
    /// covers the capture case for free: `recruitEscort` already clears
    /// `disabled` before this could ever run for a captured ship. A `.rescue`
    /// mission ship is exempted — boarding it already completed the mission by
    /// *saving* it (`World.board`), so blowing it up afterward would fire a
    /// contradictory `missionShipLost` right behind the success.
    public func finishBoardingWithoutCapture(shipID: Int) {
        // The original only marks the hulk boarded and leaves it drifting
        // disabled (EC-18); nothing to do here.
        _ = shipID
    }

    /// Recruit `ship` as a player escort (the capture branch of 0x00482940,
    /// the hire spawn 0x00422400): it flies for no government (#13) unless it
    /// belongs to a mission fleet, no longer counts as a përs, and its AI
    /// starts over as an escort while every ship that was targeting it stands
    /// down (#2). Assigns the next free formation slot and gives it a brain if
    /// it somehow lacked one.
    public func recruitEscort(_ ship: Ship) {
        let brain = ship.brain ?? AIBrain(aiType: .warship, govt: player.government)
        ship.brain = brain
        if ship.missionID == nil { ship.government = independentGovt }
        ship.personID = nil
        brain.leaderID = Self.playerEntityID
        brain.escortOrder = .defensive
        brain.provokedByPlayer = false
        brain.formationSlot = playerEscorts.filter { $0.entityID != ship.entityID }.count
        // A captured hulk joins at half its armor (0x00482940); disable is
        // derived from armor, so it is no longer disabled.
        if ship.disabled { ship.armor = ship.maxArmor * 0.5 }
        ship.disabled = false
        ship.currentTargetID = nil
        originalAI.adoptIntoPlayerWing(ship, world: self)
        Log.combat.notice("\(LogTag.ship(id: ship.entityID, name: ship.name)) recruited as escort")
    }

    /// Release `ship` from the player's command (the escort window's Release,
    /// 0x004853a0): it stays in the system as an ordinary NPC flying `aiType`,
    /// its class's default behavior, with no target. The original escort
    /// supervisor sees the missing leader and drops the escort behavior itself.
    public func releaseFromPlayerCommand(_ ship: Ship, aiType: AIType) {
        guard let brain = ship.brain, brain.leaderID == Self.playerEntityID else { return }
        brain.leaderID = nil
        brain.aiType = aiType
        ship.currentTargetID = nil
        Log.combat.notice("\(LogTag.ship(id: ship.entityID, name: ship.name)) released from the player's command")
    }

    /// Lock a specific ship by id (click-to-select). Unlike
    /// `selectNearestTarget`, this has no range gate — if it's on screen, it's
    /// selectable, including disabled hulks that can be boarded.
    @discardableResult
    public func selectTarget(id: Int) -> Ship? {
        guard let ship = npcs.first(where: { $0.entityID == id }), ship.isAlive,
              canTarget(ship, by: player) else { return nil }
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
