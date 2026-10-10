import Foundation
import NovaSwiftKit

/// The IFF decoder's stellar colours (OS-05, D-4):
/// `Stellar_GetStellarRadarColor` 0x00466030, read by the radar panel
/// 0x0045d600 while an IFF (oütf ModType 14) is owned. Colours are the
/// original's 16-bit QuickDraw components.
public enum RadarIFF {
    public typealias RGB16 = (r: UInt16, g: UInt16, b: UInt16)

    /// Theme grey 0x00733b56 (`Settings_InitColors` 0x004ad7c0: 0x8000 each).
    public static let inactive: RGB16 = (0x8000, 0x8000, 0x8000)
    public static let yellow: RGB16 = (0xFFFF, 0xFFFF, 0)
    public static let orange: RGB16 = (0xFFFF, 0x6666, 0)
    public static let red: RGB16 = (0xFFFF, 0, 0)
    public static let green: RGB16 = (0, 0xFFFF, 0)
    public static let wormhole: RGB16 = (0, 22000, 22000)

    /// The ladder, first match wins:
    /// 1. not landable, or not in the destroyed state its Flags 0x0080 asks
    ///    for (0x0046e3f0), or uninhabited (Flags 0x20) → inactive grey;
    /// 2. a hypergate → yellow under an always-land rank, else the standing
    ///    ladder (6);
    /// 3. a wormhole → dark cyan;
    /// 4. dominated → green;
    /// 5. an always-land rank with its government → yellow;
    /// 6. MinStatus 32767, or the system's reputation below a MinStatus above
    ///    −32767 → red at negative reputation, else orange; otherwise yellow.
    public static func stellarColor(_ spob: SpobRes, state: PlayerState, game: NovaGame, system: Int) -> RGB16 {
        let destroyed = state.isStellarDestroyed(spob.id)
        guard spob.canLand, destroyed == spob.landsOnlyWhenDestroyed, !spob.isUninhabited else { return inactive }
        let alwaysLand = spob.government >= 0 && state.activeRanks.contains { rid in
            game.rank(rid).map { $0.canAlwaysLand && $0.govt == spob.government } ?? false
        }
        func standing() -> RGB16 {
            let rep = state.reputation(atSystem: system)
            let refused = spob.minStatus == 32767 || (rep < spob.minStatus && spob.minStatus > -32767)
            guard refused else { return yellow }
            return rep < 0 ? red : orange
        }
        if spob.isHypergate { return alwaysLand ? yellow : standing() }
        if spob.isWormhole { return wormhole }
        if state.hasDominated(spob.id) || spob.startsDominated { return green }
        if alwaysLand { return yellow }
        return standing()
    }
}
