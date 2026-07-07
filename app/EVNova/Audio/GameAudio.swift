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

        var soundID: Int {
            switch self {
            case .hyperspaceCharge: return 128   // "Warp up"
            case .hyperspaceArrive: return 130   // "Warp out"
            case .uiSelect:         return 150   // "Beep1"
            case .uiError:          return 152   // "Beep3"
            case .targetLock:       return 151   // "Beep2"
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
        guard let url = musicURL, settings.musicEnabled, !settings.muteAll, settings.musicVolume > 0 else {
            engine.stopMusic(); return
        }
        engine.startMusic(url: url)
    }

    func stopMusic() { engine.stopMusic() }

    // MARK: SFX

    /// Play a fixed engine/UI event.
    func play(_ event: GameEvent) { playSound(event.soundID) }

    /// Play a `snd ` id centred (no attenuation/pan). Combat/UI systems use this
    /// with a weapon's own sound id.
    func playSound(_ id: Int, volume: Float = 1) {
        guard !settings.muteAll, let buffer = library.buffer(for: id) else { return }
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
