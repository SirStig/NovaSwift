import Foundation
import NovaSwiftKit

/// The staggered explosion sounds of an NPC ship breaking up. A dying ship does
/// not make one bang: `GameScene.beginNPCDeathSequence` fires nine bursts 0.2 s
/// apart, each at a point jittered ±22 px around the hull and each playing the
/// ship's bööm sound, then a final big blast after the ninth interval — ten
/// sounds over two seconds. This is the sound half of that table, free of any
/// audio or scene API so the Godot bridge plays exactly the same schedule.
public struct DeathBurstSounds {
    public static let burstCount = 9
    public static let burstInterval = 0.2
    /// Per-axis jitter of each of the nine bursts around the hull (px).
    public static let jitter = 22.0

    private struct Pending {
        var due: Double
        var cue: SoundCue
    }

    private var clock = 0.0
    private var pending: [Pending] = []
    /// Entities whose sequence has started (one sequence per ship).
    private var started: Set<Int> = []

    public init() {}

    /// Forget every queued burst (a new world was built).
    public mutating func reset() {
        pending.removeAll()
        started.removeAll()
        clock = 0
    }

    public var isEmpty: Bool { pending.isEmpty }

    /// A ship began dying at `at` with bööm `boomID`; schedule its ten cues.
    /// A repeat for the same entity is ignored. Without a bööm sound the ship
    /// is silent, as in `playBoomSound`.
    public mutating func begin(entityID: Int, at: Vec2, boomID: Int?, game: NovaGame?,
                               jitter: () -> Double = { Double.random(in: -DeathBurstSounds.jitter...DeathBurstSounds.jitter) }) {
        guard started.insert(entityID).inserted else { return }
        guard let sound = boomID.flatMap({ game?.boom($0)?.soundID }) else { return }
        for i in 0..<Self.burstCount {
            let p = Vec2(at.x + jitter(), at.y + jitter())
            pending.append(Pending(due: clock + Double(i) * Self.burstInterval,
                                   cue: SoundCue(soundID: sound, priority: OriginalAudio.Priority.explosion, position: p)))
        }
        pending.append(Pending(due: clock + Double(Self.burstCount) * Self.burstInterval,
                               cue: SoundCue(soundID: sound, priority: OriginalAudio.Priority.explosion, position: at)))
    }

    /// Advance `dt` seconds and return the cues that came due.
    public mutating func advance(dt: Double) -> [SoundCue] {
        clock += max(0, dt)
        guard !pending.isEmpty else { return [] }
        let due = pending.filter { $0.due <= clock + 1e-9 }.map(\.cue)
        pending.removeAll { $0.due <= clock + 1e-9 }
        return due
    }
}
