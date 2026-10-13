// Plain-Swift state for the bridge's `// MARK: Settings plumbing` section in NovaWorld.swift
// (same split as Flight.swift / Gaps.swift: `@Godot` registers only what is declared in the
// class body, so the callables live in NovaWorld and this is the data and the pure rules).
//
// The Godot side keeps every user setting in `Prefs.gd`; `SettingsPlumbing.gd` (autoload) turns
// the engine-relevant ones into one JSON object and calls `apply_settings(json)`. The keys are
// the Apple `GameSettings` property names and raw values, so the two frontends read alike:
//
//   difficulty (veryEasy|easy|normal|hard)      -> CombatTuning.playerDamageScale
//   systemAliveness (original|authentic|normal|bustling) -> Spawner.model / populationScale
//   gameSpeed (x0_5|x1|x1_5|x2|x4|x8)           -> World.timeScale (GameSpeedRules, Caps Lock 2x)
//   autoTargetAfterFiring, confirmLanding, autoLanding, invertTurn
//   enhancements { formationFlying, forgivingLanding, nearestFirstTargeting, autoRoutePlotting,
//                  quickHyperjump, frequentAutosave, ... }   (GameplayEnhancements.catalog keys)
//
// No game logic here: the damage / traffic / speed tables, the landing envelope and the
// auto-landing autopilot are `GameSettingsRules.swift` / `GameSpeedRules.swift` in the engine,
// the same code the Apple app calls.

import Foundation
import NovaSwiftEngine

struct SettingsPlumbing {
    // MARK: The settings (Apple defaults)

    var difficulty: GameDifficulty = .normal
    var traffic: SystemTrafficLevel = .original
    var gameSpeed: GameSpeedSetting = .x1
    var autoTargetAfterFiring = false
    var confirmLanding = false
    var autoLanding = false
    var invertTurn = false
    var enhancements = GameplayEnhancements()

    // MARK: Runtime state

    /// The Caps Lock toggle, pushed by the frontend (Godot has no lock-state query).
    var capsLock = false
    /// The original's 2x flag as last evaluated (Caps Lock, or a jump that started at 2x).
    var x2Flag = false
    /// The multiplier the last `step` ran the simulation at.
    var multiplier = 1.0
    /// Fixed 30 Hz ticks run since the last `apply` / world build (verification readback).
    var ticks = 0
    /// The landable body the auto-landing autopilot is flying to.
    var autoLandTarget: Int?
    /// A landing awaiting the "Land here?" confirmation (confirmLanding).
    var pendingLandConfirm: Int?
    /// The desktop mouse-aim heading (radians, compass), nil when the cursor isn't aiming.
    var mouseAimHeading: Double?
    /// The primary trigger was held last frame (auto-target-after-firing fires on the rising edge).
    var wasFiring = false

    // MARK: Derived engine values

    var landingRules: LandingRules { LandingRules(forgiving: enhancements.forgivingLanding) }
    var flightTuning: FlightTuning { FlightTuning(enhancements: enhancements) }
    var combatTuning: CombatTuning {
        var t = CombatTuning.default
        t.playerDamageScale = difficulty.playerDamageScale
        return t
    }

    // MARK: JSON in / out

    /// Replace every setting from `json` (missing keys take Apple's default). False if it isn't an object.
    mutating func apply(json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        difficulty = (obj["difficulty"] as? String).flatMap(GameDifficulty.init(rawValue:)) ?? .normal
        traffic = (obj["systemAliveness"] as? String).flatMap(SystemTrafficLevel.init(rawValue:)) ?? .original
        gameSpeed = (obj["gameSpeed"] as? String).flatMap(GameSpeedSetting.init(rawValue:)) ?? .x1
        autoTargetAfterFiring = obj["autoTargetAfterFiring"] as? Bool ?? false
        confirmLanding = obj["confirmLanding"] as? Bool ?? false
        autoLanding = obj["autoLanding"] as? Bool ?? false
        invertTurn = obj["invertTurn"] as? Bool ?? false
        var e = GameplayEnhancements()
        let raw = obj["enhancements"] as? [String: Any] ?? [:]
        for entry in GameplayEnhancements.catalog { e[keyPath: entry.keyPath] = raw[entry.key] as? Bool ?? false }
        enhancements = e
        if !autoLanding { autoLandTarget = nil }
        return true
    }

    /// Everything the engine is currently running with, for the frontend and the self-check.
    func stateJSON(world: World?) -> String {
        var enh: [String: Bool] = [:]
        for entry in GameplayEnhancements.catalog { enh[entry.key] = enhancements[keyPath: entry.keyPath] }
        let spawner = world?.spawner
        var out: [String: Any] = [
            "difficulty": difficulty.rawValue, "systemAliveness": traffic.rawValue, "gameSpeed": gameSpeed.rawValue,
            "autoTargetAfterFiring": autoTargetAfterFiring, "confirmLanding": confirmLanding,
            "autoLanding": autoLanding, "invertTurn": invertTurn, "enhancements": enh,
            "capsLock": capsLock, "x2": x2Flag, "multiplier": multiplier, "ticks": ticks,
            "autoLandTarget": autoLandTarget ?? -1, "mouseAiming": mouseAimHeading != nil,
            "playerDamageScale": world?.combatTuning.playerDamageScale ?? combatTuning.playerDamageScale,
            "timeScale": world?.timeScale ?? 1.0,
            "formationFlying": flightTuning.aiInertialess != .off,
        ]
        out["spawnModel"] = (spawner?.model ?? traffic.spawnModel) == .original ? "original" : "port"
        out["populationScale"] = spawner?.populationScale ?? traffic.populationScale
        out["worldEnhancementsMatch"] = world.map { $0.enhancements == enhancements } ?? true
        guard let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: Pushing onto a world

    /// Settings that live on the `World` / its `Spawner` (Apple `GameScene.init` and `applyDisplaySettings`).
    func configure(_ world: World) {
        world.combatTuning.playerDamageScale = difficulty.playerDamageScale
        world.enhancements = enhancements
        if let spawner = world.spawner {
            spawner.model = traffic.spawnModel
            spawner.populationScale = traffic.populationScale
        }
    }

    // MARK: The speed clock (Apple GameScene.update / evaluateX2Flag)

    /// The original's 2x flag: Caps Lock, held off for a jump that began at 1x, held on for one that began at 2x.
    func evaluateX2Flag(_ world: World) -> Bool {
        var withinTen = false, x2Cue = false, normalCue = false
        if let jump = world.playerJump {
            let off = abs(angleDelta(from: world.player.angle, to: jump.bearing)) * 180 / .pi
            withinTen = off < 11
            x2Cue = jump.cueSounding && jump.cueX2 == true
            normalCue = jump.cueSounding && jump.cueX2 == false
        }
        return GameSpeedRules.x2Flag(capsLockOn: capsLock, x2CueSounding: x2Cue,
                                     normalCueSounding: normalCue, headingWithinTenOfJump: withinTen)
    }

    mutating func resetForNewWorld() {
        autoLandTarget = nil
        pendingLandConfirm = nil
        wasFiring = false
        ticks = 0
    }
}
