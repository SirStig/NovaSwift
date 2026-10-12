import Foundation

// Prose spec (no decompiled code is reproduced here). Ground truth: the original executable,
// Ghidra addresses in ~/Projects/evnova-re.
//
// Fire cadence of one weapon type mounted `N` times (Weapon_FirePlayerWeaponBank 0x00455150 and
// Weapon_FireShipWeapons 0x00414550 share the rules). Each trigger pull is one "volley":
//  - Simultaneous weapons (wëap Flags 0x0040): a volley fires N shots and the bank cooldown is
//    `Reload`. Others: a volley fires ONE shot and the cooldown is `Reload / N`, so the mounts
//    stagger.
//  - Burst weapons (BurstCount > 0, wëap @90): every volley bumps a per-bank counter. The counter
//    wraps when it reaches Weapon_GetWeaponFireIntervalTicks (0x0046f270): BurstCount for
//    simultaneous weapons, N x BurstCount for the others. On the wrap the cooldown is set to
//    BurstReload (wëap @92, read at 0x00455150 after the counter test) INSTEAD of the normal
//    cooldown. (The Bible agrees: "BurstCount x number of mounts" for non-simultaneous weapons.)
//  - Weapon_InitShipWeaponBursts (0x00413810) preloads BurstReload as the first cooldown; that
//    start-up delay is not part of the steady-state rate computed here.
//  - A cooldown of 0 still waits for the next 30 Hz tick, so every interval is at least one tick.
//
// The editor previously assumed the burst length did not scale with the mount count for
// staggered weapons and used (BurstCount-1) x Reload; both differ from the above when N > 1.

/// Steady-state shots per second for a mounted weapon type.
public struct WeaponCadence: Sendable, Equatable {
    /// Shots fired in one full cycle (a burst plus its burst reload, or one volley).
    public var shotsPerCycle: Double
    /// Length of that cycle in seconds.
    public var cycleSeconds: Double
    public var shotsPerSecond: Double { cycleSeconds > 0 ? shotsPerCycle / cycleSeconds : 0 }

    public static func compute(reloadTicks: Int, burstCount: Int, burstReloadTicks: Int, mounts: Int,
                               simultaneous: Bool, framesPerSecond: Double = 30) -> WeaponCadence {
        let n = Double(max(1, mounts))
        let fps = max(1, framesPerSecond)
        let reload = Double(max(0, reloadTicks))
        let volleyTicks = max(1, simultaneous ? reload : reload / n)
        let shotsPerVolley = simultaneous ? n : 1
        guard burstCount > 0 else {
            return WeaponCadence(shotsPerCycle: shotsPerVolley, cycleSeconds: volleyTicks / fps)
        }
        let volleys = Double(burstCount) * (simultaneous ? 1 : n)
        let ticks = (volleys - 1) * volleyTicks + max(1, Double(burstReloadTicks))
        return WeaponCadence(shotsPerCycle: volleys * shotsPerVolley, cycleSeconds: ticks / fps)
    }
}

/// One weapon as the submunition walker sees it.
public struct SubmunitionNode: Sendable, Equatable {
    public var shieldDamage: Double
    public var armorDamage: Double
    /// wëap SubType / SubCount / SubLimit.
    public var subID: Int
    public var subCount: Int
    public var subLimit: Int
    /// Beams and fighter bays are not handled as submunitions (Bible: "anything except beams and
    /// fighters"), so they add nothing when used as a SubType.
    public var cannotBeSubmunition: Bool

    public init(shieldDamage: Double, armorDamage: Double, subID: Int = -1, subCount: Int = 0,
                subLimit: Int = 0, cannotBeSubmunition: Bool = false) {
        self.shieldDamage = shieldDamage; self.armorDamage = armorDamage
        self.subID = subID; self.subCount = subCount; self.subLimit = subLimit
        self.cannotBeSubmunition = cannotBeSubmunition
    }
}

/// Damage a shot adds through its submunitions, assuming every submunition lands.
///
/// Rules (Shot_SpawnLinkedShotsOnImpact 0x00420d30; Bible SubCount/SubType/SubTheta/SubLimit):
/// a shot that expires or detonates spawns SubCount shots of SubType (SubTheta only changes their
/// aim). Each child carries a generation one higher than its parent (a fired shot is generation
/// 0). A shot does NOT spawn children when its SubLimit is positive and no greater than its own
/// generation - that is the recursion cap for a weapon that splits into copies of itself.
/// SubLimit 0 on a self-splitting weapon would never stop, so the walk is also capped at
/// `depthCap` generations and reports `truncated`.
public enum SubmunitionDamage {
    public struct Total: Sendable, Equatable {
        public var shield = 0.0
        public var armor = 0.0
        /// The walk hit `depthCap` while submunitions were still being spawned.
        public var truncated = false
        public var isEmpty: Bool { shield == 0 && armor == 0 }
    }

    /// Damage added by the submunitions of weapon `root` (not `root`'s own hit).
    public static func total(of root: Int, depthCap: Int = 5,
                             node: (Int) -> SubmunitionNode?) -> Total {
        var out = Total()
        func walk(_ id: Int, generation: Int) -> (shield: Double, armor: Double) {
            guard let n = node(id), n.subCount > 0, n.subID >= 128 else { return (0, 0) }
            if n.subLimit > 0, n.subLimit <= generation { return (0, 0) }
            if generation >= depthCap { out.truncated = true; return (0, 0) }
            guard let child = node(n.subID), !child.cannotBeSubmunition else { return (0, 0) }
            let deeper = walk(n.subID, generation: generation + 1)
            let count = Double(n.subCount)
            return (count * (child.shieldDamage + deeper.shield), count * (child.armorDamage + deeper.armor))
        }
        let r = walk(root, generation: 0)
        out.shield = r.shield; out.armor = r.armor
        return out
    }
}
