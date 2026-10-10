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
    /// `govtID` (`Ship_ScanPlayerForContraband` 0x00401800, EC-15). Nil when
    /// the government polices nothing (no ScanMask, or a SmugPenalty of 0) or
    /// nothing illegal is aboard. There is no CrimeTol gate.
    /// - Mission cargo and junk are fined flat (ScanFine ≥ 1) or by the
    ///   percentage arm; outfits only flat.
    /// - Junk with any ScanMask aboard suppresses the outfit check.
    /// - Illegal outfits and junk cost SmugPenalty standing; mission cargo
    ///   never does (an original quirk).
    public static func inspect(player: PlayerState, game: NovaGame, govtID: Int) -> ContrabandResult? {
        let govtMask = game.governmentScanMask(govtID)
        guard govtMask != 0, let govt = game.govt(govtID), govt.smugglePenalty != 0 else { return nil }

        let cargo = player.cargo.keys.filter { player.cargo[$0]! > 0 && game.isCargoContraband($0, to: govtID) }.sorted()
        let carriesScannableJunk = player.cargo.contains { $0.value > 0 && (game.junk($0.key)?.scanMask ?? 0) != 0 }
        let outfits = carriesScannableJunk ? [] :
            player.outfits.keys.filter { player.outfits[$0]! > 0 && game.isOutfitContraband($0, to: govtID) }.sorted()
        let smuggling = player.activeMissions.map(\.missionID)
            .filter { game.isMissionCargoContraband($0, to: govtID) }.sorted()

        guard !outfits.isEmpty || !cargo.isEmpty || !smuggling.isEmpty else { return nil }

        let scanFine = govt.scanFine
        var (amount, warningOnly) = Contraband.fine(scanFine: scanFine, cash: player.credits)
        if smuggling.isEmpty, cargo.isEmpty, scanFine < 0 { amount = 0 }   // outfits: flat fines only
        let smugPenalty = (outfits.isEmpty && cargo.isEmpty) ? 0 : max(0, govt.smugglePenalty)

        return ContrabandResult(contrabandOutfits: outfits, contrabandCargo: cargo,
                                smugglingMissions: smuggling, fine: amount,
                                warningOnly: warningOnly, smugglingPenalty: smugPenalty)
    }

    /// Inspect and apply the consequences to `player`: deduct the fine and apply
    /// the smuggling evilness to the legal record with `govtID`. Returns the
    /// result (nil if nothing was found).
    /// In flight the live `Diplomacy` owns the reputation: pass
    /// `recordCrime: false` and flood it there (`Diplomacy.recordSmuggling`).
    @discardableResult
    public static func enforce(on player: inout PlayerState, game: NovaGame, govtID: Int,
                               recordCrime: Bool = true) -> ContrabandResult? {
        guard let result = inspect(player: player, game: game, govtID: govtID) else { return nil }
        if result.fine > 0 { player.credits = max(0, player.credits - result.fine) }
        if recordCrime, result.smugglingPenalty > 0 {
            // Detected smuggling is a crime event like a kill or a board: the
            // SmugPenalty flood from the current system (EC-02).
            player.recordCrime(.smuggling, against: govtID, game: game)
        }
        return result
    }
}
