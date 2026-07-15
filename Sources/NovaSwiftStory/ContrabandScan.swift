import Foundation
import NovaSwiftKit

/// What a government scan turned up in the player's holds and equipment.
public struct ContrabandResult: Equatable, Sendable {
    /// Owned outfit ids the scanning government considers illegal.
    public let contrabandOutfits: [Int]
    /// Cargo (jünk) ids the scanning government considers illegal.
    public let contrabandCargo: [Int]
    /// Active mission ids whose (illegal) cargo was detected — the smuggling case.
    public let smugglingMissions: [Int]
    /// Credits levied by the `ScanFine` rule (0 when a warning-only govt).
    public let fine: Int
    /// True when the government fines nothing and only warns (`ScanFine == 0`).
    public let warningOnly: Bool
    /// `SmugPenalty` legal-record evilness applied for mission smuggling (0 if none).
    public let smugglingPenalty: Int

    public var foundContraband: Bool {
        !contrabandOutfits.isEmpty || !contrabandCargo.isEmpty || !smugglingMissions.isEmpty
    }
}

/// Government contraband scanning: given who's scanning, decide what the player
/// is illegally carrying and levy the EV Nova `ScanFine` / `SmugPenalty`
/// consequences. Pure with respect to everything except the `PlayerState` it's
/// told to mutate. Driven by the app when a `WorldEvent.shipScanned` targeting
/// the player arrives (the scanning ship's government is the `govtID`).
public enum ContrabandScan {

    /// Inspect (without mutating) what the player carries that is illegal to
    /// `govtID`. Returns nil when the player is already criminal enough with this
    /// government to simply be attacked (`CrimeTol`) — fines don't apply then,
    /// combat does — or when nothing illegal is aboard.
    public static func inspect(player: PlayerState, game: NovaGame, govtID: Int) -> ContrabandResult? {
        let govtMask = game.governmentScanMask(govtID)
        guard govtMask != 0 else { return nil }   // this govt polices nothing

        // Already-attackable gate: evilness ≥ CrimeTol means they'd be shot at,
        // not fined (Bible: fined only "if he isn't yet evil enough to attack").
        // Uses the *effective* (universal + local-here) standing — the same
        // "displayed legal status" combat hostility checks against.
        if let g = game.govt(govtID) {
            let evilness = max(0, -player.effectiveLegalRecord(govt: govtID, atSystem: player.currentSystem))
            if g.crimeTolerance > 0, evilness >= g.crimeTolerance { return nil }
        }

        let outfits = player.outfits.keys.filter { player.outfits[$0]! > 0 && game.isOutfitContraband($0, to: govtID) }.sorted()
        let cargo = player.cargo.keys.filter { player.cargo[$0]! > 0 && game.isCargoContraband($0, to: govtID) }.sorted()
        let smuggling = player.activeMissions.map(\.missionID)
            .filter { game.isMissionCargoContraband($0, to: govtID) }.sorted()

        guard !outfits.isEmpty || !cargo.isEmpty || !smuggling.isEmpty else { return nil }

        let scanFine = game.govt(govtID)?.scanFine ?? 0
        let (amount, warningOnly) = Contraband.fine(scanFine: scanFine, cash: player.credits)
        let smugPenalty = smuggling.isEmpty ? 0 : max(0, game.govt(govtID)?.smugglePenalty ?? 0)

        return ContrabandResult(contrabandOutfits: outfits, contrabandCargo: cargo,
                                smugglingMissions: smuggling, fine: amount,
                                warningOnly: warningOnly, smugglingPenalty: smugPenalty)
    }

    /// Inspect and apply the consequences to `player`: deduct the fine and apply
    /// the smuggling evilness to the legal record with `govtID`. Returns the
    /// result (nil if nothing was found / the player is already attackable).
    @discardableResult
    public static func enforce(on player: inout PlayerState, game: NovaGame, govtID: Int) -> ContrabandResult? {
        guard let result = inspect(player: player, game: game, govtID: govtID) else { return nil }
        if result.fine > 0 { player.credits = max(0, player.credits - result.fine) }
        if result.smugglingPenalty > 0 {
            // Detected smuggling is a hostile-action-against-ships-style
            // event, not a mission reward, so — per the wiki's Legal Status
            // page — it's felt *locally*: full weight at the current system,
            // tapered into nearby ones, plus the usual §1.2 ally/enemy
            // propagation at each. Same rule live combat uses
            // (`NovaSwiftEngine.Diplomacy.recordCrime`), reimplemented here
            // via the shared `LegalRecordPropagation.applyLocal` since
            // `NovaSwiftStory` can't depend on `NovaSwiftEngine`.
            let govtsByID = Dictionary(uniqueKeysWithValues: game.govts().map { ($0.id, $0) })
            let here = player.currentSystem
            var local = player.localLegalRecord ?? [:]
            var current: [Int: Int] = [:]
            for (govt, bySystem) in local { if let v = bySystem[here] { current[govt] = v } }
            var spread: [Int: [Int: Int]] = [:]
            LegalRecordPropagation.applyLocal(penalty: result.smugglingPenalty, to: govtID, atSystem: here,
                                              current: &current, spread: &spread,
                                              govts: govtsByID, game: game)
            for (govt, value) in current { local[govt, default: [:]][here] = value }
            for (govt, bySystem) in spread {
                for (systemID, delta) in bySystem { local[govt, default: [:]][systemID, default: 0] += delta }
            }
            player.localLegalRecord = local
        }
        return result
    }
}
