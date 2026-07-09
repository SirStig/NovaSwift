import SwiftUI

/// The in-flight communication dialog — a compact panel centered over the
/// dimmed, paused game (mirrors `GameMenuView`'s "small overlay panel"
/// structure), but styled with the same authentic ingredients as `NovaDialog`
/// (Geneva body font via `NovaText`, the amber accent, the title-screen
/// backdrop art as a dark panel texture, the same gradient pill buttons) so
/// it still reads as real EV Nova UI rather than a generic system panel.
/// Doesn't reuse `NovaDialog` itself: that component paints its backdrop
/// full-bleed behind the *entire window*, which was built for pre-flight
/// screens (pilot roster, new-pilot flow) and dominates/obscures the live
/// game when layered over it mid-flight — here the same backdrop texture is
/// clipped to just this small panel instead.
struct HailDialogView: View {
    @EnvironmentObject private var model: AppModel
    let state: HailDialogState
    let portrait: CGImage?
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
                .frame(maxWidth: 380)
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
                    NovaText(state.name, size: 15, color: novaAmber, weight: .bold)
                    if !state.govtLabel.isEmpty {
                        NovaText(state.govtLabel, size: 11, color: state.hostile ? .red : Color(white: 0.65))
                    }
                }
                Spacer(minLength: 0)
            }
            NovaText(state.responseText, size: 13, color: .white)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                button("Greetings", action: onGreetings)
                if showAssistButton {
                    button("Request Assistance", enabled: assistEnabled, action: onRequestAssistance)
                }
                button("Close Channel", isDefault: true, action: onClose)
            }
        }
    }

    // Mirrors `NovaDialog.footerButton` exactly (same Geneva pill style) so
    // every in-game dialog shares one authentic button language.
    private func button(_ title: String, isDefault: Bool = false, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button {
            model.audio.play(.uiSelect)
            action()
        } label: {
            Text(title)
                .font(.custom("Geneva", size: 12))
                .foregroundStyle(!enabled ? Color(white: 0.45) : (isDefault ? .black : .white))
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(
                    Capsule().fill(
                        isDefault
                        ? LinearGradient(colors: [novaAmber, novaAmber.opacity(0.82)],
                                         startPoint: .top, endPoint: .bottom)
                        : LinearGradient(colors: [Color(white: 0.34), Color(white: 0.20)],
                                         startPoint: .top, endPoint: .bottom))
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
