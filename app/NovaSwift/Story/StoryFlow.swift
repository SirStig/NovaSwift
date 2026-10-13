import SwiftUI
import NovaSwiftStory

// The flow-row model and `buildStoryFlow` live in NovaSwiftStory (StoryFlowLayout.swift,
// shared with the Godot Story Map); this file keeps only the SwiftUI presentation of a
// connector.

extension StoryConnector {
    var tint: Color {
        switch self {
        case .onSuccess, .onAccept, .onComplete: return EVTheme.accent
        case .onRefuse:                           return .orange
        case .onFailure, .onAbort:                return .red
        case .random:                             return Color(red: 0.72, green: 0.55, blue: 0.98)
        case .unlocks, .start, .then:             return .gray
        }
    }

    /// Icon for the connector pill (nil for quiet connectors).
    var symbol: String? {
        switch self {
        case .start, .then:                       return nil
        case .onSuccess, .onAccept, .onComplete:  return "checkmark"
        case .onRefuse:                           return "arrow.uturn.left"
        case .onFailure, .onAbort:                return "xmark"
        case .unlocks:                            return "lock.open"
        case .random:                             return "dice"
        }
    }
}
