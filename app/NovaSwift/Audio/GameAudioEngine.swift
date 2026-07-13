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

    /// Persistent looping voices, keyed by caller-chosen id (e.g. one per
    /// firing ship+mount), separate from the one-shot round-robin pool above —
    /// these live until explicitly stopped rather than being subject to
    /// stealing by unrelated one-shot SFX.
    private var loopVoices: [String: AVAudioPlayerNode] = [:]
    /// Free, pre-attached loop voices. Attaching/detaching a node to a *running*
    /// `AVAudioEngine` reconfigures the whole graph (an audible hitch) — so loop
    /// voices are attached once up front and recycled through this pool rather
    /// than attached per beam-start and detached per beam-stop.
    private var loopPool: [AVAudioPlayerNode] = []

    private var started = false
    private var musicURL: URL?
    /// Whether the music track was playing when the last menu pause froze it, so
    /// resume only restarts music that was actually going.
    private var musicWasPlayingBeforePause = false

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
        // A pool of loop voices, attached once here so beam-start/stop never
        // reconfigures the running graph.
        for _ in 0..<8 {
            let v = AVAudioPlayerNode()
            engine.attach(v)
            engine.connect(v, to: sfxBus, format: Self.canonicalFormat)
            loopPool.append(v)
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
        do {
            try engine.start()
            started = true
            Log.audio.debug("engine started: outputVolume=\(self.engine.mainMixerNode.outputVolume, privacy: .public) isRunning=\(self.engine.isRunning, privacy: .public)")
        }
        catch {
            Log.audio.error("engine failed to start: \(error, privacy: .public)")
        }
    }

    func stop() {
        guard started else { return }
        musicPlayer.stop()
        voices.forEach { $0.stop() }
        // Loop voices are pool-managed (attached once, never detached); just stop
        // them and return them to the free pool.
        for (_, voice) in loopVoices { voice.stop(); loopPool.append(voice) }
        loopVoices.removeAll()
        engine.stop()
        started = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    /// Freeze the sustained game audio in place — the music track and every active
    /// looping SFX voice (beam weapons, etc.) — while an in-flight menu is open, then
    /// resume it exactly where it left off. One-shot voices are deliberately left
    /// running so the menu's own UI beeps still sound while paused. Idempotent, and a
    /// no-op before the engine has started.
    func setSustainedAudioPaused(_ paused: Bool) {
        guard started else { return }
        if paused {
            if musicPlayer.isPlaying {
                musicPlayer.pause()
                musicWasPlayingBeforePause = true
            }
            for (_, voice) in loopVoices where voice.isPlaying { voice.pause() }
        } else {
            if musicWasPlayingBeforePause {
                musicPlayer.play()
                musicWasPlayingBeforePause = false
            }
            for (_, voice) in loopVoices { voice.play() }
        }
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
        // Prefer a voice that's actually free over blindly stealing the next
        // one in rotation — with more concurrent SFX than the pool size (easy
        // to hit in a multi-ship fight), blind round-robin truncates whatever
        // still-audible sound happens to be on the next slot, which is exactly
        // what reads as "sounds keep cutting off." Only steal (oldest-first)
        // when every voice is genuinely busy.
        var chosen = nextVoice
        for offset in 0..<voices.count {
            let idx = (nextVoice + offset) % voices.count
            if !voices[idx].isPlaying { chosen = idx; break }
        }
        nextVoice = (chosen + 1) % voices.count
        let voice = voices[chosen]
        voice.volume = max(0, min(1, volume))
        voice.pan = max(-1, min(1, pan))
        // Do NOT call `voice.stop()` here. `AVAudioPlayerNode.stop()` blocks the
        // calling (render-loop) thread until the audio render cycle acknowledges
        // — a multi-millisecond stall on EVERY shot, which is exactly the hitch
        // felt each time a weapon fires. The `.interrupts` option already stops
        // whatever this voice was playing and starts the new buffer; the node
        // stays "playing" after its first `play()`, so no per-shot stop/start.
        voice.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
        if !voice.isPlaying { voice.play() }
    }

    // MARK: Looping SFX (continuous-fire weapons, etc.)

    /// Start (or, if already looping under this `id`, just re-level) a real
    /// gapless loop of `buffer` on a dedicated voice. Use for `loopSound`
    /// weapons instead of retriggering `play()` every reload tick — retriggering
    /// restarts the sample from frame 0 each time and can steal a voice from an
    /// unrelated in-flight sound.
    func playLoop(id: String, buffer: AVAudioPCMBuffer, volume: Float = 1, pan: Float = 0) {
        if !started { start() }
        guard started else { return }
        if let existing = loopVoices[id] {
            existing.volume = max(0, min(1, volume))
            existing.pan = max(-1, min(1, pan))
            return
        }
        // Recycle a pre-attached loop voice (no graph reconfiguration). If the
        // pool is momentarily exhausted, skip rather than attach on the fly.
        guard let voice = loopPool.popLast() else { return }
        voice.volume = max(0, min(1, volume))
        voice.pan = max(-1, min(1, pan))
        voice.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        voice.play()
        loopVoices[id] = voice
    }

    /// Re-level an already-playing loop (distance attenuation/pan as the
    /// shooter or listener moves). No-op if `id` isn't currently looping.
    func updateLoop(id: String, volume: Float, pan: Float) {
        guard let voice = loopVoices[id] else { return }
        voice.volume = max(0, min(1, volume))
        voice.pan = max(-1, min(1, pan))
    }

    /// Stop a loop started by `playLoop` and return its voice to the pool (no
    /// detach → no graph reconfiguration).
    func stopLoop(id: String) {
        guard let voice = loopVoices.removeValue(forKey: id) else { return }
        voice.stop()
        loopPool.append(voice)
    }

    // MARK: Music playback (streamed from a file, seamless loop)

    /// Begin looping a music file. Safe to call repeatedly with the same URL (no-op
    /// if already playing that track).
    func startMusic(url: URL) {
        if !started { start() }
        guard started else {
            Log.audio.error("startMusic: engine not started, cannot play \(url.lastPathComponent, privacy: .public)")
            return
        }
        if musicURL == url && musicPlayer.isPlaying {
            Log.audio.debug("startMusic: already playing \(url.lastPathComponent, privacy: .public)")
            return
        }
        musicURL = url
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            Log.audio.error("startMusic: cannot open \(url.path, privacy: .public): \(error, privacy: .public)")
            return
        }
        musicPlayer.stop()
        engine.disconnectNodeOutput(musicPlayer)
        engine.connect(musicPlayer, to: musicBus, format: file.processingFormat)
        scheduleMusicLoop(file)
        musicPlayer.play()
        Log.audio.debug("startMusic: playing \(url.lastPathComponent, privacy: .public) busVolume=\(self.musicBus.outputVolume, privacy: .public) isPlaying=\(self.musicPlayer.isPlaying, privacy: .public)")
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
