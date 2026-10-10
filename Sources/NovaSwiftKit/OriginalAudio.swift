import Foundation

/// The original's sound rules, kept free of any audio API so they can be
/// pinned by tests. The app's mixer (`GameAudioEngine`) runs on these.
public enum OriginalAudio {
    /// A voice's unity volume: the mixer scales samples by `vol >> 7`
    /// (0x00507f90), and `Audio_AllocateVoiceSlot` clamps every channel to it.
    public static let unityVolume = 128
    /// Virtual voice slots (0x004d6550) and how many of them are mixed
    /// (`NovaAudio_Initialize(8, 0)` from 0x00416100).
    public static let slotCount = 16
    public static let audibleVoices = 8

    // MARK: Volume

    /// `NovaAudio_UpdateCenteredGainFromPreference` (0x0046ab60): the global
    /// effects volume is the sound preference × 8, clamped to 0…256.
    public static func masterVolume(preference: Int) -> Int { max(0, min(256, preference * 8)) }

    /// `NovaAudio_PlaySpatialByDistance` (0x004692e0) followed by
    /// `nv_PlaySound` (0x0046aad0): the mono volume of a sound at offset
    /// (`dx`, `dy`) px from the player, for master volume `v`.
    ///
    /// Within 200 px (d² ≤ 40000) it plays at `v`. Beyond, each channel is
    /// `v·850²/d²`, except that the far side of a source more than 200 px off
    /// to one side gets `v·200²/d²`. Each channel is clamped to
    /// `[max(1, v/8), v]` and the two are averaged — so there is no pan and no
    /// distance cut-off: a sound anywhere in the system plays at ≥ v/8.
    public static func spatialVolume(dx: Double, dy: Double, master v: Int) -> Int {
        var left = v, right = v
        if v > 0 {
            let ix = Int(dx.rounded(.towardZero)), iy = Int(dy.rounded(.towardZero))
            let d2 = ix * ix + iy * iy
            if d2 > 40000 {
                let far = v * 722_500 / d2, near = v * 40000 / d2
                if ix > 200 {
                    right = far; left = near
                } else if ix < -200 {
                    left = far; right = near
                } else {
                    left = far; right = far
                }
                let floor = max(1, v / 8)
                left = min(v, max(floor, left))
                right = min(v, max(floor, right))
            }
        }
        return monoVolume(left: left, right: right)
    }

    /// `nv_PlaySound`: the voice plays at the rounded average of both channels.
    public static func monoVolume(left: Int, right: Int) -> Int { (left + right + 1) >> 1 }

    // MARK: Priorities (call sites of nv_PlaySound / PlaySpatialByDistance)

    public enum Priority {
        /// NPC weapon fire, linked sub-shots (0x00414550, 0x00420d30).
        public static let npcWeapon = 4
        /// Turret fire picked by `Weapon_SelectTurretTargetWithinArc` (0x0043a310).
        public static let turret = 3
        /// Player weapon fire (0x00455150): 6 for beams (guidance 0/3), carried
        /// ships (99) and wëap Flags 0x0002 weapons, else 5.
        public static func playerWeapon(guidance: Int, flags: Int) -> Int {
            (guidance == 0 || guidance == 3 || guidance == 99 || flags & 0x0002 != 0) ? 6 : 5
        }
        /// An NPC launching a bay fighter (`Ship_LaunchShipFromCarrierBay` 0x0040d9a0).
        public static let carrierLaunch = 5
        /// bööm sounds (`Shot_SpawnAreaImpactEffects` 0x004211d0).
        public static let explosion = 6
        /// Interface beeps 150-154 (most call sites).
        public static let beep = 1
        /// snd 370 "Red Alert" (0x0044aa70:289).
        public static let redAlert = 5
        /// snd 371 "Klaxxon" and combat chatter (0x0044f3d0:1708).
        public static let klaxxon = 0xF
        /// snd 390 "Airlock" (boarding, 0x0045a3d0) and cloak 380/381.
        public static let airlock = 8
        /// snd 130 "Warp out", snd 372, menu slide 602/603.
        public static let warpOut = 0x32
        /// The pre-staged "Warp up" descriptor (0x004b0740).
        public static let warpUp = 32000
        /// Main-menu transitions 600/601 (0x0048bc20).
        public static let menuTransition = 10
    }

    // MARK: Voice list

    /// One virtual voice in the original's sorted list.
    public struct Voice<Payload> {
        public var soundID: Int
        public var priority: Int
        /// volL + volR (each clamped to 128); the mono mixer keeps L = R.
        public var volumeSum: Int
        public var payload: Payload
    }

    /// The 16-slot voice list of `Audio_AllocateVoiceSlot` (0x004d6550).
    /// Slots stay in insertion order; only the first `audibleVoices` are mixed,
    /// the rest advance silently and become audible as voices ahead of them end.
    public struct VoiceList<Payload> {
        public private(set) var voices: [Voice<Payload>] = []
        public init() {}

        public enum InsertResult {
            /// The list ranked the new sound below all 16 slots: not played.
            case dropped
            /// Inserted at `index`; `evicted` is the 16th voice pushed off the end.
            case inserted(index: Int, evicted: Voice<Payload>?)
        }

        /// Insert a sound: priority 0 counts as 1, each channel is clamped to
        /// 128, and the new voice skips every slot where its priority is lower
        /// **or** its volume sum is lower, landing at the first other slot.
        public mutating func insert(soundID: Int, priority: Int, volume: Int, payload: Payload) -> InsertResult {
            let prio = priority == 0 ? 1 : UInt16(truncatingIfNeeded: priority).toInt
            let ch = min(UInt16(truncatingIfNeeded: volume).toInt, OriginalAudio.unityVolume)
            let sum = ch + ch
            var idx = 0
            while idx < voices.count, idx < OriginalAudio.slotCount {
                let slot = voices[idx]
                if prio < slot.priority || sum < slot.volumeSum { idx += 1 } else { break }
            }
            guard idx < OriginalAudio.slotCount else { return .dropped }
            voices.insert(Voice(soundID: soundID, priority: prio, volumeSum: sum, payload: payload), at: idx)
            var evicted: Voice<Payload>?
            if voices.count > OriginalAudio.slotCount { evicted = voices.removeLast() }
            return .inserted(index: idx, evicted: evicted)
        }

        /// Replace the payload of the voice at `index` (e.g. bind its mixer node).
        public mutating func setPayload(at index: Int, _ payload: Payload) {
            guard voices.indices.contains(index) else { return }
            voices[index].payload = payload
        }

        /// `NovaAudio_CountActiveByHandle` (0x004d6770); 0 counts every voice.
        public func count(soundID: Int) -> Int {
            soundID == 0 ? voices.count : voices.filter { $0.soundID == soundID }.count
        }

        /// Remove the voices matching `predicate` (finished, or stopped by id).
        @discardableResult
        public mutating func remove(where predicate: (Voice<Payload>) -> Bool) -> [Voice<Payload>] {
            let gone = voices.filter(predicate)
            voices.removeAll(where: predicate)
            return gone
        }

        /// Whether the voice at `index` is mixed.
        public static func isAudible(index: Int) -> Bool { index < OriginalAudio.audibleVoices }
    }

    // MARK: Data ranges

    /// wëap `Sound` (0..255 → snd 200+n): the original plays it only when the
    /// field is ≥ 0 (0x00414550, 0x00455150).
    public static func weaponSoundID(raw: Int) -> Int? { (0..<256).contains(raw) ? raw + 200 : nil }
    /// bööm `SoundIndex` (0..63 → snd 300+n): played only when 0 ≤ s < 64 (0x004211d0).
    public static func boomSoundID(raw: Int) -> Int? { (0..<64).contains(raw) ? raw + 300 : nil }

    /// The variants of hail voice bank `base` (1000 + 100·voice + 10·bank, bank
    /// 0..2): the preload 0x004b0740 counts contiguous ids from `base` and stops
    /// at the first gap, at most 9.
    public static func voiceVariants(base: Int, exists: (Int) -> Bool) -> [Int] {
        var out: [Int] = []
        for n in 0..<9 {
            guard exists(base + n) else { break }
            out.append(base + n)
        }
        return out
    }

    /// `Frame_UpdateCombatChatter` (0x004311f0): the snd id for a queued
    /// chatter line — `bank` 0..2 (+0/+10/+20), the speaker's gövt voice type,
    /// and its gender (ship +0xc922: 0/1, else unknown). With an even variant
    /// count and a known gender, even variants are one gender and odd the
    /// other; otherwise any variant. `random(n)` is the game RNG (0..<n).
    public static func chatterSoundID(bank: Int, voiceType: Int, gender: Int, variantCount: Int,
                                      random: (Int) -> Int) -> Int? {
        guard (0...2).contains(bank), voiceType != -1, variantCount > 0 else { return nil }
        let base = 1000 + voiceType * 100 + bank * 10
        if gender < 0 || gender > 1 || variantCount % 2 != 0 {
            return base + random(variantCount)
        }
        if variantCount == 2 { return base + gender }
        return base + random(variantCount / 2) * 2 + gender
    }

    // MARK: Music

    /// The candidate paths `FUN_004ab5d0` tries for the title music named in
    /// `STR# 130` #2: the plug-ins folder first, then Nova Files, each as the
    /// bare name, then `.mov`, then `.mp3`.
    public static func musicCandidates(name: String) -> [(folder: String, file: String)] {
        let ext = ["", ".mov", ".mp3"]
        return ["Nova Plug-ins", "Nova Files"].flatMap { folder in ext.map { (folder, name + $0) } }
    }

    /// Music volumes (QuickTime 0…256): `pref × 0x30` at start (0x004ab5d0),
    /// `pref × 0x20` from the first 40-tick service on (0x004ab8d0).
    public static func musicStartVolume(preference: Int) -> Int { max(0, min(256, preference * 0x30)) }
    public static func musicPlayingVolume(preference: Int) -> Int { max(0, min(256, preference * 0x20)) }
    /// The fade-out (0x004ab820) steps the volume down by 8 per tick from
    /// `pref × 0x20`: this many 60 Hz ticks.
    public static func musicFadeTicks(preference: Int) -> Int {
        let v = musicPlayingVolume(preference: preference)
        return (v + 7) / 8
    }
    /// The service interval of the music task (0x004ab8d0), in 60 Hz ticks.
    public static let musicServiceTicks = 40
}

private extension UInt16 {
    var toInt: Int { Int(self) }
}
