// Plain-Swift state for the bridge's sound section (`// MARK: Audio` in
// NovaWorld.swift); same split as Navigation.swift — `@Godot` registers only what
// is declared in the class body, so the callables live in NovaWorld and this is
// just the data they share.
//
// No game logic here: which sound an event makes, its priority/position/guard
// rules and the 16-voice arbitration are the shared `SoundCues` /
// `SoundVoiceBoard` (NovaSwiftEngine) the Apple app's rules come from, and the
// alarm edge detection is the shared `RedAlertCue`.

import Foundation
import NovaSwiftEngine

struct SoundState {
    /// The original's 16-voice list; GDScript owns 16 players and applies its commands.
    let board = SoundVoiceBoard()
    /// Cues raised since the last drain (events, the jump, docking, UI beeps).
    var pending: [SoundCue] = []
    /// Sample length in seconds per `snd ` id; 0 = missing / undecodable.
    var durations: [Int: Double] = [:]
    /// The escort chatter line just queued, and when its sound ends
    /// (`World.combatChatterPlaying` stays set until then).
    var chatterSoundID: Int?
    var chatterEnd: TimeInterval?
    var redAlert = RedAlertCue()
    var rawCallAccumulator = 0.0
    var klaxxonOn = false
    var warpUpStarted = false
    var warpUpCut = false

    /// A new world was built: drop stale cues and per-world alarm state.
    mutating func resetForNewWorld() {
        pending.removeAll(keepingCapacity: true)
        chatterSoundID = nil
        chatterEnd = nil
        redAlert = RedAlertCue()
        rawCallAccumulator = 0
        klaxxonOn = false
        warpUpStarted = false
        warpUpCut = false
    }
}
