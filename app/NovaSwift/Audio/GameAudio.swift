import Foundation
import SwiftUI
import NovaSwiftKit

/// The game's audio facade. Owns the engine + sound library, applies user volume
/// settings, maps named game events to `snd ` resources, plays positional SFX,
/// and drives background music. One instance lives on `AppModel` and is shared by
/// the launcher (UI clicks, music, sound test) and the game scene (flight SFX).
///
/// Sounds follow the original's rules (`OriginalAudio`): every play carries the
/// call site's priority into a 16-voice list of which 8 are heard; positional
/// sounds use the 200 px / 850²/d² law with a 1/8 floor and play mono; a
/// same-sound guard (`NovaAudio_CountActiveByHandle`) stops wëap Flags 0x0010
/// weapons, Warp out and Klaxxon from stacking.
@MainActor
final class GameAudio: ObservableObject {
    private let engine = GameAudioEngine()
    private let library = NovaSoundLibrary()
    private var settings = GameSettings()
    private var musicURL: URL?
    private var screenAllowsMusic = false

    /// Fixed sounds not carried by weapon/outfit data, with the priority their
    /// original call sites pass and whether they are guarded against stacking.
    enum GameEvent {
        case hyperspaceCharge    // spinning up for a jump
        case hyperspaceArrive    // Warp out
        // The original's five interface beeps, snd 150-154, loaded as
        // g_nv_beep1 + DAT_00591564/68/6c/70 by NovaAudio_PreloadGameplayData
        // 0x004b0740 and played at priority 1 at every call site. By use:
        //   beep1 (150) confirm / dismiss: clear target or travel selection,
        //          pick a nav stellar, map close, escort panel open/close
        //   beep2 (151) notice / alarm: comm and news button presses, landing
        //          request and clearance, disabled / destroyed / mission failed,
        //          escort orders, self-destruct abort
        //   beep3 (152) select / back: target cycling, map open, link cycle,
        //          clear secondary, window close, plunder actions
        //   beep4 (153) denied: a command that cannot be done right now
        //   beep5 (154) incoming: a new message or window (hail open, escort
        //          repaired, fleet quote)
        case beep1, beep2, beep3, beep4, beep5
        case redAlert            // a ship starts threatening the player's squad
        case docking             // player set down on a spöb
        case launch              // player lifted off from a spöb

        /// Port-only screens (launcher, settings, plug-ins, debug) have no
        /// original counterpart and click with the first beep.
        static let uiSelect = GameEvent.beep1
        /// A port-only form rejecting input (new-pilot and import screens, the
        /// text prompt's length cap) keeps the snd 152 it always had.
        static let uiError = GameEvent.beep3

        /// The beep for snd `soundID` (150-154), nil for any other id.
        static func beep(soundID: Int) -> GameEvent? {
            [GameEvent.beep1, .beep2, .beep3, .beep4, .beep5].first { $0.soundID == soundID }
        }

        var soundID: Int {
            switch self {
            case .hyperspaceCharge:    return 128   // "Warp up"
            case .hyperspaceArrive:    return 130   // "Warp out"
            case .beep1:               return 150   // "Beep1"
            case .beep2:               return 151   // "Beep2"
            case .beep3:               return 152   // "Beep3"
            case .beep4:               return 153   // "Beep4"
            case .beep5:               return 154   // "Beep5"
            case .redAlert:            return 370   // "Red Alert"
            case .docking, .launch:    return 390   // "Airlock"
            }
        }

        var priority: Int {
            let P = OriginalAudio.Priority.self
            switch self {
            case .hyperspaceCharge:    return P.warpUp
            case .hyperspaceArrive:    return P.warpOut
            case .beep1, .beep2, .beep3, .beep4, .beep5: return P.beep
            case .redAlert:            return P.redAlert
            case .docking, .launch:    return P.airlock
            }
        }

        /// Played only when no voice is already playing it (0x0044f3d0:85 for
        /// Warp out, :1707 for Klaxxon).
        var playsOnlyWhenSilent: Bool {
            self == .hyperspaceArrive
        }
    }

    // MARK: Setup

    /// Point the library at freshly-loaded game data and start the engine.
    func attach(game: NovaGame?) {
        library.attach(game: game)
        weaponSoundRules.removeAll()
        engine.start()
        applyVolumes()
    }

    /// The title music file (`GameDataController.musicTrackURL`, STR# 130 #2).
    func setMusic(url: URL?) { musicURL = url }

    /// Re-read volumes/toggles after the user changes settings.
    func apply(settings: GameSettings) {
        self.settings = settings
        applyVolumes()
        updateMusicState(restart: false)
    }

    private func applyVolumes() {
        // The sound preference (0...8) drives the effects level exactly as
        // NovaAudio_UpdateCenteredGainFromPreference 0x0046ab60 does:
        // min(256, step * 8), here relative to the step-8 maximum (64).
        let level = Float(OriginalAudio.masterVolume(preference: settings.soundVolumeStep)) / 64
        let master = settings.muteAll ? 0 : Float(settings.masterVolume) * min(1, level)
        engine.masterVolume = master
        engine.sfxVolume = Float(settings.sfxVolume)
        // Music level is the original's preference-derived movie volume
        // (`musicGains`), applied on the player node.
        engine.musicVolume = 1
    }

    // MARK: Music

    /// The music slider as the original's 0…8 sound preference.
    private var musicPreference: Int { max(0, min(8, settings.soundVolumeStep)) }

    /// `pref × 0x30` at start, `pref × 0x20` while playing (QuickTime 0…256).
    private var musicGains: (start: Float, playing: Float) {
        let p = musicPreference
        return (Float(OriginalAudio.musicStartVolume(preference: p)) / 256,
                Float(OriginalAudio.musicPlayingVolume(preference: p)) / 256)
    }

    /// Start (or keep) music according to the current settings.
    func startMusicIfEnabled() { updateMusicState(restart: false) }

    /// The authentic EV Nova main menu is the only screen music plays over.
    /// Entering it starts the track from the top (0x004ab5d0 runs on every
    /// main-menu entry); leaving it fades it out (0x004ab820).
    func setMusicAllowed(_ allowed: Bool) {
        let entering = allowed && !screenAllowsMusic
        let leaving = !allowed && screenAllowsMusic
        screenAllowsMusic = allowed
        if leaving { engine.fadeOutMusic(); return }
        if entering { musicPlayedThisVisit = false }
        updateMusicState(restart: entering)
    }

    private var musicEnabled: Bool {
        // "Intro Music" off: the title music never starts (0x004ab5d0).
        settings.musicEnabled && settings.introMusic && !settings.muteAll && settings.musicVolume > 0
    }

    private func updateMusicState(restart: Bool) {
        guard screenAllowsMusic, musicEnabled, let url = musicURL else {
            if musicURL == nil { Log.audio.debug("updateMusicState: no title music (STR# 130 #2 not found)") }
            engine.stopMusic(); return
        }
        let gains = musicGains
        if restart || (!engine.isMusicPlaying && !musicPlayedThisVisit) {
            musicPlayedThisVisit = true
            engine.startMusic(url: url, startGain: gains.start, playingGain: gains.playing)
        } else {
            engine.setMusicGain(gains.playing)
        }
    }

    /// The track plays once per main-menu visit; a settings change must not
    /// replay a track that already ended. Reset on each main-menu entry.
    private var musicPlayedThisVisit = false

    func stopMusic() { engine.stopMusic() }

    /// Stop every looping SFX voice (spaceport ambient, the quick-jump charge)
    /// and every one-shot voice. Called when leaving the game.
    func stopAllLoops() {
        engine.stopAllLoops()
        engine.stop(soundID: 0)
    }

    /// Freeze/thaw the sustained game audio (music + looping SFX) while an in-flight
    /// overlay menu is open. Resumes exactly where it left off.
    func setPaused(_ paused: Bool) { engine.setSustainedAudioPaused(paused) }

    // MARK: SFX

    /// Play a fixed engine/UI event at its original priority. Interface beeps
    /// also follow the interface-volume slider.
    func play(_ event: GameEvent) {
        if event.playsOnlyWhenSilent, engine.isPlaying(soundID: event.soundID) { return }
        switch event {
        case .beep1, .beep2, .beep3, .beep4, .beep5:
            playSound(event.soundID, priority: event.priority, gainScale: Float(settings.uiVolume))
        default:
            playSound(event.soundID, priority: event.priority)
        }
    }

    /// `nv_PlaySound`: play a `snd ` id centred at full volume.
    func playSound(_ id: Int, priority: Int = OriginalAudio.Priority.beep, gainScale: Float = 1) {
        guard !settings.muteAll else { return }
        guard let buffer = library.buffer(for: id) else {
            Log.audio.debug("playSound(\(id, privacy: .public)): no buffer (missing snd or undecodable)")
            return
        }
        engine.play(buffer, soundID: id, priority: priority,
                    volume: OriginalAudio.unityVolume, gainScale: gainScale)
    }

    /// Play an escort chatter line unpositioned and report its length in
    /// seconds (0 if it can't play), so the world can hold the next line until
    /// this one ends (`DAT_00591a8c`).
    func playChatter(_ id: Int) -> Double {
        guard !settings.muteAll, let buffer = library.buffer(for: id) else { return 0 }
        engine.play(buffer, soundID: id, priority: OriginalAudio.Priority.klaxxon,
                    volume: OriginalAudio.unityVolume, gainScale: Float(settings.uiVolume))
        return Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
    }

    /// `NovaAudio_PlaySpatialByDistance`: play a `snd ` id at a world point
    /// heard from `listener` (the player). Mono; never quieter than 1/8.
    func play(_ id: Int, at source: CGPoint, listener: CGPoint,
              priority: Int = OriginalAudio.Priority.explosion) {
        guard !settings.muteAll, let buffer = library.buffer(for: id) else { return }
        let volume = OriginalAudio.spatialVolume(dx: Double(source.x - listener.x),
                                                 dy: Double(source.y - listener.y),
                                                 master: OriginalAudio.unityVolume)
        engine.play(buffer, soundID: id, priority: priority, volume: volume)
    }

    /// Whether any voice is playing `snd ` `id` (`NovaAudio_CountActiveByHandle`).
    func isPlaying(_ id: Int) -> Bool { engine.isPlaying(soundID: id) }

    /// `NovaAudio_UnregisterCallbacks`: stop every voice of `snd ` `id`.
    func stopSound(_ id: Int) { engine.stop(soundID: id) }

    // MARK: Weapons

    private struct WeaponSoundRule {
        var retriggerOnlyWhenDone: Bool   // wëap Flags 0x0010
        var playerPriority: Int
        var pointDefense: Bool            // guidance 9/10
        var carried: Bool                 // guidance 99 (fighter bay)
    }

    /// Per-weapon sound rule, read once from the wëap.
    private var weaponSoundRules: [Int: WeaponSoundRule] = [:]

    private func weaponRule(_ weaponID: Int) -> WeaponSoundRule {
        if let hit = weaponSoundRules[weaponID] { return hit }
        let w = library.loadedGame?.weapon(weaponID)
        let guidance = w?.guidanceRaw ?? -1
        let rule = WeaponSoundRule(
            retriggerOnlyWhenDone: w?.loopSound ?? false,
            playerPriority: OriginalAudio.Priority.playerWeapon(guidance: guidance, flags: Int(w?.flagsRaw ?? 0)),
            pointDefense: guidance == 9 || guidance == 10,
            carried: guidance == 99)
        weaponSoundRules[weaponID] = rule
        return rule
    }

    /// A weapon's fire sound, as the original's call sites play it:
    /// `Weapon_FireShipWeapons` (NPCs, priority 4, at the shooter),
    /// `Weapon_FirePlayerWeaponBank` (the player, 5/6, at full volume),
    /// point defense (`Weapon_SelectTurretTargetWithinArc`, 3, at the shooter)
    /// and an NPC bay launch (`Ship_LaunchShipFromCarrierBay`, 5). wëap Flags
    /// 0x0010 makes it play only when no voice anywhere is already playing
    /// that sound — every weapon kind, not just beams; a retrigger-when-done,
    /// not a loop (the bay launch ignores it).
    func playWeaponFire(soundID: Int, weaponID: Int, isPlayer: Bool, at source: CGPoint, listener: CGPoint) {
        let rule = weaponRule(weaponID)
        let P = OriginalAudio.Priority.self
        if !(rule.carried && !isPlayer), rule.retriggerOnlyWhenDone, engine.isPlaying(soundID: soundID) { return }
        if rule.pointDefense {
            play(soundID, at: source, listener: listener, priority: P.turret)
        } else if isPlayer {
            play(soundID, at: listener, listener: listener, priority: rule.playerPriority)
        } else if rule.carried {
            play(soundID, at: source, listener: listener, priority: P.carrierLaunch)
        } else {
            play(soundID, at: source, listener: listener, priority: P.npcWeapon)
        }
    }

    // MARK: Looping SFX (spaceport ambience, the quickHyperjump charge)

    /// Stop a loop started by `startAmbient`. No-op if not looping.
    func stopLoop(key: String) { engine.stopLoop(id: key) }

    /// Key for the landed-spaceport ambience loop (`SpobRes.ambientSoundID`).
    private static let ambientLoopKey = "spaceport-ambient"

    /// Start (or switch) the ambient loop for the spöb the player just landed
    /// on. No-op if that spöb has no `ambientSoundID` (`-1`/nil in the data).
    func startAmbient(soundID: Int?) {
        // "Ambient Sounds" off: the landed screen plays no spaceport loop (0x00491f30).
        guard settings.ambientSounds else { engine.stopLoop(id: Self.ambientLoopKey); return }
        guard !settings.muteAll, let soundID, soundID >= 0, let buffer = library.buffer(for: soundID) else {
            engine.stopLoop(id: Self.ambientLoopKey)
            return
        }
        engine.playLoop(id: Self.ambientLoopKey, buffer: buffer, volume: Float(settings.sfxVolume), pan: 0)
    }

    /// Stop the landed-spaceport ambience — called on takeoff.
    func stopAmbient() { engine.stopLoop(id: Self.ambientLoopKey) }

    /// The `quickHyperjump` enhancement's charge-up loop, cut when its jump commits.
    private static let hyperspaceChargeLoopKey = "hyperspace-charge"

    func startHyperspaceCharge() {
        guard !settings.muteAll, let buffer = library.buffer(for: GameEvent.hyperspaceCharge.soundID) else { return }
        engine.playLoop(id: Self.hyperspaceChargeLoopKey, buffer: buffer, volume: Float(settings.sfxVolume), pan: 0)
    }

    func stopHyperspaceCharge() { engine.stopLoop(id: Self.hyperspaceChargeLoopKey) }

    // MARK: The original jump cue

    /// snd 129, the "Warp up" cue the original plays instead of snd 128 while its
    /// Caps Lock 2x flag is on (`PlayerTick_ManualFlightAndRegeneration`
    /// 0x0044c8d0 / `Stellar_GetJumpSequenceDuration60Hz` 0x0046efb0).
    static let warpUp2xSoundID = 129

    /// The pre-staged Warp up voice (0x004b0740 / 0x0046ab00): snd 128 played
    /// once, `multiplier` times faster (voice rate `65536 / multiplier`… the
    /// descriptor's step), at priority 32000, and only when no Warp up voice
    /// is sounding. With `x2` (the Caps Lock flag) it is snd 129 instead, at the
    /// same rate; if the data has no snd 129 the normal cue plays. Every other
    /// game speed keeps snd 128: the jump's cue and tunnel ramp run on the wall
    /// clock at any speed (`PlayerHyperjump.elapsed60`), so the cue plays as is.
    func startWarpUp(multiplier: Double, x2: Bool = false) {
        let normal = GameEvent.hyperspaceCharge.soundID
        guard !settings.muteAll,
              !engine.isPlaying(soundID: normal), !engine.isPlaying(soundID: Self.warpUp2xSoundID)
        else { return }
        var id = normal
        var buffer = library.buffer(for: normal, rate: multiplier)
        if x2, let x2Buffer = library.buffer(for: Self.warpUp2xSoundID, rate: multiplier) {
            id = Self.warpUp2xSoundID
            buffer = x2Buffer
        }
        guard let buffer else { return }
        engine.play(buffer, soundID: id, priority: OriginalAudio.Priority.warpUp,
                    volume: OriginalAudio.unityVolume)
    }

    /// The cut at `350 / multiplier` ticks (0x0044f3d0:368-381).
    func stopWarpUp() {
        engine.stop(soundID: GameEvent.hyperspaceCharge.soundID)
        engine.stop(soundID: Self.warpUp2xSoundID)
    }

    // MARK: Main menu

    /// `FUN_0048bc20`: a main-menu command plays snd 600, waits for it to end,
    /// plays snd 601, then acts.
    func playMenuTransition(then action: @escaping @MainActor () -> Void) {
        playSound(600, priority: OriginalAudio.Priority.menuTransition)
        func waitThenAct() {
            if engine.isPlaying(soundID: 600) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { waitThenAct() }
                return
            }
            playSound(601, priority: OriginalAudio.Priority.menuTransition)
            action()
        }
        waitThenAct()
    }

    /// Mouse tracking on a main-menu button (`FUN_004861b0`): snd 600 as the
    /// press lands on a button, snd 601 as it leaves every button or is
    /// released on one.
    func playMenuButton(down: Bool) {
        playSound(down ? 600 : 601, priority: OriginalAudio.Priority.menuTransition)
    }

    /// A menu shutter strip starts (snd 602) or lands (snd 603) (`FUN_0048bfb0`).
    func playMenuSlide(landed: Bool) {
        playSound(landed ? 603 : 602, priority: OriginalAudio.Priority.warpOut)
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
