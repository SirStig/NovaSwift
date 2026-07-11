import Foundation
import NovaSwiftKit

/// What a hail (or board) of a named `pêrs` character produces: the quotes to
/// display and the mission (if any) to offer.
public struct PersHailResult: Equatable, Sendable {
    public let personID: Int
    public let name: String
    /// Comm-dialog quote (`STR#` 7100[CommQuote]), or nil if none applies.
    public let commQuote: String?
    /// Over-the-radio quote (`STR#` 7101[HailQuote]), gated by the flag
    /// conditions, or nil.
    public let hailQuote: String?
    /// `PICT` id to show in the comm dialog instead of the ship's default, or nil.
    public let hailPictID: Int?
    /// The `mïsn` id this person offers right now (LinkMission), or nil.
    public let offerMissionID: Int?
}

/// Resolves a `pêrs` character's hail/board interaction — the quotes and the
/// LinkMission offer — against live pilot + story state, honouring `pêrs.Flags`.
public enum PersEncounter {

    /// Whether the player currently "likes" this person: no grudge and a
    /// non-negative legal standing with the person's government.
    public static func likesPlayer(_ pers: PersRes, player: PlayerState) -> Bool {
        guard !player.persHoldsGrudge(pers.personID) else { return false }
        guard pers.govt >= 0 else { return true }
        return (player.legalRecord[pers.govt] ?? 0) >= 0
    }

    /// The `mïsn` this person offers right now (LinkMission), if it's valid,
    /// unfinished, and its own gate passes — nil otherwise. `boarding` selects
    /// the board-vs-hail offer context (Flags 0x0200).
    public static func offeredMission(_ pers: PersRes, player: PlayerState, game: NovaGame,
                                      engine: StoryEngine, boarding: Bool) -> Int? {
        guard pers.linkMission >= 128 else { return nil }
        // Flags 0x0200: offer on boarding, not hailing (and vice-versa).
        if pers.offerMissionOnBoard != boarding { return nil }
        guard let m = game.mission(pers.linkMission) else { return nil }
        if player.isMissionActive(m.id) || player.completedMissions.contains(m.id) { return nil }
        guard engine.evaluate(test: m.availBits) else { return nil }
        return m.id
    }

    /// Resolve a hail (or board, when `boarding` is true) of `pers`. `disabled`
    /// is whether the person's ship is currently a disabled hulk (enables the
    /// disabled-only HailQuote). Does not mutate — the caller applies quote-once
    /// via `PlayerState.markPersQuoteShown` when it actually shows the quote.
    public static func hail(_ pers: PersRes, player: PlayerState, game: NovaGame,
                            engine: StoryEngine, boarding: Bool = false,
                            disabled: Bool = false) -> PersHailResult {
        let mission = offeredMission(pers, player: player, game: game, engine: engine, boarding: boarding)
        let missionAvailable = mission != nil
        let hasGrudge = player.persHoldsGrudge(pers.personID)
        let likes = likesPlayer(pers, player: player)

        // Quote-once already spent? Then no quotes.
        let spent = pers.quoteOnce && player.wasPersQuoteShown(pers.personID)
        // "Don't show quote when the LinkMission isn't available" (0x0400).
        let missionGateOK = !pers.noQuoteWithoutMission || missionAvailable

        func str(_ listID: Int, _ index1: Int) -> String? {
            guard index1 >= 1, let list = game.stringList(listID), index1 <= list.strings.count else { return nil }
            let s = list.strings[index1 - 1]
            return s.isEmpty ? nil : s
        }

        // CommQuote: shown in the comm dialog when hailing (not on a plain board).
        var comm: String?
        if !boarding, !spent, missionGateOK, pers.commQuote >= 1 {
            comm = str(7100, pers.commQuote)
        }

        // HailQuote: gated by the "only show when…" flags. With none of those
        // flags set it shows by default; a set flag requires its condition.
        var hail: String?
        if !spent, missionGateOK, pers.hailQuote >= 1 {
            let conditional = pers.hailQuoteWhenGrudge || pers.hailQuoteWhenLikes
                || pers.hailQuoteWhenAttacking || pers.hailQuoteWhenDisabled
            let ok = !conditional
                || (pers.hailQuoteWhenGrudge && hasGrudge)
                || (pers.hailQuoteWhenLikes && likes)
                || (pers.hailQuoteWhenDisabled && disabled)
            if ok { hail = str(7101, pers.hailQuote) }
        }

        return PersHailResult(personID: pers.personID, name: pers.name,
                              commQuote: comm, hailQuote: hail,
                              hailPictID: pers.hailPict >= 128 ? pers.hailPict : nil,
                              offerMissionID: mission)
    }
}
