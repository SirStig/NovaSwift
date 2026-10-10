import Foundation

/// The per-stellar frame stepper of `Stellar_UpdateStellarSprites` 0x0042cd10.
///
/// Time is the accumulated frame step in 30 Hz ticks. A stellar animates
/// whenever its sheet has more than one frame; `AnimDelay` 0 advances every
/// step. `Flags2` 0x0001 returns to frame 0 between frames (the random pick
/// then skips frame 0), 0x0002 picks the next frame at random without
/// repeating the current one, and 0x1000 (a hypergate) opens up to a
/// transition frame while ships use it and closes again afterwards.
public struct StellarAnimator: Sendable {
    public let frameCount: Int
    public let delay: Int
    public let bias: Int
    public let returnsToFirst: Bool
    public let random: Bool
    public let isGate: Bool
    /// `spöb.CustPicID`: a gate's transition frame when within 1..<count-1.
    public let custPic: Int

    public private(set) var accum: Double = 0
    public private(set) var current = 0
    public private(set) var next = 0

    public init(frameCount: Int, delay: Int, bias: Int, flags2: UInt32, custPic: Int) {
        self.frameCount = frameCount
        self.delay = delay
        self.bias = bias
        returnsToFirst = flags2 & 0x0001 != 0
        random = flags2 & 0x0002 != 0
        isGate = flags2 & 0x1000 != 0
        self.custPic = custPic
    }

    /// A gate's transition frame T.
    public var transitionFrame: Int {
        (custPic >= 1 && custPic < frameCount - 1) ? custPic : frameCount / 2
    }

    /// Advance by `ticks` (30 Hz) and return the frame to show. `engaged` only
    /// matters for a gate. `rand(n)` is a uniform pick in 0..<n.
    public mutating func step(ticks: Double, engaged: Bool, rand: (Int) -> Int) -> Int {
        guard frameCount > 1 else { current = 0; return 0 }
        accum += ticks
        let n = frameCount
        if !isGate {
            let threshold = (current == 0 && bias > 1) ? delay * bias : delay
            guard Double(threshold) <= accum else { return current }
            accum = 0
            if !returnsToFirst {
                current = next
                if !random { next = (next + 1) % n }
                else { repeat { next = rand(n) } while next == current }
            } else if current == 0 {
                current = next
                if !random {
                    next = (next + 1) % n
                    if next == 0 { next += 1 }
                } else {
                    repeat {
                        repeat { next = rand(n) } while next == 0
                    } while next == current
                }
            } else {
                current = 0
            }
            return current
        }
        let t = transitionFrame
        if engaged {
            let threshold = (t == current && bias > 1) ? delay * bias : delay
            guard Double(threshold) <= accum else { return current }
            accum = 0
            if current < t {
                current += 1
                next = current
            } else if !returnsToFirst {
                current = next
                if !random {
                    next = (next + 1) % n
                    if next < t { next = t }
                } else {
                    repeat { next = rand(n - t) + t } while next == current
                }
            } else if t == current {
                current = next
                if !random {
                    next = (next + 1) % n
                    if next < t { next = t + 1 }
                } else {
                    repeat {
                        repeat { next = rand(n - t) + t } while t == next
                    } while next == current
                }
            } else {
                current = t
            }
        } else if Double(delay) <= accum {
            accum = 0
            if current < t {
                if current > 0 { current -= 1 }
            } else if !random {
                if current < n - 1 { current += 1 } else { current = t - 1 }
            } else {
                current = t - 1
            }
        }
        return current
    }
}
