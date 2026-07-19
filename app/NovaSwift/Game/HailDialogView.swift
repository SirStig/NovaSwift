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
        if let portrait {
            Image(decorative: portrait, scale: 1)
                .resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                .frame(width: 200, height: 200)
                .novaPlace(space, 4.5, -100.5)   // item 10: (216,7)-(416,207) 200×200
        }
        NovaText(state.responseText, size: 10, width: 188)
            .novaPlace(space, -200.5, -99.5)     // item 9: (11,8)-(203,66) 192×58
        identifierText(width: 130)
            .novaPlace(space, -171.5, -34.5)     // item 11: (40,73)-(174,119) 134×46

        // Items 2/1/0 top-to-bottom (166×26 each, stacked left column, x=21).
        responseButton("Greetings", width: 140, action: onGreetings, graphics: graphics)
            .novaPlace(space, -190.5, 17.5)      // item 2 (top): (21,125)-(187,151)
        if showAssistButton {
            responseButton("Request Assistance", width: 140, enabled: assistEnabled,
                            action: onRequestAssistance, graphics: graphics)
                .novaPlace(space, -190.5, 45.5)  // item 1 (mid): (21,153)-(187,179)
        }
        responseButton("Close Channel", width: 140, action: onClose, graphics: graphics)
            .novaPlace(space, -190.5, 73.5)      // item 0 (bottom): (21,181)-(187,207)
    }

    // MARK: - Planet comm (DITL #1009, frame 540×295)

    @ViewBuilder
    private func planetContent(_ space: NovaSpace, _ graphics: SpaceportGraphics) -> some View {
        if let portrait {
            // Fill the 310×283 comm box edge-to-edge (the landscape is a wide
            // panorama; `.fit` letterboxed it and left the box mostly empty).
            Image(decorative: portrait, scale: 1)
                .resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                .frame(width: 310, height: 283).clipped()
                .novaPlace(space, -48, -142.5)    // item 4: (222,5)-(532,288) 310×283
        }
        NovaText(state.responseText, size: 10, width: 196)
            .novaPlace(space, -265, -142.5)       // item 3: (5,5)-(205,65) 200×60
        identifierText(width: 116)
            .novaPlace(space, -254, -65.5)        // item 5: (16,82)-(136,132) 120×50

        // Items 1/2/0 top-to-bottom (146×26 each, stacked left column, x=27):
        //  • top: Greetings, or "Request Landing" when clearance isn't granted
        //  • middle: Demand Tribute — the forceful-takeover option, only where
        //    it could actually do something (see `canDemandTribute`)
        //  • bottom: Close Channel
        if planetLandable {
            responseButton(graphics.buttonLabel(SpaceportLabel.greetings, fallback: "Greetings"),
                           width: 120, action: onGreetings, graphics: graphics)
                .novaPlace(space, -243, 36.5)     // item 1 (top): (27,184)-(173,210)
        } else {
            responseButton(graphics.buttonLabel(SpaceportLabel.requestLanding, fallback: "Request Landing"),
                           width: 120, action: onRequestLanding, graphics: graphics)
                .novaPlace(space, -243, 36.5)
        }
        if state.canDemandTribute {
            responseButton(graphics.buttonLabel(SpaceportLabel.demandTribute, fallback: "Demand Tribute"),
                           width: 120, action: onDemandTribute, graphics: graphics)
                .novaPlace(space, -243, 66.5)     // item 2 (middle): (27,214)-(173,240)
        }
        responseButton(graphics.buttonLabel(SpaceportLabel.closeChannel, fallback: "Close Channel"),
                       width: 120, action: onClose, graphics: graphics)
            .novaPlace(space, -243, 96.5)         // item 0 (bottom): (27,244)-(173,270)
    }

    private var planetLandable: Bool { state.landable }

    // MARK: - Shared pieces

    // Frame-pixel `NovaText`, not `.novaFont` roles — this sits inside a
    // `NovaMenu`'s native coordinate space, where the roles' 13–15pt chrome
    // sizes render oversized once the frame is scaled up.
    private func identifierText(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            NovaText(state.name, size: 12, color: novaAmber, width: width, weight: .bold)
            if !state.govtLabel.isEmpty {
                NovaText(state.govtLabel, size: 10,
                         color: state.hostile ? .red : Color(white: 0.75), width: width)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func responseButton(_ title: String, width: CGFloat, enabled: Bool = true,
                                 action: @escaping () -> Void, graphics: SpaceportGraphics) -> some View {
        NovaButton(graphics: graphics, title: title, width: width, enabled: enabled) {
            model.audio.play(.uiSelect)
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
                    fallbackButton("Request Assistance", width: 150, enabled: assistEnabled, action: onRequestAssistance)
                }
                fallbackButton("Close Channel", width: 106, action: onClose)
            }
        }
    }

    @ViewBuilder
    private func fallbackButton(_ title: String, width: CGFloat, enabled: Bool = true,
                                 action: @escaping () -> Void) -> some View {
        // No game data loaded — no button art to decode.
        Button {
            model.audio.play(.uiSelect)
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
