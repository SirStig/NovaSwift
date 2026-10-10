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
                             && (diplomacy?.stellarBatteriesTargetPlayer(
                                    stellarGovt: body.government,
                                    playerHullGovt: player.inherentCombatGovt) ?? false)))
        var best: Ship?
        var bestD = range
        // A disabled hull is passed over only by a disable-only or massless
        // weapon (`Stellar_TickStellarDefenseBatteries` 0x0042d890).
        let skipsDisabled = body.defenseWeapon.map { $0.disablesOnly || $0.armorDamage <= 0 } ?? true
        for ship in allShips where ship.isAlive && !(skipsDisabled && ship.disabled)
            && !ship.isEffectivelyCloaked {
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

    /// Loose one shot at `target` (`Stellar_TickStellarDefenseBatteries`
    /// 0x0042d890): an ownerless shot from the stellar's centre with no launch
    /// velocity of its own, aimed with a one-step lead (`distance / speed`,
    /// `Shot_AimStellarBatteryShot` 0x0043ba30), that can hit only `target`.
    private func fireStellarWeapon(from body: StellarBody, spec: WeaponSpec,
                                   mount: WeaponMount, at target: Ship) {
        let shooterID = World.stellarShooterID(forSpob: body.id)
        var aim = leadAngle(from: body.position, shooterVel: Vec2(), target: target,
                            shotSpeed: spec.projectileSpeed, instantHit: spec.isBeam)
        if spec.inaccuracyDegrees > 0 {
            aim += Double(rng.range(2 * spec.inaccuracyDegrees) - spec.inaccuracyDegrees) * .pi / 180
        }
        let dir = Vec2.heading(aim)
        let muzzle = body.position

        if spec.isBeam {
            let cast = beamCast(from: muzzle, dir: dir, range: spec.beamLength,
                                ownerID: shooterID, ownerGovt: body.government)
            let struck = cast.hitShip.flatMap { $0.entityID == target.entityID ? $0 : nil }
            if let h = struck {
                applyHit(to: h, shield: spec.shieldDamage, armor: spec.armorDamage,
                         ownerID: shooterID, ionization: spec.ionization,
                         ionizeColor: spec.ionizeColor, piercing: spec.penetratesShields,
                         weaponID: spec.id, disablesOnly: spec.disablesOnly,
                         impact: spec.impact, impactFrom: muzzle)
            }
            let hit = struck != nil
            let end = hit ? cast.end : muzzle + dir * spec.beamLength
            // Stellar beams are always pulse flashes (`refreshActiveBeams`
            // counts them down by `life` without needing a shooter ship).
            if let existing = activeBeams.first(where: {
                $0.shooterID == shooterID && $0.mountIndex == 0 && !$0.continuous }) {
                existing.from = muzzle; existing.to = end; existing.hit = hit
                existing.life = existing.maxLife
            } else {
                activeBeams.append(ActiveBeam(shooterID: shooterID, mountIndex: 0,
                                              weaponID: spec.id, from: muzzle, to: end,
                                              hit: hit, continuous: false,
                                              life: spec.pulseBeamLifeSeconds,
                                              width: spec.beamWidth, color: spec.beamColor,
                                              coronaColor: spec.coronaColor,
                                              coronaFalloff: spec.coronaFalloff))
            }
            emit(.beam(shooterID: shooterID, mountIndex: 0, from: muzzle, to: end,
                       hit: hit, soundID: spec.fireSoundID, weaponID: spec.id))
        } else {
            let shot = spawnProjectile(spec: spec, muzzle: muzzle, aim: aim,
                                       ownerID: shooterID, ownerGovt: body.government,
                                       ownerVelocity: Vec2(),
                                       targetID: spec.homes ? target.entityID : nil, subDepth: 0)
            shot.batteryTargetID = target.entityID
            emit(.weaponFired(shooterID: shooterID, at: muzzle, heading: aim,
                              soundID: spec.fireSoundID, weaponID: spec.id))
        }
        mount.didFire(shots: 1)
    }
}

// MARK: - Destroyable stellars (`spöb.Strength` / `Explosion` / `DeadTime`)
//
// The other half of an armed planet: one you can shoot back. A `spöb` with a
// positive `Strength` is a real target that soaks combined mass+energy damage
// and, at zero, detonates its `Explosion` and swaps to its `DestroyedGraphic`.
//
// Almost every base-game stellar carries a positive `Strength` (1000-10000;
// Earth is 3000) — so what keeps stock worlds standing is **not** invulnerability
// but the weapon gate: the Bible defines `Strength` as the damage a stellar takes
// "from planetary-type weapons", and `wëap.Flags2` 0x0400 as "Weapon is a
// planet-type weapon, and can only hit planet-type ships or destroyable
// stellars". Ordinary guns therefore pass straight through a planet. The two
// call sites — `World.stepProjectiles` and `beamCast` — enforce that; without it
// a routine dogfight near a world could destroy it, firing its `OnDestroy`
// control bits and (for a hypergate) deleting a route off the map.
extension World {

    /// Every destroyable stellar in the current system that is still standing.
    var destroyableStellars: [StellarBody] {
        systemContext.bodies.filter { $0.isDestroyable && !stellarsDestroyedThisSession.contains($0.id) }
    }

    /// The armor a destroyable stellar has left, seeding from its full strength
    /// the first time it's asked.
    func stellarArmorRemaining(_ body: StellarBody) -> Double {
        stellarArmor[body.id] ?? body.strength
    }

    /// Land one weapon hit on a stellar. Damage is the Bible's "combined mass and
    /// energy damage" — a stellar has no shields to knock down first, so both
    /// halves of the shot count toward the same pool. Returns true when this hit
    /// destroyed it. When the player's own shot (`ownerID` 0) destroys it, the
    /// stellar's government takes ten kill events (OS-13; 0x00437e20).
    @discardableResult
    func applyStellarHit(_ body: StellarBody, shield: Double, armor: Double, ownerID: Int = -1) -> Bool {
        guard body.isDestroyable, !stellarsDestroyedThisSession.contains(body.id) else { return false }
        // Destroyed once its strength goes below zero (0x00437e20).
        let remaining = stellarArmorRemaining(body) - (shield + armor)
        stellarArmor[body.id] = remaining
        emit(.stellarDamaged(spobID: body.id, armor: max(0, remaining), maxArmor: body.strength))
        guard remaining < 0 else { return false }
        stellarsDestroyedThisSession.insert(body.id)
        emit(.stellarDestroyed(spobID: body.id, at: body.position,
                               boomID: body.explosionBoomID, sparks: body.explosionHasSparks))
        // A destroyed stellar stops shooting and drops any tribute contest.
        stellarWeaponMounts[body.id] = nil
        stellarDefenses[body.id] = nil
        if ownerID == 0 {
            for _ in 0..<10 { diplomacy?.recordCrime(.kill, against: body.government) }
        }
        Log.combat.notice("Stellar \(body.id, privacy: .public) destroyed by weapon fire")
        return true
    }

    /// Swept collision of one shot's path against every destroyable stellar.
    /// Returns the body it struck, if any.
    func destroyableStellarHit(from: Vec2, to: Vec2, reach: Double) -> StellarBody? {
        for body in destroyableStellars
        where Self.segmentPointDistance(from, to, body.position) <= body.radius + reach {
            return body
        }
        return nil
    }
}
