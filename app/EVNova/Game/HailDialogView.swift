import SwiftUI

/// The in-flight communication dialog — a compact panel centered over the
/// dimmed, paused game (mirrors `GameMenuView`'s "small overlay panel"
/// structure). Built from the real decoded game assets, not invented chrome:
/// Geneva text (`NovaText`), the amber accent, and — critically — the actual
/// three-slice button art (`NovaButton`, PICTs 7500–7508) the spaceport
/// screens already use, not hand-drawn `Capsule` buttons.
///
/// EV Nova's own comm dialog is native OS dialog chrome in the source data —
/// there's no dedicated "dialog panel" PICT to point at (confirmed against
/// the Nova Bible; the only real custom art inside these dialogs is the
/// buttons and the per-hail portrait). So the panel background here is
/// necessarily an approximation (a dark, amber-bordered card using the
/// title-screen texture at low opacity, the same texture `NovaDialog` uses)
/// — but every *drawable* element (buttons, text, portrait) is real game art.
struct HailDialogView: View {
    @EnvironmentObject private var model: AppModel
    let state: HailDialogState
    let portrait: CGImage?
    /// The current session's graphics, for `NovaButton`'s three-slice art.
    /// Nil only in the no-game-data demo path, where buttons fall back to a
    /// plain style so the flow still works (mirrors `NovaDialog`'s own
    /// documented degrade-gracefully behavior).
    let graphics: SpaceportGraphics?
    let showAssistButton: Bool
    let assistEnabled: Bool
    var onGreetings: () -> Void
    var onRequestAssistance: () -> Void
    var onClose: () -> Void

    private var backdrop: CGImage? { model.uiGraphics?.pict(8000) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            panel
                .padding(20)
                .frame(maxWidth: 400)
                .background {
                    ZStack {
                        Color(white: 0.08)
                        if let backdrop {
                            Image(decorative: backdrop, scale: 1)
                                .resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                                .opacity(0.18)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(novaAmber.opacity(0.35)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .novaResponsive()
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                if let portrait {
                    Image(decorative: portrait, scale: 1)
                        .resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                        .frame(width: 84, height: 84)
                        .background(Color.black.opacity(0.4))
                        .overlay(Rectangle().strokeBorder(.white.opacity(0.2)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.name).novaFont(.heading, weight: .bold).foregroundStyle(novaAmber)
                    if !state.govtLabel.isEmpty {
                        Text(state.govtLabel).novaFont(.caption)
                            .foregroundStyle(state.hostile ? .red : Color(white: 0.65))
                    }
                }
                Spacer(minLength: 0)
            }
            Text(state.responseText).novaFont(.body).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                button("Greetings", width: 76, action: onGreetings)
                if showAssistButton {
                    button("Request Assistance", width: 150, enabled: assistEnabled, action: onRequestAssistance)
                }
                button("Close Channel", width: 106, action: onClose)
            }
        }
    }

    @ViewBuilder
    private func button(_ title: String, width: CGFloat, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        if let graphics {
            NovaButton(graphics: graphics, title: title, width: width, enabled: enabled) {
                model.audio.play(.uiSelect)
                action()
            }
        } else {
            // No game data loaded (demo path) — no button art to decode.
            Button {
                model.audio.play(.uiSelect)
                action()
            } label: {
                Text(title).novaFont(.button).foregroundStyle(.white)
                    .frame(width: 26 + width, height: 25)
                    .background(Color(white: 0.25), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
    }
}
