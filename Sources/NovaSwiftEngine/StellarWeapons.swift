import Foundation
import NovaSwiftKit

// EV Nova's planetary/station defense weapons (`spöb.Weapon`): an armed stellar
// fires its weapon at ships hostile to its government — the stations that
// hammer anyone their owner is at war with, and any planet the player picks a
// tribute fight with. The weapon behaves like a stationary, always-turreted
// mount at the stellar's position: it leads its target, respects the weapon's
// real range/reload/burst data, and fires real projectiles/beams through the
// same damage pipeline as ship fire. Complements the defense *fleet*
// (`Domination.swift`) — a planet can have either, both, or neither.
extension World {

    /// The synthetic "entity id" carried by a stellar's shots as their owner —
    /// distinct per stellar, and never a real ship id (ship entity ids count up
    /// from 0). Ship lookups by this id simply find nothing, which every
    /// consumer (hit attribution, provocation, renderer glow) already treats
    /// as "some non-ship shooter".
    public static func stellarShooterID(forSpob spobID: Int) -> Int { -10_000 - spobID }

    /// Per-frame firing pass for every armed stellar in the system. Called from
    /// `step` alongside the other combat phases.
    func updateStellarWeapons(_ dt: Double) {
        for body in systemContext.bodies {
            guard let spec = body.defenseWeapon else { continue }
            let mount: WeaponMount
            if let existing = stellarWeaponMounts[body.id] {
                mount = existing
            } else {
                // Planets never run dry: unlimited ammo, one barrel.
                mount = WeaponMount(spec: spec, ammo: -1, count: 1)
                stellarWeaponMounts[body.id] = mount
            }
            mount.tick(dt)
            guard mount.ready else { continue }
            guard let target = stellarWeaponTarget(for: body, range: spec.range) else { continue }
            fireStellarWeapon(from: body, spec: spec, mount: mount, at: target)
        }
    }

    /// The ship this stellar wants to shoot right now: the nearest in-range,
    /// up-and-fighting ship that's hostile to it — or nil to hold fire.
    ///
    /// Hostility, stellar → ship:
    /// - Player fleet (player + escorts/fighters): hostile while the planet is
    ///   fighting off a tribute demand, once the player has provoked its
    ///   government in this system, or when its government wants the player
    ///   dead on legal record — but never once the stellar is *dominated*
    ///   (it's the player's planet now).
    /// - NPCs: ships of a government at war with the stellar's own.
    /// - `Flags2 0x0200` ("fires weapon only when provoked") narrows all of
    ///   that to the tribute-contest / player-provoked cases: the stellar
    ///   ignores passing wars and a merely-criminal legal record.
    private func stellarWeaponTarget(for body: StellarBody, range: Double) -> Ship? {
        let contested = stellarDefenses[body.id] != nil
        let provoked = contested || provokedGovernments.contains(body.government)
        let playerHostile = !dominatedStellars.contains(body.id)
            && (provoked || (!body.firesOnlyWhenProvoked
                             && (diplomacy?.isHostileToPlayer(body.government) ?? false)))
        var best: Ship?
        var bestD = range
        for ship in allShips where ship.isAlive && !ship.disabled && !ship.cloakEngaged {
            let hostile: Bool
            if isPlayerFleetMember(ship.entityID) {
                hostile = playerHostile
            } else if body.firesOnlyWhenProvoked {
                hostile = false   // holds fire on NPC wars entirely
            } else {
                hostile = diplomacy?.areEnemies(body.government, ship.government) ?? false
            }
            guard hostile else { continue }
            let d = (ship.position - body.position).length
            if d <= bestD { bestD = d; best = ship }
        }
        return best
    }

    /// Loose one shot at `target`: turret-style lead from the stellar's
    /// position (a planet has no hull heading, so every stellar weapon aims
    /// like a turret regardless of its `Guidance`), spawning a real projectile
    /// or casting a real beam through the normal damage pipeline.
    private func fireStellarWeapon(from body: StellarBody, spec: WeaponSpec,
                                   mount: WeaponMount, at target: Ship) {
        let shooterID = World.stellarShooterID(forSpob: body.id)
        var aim = leadAngle(from: body.position, shooterVel: Vec2(), target: target,
                            shotSpeed: spec.projectileSpeed, instantHit: spec.isBeam)
        if spec.accuracyRadians > 0 && !spec.firesAtFixedAngle {
            aim += rng.double(in: -spec.accuracyRadians...spec.accuracyRadians)
        }
        let dir = Vec2.heading(aim)
        // Shots leave from just inside the stellar's rim toward the target, so
        // they visibly emerge from the planet's surface installations rather
        // than materializing at its centre under the sprite.
        let muzzle = body.position + dir * max(0, body.radius * 0.7)

        if spec.isBeam {
            let cast = beamCast(from: muzzle, dir: dir, range: spec.range,
                                ownerID: shooterID, ownerGovt: body.government)
            if let h = cast.hitShip {
                applyHit(to: h, shield: spec.shieldDamage, armor: spec.armorDamage,
                         ownerID: shooterID, ionization: spec.ionization,
                         ionizeColor: spec.ionizeColor, piercing: spec.penetratesShields,
                         weaponID: spec.id)
                if spec.impact > 0 {
                    h.velocity += dir * (spec.impact * 6.0 / max(4, h.radius))
                }
            } else if let rock = cast.hitAsteroid {
                applyAsteroidHit(rock, shield: spec.shieldDamage, armor: spec.armorDamage,
                                 shooterID: shooterID)
            }
            let hit = cast.hitShip != nil || cast.hitAsteroid != nil
            // Stellar beams are always pulse flashes (`refreshActiveBeams`
            // counts them down by `life` without needing a shooter ship);
            // continuous-loop welding only exists for ships, and a fresh pulse
            // per reload tick reads correctly for a ground battery anyway.
            if let existing = activeBeams.first(where: {
                $0.shooterID == shooterID && $0.mountIndex == 0 && !$0.continuous }) {
                existing.from = muzzle; existing.to = cast.end; existing.hit = hit
                existing.life = existing.maxLife
            } else {
                activeBeams.append(ActiveBeam(shooterID: shooterID, mountIndex: 0,
                                              weaponID: spec.id, from: muzzle, to: cast.end,
                                              hit: hit, continuous: false,
                                              life: spec.pulseBeamLifeSeconds,
                                              width: spec.beamWidth, color: spec.beamColor,
                                              coronaColor: spec.coronaColor,
                                              coronaFalloff: spec.coronaFalloff))
            }
            emit(.beam(shooterID: shooterID, mountIndex: 0, from: muzzle, to: cast.end,
                       hit: hit, soundID: spec.fireSoundID, weaponID: spec.id))
        } else {
            spawnProjectile(spec: spec, muzzle: muzzle, aim: aim,
                            ownerID: shooterID, ownerGovt: body.government,
                            ownerVelocity: Vec2(),
                            targetID: spec.homes ? target.entityID : nil, subDepth: 0)
            emit(.weaponFired(shooterID: shooterID, at: muzzle, heading: aim,
                              soundID: spec.fireSoundID, weaponID: spec.id))
        }
        mount.didFire(shots: 1)
    }
}
