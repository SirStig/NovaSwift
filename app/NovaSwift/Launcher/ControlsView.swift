import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Full, rebindable keyboard controls (EV Nova scheme). Tap a key to rebind it,
/// then press the new key. Escape cancels. Works with any hardware keyboard
/// (Mac, iPad). Touch/controller play doesn't need these but they persist.
struct ControlsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var capturing: GameAction?

    var body: some View {
        List {
            Section {
                Text("Tap a key to rebind, then press the new key — or hold a modifier alone, like Control (Esc cancels). These match EV Nova's scheme and drive keyboard play.")
                    .novaFont(.caption).foregroundStyle(.secondary)
            }
            ForEach(GameAction.Category.allCases) { category in
                Section(category.rawValue) {
                    ForEach(actions(in: category)) { action in
                        row(action)
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    model.bindings.resetToDefaults()
                    model.commitBindings()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .novaResponsive()
        .navigationTitle("Controls")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .focusable()
        .onKeyPress(phases: .down) { press in
            guard let action = capturing else { return .ignored }
            let token = KeyToken.from(press)
            if token == "escape" || token.isEmpty { capturing = nil; return .handled }
            model.bindings.rebind(action, to: token)
            model.commitBindings()
            capturing = nil
            return .handled
        }
        #if os(macOS)
        // A bare modifier tap (e.g. Control, the real-EV-Nova default for
        // "fire secondary weapon") never reaches `onKeyPress` above — see
        // `ModifierFlagsBridge`'s doc comment — so it's captured here instead.
        .background {
            if capturing != nil { ModifierFlagsBridge(onChange: captureModifier) }
        }
        #endif
    }

    #if os(macOS)
    private func captureModifier(_ flags: NSEvent.ModifierFlags) {
        guard let action = capturing, let token = bareModifierToken(flags) else { return }
        model.bindings.rebind(action, to: token)
        model.commitBindings()
        capturing = nil
    }
    #endif

    private func actions(in category: GameAction.Category) -> [GameAction] {
        GameAction.allCases.filter { $0.category == category }
    }

    private func row(_ action: GameAction) -> some View {
        HStack {
            Text(action.title).novaFont(.body)
            Spacer()
            Button {
                capturing = (capturing == action) ? nil : action
            } label: {
                Text(capturing == action ? "Press a key…" : KeyToken.label(model.bindings.token(for: action)))
                    .novaFont(.hud, weight: .semibold)
                    .foregroundStyle(capturing == action ? Color.accentColor : .primary)
                    .frame(minWidth: 64)
                    .padding(.vertical, 5).padding(.horizontal, 10)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(capturing == action ? Color.accentColor : .white.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
    }
}
