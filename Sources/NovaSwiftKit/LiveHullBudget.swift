import Foundation

/// How many hulls the "Full live 3D" presentation may draw at once
/// (docs/HD_PIPELINE.md). Each live hull is a SceneKit render pass of its
/// own, so the count is what the presentation costs.
///
/// Starts from what the device class can afford (`ceiling`) and then follows
/// the frame rate actually achieved: frames running long shed live hulls
/// (those ships draw their baked sprites instead) and a steady frame rate
/// earns them back one at a time. Phones and older Macs therefore settle at
/// whatever they can hold, down to none, without a setting to tune.
public struct LiveHullBudget: Sendable, Equatable {
    /// The most live hulls this device is ever given.
    public let ceiling: Int
    /// Live hulls allowed right now (0…ceiling).
    public private(set) var allowed: Int

    /// Seconds of frames per decision.
    public static let window: Double = 1.0
    /// A window whose average frame takes this much longer than the target sheds hulls.
    public static let slowRatio: Double = 1.2
    /// A window at most this much over target counts as steady.
    public static let steadyRatio: Double = 1.05
    /// Steady windows in a row before one more hull is allowed.
    public static let windowsToGrow = 3

    private var elapsed: Double = 0
    private var frames = 0
    private var steadyWindows = 0

    public init(ceiling: Int) {
        self.ceiling = max(0, ceiling)
        allowed = self.ceiling
    }

    /// The ceiling for a device class.
    /// - Parameters:
    ///   - mobile: phone, tablet, TV box or headset.
    ///   - appleGPU: an Apple-family GPU (Apple silicon, A-series); false
    ///     for Intel/AMD Macs.
    ///   - lowPowerGPU: an integrated GPU on a Mac (`MTLDevice.isLowPower`).
    ///   - memoryGB: physical memory.
    public static func ceiling(mobile: Bool, appleGPU: Bool, lowPowerGPU: Bool, memoryGB: Double) -> Int {
        if mobile { return memoryGB >= 6 ? 6 : (memoryGB >= 3 ? 4 : 2) }
        if !appleGPU { return lowPowerGPU ? 2 : 6 }
        return memoryGB > 8 ? 24 : 10
    }

    /// Feed one frame. `seconds` is the real frame time; `target` the frame
    /// time the player asked for (1/cap), or nil when uncapped (then 1/60).
    /// `inUse` is how many live hulls drew this frame: shedding only ever
    /// goes below what was actually in use, so an idle budget isn't punished
    /// for frames that were slow for other reasons.
    public mutating func frame(seconds: Double, target: Double?, inUse: Int) {
        guard seconds > 0, seconds < 0.5 else { return }   // a hitch (load, jump) isn't a frame rate
        elapsed += seconds
        frames += 1
        guard elapsed >= Self.window else { return }
        let average = elapsed / Double(frames)
        let goal = target ?? 1.0 / 60.0
        elapsed = 0; frames = 0
        if average > goal * Self.slowRatio {
            steadyWindows = 0
            // Shed a quarter of what's drawing (at least one), from what's in use.
            if inUse > 0 { allowed = max(0, min(allowed, inUse) - max(1, inUse / 4)) }
        } else if average <= goal * Self.steadyRatio {
            steadyWindows += 1
            if steadyWindows >= Self.windowsToGrow, allowed < ceiling {
                allowed += 1
                steadyWindows = 0
            }
        } else {
            steadyWindows = 0
        }
    }
}
