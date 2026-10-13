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

    /// The status-line lines the original-port app posts for this scan.
    public var messages: [String] {
        var out: [String] = []
        if !failedMissionIDs.isEmpty { out.append("Your illicit cargo was detected — mission failed.") }
        if let r = result, r.foundContraband {
            if r.warningOnly { out.append("\(scannerName): contraband detected — you are let off with a warning.") }
            else if r.fine > 0 { out.append("\(scannerName) fined you \(r.fine)cr for carrying contraband.") }
            if r.smugglingPenalty > 0 { out.append("\(scannerName) logs your smuggling; your standing worsens.") }
        }
        return out
    }
}

extension ContrabandScan {
    /// A government ship `scannerGovt` finished scanning the player: smuggling
    /// missions that fail when scanned are blown, then the contraband fine
    /// (`ScanFine`) is levied. The `SmugPenalty` flood is left to the live
    /// per-system record (`recordCrime: false`) — the caller floods
    /// `Diplomacy.recordSmuggling` when `outcome.result?.smugglingPenalty > 0`.
    @discardableResult
    public static func scanPlayer(state: inout PlayerState, game: NovaGame, scannerGovt: Int,
                                  services: GameServices? = nil) -> PlayerScanOutcome {
        var out = PlayerScanOutcome(scannerGovt: scannerGovt,
                                    scannerName: game.govt(scannerGovt)?.displayName ?? "Patrol")
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
        out.result = enforce(on: &state, game: game, govtID: scannerGovt, recordCrime: false)
        return out
    }
}
