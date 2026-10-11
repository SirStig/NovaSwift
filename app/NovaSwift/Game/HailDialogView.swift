import SwiftUI

/// The in-flight communication dialog (ship hail / planet comm), overlaid on the
/// dimmed, paused game — built from the real decoded game assets:
///
/// - **Ship hail** uses DLOG/DITL #1007 "Communications", frame PICT 8511
///   (423×215, confirmed by decoding the PICT itself — the DLOG's own bounds
///   rect agrees here). Only items 0/1/2 (the 3 stacked response buttons),
///   9 (message text), 10 (200×200 portrait box) and 11 (identifier text) fall
///   inside that 215px-tall frame; items 3–8 sit far past it (down to y=360) and
///   are unused/vestigial in this resource (neither "Negotiation" #1008 nor
///   "Plunder Dialog" #1011 — Nova's real name for those flows — so they aren't
///   a second live sub-layout of this dialog, just dead DITL entries).
/// - **Planet comm** uses DLOG/DITL #1009 "Planet Comm", frame PICT 8512
///   (540×295 — DLOG bounds, PICT size and DITL item bounding box all agree):
///   a header text box, a small identifier box, a big 310×283 picture panel,
///   and 3 stacked ~146×26 action buttons — of which this dialog only ever
///   drives 2 (no "assist" concept for a planet).
///
/// Every button is the real three-slice art (`NovaButton`, PICTs 7500–7508)
/// the spaceport screens already use, positioned via `NovaSpace`/`.novaPlace`
/// straight from the DITL item rects (see `NovaMenu.swift`).
struct HailDialogView: View {
    @EnvironmentObject private var model: AppModel
    let state: HailDialogState
    let portrait: CGImage?
    /// The current session's graphics, for `NovaButton`'s three-slice art and
    /// the real frame PICTs. Nil only in the no-game-data demo path, where the
    /// dialog falls back to a plain generic card so the flow still works.
    let graphics: SpaceportGraphics?
    let showAssistButton: Bool
    let assistEnabled: Bool
    var onGreetings: () -> Void
    var onRequestAssistance: () -> Void
    /// Planet-hail actions: ask for landing clearance (shown in place of
    /// Greetings when clearance isn't granted) and demand tribute (attempt to
    /// dominate the stellar). Default no-ops so ship hails ignore them.
    var onRequestLanding: () -> Void = {}
    var onDemandTribute: () -> Void = {}
    var onClose: () -> Void

    private static let shipFrameID = 8511    // PICT "Communications" (DITL #1007)
    private static let planetFrameID = 8512  // PICT "Planet Communications" (DITL #1009)

    private var isPlanet: Bool { if case .planet = state.kind { return true }; return false }
    private var frameID: Int { isPlanet ? Self.planetFrameID : Self.shipFrameID }
    private var frameImage: CGImage? { graphics?.pict(frameID) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            #if !os(tvOS)
            // The comm window's key shortcuts (0x0047fa40): Return, E and Esc
            // close the channel, R requests assistance, G says greetings.
            Group {
                Button("") { onClose() }.keyboardShortcut(.defaultAction)
                Button("") { onClose() }.keyboardShortcut(.cancelAction)
                Button("") { onClose() }.keyboardShortcut("e", modifiers: [])
                Button("") { if !isPlanet, showAssistButton, assistEnabled { onRequestAssistance() } }
                    .keyboardShortcut("r", modifiers: [])
                Button("") { onGreetings() }.keyboardShortcut("g", modifiers: [])
            }
            .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
            #endif

            if let graphics, let frameImage {
                // NovaMenu does its own GeometryReader-based scaling against the
                // shared 1024×768 reference space (matching the spaceport
                // dialogs) — no `.novaResponsive()` here, that would double-scale.
                NovaMenu(frame: frameImage, overlay: true) { space in
                    if isPlanet { planetContent(space, graphics) } else { shipContent(space, graphics) }
                }
            } else {
                fallbackPanel
                    .padding(20)
                    .frame(maxWidth: 400)
                    .background {
                        ZStack {
                            Color(white: 0.08)
                            if let backdrop = model.uiGraphics?.pict(8000) {
                                Image(decorative: backdrop, scale: 1)
                                    .resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                                    .opacity(0.18)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(novaAmber.opacity(0.35)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .novaResponsive()
            }
        }
    }

    // MARK: - Ship hail (DITL #1007, frame 423×215)

    @ViewBuilder
    private func shipContent(_ space: NovaSpace, _ graphics: SpaceportGraphics) -> some View {
        // Rects from DITL #1007 (stock rects as fallback), so a plug-in's
        // replacement layout takes effect.
        let d = DITLPlacement(graphics.game, 1007, window: space.size)
        if let portrait {
            let box = d.rect(10, top: 7, left: 216, bottom: 207, right: 416)   // 200×200
            Image(decorative: portrait, scale: 1)
                .resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                .frame(width: box.width, height: box.height)
                .ditlPlace(space, d, box)
        }
        let text = d.rect(9, top: 8, left: 11, bottom: 66, right: 203)
        NovaText(state.responseText, size: 10, width: max(0, text.width - 4))
            .ditlPlace(space, d, text)
        let ident = d.rect(11, top: 73, left: 40, bottom: 119, right: 174)
        identifierText(width: max(0, ident.width - 4))
            .ditlPlace(space, d, ident)

        // Items 2/1/0 top-to-bottom (166×26 each, stacked left column, x=21).
        let top = d.rect(2, top: 125, left: 21, bottom: 151, right: 187)
        responseButton("Greetings", rect: top, action: onGreetings, graphics: graphics)
            .ditlPlace(space, d, top)
        if showAssistButton {
            let mid = d.rect(1, top: 153, left: 21, bottom: 179, right: 187)
            responseButton(state.assistTitle, rect: mid, enabled: assistEnabled,
                            action: onRequestAssistance, graphics: graphics)
                .ditlPlace(space, d, mid)
        }
        let bottom = d.rect(0, top: 181, left: 21, bottom: 207, right: 187)
        responseButton("Close Channel", rect: bottom, closes: true, action: onClose, graphics: graphics)
            .ditlPlace(space, d, bottom)
    }

    // MARK: - Planet comm (DITL #1009, frame 540×295)

    @ViewBuilder
    private func planetContent(_ space: NovaSpace, _ graphics: SpaceportGraphics) -> some View {
        let d = DITLPlacement(graphics.game, 1009, window: space.size)
        if let portrait {
            // Fill the 310×283 comm box edge-to-edge (the landscape is a wide
            // panorama; `.fit` letterboxed it and left the box mostly empty).
            let box = d.rect(4, top: 5, left: 222, bottom: 288, right: 532)
            Image(decorative: portrait, scale: 1)
                .resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                .frame(width: box.width, height: box.height).clipped()
                .ditlPlace(space, d, box)
        }
        let text = d.rect(3, top: 5, left: 5, bottom: 65, right: 205)
        NovaText(state.responseText, size: 10, width: max(0, text.width - 4))
            .ditlPlace(space, d, text)
        let ident = d.rect(5, top: 82, left: 16, bottom: 132, right: 136)
        identifierText(width: max(0, ident.width - 4))
            .ditlPlace(space, d, ident)
        let top = d.rect(1, top: 184, left: 27, bottom: 210, right: 173)
        let mid = d.rect(2, top: 214, left: 27, bottom: 240, right: 173)
        let bottom = d.rect(0, top: 244, left: 27, bottom: 270, right: 173)

        // Items 1/2/0 are always shown (0x004a0f90):
        //  • top: Greetings, or Offer Bribe where landing is refused (the
        //    `forgivingLanding` enhancement's Request Landing stands in when
        //    only its own gates refuse)
        //  • middle: Demand Tribute, or Release on a dominated world
        //  • bottom: Close Channel
        responseButton(state.topButtonTitle, rect: top,
                       action: state.topButtonTitle == requestLandingTitle(graphics) ? onRequestLanding : onGreetings,
                       graphics: graphics)
            .ditlPlace(space, d, top)
        if state.tributeVisible {
            responseButton(state.tributeTitle, rect: mid, enabled: state.tributeEnabled,
                           action: onDemandTribute, graphics: graphics)
                .ditlPlace(space, d, mid)
        }
        responseButton(graphics.buttonLabel(SpaceportLabel.closeChannel, fallback: "Close Channel"),
                       rect: bottom, closes: true, action: onClose, graphics: graphics)
            .ditlPlace(space, d, bottom)
    }

    private func requestLandingTitle(_ graphics: SpaceportGraphics) -> String {
        graphics.buttonLabel(SpaceportLabel.requestLanding, fallback: "Request Landing")
    }

    // MARK: - Shared pieces

    // Frame-pixel `NovaText`, not `.novaFont` roles — this sits inside a
    // `NovaMenu`'s native coordinate space, where the roles' 13–15pt chrome
    // sizes render oversized once the frame is scaled up.
    private func identifierText(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            NovaText(state.name, size: 12, color: novaAmber, width: width, weight: .bold)
            if !state.govtLabel.isEmpty {
                NovaText(state.govtLabel, size: 10,
                         color: Color(white: 0.75), width: width)
            }
            if let status = state.statusText {
                NovaText(status, size: 10, color: state.statusHostile ? .red : Color(white: 0.75), width: width)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func responseButton(_ title: String, rect: CGRect, enabled: Bool = true, closes: Bool = false,
                                 action: @escaping () -> Void, graphics: SpaceportGraphics) -> some View {
        NovaButton(graphics: graphics, title: title, ditl: rect, enabled: enabled) {
            // The comm windows sound snd 151 for their action buttons
            // (0x0047e470, 0x00480030) and snd 152 as they close.
            model.audio.play(closes ? .beep3 : .beep2)
            action()
        }
    }

    // MARK: - Fallback (no game data loaded — demo path)

    private var fallbackPanel: some View {
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
                fallbackButton("Greetings", width: 76, action: onGreetings)
                if showAssistButton {
                    fallbackButton(state.assistTitle, width: 150, enabled: assistEnabled, action: onRequestAssistance)
                }
                fallbackButton("Close Channel", width: 106, closes: true, action: onClose)
            }
        }
    }

    @ViewBuilder
    private func fallbackButton(_ title: String, width: CGFloat, enabled: Bool = true, closes: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        // No game data loaded — no button art to decode.
        Button {
            model.audio.play(closes ? .beep3 : .beep2)
            action()
        } label: {
            Text(title).novaFont(.button).foregroundStyle(.white)
                .frame(width: 26 + width, height: 25)
                .background(Color(white: 0.25), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.novaPlain)
        .disabled(!enabled)
    }
}
