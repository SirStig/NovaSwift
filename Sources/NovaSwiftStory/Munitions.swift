import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// Ammunition and carried fighters as pilot state (UI-02).
///
/// In the original a weapon bank's loaded rounds and a bay's carried fighters
/// are saved with the pilot, and the outfitter's count of an ammunition outfit
/// *is* that bank's loaded rounds: `Weapon_ReconcileOutfitPoolWithWeaponBanks`
/// (0x00462ec0) walks the owned ammo outfits in order, letting each explain as
/// many rounds as the bank still holds and clamping it down past that, then
/// credits any rounds left unexplained (plundered ammo) to the first matching
/// outfit. So fired missiles and lost fighters stay spent until bought again.
///
/// NovaSwift keeps rounds as owned ammunition outfits (`PlayerState.outfits`)
/// and builds each flight's mounts from them; this folds what the flight spent
/// or plundered back into those counts.
public enum Munitions {

    /// Fold the live ship's remaining rounds and carried fighters back into the
    /// pilot's owned ammunition outfits. Returns true when a count changed.
    @discardableResult
    public static func record(_ ship: Ship, into state: inout PlayerState, game: NovaGame) -> Bool {
        var rounds: [Int: Int] = [:]                       // ammo pool → rounds aboard
        for mount in ship.weapons where mount.spec.ammoPerShot > 0 && mount.ammo >= 0 {
            guard mount.spec.ammoTypeRaw >= 0, !isFighterBay(mount.spec.id, ship: ship) else { continue }
            let pool = 128 + mount.spec.ammoTypeRaw
            // Mounts sharing a pool were each seeded with the whole pool, so
            // the pool holds what the emptiest one has left.
            rounds[pool] = min(rounds[pool] ?? .max, mount.ammo)
        }
        for bay in ship.fighterBays {
            rounds[bay.spec.bayWeaponID, default: 0] += bay.docked + bay.deployed.count
        }
        var changed = false
        for (pool, aboard) in rounds {
            changed = reconcile(pool: pool, rounds: aboard, state: &state, game: game) || changed
        }
        return changed
    }

    /// Fighters a bay carries this flight: the owned ammunition outfits that
    /// load it, up to its capacity. Nil when no outfit loads the bay — such a
    /// bay can't be restocked, so it flies full.
    public static func carriedFighters(bayWeaponID: Int, capacity: Int, state: PlayerState, game: NovaGame) -> Int? {
        let loaders = ammoOutfits(forPool: bayWeaponID, game: game)
        guard !loaders.isEmpty else { return nil }
        let owned = loaders.reduce(0) { $0 + (state.outfits[$1] ?? 0) }
        return min(capacity, owned)
    }

    /// Set each of the player's bays to the fighters the pilot actually owns.
    public static func loadCarriedFighters(into ship: Ship, state: PlayerState, game: NovaGame) {
        for bay in ship.fighterBays {
            guard let carried = carriedFighters(bayWeaponID: bay.spec.bayWeaponID, capacity: bay.spec.capacity,
                                                state: state, game: game) else { continue }
            bay.docked = carried
            ship.weapons.first { $0.spec.id == bay.spec.bayWeaponID }?.ammo = carried
        }
    }

    // MARK: -

    private static func isFighterBay(_ weaponID: Int, ship: Ship) -> Bool {
        ship.fighterBays.contains { $0.spec.bayWeaponID == weaponID }
    }

    /// Outfits whose ModType-3 ammunition names `pool`, in id order.
    private static func ammoOutfits(forPool pool: Int, game: NovaGame) -> [Int] {
        game.outfits().filter { $0.ammoFor.contains(pool) }.map(\.id).sorted()
    }

    /// The original's two-way reconcile for one pool.
    private static func reconcile(pool: Int, rounds: Int, state: inout PlayerState, game: NovaGame) -> Bool {
        let loaders = ammoOutfits(forPool: pool, game: game)
        guard !loaders.isEmpty else { return false }
        let before = loaders.map { state.outfits[$0] ?? 0 }
        var balance = max(0, rounds)
        for id in loaders {
            let owned = state.outfits[id] ?? 0
            guard owned > 0 else { continue }
            if owned < balance {
                balance -= owned
            } else {
                state.outfits[id] = balance > 0 ? balance : nil
                balance = 0
            }
        }
        if balance > 0 {
            let first = loaders[0]
            state.outfits[first, default: 0] += balance
        }
        return loaders.map { state.outfits[$0] ?? 0 } != before
    }
}
