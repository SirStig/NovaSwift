import Foundation
import NovaSwiftKit

/// The Classic star map's marker-ring colour class (`Stellar_ComputeStellarDisplayColor`
/// 0x00466260), shared by the Apple `GalaxyMapView` rule and the Godot frontend.
///
/// Unvisited: dark grey. No usable port (gates, uninhabited and destroyed stellars do not
/// count): light grey. Otherwise graded from the usable stellars: any dominated one green,
/// else any the player may land on (MinStatus met, or an always-land rank) blue, else orange
/// while the system's legal reputation is >= 0 and red below. There is no neutral yellow.
public enum OriginalMapMarker {
    public enum Kind: Int, Sendable {
        case unvisited = 0, noPort, dominated, landable, friendly, hostile
    }

    public static func kind(system s: SystRes, state: PlayerState, game: NovaGame, visited: Bool) -> Kind {
        guard visited else { return .unvisited }
        let usable = s.spobs.compactMap(game.spob).filter {
            !$0.isGate && !$0.isUninhabited && !state.isStellarDestroyed($0.id)
        }
        guard !usable.isEmpty else { return .noPort }
        let rep = state.legalStatusReputation(inSystem: s.id, game: game)
        var dominated = 0, landable = 0, friendly = 0, hostile = 0
        for spob in usable {
            if state.hasDominated(spob.id) { dominated += 1; continue }
            let alwaysLand = RankPrivilege.alwaysLands(at: spob.government, state: state, game: game)
            let forbidden = spob.minStatus == 32767 || (rep < spob.minStatus && spob.minStatus > -32767)
            if !alwaysLand && forbidden {
                if rep < 0 { hostile += 1 } else { friendly += 1 }
            } else {
                landable += 1
            }
        }
        if dominated > 0 { return .dominated }
        if landable > 0 { return .landable }
        if friendly > 0 { return .friendly }
        if hostile > 0 { return .hostile }
        return .noPort
    }

    /// The ring colour as 0...1 RGB.
    public static func rgb(_ kind: Kind) -> (r: Double, g: Double, b: Double) {
        switch kind {
        case .unvisited: return (0.25, 0.25, 0.25)
        case .noPort: return (0.75, 0.75, 0.75)
        case .dominated: return (0.2, 0.85, 0.3)
        case .landable: return (0, 0, 1)
        case .friendly: return (1, 0.4, 0)
        case .hostile: return (1, 0, 0)
        }
    }
}
