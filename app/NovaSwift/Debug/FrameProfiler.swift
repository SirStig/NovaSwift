import Foundation

/// One phase's cost over a reporting window: the average time it took per frame
/// and the single worst frame it was seen in, both in milliseconds. `id` is the
/// phase name so SwiftUI can list these directly.
struct PerfPhase: Identifiable, Equatable {
    var name: String
    /// Mean milliseconds this phase cost per frame over the window.
    var avgMs: Double
    /// Worst single-frame cost this phase hit during the window, in ms — the
    /// value a smoothed average hides but that reads as a stutter.
    var worstMs: Double
    var id: String { name }
}

/// A tiny, allocation-light windowed frame profiler for the game loop.
///
/// The live performance readout already tells you *that* a frame was slow (fps,
/// average/worst frame ms) and *how much* is on screen (ships, shots, nodes) —
/// but not *which subsystem* ate the frame. This closes that gap: each frame is
/// partitioned into named phases (sim sub-steps fed from the engine, plus the
/// scene's own sync/render phases), and over a window we report each phase's
/// mean and worst cost, sorted by the biggest offender. That's the number that
/// tells you where to go dig.
///
/// Timing uses the monotonic mach clock via `DispatchTime` — cheap enough to
/// wrap every phase, and only ever exercised while the debug suite is attached
/// (the whole thing is inert in normal play, driven from `GameScene` under a
/// `debug != nil` guard).
final class FrameProfiler {

    /// Per-phase accumulation across the current window.
    private struct Accum { var totalMs: Double = 0; var worstMs: Double = 0 }
    private var accum: [String: Accum] = [:]
    /// Stable first-seen order, so a phase doesn't jump around the list between
    /// windows just because a dictionary rehashed.
    private var order: [String] = []
    /// How many frames have been closed (via `endFrame`) since the last flush —
    /// the divisor for turning window totals into per-frame averages.
    private var windowFrames = 0

    /// The phases recorded in the frame currently being built, in call order,
    /// used for per-frame spike capture. Cleared at each `endFrame`.
    private var current: [(name: String, ms: Double)] = []

    // MARK: Recording

    /// Monotonic timestamp in nanoseconds. Pair with `lap` to time a linear
    /// stretch of the loop without a closure.
    @inline(__always) func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Record the stretch from `start` to now under `name`, and return a fresh
    /// timestamp so laps can be chained: `m = lap("a", since: m)`.
    @discardableResult
    func lap(_ name: String, since start: UInt64) -> UInt64 {
        let end = now()
        record(name, seconds: Double(end &- start) / 1_000_000_000)
        return end
    }

    /// Fold one phase sample (in seconds) into the window and the current frame.
    /// This is the sink the engine's sim sub-phases feed through as well.
    func record(_ name: String, seconds: Double) {
        let ms = seconds * 1000
        current.append((name, ms))
        if accum[name] == nil { accum[name] = Accum(); order.append(name) }
        accum[name]!.totalMs += ms
        accum[name]!.worstMs = max(accum[name]!.worstMs, ms)
    }

    /// Close the current frame: count it toward the window and, if its total CPU
    /// time crossed `spikeThresholdMs`, return that frame's phase breakdown
    /// (sorted worst-first) so the caller can log/surface the culprit. Returns
    /// `nil` for an ordinary frame.
    func endFrame(spikeThresholdMs: Double) -> (frameMs: Double, phases: [PerfPhase])? {
        windowFrames += 1
        let frameMs = current.reduce(0) { $0 + $1.ms }
        defer { current.removeAll(keepingCapacity: true) }
        guard frameMs >= spikeThresholdMs else { return nil }
        let phases = current
            .map { PerfPhase(name: $0.name, avgMs: $0.ms, worstMs: $0.ms) }
            .sorted { $0.avgMs > $1.avgMs }
        return (frameMs, phases)
    }

    // MARK: Flush

    /// Snapshot the window as per-frame averages (sorted most-expensive first)
    /// and reset it. Returns `[]` if no frames were recorded since the last call.
    func snapshot() -> [PerfPhase] {
        guard windowFrames > 0 else { reset(); return [] }
        let n = Double(windowFrames)
        let phases = order.compactMap { name -> PerfPhase? in
            guard let a = accum[name] else { return nil }
            return PerfPhase(name: name, avgMs: a.totalMs / n, worstMs: a.worstMs)
        }
        .sorted { $0.avgMs > $1.avgMs }
        reset()
        return phases
    }

    /// Drop all window state (both when flushing and when the profiler is
    /// detached, so a fresh session never inherits stale timings).
    func reset() {
        accum.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        current.removeAll(keepingCapacity: true)
        windowFrames = 0
    }
}

/// Resident memory of this process in megabytes, or 0 if the kernel query
/// fails. Sampled on the throttled report tick — cheap, but not per-frame.
func residentMemoryMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}
