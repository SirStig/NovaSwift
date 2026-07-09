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
                fireSoundID: Int? = nil, explosionBoomID: Int? = nil, loopSound: Bool = false,
                isPointDefense: Bool = false, vulnerableToPD: Bool = true,
                ionization: Double = 0, cantFireWhileIonized: Bool = false) {
        self.id = id; self.name = name
        self.shieldDamage = shieldDamage; self.armorDamage = armorDamage
        self.reloadSeconds = reloadSeconds; self.projectileSpeed = projectileSpeed
        self.range = range; self.accuracyRadians = accuracyRadians
        self.isBeam = isBeam; self.isGuided = isGuided; self.turnRate = turnRate
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
    /// A paid "Request Assistance" ally docked with the player and delivered
    /// fuel/repairs — `entityID` is the ally, for the renderer's banner text.
    case assistanceDelivered(entityID: Int)
}
