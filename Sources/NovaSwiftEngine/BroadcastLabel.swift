import Foundation
import NovaSwiftKit

extension World {
    /// The name a ship speaks with on the status bar (UI-11): the përs's own
    /// name when the ship is a named pilot (`+0xc8d0` ≠ −1, përs name at
    /// `+0x624`), else its hull's class name (`shïp +0x6c`), or a mission
    /// ship's `ShipName`. Used by the contraband scan sentence
    /// (0x00401800), the assistance "Repairs complete" line (0x00408150) and
    /// the scan warning (0x00403de0).
    public func broadcastLabel(of ship: Ship, game: NovaGame) -> String {
        if let pid = ship.personID, let pers = game.pers(pid), !pers.name.isEmpty { return pers.name }
        return OriginalAI.broadcastName(ship, game: game)
    }
}
