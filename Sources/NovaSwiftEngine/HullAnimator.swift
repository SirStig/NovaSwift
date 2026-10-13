import Foundation
import NovaSwiftKit

/// Renderer-free port of the Apple app's `HullAnim`/`BankTracker`/shield-flare math
/// (`app/NovaSwift/Game/HullAnimation.swift`, `GameScene.advanceShieldFlare`), so the
/// Godot frontend selects exactly the sprite frames and overlay intensities the Apple
/// Classic path does. Foundation-only: no SpriteKit, no CoreGraphics.
///
/// The base hull sheet packs `setCount` rotation sets of `framesPerSet` frames. Frame
/// `set*framesPerSet + heading` picks a heading within a set; which set is live depends
/// on `mode` (banking → turn direction, animation → a clock). The engine-glow, running-
/// light and weapon-glow overlays share that frame layout.
public struct HullAnimConfig: Sendable {
    public var framesPerSet = 36
    public var setCount = 1
    public var mode: ShanRes.ExtraFrames = .none
    public var animDelaySec: Double = 1.0 / 30
    public var weapDecay = 50
    public var blinkMode = 0
    public var blink: (a: Int, b: Int, c: Int, d: Int) = (0, 0, 0, 0)
    public var hidesLightsWhenDisabled = false
    /// `shän.AltSetCount`; 0 = this hull has no alt layer.
    public var altSetCount = 0
    /// `shän.BaseTransp` as a 0…1 hull alpha.
    public var baseOpacity: Double = 1

    public init() {}

    /// - Parameter animations: the "Ship Animations" preference. Off, the original loads
    ///   every hull with a single set (0x004b4ee0): no banking, animation or extra alt sets.
    public init(_ shan: ShanRes, animations: Bool = true) {
        framesPerSet = max(1, shan.framesPerSet)
        setCount = animations ? max(1, shan.baseSetCount) : 1
        mode = shan.extraFrames
        animDelaySec = Double(max(1, shan.animDelay)) / 30.0
        weapDecay = shan.weapDecay
        blinkMode = shan.blinkMode
        blink = shan.blinkValues
        hidesLightsWhenDisabled = shan.hidesLightsWhenDisabled
        altSetCount = shan.hasAltLayer ? (animations ? shan.altSetCount : 1) : 0
        baseOpacity = shan.baseOpacity
    }

    public func altSet(animClock: Double) -> Int {
        guard altSetCount > 1 else { return 0 }
        return Int(animClock / animDelaySec) % altSetCount
    }

    /// Heading frame (0..<framesPerSet) for a world angle (radians clockwise from north).
    public func heading(forAngle angle: Double) -> Int {
        SpriteFrames.headingFrame(angle: angle, frames: framesPerSet)
    }

    /// Which base sprite set to show. `turnSign`: +1 turning left, -1 right, 0 straight.
    /// - Parameter foldSet: the ship's `HullFoldState.currentSet`; only a `.folding` hull reads it.
    ///   Folding ignores `disabled`: the original's fold branch (0x00428340) runs for a hulk too.
    public func baseSet(turnSign: Int, animClock: Double, disabled: Bool, carriesKeyShip: Bool = false,
                        foldSet: Int = 0) -> Int {
        guard setCount > 1 else { return 0 }
        if mode == .folding { return max(0, min(foldSet, setCount - 1)) }
        guard !disabled else { return 0 }     // a hulk has no attitude control
        switch mode {
        case .banking:
            if turnSign > 0 { return min(1, setCount - 1) }
            if turnSign < 0 { return min(2, setCount - 1) }
            return 0
        case .animation:
            return Int(animClock / animDelaySec) % setCount
        case .keyCarried:
            return carriesKeyShip ? min(1, setCount - 1) : 0
        case .none, .folding:
            return 0   // .folding returned above
        }
    }

    /// Flat sheet index, wrapped by `count` like `Sprite_SetCurrentFrame` (0x00475830).
    public func frameIndex(set: Int, heading: Int, count: Int) -> Int {
        OriginalRendering.wrappedFrame(set * framesPerSet + heading, count: count)
    }

    /// Running-light opacity (0…1) for a blink clock in seconds. Ticks are 1/30 s.
    public func lightIntensity(clock: Double) -> Double {
        let t = clock * 30.0
        switch blinkMode {
        case 1:
            let a = Double(max(1, blink.a)), b = Double(max(0, blink.b))
            let c = Double(max(1, blink.c)), d = Double(max(0, blink.d))
            let blinkLen = a + b
            let groupLen = c * blinkLen + d
            guard groupLen > 0 else { return 1 }
            let phase = t.truncatingRemainder(dividingBy: groupLen)
            if phase >= c * blinkLen { return 0 }
            return phase.truncatingRemainder(dividingBy: blinkLen) < a ? 1 : 0
        case 2:
            let mn = Double(max(1, min(blink.a, blink.c)))
            let mx = Double(max(mn + 1, Double(max(blink.a, blink.c))))
            let rise = max(0.01, Double(blink.b) / 100.0)
            let fall = max(0.01, Double(blink.d) / 100.0)
            let upT = (mx - mn) / rise, downT = (mx - mn) / fall
            let period = upT + downT
            guard period > 0 else { return mx / 32.0 }
            let ph = t.truncatingRemainder(dividingBy: period)
            let inten = ph < upT ? mn + rise * ph : mx - fall * (ph - upT)
            return min(32, max(1, inten)) / 32.0
        case 3:
            let mn = Double(max(1, blink.a)), mx = Double(max(blink.a + 1, blink.b))
            let step = Double(max(1, blink.c))
            let bucket = Int(t / step)
            var x = UInt64(bitPattern: Int64(bucket &* 2654435761 &+ 1013904223))
            x ^= x >> 13; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33
            let r = Double(x % 100_000) / 100_000.0
            return min(32, max(1, mn + r * (mx - mn))) / 32.0
        default:
            return 1
        }
    }

    /// A weapon-glow flare after `dt` seconds: it loses `WeapDecay × 0.333` of its 0…32
    /// value every 30 Hz tick, linearly (`Ship_UpdateVisualState` 0x00428340, C-4).
    public func weaponGlowAfter(_ flare: Double, dt: Double) -> Double {
        let perTick = Double(max(0, weapDecay)) * 0.333 / 32.0
        return max(0.0, flare - perTick * dt * 30.0)
    }
}

/// Signed turn direction from an angle change with a small deadband.
public func hullTurnSign(fromAngle last: Double, toAngle now: Double, dt: Double) -> Int {
    guard dt > 0, last.isFinite else { return 0 }
    var delta = (now - last).truncatingRemainder(dividingBy: 2 * .pi)
    if delta > .pi { delta -= 2 * .pi }
    if delta < -.pi { delta += 2 * .pi }
    let rate = delta / dt
    if rate > 0.2 { return 1 }
    if rate < -0.2 { return -1 }
    return 0
}

/// Which way a hull is banking, held across display frames (the sim turns on a fixed
/// 30 Hz tick; see Apple `BankTracker`).
public struct HullBankTracker: Sendable {
    private var lastAngle: Double = .nan
    private var age: Double = 0
    private var sign = 0
    private static let holdSeconds = 0.05
    public init() {}

    public mutating func update(angle: Double, dt: Double) -> Int {
        age += dt
        if angle != lastAngle {
            if lastAngle.isFinite { sign = hullTurnSign(fromAngle: lastAngle, toAngle: angle, dt: age) }
            lastAngle = angle
            age = 0
        } else if age > Self.holdSeconds {
            sign = 0
        }
        return sign
    }
}

/// The decaying shield-hit flare (Apple `GameScene.advanceShieldFlare`).
public enum ShieldFlare {
    public static let decaySeconds = 0.45
    public static let maxAlpha = 0.85

    /// Decays every frame and spikes when the shield dropped since the last sample.
    /// `shieldWas < 0` = no prior sample.
    public static func advance(_ current: Double, shieldNow: Double, shieldWas: Double,
                               maxShield: Double, dt: Double) -> Double {
        var flare = max(0, current - dt / decaySeconds)
        if shieldWas >= 0, maxShield > 0 {
            let dropFrac = (shieldWas - shieldNow) / maxShield
            if dropFrac > 0.0001 { flare = max(flare, min(1, 0.4 + dropFrac * 6)) }
        }
        return flare
    }
}

/// Everything per-ship the frontend needs to pick overlay frames and intensities for one
/// display frame. Mutable state of one hull, advanced once per display frame.
public struct ShipLayerState: Sendable {
    public var bank = HullBankTracker()
    public var animClock = 0.0
    public var blinkClock = 0.0
    public var weaponGlowFlare = 0.0
    public var shieldFlare = 0.0
    public var lastShield = -1.0
    /// Low-pass-filtered exhaust flicker alpha.
    public var thrusterAlpha = 0.7
    public init() {}
}

// MARK: - Folding hulls (shän Flags 0x0002)

/// What a hull needs to fold and unfold, from its `shän` (`ShipClass_LoadShipClassVisualAndLaunchData`
/// 0x004b4ee0 copies shän +0x2e to class +0xa24, +0x30 to +0x9fe and the set count to +0xa00).
/// The hull sheet's sets are the fold frames: set 0 is folded and the last set unfolded, except for
/// a hull that also has Flags 0x0080 ("weapons fold"), where set 0 is the firing pose.
public struct HullFoldConfig: Sendable, Equatable {
    /// `shän` Flags 0x0002 and more than one set.
    public var folds = false
    /// `shän` Flags 0x0080: the hull unfolds to fire and refolds when idle.
    public var weaponsFold = false
    public var setCount = 1
    /// `shän.AnimDelay` in 1/30 s ticks: the time one fold step takes.
    public var delayTicks: Double = 0

    public static let none = HullFoldConfig()
    public init() {}

    /// - Parameter animations: the "Ship Animations" preference; off, the original loads one set.
    public init(_ shan: ShanRes, animations: Bool = true) {
        let sets = animations ? max(1, shan.baseSetCount) : 1
        setCount = sets
        folds = shan.extraFrameFlags & 0x0002 != 0 && sets > 1
        weaponsFold = shan.extraFrameFlags & 0x0080 != 0
        delayTicks = Double(shan.animDelay)
    }
}

/// One ship's fold state (`ship+0xc8fc` current set, `+0xc8fa` direction, `+0xe4e4` timer,
/// `+0xa8` last weapon-fire tick) and the rules that move it. The per-frame step is
/// `Ship_UpdateVisualState` 0x00428340; the triggers are named at each method. Pure value
/// logic: both frontends read `currentSet` and the world drives the rest.
public struct HullFoldState: Sendable {
    public var config = HullFoldConfig.none
    /// True once `config` was read from the hull's `shän`.
    public var configResolved = false
    /// The fold set. Negative = never set: a freshly allocated or launched-from-bay ship is fully
    /// extended (`Ship_AllocateShipSlotInSystem` 0x004254b0 and 0x0041e640 write setCount - 1).
    public var set = -1
    /// +1 unfolding (toward the last set), -1 folding (toward set 0), 0 at rest.
    public var direction = 0
    /// Ticks (1/30 s) since the last set change.
    public var timer: Double = 0
    /// The ship's own 60 Hz clock, standing in for the original's `TickCount` (0x004d5e10).
    public var clock60: Double = 0
    /// `+0xa8`: the clock when a weapon bank was last asked to fire.
    public var lastFire60: Double = 0

    /// The 45 ticks (0x2d, 60 Hz) a weapons-fold hull waits after its last shot before refolding.
    public static let idleTicks60: Double = 45

    public init() {}

    private var lastSet: Int { max(0, config.setCount - 1) }

    /// The set to draw, clamped to the hull's sets. Always 0 for a hull that does not fold.
    public var currentSet: Int {
        guard config.folds else { return 0 }
        return set < 0 ? lastSet : min(set, lastSet)
    }

    /// Resolve the "never set" sentinel against the config.
    private mutating func resolve() {
        if set < 0 { set = lastSet }
    }

    /// `Ship_UpdateVisualState` 0x00428340, the Flags 0x0002 branch. `ticks` is 1/30 s units.
    /// The extra period at the end of an unfold is the original's: the set wraps past the last
    /// one before the direction clears.
    public mutating func step(ticks: Double) {
        clock60 += ticks * 2
        guard config.folds else { return }
        resolve()
        if direction > 0 {
            timer += ticks
            if config.delayTicks < timer {
                timer = 0
                set += 1
                if config.setCount <= set {
                    set = config.setCount - 1
                    direction = 0
                }
            }
        } else if direction < 0 {
            timer += ticks
            if config.delayTicks < timer {
                timer = 0
                set -= 1
                if set < 1 {
                    set = 0
                    direction = 0
                }
            }
        } else {
            timer = 0
        }
        // A weapons-fold hull extends again once it has not fired for 45 ticks.
        if config.weaponsFold, direction < 1, set < config.setCount - 1,
           clock60 >= lastFire60 + Self.idleTicks60 {
            direction = 1
        }
    }

    /// Launch, takeoff and the player's hyperspace arrival (0x00457580, 0x0044aa70 and its
    /// fragments, reset 0x004b3350): a normal hull starts folded and unfolds; a weapons-fold
    /// hull starts at its last set and stays.
    public mutating func beginLaunch() {
        timer = 0
        if config.weaponsFold {
            set = lastSet
            direction = 0
        } else {
            set = 0
            direction = 1
        }
    }

    /// An NPC emerging from hyperspace (`FUN_00410e20`, state 8): set 0 unfolding, whatever
    /// the flags.
    public mutating func beginArrival() {
        set = 0
        direction = 1
        timer = 0
    }

    /// The player engaging a jump, an NPC entering a jump control mode (4 or 0xd), and the
    /// idle-to-unfold test of `Ship_UpdateShipAI` 0x00401000 (the fold half): a normal hull above
    /// set 0 with nothing moving folds. A weapons-fold hull does not.
    public mutating func foldForJump() {
        guard config.folds, !config.weaponsFold else { return }
        resolve()
        if set > 0, direction == 0 { direction = -1 }
    }

    /// The player's own engage (0x0044c4e9 and its copies) does not wait for the direction to
    /// be idle.
    public mutating func foldForPlayerJump() {
        guard config.folds, !config.weaponsFold else { return }
        resolve()
        if set > 0 { direction = -1 }
    }

    /// An NPC parking at a stellar (`Ship_UpdateShipAiState` 0x00405590): folds from the moment
    /// it is inside the stop box, weapons-fold hulls included.
    public mutating func foldAtStellar() {
        guard config.folds else { return }
        resolve()
        if set > 0 { direction = -1 }
    }

    /// The AI's unfold tests (`Ship_UpdateShipAI` 0x00401000): arriving from a jump, or parked and
    /// no longer coasting. A normal hull unfolds at once; a weapons-fold hull only after the
    /// 45-tick idle.
    public mutating func unfoldIfIdle() {
        guard config.folds else { return }
        resolve()
        guard direction == 0, set < config.setCount - 1 else { return }
        if !config.weaponsFold || clock60 >= lastFire60 + Self.idleTicks60 { direction = 1 }
    }

    /// `Weapon_FireShipWeapons` 0x00414550 / `Weapon_FirePlayerWeaponBank` 0x00455150: every fire
    /// attempt stamps the clock. A weapons-fold hull that is not at set 0 starts folding toward
    /// it and the shot is refused. Returns true when the shot must not be fired.
    public mutating func noteFireAttempt() -> Bool {
        lastFire60 = clock60
        guard config.folds, config.weaponsFold, config.setCount > 1 else { return false }
        resolve()
        if set > 0 {
            direction = -1
            return true
        }
        return false
    }
}

extension World {
    /// Read `ship`'s fold rules from its hull's `shän` (cached per hull type). A ship with no
    /// `shän`, or a world with no galaxy, simply never folds.
    func resolveFoldConfig(_ ship: Ship) {
        guard !ship.fold.configResolved else { return }
        ship.fold.configResolved = true
        if let cached = foldConfigs[ship.shipTypeID] {
            ship.fold.config = cached
            return
        }
        var cfg = HullFoldConfig.none
        if ship.shipTypeID >= 128, let shan = galaxy?.game.shan(ship.shipTypeID) {
            cfg = HullFoldConfig(shan, animations: shipAnimations)
        }
        foldConfigs[ship.shipTypeID] = cfg
        ship.fold.config = cfg
    }

    /// The player's hull unfolds on launch, takeoff and hyperspace arrival (`Stellar_HandleStellarEntryAndExit`
    /// 0x00457580, the jump-fire fragments of `Ship_HandlePlayerShipCore`, `Ship_ResetPlayerShipState`
    /// 0x004b3350): a normal hull from set 0, a weapons-fold hull at its last set.
    public func beginPlayerHullLaunch() {
        resolveFoldConfig(player)
        player.fold.beginLaunch()
    }

    /// The lowest unused ship slot, 1 and up (`Ship_AllocateShipSlotInSystem` 0x004254b0 takes the
    /// first free of 63; the table has no gaps to skip, so the same number comes out of the
    /// occupied set). Slot 0 is the player.
    func lowestFreeShipSlot() -> Int {
        let used = Set(npcs.map { $0.slot })
        var n = 1
        while used.contains(n) { n += 1 }
        return n
    }
}
