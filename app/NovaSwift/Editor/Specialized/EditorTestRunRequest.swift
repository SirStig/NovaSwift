#if os(macOS)
import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// A request, posted on `EditorModel.testRunRequest`, for the shell to open a test run
/// (`EditorTestRunView`) — optionally pre-equipped and with a disabled target dummy
/// placed ahead of the player ("firing range").
struct EditorTestRunRequest: Equatable, Identifiable {
    let id = UUID()
    var ship: Int?
    var system: Int?
    /// `wëap` ids to mount (via the outfit that installs each) once the run is up.
    var giveWeapons: [Int] = []
    /// Place an invulnerable, disabled dummy ~500 px dead ahead of the player and make
    /// the player invulnerable so the author can shoot at it undisturbed.
    var rangeDummyHull: Int?

    /// Runs on the main actor once the session is `.running`.
    @MainActor
    func prepare(_ session: EditorTestSession) {
        let req = self
        Task { @MainActor in
            guard let game = session.game else { return }
            for w in req.giveWeapons {
                if let o = game.outfitInstalling(weapon: w) { session.giveOutfit(o, count: 1) }
                // Ammunition outfit for a launcher: the outfit whose first slot loads this weapon's pool.
                if let raw = game.weapon(w), raw.ammoType >= 0,
                   let ammo = game.outfits().first(where: {
                       $0.firstSlot.type == OutfitModType.ammunition.rawValue && $0.firstSlot.value == 128 + raw.ammoType
                   }) {
                    session.giveOutfit(ammo.id, count: 25)
                }
            }
            guard let hull = req.rangeDummyHull else { return }
            // Equipping rebuilds the host in place; give it a moment to settle.
            if !req.giveWeapons.isEmpty { try? await Task.sleep(nanoseconds: 1_800_000_000) }
            session.setGod(true)
            guard session.spawnShips(hull: hull, count: 1, stance: .neutral, govt: nil, placement: .nearPlayer) > 0,
                  let world = session.host?.scene.editorWorld,
                  let dummy = world.npcs.last else { return }
            dummy.maxArmor = 1e7; dummy.armor = 1e7
            dummy.maxShield = 1e7; dummy.shield = 1e7
            dummy.heldDisabled = true
            dummy.velocity = Vec2(0, 0)
            dummy.position = world.player.position + Vec2.heading(world.player.angle) * 500
        }
    }
}
#endif
