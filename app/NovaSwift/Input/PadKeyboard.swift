import SwiftUI

/// A controller-drivable on-screen keyboard for platforms without one.
///
/// tvOS has the system fullscreen keyboard (see `TVTextEntry.swift`), but a
/// player driving an iPhone/iPad/Mac build with a gamepad has no way to type
/// without reaching for the screen or a real keyboard. Cursor-clicking a
/// `NovaTextField` while a pad is connected opens this overlay instead: a
/// key grid of cursor targets, plus suggestion chips (e.g. random pilot
/// names) so common entries need no typing at all.
///
/// One request at a time, presented at the `RootView` level (over any dialog,
/// under the cursor overlay) via `AppModel.padKeyboard`.
struct PadKeyboardRequest: Identifiable {
    let id = UUID()
    var title: String
    var text: String
    /// Optional provider for the suggestion chips row ("predictive" entries —
    /// tap one to accept it, reroll for a fresh set).
    var suggestions: (() -> [String])?
    var onCommit: (String) -> Void
}

struct PadKeyboardView: View {
    @EnvironmentObject private var model: AppModel
    let request: PadKeyboardRequest

    @State private var text: String
    @State private var shifted = true
    @State private var suggestions: [String]

    init(request: PadKeyboardRequest) {
        self.request = request
        _text = State(initialValue: request.text)
        _suggestions = State(initialValue: request.suggestions?() ?? [])
    }

    private let letterRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]
    private let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    var body: some View {
        ZStack {
            // Scrim: also a cursor target, so Ⓐ outside the panel cancels.
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .cursorClickable { cancel() }

            VStack(spacing: 14) {
                Text(request.title)
                    .novaFont(.heading, weight: .bold)
                    .foregroundStyle(novaAmber)

                // The entry line, with a soft caret.
                HStack(spacing: 2) {
                    Text(text.isEmpty ? " " : text)
                        .novaFont(.body, size: 20)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Rectangle().fill(novaAmber).frame(width: 2, height: 22)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color(white: 0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(white: 0.3)))

                if !suggestions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { s in
                            key(s, wide: true) { text = s }
                        }
                        key("↻") { suggestions = request.suggestions?() ?? [] }
                    }
                }

                VStack(spacing: 6) {
                    HStack(spacing: 6) { ForEach(digits, id: \.self) { c in key(c) { type(c) } } }
                    ForEach(letterRows, id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(row, id: \.self) { c in
                                let display = shifted ? c.uppercased() : c
                                key(display) { type(display) }
                            }
                            if row.first == "z" {
                                key("⌫") { if !text.isEmpty { text.removeLast() } }
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        key(shifted ? "⇧ ABC" : "⇧ abc", wide: true) { shifted.toggle() }
                        key("Space", wide: true) { type(" ") }
                        key("-") { type("-") }
                        key("'") { type("'") }
                        key("Clear", wide: true) { text = "" }
                    }
                }

                HStack(spacing: 12) {
                    footer("Cancel", prominent: false) { cancel() }
                    footer("Done", prominent: true) {
                        request.onCommit(text)
                        model.padKeyboard = nil
                    }
                }
                .padding(.top, 2)
            }
            .padding(22)
            .frame(width: 560)
            .background(Color(red: 0.07, green: 0.07, blue: 0.1),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(novaAmber.opacity(0.4)))
            // Its own scale container: keys register where they're drawn.
            .cursorScaleEffect(keyboardScale)
        }
    }

    private var keyboardScale: CGFloat {
        #if os(tvOS)
        1.5
        #else
        1.0
        #endif
    }

    private func type(_ s: String) {
        text += s
        // Auto-downshift after the first letter, like a name field expects;
        // shift back up after a space (new word).
        if s == " " { shifted = true } else if s.first?.isLetter == true { shifted = false }
    }

    private func cancel() {
        model.padKeyboard = nil
    }

    private func key(_ label: String, wide: Bool = false,
                     action: @escaping () -> Void) -> some View {
        CursorButton {
            model.audio.play(.uiSelect)
            action()
        } label: {
            Text(label)
                .novaFont(.body, weight: .semibold, size: 16)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, wide ? 12 : 0)
                .frame(minWidth: wide ? 0 : 40, minHeight: 40)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.14)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.novaPlain)
    }

    private func footer(_ title: String, prominent: Bool,
                        action: @escaping () -> Void) -> some View {
        CursorButton {
            model.audio.play(.uiSelect)
            action()
        } label: {
            Text(title)
                .novaFont(.button, weight: .semibold, size: 16)
                .foregroundStyle(prominent ? .black : .white)
                .padding(.horizontal, 26).padding(.vertical, 9)
                .background(Capsule().fill(prominent ? AnyShapeStyle(novaAmber)
                                                     : AnyShapeStyle(Color.white.opacity(0.12))))
        }
        .buttonStyle(.novaPlain)
    }
}
