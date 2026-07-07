import Foundation
import AVFoundation

/// The low-level audio graph. Three buses feed the main mixer:
///
///   sfx voices ─┐
///               ├─▶ sfxBus  ─┐
///   music ──────────▶ musicBus ─┴─▶ mainMixer ─▶ output
///
/// Master volume is the main mixer's output level; per-bus sliders live on the
/// SFX and music sub-mixers. SFX play through a small pool of player nodes
/// (polyphony) that all share one canonical format so any decoded buffer can play
/// on any voice. Higher-level policy (which sound for which event, positional
/// panning, settings) lives in `GameAudio`.
final class GameAudioEngine {
    /// Canonical SFX format: everything is resampled to this so the voice pool is
    /// format-uniform. 22.05 kHz mono matches EV Nova's original mixing rate.
    static let canonicalRate: Double = 22050
    static let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: canonicalRate, channels: 1)!

    private let engine = AVAudioEngine()
    private let sfxBus = AVAudioMixerNode()
    private let musicBus = AVAudioMixerNode()

    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private let musicPlayer = AVAudioPlayerNode()

    private var started = false
    private var musicURL: URL?

    init(voiceCount: Int = 16) {
        engine.attach(sfxBus)
        engine.attach(musicBus)
        engine.connect(sfxBus, to: engine.mainMixerNode, format: Self.canonicalFormat)
        engine.connect(musicBus, to: engine.mainMixerNode, format: nil)

        for _ in 0..<voiceCount {
            let v = AVAudioPlayerNode()
            engine.attach(v)
            engine.connect(v, to: sfxBus, format: Self.canonicalFormat)
            voices.append(v)
        }
        engine.attach(musicPlayer)
        // Music is (re)connected with the file's own format when a track starts.
    }

    // MARK: Lifecycle

    /// Start the engine (idempotent). Configures the iOS audio session for game
    /// playback that mixes politely and honours the ring/silent switch appropriately.
    func start() {
        guard !started else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
        engine.prepare()
        do { try engine.start(); started = true }
        catch { NSLog("EVNova audio: engine failed to start: \(error)") }
    }

    func stop() {
        guard started else { return }
        musicPlayer.stop()
        voices.forEach { $0.stop() }
        engine.stop()
        started = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    // MARK: Volume (0…1)

    var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }
    var sfxVolume: Float {
        get { sfxBus.outputVolume }
        set { sfxBus.outputVolume = newValue }
    }
    var musicVolume: Float {
        get { musicBus.outputVolume }
        set { musicBus.outputVolume = newValue }
    }

    // MARK: SFX playback

    /// Play a one-shot buffer through the next voice in the pool.
    /// - Parameters:
    ///   - volume: 0…1 gain for this instance (e.g. distance attenuation).
    ///   - pan: -1 (left) … 1 (right).
    func play(_ buffer: AVAudioPCMBuffer, volume: Float = 1, pan: Float = 0) {
        if !started { start() }
        guard started else { return }
        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        voice.stop()                 // reuse this voice, interrupting whatever it played
        voice.volume = max(0, min(1, volume))
        voice.pan = max(-1, min(1, pan))
        voice.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
        voice.play()
    }

    // MARK: Music playback (streamed from a file, seamless loop)

    /// Begin looping a music file. Safe to call repeatedly with the same URL (no-op
    /// if already playing that track).
    func startMusic(url: URL) {
        if !started { start() }
        guard started else { return }
        if musicURL == url && musicPlayer.isPlaying { return }
        musicURL = url
        guard let file = try? AVAudioFile(forReading: url) else {
            NSLog("EVNova audio: cannot open music \(url.lastPathComponent)"); return
        }
        musicPlayer.stop()
        engine.disconnectNodeOutput(musicPlayer)
        engine.connect(musicPlayer, to: musicBus, format: file.processingFormat)
        scheduleMusicLoop(file)
        musicPlayer.play()
    }

    func stopMusic() {
        musicURL = nil
        musicPlayer.stop()
    }

    var isMusicPlaying: Bool { musicPlayer.isPlaying }

    /// Schedule the file and re-schedule on completion for a gapless loop.
    private func scheduleMusicLoop(_ file: AVAudioFile) {
        musicPlayer.scheduleFile(file, at: nil) { [weak self] in
            guard let self, self.musicURL == file.url else { return }
            // Rewind and loop. scheduleFile reads from the current frame position,
            // so reset it before re-scheduling.
            file.framePosition = 0
            self.scheduleMusicLoop(file)
        }
    }
}
