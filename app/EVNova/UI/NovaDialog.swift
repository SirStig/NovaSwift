import SwiftUI
import EVNovaKit

/// Authentic EV Nova dialog chrome for the screens the game itself presents as
/// dialogs over the title backdrop (new-pilot name entry, scenario select) and
/// for the port's own additions (the multi-save pilot roster). Everything is
/// drawn from the player's data: the title background PICT 8000 behind a centred
/// panel, the game's three-slice buttons (`NovaButton`, PICTs 7500–7508) and its
/// Geneva body font (`NovaText`).
///
/// When game graphics aren't available (no data imported / demo), it degrades to
/// a clean dark panel with system buttons so the flow still works.
struct NovaDialog<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    var width: CGFloat = 460
    var buttons: [NovaDialogButton]
    @ViewBuilder var content: () -> Content

    private var graphics: SpaceportGraphics? { model.uiGraphics }
    private var backdrop: CGImage? { graphics?.pict(8000) }

    var body: some View {
        ZStack {
            // The whole dialog is one cohesive dark surface that fills the sheet —
            // a heavily-dimmed title screen as texture, never a band across a
            // competing backdrop.
            Rectangle().fill(Color(white: 0.08)).ignoresSafeArea()
            if let backdrop {
                Image(decorative: backdrop, scale: 1)
                    .resizable().interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .opacity(0.14)
                    .ignoresSafeArea()
            }

            // Content in a centred, readable column; the surface behind is full-bleed.
            VStack(alignment: .leading, spacing: 16) {
                NovaText(title, size: 15, color: novaAmber, weight: .bold)
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 10) {
                    Spacer()
                    ForEach(buttons) { b in footerButton(b) }
                }
            }
            .padding(28)
            .frame(maxWidth: width)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // A clean EV-Nova-style pill button: grey (or amber for the default action),
    // Geneva label. (The data's three-slice PICT button art currently mis-decodes
    // to magenta, so dialogs use this reliable style until that PICT bug is fixed.)
    private func footerButton(_ b: NovaDialogButton) -> some View {
        Button { model.audio.play(.uiSelect); b.action() } label: {
            Text(b.title)
                .font(.custom("Geneva", size: 12))
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
            .font(.custom("Geneva", size: 13)).foregroundColor(.secondary))
            .textFieldStyle(.plain)
            .font(.custom("Geneva", size: 13))
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
