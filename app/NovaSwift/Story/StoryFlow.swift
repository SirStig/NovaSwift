import SwiftUI
import NovaSwiftStory

// The flow-row model and `buildStoryFlow` live in NovaSwiftStory (StoryFlowLayout.swift,
// shared with the Godot Story Map); this file keeps only the SwiftUI presentation of a
// connector.

extension StoryConnector {
    var tint: Color {
        switch self {
        case .onSuccess, .onAccept, .onComplete: return EVTheme.accent
        case .onRefuse:                           return Color(red: 1.0, green: 0.6, blue: 0.15)
        case .onFailure, .onAbort:                return EVTheme.fail
        case .random:                             return EVTheme.purple
        case .unlocks, .start, .then:             return .gray
        }
    }

    /// Icon for the connector pill (nil for quiet connectors).
    var symbol: String? {
        switch self {
        case .start, .then:                       return nil
        case .onSuccess, .onAccept, .onComplete:  return "checkmark"
        case .onRefuse:                           return "arrow.triangle.branch"
        case .onFailure, .onAbort:                return "xmark.octagon.fill"
        case .unlocks:                            return "lock.open.fill"
        case .random:                             return "sparkles"
        }
    }
}
