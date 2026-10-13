import Foundation
import NovaSwiftKit

// `DevEntityRef` and `DevLogLinking` moved to NovaSwiftKit/DebugEntityRef.swift (shared with the
// Godot debug suite); only the SF Symbol mapping stays app-side.
extension DevEntityRef {
    var systemImage: String {
        switch self {
        case .ship: return "airplane"
        case .spob: return "globe.americas.fill"
        }
    }
}
