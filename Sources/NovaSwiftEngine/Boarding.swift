import Foundation

// MARK: - Fuel & ammunition plunder
//
// The EV Nova "Plunder Dialog" (`DLOG`/`DITL` #1011) offers six actions, whose
// labels are the six consecutive `STR#` 150 entries "Cargo · Credits · Ammo ·
// Energy · Capture Ship · Demand Tribute". Cargo, Credits, Capture and the
// `përs` ItemClass loot are handled in `World`'s main boarding section; the two
// remaining resource siphons — **Energy** (the hulk's jump fuel) and **Ammo**
// (its weapon ammunition) — live here so they can be added without editing the
// heavily-trafficked `World.swift`. All four entry points share the same
// "is this a boardable hulk?" guard the rest of the boarding code uses (alive +
// disabled + not the player), so they're safe to call on any entity id.
extension World {

    /// Jump fuel aboard disabled hulk `shipID` that the player could siphon, in
    /// engine fuel units (100 = one hyperjump). 0 if it isn't a boardable hulk.
    public func fuelAboard(_ shipID: Int) -> Double {
        guard let s = ship(id: shipID), s !== player, s.isAlive, s.disabled else { return 0 }
        return max(0, s.fuel)
    }

    /// Siphon a boarded hulk's jump fuel into the player, capped at the player's
    /// remaining fuel capacity. Zeroes what was taken from the hulk (so it can't
    /// be re-siphoned) and returns the units actually transferred.
    @discardableResult
    public func takePlunderFuel(from shipID: Int) -> Double {
        guard let s = ship(id: shipID), s !== player, s.isAlive, s.disabled else { return 0 }
        let room = max(0, player.maxFuel - player.fuel)
        let take = min(max(0, s.fuel), room)
        guard take > 0 else { return 0 }
        player.fuel += take
        s.fuel -= take
        return take
    }

    /// Total ammunition aboard disabled hulk `shipID` that the player could take
    /// — only rounds for weapon types the player also carries (and that have room
    /// to spare) can be looted, matching EV Nova's "the ammo tops up your guns"
    /// behavior. 0 if it isn't a boardable hulk.
    public func ammoAboard(_ shipID: Int) -> Int {
        guard let s = ship(id: shipID), s !== player, s.isAlive, s.disabled else { return 0 }
        var total = 0
        for hulkMount in s.weapons where hulkMount.ammo > 0 {
            let cap = galaxy?.game.weapon(hulkMount.spec.id)?.maxAmmo ?? 0
            for mine in player.weapons where mine.spec.id == hulkMount.spec.id && mine.ammo >= 0 {
                total += min(hulkMount.ammo, max(0, cap - mine.ammo))
            }
        }
        return total
    }

    /// Transfer a boarded hulk's ammunition into the player's matching weapons,
    /// each pool capped at that weapon's `maxAmmo`. Decrements the hulk's rounds
    /// (so re-boarding can't duplicate them) and returns the rounds taken.
    /// `WeaponMount` is a reference type, so mutating the elements in place sticks.
    @discardableResult
    public func takePlunderAmmo(from shipID: Int) -> Int {
        guard let s = ship(id: shipID), s !== player, s.isAlive, s.disabled else { return 0 }
        var taken = 0
        for hulkMount in s.weapons where hulkMount.ammo > 0 {
            let cap = galaxy?.game.weapon(hulkMount.spec.id)?.maxAmmo ?? 0
            for mine in player.weapons where mine.spec.id == hulkMount.spec.id && mine.ammo >= 0 {
                let move = min(hulkMount.ammo, max(0, cap - mine.ammo))
                guard move > 0 else { continue }
                mine.ammo += move
                hulkMount.ammo -= move
                taken += move
            }
        }
        return taken
    }
}
