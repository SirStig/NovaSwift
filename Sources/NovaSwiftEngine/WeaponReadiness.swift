import Foundation
import NovaSwiftKit

/// The original's per-bank weapon helpers the AI reads: whether a bank can
/// fire, the ammo classification, the maximum and stock ranges; and the
/// escort combat chatter queue.
extension World {

    // MARK: Fire readiness

    /// `Weapon_CanFireWeaponBank` (0x00468990); see `Ship.canFireBank`.
    func canFireBank(_ ship: Ship, _ mount: WeaponMount) -> Bool { ship.canFireBank(mount) }

    /// The most shots one volley may fire (`Weapon_GetWeaponBurstAttempts`
    /// 0x0046f2c0 with the per-attempt CanFire): the rounds left, or the fuel
    /// shots left for a fuel weapon; unlimited otherwise.
    func volleyAllowance(_ ship: Ship, _ mount: WeaponMount) -> Int {
        let spec = mount.spec
        if spec.fuelPerShot > 0 { return Int((ship.fuel / spec.fuelPerShot).rounded(.towardZero)) }
        if spec.ammoPerShot > 0, mount.ammo >= 0 { return mount.ammo / spec.ammoPerShot }
        return .max
    }

    /// `Ship_TallyInboundWeaponThreat` (0x00422210) for one ship: half the
    /// Energy + Mass damage of every live shot aimed at it (not confused or
    /// turned), accumulated in a truncating 16-bit counter.
    func inboundThreat(on target: Ship) -> Int {
        var total: Int16 = 0
        for p in projectiles where p.alive && !p.visualOnly && p.life > 0
            && p.shotTargetID == target.entityID && p.guidanceState == 0 {
            let raw = Double(total) + (p.baseShieldDamage + p.baseArmorDamage) * 0.5
            total = Int16(truncatingIfNeeded: Int(raw.rounded(.towardZero)))
        }
        return Int(total)
    }

    /// `Ship_IsInboundThreatExceedingDefenses` (0x004221d0): the inbound
    /// tally reaches `(shield + armor) × 1.05`.
    func inboundThreatExceedsDefenses(_ target: Ship) -> Bool {
        Double(inboundThreat(on: target)) >= (target.shield + target.armor) * 1.05
    }

    /// `Weapon_ClassifyShipWeaponAmmoReadiness` (0x004138a0) over every bank,
    /// bays and point defense included. An ammo bank (AmmoType ≥ 0) is dry
    /// with no round left, a fuel bank (AmmoType < −1000) with less fuel than
    /// `|AmmoType| − 1000` (unscaled, as the original reads it); a free bank
    /// never is. 2 when nothing is armed or every bank is dry, 1 when every
    /// ammo/fuel bank is dry but a free one remains, else 0.
    func ammoReadiness(_ ship: Ship) -> Int {
        var armed = 0, usable = 0, dry = 0
        for mount in ship.weapons where mount.count > 0 {
            armed += 1
            let t = mount.spec.ammoTypeRaw
            guard t >= 0 || t < -1000 else { continue }
            usable += 1
            if t < 0 {
                if ship.fuel < Double(abs(t) - 1000) { dry += 1 }
            } else if mount.spec.guidance == .bay {
                if (ship.fighterBays.first { $0.spec.bayWeaponID == mount.spec.id }?.docked ?? mount.ammo) < 1 { dry += 1 }
            } else if mount.ammo == 0 {
                dry += 1
            }
        }
        if armed == 0 { return 2 }
        if dry > 0 && dry == armed { return 2 }
        if dry > 0 && dry == usable { return 1 }
        return 0
    }

    /// `Weapon_GetShipMaxWeaponRange` (0x0046cec0): the longest reach among
    /// banks that can fire — a beam's BeamLength, `trunc(range)` for unguided,
    /// turret and front-quadrant guns, × 0.85 for homing, × 0.5 for rockets,
    /// and 0 for everything else (the original tests mode 7 twice, so rear
    /// quadrant guns count 0 too); capped at 0x7fff.
    func maxWeaponRange(_ ship: Ship) -> Int {
        var best = 0
        for mount in ship.weapons where mount.count > 0 && canFireBank(ship, mount) {
            let spec = mount.spec
            let r: Int
            switch spec.guidance {
            case .beam, .beamTurret: r = Int(spec.beamLength)
            case .unguided, .turret, .frontQuadrant: r = Int(Float(spec.range).rounded(.towardZero))
            case .guided: r = Int((Float(spec.range) * 0.85).rounded(.towardZero))
            case .rocket: r = Int((Float(spec.range) * 0.5).rounded(.towardZero))
            default: r = 0
            }
            best = max(best, r)
        }
        return min(best, 0x7fff)
    }

    /// `Weapon_IsShipWithinWeaponRangeOfTarget(ship, target, −1)` (0x00411600):
    /// any of the hull class's stock weapons below guidance 9 reaches the
    /// target, by `floor|dx|² + floor|dy|²` against `BeamLength + 32` for a
    /// beam, else `trunc(range + 32)`. Falls back to the fitted mounts for a
    /// ship without class data.
    func withinStockWeaponRange(_ ship: Ship, of target: Ship) -> Bool {
        let dx = abs(ship.position.x - target.position.x), dy = abs(ship.position.y - target.position.y)
        var specs: [WeaponSpec] = []
        if let res = galaxy?.game.ship(ship.shipTypeID) {
            specs = res.weapons.filter { $0.count > 0 }.compactMap { galaxy?.weaponSpec($0.id) }
        } else {
            specs = ship.weapons.map(\.spec)
        }
        return specs.contains { spec in
            spec.guidance.rawValue < 9 && Self.npcWithinRange(spec, dx: dx, dy: dy)
        }
    }

    // MARK: Combat chatter (0x00426ce0 / 0x004311f0 / 0x004313c0)

    /// Nothing queued and nothing playing.
    var combatChatterIdle: Bool { pendingChatter == nil && !combatChatterPlaying }

    /// `Frame_QueueCombatChatter`: the one pending line, replaced by a later
    /// call. `govt` is a government resource id (−1 none), `voice` 0/1.
    public func queueCombatChatter(category: Int, govt: Int, voice: Int) {
        pendingChatter = (category, govt, voice)
    }

    /// `Frame_CancelCombatChatter`: drop the pending line (landing, jumping).
    public func cancelCombatChatter() { pendingChatter = nil }

    /// `Frame_UpdateCombatChatter`, once per step: when no chatter sound is
    /// playing, the pending line resolves to `snd 1000 + 100 × VoiceType +
    /// 10 × category + variant`, where with N sounds in that bank a voice-0/1
    /// speaker takes every other variant (`2 × Rand(N/2) + voice`, or just
    /// `voice` when N is 2) and anyone else, or an odd N, `Rand(N)`.
    func updateCombatChatter() {
        guard let line = pendingChatter, !combatChatterPlaying else { return }
        pendingChatter = nil
        guard (0..<3).contains(line.category) else { return }
        let voiceSet = line.govt >= govtResourceBase ? (govtRes(line.govt)?.voiceSet ?? 0) : 0
        guard voiceSet >= 0 else { return }
        let base = 1000 + voiceSet * 100 + line.category * 10
        let n = chatterBankSize(base)
        guard n > 0 else { return }
        let variant: Int
        if line.voice < 0 || line.voice > 1 || n % 2 != 0 {
            variant = rng.range(n)
        } else if n == 2 {
            variant = line.voice
        } else {
            variant = rng.range(n / 2) * 2 + line.voice
        }
        combatChatterPlaying = true
        emit(.combatChatter(soundID: base + variant))
    }

    /// How many consecutive `snd` resources exist from `base` (at most 9),
    /// as the loader counts them (0x004b0740).
    func chatterBankSize(_ base: Int) -> Int {
        guard let game = galaxy?.game else { return 0 }
        var n = 0
        while n < 9, game.resources.resource(NovaType.snd, base + n) != nil { n += 1 }
        return n
    }
}
