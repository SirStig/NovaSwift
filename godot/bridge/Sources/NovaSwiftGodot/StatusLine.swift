// Plain-Swift state and pure helpers for the bridge's status line (`// MARK: UI polish`
// in NovaWorld.swift); same split as Flight.swift / Audio.swift. `@Godot` registers only
// what is declared in the class body, so the callables live in NovaWorld.
//
// No game logic here: the arrival / launch wording is the shared `OriginalText`
// (`arrival` #43-49 / #164-165, `launch` #55-60), the buoy is `NovaGame.systemMessageText`
// (STR# 1000), the HailQuote broadcast is the shared `PersQuoteBroadcaster`
// (0x00433050) and the radar stellar colour is the shared `RadarIFF` (0x00466030).
// These are the same calls the Apple app makes in `GameContainerView.postArrivalLine` /
// `postLaunchLine` and `GameScene.broadcastHailQuotes`.

import Foundation
import NovaSwiftEngine
import NovaSwiftKit
import NovaSwiftStory

struct StatusLineState {
    /// Display length, in raw sim calls, of lines posted with a non-default duration
    /// (the buoy 0x1e0, a mission `Q` 0x1f4, a HailQuote 0x1a4, landing 0xfa / 0x168).
    /// GDScript pops an entry as it shows the line; absent = the default 0xf0.
    var rawCalls: [String: Int] = [:]
    /// The frontend's message line is showing something (the broadcast waits for it).
    var busy = false
    /// The sound volume is below 2 of 7 (Red Alert shows the cicn blink then).
    var lowVolume = false
    /// Test seam (status_line_selfcheck): the 1-in-140 roll always passes.
    var forceRoll = false
    /// Per-ship HailQuote latches and the original's rate gates.
    let quotes = PersQuoteBroadcaster()

    mutating func note(_ line: String, rawCalls calls: Int) {
        guard calls > 0, !line.isEmpty else { return }
        if rawCalls.count > 48 { rawCalls.removeAll() }
        rawCalls[line] = calls
    }

    mutating func pop(_ line: String) -> Int { rawCalls.removeValue(forKey: line) ?? 0 }

    func resetForNewWorld() { quotes.reset() }
}

enum StatusLineBackend {
    /// The line on arriving in a system (0x0044f3d0; UI-11): the sÿst buoy (STR# 1000,
    /// 0x1e0 raw calls) when the system has one, else "Arriving in the X system on
    /// <date>." (#43-48; gate #46 / wormhole #47; "No stellar objects present." #49;
    /// "(N fighters abandoned)" #164/#165). Mirrors `GameContainerView.postArrivalLine`.
    static func arrival(game: NovaGame, pilot: PlayerState, systemID: Int, gateID: Int?,
                        abandonedFighters: Int) -> (text: String, rawCalls: Int)? {
        guard let system = game.system(systemID) else { return nil }
        if let buoy = game.systemMessageText(system.message) {
            return (buoy, OriginalText.Duration.buoy)
        }
        let gate = gateID.flatMap { game.spob($0) }
        let kind: OriginalText.GateKind? = gate.map { $0.isWormhole ? .wormhole : .hypergate }
        let hasStellars = system.spobs.contains { game.spob($0).map { !$0.isGate } ?? false }
        let line = OriginalText(game: game).arrival(system: system.displayName, player: pilot,
                                                    hasStellars: hasStellars, via: kind,
                                                    abandonedFighters: abandonedFighters) { Int.random(in: 0..<$0) }
        return (line, 0)
    }

    /// "Launching from X on <date>." (#55-60). Mirrors `GameContainerView.postLaunchLine`.
    static func launch(game: NovaGame, pilot: PlayerState, spobID: Int) -> String {
        let name = game.spob(spobID)?.displayName ?? ""
        return OriginalText(game: game).launch(stellar: name, player: pilot) { Int.random(in: 0..<$0) }
    }
}
