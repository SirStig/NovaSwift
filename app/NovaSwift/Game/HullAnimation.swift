import Foundation
import SpriteKit
import NovaSwiftKit

/// Immutable per-hull animation configuration decoded from a `shän`, plus the
/// pure frame-selection / blink math the renderer uses each frame. Mutable
/// per-ship state (turn history, animation + blink clocks, weapon-glow flare)
/// lives on the scene / NPC node, not here.
///
/// The base hull sheet packs `setCount` rotation sets of `framesPerSet` frames.
/// Frame `set*framesPerSet + heading` picks a heading within a set; which set is
/// live depends on `mode` (banking → turn direction, animation → a clock). The
/// engine-glow, running-light and weapon-glow overlays share this exact frame
/// layout (Bible: "same number of frames as base, including banking frames"), so
/// they index with the same `frameIndex(set:heading:)`.
struct HullAnim {
    var framesPerSet = 36
    var setCount = 1
    var mode: ShanRes.ExtraFrames = .none
    var animDelaySec: Double = 1.0 / 30
    var weapDecay = 50
    var blinkMode = 0
    var blink: (a: Int, b: Int, c: Int, d: Int) = (0, 0, 0, 0)
    var hidesLightsWhenDisabled = false

    init() {}
    init(_ shan: ShanRes) {
        framesPerSet = max(1, shan.framesPerSet)
        setCount = max(1, shan.baseSetCount)
        mode = shan.extraFrames
        animDelaySec = Double(max(1, shan.animDelay)) / 30.0
        weapDecay = shan.weapDecay
        blinkMode = shan.blinkMode
        blink = shan.blinkValues
        hidesLightsWhenDisabled = shan.hidesLightsWhenDisabled
    }

    /// Whether this hull has more than the single level-flight set to draw.
    var hasExtraSets: Bool { setCount > 1 && (mode == .banking || mode == .animation) }

    /// Heading frame (0..<framesPerSet) for a world angle (radians, CCW, +y up).
    /// Computed from the true angle so hulls with more than 36 frames/rotation
    /// (e.g. the Leviathan's 64) index their full sheet, not just the first 36.
    func heading(forAngle angle: Double) -> Int {
        let twoPi = 2 * Double.pi
        var a = angle.truncatingRemainder(dividingBy: twoPi)
        if a < 0 { a += twoPi }
        return Int((a / twoPi * Double(framesPerSet)).rounded()) % framesPerSet
    }

    /// Which base sprite set to show. `turnSign`: +1 turning left (CCW), -1 right,
    /// 0 ~straight. `animClock`: seconds accumulated (animation mode only).
    /// Folding / keyCarried aren't wired to their triggers yet, so they draw the
    /// level set (set 0) — no worse than today, and ready to extend.
    func baseSet(turnSign: Int, animClock: Double, disabled: Bool) -> Int {
        guard setCount > 1 else { return 0 }
        // A hulk has no attitude control, so it can't bank and its animation is
        // dead: it always draws the level set, whatever it seems to be doing.
        guard !disabled else { return 0 }
        switch mode {
        case .banking:
            if turnSign > 0 { return min(1, setCount - 1) }   // bank left  = set 1
            if turnSign < 0 { return min(2, setCount - 1) }   // bank right = set 2
            return 0
        case .animation:
            return Int(animClock / animDelaySec) % setCount
        case .none, .folding, .keyCarried:
            return 0
        }
    }

    /// Flat index into a `set*framesPerSet + heading` sheet, clamped to `count`.
    func frameIndex(set: Int, heading: Int, count: Int) -> Int {
        min(max(0, set * framesPerSet + heading), max(0, count - 1))
    }

    /// Running-light opacity (0…1) for a blink clock in seconds. Steady-on for
    /// mode 0/-1 or anything unrecognised. Ticks are 1/30 s (Bible units).
    func lightIntensity(clock: Double) -> CGFloat {
        let t = clock * 30.0
        switch blinkMode {
        case 1:   // square wave: on A, off B, C blinks per group, D gap between groups
            let a = Double(max(1, blink.a)), b = Double(max(0, blink.b))
            let c = Double(max(1, blink.c)), d = Double(max(0, blink.d))
            let blinkLen = a + b
            let groupLen = c * blinkLen + d
            guard groupLen > 0 else { return 1 }
            let phase = t.truncatingRemainder(dividingBy: groupLen)
            if phase >= c * blinkLen { return 0 }             // in the between-groups gap
            return phase.truncatingRemainder(dividingBy: blinkLen) < a ? 1 : 0
        case 2:   // triangle pulse between min(A) and max(C), rise B/100 & fall D/100 per tick
            let mn = Double(max(1, min(blink.a, blink.c)))
            let mx = Double(max(mn + 1, Double(max(blink.a, blink.c))))
            let rise = max(0.01, Double(blink.b) / 100.0)
            let fall = max(0.01, Double(blink.d) / 100.0)
            let upT = (mx - mn) / rise, downT = (mx - mn) / fall
            let period = upT + downT
            guard period > 0 else { return CGFloat(mx / 32.0) }
            let ph = t.truncatingRemainder(dividingBy: period)
            let inten = ph < upT ? mn + rise * ph : mx - fall * (ph - upT)
            return CGFloat(min(32, max(1, inten)) / 32.0)
        case 3:   // random intensity in [A,B], a new value every C ticks
            let mn = Double(max(1, blink.a)), mx = Double(max(blink.a + 1, blink.b))
            let step = Double(max(1, blink.c))
            let bucket = Int(t / step)
            // Deterministic pseudo-random in [0,1) from the bucket index (stateless,
            // so it needs no per-node storage and stays stable within a bucket).
            var x = UInt64(bitPattern: Int64(bucket &* 2654435761 &+ 1013904223))
            x ^= x >> 13; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33
            let r = Double(x % 100_000) / 100_000.0
            return CGFloat(min(32, max(1, mn + r * (mx - mn))) / 32.0)
        default:
            return 1
        }
    }

    /// Per-frame decay factor applied to a weapon-glow flare (0…1): the flare is
    /// set to 1 on firing and multiplied by this each frame. `weapDecay` is the
    /// Bible rate — lower = slower fade (50 ≈ a ~0.4 s tail).
    func weaponGlowDecay(dt: TimeInterval) -> CGFloat {
        let perTick = Double(max(1, weapDecay)) / 100.0   // fraction lost per 1/30 s tick
        let ticks = dt * 30.0
        return CGFloat(pow(max(0.0, 1.0 - perTick), ticks))
    }
}

/// Tracks which way a hull is banking, across frames.
///
/// The sim advances angles on a fixed 30 Hz tick while the scene draws at 60 or
/// 120 Hz, so measuring `(angle - lastAngle) / frameDT` every displayed frame
/// sees a doubled turn rate on the frames a tick landed on and a dead stop on
/// the ones between — which strobes a banking hull between its banked and level
/// sprite sets every single frame. Timing each angle change against how long it
/// has actually been since the angle last *changed*, and holding that verdict
/// over the frames in between, samples the sim's real turn rate instead of the
/// display's.
struct BankTracker {
    private var lastAngle: Double = .nan
    private var age: TimeInterval = 0
    private var sign = 0

    /// How long a frozen heading is allowed to hold its bank before the hull
    /// levels out — comfortably over one 30 Hz tick, so a real stop still reads
    /// as level almost immediately.
    private static let holdSeconds: TimeInterval = 0.05

    mutating func update(angle: Double, dt: TimeInterval) -> Int {
        age += dt
        if angle != lastAngle {
            if lastAngle.isFinite { sign = turnSign(fromAngle: lastAngle, toAngle: angle, dt: age) }
            lastAngle = angle
            age = 0
        } else if age > Self.holdSeconds {
            sign = 0
        }
        return sign
    }
}

/// The signed turn direction from an angle change, with a small deadband so a
/// ship flying straight doesn't jitter between bank sets. +1 = turning left
/// (CCW), -1 = right, 0 = straight. `dt` guards against divide-by-zero.
func turnSign(fromAngle last: Double, toAngle now: Double, dt: TimeInterval) -> Int {
    guard dt > 0, last.isFinite else { return 0 }
    var delta = (now - last).truncatingRemainder(dividingBy: 2 * .pi)
    if delta > .pi { delta -= 2 * .pi }
    if delta < -.pi { delta += 2 * .pi }
    let rate = delta / dt                     // rad/s
    if rate > 0.2 { return 1 }
    if rate < -0.2 { return -1 }
    return 0
}

extension SpriteTextures {
    /// Every frame of a sheet, in packed order (`set*framesPerSet + heading`), so
    /// callers can index banking/animation sets — not just the first rotation set
    /// like `rotationFrames`.
    static func allFrames(from sheet: SpriteSheet) -> [SKTexture] {
        rotationFrames(from: sheet, rotationCount: sheet.frameCount)
    }
}
