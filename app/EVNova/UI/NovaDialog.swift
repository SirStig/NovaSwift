import SwiftUI
import EVNovaKit

/// Authentic EV Nova dialog chrome for the screens the game itself presents as
/// dialogs over the title backdrop (new-pilot name entry, scenario select) and
/// for the port's own additions (pilot roster, About, Import).
///
/// It is a **true overlay**: a translucent scrim dims whatever UI is already on
/// screen (the real main menu shows through), and the panel — the game's
/// stretchable mission-panel frame (PICTs 8521/8522/8523: metal border, black
/// interior, grey control strip) with three-slice buttons (`NovaButton`) in the
/// strip — floats centred over it. It does **not** paint its own copy of the
/// title screen (which read as a second, emptier background menu).
///
/// The panel is a **fixed `width` and hugs its content's height**. When game
/// graphics aren't available (no data imported / demo), it degrades to a clean
/// dark panel with system-style buttons so the flow still works.
struct NovaDialog<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    var width: CGFloat = 460
    var buttons: [NovaDialogButton]
    @ViewBuilder var content: () -> Content

    private var graphics: SpaceportGraphics? { model.uiGraphics }

    var body: some View {
        ZStack {
            // Scrim over the existing UI — this is a dialog floating over the
            // menu, not a replacement backdrop.
            Color.black.opacity(0.55).ignoresSafeArea()

            // The authentic panel, centred, sized to its content.
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(title).novaFont(.heading, weight: .bold).foregroundStyle(novaAmber)
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 16)

                // Footer buttons live on the panel art's own grey control strip.
                HStack(spacing: 10) {
                    Spacer()
                    ForEach(buttons) { b in footerButton(b) }
                }
                .padding(.horizontal, 16)
                .frame(height: 40)
            }
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(NovaPanelBackground(graphics: graphics))
        }
    }

    /// The game's real three-slice button art when graphics are loaded; a
    /// clean pill fallback (amber for the default action) before data import.
    @ViewBuilder private func footerButton(_ b: NovaDialogButton) -> some View {
        if let graphics {
            NovaButton(graphics: graphics, title: b.title,
                       width: max(50, CGFloat(b.title.count) * 8), enabled: b.enabled) {
                model.audio.play(.uiSelect)
                b.action()
            }
        } else {
            Button { model.audio.play(.uiSelect); b.action() } label: {
                Text(b.title)
                    .novaFont(.button)
                    .foregroundStyle(!b.enabled ? Color(white: 0.45)
                                     : (b.isDefault ? .black : .white))
                    .padding(.horizontal, 18).padding(.vertical, 7)
                    .background(
                        Capsule().fill(
                            b.isDefault
                            ? LinearGradient(colors: [novaAmber, novaAmber.opacity(0.82)],
                                             startPoint: .top, endPoint: .bottom)
                            : LinearGradient(colors: [Color(white: 0.34), Color(white: 0.20)],
                                             startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .disabled(!b.enabled)
        }
    }
}

/// Dialog chrome for the port's own **scrollable, native-control** surfaces
/// (Settings, the Plug-in hub) that can't live inside `NovaDialog`'s
/// content-hugging panel. Like `NovaDialog` it's a **true overlay** — a scrim
/// dims the UI already on screen — but the panel is a **fixed-size centred
/// card** (not a full-window takeover) whose Form/List scrolls inside it, with
/// an amber title header and a Done button on the panel's grey control strip.
struct DialogChrome<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    var onClose: () -> Void = {}
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text(title).novaFont(.heading, weight: .bold).foregroundStyle(novaAmber)
                    Spacer()
                }
                .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 10)

                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                HStack {
                    Spacer()
                    doneButton
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
            }
            // A bounded, centred card — never taller/wider than the window's
            // usable area, so it reads as a dialog over the menu, not a page.
            .frame(width: 660, height: 620)
            .background(NovaPanelBackground(graphics: model.uiGraphics))
        }
    }

    /// The game's real three-slice Done button when data is loaded (matching
    /// every other dialog); a plain amber pill only before any data import.
    @ViewBuilder private var doneButton: some View {
        if let graphics = model.uiGraphics {
            NovaButton(graphics: graphics, title: "Done", width: 60) { onClose() }
        } else {
            Button { onClose() } label: {
                Text("Done").novaFont(.button, weight: .semibold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22).padding(.vertical, 7)
                    .background(Capsule().fill(novaAmber))
            }
            .buttonStyle(.plain)
        }
    }
}

/// The game's own stretchable dialog frame, shared by `NovaDialog` and
/// `DialogChrome`: PICTs 8521 (top cap, 9px), 8522 (middle, stretches with
/// content) and 8523 (bottom cap, 40px — the grey strip footer controls sit
/// on). Native width is 441; small horizontal stretches of the brushed-metal
/// border are imperceptible. Falls back to a plain dark card before data import.
struct NovaPanelBackground: View {
    let graphics: SpaceportGraphics?

    var body: some View {
        if let g = graphics,
           let top = g.pict(8521), let middle = g.pict(8522), let bottom = g.pict(8523) {
            VStack(spacing: 0) {
                Image(decorative: top, scale: 1).resizable().frame(height: 9)
                Image(decorative: middle, scale: 1).resizable()
                Image(decorative: bottom, scale: 1).resizable().frame(height: 40)
            }
        } else {
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.10))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.2)))
        }
    }
}

/// A dialog footer button (authentic three-slice when data is present).
struct NovaDialogButton: Identifiable {
    let id = UUID()
    let title: String
    var isDefault = false
    var enabled = true
    let action: () -> Void
}

/// The EV Nova UI accent used for headings in the port's authentic screens.
let novaAmber = Color(red: 1.0, green: 0.7, blue: 0.28)

/// A Geneva-styled single-line text field matching the game's dialog inputs.
struct NovaTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder)
            .font(.custom(NovaFontRole.body.family, size: NovaFontRole.body.baseSize)).foregroundColor(.secondary))
            .textFieldStyle(.plain)
            .novaFont(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(white: 0.04), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(white: 0.3)))
    }
}

/// A selectable row inside a dialog (scenario / option lists), authentically
/// styled: Geneva text with a highlight bar for the selected row.
struct NovaSelectRow<Detail: View>: View {
    let title: String
    let selected: Bool
    @ViewBuilder var detail: () -> Detail
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    NovaText(title, size: 13, color: selected ? .black : .white, weight: .bold)
                    detail()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? novaAmber : Color(white: 0.14),
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}
