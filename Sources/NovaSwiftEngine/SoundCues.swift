import Foundation
import NovaSwiftKit

/// One sound the game wants played, before any audio backend touches it: which
/// `snd `, at what priority, heard from where. The Apple app plays these through
/// `GameAudio`; the Godot frontend gets them from the bridge. The event → cue
/// table below is the original's call-site table (`GameScene.processWorldEvents`
/// and `GameAudio`), kept free of any audio API so both frontends share it.
public struct SoundCue: Equatable {
    /// Where the sound is heard from. `nil` = `nv_PlaySound`: centred at unity
    /// volume; otherwise `NovaAudio_PlaySpatialByDistance` from this world point.
    public var position: Vec2?
    public var soundID: Int
    /// The call site's priority (`OriginalAudio.Priority`).
    public var priority: Int
    /// Played only when no voice already sounds this `snd ` (wëap Flags 0x0010
    /// weapons, Warp out, Klaxxon — `NovaAudio_CountActiveByHandle`).
    public var onlyWhenSilent = false
    /// Follows the interface-volume slider (beeps, escort chatter) rather than
    /// only the effects level.
    public var interfaceVolume = false
    /// Playback rate (the Warp up cue runs at the hull's jump multiplier).
    public var rate = 1.0

    public init(soundID: Int, priority: Int, position: Vec2? = nil) {
        self.soundID = soundID
        self.priority = priority
        self.position = position
    }
}

/// The original's event → sound mapping.
public enum SoundCues {
    private typealias P = OriginalAudio.Priority

    // MARK: Fixed sounds (GameAudio.GameEvent)

    public static let hyperspaceChargeID = 128    // "Warp up"
    public static let warpUp2xID = 129
    public static let hyperspaceArriveID = 130    // "Warp out"
    public static let redAlertID = 370
    public static let klaxxonID = 371
    public static let airlockID = 390

    /// Interface beep `n` (1…5 = snd 150…154), priority 1.
    public static func beep(_ n: Int) -> SoundCue? {
        guard (1...5).contains(n) else { return nil }
        var cue = SoundCue(soundID: 149 + n, priority: P.beep)
        cue.interfaceVolume = true
        return cue
    }

    /// Warp out: only when none is sounding already (0x0044f3d0:85).
    public static var hyperspaceArrive: SoundCue {
        var cue = SoundCue(soundID: hyperspaceArriveID, priority: P.warpOut)
        cue.onlyWhenSilent = true
        return cue
    }

    /// The Warp up voice (0x004b0740): snd 128, or snd 129 under Caps Lock 2x,
    /// at priority 32000 and `multiplier` times faster; only when none sounds.
    public static func warpUp(multiplier: Double, x2: Bool) -> SoundCue {
        var cue = SoundCue(soundID: x2 ? warpUp2xID : hyperspaceChargeID, priority: P.warpUp)
        cue.onlyWhenSilent = true
        cue.rate = multiplier > 0 ? multiplier : 1
        return cue
    }

    public static var redAlert: SoundCue { SoundCue(soundID: redAlertID, priority: P.redAlert) }
    /// Klaxxon sounds only while none is already playing (0x0044b120:2856).
    public static var klaxxon: SoundCue {
        var cue = SoundCue(soundID: klaxxonID, priority: P.klaxxon)
        cue.onlyWhenSilent = true
        return cue
    }
    /// The player set down on a spöb (and a paid assistance docking): snd 390.
    public static var docking: SoundCue { SoundCue(soundID: airlockID, priority: P.airlock) }

    // MARK: Weapons

    /// A weapon's fire sound as the original's call sites play it:
    /// `Weapon_FireShipWeapons` (NPCs, priority 4, at the shooter),
    /// `Weapon_FirePlayerWeaponBank` (the player, 5/6, at full volume), point
    /// defense (guidance 9/10, priority 3, at the shooter) and an NPC bay
    /// launch (guidance 99, priority 5). wëap Flags 0x0010 plays only when no
    /// voice is already playing that sound (the bay launch ignores it).
    public static func weaponFire(soundID: Int, weaponID: Int, isPlayer: Bool, at: Vec2, game: NovaGame?) -> SoundCue {
        let w = game?.weapon(weaponID)
        let guidance = w?.guidanceRaw ?? -1
        let pointDefense = guidance == 9 || guidance == 10
        let carried = guidance == 99
        var cue: SoundCue
        if pointDefense {
            cue = SoundCue(soundID: soundID, priority: P.turret, position: at)
        } else if isPlayer {
            cue = SoundCue(soundID: soundID, priority:
                            P.playerWeapon(guidance: guidance, flags: Int(w?.flagsRaw ?? 0)))
        } else if carried {
            cue = SoundCue(soundID: soundID, priority: P.carrierLaunch, position: at)
        } else {
            cue = SoundCue(soundID: soundID, priority: P.npcWeapon, position: at)
        }
        cue.onlyWhenSilent = !(carried && !isPlayer) && (w?.loopSound ?? false)
        return cue
    }

    // MARK: Events

    /// The sounds a `WorldEvent` makes. Events with no sound of their own return
    /// `[]`. (Presentation-driven sounds — the jump cue, red alert, klaxxon,
    /// docking by a UI action — are not events; see the `SoundCues` statics.)
    public static func cues(for event: WorldEvent, game: NovaGame?) -> [SoundCue] {
        switch event {
        case let .debrisPuffSound(at):
            return [SoundCue(soundID: 372, priority: P.explosion, position: at)]
        case let .playerCloakChanged(engaging):
            // Plain nv_PlaySound at priority 8 (0x004680d0 / 0x00468190), player only.
            return [SoundCue(soundID: engaging ? 381 : 380, priority: P.airlock)]
        case let .combatChatter(soundID):
            var cue = SoundCue(soundID: soundID, priority: P.klaxxon)
            cue.interfaceVolume = true
            return [cue]
        case let .weaponFired(shooterID, at, _, soundID, weaponID):
            guard let soundID else { return [] }
            return [weaponFire(soundID: soundID, weaponID: weaponID, isPlayer: shooterID == 0, at: at, game: game)]
        case let .beam(shooterID, _, from, _, _, soundID, weaponID):
            guard let soundID else { return [] }
            return [weaponFire(soundID: soundID, weaponID: weaponID, isPlayer: shooterID == 0, at: from, game: game)]
        case let .explosion(at, _, soundID, _):
            guard let soundID else { return [] }
            return [SoundCue(soundID: soundID, priority: P.explosion, position: at)]
        case let .stellarDestroyed(_, at, boomID, _):
            guard let sound = boomID.flatMap({ game?.boom($0)?.soundID }) else { return [] }
            return [SoundCue(soundID: sound, priority: P.explosion, position: at)]
        case let .shipDying(_, at, boomID):
            // The death bursts' bööm sound, heard from the player like every explosion.
            guard let sound = boomID.flatMap({ game?.boom($0)?.soundID }) else { return [] }
            return [SoundCue(soundID: sound, priority: P.explosion, position: at)]
        case let .interfaceBeep(soundID):
            guard (150...154).contains(soundID) else { return [] }
            return beep(soundID - 149).map { [$0] } ?? []
        case let .shipLanded(entityID, _, _):
            return entityID == 0 ? [docking] : []
        case let .shipDisabled(entityID, _):
            return entityID == 0 ? beep(2).map { [$0] } ?? [] : []      // snd 151, 0x004192d0
        case .escortRejoined, .fighterRecoveredToBay:
            return beep(5).map { [$0] } ?? []                           // snd 154, 0x0045a3d0
        case .repairSystemEngaged(let entityID):
            return entityID == 0 ? beep(5).map { [$0] } ?? [] : []      // snd 154, 0x0044b120
        case let .shipCapturedByNPC(_, _, stolenLine):
            return stolenLine != nil ? beep(2).map { [$0] } ?? [] : []  // snd 151, 0x00412550
        case .assistanceDelivered:
            return (beep(2).map { [$0] } ?? []) + [docking]             // 0x00408150
        case .playerDying:
            return beep(2).map { [$0] } ?? []                           // snd 151, 0x004192d0
        default:
            return []
        }
    }
}

/// The original's 16-voice list as a backend-neutral board (`GameAudioEngine`
/// does the same on `AVAudioPlayerNode`s): a frontend owns 16 player nodes and
/// this decides, per cue, which node starts which sound, at what gain, and which
/// are audible (the first 8 by priority/volume). Time is passed in explicitly,
/// so it is deterministic and testable.
public final class SoundVoiceBoard {
    public struct Command: Equatable {
        public enum Action: Int { case level = 0, start = 1, stop = 2 }
        public var node: Int
        public var soundID: Int
        /// Linear 0…1 (voice volume / unity), before any interface-slider scale.
        public var gain: Float
        public var action: Action
        public var rate: Double
        public var interfaceVolume: Bool
    }

    private struct Slot {
        var node: Int
        var endTime: TimeInterval
        var gain: Float
        var rate: Double
        var interfaceVolume: Bool
        var started: Bool
    }

    private var list = OriginalAudio.VoiceList<Slot>()
    private var freeNodes = Array((0..<OriginalAudio.slotCount).reversed())
    private var stopped: [Command] = []
    private var dirty = false

    public init() {}

    private func purge(now: TimeInterval) {
        for gone in list.remove(where: { $0.payload.endTime <= now }) where gone.payload.node >= 0 {
            freeNodes.append(gone.payload.node)
            dirty = true
        }
    }

    /// `NovaAudio_CountActiveByHandle` (0 = every voice).
    public func activeCount(soundID: Int, now: TimeInterval) -> Int {
        purge(now: now)
        return list.count(soundID: soundID)
    }

    /// Submit a cue heard from `listener`; `duration` is the sample's length in
    /// seconds at rate 1. Returns false if it was dropped (guarded or ranked
    /// below all 16 voices).
    @discardableResult
    public func play(_ cue: SoundCue, listener: Vec2, duration: TimeInterval, now: TimeInterval) -> Bool {
        purge(now: now)
        if cue.onlyWhenSilent, list.count(soundID: cue.soundID) > 0 { return false }
        let volume: Int
        if let at = cue.position {
            volume = OriginalAudio.spatialVolume(dx: at.x - listener.x, dy: at.y - listener.y,
                                                 master: OriginalAudio.unityVolume)
        } else {
            volume = OriginalAudio.unityVolume
        }
        let gain = Float(min(max(volume, 0), OriginalAudio.unityVolume)) / Float(OriginalAudio.unityVolume)
        let slot = Slot(node: -1, endTime: now + duration / max(cue.rate, 0.01), gain: gain,
                        rate: cue.rate, interfaceVolume: cue.interfaceVolume, started: false)
        switch list.insert(soundID: cue.soundID, priority: cue.priority, volume: volume, payload: slot) {
        case .dropped:
            return false
        case let .inserted(index, evicted):
            let node: Int
            if let evicted, evicted.payload.node >= 0 {
                node = evicted.payload.node
            } else if let free = freeNodes.popLast() {
                node = free
            } else {
                list.remove(where: { $0.payload.node < 0 })
                return false
            }
            var bound = slot
            bound.node = node
            list.setPayload(at: index, bound)
            dirty = true
            return true
        }
    }

    /// `NovaAudio_UnregisterCallbacks`: stop every voice of `soundID` (0 = all).
    public func stop(soundID: Int) {
        let gone = list.remove(where: { soundID == 0 || $0.soundID == soundID })
        for v in gone where v.payload.node >= 0 {
            freeNodes.append(v.payload.node)
            stopped.append(Command(node: v.payload.node, soundID: v.soundID, gain: 0, action: .stop,
                                   rate: 1, interfaceVolume: false))
        }
        if !gone.isEmpty { dirty = true }
    }

    /// What the frontend must apply now: stops, then — if anything changed —
    /// the level of every live voice (a `.start` the first time it is listed;
    /// voices past the 8th are silent). Empty when nothing changed.
    public func commands(now: TimeInterval) -> [Command] {
        purge(now: now)
        guard dirty else { return [] }
        dirty = false
        var out = stopped
        stopped.removeAll(keepingCapacity: true)
        for (i, v) in list.voices.enumerated() where v.payload.node >= 0 {
            let first = !v.payload.started
            if first {
                var bound = v.payload
                bound.started = true
                list.setPayload(at: i, bound)
            }
            let audible = OriginalAudio.VoiceList<Slot>.isAudible(index: i)
            out.append(Command(node: v.payload.node, soundID: v.soundID,
                               gain: audible ? v.payload.gain : 0,
                               action: first ? .start : .level,
                               rate: v.payload.rate, interfaceVolume: v.payload.interfaceVolume))
        }
        return out
    }
}
