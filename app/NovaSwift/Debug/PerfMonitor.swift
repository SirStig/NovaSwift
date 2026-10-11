import Foundation
import os
import Darwin

/// Always-on runtime health log, cheap enough to leave running in every build.
///
/// Every five seconds of play it writes one `Perf` line: frame rate, average
/// and worst frame, hitches, memory footprint, thread count, the HD layer's
/// size, and the events that cause visible trouble — HD art built on demand
/// (pop-in) and cache evictions. Watch it in Xcode's console or with
/// `log stream --predicate 'subsystem == "com.novaswift.app" && category == "Perf"'`.
/// HD preparation and evictions are also signposted, so they line up with
/// frame drops in Instruments (Points of Interest / os_signpost).
final class PerfMonitor: @unchecked Sendable {
    static let shared = PerfMonitor()
    static let signposter = OSSignposter(subsystem: Log.subsystem, category: .pointsOfInterest)

    /// A frame slower than this reads as a stutter.
    static let hitchMs = 25.0
    private static let window: TimeInterval = 5

    private let lock = NSLock()
    private var windowStart: TimeInterval = 0
    private var frames = 0
    private var totalMs = 0.0
    private var worstMs = 0.0
    private var hitches = 0
    private var onDemand: [Int] = []
    /// CPU work per frame (update → didFinishUpdate), the real headroom
    /// measure — the frame interval just sits at the display's refresh rate.
    private var workStart: UInt64 = 0
    private var workMs: [Double] = []
    private var evictions: [String] = []

    /// Once per rendered frame, from the scene's update.
    func frame(seconds raw: TimeInterval, at now: TimeInterval) {
        guard raw > 0, raw < 2 else { return }   // first frame / returning from the background
        let ms = raw * 1000
        lock.lock()
        if windowStart == 0 { windowStart = now }
        frames += 1; totalMs += ms; worstMs = max(worstMs, ms)
        if ms > Self.hitchMs { hitches += 1 }
        let due = now - windowStart >= Self.window
        lock.unlock()
        if due { flush(now: now) }
    }

    /// Bracket the scene's own per-frame work: call at the top of `update`
    /// and from `didFinishUpdate` (after actions, physics and constraints).
    func beginWork() { workStart = DispatchTime.now().uptimeNanoseconds }
    func endWork() {
        guard workStart != 0 else { return }
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- workStart) / 1_000_000
        workStart = 0
        lock.lock(); workMs.append(ms); lock.unlock()
    }

    /// HD art that wasn't ready when first drawn (the classic art showed instead).
    func noteHDOnDemand(spriteID: Int) {
        lock.lock(); onDemand.append(spriteID); lock.unlock()
        Self.signposter.emitEvent("HD on demand", "sprite \(spriteID)")
    }

    func noteEviction(_ what: String) {
        lock.lock(); evictions.append(what); lock.unlock()
        Self.signposter.emitEvent("Evict", "\(what)")
    }

    private func flush(now: TimeInterval) {
        lock.lock()
        let n = frames, avg = frames > 0 ? totalMs / Double(frames) : 0, worst = worstMs, h = hitches
        let span = now - windowStart
        let pops = onDemand, evicted = evictions, work = workMs.sorted()
        windowStart = now; frames = 0; totalMs = 0; worstMs = 0; hitches = 0; onDemand = []; evictions = []; workMs = []
        lock.unlock()

        let fps = span > 0 ? Double(n) / span : 0
        let hd = HDGraphics.shared.stats()
        var line = String(format: "%.1f fps, avg %.1f ms, worst %.1f ms, %d hitch(es) >%.0f ms | mem %d MB, %d threads",
                          fps, avg, worst, h, Self.hitchMs, Self.footprintMB(), Self.threadCount())
        if !work.isEmpty {
            let mean = work.reduce(0, +) / Double(work.count)
            let p99 = work[min(work.count - 1, Int(Double(work.count) * 0.99))]
            line += String(format: " | CPU work avg %.2f ms, p99 %.2f ms, worst %.2f ms (%.0f%% of frame)",
                           mean, p99, work.last!, avg > 0 ? mean / avg * 100 : 0)
        }
        if hd.enabled {
            line += String(format: " | HD %d sheet(s) %d MB, %d on GPU", hd.sheets, hd.atlasMB, hd.textureSheets)
        }
        if !pops.isEmpty { line += " | HD built on demand: \(pops.map(String.init).joined(separator: ","))" }
        if !evicted.isEmpty { line += " | evicted: \(evicted.joined(separator: "; "))" }
        if !pops.isEmpty || h > 0 || !evicted.isEmpty {
            Log.perf.notice("\(line, privacy: .public)")
        } else {
            Log.perf.info("\(line, privacy: .public)")
        }
    }

    /// Physical memory charged to the app (what the OS judges it by).
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                      vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }
}
