import Foundation
import NovaSwiftKit

/// The original's legal-status label (UI-14, `NovaUi_DrawSystemFactionConflictStatus`
/// 0x00468d90), shared by Player Info, the main menu and the star map.
///
/// The level comes from R, the player's reputation in a system, and T, that
/// system government's CrimeTol (government table entry 0 when the system is
/// ungoverned), in ×4 steps. Later tests override earlier ones. The label is
/// STR# 134 entry `level + 1`; level 0 reads "N/A" (STR# 2002 #396).
public enum LegalStatus {

    /// Level 0, "N/A": a xenophobic government, or (Player Info) a system with
    /// no usable destination.
    public static let notApplicable = 0
    public static let militaryDictator = 16
    public static let militaryGovernor = 17

    /// The record-driven level, 1…15.
    public static func level(reputation r: Int, crimeTolerance t: Int) -> Int {
        var level = 1                                  // R == 0: No Record
        if r < 0 {
            level = 2                                  // No Convictions
            if r < -t { level = 3 }                    // Minor Offender
            if r < -4 * t { level = 4 }                // Offender
            if r < -16 * t { level = 5 }               // Criminal
            if r < -64 * t { level = 6 }               // Wanted Criminal
            if r < -256 * t { level = 7 }              // Fugitive
            if r < -1024 * t { level = 8 }             // Hunted Fugitive
            if r < -4096 * t { level = 9 }             // Public Enemy
        } else if r > 0 {
            level = 10                                 // Citizen
            if r > 4 * t { level = 11 }                // Good Citizen
            if r > 16 * t { level = 12 }               // Upstanding Citizen
            if r > 64 * t { level = 13 }               // Leading Citizen
            if r > 256 * t { level = 14 }              // Model Citizen
            if r > 1024 * t { level = 15 }             // Virtuous Citizen
        }
        return level
    }

    /// The full level for `system`, with the domination and xenophobia
    /// overrides. Only the system's **first three** nav stellars are looked at
    /// for domination (an original quirk); of those that are usable (not
    /// destroyed, not uninhabited), any dominated gives Military Dictator, all
    /// of them Military Governor. `requireUsableDestination` is the Player Info
    /// window's extra N/A for a system with nowhere to land.
    public static func level(inSystem systemID: Int, player: PlayerState, game: NovaGame,
                             requireUsableDestination: Bool = false) -> Int {
        guard let system = game.system(systemID) else { return notApplicable }
        let govt = system.government >= 0 ? game.govt(system.government) : nil
        let tolerance = (govt ?? game.govts().min { $0.id < $1.id })?.crimeTolerance ?? 0
        var level = Self.level(reputation: player.legalStatusReputation(inSystem: systemID, game: game),
                               crimeTolerance: tolerance)
        let usable = system.spobs.prefix(3).compactMap(game.spob).filter {
            !$0.isUninhabited && !player.isStellarDestroyed($0.id)
        }
        let dominated = usable.filter { player.hasDominated($0.id) }.count
        if dominated > 0 { level = dominated == usable.count ? militaryGovernor : militaryDictator }
        if govt?.xenophobic == true { level = notApplicable }
        if requireUsableDestination,
           !system.spobs.compactMap(game.spob).contains(where: { !$0.isUninhabited && !$0.isGate }) {
            level = notApplicable
        }
        return level
    }

    /// The label for `level`, read from STR# 134 (N/A from STR# 2002 #396).
    public static func label(level: Int, game: NovaGame) -> String {
        if level == notApplicable { return game.stringList(2002)?.string(at: 396) ?? "N/A" }
        return game.stringList(134)?.string(at: level + 1) ?? ""
    }

    public static func label(inSystem systemID: Int, player: PlayerState, game: NovaGame,
                             requireUsableDestination: Bool = false) -> String {
        label(level: level(inSystem: systemID, player: player, game: game,
                           requireUsableDestination: requireUsableDestination), game: game)
    }
}

extension PlayerState {
    /// The player's reputation in `systemID`, the R the legal-status label is
    /// computed from — the original's one record per system (EC-02).
    public func legalStatusReputation(inSystem systemID: Int, game: NovaGame) -> Int {
        if systemReputation != nil { return reputation(atSystem: systemID) }
        // A pilot not yet migrated off the per-government record shows what its
        // migration would seed (EC-02).
        guard let system = game.system(systemID), system.government >= 0 else { return 0 }
        return legacyStanding(govt: system.government, atSystem: systemID)
    }
}
