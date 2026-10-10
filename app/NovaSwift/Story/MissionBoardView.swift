import SwiftUI
import AVKit
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

    @EnvironmentObject private var appModel: AppModel

    @StateObject private var services = AppGameServices()
    @State private var engine: StoryEngine?
    @State private var offered: [MissionRes] = []
    @State private var graphics: SpaceportGraphics?
    @State private var showStoryGuide = false
    @State private var storyGuideFocusKey: String?
    /// The offer whose destination the player asked to see on the chart, and a
    /// throwaway `NavigationModel` to render it with. The map is a read-only
    /// preview here — plotting a course on it goes nowhere, since the player is
    /// standing in a spaceport.
    @State private var mapPreview: DestinationPreviewTarget?
    @StateObject private var mapNav = NavigationModel(game: nil, startSystemID: 128)

    /// Storyline tag per mission id, from the table prewarmed once per data
    /// set at load time (`GameDataController.prewarm()`) — powers the
    /// "continues the X storyline" badge on offer rows and the offer dialog.
    private var storylineTags: [Int: MissionStorylineTag] {
        appModel.settings.showMissionStorylineTags ? appModel.data.storylineTags : [:]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if offered.isEmpty {
                NovaText("No missions available at this time.", size: 11, color: Color(white: 0.6),
                          width: width, align: .leading)
            } else {
                ForEach(offered, id: \.id) { mission in
                    HStack(spacing: 4) {
                        Button { present(mission) } label: {
                            HStack(spacing: 6) {
                                NovaText(engine?.resolvedName(for: mission) ?? mission.displayName, size: 11, width: width - 65, align: .leading)
                                Spacer(minLength: 0)
                                NovaText(mission.pay.creditsAbbreviated, size: 11,
                                         color: Color(red: 1, green: 0.85, blue: 0.4), width: 60, align: .trailing)
                            }
                            .padding(.vertical, 2.5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.novaPlain)
                        if let tag = storylineTags[mission.id] {
                            StorylineTagBadge(title: tag.title) { openStoryline(tag.key) }
                        }
                    }
                }
            }
        }
        .overlay { StoryTextOverlay(services: services) }
        .onAppear(perform: buildEngine)
        .storylineGuideSheet(isPresented: $showStoryGuide, game: game, player: { pilot.state },
                             storylineKey: storyGuideFocusKey)
        .sheet(item: $mapPreview) { target in
            GalaxyMapView(nav: mapNav, pilot: pilot,
                          onJump: {},                       // read-only preview: nowhere to jump from a spaceport
                          onClose: { mapPreview = nil },
                          fullscreen: appModel.settings.fullscreenGalaxyMap,
                          destinationPreview: .init(systemID: target.systemID, label: target.label))
        }
        .sheet(isPresented: Binding(get: { services.pendingOffer != nil },
                                    set: { if !$0 { services.pendingOffer = nil } })) {
            if let offer = services.pendingOffer, let graphics {
                let tag = storylineTags[offer.mission.id]
                switch location {
                case .missionComputer:
                    MissionInfoSheet(graphics: graphics, offer: offer, offered: offered,
                                      resolvedName: { engine?.resolvedName(for: $0) ?? $0.displayName },
                                      onSelect: { present($0) },
                                      onAccept: { accept(offer) }, onDecline: { decline(offer) },
                                      storylineTag: tag, onOpenStoryline: tag.map { t in { openStoryline(t.key) } },
                                      onShowDestination: showDestinationAction(for: offer))
                case .bar:
                    MissionSingleDialog(graphics: graphics, offer: offer, offered: offered,
                                        onPage: { present($0) },
                                        onAccept: { accept(offer) }, onDecline: { decline(offer) },
                                        storylineTag: tag, onOpenStoryline: tag.map { t in { openStoryline(t.key) } },
                                        onShowDestination: showDestinationAction(for: offer))
                // persShip/mainSpaceport/tradeCenter/shipyard/outfitter/unknown: no dedicated
                // authentic sheet yet (this view only ever gets instantiated at .missionComputer
                // or .bar today) — fall back to the mission-computer style so an offer is never
                // silently dropped if one of these locations is ever wired up.
                default:
                    MissionInfoSheet(graphics: graphics, offer: offer, offered: offered,
                                      resolvedName: { engine?.resolvedName(for: $0) ?? $0.displayName },
                                      onSelect: { present($0) },
                                      onAccept: { accept(offer) }, onDecline: { decline(offer) },
                                      storylineTag: tag, onOpenStoryline: tag.map { t in { openStoryline(t.key) } },
                                      onShowDestination: showDestinationAction(for: offer))
                }
            }
        }
    }

    private func buildEngine() {
        let e = StoryEngine(game: game, player: pilot.state, services: services,
                            seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
        engine = e
        offered = list(e)
        if graphics == nil { graphics = SpaceportGraphics(game: game) }
        // The preview chart needs a nav model anchored at the port we're standing
        // on, so "you are here" and the hyperspace web read correctly.
        let here = game.systems().first { $0.spobs.contains(spob.id) }?.id ?? pilot.state.currentSystem
        mapNav.configure(game: game, startSystemID: here)
    }

    /// The offer's Map command with its preselected system: only mïsn Flags
    /// 0x0100 marks the destination (0x00442510 button 4); nil otherwise.
    private func showDestinationAction(for offer: MissionOffer) -> (() -> Void)? {
        guard let sys = engine?.offerHighlightSystem(for: offer.mission) else { return nil }
        let label = game.system(sys)?.displayName ?? ""
        return { mapPreview = DestinationPreviewTarget(systemID: sys, label: label) }
    }

    /// The landing's mission-computer list (fixed at landing, compacted by
    /// accepts) or, for any other location, the live list.
    private func list(_ e: StoryEngine) -> [MissionRes] {
        location == .missionComputer ? e.missionComputerList(spob: spob.id)
            : e.missionsOffered(at: location, spob: spob.id)
    }

    /// Present an offer; a can't-refuse one with no offer text activates
    /// silently, so the pilot is written back either way.
    private func present(_ mission: MissionRes) {
        guard let engine else { return }
        if !engine.present(mission) {
            pilot.state = engine.player
            pilot.save()
            offered = list(engine)
        }
    }

    private func openStoryline(_ key: String) {
        storyGuideFocusKey = key
        showStoryGuide = true
    }

    private func accept(_ offer: MissionOffer) {
        guard let engine else { return }
        _ = engine.accept(offer.mission.id)
        pilot.state = engine.player
        pilot.save()
        services.pendingOffer = nil
        offered = list(engine)
    }

    private func decline(_ offer: MissionOffer) {
        guard let engine else { return }
        engine.decline(offer.mission.id)
        pilot.state = engine.player
        services.pendingOffer = nil
    }
}

/// A small chart pin beside a mission offer's title: the offer window's Map
/// command, shown only for missions whose mïsn Flags 0x0100 preselect their
/// destination system on the starmap (0x00442510), as in the original.
struct DestinationMapBadge: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(red: 0.55, green: 0.82, blue: 1.0))
        }
        .buttonStyle(.novaPlain)
        .accessibilityLabel("Show destination on the galaxy map")
        .help("Show this mission's destination on the galaxy map")
    }
}

/// One "show this offer's destination" request — `Identifiable` so it can drive
/// a `.sheet(item:)` and carry which system to point the chart at.
private struct DestinationPreviewTarget: Identifiable {
    let systemID: Int
    let label: String
    var id: Int { systemID }
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
    /// Resolves a listed mission's `<…>` wildcards (`<DST>` etc.) for the row
    /// labels — the raw `mïsn` name still carries them.
    let resolvedName: (MissionRes) -> String
    let onSelect: (MissionRes) -> Void
    let onAccept: () -> Void
    let onDecline: () -> Void
    var storylineTag: MissionStorylineTag? = nil
    var onOpenStoryline: (() -> Void)? = nil
    /// Opens the galaxy map on this job's destination. Nil when the mission has
    /// nowhere to send the player.
    var onShowDestination: (() -> Void)? = nil

    /// PICT #8517 "Mission Info" — 471×155, matches the DLOG bounds exactly.
    private static let pictID = 8517

    var body: some View {
        Group {
            if let image = graphics.pict(Self.pictID) {
                // Rects resolve through DITL #1012 (stock rects as fallback).
                let d = DITLPlacement(graphics.game, 1012, frame: image)
                MissionPictFrame(image: image) { space in
                    // item 2: (13,1)-(206,13) 193x12 — selected mission's title
                    let title = d.rect(2, top: 1, left: 13, bottom: 13, right: 206)
                    HStack(spacing: 4) {
                        NovaText(offer.title, size: 11, width: max(0, title.width - 30),
                                 align: .leading, weight: .bold)
                        if let onShowDestination { DestinationMapBadge(action: onShowDestination) }
                        if let storylineTag, let onOpenStoryline {
                            StorylineTagBadge(title: storylineTag.title, action: onOpenStoryline)
                        }
                    }
                    .frame(width: title.width, alignment: .leading)
                    .ditlPlace(space, d, title)
                    // item 6: (343,4)-(465,16) 122x12 — its reward
                    let reward = d.rect(6, top: 4, left: 343, bottom: 16, right: 465)
                    NovaText(offer.mission.pay.creditsAbbreviated, size: 11,
                             color: Color(red: 1, green: 0.85, blue: 0.4), width: reward.width, align: .trailing)
                        .ditlPlace(space, d, reward)
                    // item 1: (9,24)-(204,108) 195x84 — other offers here
                    let list = d.rect(1, top: 24, left: 9, bottom: 108, right: 204)
                    offersList(list.size).ditlPlace(space, d, list)
                    // item 3: (218,26)-(460,117) 242x91 — briefing text
                    let brief = d.rect(3, top: 26, left: 218, bottom: 117, right: 460)
                    ScrollView(showsIndicators: false) {
                        NovaText(offer.briefingText, size: 10, width: brief.width, align: .leading)
                    }
                    .cursorScrollable()
                    .frame(width: brief.width, height: brief.height)
                    .ditlPlace(space, d, brief)
                    // item 4: (57,125)-(156,150) 99x25 — refuse
                    if offer.canRefuse {
                        let refuse = d.rect(4, top: 125, left: 57, bottom: 150, right: 156)
                        NovaButton(graphics: graphics, title: offer.refuseButton, ditl: refuse, action: onDecline)
                            .ditlPlace(space, d, refuse)
                    }
                    // item 0: (290,125)-(389,150) 99x25 — accept
                    let accept = d.rect(0, top: 125, left: 290, bottom: 150, right: 389)
                    // Always live: a failed activation shows its no-room text
                    // and closes the window (0x0043f100, 0x004a1670).
                    NovaButton(graphics: graphics, title: offer.acceptButton, ditl: accept, action: onAccept)
                        .ditlPlace(space, d, accept)
                }
            } else {
                fallback
            }
        }
    }

    private func offersList(_ size: CGSize) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(offered, id: \.id) { mission in
                    Button { onSelect(mission) } label: {
                        NovaText(resolvedName(mission), size: 10,
                                 color: mission.id == offer.mission.id ? .white : Color(white: 0.6),
                                 width: max(0, size.width - 4), align: .leading)
                            .padding(.vertical, 1)
                    }
                    .buttonStyle(.novaPlain)
                }
            }
        }
        .cursorScrollable()
        .frame(width: size.width, height: size.height)
    }

    /// Data present but no frame PICT decoded (e.g. running on data missing
    /// Nova Graphics 3) — a plain fallback so the flow still works.
    private var fallback: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text(offer.title).novaFont(.heading)
                if let onShowDestination { DestinationMapBadge(action: onShowDestination) }
                if let storylineTag, let onOpenStoryline {
                    StorylineTagBadge(title: storylineTag.title, action: onOpenStoryline)
                }
            }
            ScrollView { Text(offer.briefingText).novaFont(.body).frame(maxWidth: .infinity, alignment: .leading) }
                .cursorScrollable()
            HStack {
                if offer.canRefuse { Button(offer.refuseButton, action: onDecline) }
                Spacer()
                Button(offer.acceptButton, action: onAccept).novaProminentButton()
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
    var storylineTag: MissionStorylineTag? = nil
    var onOpenStoryline: (() -> Void)? = nil
    /// Opens the galaxy map on this job's destination. Nil when the mission has
    /// nowhere to send the player.
    var onShowDestination: (() -> Void)? = nil

    @EnvironmentObject private var model: AppModel
    /// Set while the briefing's `dësc` movie (`offer's` `MissionOffer.mission`
    /// → `game.desc(offerTextID)?.movieFilename`) is playing full-screen over
    /// the dialog — dismissed by Skip or when the clip ends/fails, same pattern
    /// as `GamblingView`'s racing holovid.
    @State private var moviePlayer: AVPlayer?

    private static let upperID = 8521, middleID = 8522, lowerID = 8523
    private static let frameWidth: CGFloat = 441
    private static let frameHeight: CGFloat = 317
    private static let topHeight: CGFloat = 9
    private static let bottomHeight: CGFloat = 40

    /// DITL/DLOG #1016 from the loaded data: the frame takes the DLOG's size
    /// and every item its DITL rect (stock values as fallback).
    private var ditl: DITLPlacement {
        let stock = DITLPlacement(graphics.game, 1016,
                                  window: CGSize(width: Self.frameWidth, height: Self.frameHeight))
        return DITLPlacement(graphics.game, 1016, window: stock.windowSize)
    }

    private var index: Int? { offered.firstIndex { $0.id == offer.mission.id } }

    private var movieFilename: String? {
        model.data.game?.desc(offer.mission.offerTextID)?.movieFilename
    }
    /// dësc Flags 0x0001: the movie plays after the window closes.
    private var movieAfterText: Bool {
        model.data.game?.desc(offer.mission.offerTextID)?.moviePlaysAfterText ?? false
    }
    /// The button action waiting for an after-text movie to finish.
    @State private var afterMovie: (() -> Void)?

    /// Run a button's action — after the dësc movie when it plays after the
    /// text (0x00442510).
    private func finish(_ action: @escaping () -> Void) {
        if movieAfterText, movieFilename != nil, moviePlayer == nil, afterMovie == nil {
            afterMovie = action
            playMovie()
            if moviePlayer == nil { afterMovie = nil; action() }
        } else {
            action()
        }
    }

    // Rendered as a full-screen overlay at the shared 1024×768 reference scale
    // (like every NovaMenu dialog), so the patron's offer stacks over the bar
    // at its true relative size instead of appearing in a native sheet.
    var body: some View {
        GeometryReader { geo in
            let scale = novaFrameScale(frame: ditl.windowSize,
                                       viewport: geo.size)
            frameBody
                .cursorScaleEffect(scale)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .overlay { if moviePlayer != nil { moviePlayerOverlay } }
        // The offer's dësc movie plays by itself before the text, unless its
        // Flags put it after (0x00442510).
        .onAppear { if !movieAfterText { playMovie() } }
    }

    /// The briefing's holovid, full-screen over the whole dialog — mirrors
    /// `GamblingView.racingView`'s player + Skip + end/fail-dismiss pattern.
    @ViewBuilder private var moviePlayerOverlay: some View {
        if let moviePlayer {
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea()
                VStack(spacing: 14) {
                    VideoPlayer(player: moviePlayer)
                        .frame(maxWidth: 640, maxHeight: 400)
                        .onReceive(NotificationCenter.default.publisher(
                            for: .AVPlayerItemDidPlayToEndTime, object: moviePlayer.currentItem)) { _ in
                            dismissMovie()
                        }
                        .onReceive(NotificationCenter.default.publisher(
                            for: .AVPlayerItemFailedToPlayToEndTime, object: moviePlayer.currentItem)) { _ in
                            dismissMovie()
                        }
                    NovaButton(graphics: graphics, title: "Skip", width: 42, action: dismissMovie)
                }
            }
        }
    }

    private func playMovie() {
        guard let filename = movieFilename, let url = model.data.videoURL(named: filename) else { return }
        let player = AVPlayer(url: url)
        moviePlayer = player
        player.play()
    }

    private func dismissMovie() {
        moviePlayer?.pause()
        moviePlayer = nil
        if let action = afterMovie {
            afterMovie = nil
            action()
        }
    }

    @ViewBuilder private var frameBody: some View {
        Group {
            if let top = graphics.pict(Self.upperID), let middle = graphics.pict(Self.middleID),
               let bottom = graphics.pict(Self.lowerID) {
                MissionThreeSliceFrame(top: top, middle: middle, bottom: bottom,
                                        width: ditl.windowSize.width, height: ditl.windowSize.height,
                                        topHeight: Self.topHeight, bottomHeight: Self.bottomHeight) { space in
                    let d = ditl
                    // item 2: (12,9)-(427,276) 415x267 — briefing pane
                    let pane = d.rect(2, top: 9, left: 12, bottom: 276, right: 427)
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                NovaText(offer.title, size: 11, width: max(0, pane.width - 47),
                                         align: .leading, weight: .bold)
                                if let onShowDestination { DestinationMapBadge(action: onShowDestination) }
                                if let storylineTag, let onOpenStoryline {
                                    StorylineTagBadge(title: storylineTag.title, action: onOpenStoryline)
                                }
                            }
                            // The dësc record's own picture, when it has one (e.g. a
                            // patron's portrait or a new-territory establishing shot)
                            // — sits above the text, matching the original's briefing
                            // layout, capped so a large PICT doesn't push the buttons
                            // off-screen inside the scrolling pane.
                            if let pid = offer.pictureID, let cg = graphics.pict(pid) {
                                Image(decorative: cg, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: max(0, pane.width - 8), maxHeight: 140)
                            }
                            NovaText(offer.briefingText, size: 10, width: max(0, pane.width - 4), align: .leading)
                        }
                        .padding(.top, 2).padding(.leading, 2)
                    }
                    .cursorScrollable()
                    .frame(width: pane.width, height: pane.height)
                    .ditlPlace(space, d, pane)

                    if offer.canRefuse {
                        // item 1: (117,285)-(216,310) — refuse, paired with item 0
                        let refuse = d.rect(1, top: 285, left: 117, bottom: 310, right: 216)
                        NovaButton(graphics: graphics, title: offer.refuseButton, ditl: refuse, action: { finish(onDecline) })
                            .ditlPlace(space, d, refuse)
                        // item 0: (225,285)-(324,310) — accept, paired with item 1
                        let accept = d.rect(0, top: 285, left: 225, bottom: 310, right: 324)
                        NovaButton(graphics: graphics, title: offer.acceptButton, ditl: accept,
                                   action: { finish(onAccept) })
                            .ditlPlace(space, d, accept)
                    } else {
                        // item 5: (173,285)-(272,310) — accept, centered (no refuse)
                        let accept = d.rect(5, top: 285, left: 173, bottom: 310, right: 272)
                        NovaButton(graphics: graphics, title: offer.acceptButton, ditl: accept,
                                   action: { finish(onAccept) })
                            .ditlPlace(space, d, accept)
                    }

                    if offered.count > 1, let index {
                        // item 8: (340,287)-(363,310) 23x23 — previous offer
                        pageButton(system: "chevron.left", enabled: index > 0) {
                            onPage(offered[index - 1])
                        }
                        .ditlPlace(space, d, d.rect(8, top: 287, left: 340, bottom: 310, right: 363))
                        // item 9: (373,287)-(396,310) 23x23 — next offer
                        pageButton(system: "chevron.right", enabled: index < offered.count - 1) {
                            onPage(offered[index + 1])
                        }
                        .ditlPlace(space, d, d.rect(9, top: 287, left: 373, bottom: 310, right: 396))
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
        .buttonStyle(.novaPlain)
        .disabled(!enabled)
    }

    private var fallback: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text(offer.title).novaFont(.heading)
                if let onShowDestination { DestinationMapBadge(action: onShowDestination) }
                if let storylineTag, let onOpenStoryline {
                    StorylineTagBadge(title: storylineTag.title, action: onOpenStoryline)
                }
            }
            ScrollView { Text(offer.briefingText).novaFont(.body).frame(maxWidth: .infinity, alignment: .leading) }
                .cursorScrollable()
            HStack {
                if offer.canRefuse { Button(offer.refuseButton, action: onDecline) }
                Spacer()
                Button(offer.acceptButton, action: onAccept).novaProminentButton()
            }
        }
        .padding(20)
        .frame(width: 380, height: 280)
        .novaResponsive()
    }
}
