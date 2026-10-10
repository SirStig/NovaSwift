import Foundation
import AVFoundation
import NovaSwiftKit

/// The low-level audio graph. Three buses feed the main mixer:
///
///   sfx voices ─┐
///               ├─▶ sfxBus  ─┐
///   music ──────────▶ musicBus ─┴─▶ mainMixer ─▶ output
///
/// Master volume is the main mixer's output level; per-bus sliders live on the
/// SFX and music sub-mixers. One-shot SFX run through the original's voice list
/// (`OriginalAudio.VoiceList`, 0x004d6550): 16 virtual voices sorted by
/// priority and volume, of which only the first 8 are heard. Every virtual
/// voice owns a player node; nodes past slot 8 keep playing at zero volume, so
/// a sound becomes audible mid-sample when the voices ahead of it end, as in
/// the original mixer (0x004d6b90). Mono, no pan, no loop points.
final class GameAudioEngine {
    /// Canonical SFX format: everything is resampled to this so the voice pool is
    /// format-uniform. 22.05 kHz mono matches EV Nova's original mixing rate.
    static let canonicalRate: Double = 22050
    static let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: canonicalRate, channels: 1)!

    private let engine = AVAudioEngine()
    private let sfxBus = AVAudioMixerNode()
    private let musicBus = AVAudioMixerNode()

    private var voices: [AVAudioPlayerNode] = []
    /// A virtual voice: its node, when its sample ends, and its gain.
    struct VoiceRef { var node: Int; var endTime: TimeInterval; var gain: Float }
    private var voiceList = OriginalAudio.VoiceList<VoiceRef>()
    private var freeNodes: [Int] = []
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

    init(voiceCount: Int = OriginalAudio.slotCount) {
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
        freeNodes = Array(voices.indices.reversed())
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
        voiceList = OriginalAudio.VoiceList<VoiceRef>()
        freeNodes = Array(voices.indices.reversed())
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

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Drop the voices whose samples have ended (the mixer frees a voice at
    /// its sample end, 0x004d6b90).
    private func purgeFinished() {
        let t = Self.now()
        for gone in voiceList.remove(where: { $0.payload.endTime <= t }) where gone.payload.node >= 0 {
            freeNodes.append(gone.payload.node)
        }
    }

    /// Only the first 8 voices of the list are mixed; the rest run silently.
    private func relevel() {
        for (i, v) in voiceList.voices.enumerated() where v.payload.node >= 0 {
            let node = voices[v.payload.node]
            node.volume = OriginalAudio.VoiceList<VoiceRef>.isAudible(index: i) ? v.payload.gain : 0
            node.pan = 0
        }
    }

    /// Play a one-shot `snd` through the original's voice list.
    /// - Parameters:
    ///   - soundID: the `snd ` id (the handle `isPlaying`/`stop` match).
    ///   - priority: the call site's priority (`OriginalAudio.Priority`).
    ///   - volume: the voice volume, 128 = unity (`OriginalAudio.spatialVolume`).
    ///   - gainScale: an extra presentation gain (the interface-volume slider).
    /// - Returns: false when the list ranked it below all 16 voices (dropped).
    @discardableResult
    func play(_ buffer: AVAudioPCMBuffer, soundID: Int, priority: Int, volume: Int,
              gainScale: Float = 1) -> Bool {
        if !started { start() }
        guard started else { return false }
        purgeFinished()
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let clamped = min(max(volume, 0), OriginalAudio.unityVolume)
        let gain = Float(clamped) / Float(OriginalAudio.unityVolume) * gainScale
        let ref = VoiceRef(node: -1, endTime: Self.now() + duration, gain: gain)
        switch voiceList.insert(soundID: soundID, priority: priority, volume: volume, payload: ref) {
        case .dropped:
            return false
        case let .inserted(index, evicted):
            let node: Int
            if let evicted, evicted.payload.node >= 0 {
                node = evicted.payload.node
            } else if let free = freeNodes.popLast() {
                node = free
            } else {
                // Cannot happen (one node per virtual voice); never steal.
                voiceList.remove(where: { $0.payload.node < 0 })
                return false
            }
            var bound = ref
            bound.node = node
            voiceList.setPayload(at: index, bound)
            let voice = voices[node]
            voice.volume = 0
            // `.interrupts` replaces whatever the node still held (an evicted
            // or finished voice) without the blocking `stop()`.
            voice.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
            if !voice.isPlaying { voice.play() }
            relevel()
            return true
        }
    }

    /// `NovaAudio_CountActiveByHandle` (0x004d6770): voices of `soundID`
    /// still sounding (0 = every voice).
    func activeCount(soundID: Int) -> Int {
        purgeFinished()
        return voiceList.count(soundID: soundID)
    }

    func isPlaying(soundID: Int) -> Bool { activeCount(soundID: soundID) > 0 }

    /// `NovaAudio_UnregisterCallbacks` (0x004d67d0): stop every voice of
    /// `soundID` (0 = all). The node is muted and freed; its next sound
    /// replaces the buffer.
    func stop(soundID: Int) {
        let gone = voiceList.remove(where: { soundID == 0 || $0.soundID == soundID })
        for v in gone where v.payload.node >= 0 {
            voices[v.payload.node].volume = 0
            freeNodes.append(v.payload.node)
        }
        relevel()
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

    /// Silence every looping SFX voice (beam weapons, spaceport ambient) without
    /// tearing down the engine or music. Used when leaving the game (death / menu
    /// return) so no loop bleeds into the main menu — nothing else clears looping
    /// SFX on that transition. Idempotent; safe before the engine has started.
    func stopAllLoops() {
        for (_, voice) in loopVoices { voice.stop(); loopPool.append(voice) }
        loopVoices.removeAll()
    }

    // MARK: Music playback (streamed from a file, played once)

    /// Bumped on every start/stop so a stale volume step or fade from an
    /// earlier track never touches the current one.
    private var musicGeneration = 0

    /// Start the title music the way `FUN_004ab5d0` does: from the top, at
    /// `startGain`; the 40-tick music task (0x004ab8d0) then re-levels it to
    /// `playingGain` while the movie runs. The track plays **once** — when it
    /// is done the task disposes of it, nothing rewinds it.
    func startMusic(url: URL, startGain: Float, playingGain: Float) {
        if !started { start() }
        guard started else {
            Log.audio.error("startMusic: engine not started, cannot play \(url.lastPathComponent, privacy: .public)")
            return
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            Log.audio.error("startMusic: cannot open \(url.path, privacy: .public): \(error, privacy: .public)")
            return
        }
        musicGeneration += 1
        let generation = musicGeneration
        musicURL = url
        musicPlayer.stop()
        engine.disconnectNodeOutput(musicPlayer)
        engine.connect(musicPlayer, to: musicBus, format: file.processingFormat)
        musicPlayer.volume = startGain
        musicPlayer.scheduleFile(file, at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.musicGeneration == generation else { return }
                self.musicURL = nil
            }
        }
        musicPlayer.play()
        let service = Double(OriginalAudio.musicServiceTicks) / 60
        DispatchQueue.main.asyncAfter(deadline: .now() + service) { [weak self] in
            guard let self, self.musicGeneration == generation, self.musicPlayer.isPlaying else { return }
            self.musicPlayer.volume = playingGain
        }
        Log.audio.debug("startMusic: playing \(url.lastPathComponent, privacy: .public) once at \(startGain, privacy: .public)")
    }

    /// Re-level a playing track (a settings change).
    func setMusicGain(_ gain: Float) {
        guard musicURL != nil else { return }
        musicPlayer.volume = gain
    }

    /// `FUN_004ab820(fade)`: step the volume down by 8/256 per 60 Hz tick
    /// from its current level, then stop.
    func fadeOutMusic() {
        guard musicURL != nil, musicPlayer.isPlaying else { stopMusic(); return }
        musicGeneration += 1
        let generation = musicGeneration
        let step: Float = 8.0 / 256.0
        func tick() {
            guard musicGeneration == generation else { return }
            let next = musicPlayer.volume - step
            if next <= 0 { stopMusic(); return }
            musicPlayer.volume = next
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { tick() }
        }
        tick()
    }

    func stopMusic() {
        musicGeneration += 1
        musicURL = nil
        musicPlayer.stop()
    }

    var isMusicPlaying: Bool { musicURL != nil && musicPlayer.isPlaying }
}
