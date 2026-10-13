import Foundation
import NovaSwiftKit

// `PerfPhase` and `FrameProfiler` moved to NovaSwiftKit/FrameProfiler.swift (shared with the
// Godot debug suite); only the Apple-specific memory probe stays here.

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
