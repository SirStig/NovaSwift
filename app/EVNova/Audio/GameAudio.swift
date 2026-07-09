import Foundation
import SwiftUI
import EVNovaKit

/// The game's audio facade. Owns the engine + sound library, applies user volume
/// settings, maps named game events to `snd ` resources, plays positional SFX,
/// and drives background music. One instance lives on `AppModel` and is shared by
/// the launcher (UI clicks, music, sound test) and the game scene (flight SFX).
///
/// Combat / AI systems trigger sound by calling `play(_:at:listener:)` with an
/// explicit `snd ` id (a weapon's or explosion's own sound); `GameEvent` covers
/// the fixed engine/UI sounds that aren't data-driven.
@MainActor
final class GameAudio: ObservableObject {
    private let engine = GameAudioEngine()
    private let library = NovaSoundLibrary()
    private var settings = GameSettings()
    private var musicURL: URL?

    /// Fixed sounds not carried by weapon/outfit data. The default ids are real
    /// EV Nova base resources (verified present in the shipping data); a plug-in
    /// that lacks one simply produces no sound.
    enum GameEvent {
        case hyperspaceCharge    // spinning up for a jump
        case hyperspaceArrive    // popping out into a new system
        case uiSelect            // menu/button click
        case uiError             // rejected action
        case targetLock          // acquired a target
        case lowShieldWarning    // shields/hull crossed below a safe threshold
        case criticalHullWarning // hull critically low
        case docking             // player set down on a spöb
        case launch              // player lifted off from a spöb

        var soundID: Int {
            switch self {
            case .hyperspaceCharge:    return 128   // "Warp up"
            case .hyperspaceArrive:    return 130   // "Warp out"
            case .uiSelect:            return 150   // "Beep1"
            case .uiError:             return 152   // "Beep3"
            case .targetLock:          return 151   // "Beep2"
            case .lowShieldWarning:    return 371   // "Klaxxon"
            case .criticalHullWarning: return 370   // "Red Alert"
            case .docking, .launch:    return 390   // "Airlock"
            }
        }
    }

    // MARK: Setup

    /// Point the library at freshly-loaded game data and start the engine.
    func attach(game: NovaGame?) {
        library.attach(game: game)
        engine.start()
        applyVolumes()
    }

    /// Locate a background music track shipped alongside the base data, if any.
    func setMusic(url: URL?) { musicURL = url }

    /// Re-read volumes/toggles after the user changes settings.
    func apply(settings: GameSettings) {
        self.settings = settings
        applyVolumes()
        updateMusicState()
    }

    private func applyVolumes() {
        let master = settings.muteAll ? 0 : Float(settings.masterVolume)
        engine.masterVolume = master
        engine.sfxVolume = Float(settings.sfxVolume)
        engine.musicVolume = Float(settings.musicVolume)
    }

    // MARK: Music

    /// Start (or keep) music according to the current settings.
    func startMusicIfEnabled() { updateMusicState() }

    private func updateMusicState() {
        guard let url = musicURL else {
            Log.audio.debug("updateMusicState: no music track found (musicTrackURL() returned nil)")
            engine.stopMusic(); return
        }
        guard settings.musicEnabled, !settings.muteAll, settings.musicVolume > 0 else {
            Log.audio.debug("updateMusicState: music suppressed by settings (enabled=\(self.settings.musicEnabled, privacy: .public) muteAll=\(self.settings.muteAll, privacy: .public) volume=\(self.settings.musicVolume, privacy: .public))")
            engine.stopMusic(); return
        }
        engine.startMusic(url: url)
    }

    func stopMusic() { engine.stopMusic() }

    // MARK: SFX

    /// Play a fixed engine/UI event. Interface beeps use the interface-volume
    /// slider; world events use the effects volume.
    func play(_ event: GameEvent) {
        switch event {
        case .uiSelect, .uiError:
            playSound(event.soundID, volume: Float(settings.uiVolume))
        default:
            playSound(event.soundID)
        }
    }

    /// Play a `snd ` id centred (no attenuation/pan). Combat/UI systems use this
    /// with a weapon's own sound id.
    func playSound(_ id: Int, volume: Float = 1) {
        guard !settings.muteAll else { return }
        guard let buffer = library.buffer(for: id) else {
            Log.audio.debug("playSound(\(id, privacy: .public)): no buffer (missing snd or undecodable)")
            return
        }
        engine.play(buffer, volume: volume)
    }

    /// Play a `snd ` id positioned in the world relative to the listener (the
    /// player ship / camera). Distance attenuates volume; horizontal offset pans.
    /// `range` is the world distance at which the sound fades to silence.
    func play(_ id: Int, at source: CGPoint, listener: CGPoint, range: CGFloat = 3000) {
        guard !settings.muteAll, let buffer = library.buffer(for: id) else { return }
        let dx = source.x - listener.x
        let dy = source.y - listener.y
        let dist = (dx * dx + dy * dy).squareRoot()
        let atten = Float(max(0, 1 - dist / max(1, range)))
        guard atten > 0.001 else { return }
        // Pan by horizontal offset, softened so far-left/right isn't fully mono-side.
        let pan = Float(max(-1, min(1, dx / max(1, range)))) * 0.85
        engine.play(buffer, volume: atten, pan: pan)
    }

    // MARK: Hailing

    /// Play a hailed government's voice line — the "Acknowledge" bank normally,
    /// "Target" if that government is hostile to the player — picking a random
    /// real variant. No-op for governments that can't be hailed or have nothing
    /// to say (`gövt.cantBeHailed` / `nonTalkative`).
    func playHailVoice(govt: GovtRes, hostile: Bool) {
        guard !govt.cantBeHailed, !govt.nonTalkative else { return }
        let base = 1000 + govt.voiceType * 100 + (hostile ? 10 : 0)
        let available = Set(availableSoundIDs())
        let variants = (0...9).map { base + $0 }.filter { available.contains($0) }
        guard let id = variants.randomElement() else { return }
        playSound(id, volume: Float(settings.uiVolume))
    }

    // MARK: Sound test (Settings)

    /// Ids available for the settings sound browser.
    func availableSoundIDs() -> [Int] { library.availableIDs() }
    func soundName(_ id: Int) -> String? { library.name(for: id) }

    /// Play a sound for the settings preview, honouring current volumes even if the
    /// engine wasn't started yet.
    func preview(_ id: Int) {
        engine.start()
        applyVolumes()
        playSound(id)
    }
}
