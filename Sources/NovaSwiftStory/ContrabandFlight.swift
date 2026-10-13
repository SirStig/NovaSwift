import Foundation
import NovaSwiftKit

/// What the player's in-flight scan by a government ship turned up and cost —
/// the consequence the Apple app wires into `GameScene.onPlayerScanned`.
public struct PlayerScanOutcome: Equatable, Sendable {
    /// Active missions blown because the scan found their illegal cargo aboard
    /// (`mïsn` Flags 0x0020 "fail if scanned").
    public var failedMissionIDs: [Int] = []
    /// The contraband verdict (nil = nothing illegal).
    public var result: ContrabandResult?
    /// The government that scanned.
    public var scannerGovt: Int
    public var scannerName: String

    /// The status-line lines for this scan, in the original's order
    /// (`Ship_ScanPlayerForContraband` 0x00401800): STR# 2002 #286 for a
    /// fail-if-scanned mission (nothing when its Flags hold 0x0400), then the
    /// detected-contraband sentence for mission cargo, and for junk or an
    /// outfit (`OriginalText.scanDetected`). The invented "logs your
    /// smuggling" line is gone: the SmugPenalty flood prints nothing.
    public var messages: [String] = []
}

extension ContrabandScan {
    /// A government ship `scannerGovt` finished scanning the player: smuggling
    /// missions that fail when scanned are blown, then the contraband fine
    /// (`ScanFine`) is levied. The `SmugPenalty` flood is left to the live
    /// per-system record (`recordCrime: false`) — the caller floods
    /// `Diplomacy.recordSmuggling` when `outcome.result?.smugglingPenalty > 0`.
    @discardableResult
    public static func scanPlayer(state: inout PlayerState, game: NovaGame, scannerGovt: Int,
                                  services: GameServices? = nil, scannerLabel: String? = nil) -> PlayerScanOutcome {
        var out = PlayerScanOutcome(scannerGovt: scannerGovt,
                                    scannerName: scannerLabel ?? game.govt(scannerGovt)?.displayName ?? "Patrol")
        let failIDs = state.activeMissions.map(\.missionID).filter { id in
            guard let m = game.mission(id), m.failIfScanned else { return false }
            let cargoType = state.activeMission(id)?.resolvedCargoType ?? m.cargoType
            return (state.cargo[cargoType] ?? 0) > 0 && game.isMissionCargoContraband(id, to: scannerGovt)
        }
        if !failIDs.isEmpty {
            let engine = StoryEngine(game: game, player: state, services: services)
            for id in failIDs { engine.failMission(id) }
            state = engine.player
            out.failedMissionIDs = failIDs
        }
        let hidden = failIDs.first.flatMap { game.mission($0)?.invisible } ?? false
        out.result = enforce(on: &state, game: game, govtID: scannerGovt, recordCrime: false)
        out.messages = scanLines(failed: !failIDs.isEmpty && !hidden, result: out.result, state: state,
                                 game: game, scanner: out.scannerName)
        return out
    }

    /// The sentences of one scan (see `PlayerScanOutcome.messages`). `state`
    /// supplies the pilot's name and the outfit counts.
    public static func scanLines(failed: Bool, result: ContrabandResult?, state: PlayerState,
                                 game: NovaGame, scanner: String) -> [String] {
        let text = OriginalText(game: game)
        var lines: [String] = []
        if failed { lines.append(text.misc(286)) }
        guard let result, result.foundContraband else { return lines }
        let pilot = state.pilotName
        let fine = result.fine
        if !result.smugglingMissions.isEmpty {
            lines.append(text.scanDetected(scanner: scanner, pilot: pilot, finding: .missionCargo, fine: fine))
        }
        if let junkID = result.contrabandCargo.first, let junk = game.junk(junkID) {
            lines.append(text.scanDetected(scanner: scanner, pilot: pilot,
                                           finding: .junk(junk.runningTextName), fine: fine))
        } else if let outfitID = result.contrabandOutfits.first, let outfit = game.outfit(outfitID) {
            let count = state.outfits[outfitID] ?? 1
            lines.append(text.scanDetected(
                scanner: scanner, pilot: pilot,
                finding: .outfit(singular: outfit.lowercaseDisplayName, plural: outfit.lowercasePluralDisplayName,
                                 count: count), fine: fine))
        }
        return lines
    }
}
