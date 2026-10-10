import Foundation
import NovaSwiftKit

// AI-02: an NPC fires one AI-selected weapon bank, not every mount it carries.
// The original keeps a single `active_weapon_bank_slot` per ship, armed by the
// selectors below, and `Weapon_FireShipWeapons` 0x00414550 serves only that
// bank; turreted banks are aimed and fired through their own selector
// (`Weapon_FireTurretAtTarget` 0x0040ce00), again one bank at a time.
extension World {

    /// The mounts an NPC may fire this trigger: its selected forward bank and
    /// its selected turret bank (either may be absent).
    func npcSelectedMounts(for ship: Ship, target: Ship?) -> Set<Int> {
        guard let target else {
            // No target: only the general fallback (0x0040d910) arms anything.
            return Set([npcGeneralBank(for: ship)].compactMap { $0 })
        }
        var picked: Set<Int> = []
        if let bank = npcGuidedBank(for: ship, target: target)
            ?? npcDirectFireBank(for: ship, target: target, allowGuided: false) {
            picked.insert(bank)
        }
        if let turret = npcTurretBank(for: ship, target: target) { picked.insert(turret) }
        return picked
    }

    /// `Weapon_SelectGeneralWeaponBank` 0x0040d910: the last ready bank that
    /// isn't a beam, a turreted beam, or mode ≥ 8.
    func npcGeneralBank(for ship: Ship) -> Int? {
        ship.weapons.indices.last { i in
            let s = ship.weapons[i].spec
            return ship.weapons[i].ready && s.guidance.rawValue < 8
                && s.guidance != .beam && s.guidance != .beamTurret
        }
    }

    /// `Weapon_SelectUnguidedWeaponBank` 0x0040d7e0: among ready unguided,
    /// beam and rocket banks (a front-quadrant gun too while the ship has no
    /// target) that aren't planet-type weapons, the one with the most mass
    /// (armor) damage, at least 1; the first bank wins a tie. No range test.
    /// (The original also drops a beam carrying wëap Flags 0x0001 on a hull
    /// with a matching flag; the port doesn't model that pairing.)
    func npcUnguidedBank(for ship: Ship, target: Ship?) -> Int? {
        var best: (index: Int, value: Double)?
        for (i, mount) in ship.weapons.enumerated() {
            let spec = mount.spec
            switch spec.guidance {
            case .unguided, .beam, .rocket: break
            case .frontQuadrant where target == nil: break
            default: continue
            }
            guard mount.ready, !spec.isPlanetTypeWeapon else { continue }
            let mass = max(1, spec.armorDamage)
            if best == nil || mass > best!.value { best = (i, mass) }
        }
        return best?.index
    }

    /// `Weapon_SelectGuidedWeaponBankForPrimaryTarget` 0x0040d220: the first
    /// homing bank that can track the target (a target turning more than 3°
    /// a tick needs a missile that turns faster than 2° a tick and lacks
    /// `wëap` Flags 0x0008) and has it within `dist² × 0.95 ≤ range²`. Armed
    /// only if that bank is ready.
    func npcGuidedBank(for ship: Ship, target: Ship) -> Int? {
        let d = target.position - ship.position
        let distSq = d.x * d.x + d.y * d.y
        // shïp TurnRate is tenths of a degree per tick (FL-10).
        let targetTurn = Int(Double(target.rawTurnRate) / 10)
        for (i, mount) in ship.weapons.enumerated() where mount.spec.guidance == .guided {
            let spec = mount.spec
            let tracks = targetTurn <= 3
                || (!spec.wontFireAtFastShips && spec.turnRate * 180 / .pi / 30 > 2)
            guard tracks, spec.isPlanetTypeWeapon == target.isPlanetTypeShip,
                  mount.ammo != 0, distSq * 0.95 <= spec.range * spec.range else { continue }
            return mount.ready ? i : nil
        }
        return nil
    }

    /// `Weapon_SelectDirectFireWeaponBankForPrimaryTarget` 0x0040d470: among
    /// ready, in-range unguided, beam and rocket banks (homing ones too when
    /// `allowGuided`), the one with the most energy (shield) damage while the
    /// target's shields are up, else the most mass (armor) damage; the first
    /// bank wins a tie. A rocket with a blast radius qualifies only from
    /// outside 2.5 × that radius on both axes. With nothing armed and no
    /// non-guided bank aboard, it tries once more allowing homing banks.
    func npcDirectFireBank(for ship: Ship, target: Ship, allowGuided: Bool) -> Int? {
        var hasNonGuided = false
        var bestMass: (index: Int, value: Double)?
        var bestEnergy: (index: Int, value: Double)?
        let dx = abs(target.position.x - ship.position.x), dy = abs(target.position.y - ship.position.y)
        for (i, mount) in ship.weapons.enumerated() {
            let spec = mount.spec
            switch spec.guidance {
            case .unguided, .beam, .rocket: break
            case .guided where allowGuided: break
            default: continue
            }
            guard spec.isPlanetTypeWeapon == target.isPlanetTypeShip, mount.ammo != 0 else { continue }
            if spec.guidance != .guided { hasNonGuided = true }
            guard mount.cooldown <= 0, Self.npcWithinRange(spec, dx: dx, dy: dy) else { continue }
            if spec.guidance == .rocket, spec.blastRadius > 0 {
                let clearance = spec.blastRadius * 2.5
                guard clearance <= dx, clearance <= dy else { continue }
            }
            let mass = max(1, spec.armorDamage), energy = max(1, spec.shieldDamage)
            if bestMass == nil || mass > bestMass!.value { bestMass = (i, mass) }
            if bestEnergy == nil || energy > bestEnergy!.value { bestEnergy = (i, energy) }
        }
        if let pick = (target.shield >= 0 ? bestEnergy : bestMass)?.index { return pick }
        if !hasNonGuided && !allowGuided { return npcDirectFireBank(for: ship, target: target, allowGuided: true) }
        return nil
    }

    /// The turret selector (`Weapon_FireTurretAtTarget` 0x0040ce00): the ready,
    /// in-range turreted or quadrant bank with the most energy damage while
    /// the target has shields, else the most mass damage.
    func npcTurretBank(for ship: Ship, target: Ship) -> Int? {
        let dx = abs(target.position.x - ship.position.x), dy = abs(target.position.y - ship.position.y)
        var best: (index: Int, value: Double)?
        for (i, mount) in ship.weapons.enumerated() {
            let spec = mount.spec
            switch spec.guidance {
            case .turret, .beamTurret, .frontQuadrant, .rearQuadrant: break
            default: continue
            }
            guard mount.ready, spec.isPlanetTypeWeapon == target.isPlanetTypeShip,
                  Self.npcWithinRange(spec, dx: dx, dy: dy) else { continue }
            let value = target.shield >= 0 ? max(1, spec.shieldDamage) : max(1, spec.armorDamage)
            if best == nil || value > best!.value { best = (i, value) }
        }
        return best?.index
    }

    /// `Weapon_ShipWithinWeaponRangeOfTarget`: the whole-pixel distance within
    /// `BeamLength + 32` for a beam, else `range + 32` (floored).
    static func npcWithinRange(_ spec: WeaponSpec, dx: Double, dy: Double) -> Bool {
        let fx = dx.rounded(.down), fy = dy.rounded(.down)
        let reach = spec.guidance == .beam || spec.guidance == .beamTurret
            ? spec.beamLength + 32 : (spec.range + 32).rounded(.down)
        return fx * fx + fy * fy <= reach * reach
    }
}
