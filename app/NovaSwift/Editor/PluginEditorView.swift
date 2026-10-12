#if os(macOS)
import SwiftUI

/// The Plugin Editor's root screen. Replaces the whole game UI while open
/// (`AppModel.Screen.editor`); see docs/PLUGIN_EDITOR.md.
struct PluginEditorView: View {
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Plugin Editor").font(.largeTitle.weight(.semibold))
            Button("Back to Menu", action: onClose)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
#endif
