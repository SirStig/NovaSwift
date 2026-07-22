import SwiftUI
#if os(tvOS)
import UIKit

/// tvOS text input for the cursor-driven UI.
///
/// tvOS only accepts text through its fullscreen keyboard, which the system
/// presents when a text field becomes first responder. This app deliberately
/// keeps controls out of the focus engine (the controller cursor is the
/// pointer — see `ControllerCursor.swift`), so an inline SwiftUI `TextField`
/// can never be activated here. Instead, field chrome is a cursor button and
/// this hidden `UITextField` is forced to first responder when `editing`
/// flips true; the accepted text is written back on commit, and a Menu-press
/// cancel (`DidEndEditingReason.cancelled`) leaves the binding untouched.
struct TVTextEntryBridge: UIViewRepresentable {
    @Binding var text: String
    @Binding var editing: Bool
    var placeholder: String = ""
    var keyboardType: UIKeyboardType = .default
    /// Runs after a *committed* entry has been written back (e.g. chat send).
    var onCommit: () -> Void = {}

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.delegate = context.coordinator
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.placeholder = placeholder
        field.keyboardType = keyboardType
        guard editing, !field.isFirstResponder, !coordinator.presenting else { return }
        coordinator.presenting = true
        field.text = text
        // State mutations can't happen inside this view-update pass; the
        // keyboard also can't be presented from it.
        DispatchQueue.main.async {
            // Park the cursor: while the system keyboard owns the screen, the
            // controller's Ⓐ must not fire the hit targets underneath it.
            CursorTargets.shared.suppressed = true
            if !field.becomeFirstResponder() {
                // Couldn't present (shouldn't happen) — never leave the UI
                // soft-locked behind a suppressed cursor and editing == true.
                CursorTargets.shared.suppressed = false
                coordinator.presenting = false
                coordinator.parent.editing = false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TVTextEntryBridge
        /// Guards against double-presentation between the `editing` flip and
        /// the async first-responder grab.
        var presenting = false

        init(_ parent: TVTextEntryBridge) { self.parent = parent }

        func textFieldDidEndEditing(_ field: UITextField,
                                    reason: UITextField.DidEndEditingReason) {
            presenting = false
            CursorTargets.shared.suppressed = false
            let committed = reason == .committed
            if committed { parent.text = field.text ?? "" }
            parent.editing = false
            if committed { parent.onCommit() }
        }
    }
}

extension View {
    /// Attach to a cursor-clickable "field" chrome: when `editing` flips
    /// true, the tvOS fullscreen keyboard opens pre-filled with `text` and
    /// writes the result back on commit.
    func tvTextEntry(text: Binding<String>, editing: Binding<Bool>,
                     placeholder: String = "",
                     keyboardType: UIKeyboardType = .default,
                     onCommit: @escaping () -> Void = {}) -> some View {
        background(
            // Not `hidden()`/zero-sized — a view that isn't in the layout
            // can't become first responder. One transparent point is enough.
            TVTextEntryBridge(text: text, editing: editing,
                              placeholder: placeholder,
                              keyboardType: keyboardType,
                              onCommit: onCommit)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
        )
    }
}

/// Drop-in for a system-styled `TextField` in the cursor-driven tvOS UI:
/// renders as a field-looking cursor button; clicking it opens the fullscreen
/// keyboard. (The authentic-dialog counterpart is `NovaTextField`, which
/// applies the same pattern with the game's field chrome.)
struct TVCursorTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var onCommit: () -> Void = {}
    @State private var editing = false

    var body: some View {
        CursorButton { editing = true } label: {
            HStack(spacing: 8) {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? Color.secondary : .white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "keyboard")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.15)))
            .contentShape(Rectangle())
        }
        .tvTextEntry(text: $text, editing: $editing, placeholder: placeholder,
                     keyboardType: keyboardType, onCommit: onCommit)
    }
}
#endif
