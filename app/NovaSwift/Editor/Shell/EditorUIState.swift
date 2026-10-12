#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// Small cross-view UI signals that don't belong in the document model.
@MainActor
final class EditorUIState: ObservableObject {
    /// Bumped by ⌘F to focus the resource-list search field.
    @Published var searchTick = 0
    /// Bumped by "Show references" so the inspector opens its popover.
    @Published var refsTick = 0
    /// Resource waiting for the renumber sheet.
    @Published var renumberTarget: ResourceKey?
    /// Inspector shows the hex editor instead of the form/special editor.
    @Published var rawMode = false
    /// Field the form should scroll to after navigating from a lint issue.
    @Published var focusField: String?
}
#endif
