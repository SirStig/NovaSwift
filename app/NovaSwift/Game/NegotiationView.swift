import SwiftUI
import EVNovaKit

/// The in-flight "Negotiation" dialog — `DLOG`/`DITL` #1008 in `Nova.rez`,
/// verified with `evnova-extract dlog/ditl "data/EV Nova/Nova.rez" 1008`:
///
///     DLOG #1008  bounds=(40,40)-(302,147)  262x107
///     DITL #1008 "Negotiation"
///       [2] (  7,  6)-(255, 31) 248x25  userItem  [disabled]   ← static message
///       [1] ( 58, 39)-(204, 65) 146x26  userItem                ← button (top)
///       [0] ( 58, 74)-(204,100) 146x26  userItem                ← button (bottom)
///
/// The backdrop is real game art: PICT #8514 "Haggle" in
/// `Nova Graphics 3.rez` decodes to exactly 262×107 — the same size as the
/// DLOG bounds, confirming it (not a guess) as this dialog's frame. Every
/// item is a custom-drawn `userItem` — the black bar at the top of the PICT
/// is empty in the art; item [2]'s text is drawn at runtime, same as the
/// button labels.
///
/// EV Nova reuses this exact 2-button-plus-message shape for more than one
/// negotiation flavour (the resource fork doesn't record which `STR# 150`
/// pair belongs to which call site — these are all drawn at runtime by the
/// original engine, not stored). The clearest fit for a dialog literally
/// named "Negotiation" is the ship-to-ship comm exchange with a hostile:
/// `STR# 150` indices 24-25, "Offer Bribe" / "Beg For Mercy", are adjacent
/// and read as a coherent pair (unlike the also-plausible but
/// non-adjacent mission-pay-haggle pair "Demand More"/"Accept Price",
/// indices 29-30). Both button slots are the same width (146px) in the
/// real layout, wide enough for either pair, so the labels are left as
/// parameters rather than hardcoded — whichever caller wires this up passes
/// the pair that fits its scenario.
struct NegotiationView: View {
    /// Nil in the no-game-data path — falls back to plain chrome, same
    /// degrade-gracefully behavior as `HailDialogView`.
    let graphics: SpaceportGraphics?
    /// The line drawn into item [2]'s black bar — the opponent's demand or
    /// response ("Pay us 2,500 credits and we'll let you go.").
    let message: String
    /// Item [1] (top button).
    let primaryLabel: String
    var primaryEnabled: Bool = true
    /// Item [0] (bottom button).
    let secondaryLabel: String
    var secondaryEnabled: Bool = true
    var onPrimary: () -> Void
    var onSecondary: () -> Void
    /// Tapping outside the panel — mirrors `HailDialogView`'s "tap outside
    /// closes" behavior; the real DLOG has `goAway=false` (no title-bar
    /// close box), so this is the only non-button dismissal.
    var onDismiss: () -> Void

    /// PICT #8514 "Haggle" (`Nova Graphics 3.rez`) — not added to
    /// `SpaceportGraphics.Frame` per instructions; a local constant instead.
    private static let framePictID = 8514
    private static let frameSize = CGSize(width: 262, height: 107)

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            if let graphics, let frame = graphics.pict(Self.framePictID) {
                NovaMenu(frame: frame, overlay: true) { space in
                    NovaText(message, size: 11, width: 248)
                        .frame(height: 25, alignment: .leading)
                        .novaPlace(space, 7 - Self.frameSize.width / 2, 6 - Self.frameSize.height / 2)
                    NovaButton(graphics: graphics, title: primaryLabel, width: 120, enabled: primaryEnabled, action: onPrimary)
                        .novaPlace(space, 58 - Self.frameSize.width / 2, 39 - Self.frameSize.height / 2)
                    NovaButton(graphics: graphics, title: secondaryLabel, width: 120, enabled: secondaryEnabled, action: onSecondary)
                        .novaPlace(space, 58 - Self.frameSize.width / 2, 74 - Self.frameSize.height / 2)
                }
            } else {
                fallbackPanel
            }
        }
        .novaResponsive()
    }

    // MARK: Fallback (no loaded PICT/button art — demo/no-data path)

    private var fallbackPanel: some View {
        VStack(spacing: 14) {
            Text(message).novaFont(.body).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            fallbackButton(primaryLabel, enabled: primaryEnabled, action: onPrimary)
            fallbackButton(secondaryLabel, enabled: secondaryEnabled, action: onSecondary)
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(novaAmber.opacity(0.35)))
    }

    private func fallbackButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).novaFont(.button).foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 25)
                .background(Color(white: 0.25), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Previews

#Preview("Bribe a hostile") {
    NegotiationView(
        graphics: nil,
        message: "Pay us 2,500 credits and we'll let you go.",
        primaryLabel: "Offer Bribe", primaryEnabled: true,
        secondaryLabel: "Beg For Mercy", secondaryEnabled: true,
        onPrimary: {}, onSecondary: {}, onDismiss: {})
    .frame(width: 900, height: 650)
    .preferredColorScheme(.dark)
}

#Preview("Mission pay haggle") {
    NegotiationView(
        graphics: nil,
        message: "500 credits is our final offer for this run.",
        primaryLabel: "Demand More", primaryEnabled: true,
        secondaryLabel: "Accept Price", secondaryEnabled: true,
        onPrimary: {}, onSecondary: {}, onDismiss: {})
    .frame(width: 900, height: 650)
    .preferredColorScheme(.dark)
}
