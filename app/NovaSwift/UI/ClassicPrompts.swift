import SwiftUI
import NovaSwiftKit

/// The original's two small modal prompts, in the native window chrome:
/// DLOG/DITL 3001 "Text Input" (prompt text, edit field, OK / Cancel; the
/// answer is limited to 64 characters and a leading "the " is dropped,
/// `nv_ShowPrompt` 0x00497900) and 3002 "YesNo" (prompt text, OK / Cancel).
/// With modern dialog chrome they fall back to the system alert.
extension View {
    func classicTextPrompt(isPresented: Binding<Bool>, prompt: String, text: Binding<String>,
                           onOK: @escaping (String) -> Void, onCancel: @escaping () -> Void) -> some View {
        modifier(ClassicPromptModifier(isPresented: isPresented, prompt: prompt, text: text,
                                       okTitle: nil, cancelTitle: nil, fit: true, onOK: { onOK($0 ?? "") }, onCancel: onCancel))
    }

    func classicConfirm(isPresented: Binding<Bool>, prompt: String, okTitle: String? = nil,
                        cancelTitle: String? = nil, fit: Bool = true, onOK: @escaping () -> Void,
                        onCancel: @escaping () -> Void = {}) -> some View {
        modifier(ClassicPromptModifier(isPresented: isPresented, prompt: prompt, text: nil,
                                       okTitle: okTitle, cancelTitle: cancelTitle, fit: fit,
                                       onOK: { _ in onOK() }, onCancel: onCancel))
    }
}

/// What `nv_ShowPrompt` stores: at most 64 bytes, a leading "the " removed.
func classicPromptAnswer(_ s: String) -> String {
    var t = s
    if t.lowercased().hasPrefix("the ") { t = String(t.dropFirst(4)) }
    return t
}

private struct ClassicPromptModifier: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    let prompt: String
    var text: Binding<String>?
    let okTitle: String?
    let cancelTitle: String?
    /// False inside a small frame: draw at natural size instead of fitting the screen.
    let fit: Bool
    let onOK: (String?) -> Void
    let onCancel: () -> Void

    private var classic: Bool { !model.settings.modernDialogs && model.data.game != nil }

    private func ok() {
        if let text {
            // Over 64 bytes: beep and stay open.
            guard text.wrappedValue.utf8.count <= 64 else { model.audio.play(.uiError); return }
            isPresented = false
            onOK(classicPromptAnswer(text.wrappedValue))
        } else {
            isPresented = false
            onOK(nil)
        }
    }

    private func cancel() { isPresented = false; onCancel() }

    func body(content: Content) -> some View {
        if classic {
            content.overlay {
                if isPresented {
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                        ClassicDITLDialog(
                            game: model.data.game, graphics: model.uiGraphics,
                            id: text == nil ? 3002 : 3001,
                            fallbackSize: CGSize(width: 354, height: 140),
                            fixedScale: fit ? nil : 1,
                            texts: [2: prompt],
                            edits: text.map { [4: $0] } ?? [:],
                            actions: text == nil ? [0: ok, 4: cancel] : [0: ok, 5: cancel],
                            buttonTitles: [0: okTitle, (text == nil ? 4 : 5): cancelTitle]
                                .compactMapValues { $0 },
                            defaultItem: 0, cancelItem: text == nil ? 4 : 5)
                    }
                    .transition(.opacity)
                }
            }
        } else {
            content.alert(prompt, isPresented: $isPresented) {
                if let text { TextField("", text: text) }
                Button(okTitle ?? "OK", action: ok)
                Button(cancelTitle ?? "Cancel", role: .cancel, action: cancel)
            }
        }
    }
}
