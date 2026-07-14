import Foundation
import NovaSwiftKit

/// Scales that map EV Nova's integer combat stats into simulation units. EV Nova
/// runs its projectile logic at 30 fps and stores speeds in the same "unit" space
/// as ship speeds, so we reuse the flight speed scale to keep ships and their
/// shots proportional. Damage numbers are HP and used directly.
public struct CombatTuning {
    /// Stat "speed unit" → px/sec. Matches `FlightTuning.speedScale` so a shot
    /// from a fast ship still outruns it.
    public var unitToPxPerSec: Double = 1.0
    /// The rate EV Nova ticks weapon durations/reloads at.
    public var framesPerSecond: Double = 30
    /// Global multiplier on all weapon damage (difficulty / feel).
    public var damageScale: Double = 1.0
    /// Shield/armor stat → HP scale.
    public var hpScale: Double = 1.0
    /// EV Nova stores recharge as "points per 1/30 s"; convert to per-second and
    /// soften a little so fights aren't unkillable.
    public var rechargeToPerSec: Double = 1.2
    /// Extra multiplier on damage the *player's* ship takes (difficulty). 1 =
    /// normal, <1 more forgiving (Easy), >1 harsher (Hard). Applied per hit in
    /// `World.applyHit`, so it never touches NPC-vs-NPC combat.
    public var playerDamageScale: Double = 1.0

    public static let `default` = CombatTuning()
}

/// Which set of a hull's `shän` weapon exit points a weapon fires from — the
/// real per-hull hardpoints, so a shot leaves the gun barrel / turret / launch
/// bay it belongs to instead of the ship's centre. Derived from `wëap`'s
/// `exitType` field.
public enum WeaponExitType: Equatable {
    case center, gun, turret, guided, beam

    /// Map `WeapRes.exitType` (-1 centre / 0 gun / 1 turret / 2 guided / 3 beam).
    public init(raw: Int) {
        switch raw {
        case 0: self = .gun
        case 1: self = .turret
        case 2: self = .guided
        case 3: self = .beam
        default: self = .center
        }
    }
}

/// A weapon's submunition burst: on expiry/detonation the shot spawns `count`
/// copies of weapon `weaponID`, spread by `thetaRadians`, with recursion capped
/// at `limit`. See EV Nova Bible `SubCount`/`SubType`/`SubTheta`/`SubLimit`.
public struct Submunition {
    public let weaponID: Int
    public let count: Int
    public let thetaRadians: Double
    public let limit: Int
    public let ifExpire: Bool
    public let fireAtNearest: Bool
    public init(weaponID: Int, count: Int, thetaRadians: Double, limit: Int,
                ifExpire: Bool, fireAtNearest: Bool) {
        self.weaponID = weaponID; self.count = count; self.thetaRadians = thetaRadians
        self.limit = limit; self.ifExpire = ifExpire; self.fireAtNearest = fireAtNearest
    }
}

/// A simulation-ready weapon: damage, reach, fire rate, projectile behaviour.
/// Built from a decoded `WeapRes` via `CombatTuning`.
public struct WeaponSpec {
    public let id: Int
    public let name: String
    public let shieldDamage: Double
    public let armorDamage: Double
    /// `wëap` Flags 0x0020 — "passes through shields": this weapon's armor damage
    /// reaches the hull even while the target's shields are up. Off for the vast
    /// majority of weapons, which can't touch armor until shields are gone.
    public let penetratesShields: Bool
    public let reloadSeconds: Double
    public let projectileSpeed: Double   // px/sec
    public let range: Double             // px
    public let accuracyRadians: Double
    public let isBeam: Bool
    public let isGuided: Bool
    /// Full EV Nova guidance kind — drives how the shot is aimed (turret lead,
    /// quadrant lock, rocket) and how the projectile moves.
    public let guidance: WeaponGuidance
    /// Turreted (turret / beamTurret): aims independently of the hull's facing.
    public let isTurret: Bool
    /// Which hull hardpoint set this weapon's shots leave from.
    public let exitType: WeaponExitType
    /// Rendered beam thickness in px (beams only; 0 → engine default).
    public let beamWidth: Double
    /// Rendered beam colour as 0–1 RGB (beams only). Nil → engine default tint.
    public let beamColor: (r: Double, g: Double, b: Double)?
    public let turnRate: Double          // rad/sec, guided munitions
    public let blastRadius: Double       // px, 0 = direct hit only
    public let ammoPerShot: Int          // 0/1 typically; drains mount ammo
    /// Raw `wëap.AmmoType`. Special values drive firing side-effects: -999 = the
    /// firing ship self-destructs when it fires; ≤ -1000 = the weapon burns
    /// `abs(AmmoType+1000)/10` fuel units per shot instead of drawing ammo.
    public let ammoTypeRaw: Int
    /// `snd ` id played when this weapon fires, or nil if silent.
    public let fireSoundID: Int?
    /// `bööm` id detonated on impact/expiry, or nil if this weapon has no explosion.
    public let explosionBoomID: Int?
    /// Continuous-fire weapons (typically beams) trigger their sound once per
    /// firing burst rather than once per simulation frame.
    public let loopSound: Bool
    /// Guidance 9/10: "fires automatically at incoming guided weapons and
    /// nearby ships" (Bible) — driven by a separate targeting loop, see
    /// `World.runPointDefense`.
    public let isPointDefense: Bool
    /// Whether a *guided* shot from this weapon can be shot down by point
    /// defense (`wëap.Flags` 0x0080 inverted). Ignored for non-guided weapons.
    public let vulnerableToPD: Bool
    /// "The amount of ionization energy to add to the ship that gets hit by
    /// this weapon" (Bible) — added to the victim's `Ship.ionCharge` on hit.
    public let ionization: Double
    /// Seeker 0x0020: this (guided) weapon refuses to fire while its own ship
    /// is ionized.
    public let cantFireWhileIonized: Bool
    /// Seeker 0x0008: "Confused by sensor interference" — this guided shot's
    /// tracking degrades as the system's `sÿst.Interference` static rises.
    public let confusedByInterference: Bool
    /// Seeker 0x0010: "Turns away if jammed" — this guided shot can lose lock
    /// on a target whose government's `InhJam1-4` jamming is strong enough.
    public let turnsAwayIfJammed: Bool
    /// Proximity-fuse radius in px (unguided missiles/bombs): the shot detonates
    /// within this distance of a valid target instead of needing a direct hit.
    public let proxRadius: Double
    /// Whether the proximity fuse triggers on any valid ship, not just the target.
    public let proxHitAll: Bool
    /// Arming delay before the shot can collide/detonate (seconds).
    public let proxSafetySeconds: Double
    /// Damage lost per second while the shot flies (`wëap.Decay`). 0 = none.
    public let decayPerSec: Double
    /// Flak behaviour: detonate at the end of the shot's life.
    public let detonateOnExpire: Bool
    /// Knockback impulse on hit (inversely ∝ target mass).
    public let impact: Double
    /// Recoil "kick" pushed onto the *firing* ship opposite the shot direction
    /// (`wëap.Recoil`), inversely ∝ the shooter's mass. 0 = none.
    public let recoil: Double
    /// `spïn` id of this weapon's own shot graphic, or nil (falls back to a dot).
    public let graphicSpinID: Int?
    /// Spin the shot graphic continuously.
    public let spinShots: Bool
    /// Fires at a fixed angle (accuracy stored negative) — no target lead.
    public let firesAtFixedAngle: Bool
    /// Burst fire: N shots at the fast `reloadSeconds` cadence, then a long
    /// `burstReloadSeconds` cooldown. 0 = no burst.
    public let burstCount: Int
    public let burstReloadSeconds: Double
    /// Submunition split on expiry/detonation, or nil.
    public let submunition: Submunition?

    /// Fires on the secondary trigger (missiles/rockets), not the primary.
    public let isSecondary: Bool
    /// Multiple copies fire in one volley (flag 0x0040). When false — the default —
    /// copies stagger: one barrel at a time at `reload / count`.
    public let fireSimultaneously: Bool
    /// `Flags3` 0x0020: while this weapon is firing or reloading, none of the ship's
    /// other weapons may fire (Bible). Enforced in `World.fireWeapons`.
    public let isExclusive: Bool
    /// `Flags3` 0x0004: the firing ship can't loose another shot of this weapon
    /// until its previous one expires or hits something (Bible).
    public let cantRefireUntilShotEnds: Bool
    /// `Flags3` 0x0010: fire from whichever hardpoint is closest to the target,
    /// rather than cycling the weapon's exit points in order (Bible).
    public let firesFromClosestExit: Bool
    /// `wëap.Durability`: point-defense hits a *guided* shot from this weapon can
    /// absorb before being destroyed. 0 = shot down by any PD hit (the default).
    public let durability: Int
    /// `Flags3` 0x0001: ammo is charged once at the end of a burst cycle, not per
    /// shot inside the burst (a multi-shot round that costs a single unit).
    public let oneAmmoPerBurst: Bool
    /// `Flags3` 0x0002: this weapon's shots are drawn translucent (visual only).
    public let translucentShots: Bool

    /// Whether shots from this weapon home on a target (fly inertialessly toward
    /// the intercept). True for guidance `.guided`; also honours the legacy
    /// `isGuided` flag when `guidance` was left unset (synthetic/test specs).
    public var homes: Bool { guidance == .guided || (guidance == .unguided && isGuided) }
    /// Whether shots accelerate forward from launch (rockets).
    public var accelerates: Bool { guidance == .rocket }
    /// `AmmoType == -999`: the firing ship is destroyed the instant it fires this
    /// weapon (a suicide/self-destruct weapon).
    public var selfDestructsOnFire: Bool { ammoTypeRaw == -999 }
    /// `AmmoType <= -1000`: fuel units consumed per shot (`abs(AmmoType+1000)/10`).
    /// 0 for a normal ammo/unlimited weapon.
    public var fuelPerShot: Double { ammoTypeRaw <= -1000 ? Double(abs(ammoTypeRaw + 1000)) / 10.0 : 0 }
    /// A beam whose `Impact` is negative acts as a tractor beam, pulling the
    /// target toward the firing ship instead of shoving it away (Bible).
    public var isTractorBeam: Bool { isBeam && impact < 0 }

    public init(id: Int, name: String, shieldDamage: Double, armorDamage: Double,
                reloadSeconds: Double, projectileSpeed: Double, range: Double,
                accuracyRadians: Double, isBeam: Bool, isGuided: Bool,
                turnRate: Double, blastRadius: Double, ammoPerShot: Int,
                exitType: WeaponExitType = .center,
                beamWidth: Double = 0, beamColor: (r: Double, g: Double, b: Double)? = nil,
                fireSoundID: Int? = nil, explosionBoomID: Int? = nil, loopSound: Bool = false,
                isPointDefense: Bool = false, vulnerableToPD: Bool = true,
                ionization: Double = 0, cantFireWhileIonized: Bool = false,
                confusedByInterference: Bool = false, turnsAwayIfJammed: Bool = false,
                guidance: WeaponGuidance = .unguided, isTurret: Bool = false,
                proxRadius: Double = 0, proxHitAll: Bool = true,
                proxSafetySeconds: Double = 0, decayPerSec: Double = 0,
                detonateOnExpire: Bool = false, impact: Double = 0, recoil: Double = 0,
                graphicSpinID: Int? = nil, spinShots: Bool = false, firesAtFixedAngle: Bool = false,
                burstCount: Int = 0, burstReloadSeconds: Double = 0,
                submunition: Submunition? = nil,
                isSecondary: Bool = false, fireSimultaneously: Bool = false,
                penetratesShields: Bool = false,
                isExclusive: Bool = false, cantRefireUntilShotEnds: Bool = false,
                firesFromClosestExit: Bool = false, durability: Int = 0,
                oneAmmoPerBurst: Bool = false, translucentShots: Bool = false,
                ammoTypeRaw: Int = -1) {
        self.id = id; self.name = name
        self.shieldDamage = shieldDamage; self.armorDamage = armorDamage
        self.penetratesShields = penetratesShields
        self.reloadSeconds = reloadSeconds; self.projectileSpeed = projectileSpeed
        self.range = range; self.accuracyRadians = accuracyRadians
        self.isBeam = isBeam; self.isGuided = isGuided; self.turnRate = turnRate
        self.exitType = exitType; self.beamWidth = beamWidth; self.beamColor = beamColor
        self.blastRadius = blastRadius; self.ammoPerShot = ammoPerShot
        self.fireSoundID = fireSoundID; self.explosionBoomID = explosionBoomID
        self.loopSound = loopSound
        self.isPointDefense = isPointDefense; self.vulnerableToPD = vulnerableToPD
        self.ionization = ionization; self.cantFireWhileIonized = cantFireWhileIonized
        self.confusedByInterference = confusedByInterference; self.turnsAwayIfJammed = turnsAwayIfJammed
        self.guidance = guidance; self.isTurret = isTurret
        self.proxRadius = proxRadius; self.proxHitAll = proxHitAll
        self.proxSafetySeconds = proxSafetySeconds
        self.decayPerSec = decayPerSec; self.detonateOnExpire = detonateOnExpire
        self.impact = impact; self.recoil = recoil
        self.graphicSpinID = graphicSpinID; self.spinShots = spinShots
        self.firesAtFixedAngle = firesAtFixedAngle
        self.burstCount = burstCount; self.burstReloadSeconds = burstReloadSeconds
        self.submunition = submunition
        self.isSecondary = isSecondary; self.fireSimultaneously = fireSimultaneously
        self.isExclusive = isExclusive; self.cantRefireUntilShotEnds = cantRefireUntilShotEnds
        self.firesFromClosestExit = firesFromClosestExit; self.durability = durability
        self.oneAmmoPerBurst = oneAmmoPerBurst; self.translucentShots = translucentShots
        self.ammoTypeRaw = ammoTypeRaw
    }

    /// Convert a decoded weapon into simulation units.
    public init(_ w: WeapRes, tuning: CombatTuning = .default) {
        id = w.id
        name = w.name
        shieldDamage = Double(w.shieldDamage) * tuning.damageScale
        armorDamage = Double(w.armorDamage) * tuning.damageScale
        penetratesShields = w.penetratesShields
        reloadSeconds = max(0.1, Double(w.reload) / tuning.framesPerSecond)
        projectileSpeed = Double(w.speed) * tuning.unitToPxPerSec
        // WeapRes.range is speed(unit/frame)×duration(frames); scale to px.
        range = max(60, w.range * tuning.unitToPxPerSec / tuning.framesPerSecond)
        accuracyRadians = Double(w.accuracy) * .pi / 180.0
        isBeam = w.isBeam
        isGuided = w.isGuided
        guidance = w.guidance
        isTurret = w.isTurret
        proxRadius = Double(max(0, w.proxRadius))
        proxHitAll = w.proxHitAll
        proxSafetySeconds = Double(max(0, w.proxSafety)) / tuning.framesPerSecond
        // Decay: "-1 point of shield & armor damage every `decay` frames" →
        // points/sec = framesPerSecond / decay.
        decayPerSec = w.decay > 0 ? tuning.framesPerSecond / Double(w.decay) : 0
        detonateOnExpire = w.detonateOnExpire
        // Impact may be negative — a negative Impact on a beam makes it a tractor
        // beam (pull, not push). The projectile knockback path guards on `> 0`, so
        // a negative value is simply inert there.
        impact = Double(w.impact)
        recoil = Double(w.recoil)
        graphicSpinID = w.graphicSpinID
        spinShots = w.spinShots
        firesAtFixedAngle = w.firesAtFixedAngle
        burstCount = max(0, w.burstCount)
        burstReloadSeconds = w.burstReload > 0 ? Double(w.burstReload) / tuning.framesPerSecond : 0
        submunition = w.hasSubmunition
            ? Submunition(weaponID: w.subID, count: w.subCount,
                          thetaRadians: Double(w.subTheta) * .pi / 180.0,
                          limit: max(0, w.subLimit), ifExpire: w.subIfExpire,
                          fireAtNearest: w.subFireAtNearest)
            : nil
        // Honour the weapon's declared exit type; fall back to a sensible hardpoint
        // set by guidance when the data leaves it at "centre" (-1) so a gun still
        // leaves the gun ports rather than the hull's dead centre.
        var et = WeaponExitType(raw: w.exitType)
        if et == .center {
            if w.isBeam { et = .beam }
            else if w.isGuided { et = .guided }
            else if w.isTurret { et = .turret }
            else { et = .gun }
        }
        exitType = et
        beamWidth = Double(max(0, w.beamWidth))
        beamColor = w.isBeam ? (Double(w.beamColor.r) / 255.0,
                                Double(w.beamColor.g) / 255.0,
                                Double(w.beamColor.b) / 255.0) : nil
        turnRate = Double(w.turnRate) * 3.0 * .pi / 180.0
        blastRadius = Double(w.blastRadius)
        ammoPerShot = w.maxAmmo > 0 ? 1 : 0
        isSecondary = w.firedBySecondTrigger
        fireSimultaneously = w.fireSimultaneously
        isExclusive = w.isExclusive
        cantRefireUntilShotEnds = w.cantRefireUntilShotEnds
        firesFromClosestExit = w.firesFromClosestExit
        durability = max(0, w.durability)
        oneAmmoPerBurst = w.oneAmmoPerBurst
        translucentShots = w.translucentShots
        ammoTypeRaw = w.ammoType
        fireSoundID = w.fireSoundID
        explosionBoomID = w.explosionBoomID
        loopSound = w.loopSound
        isPointDefense = w.isPointDefense
        vulnerableToPD = w.vulnerableToPD
        ionization = Double(w.ionization)
        cantFireWhileIonized = w.cantFireWhileIonized
        confusedByInterference = w.confusedByInterference
        turnsAwayIfJammed = w.turnsAwayIfJammed
    }
}

/// One installed *weapon type* on a ship (EV Nova groups by type, not by barrel):
/// its spec, how many copies are fitted (`count`), the shared ammo pool, and the
/// group's cooldown. Multiple copies stagger — one barrel at a time at
/// `reload / count`, cycling through the hull's exit points — unless the weapon
/// has the "fire simultaneously" flag. See `World.fireWeapons`.
public final class WeaponMount {
    public let spec: WeaponSpec
    /// Number of copies of this weapon fitted (drives the staggered fire rate and
    /// how many exit points to cycle through).
    public var count: Int
    public var cooldown: Double = 0      // seconds until the group can fire again
    public var ammo: Int                 // pooled across the group; -1 = unlimited
    /// The next hull hardpoint (of `spec.exitType`) this group fires from,
    /// advanced each shot so successive shots leave successive barrels.
    public var exitCursor: Int = 0
    /// Shots fired since the last burst reload (only meaningful when
    /// `spec.burstCount > 0`); the group bursts `burstCount × count` before the
    /// long reload.
    public var burstShots: Int = 0

    /// Which blocked-fire reason we last logged, so a held-down fire button
    /// while reloading/dry doesn't spam the log every frame — only the frame
    /// the reason first appears (or changes) gets a line.
    private var loggedBlockReason: String?

    public init(spec: WeaponSpec, ammo: Int = -1, count: Int = 1) {
        self.spec = spec
        self.ammo = ammo
        self.count = max(1, count)
    }

    public var ready: Bool { cooldown <= 0 && (ammo != 0) }

    /// Advance the cooldown clock.
    public func tick(_ dt: Double) { if cooldown > 0 { cooldown -= dt } }

    /// The reload the group takes for a normal shot: `reload / count` for the
    /// usual staggered weapons, or the flat `reload` when they fire simultaneously.
    public var perShotReload: Double {
        spec.fireSimultaneously ? spec.reloadSeconds : spec.reloadSeconds / Double(max(1, count))
    }

    /// Record that the group fired `shots` shots this event: spend ammo, advance
    /// the burst counter, and set the next cooldown (the long burst reload once
    /// the burst is spent).
    public func didFire(shots: Int) {
        if spec.burstCount > 0 {
            burstShots += shots
            // Normally ammo is spent per shot. `Flags3` 0x0001 (oneAmmoPerBurst)
            // instead charges a single round for the whole burst, spent only when
            // the burst completes (a multi-shot missile that costs one missile).
            if !spec.oneAmmoPerBurst, ammo > 0, spec.ammoPerShot > 0 {
                ammo = max(0, ammo - shots * spec.ammoPerShot)
            }
            if burstShots >= spec.burstCount * max(1, count) {
                if spec.oneAmmoPerBurst, ammo > 0, spec.ammoPerShot > 0 {
                    ammo = max(0, ammo - spec.ammoPerShot)
                }
                cooldown = spec.burstReloadSeconds > 0 ? spec.burstReloadSeconds : perShotReload
                burstShots = 0
                return
            }
            cooldown = perShotReload
            return
        }
        if ammo > 0, spec.ammoPerShot > 0 { ammo = max(0, ammo - shots * spec.ammoPerShot) }
        cooldown = perShotReload
    }

    /// Called when something tried to fire this mount but it wasn't `ready` —
    /// the invisible "why didn't my weapon fire" case (reload not up yet, or
    /// dry on ammo). Logs once per transition into/within a block reason.
    func logBlockedIfNeeded(for ship: Ship) {
        guard !ready else { loggedBlockReason = nil; return }
        let reason = ammo == 0 ? "out of ammo" : "reloading"
        guard loggedBlockReason != reason else { return }
        loggedBlockReason = reason
        let weaponName = spec.name
        Log.combat.debug("\(ship.name) [\(ship.entityID)] weapon \(weaponName) did not fire: \(reason)")
    }
}

/// A live projectile in the world. Guided shots steer toward `targetID`; rockets
/// accelerate; shots can decay in power, detonate by proximity, and split into
/// submunitions.
public final class Projectile {
    public var position: Vec2
    public var velocity: Vec2
    public var life: Double              // seconds remaining
    public var shieldDamage: Double      // var: decays over the shot's life
    public var armorDamage: Double
    /// `wëap` Flags 0x0020: armor damage reaches the hull through live shields.
    public let penetratesShields: Bool
    public let blastRadius: Double
    public let ownerID: Int              // entity that fired it (no self-hit)
    public let ownerGovt: Int            // faction (no friendly fire)
    /// The `wëap` id that fired this shot — lets `Flags3` 0x0004 ("can't refire
    /// until the previous shot ends") test whether the owner still has one aloft.
    public let weaponID: Int
    /// `wëap.Durability`: remaining point-defense hits this (guided) shot survives
    /// before it's destroyed. Decremented per PD hit; 0 ⇒ next hit kills it.
    public var pdDurability: Int
    /// Homing (guided): steers toward the intercept point, flying inertialess
    /// (velocity = heading × speed).
    public let homing: Bool
    /// Rocket: accelerates forward from launch up to `speed`.
    public let accelerating: Bool
    public let turnRate: Double
    public let speed: Double              // cruise / cap speed (px/sec)
    public var facing: Double             // heading, for rendering the shot sprite
    public var targetID: Int?            // for guided/homing munitions
    public var alive = true
    /// Whether point defense can shoot this shot down (`wëap.Flags` 0x0080
    /// inverted) — only meaningful for guided shots; see `World.runPointDefense`.
    public let vulnerableToPD: Bool
    /// Ionization energy this shot adds to whatever it hits.
    public let ionization: Double
    /// Points of shield & armor damage lost per second in flight (`wëap.Decay`).
    public let decayPerSec: Double
    /// Proximity fuse radius (px) and remaining arming delay (s).
    public let proxRadius: Double
    public var proxSafetyRemaining: Double
    /// Whether the proximity fuse triggers on any valid ship (not just the target).
    public let proxHitAll: Bool
    /// Detonate (explosion + submunitions) at the end of life, not just on hit.
    public let detonateOnExpire: Bool
    /// Knockback impulse imparted on hit.
    public let impact: Double
    /// Submunition split on expiry/detonation, and how many splits deep we are.
    public let submunition: Submunition?
    public let subDepth: Int
    /// `bööm` explosion id for the detonation effect, or nil.
    public let explosionBoomID: Int?
    /// Shot sprite (`spïn` id) and whether it spins, for the renderer.
    public let graphicSpinID: Int?
    public let spinShots: Bool
    /// `wëap.Flags3` 0x0002: draw this shot translucent (renderer applies alpha).
    public let translucentShots: Bool
    /// Seeker 0x0008: tracking degrades as system Interference rises.
    public let confusedByInterference: Bool
    /// Seeker 0x0010: can lose lock on a target whose government jams hard enough.
    public let turnsAwayIfJammed: Bool

    public init(position: Vec2, velocity: Vec2, life: Double,
                shieldDamage: Double, armorDamage: Double, blastRadius: Double,
                ownerID: Int, ownerGovt: Int, homing: Bool, turnRate: Double,
                speed: Double, targetID: Int?, vulnerableToPD: Bool = true,
                ionization: Double = 0, accelerating: Bool = false, facing: Double = 0,
                decayPerSec: Double = 0, proxRadius: Double = 0, proxSafetyRemaining: Double = 0,
                proxHitAll: Bool = true, detonateOnExpire: Bool = false, impact: Double = 0,
                submunition: Submunition? = nil, subDepth: Int = 0,
                explosionBoomID: Int? = nil, graphicSpinID: Int? = nil, spinShots: Bool = false,
                confusedByInterference: Bool = false, turnsAwayIfJammed: Bool = false,
                penetratesShields: Bool = false, weaponID: Int = -1, pdDurability: Int = 0,
                translucentShots: Bool = false) {
        self.weaponID = weaponID; self.pdDurability = pdDurability
        self.translucentShots = translucentShots
        self.confusedByInterference = confusedByInterference; self.turnsAwayIfJammed = turnsAwayIfJammed
        self.position = position; self.velocity = velocity; self.life = life
        self.shieldDamage = shieldDamage; self.armorDamage = armorDamage
        self.penetratesShields = penetratesShields
        self.blastRadius = blastRadius; self.ownerID = ownerID; self.ownerGovt = ownerGovt
        self.homing = homing; self.turnRate = turnRate; self.speed = speed
        self.targetID = targetID
        self.ionization = ionization
        self.vulnerableToPD = vulnerableToPD
        self.accelerating = accelerating; self.facing = facing
        self.decayPerSec = decayPerSec
        self.proxRadius = proxRadius; self.proxSafetyRemaining = proxSafetyRemaining
        self.proxHitAll = proxHitAll; self.detonateOnExpire = detonateOnExpire
        self.impact = impact
        self.submunition = submunition; self.subDepth = subDepth
        self.explosionBoomID = explosionBoomID
        self.graphicSpinID = graphicSpinID; self.spinShots = spinShots
    }
}

/// A hull's real weapon exit points (from its `shän`), in the engine's maths
/// convention: origin at the hull centre, **+y toward the nose**, +x to the
/// ship's right, in unrotated sprite pixels. (`shän` already stores y
/// nose-positive, matching this y-up world — see `Galaxy.exitPoints`.)
/// `muzzleOffset` rotates one of these into world space for the current heading.
public struct ShipExitPoints {
    public var gun: [Vec2]
    public var turret: [Vec2]
    public var guided: [Vec2]
    public var beam: [Vec2]
    /// Per-point `z` (screen-vertical) nudges, added after x/y and compression,
    /// **unscaled** (Bible: positive z moves up the screen). Parallel to the
    /// point arrays; an empty array means all-zero.
    public var gunZ: [Double]
    public var turretZ: [Double]
    public var guidedZ: [Double]
    public var beamZ: [Double]
    /// Perspective foreshortening (x%, y%) for hulls facing screen-up / screen-down.
    public var upCompress: (x: Double, y: Double)
    public var downCompress: (x: Double, y: Double)

    public init(gun: [Vec2], turret: [Vec2], guided: [Vec2], beam: [Vec2],
                gunZ: [Double] = [], turretZ: [Double] = [], guidedZ: [Double] = [], beamZ: [Double] = [],
                upCompress: (x: Double, y: Double) = (100, 100),
                downCompress: (x: Double, y: Double) = (100, 100)) {
        self.gun = gun; self.turret = turret; self.guided = guided; self.beam = beam
        self.gunZ = gunZ; self.turretZ = turretZ; self.guidedZ = guidedZ; self.beamZ = beamZ
        self.upCompress = upCompress; self.downCompress = downCompress
    }

    public func points(for type: WeaponExitType) -> [Vec2] {
        switch type {
        case .gun: return gun
        case .turret: return turret
        case .guided: return guided
        case .beam: return beam
        case .center: return []
        }
    }

    private func zValues(for type: WeaponExitType) -> [Double] {
        switch type {
        case .gun: return gunZ
        case .turret: return turretZ
        case .guided: return guidedZ
        case .beam: return beamZ
        case .center: return []
        }
    }

    /// World-space offset (relative to the hull centre) of exit point `index` of
    /// `type`, for a hull pointing along `angle`. Falls back to a point `nose`
    /// pixels ahead of centre when the hull declares no points of that type.
    public func muzzleOffset(type: WeaponExitType, index: Int, angle: Double, nose: Double) -> Vec2 {
        let pts = points(for: type)
        let forward = Vec2.heading(angle)          // (sinθ, cosθ), +y = nose at θ=0
        guard !pts.isEmpty else { return forward * nose }
        let i = ((index % pts.count) + pts.count) % pts.count
        let local = pts[i]
        let z = zValues(for: type).indices.contains(i) ? zValues(for: type)[i] : 0
        // A hull that never authored this hardpoint leaves it at the origin;
        // firing from dead centre looks wrong, so fall back to a nose muzzle.
        if local.x == 0 && local.y == 0 && z == 0 { return forward * nose }
        let right = Vec2(forward.y, -forward.x)    // ship's right in world space
        var world = right * local.x + forward * local.y
        // Screen-space perspective squish (identity at 100/100).
        let up = forward.y >= 0                      // nose in the upper screen half
        let cx = (up ? upCompress.x : downCompress.x) / 100.0
        let cy = (up ? upCompress.y : downCompress.y) / 100.0
        world = Vec2(world.x * cx, world.y * cy)
        // Z: unscaled screen-vertical nudge (+z = up the screen = +y here).
        return Vec2(world.x, world.y + z)
    }
}

/// A live beam segment the renderer draws this frame. Continuous (`loopSound`)
/// beams persist while their trigger is held and have their geometry recomputed
/// off the live shooter every step, so the beam stays welded to the moving,
/// turning ship; pulse beams live a fraction of a second. The world owns these
/// (see `World.activeBeams`); the renderer mirrors them like it does projectiles.
public final class ActiveBeam {
    public let shooterID: Int
    public let mountIndex: Int
    /// The `wëap` id that fired this beam, so the renderer can pick up its
    /// lightning (`LiDensity`/`LiAmplitude`) and other beam styling; -1 if unknown.
    public let weaponID: Int
    public var from: Vec2
    public var to: Vec2
    public var hit: Bool
    /// Continuous vs. one-shot pulse. Continuous beams are refreshed each step
    /// and removed on trigger release; pulse beams count `life` down.
    public let continuous: Bool
    public var life: Double
    public let width: Double
    public let color: (r: Double, g: Double, b: Double)?

    public init(shooterID: Int, mountIndex: Int, weaponID: Int = -1, from: Vec2, to: Vec2, hit: Bool,
                continuous: Bool, life: Double, width: Double,
                color: (r: Double, g: Double, b: Double)?) {
        self.shooterID = shooterID; self.mountIndex = mountIndex; self.weaponID = weaponID
        self.from = from; self.to = to; self.hit = hit
        self.continuous = continuous; self.life = life
        self.width = width; self.color = color
    }
}

/// Transient things the renderer/audio layer should react to this frame. The
/// world appends them during `step`; the scene drains them after. Persistent
/// entities (ships, projectiles) are read directly off the world instead.
public enum WorldEvent {
    case weaponFired(shooterID: Int, at: Vec2, heading: Double, soundID: Int?)
    /// `mountIndex` lets the renderer correlate this shot with an active
    /// `beamLoopStart` on the same mount (continuous beams reposition one
    /// persistent line instead of spawning a fresh flash node every tick).
    case beam(shooterID: Int, mountIndex: Int, from: Vec2, to: Vec2, hit: Bool, soundID: Int?)
    /// A `loopSound` beam mount started/stopped continuous fire (trigger
    /// held/released, independent of the reload tick) — the renderer should
    /// start/stop a real looping voice rather than retrigger a one-shot per tick.
    case beamLoopStart(shooterID: Int, mountIndex: Int, soundID: Int?)
    case beamLoopStop(shooterID: Int, mountIndex: Int)
    /// `weaponID` is the `wëap` that landed the hit, so the renderer can throw
    /// that weapon's authored impact-particle spray (`wëap` hit particles); -1
    /// when unknown (the renderer then uses a generic shield/armor spark).
    case shieldHit(at: Vec2, weaponID: Int)
    case armorHit(at: Vec2, weaponID: Int)
    /// `boomID` is the `bööm` whose real sprite/animation the renderer should
    /// play (nil = a generic flash, e.g. small proximity taps). `soundID` is
    /// resolved separately so a silent bööm still bangs where the caller wants.
    case explosion(at: Vec2, radius: Double, soundID: Int?, boomID: Int?)
    /// A shattered `röid` throws colored debris. `color` is the rock's decoded
    /// `partColor`, `count` its `partCount` — the renderer sprays that many
    /// short-lived chunky fragments in that tint alongside the rock's explosion.
    case asteroidDebris(at: Vec2, color: NovaColor, count: Int)
    /// The player's mining scoop collected an asteroid's yield (`röid.YieldType`
    /// cargo, `YieldQty` boxes ±50%). `cargoType` follows the cargo-id convention
    /// (0-5 standard commodity). The host adds it to pilot cargo if there's room.
    case asteroidMined(cargoType: Int, quantity: Int, at: Vec2)
    /// The player locked a new target (via targetNearest/targetNext/nearestHostile).
    case targetAcquired(entityID: Int)
    case shipDestroyed(entityID: Int, shipTypeID: Int, at: Vec2)
    /// A ship appeared. `fromHyperspace` distinguishes an inbound hyperspace jump
    /// (warp-in effect, at the system edge) from an internal/populate spawn.
    case shipArrived(entityID: Int, at: Vec2, fromHyperspace: Bool)
    /// A ship left via the hyperspace edge; `heading` is its outbound facing so the
    /// renderer can streak it out the right way.
    case shipDeparted(entityID: Int, at: Vec2, heading: Double)
    /// A ship set down on a stellar object (flew into it and docked).
    case shipLanded(entityID: Int, spobID: Int, at: Vec2)
    /// A ship lifted off from a stellar object.
    case shipLaunched(entityID: Int, at: Vec2)
    /// A ship emerged from a hypergate: the renderer flashes the gate open,
    /// pops the ship out of it, then closes the gate. `gateSpobID` is the gate
    /// spöb to animate; the ship starts at its position heading outward.
    case shipEmergedFromGate(entityID: Int, gateSpobID: Int, at: Vec2)
    /// A ship's armor was knocked out but it survived as a drifting hulk.
    case shipDisabled(entityID: Int, at: Vec2)
    /// A government patrol/interceptor ran a scan pass on another ship (checking
    /// for contraband in EV Nova; here it's the visible fly-by + scan sweep).
    /// `scannerID` is the authority ship, `targetID` the ship being scanned.
    case shipScanned(scannerID: Int, targetID: Int, at: Vec2)
    /// A paid "Request Assistance" ally docked with the player and delivered
    /// fuel/repairs — `entityID` is the ally, for the renderer's banner text.
    case assistanceDelivered(entityID: Int)
    /// The player boarded a disabled hulk (to plunder/attempt capture).
    case shipBoarded(entityID: Int, at: Vec2)
    /// The player captured a disabled hulk; it joins the escort wing.
    case shipCaptured(entityID: Int, shipTypeID: Int, at: Vec2)
    /// The player attacked a named person (`pêrs`) who now holds a grudge — they
    /// will attack the player wherever they meet. The host persists this.
    case personGrudge(personID: Int)
    /// The player destroyed a named person; they cease to appear again. Persisted.
    case personDefeated(personID: Int)
    /// The player's own ship was destroyed (armor reached zero). `hadEscapePod`
    /// (`Loadout.hasEscapePod`, ModType 11) tells the app which outcome to run:
    /// true survives via rescue at the nearest inhabited port (ship/cargo/
    /// outfits lost); false is a real game-over. Fires once per `World`.
    case playerDestroyed(hadEscapePod: Bool)

    /// A mission (`mïsn`) special/aux ship was spawned into the system. The story
    /// layer correlates it by `missionID`; the renderer can flag it as an
    /// objective ship. `count` is how many were placed in this batch.
    case missionShipsSpawned(missionID: Int, entityIDs: [Int])
    /// A combat objective on a mission ship was reached: the player (or the
    /// world) destroyed/disabled/boarded a `missionID` ship whose `ShipGoal`
    /// matches `goal`. The story layer decides whether that completes/fails the
    /// mission — this event just reports the fact. `byPlayer` distinguishes a
    /// kill the player earned from an incidental NPC-vs-NPC one.
    case missionShipGoalReached(missionID: Int, entityID: Int, goal: MissionShipGoal, byPlayer: Bool)
    /// A mission's ships were cleared from the system by the story layer (e.g.
    /// escorts that leave at a plot point, or a cancelled mission) via
    /// `World.despawnMissionShips`. Not a kill — they simply vanish/jump out.
    case missionShipsDespawned(missionID: Int, entityIDs: [Int])
    /// A mission special ship the player was meant to keep alive (an escort, or a
    /// not-yet-rescued derelict) was **destroyed** — a failure signal for
    /// escort/rescue goals. Distinct from `missionShipGoalReached` (a goal met).
    case missionShipLost(missionID: Int, goal: MissionShipGoal)

    /// The player demanded tribute from a stellar and was rebuffed — the renderer
    /// shows the matching "the planet laughs at you / is unimpressed / can't be
    /// dominated" message. See `TributeRefusal`.
    case tributeRefused(spobID: Int, reason: TributeRefusal)
    /// A stellar launched a wave of its defense fleet (`spöb.DefenseDude`) in
    /// response to a tribute demand. `count` just launched, `remainingPool` still
    /// to come after this wave.
    case stellarDefendersLaunched(spobID: Int, count: Int, remainingPool: Int)
    /// The player broke a stellar's defenses and it surrendered: it is now
    /// dominated. The host persists it (`PlayerState.dominatedStellars`), applies
    /// the stellar's `OnDominate` control bits, and starts paying its daily tribute.
    case stellarDominated(spobID: Int)
}

/// Why a Demand-Tribute attempt was rebuffed (`WorldEvent.tributeRefused`).
public enum TributeRefusal: Sendable, Equatable {
    /// The player's combat rating is too low — the planet isn't intimidated.
    case combatRatingTooLow(required: Int)
    /// The stellar has no defense fleet, so it can't be forced to submit at all.
    case noDefenseFleet
    /// The stellar is already dominated by the player.
    case alreadyDominated
    /// Not an inhabited/governed stellar the player can dominate (no govt, a
    /// gate, an uninhabited rock).
    case notDominatable
}

/// The result of `World.demandTribute`.
public enum TributeOutcome: Sendable, Equatable {
    /// The demand was rebuffed (see reason). No fight started.
    case refused(TributeRefusal)
    /// The planet answered with force: `launched` defenders jumped in this
    /// instant, and the fight is on (more waves may follow as they're destroyed).
    case defending(launched: Int)
    /// The planet is still defending from an earlier demand — its defenders
    /// aren't beaten yet, so it has nothing new to say.
    case stillDefending
    /// The planet's defenses are broken; it surrendered and is now dominated.
    case dominated
}
