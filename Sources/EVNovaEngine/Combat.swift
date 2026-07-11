import Foundation
import EVNovaKit

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

/// A simulation-ready weapon: damage, reach, fire rate, projectile behaviour.
/// Built from a decoded `WeapRes` via `CombatTuning`.
public struct WeaponSpec {
    public let id: Int
    public let name: String
    public let shieldDamage: Double
    public let armorDamage: Double
    public let reloadSeconds: Double
    public let projectileSpeed: Double   // px/sec
    public let range: Double             // px
    public let accuracyRadians: Double
    public let isBeam: Bool
    public let isGuided: Bool
    /// Which hull hardpoint set this weapon's shots leave from.
    public let exitType: WeaponExitType
    /// Rendered beam thickness in px (beams only; 0 → engine default).
    public let beamWidth: Double
    /// Rendered beam colour as 0–1 RGB (beams only). Nil → engine default tint.
    public let beamColor: (r: Double, g: Double, b: Double)?
    public let turnRate: Double          // rad/sec, guided munitions
    public let blastRadius: Double       // px, 0 = direct hit only
    public let ammoPerShot: Int          // 0/1 typically; drains mount ammo
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

    public init(id: Int, name: String, shieldDamage: Double, armorDamage: Double,
                reloadSeconds: Double, projectileSpeed: Double, range: Double,
                accuracyRadians: Double, isBeam: Bool, isGuided: Bool,
                turnRate: Double, blastRadius: Double, ammoPerShot: Int,
                exitType: WeaponExitType = .center,
                beamWidth: Double = 0, beamColor: (r: Double, g: Double, b: Double)? = nil,
                fireSoundID: Int? = nil, explosionBoomID: Int? = nil, loopSound: Bool = false,
                isPointDefense: Bool = false, vulnerableToPD: Bool = true,
                ionization: Double = 0, cantFireWhileIonized: Bool = false) {
        self.id = id; self.name = name
        self.shieldDamage = shieldDamage; self.armorDamage = armorDamage
        self.reloadSeconds = reloadSeconds; self.projectileSpeed = projectileSpeed
        self.range = range; self.accuracyRadians = accuracyRadians
        self.isBeam = isBeam; self.isGuided = isGuided; self.turnRate = turnRate
        self.exitType = exitType; self.beamWidth = beamWidth; self.beamColor = beamColor
        self.blastRadius = blastRadius; self.ammoPerShot = ammoPerShot
        self.fireSoundID = fireSoundID; self.explosionBoomID = explosionBoomID
        self.loopSound = loopSound
        self.isPointDefense = isPointDefense; self.vulnerableToPD = vulnerableToPD
        self.ionization = ionization; self.cantFireWhileIonized = cantFireWhileIonized
    }

    /// Convert a decoded weapon into simulation units.
    public init(_ w: WeapRes, tuning: CombatTuning = .default) {
        id = w.id
        name = w.name
        shieldDamage = Double(w.shieldDamage) * tuning.damageScale
        armorDamage = Double(w.armorDamage) * tuning.damageScale
        reloadSeconds = max(0.1, Double(w.reload) / tuning.framesPerSecond)
        projectileSpeed = Double(w.speed) * tuning.unitToPxPerSec
        // WeapRes.range is speed(unit/frame)×duration(frames); scale to px.
        range = max(60, w.range * tuning.unitToPxPerSec / tuning.framesPerSecond)
        accuracyRadians = Double(w.accuracy) * .pi / 180.0
        isBeam = w.isBeam
        isGuided = w.isGuided
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
        fireSoundID = w.fireSoundID
        explosionBoomID = w.explosionBoomID
        loopSound = w.loopSound
        isPointDefense = w.isPointDefense
        vulnerableToPD = w.vulnerableToPD
        ionization = Double(w.ionization)
        cantFireWhileIonized = w.cantFireWhileIonized
    }
}

/// One installed weapon on a ship: its spec, remaining ammo, and cooldown.
public final class WeaponMount {
    public let spec: WeaponSpec
    public var cooldown: Double = 0      // seconds until it can fire again
    public var ammo: Int                 // -1 = unlimited
    /// Which of the hull's exit points (of this weapon's `spec.exitType`) this
    /// mount fires from. Assigned by `Ship` when its weapon list is installed:
    /// the Nth mount of a given exit type takes the Nth hardpoint, so a
    /// four-gun hull's guns leave four distinct barrels at once. Indexed
    /// modulo the available point count.
    public var exitIndex: Int = 0

    /// Which blocked-fire reason we last logged, so a held-down fire button
    /// while reloading/dry doesn't spam the log every frame — only the frame
    /// the reason first appears (or changes) gets a line.
    private var loggedBlockReason: String?

    public init(spec: WeaponSpec, ammo: Int = -1) {
        self.spec = spec
        self.ammo = ammo
    }

    public var ready: Bool { cooldown <= 0 && (ammo != 0) }

    /// Advance the cooldown clock.
    public func tick(_ dt: Double) { if cooldown > 0 { cooldown -= dt } }

    /// Mark the weapon fired: reset cooldown and spend ammo.
    public func didFire() {
        cooldown = spec.reloadSeconds
        if ammo > 0 && spec.ammoPerShot > 0 { ammo = max(0, ammo - spec.ammoPerShot) }
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

/// A live projectile in the world. Guided shots steer toward `targetID`.
public final class Projectile {
    public var position: Vec2
    public var velocity: Vec2
    public var life: Double              // seconds remaining
    public let shieldDamage: Double
    public let armorDamage: Double
    public let blastRadius: Double
    public let ownerID: Int              // entity that fired it (no self-hit)
    public let ownerGovt: Int            // faction (no friendly fire)
    public let guided: Bool
    public let turnRate: Double
    public let speed: Double
    public var targetID: Int?            // for guided munitions
    public var alive = true
    /// Whether point defense can shoot this shot down (`wëap.Flags` 0x0080
    /// inverted) — only meaningful for guided shots; see `World.runPointDefense`.
    public let vulnerableToPD: Bool
    /// Ionization energy this shot adds to whatever it hits.
    public let ionization: Double

    public init(position: Vec2, velocity: Vec2, life: Double,
                shieldDamage: Double, armorDamage: Double, blastRadius: Double,
                ownerID: Int, ownerGovt: Int, guided: Bool, turnRate: Double,
                speed: Double, targetID: Int?, vulnerableToPD: Bool = true,
                ionization: Double = 0) {
        self.position = position; self.velocity = velocity; self.life = life
        self.shieldDamage = shieldDamage; self.armorDamage = armorDamage
        self.blastRadius = blastRadius; self.ownerID = ownerID; self.ownerGovt = ownerGovt
        self.guided = guided; self.turnRate = turnRate; self.speed = speed
        self.targetID = targetID
        self.ionization = ionization
        self.vulnerableToPD = vulnerableToPD
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
    /// Perspective foreshortening (x%, y%) for hulls facing screen-up / screen-down.
    public var upCompress: (x: Double, y: Double)
    public var downCompress: (x: Double, y: Double)

    public init(gun: [Vec2], turret: [Vec2], guided: [Vec2], beam: [Vec2],
                upCompress: (x: Double, y: Double) = (100, 100),
                downCompress: (x: Double, y: Double) = (100, 100)) {
        self.gun = gun; self.turret = turret; self.guided = guided; self.beam = beam
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

    /// World-space offset (relative to the hull centre) of exit point `index` of
    /// `type`, for a hull pointing along `angle`. Falls back to a point `nose`
    /// pixels ahead of centre when the hull declares no points of that type.
    public func muzzleOffset(type: WeaponExitType, index: Int, angle: Double, nose: Double) -> Vec2 {
        let pts = points(for: type)
        let forward = Vec2.heading(angle)          // (sinθ, cosθ), +y = nose at θ=0
        guard !pts.isEmpty else { return forward * nose }
        let local = pts[((index % pts.count) + pts.count) % pts.count]
        // A hull that never authored this hardpoint leaves it at the origin;
        // firing from dead centre looks wrong, so fall back to a nose muzzle.
        if local.x == 0 && local.y == 0 { return forward * nose }
        let right = Vec2(forward.y, -forward.x)    // ship's right in world space
        var world = right * local.x + forward * local.y
        // Screen-space perspective squish (identity at 100/100).
        let up = forward.y >= 0                      // nose in the upper screen half
        let cx = (up ? upCompress.x : downCompress.x) / 100.0
        let cy = (up ? upCompress.y : downCompress.y) / 100.0
        world = Vec2(world.x * cx, world.y * cy)
        return world
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
    public var from: Vec2
    public var to: Vec2
    public var hit: Bool
    /// Continuous vs. one-shot pulse. Continuous beams are refreshed each step
    /// and removed on trigger release; pulse beams count `life` down.
    public let continuous: Bool
    public var life: Double
    public let width: Double
    public let color: (r: Double, g: Double, b: Double)?

    public init(shooterID: Int, mountIndex: Int, from: Vec2, to: Vec2, hit: Bool,
                continuous: Bool, life: Double, width: Double,
                color: (r: Double, g: Double, b: Double)?) {
        self.shooterID = shooterID; self.mountIndex = mountIndex
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
    case shieldHit(at: Vec2)
    case armorHit(at: Vec2)
    case explosion(at: Vec2, radius: Double, soundID: Int?)
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
    /// A ship's armor was knocked out but it survived as a drifting hulk.
    case shipDisabled(entityID: Int, at: Vec2)
    /// A government patrol/interceptor ran a scan pass on another ship (checking
    /// for contraband in EV Nova; here it's the visible fly-by + scan sweep).
    /// `scannerID` is the authority ship, `targetID` the ship being scanned.
    case shipScanned(scannerID: Int, targetID: Int, at: Vec2)
    /// A paid "Request Assistance" ally docked with the player and delivered
    /// fuel/repairs — `entityID` is the ally, for the renderer's banner text.
    case assistanceDelivered(entityID: Int)
}
