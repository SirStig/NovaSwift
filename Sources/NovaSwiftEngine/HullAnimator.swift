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
    public func baseSet(turnSign: Int, animClock: Double, disabled: Bool, carriesKeyShip: Bool = false) -> Int {
        guard setCount > 1 else { return 0 }
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
            return 0
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
