import Foundation
import NovaSwiftKit

/// Rank privileges (EC-10): `Government_HasRankPrivilege` 0x0046e860 reads two per-government
/// bytes the derived-state recompute (0x0046d4b0) rebuilds from the active ranks - privilege 0
/// ("won't attack", `ränk.Flags` 0x0100, +0x84) and privilege 1 ("always land", 0x0200, +0x85).
/// A rank's flag lands on **every government allied with the rank's government**
/// (`Government_AreGovtsAllied` 0x0046bc90: the same id; never when either side is a derelict
/// government, Flags 0x0800; otherwise any overlap between one side's classes and the other's
/// allies), not only on the rank's own. Landing (0x00457580), the radar colour (0x00466030) and
/// the map colour (0x00466260) all consult the AlwaysLand byte.
public enum RankPrivilege {
    public static let wontAttack = 0x0100
    public static let alwaysLand = 0x0200

    static func govtTable(_ game: NovaGame) -> [Int: GovtRes] {
        game.memo("RankPrivilege.govtTable") {
            Dictionary(game.govts().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Whether any active rank carrying `flag` belongs to a government allied with `govt`.
    public static func has(_ flag: Int, govt: Int, activeRanks: Set<Int>, game: NovaGame) -> Bool {
        guard govt >= 128, !activeRanks.isEmpty else { return false }
        let table = govtTable(game)
        for rid in activeRanks.sorted() {
            guard let r = game.rank(rid), r.flags & flag != 0, r.govt >= 128 else { continue }
            if GovtRelations.allied(r.govt, govt, govts: table) { return true }
        }
        return false
    }

    /// Every government the privilege reaches (the rebuilt byte array).
    public static func governments(with flag: Int, activeRanks: Set<Int>, game: NovaGame) -> Set<Int> {
        guard !activeRanks.isEmpty else { return [] }
        let table = govtTable(game)
        var out = Set<Int>()
        for rid in activeRanks.sorted() {
            guard let r = game.rank(rid), r.flags & flag != 0, r.govt >= 128 else { continue }
            for g in table.keys where GovtRelations.allied(r.govt, g, govts: table) { out.insert(g) }
        }
        return out
    }

    /// `Government_HasRankPrivilege(govt, 1)`: AlwaysLand reaches `govt`.
    public static func alwaysLands(at govt: Int, state: PlayerState, game: NovaGame) -> Bool {
        has(alwaysLand, govt: govt, activeRanks: state.activeRanks, game: game)
    }
}
