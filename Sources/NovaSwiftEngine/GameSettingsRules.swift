import Foundation

// The engine-side rules behind the user-facing Settings that change how the world
// plays, shared by every frontend (the Apple app's `GameSettings` and the Godot
// bridge's `apply_settings`). Each rule used to live in `app/NovaSwift`; they moved
// here unchanged so a second frontend applies them identically. UI strings (labels,
// blurbs) stay with the frontends; only the numbers and the logic live here.

/// Difficulty: scales the damage the player takes. Raw values are the saved
/// settings' (`GameSettings.Difficulty`).
public enum GameDifficulty: String, Codable, CaseIterable, Sendable {
    case veryEasy, easy, normal, hard

    /// Damage the player takes, scaled. Easy is more forgiving; hard, less.
    /// Very Easy halves Easy again, for players who want the story without
    /// the fights, still lethal if you ignore your shields entirely.
    public var playerDamageScale: Double {
        switch self {
        case .veryEasy: return 0.3
        case .easy: return 0.6
        case .normal: return 1.0
        case .hard: return 1.5
        }
    }
}

/// System Aliveness: which spawner rules run and how populated systems are.
/// Raw values are the saved settings' (`GameSettings.SystemAliveness`).
public enum SystemTrafficLevel: String, Codable, CaseIterable, Sendable {
    case original, authentic, normal, bustling

    /// The `Spawner` rules this setting runs.
    public var spawnModel: Spawner.SpawnModel { self == .original ? .original : .port }

    /// Multiplies `Spawner.targetPopulation`/`maxPopulation`/`maxConcurrentFleets`
    /// and inversely scales `spawnInterval`/`fleetInterval`.
    public var populationScale: Double {
        switch self {
        case .original, .normal: return 1.0
        case .authentic: return 0.55
        case .bustling: return 1.35
        }
    }
}

/// Simulation speed option (before the Caps Lock 2x, see `GameSpeedRules`).
/// Raw values are the saved settings' (`GameSettings.GameSpeed`).
public enum GameSpeedSetting: String, Codable, CaseIterable, Sendable {
    case x0_5, x1, x1_5, x2, x4, x8

    /// Physics-timestep multiplier; `x1` is exactly real time.
    public var multiplier: Double {
        switch self {
        case .x0_5: return 0.5
        case .x1: return 1.0
        case .x1_5: return 1.5
        case .x2: return 2.0
        case .x4: return 4.0
        case .x8: return 8.0
        }
    }
}

/// The colorblind-assist filter as a 4x4 colour matrix (the rows of Apple's
/// `CIColorMatrix` vectors): `out.r = dot(rVector, rgba)` and so on. A frontend
/// applies it with whatever its renderer has (Core Image, a screen-space shader).
public enum ColorblindFilter: String, Codable, CaseIterable, Sendable {
    case none, protanopia, deuteranopia, tritanopia

    /// Rows R, G, B, A of the matrix, each `[r, g, b, a]` (CIColorMatrix's
    /// `inputRVector`, `inputGVector`, `inputBVector`, `inputAVector`); nil for `none`.
    public var matrixRows: [[Double]]? {
        let k = 0.5
        switch self {
        case .none: return nil
        case .protanopia, .deuteranopia:
            return [[1, 0, 0, 0], [0, 1, 0, 0], [k, -k, 1, 0], [0, 0, 0, 1]]
        case .tritanopia:
            return [[1, 0, 0, 0], [-k, 1, k, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
        }
    }
}

/// The player's landing envelope: the original's (0x00457580) or the
/// `forgivingLanding` enhancement's circle of `radius + 70` at 130 px/s with no
/// clearance step (FL-12).
public struct LandingRules: Equatable, Sendable {
    public var forgiving: Bool
    public init(forgiving: Bool) { self.forgiving = forgiving }

    /// The speed below which a landing is allowed, px/s: the forgiving overall
    /// limit, or the original's per-axis 0.75 px/tick.
    public var speedLimit: Double { forgiving ? 130 : PlayerLanding.perAxisSpeedLimit }

    /// The landing envelope's half-size.
    public func reach(radius: Double) -> Double {
        forgiving ? radius + 70 : PlayerLanding.reach(radius: radius)
    }

    /// The original's per-axis speed gate (0.75 px/tick), or the forgiving overall limit.
    public func isSlowEnough(_ velocity: Vec2) -> Bool {
        forgiving ? velocity.length <= speedLimit : PlayerLanding.isSlowEnough(velocity)
    }

    /// Whether the offset from the ship to the body is inside the envelope.
    public func inReach(offset d: Vec2, radius: Double) -> Bool {
        let r = reach(radius: radius)
        return forgiving ? d.length <= r : abs(d.x) < r && abs(d.y) < r
    }

    /// Whether a ship may set down right now. `offset` is body minus ship.
    public func canLand(offset d: Vec2, radius: Double, velocity: Vec2, cleared: Bool, cloaked: Bool) -> Bool {
        if forgiving { return d.length <= reach(radius: radius) && velocity.length <= speedLimit }
        let r = reach(radius: radius)
        return abs(d.x) < r && abs(d.y) < r
            && abs(velocity.x) <= speedLimit && abs(velocity.y) <= speedLimit
            && cleared
            && !cloaked                 // a cloaked ship is refused (STR# 2002 #73)
    }
}

/// The auto-landing autopilot (Settings > Auto-landing): fly toward the body,
/// brake into the approach, hand back `.arrived` once the ship may set down.
public enum AutoLandPilot {
    public enum Step: Equatable {
        /// In range and slow: the frontend commits the landing.
        case arrived
        /// Fly this intent for one frame.
        case fly(ControlIntent)
    }

    public static func step(player p: Ship, body: StellarBody, rules: LandingRules, cleared: Bool) -> Step {
        let to = body.position - p.position
        let dist = to.length
        let reach = min(body.radius + 55, rules.reach(radius: body.radius))
        let speed = p.velocity.length
        if rules.canLand(offset: to, radius: body.radius, velocity: p.velocity, cleared: cleared,
                         cloaked: p.isEffectivelyCloaked) {
            return .arrived
        }
        var i = ControlIntent()
        i.desiredHeading = atan2(to.x, to.y)   // 0 = +y (up), clockwise, matches the engine
        var da = (i.desiredHeading! - p.angle).truncatingRemainder(dividingBy: 2 * .pi)
        if da > .pi { da -= 2 * .pi }
        if da < -.pi { da += 2 * .pi }
        let aligned = abs(da) < 0.5
        if dist > reach * 1.8 {
            if aligned { i.thrust = true }             // cruise in while pointed at it
        } else if speed > rules.speedLimit * 0.75 {
            // Brake into the pad: swing to retrograde and burn.
            let retro = p.velocity.angle + .pi
            i.desiredHeading = retro
            i.thrust = abs(angleDelta(from: p.angle, to: retro)) < 0.3
        } else if aligned && dist > reach {
            i.thrust = true                            // nudge the last stretch
        }
        return .fly(i)
    }
}

extension World {
    /// The nearest-first Tab-cycle order (`nearestFirstTargeting` enhancement):
    /// every in-range ship the player can see, nearest first, the player's own
    /// escorts at the back (in the original they crowded the front of the cycle).
    public func nearestFirstCycleCandidates() -> [Int] {
        let p = player.position
        var others: [(id: Int, dist: Double)] = []
        var escorts: [(id: Int, dist: Double)] = []
        for npc in npcs where npc.isAlive && canTarget(npc, by: player) {
            let d = (npc.position - p).length
            guard d <= World.targetLockRange else { continue }
            if isPlayerEscort(npc) {
                escorts.append((npc.entityID, d))
            } else {
                others.append((npc.entityID, d))
            }
        }
        let byDistance: ((id: Int, dist: Double), (id: Int, dist: Double)) -> Bool = { $0.dist < $1.dist }
        return (others.sorted(by: byDistance) + escorts.sorted(by: byDistance)).map(\.id)
    }

    /// One step of the nearest-first cycle; returns the ship now targeted, or nil if none.
    @discardableResult
    public func cycleNearestFirst(reverse: Bool) -> Ship? {
        let candidates = nearestFirstCycleCandidates()
        guard !candidates.isEmpty else { return nil }
        let currentIdx = candidates.firstIndex { $0 == player.currentTargetID }
        let step = reverse ? -1 : 1
        let next = ((currentIdx.map { $0 + step } ?? 0) % candidates.count + candidates.count) % candidates.count
        return selectTarget(id: candidates[next])
    }
}
