import Foundation
import EVNovaKit

/// One-call assembly of a fully-wired, populated `World` for a system: the player
/// ship, the diplomacy table, the system's stellar geometry, and a spawner that
/// keeps NPCs coming and going from the `düde`/`flët` table. This is the seam the
/// app uses to turn "loaded data + a player ship" into a living system with AI.
///
/// The renderer keeps owning sprites/textures; this only builds the simulation.
public enum GameSession {

    /// Build a live world for `systemID`, populated with NPCs.
    ///
    /// - Parameters:
    ///   - game: the loaded, merged game data.
    ///   - systemID: the `sÿst` to play in.
    ///   - player: the player's ship (already carrying its stats/sprite identity).
    ///     Its combat state is filled in from the matching hull if it looks unset.
    ///   - galaxy: an existing catalog to reuse, or nil to build one.
    ///   - seed: RNG seed, so a session can be replayed deterministically.
    /// - Returns: the wired world and the galaxy catalog (for sprite lookups).
    @discardableResult
    public static func makeWorld(game: NovaGame, systemID: Int, player: Ship,
                                 galaxy existing: Galaxy? = nil,
                                 flightTuning: FlightTuning = .default,
                                 combatTuning: CombatTuning = .default,
                                 seed: UInt64 = 0x5EED_1234) -> (world: World, galaxy: Galaxy) {
        let galaxy = existing ?? Galaxy(game: game, flightTuning: flightTuning, combatTuning: combatTuning)

        // Give the player real combat stats/loadout from its hull if not already set.
        if player.weapons.isEmpty, player.shipTypeID >= 128, let spec = galaxy.shipSpec(player.shipTypeID) {
            player.maxShield = spec.maxShield; player.shield = spec.maxShield
            player.maxArmor = spec.maxArmor; player.armor = spec.maxArmor
            player.shieldRechargePerSec = spec.shieldRechargePerSec
            player.armorRechargePerSec = spec.armorRechargePerSec
            player.radius = spec.radius
            player.weapons = spec.mounts.map { WeaponMount(spec: $0.spec, ammo: $0.ammo) }
            if player.government == independentGovt { player.government = spec.government }
        }

        let world = World(player: player, tuning: flightTuning, combatTuning: combatTuning)
        world.rng = SplitMix64(seed: seed)
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        world.systemContext = galaxy.systemContext(for: systemID)
        if let sys = game.system(systemID) {
            let spawner = Spawner(galaxy: galaxy, table: SpawnTable(system: sys))
            world.spawner = spawner
            spawner.populate(world)
            world.populateAsteroids(typeIDs: sys.asteroidTypeIDs, count: sys.asteroidCount)
        }
        return (world, galaxy)
    }
}
