import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

/// A list of real `mïsn` offers at one `MissionOfferLocation`, shared by the
/// Mission BBS and Bar screens (`AvailLoc` 0 and 1 respectively — the two
/// locations the Bible/repo docs call out as the common case). Backed by the
/// actual `StoryEngine` (control-bit gated availability, random-appearance
/// roll, reward text) rather than a placeholder; accepting/declining writes
/// the mutated `PlayerState` straight back to the live pilot.
///
/// This row list is the one embedded by `MissionBBSView`/`BarView` (out of
/// this file's scope) inside their own DITL #1006 "Mission BBS" (PICT 8505)
/// backdrop — those callers already own the frame + scrolling box, so this
/// view only supplies list rows sized to their `width`, matching the row
/// count DITL #1006's list item (`(10,30)-(205,174)`, 195×144 ≈ 16px/row)
/// implies for a ~144pt-tall box. Tapping a row opens the real accept/refuse
/// popup — DITL #1012 "Mission Info" for the mission computer, DITL #1016
/// "Single Mission" for the bar (a lone patron's offer, no browsing list) —
/// both verified against `novaswift-extract dlog/ditl` and their frame PICTs.
struct MissionBoardView: View {
    let game: NovaGame
    @ObservedObject var pilot: PilotStore
    let spob: SpobRes
    let location: MissionOfferLocation
    var width: CGFloat = 300

    @StateObject private var services = AppGameServices()
    @State private var engine: StoryEngine?
    @State private var offered: [MissionRes] = []
    @State private var graphics: SpaceportGraphics?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if offered.isEmpty {
                NovaText("No missions available at this time.", size: 11, color: Color(white: 0.6),
                          width: width, align: .leading)
            } else {
                ForEach(offered, id: \.id) { mission in
                    Button { engine?.present(mission) } label: {
                        HStack(spacing: 6) {
                            NovaText(engine?.resolvedName(for: mission) ?? mission.displayName, size: 11, width: width - 65, align: .leading)
                            Spacer(minLength: 0)
                            NovaText(creditsLabel(mission.pay), size: 11,
                                     color: Color(red: 1, green: 0.85, blue: 0.4), width: 60, align: .trailing)
                        }
                        .padding(.vertical, 2.5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear(perform: buildEngine)
        .sheet(isPresented: Binding(get: { services.pendingOffer != nil },
                                    set: { if !$0 { services.pendingOffer = nil } })) {
            if let offer = services.pendingOffer, let graphics {
                switch location {
                case .missionComputer:
                    MissionInfoSheet(graphics: graphics, offer: offer, offered: offered,
                                      onSelect: { engine?.present($0) },
                                      onAccept: { accept(offer) }, onDecline: { decline(offer) })
                case .bar:
                    MissionSingleDialog(graphics: graphics, offer: offer, offered: offered,
                                        onPage: { engine?.present($0) },
                                        onAccept: { accept(offer) }, onDecline: { decline(offer) })
                // persShip/mainSpaceport/tradeCenter/shipyard/outfitter/unknown: no dedicated
                // authentic sheet yet (this view only ever gets instantiated at .missionComputer
                // or .bar today) — fall back to the mission-computer style so an offer is never
                // silently dropped if one of these locations is ever wired up.
                default:
                    MissionInfoSheet(graphics: graphics, offer: offer, offered: offered,
                                      onSelect: { engine?.present($0) },
                                      onAccept: { accept(offer) }, onDecline: { decline(offer) })
                }
            }
        }
    }

    private func buildEngine() {
        let e = StoryEngine(game: game, player: pilot.state, services: services,
                            seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
        engine = e
        offered = e.missionsOffered(at: location, spob: spob.id)
        if graphics == nil { graphics = SpaceportGraphics(game: game) }
    }

    private func accept(_ offer: MissionOffer) {
        guard let engine else { return }
        _ = engine.accept(offer.mission.id)
        pilot.state = engine.player
        pilot.save()
        services.pendingOffer = nil
        offered = engine.missionsOffered(at: location, spob: spob.id)
    }

    private func decline(_ offer: MissionOffer) {
        guard let engine else { return }
        engine.decline(offer.mission.id)
        pilot.state = engine.player
        services.pendingOffer = nil
    }
}

/// Formats a credit amount the way every spaceport screen does ("1,234 cr").
private func creditsLabel(_ n: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    return (f.string(from: NSNumber(value: n)) ?? "\(n)") + " cr"
}

// MARK: - Frame containers

/// A backdrop PICT drawn at its own native pixel size (unlike `NovaMenu`,
/// which scales its frame to the shared 1024×768 spaceport-hub reference) —
/// right for a `.sheet`, which gets its own native-sized window/panel rather
/// than overlaying the hub. Children are positioned with the same
/// `NovaSpace`/`.novaPlace` convention as every other authentic screen.
private struct MissionPictFrame<Content: View>: View {
    let image: CGImage
    @ViewBuilder var content: (NovaSpace) -> Content

    var body: some View {
        let space = NovaSpace(width: CGFloat(image.width), height: CGFloat(image.height))
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).interpolation(.high).resizable()
                .frame(width: space.width, height: space.height)
            content(space)
        }
        .frame(width: space.width, height: space.height)
        // Native pixel size would overflow a compact iPhone sheet; cap it.
        .shrinkToFitViewport()
    }
}

/// The three-slice resizable frame DITL #1016 "Single Mission" draws itself
/// on — PICTs 8521/8522/8523 ("Mission offer (upper/middle/lower)"), each
/// 441px wide (verified via `novaswift-extract pict`: 441×9, 441×365, 441×40).
/// The middle slice stretches to fill whatever height the briefing text
/// needs, the same way `NovaButtonStyle` stretches a button's middle cap
/// horizontally.
private struct MissionThreeSliceFrame<Content: View>: View {
    let top: CGImage
    let middle: CGImage
    let bottom: CGImage
    let width: CGFloat
    let height: CGFloat
    let topHeight: CGFloat
    let bottomHeight: CGFloat
    @ViewBuilder var content: (NovaSpace) -> Content

    var body: some View {
        let space = NovaSpace(width: width, height: height)
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                slice(top, topHeight)
                slice(middle, height - topHeight - bottomHeight)
                slice(bottom, bottomHeight)
            }
            content(space)
        }
        .frame(width: width, height: height)
        .shrinkToFitViewport()
    }

    private func slice(_ image: CGImage, _ h: CGFloat) -> some View {
        Image(decorative: image, scale: 1).interpolation(.high).resizable()
            .frame(width: width, height: max(h, 0))
    }
}

// MARK: - Mission Info (mission computer)

/// The mission-computer accept/refuse popup — DITL #1012 "Mission Info",
/// bounds `(40,40)-(511,195)` = 471×155, confirmed exact against PICT #8517
/// "Mission Info" (`novaswift-extract pict` → 471×155, no stale-bounds
/// correction needed here). Item #5 (`(177,222)-(232,259)`) falls outside
/// that 155pt-tall frame in every reading of the DITL and is left unrendered
/// — likely a vestigial/unused item, not a real control.
///
/// Item #1's 195×84 list (left column, under the `(13,1)-(206,13)` title —
/// both centered on x≈106.5) re-browses the other offers at this location
/// without leaving the popup; item #3's 242×91 pane (right column, over the
/// accept button — both centered on x≈339.5) is the selected offer's
/// briefing text.
private struct MissionInfoSheet: View {
    let graphics: SpaceportGraphics
    let offer: MissionOffer
    let offered: [MissionRes]
    let onSelect: (MissionRes) -> Void
    let onAccept: () -> Void
    let onDecline: () -> Void

    /// PICT #8517 "Mission Info" — 471×155, matches the DLOG bounds exactly.
    private static let pictID = 8517

    var body: some View {
        Group {
            if let image = graphics.pict(Self.pictID) {
                MissionPictFrame(image: image) { space in
                    // item 2: (13,1)-(206,13) 193x12 — selected mission's title
                    NovaText(offer.title, size: 11, width: 193, align: .leading, weight: .bold)
                        .novaPlace(space, -222.5, -76.5)
                    // item 6: (343,4)-(465,16) 122x12 — its reward
                    NovaText(creditsLabel(offer.mission.pay), size: 11,
                             color: Color(red: 1, green: 0.85, blue: 0.4), width: 122, align: .trailing)
                        .novaPlace(space, 107.5, -73.5)
                    // item 1: (9,24)-(204,108) 195x84 — other offers here
                    offersList.novaPlace(space, -226.5, -53.5)
                    // item 3: (218,26)-(460,117) 242x91 — briefing text
                    ScrollView(showsIndicators: false) {
                        NovaText(offer.briefingText, size: 10, width: 242, align: .leading)
                    }
                    .frame(width: 242, height: 91)
                    .novaPlace(space, -17.5, -51.5)
                    // item 4: (57,125)-(156,150) 99x25 — refuse
                    if offer.canRefuse {
                        NovaButton(graphics: graphics, title: offer.refuseButton, width: 73, action: onDecline)
                            .novaPlace(space, -178.5, 47.5)
                    }
                    // item 0: (290,125)-(389,150) 99x25 — accept
                    NovaButton(graphics: graphics, title: offer.acceptButton, width: 73,
                               enabled: offer.canAccept, action: onAccept)
                        .novaPlace(space, 54.5, 47.5)
                }
            } else {
                fallback
            }
        }
    }

    private var offersList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(offered, id: \.id) { mission in
                    Button { onSelect(mission) } label: {
                        NovaText(mission.displayName, size: 10,
                                 color: mission.id == offer.mission.id ? .white : Color(white: 0.6),
                                 width: 191, align: .leading)
                            .padding(.vertical, 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 195, height: 84)
    }

    /// Data present but no frame PICT decoded (e.g. running on data missing
    /// Nova Graphics 3) — a plain fallback so the flow still works.
    private var fallback: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(offer.title).novaFont(.heading)
            ScrollView { Text(offer.briefingText).novaFont(.body).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                if offer.canRefuse { Button(offer.refuseButton, action: onDecline) }
                Spacer()
                Button(offer.acceptButton, action: onAccept).buttonStyle(.borderedProminent)
                    .disabled(!offer.canAccept)
            }
        }
        .padding(20)
        .frame(width: 380, height: 280)
        .novaResponsive()
    }
}

// MARK: - Single Mission (bar)

/// The bar's accept/decline popup — DITL #1016 "Single Mission", drawn on
/// the three-slice PICTs 8521-8523 (an existing code comment flagged these
/// as the right frame; confirmed by name via `novaswift-extract list ... PICT`
/// and by their 441px-wide decode matching the DITL's item extents). The
/// bar offers one mission at a time (no browsing list, unlike the mission
/// computer) so the frame is just the briefing pane plus accept/decline.
///
/// The DLOG's printed bounds (441×317) are too short for its own items —
/// items #3/#4/#6/#7 (all ~32×32 "paging" icons) fall 6-52pt below y=317,
/// the same stale-bounds pattern documented for #1000/1002/1004/1005/1013.
/// Rather than invent an unverified taller frame for those four, this view
/// uses the 317pt height every OTHER item is consistent with, and pages
/// between multiple simultaneous bar offers with items #8/#9 instead — two
/// 23×23 icons that already sit inside that frame, to the right of the
/// button row.
struct MissionSingleDialog: View {
    let graphics: SpaceportGraphics
    let offer: MissionOffer
    let offered: [MissionRes]
    let onPage: (MissionRes) -> Void
    let onAccept: () -> Void
    let onDecline: () -> Void

    private static let upperID = 8521, middleID = 8522, lowerID = 8523
    private static let frameWidth: CGFloat = 441
    private static let frameHeight: CGFloat = 317
    private static let topHeight: CGFloat = 9
    private static let bottomHeight: CGFloat = 40

    private var index: Int? { offered.firstIndex { $0.id == offer.mission.id } }

    // Rendered as a full-screen overlay at the shared 1024×768 reference scale
    // (like every NovaMenu dialog), so the patron's offer stacks over the bar
    // at its true relative size instead of appearing in a native sheet.
    var body: some View {
        GeometryReader { geo in
            let scale = novaFrameScale(frame: CGSize(width: Self.frameWidth, height: Self.frameHeight),
                                       viewport: geo.size)
            frameBody
                .scaleEffect(scale)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    @ViewBuilder private var frameBody: some View {
        Group {
            if let top = graphics.pict(Self.upperID), let middle = graphics.pict(Self.middleID),
               let bottom = graphics.pict(Self.lowerID) {
                MissionThreeSliceFrame(top: top, middle: middle, bottom: bottom,
                                        width: Self.frameWidth, height: Self.frameHeight,
                                        topHeight: Self.topHeight, bottomHeight: Self.bottomHeight) { space in
                    // item 2: (12,9)-(427,276) 415x267 — briefing pane
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 5) {
                            NovaText(offer.title, size: 11, width: 411, align: .leading, weight: .bold)
                            NovaText(offer.briefingText, size: 10, width: 411, align: .leading)
                        }
                        .padding(.top, 2).padding(.leading, 2)
                    }
                    .frame(width: 415, height: 267)
                    .novaPlace(space, -208.5, -149.5)

                    if offer.canRefuse {
                        // item 1: (117,285)-(216,310) — refuse, paired with item 0
                        NovaButton(graphics: graphics, title: offer.refuseButton, width: 73, action: onDecline)
                            .novaPlace(space, -103.5, 126.5)
                        // item 0: (225,285)-(324,310) — accept, paired with item 1
                        NovaButton(graphics: graphics, title: offer.acceptButton, width: 73,
                                   enabled: offer.canAccept, action: onAccept)
                            .novaPlace(space, 4.5, 126.5)
                    } else {
                        // item 5: (173,285)-(272,310) — accept, centered (no refuse)
                        NovaButton(graphics: graphics, title: offer.acceptButton, width: 73,
                                   enabled: offer.canAccept, action: onAccept)
                            .novaPlace(space, -47.5, 126.5)
                    }

                    if offered.count > 1, let index {
                        // item 8: (340,287)-(363,310) 23x23 — previous offer
                        pageButton(system: "chevron.left", enabled: index > 0) {
                            onPage(offered[index - 1])
                        }
                        .novaPlace(space, 119.5, 128.5)
                        // item 9: (373,287)-(396,310) 23x23 — next offer
                        pageButton(system: "chevron.right", enabled: index < offered.count - 1) {
                            onPage(offered[index + 1])
                        }
                        .novaPlace(space, 152.5, 128.5)
                    }
                }
            } else {
                fallback
            }
        }
    }

    private func pageButton(system: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? .white : Color(white: 0.35))
                .frame(width: 23, height: 23)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var fallback: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(offer.title).novaFont(.heading)
            ScrollView { Text(offer.briefingText).novaFont(.body).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                if offer.canRefuse { Button(offer.refuseButton, action: onDecline) }
                Spacer()
                Button(offer.acceptButton, action: onAccept).buttonStyle(.borderedProminent)
                    .disabled(!offer.canAccept)
            }
        }
        .padding(20)
        .frame(width: 380, height: 280)
        .novaResponsive()
    }
}
