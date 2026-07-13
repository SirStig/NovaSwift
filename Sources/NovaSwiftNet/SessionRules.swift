import Foundation

/// Governs what inter-player interactions actually *do* while players are
/// co-located. Every player always plays their own persistent galaxy/save — these
/// toggles never touch solo progression. They decide whether PvP damage/death is
/// real, whether PvP and trade are allowed, and whether outcomes inside an
/// authority's system carry back to a visitor's own galaxy.
///
/// See `docs/MULTIPLAYER.md` → "Stakes / SessionRules".
public struct SessionRules: Codable, Equatable, Sendable {
    /// Damage from another player actually hurts your ship.
    public var pvpDamageReal: Bool
    /// Being destroyed by / near another player is real death in your own game.
    public var deathReal: Bool
    /// Co-op partners can hit each other.
    public var friendlyFire: Bool
    /// Players may fire on one another at all.
    public var allowPvP: Bool
    /// Players may trade credits / cargo / outfits.
    public var allowTrade: Bool
    /// Outcomes in an authority's system (kills, loot) carry back to a visitor's
    /// own galaxy.
    public var carryEncounter: Bool

    public init(pvpDamageReal: Bool, deathReal: Bool, friendlyFire: Bool,
                allowPvP: Bool, allowTrade: Bool, carryEncounter: Bool) {
        self.pvpDamageReal = pvpDamageReal
        self.deathReal = deathReal
        self.friendlyFire = friendlyFire
        self.allowPvP = allowPvP
        self.allowTrade = allowTrade
        self.carryEncounter = carryEncounter
    }

    /// Sparring / safe: players can fight but nothing hurts for real.
    public static let safe = SessionRules(
        pvpDamageReal: false, deathReal: false, friendlyFire: false,
        allowPvP: true, allowTrade: true, carryEncounter: false)

    /// Full stakes: your ship is your real ship — damage and death count, and
    /// encounter outcomes carry back.
    public static let fullStakes = SessionRules(
        pvpDamageReal: true, deathReal: true, friendlyFire: true,
        allowPvP: true, allowTrade: true, carryEncounter: true)
}
