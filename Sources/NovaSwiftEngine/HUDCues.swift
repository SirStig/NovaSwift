import Foundation

/// The threat "Red Alert" cue (snd 370) and its low-volume blink.
///
/// `Ship_HandlePlayerShipCore` 0x0044aa70 (the same block in 0x0044d371):
/// every 60th spaceflight-loop frame (the raw ~47.6 Hz call, FL-01) it reads
/// `Ship_IsAnyShipThreatToPlayerSquad` 0x00410060; on the rising edge (no
/// threat at the last check, one now), unless the escape pod is running,
/// it plays snd 370 at priority 5 and — when the sound-volume pref is below
/// 2 — sets a 30-step blink counter that `FUN_0042cc30` shows as cicn
/// 18000/18001 (toggling by parity, one step every 5th frame).
public struct RedAlertCue: Sendable {
    /// The spaceflight frame counter `DAT_00597992`.
    public private(set) var frame = 0
    private var threatAtLastCheck = false
    /// The blink counter `DAT_00734c18`; the indicator shows while > 0.
    public private(set) var blink = 0

    public init() {}

    /// Advance `rawCalls` spaceflight frames. Returns true when snd 370
    /// should play.
    public mutating func advance(rawCalls: Int, lowVolume: Bool, inEscapePod: Bool,
                                 threat: () -> Bool) -> Bool {
        var play = false
        for _ in 0..<max(0, rawCalls) {
            if frame % 60 == 0 {
                let previous = threatAtLastCheck
                threatAtLastCheck = threat()
                if threatAtLastCheck, !previous, !inEscapePod {
                    play = true
                    if lowVolume { blink = 30 }
                }
            }
            if blink > 0, frame % 5 == 0 { blink -= 1 }
            frame = frame >= 0x7FFF ? 0 : frame + 1
        }
        return play
    }

    /// Which blink frame shows (cicn 18000 + this), or nil when hidden.
    public var blinkFrame: Int? { blink > 0 ? blink & 1 : nil }
}

extension World {
    /// Whether the player's death timer is running — the window in which the
    /// original keeps snd 371 "Klaxxon" playing (0x0044b120 and the other
    /// player handlers re-start it whenever it isn't already sounding).
    public var isPlayerDeathTimerRunning: Bool {
        playerDeathReportedForEject && !playerDeathSequenceOver && !playerDeathEjected
    }
}
