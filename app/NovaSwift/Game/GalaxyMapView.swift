import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

/// The galaxy map, in the spirit of EV Nova's: systems plotted at their real
/// coordinates centered on the current system, hyperspace links as thin lines,
/// a blinking crosshair over your position, and click-to-plot-course — the
/// fewest-jumps route is drawn hop by hop, green where your current fuel can
/// still reach and warning-red past that. Systems you've never visited (or
/// aren't linked to one you have, or haven't charted with a map outfit) aren't
/// drawn at all — real fog of war. Drag to pan; pinch, +/- to zoom.
///
/// Chrome is rebuilt from the real "Map" dialog, DITL #2000 (`novaswift-extract
/// ditl "data/EV Nova/Nova.rez" 2000`), drawn on its actual backdrop, PICT
/// #8509 "Map" (`Nova Files/Nova Graphics 3.rez`) — see `Item` below for the
/// verified rects. The starmap canvas, drag/pinch/tap interaction and route
/// drawing (`drawMap`/`handleTap`) are unchanged; only their container size
/// moved from full-screen to the dialog's own canvas rect.
struct GalaxyMapView: View {
    @ObservedObject var nav: NavigationModel
    @ObservedObject var pilot: PilotStore
    var onJump: () -> Void
    var onClose: () -> Void
    /// Enhanced / Nova Swift presentation: render the map edge-to-edge with its
    /// controls overlaid on gradient scrims, instead of inside the authentic
    /// PICT dialog frame. Driven by `GameSettings.fullscreenGalaxyMap`.
    var fullscreen: Bool = false

    /// Other players' locations (multiplayer presence), keyed by system id → the
    /// players in it (excluding the local player). Empty in single-player. Drawn
    /// as a coloured pip + name offset to the right of the system so it never
    /// occludes the mission arrow (above the dot) or the label (below it).
    var playerMarkers: [Int: [PlayerMapMarker]] = [:]

    /// One other player to mark on the map.
    struct PlayerMapMarker: Equatable {
        let id: String
        let name: String
    }

    /// Gate destination-picker mode. When set (landing on a hypergate opens the
    /// map this way), solid bright-blue lines run from `originSystem` to every
    /// gate this one connects to, and tapping a destination invokes
    /// `onSelect(destGateSpobID, destSystemID)` — a gate jump — instead of
    /// plotting an ordinary hyperspace course.
    struct GateSelection {
        let originSystem: Int
        let destinations: [(gateSpobID: Int, systemID: Int)]
        let onSelect: (Int, Int) -> Void
    }
    var gateSelection: GateSelection?

    // Zoom is points-per-map-unit. Median link length in the data is ~37 units,
    // so 2.4 puts directly-linked systems ~90pt apart — a comfortable local view.
    @State private var zoom: CGFloat = GalaxyMapView.defaultZoom
    @State private var pan: CGSize = .zero
    @State private var dragLast: CGSize = .zero
    @State private var pinchStartZoom: CGFloat?
    /// Government territory/faction colors — built once per data load (see
    /// `rebuildGovtColors`), shared with the Story Map via `GovernmentPalette`.
    @State private var govtPalette: GovernmentPalette?
    /// Built locally (not threaded in from `GameContainerView`, which this
    /// workstream doesn't touch) — cheap, and `SpaceportGraphics` already owns
    /// the PICT/button-slice/label decode+cache this chrome needs.
    @State private var graphics: SpaceportGraphics?
    @State private var showingFinder = false
    /// Decoded `nëbu` regions with their resolved artwork, built once per data
    /// load. Drawn behind the systems in map-space (`x,y,w,h` share the `syst`
    /// coordinate system), scaled by the current zoom.
    @State private var nebulae: [MapNebula] = []

    /// Systems that hold an active mission's destination — the galaxy map draws
    /// EV Nova's orange "go here" arrow over each. Rebuilt from the story engine
    /// when the map opens (accepted missions don't change while it's up).
    @State private var missionDestinations: [Int] = []
    /// Systems the story currently hides (`sÿst.Visibility` NCB evaluates false
    /// against the pilot's control bits) — not drawn and not selectable, EV
    /// Nova's mechanism for systems appearing/disappearing mid-campaign.
    @State private var hiddenSystems: Set<Int> = []

    private struct MapNebula { let x, y, w, h: Int; let image: CGImage }

    /// Hypergate/wormhole connections between systems (`spöb` HyperLink1-8),
    /// built once. Drawn as distinct dashed links over the hyperspace web.
    @State private var gateLinks: [GateLink] = []

    private struct GateLink { let a, b: Int; let wormhole: Bool }

    static let defaultZoom: CGFloat = 2.4
    private let minZoom: CGFloat = 0.5    // whole galaxy (~945 units wide) in view
    private let maxZoom: CGFloat = 16     // a linked neighbor fills most of the screen

    @Environment(\.novaTheme) private var theme
    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)
    /// EV Nova's mission-destination marker colour — a saturated orange arrow.
    private let missionOrange = Color(red: 1.0, green: 0.52, blue: 0.0)
    private let routeGreen = Color(red: 0.3, green: 0.95, blue: 0.4)
    private let routeWarn = Color(red: 1.0, green: 0.4, blue: 0.32)
    private let adjacentGrey = Color(white: 0.42)
    private let gateHyper = Color(red: 0.3, green: 0.85, blue: 0.95).opacity(0.85)     // hypergate link
    private let gateWormhole = Color(red: 0.78, green: 0.45, blue: 1.0).opacity(0.85)  // wormhole link
    /// Solid, bold blue for the gate destination picker's selectable jumps.
    private let gateRouteBlue = Color(red: 0.25, green: 0.62, blue: 1.0)

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()

            if fullscreen {
                // Enhanced / Nova Swift: the map fills the screen and its
                // controls float on gradient scrims (see `fullscreenChrome`).
                fullscreenChrome
            } else if let graphics, let frame = graphics.pict(Self.frameID) {
                authenticChrome(frame: frame)
            } else {
                // No Map PICT in the loaded data (or `SpaceportGraphics` hasn't
                // resolved yet) — fall back to the prior full-bleed layout so
                // the map still works.
                mapCanvas
                legacyChrome
            }
        }
        .novaResponsive()
        .onAppear {
            rebuildGovtColors()
            let g = graphics ?? nav.game.map { SpaceportGraphics(game: $0) }
            if graphics == nil { graphics = g }
            rebuildNebulae(using: g)
            rebuildGateLinks()
            rebuildMissionDestinations()
        }
        .sheet(isPresented: $showingFinder) {
            SystemFinderView(nav: nav, pilot: pilot) { system in centerOn(system) }
        }
    }

    /// The starmap canvas itself — drag/pinch/tap-to-plot-course, unchanged
    /// from before this workstream. Only its container size changed (from
    /// full-screen to the dialog's canvas rect, DITL #2000 idx2).
    private var mapCanvas: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 0.4)) { timeline in
                let blinkOn = Int(timeline.date.timeIntervalSinceReferenceDate / 0.4) % 2 == 0
                Canvas { ctx, size in
                    drawMap(ctx: &ctx, size: size, blinkOn: blinkOn)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { g in
                        pan.width += g.translation.width - dragLast.width
                        pan.height += g.translation.height - dragLast.height
                        dragLast = g.translation
                    }
                    .onEnded { _ in dragLast = .zero }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        let base = pinchStartZoom ?? zoom
                        pinchStartZoom = base
                        setZoom(base * value)
                    }
                    .onEnded { _ in pinchStartZoom = nil }
            )
            .onTapGesture { location in
                handleTap(at: location, viewSize: geo.size)
            }
        }
    }

    /// Build the shared government color palette for the loaded game.
    private func rebuildGovtColors() {
        guard let game = nav.game else { return }
        govtPalette = GovernmentPalette(game: game)
    }

    /// Decode each `nëbu` and resolve its artwork (highest-res PICT of the
    /// nebula's zoom block, falling back to the smaller levels). Built once.
    private func rebuildNebulae(using graphics: SpaceportGraphics?) {
        guard nebulae.isEmpty, let game = nav.game, let graphics else { return }
        nebulae = game.nebulae().compactMap { neb in
            let baseID = game.nebulaImageID(index: neb.id - 128)
            guard let image = graphics.pict(baseID) ?? graphics.pict(baseID - 1) ?? graphics.pict(baseID - 2) else {
                Log.spaceport.error("Galaxy map: no PICT for nebula \(neb.id, privacy: .public) (\(neb.name, privacy: .public)) — tried \(baseID, privacy: .public)/-1/-2")
                return nil
            }
            return MapNebula(x: neb.x, y: neb.y, w: neb.width, h: neb.height, image: image)
        }
    }

    /// Build the inter-system hypergate/wormhole links from every gate `spöb`'s
    /// HyperLink1-8, mapping each gate to its containing system. Undirected and
    /// deduped. Wormholes whose links are all −1 (random) contribute nothing to
    /// draw — there's no fixed destination.
    private func rebuildGateLinks() {
        guard gateLinks.isEmpty, let game = nav.game else { return }
        let systems = nav.systems()
        var spobSystem: [Int: Int] = [:]
        for s in systems { for sp in s.spobs { spobSystem[sp] = s.id } }
        var seen = Set<Int>()
        var links: [GateLink] = []
        for s in systems {
            for sp in s.spobs {
                guard let gate = game.spob(sp), gate.isGate else { continue }
                for target in gate.hyperLinks {
                    guard let other = spobSystem[target], other != s.id else { continue }
                    let key = min(s.id, other) * 100_000 + max(s.id, other)
                    if seen.insert(key).inserted {
                        links.append(GateLink(a: s.id, b: other, wormhole: gate.isWormhole))
                    }
                }
            }
        }
        gateLinks = links
    }

    /// Ask the story engine which systems currently hold an accepted mission's
    /// destination stellar. Built from a transient engine over the live pilot
    /// state (the same throwaway-engine pattern the spaceport screens use).
    private func rebuildMissionDestinations() {
        guard let game = nav.game else { return }
        let engine = StoryEngine(game: game, player: pilot.state)
        missionDestinations = engine.missionDestinationSystemIDs()
        hiddenSystems = engine.hiddenSystemIDs()
    }

    /// A government's authentic **territory** colour — its real `gövt.mapColor`
    /// (Federation blue, Auroran red, the Pirate families' greys, …), falling
    /// back to a deterministic per-faction hue when the data leaves it black.
    /// Used for the background regions, *not* the relationship dots. See
    /// `GovernmentPalette`.
    private func govtMapColor(_ government: Int, game: NovaGame) -> Color {
        govtPalette?.color(for: government) ?? GovernmentPalette.independent
    }

    // Relation dot colours — the player's *standing* with a system's government,
    // deliberately distinct from the government's own territory colour above.
    private let relFriendly    = Color(red: 0.35, green: 0.62, blue: 1.0)   // blue
    private let relNeutral     = Color(red: 0.95, green: 0.85, blue: 0.32)  // yellow
    private let relEnemy       = Color(red: 0.95, green: 0.3, blue: 0.25)   // red
    private let relPirate      = Color(white: 0.42)                         // dark grey
    private let relUninhabited = Color(white: 0.72)                         // light grey

    /// The colour of a system's star dot — by the player's **relationship** to
    /// its controlling government (not the government's own colour, which tints
    /// the territory behind it). Pirates/marauders (attack-on-sight governments)
    /// read dark grey, independent/no-government light grey, a government the
    /// player is wanted with red, good standing blue, otherwise neutral yellow.
    /// (Green "you own property here" awaits player planet-ownership tracking,
    /// which the save state doesn't expose yet.)
    private func relationColor(for s: SystRes, game: NovaGame) -> Color {
        let gov = s.government
        guard gov >= 0, let g = game.govt(gov) else { return relUninhabited }
        if g.alwaysAttacksPlayer || g.xenophobic { return relPirate }
        // The dot's own system, not wherever the player currently is — each
        // system shows its own true local standing (per the wiki's Legal
        // Status radius rule, trouble caused nearby doesn't follow you
        // everywhere that government has territory).
        let standing = pilot.state.effectiveLegalRecord(govt: gov, atSystem: s.id, fallback: g.initialRecord)
        if standing < 0 { return relEnemy }
        if standing > 0 || g.neverAttacksPlayer { return relFriendly }
        return relNeutral
    }

    // MARK: Drawing

    private func drawMap(ctx: inout GraphicsContext, size: CGSize, blinkOn: Bool) {
        // Story-hidden systems are dropped up front, so every downstream pass
        // (links, stars, labels, `byID`) excludes them uniformly.
        let systems = nav.systems().filter { !hiddenSystems.contains($0.id) }
        guard let cur = nav.current, let game = nav.game else { return }
        var byID: [Int: SystRes] = [:]
        for s in systems { byID[s.id] = s }

        // Fog of war: what the player currently knows about each system.
        let explored = pilot.state.exploredSystems
        let charted = pilot.chartedSystems
        let adjacent = nav.adjacentToKnown(explored: explored, charted: charted)
        var visibility: [Int: SystemVisibility] = [:]
        for s in systems {
            visibility[s.id] = nav.visibility(of: s.id, explored: explored, adjacent: adjacent, charted: charted)
        }

        let center = CGPoint(x: size.width / 2 + pan.width,
                             y: size.height / 2 + pan.height)
        func plot(_ x: Int, _ y: Int) -> CGPoint {
            CGPoint(x: center.x + CGFloat(x - cur.x) * zoom,
                    y: center.y + CGFloat(y - cur.y) * zoom)
        }
        // Cull to the viewport (padded so labels/lines at the edge still draw).
        let visibleRect = CGRect(origin: .zero, size: size).insetBy(dx: -60, dy: -60)

        // Faction territories: a soft radial glow in each known system's
        // government colour, additively blended so clusters of one government
        // merge into a contiguous coloured region — the map's "spheres of
        // influence". Derived from `syst.government` (there is no territory
        // resource), and gated to known systems so adjacency alone never leaks
        // a system's allegiance (matching the dot colours below). The glow
        // radius tracks zoom so neighbours' halos overlap at any scale.
        do {
            var tctx = ctx
            tctx.blendMode = .plusLighter
            let glowR = min(max(24 * zoom, 12), 260)
            let glowRect = visibleRect.insetBy(dx: -glowR, dy: -glowR)
            for s in systems {
                let vis = visibility[s.id] ?? .unknown
                guard vis == .explored || vis == .chartered, s.government >= 0 else { continue }
                let p = plot(s.x, s.y)
                guard glowRect.contains(p) else { continue }
                let col = govtMapColor(s.government, game: game)
                tctx.fill(Path(ellipseIn: CGRect(x: p.x - glowR, y: p.y - glowR, width: glowR * 2, height: glowR * 2)),
                          with: .radialGradient(Gradient(colors: [col.opacity(0.22), .clear]),
                                                center: p, startRadius: 0, endRadius: glowR))
            }
        }

        // Nebulae: coloured background regions (`nëbu`), drawn first so systems,
        // links and labels sit on top. Each is placed by its map-space box
        // (top-left `x,y`, extent `w,h` — same units as systems), scaled by zoom.
        // Dimmed so it reads as atmosphere behind the map, not chrome over it.
        if !nebulae.isEmpty {
            var nctx = ctx
            nctx.opacity = 0.5
            for neb in nebulae {
                let tl = plot(neb.x, neb.y)
                let rect = CGRect(x: tl.x, y: tl.y, width: CGFloat(neb.w) * zoom, height: CGFloat(neb.h) * zoom)
                guard rect.intersects(visibleRect) else { continue }
                nctx.draw(nctx.resolve(Image(decorative: neb.image, scale: 1)), in: rect)
            }
        }

        // Hyperspace links: thin dim lines, culled to known systems only (an
        // unknown system's links stay hidden — that's how fog of war works).
        // Links touching the current system are tinted by fuel affordability.
        var links = Path()
        var currentLinks = Path()
        for s in systems {
            guard visibility[s.id] != .unknown else { continue }
            let a = plot(s.x, s.y)
            for link in s.links {
                guard let n = byID[link], link > s.id, visibility[link] != .unknown else { continue }
                let b = plot(n.x, n.y)
                guard visibleRect.contains(a) || visibleRect.contains(b) else { continue }
                if s.id == nav.currentSystemID || link == nav.currentSystemID {
                    currentLinks.move(to: a); currentLinks.addLine(to: b)
                } else {
                    links.move(to: a); links.addLine(to: b)
                }
            }
        }
        ctx.stroke(links, with: .color(.white.opacity(0.16)), lineWidth: 1)
        let canJumpNow = nav.availableJumps >= 1
        ctx.stroke(currentLinks, with: .color((canJumpNow ? routeGreen : routeWarn).opacity(0.6)), lineWidth: 1.3)

        // Hypergate (cyan) and wormhole (violet) connections, dashed to set them
        // apart from the solid hyperspace web. Shown only between known systems.
        for gl in gateLinks {
            guard let a = byID[gl.a], let b = byID[gl.b],
                  visibility[gl.a] != .unknown, visibility[gl.b] != .unknown else { continue }
            let pa = plot(a.x, a.y), pb = plot(b.x, b.y)
            guard visibleRect.contains(pa) || visibleRect.contains(pb) else { continue }
            var path = Path(); path.move(to: pa); path.addLine(to: pb)
            ctx.stroke(path, with: .color(gl.wormhole ? gateWormhole : gateHyper),
                       style: StrokeStyle(lineWidth: 1.3, dash: [2.5, 3]))
        }

        // Gate destination picker: bold, solid blue lines from the origin gate's
        // system to each gate it reaches, with a ring on each tappable target.
        // Destinations are always shown (using a gate bypasses fog of war).
        if let gs = gateSelection, let origin = byID[gs.originSystem] {
            let pa = plot(origin.x, origin.y)
            for dest in gs.destinations {
                guard let d = byID[dest.systemID] else { continue }
                let pb = plot(d.x, d.y)
                var line = Path(); line.move(to: pa); line.addLine(to: pb)
                ctx.stroke(line, with: .color(gateRouteBlue), lineWidth: 3)
                let ring = Path(ellipseIn: CGRect(x: pb.x - 7, y: pb.y - 7, width: 14, height: 14))
                ctx.stroke(ring, with: .color(gateRouteBlue), lineWidth: 2)
            }
        }

        // The plotted course: green while your current fuel can still reach that
        // hop, warning red past it — segment by segment, drawn on top of the web.
        if !nav.route.isEmpty {
            let greenHops = min(nav.availableJumps, nav.route.count)
            var from = plot(cur.x, cur.y)
            for (i, hop) in nav.route.enumerated() {
                guard let s = byID[hop] else { break }
                let to = plot(s.x, s.y)
                var seg = Path()
                seg.move(to: from); seg.addLine(to: to)
                let color = i < greenHops ? routeGreen : routeWarn
                ctx.stroke(seg, with: .color(color.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                from = to
            }
        }

        let neighborIDs = Set(cur.links)
        let showLabels = zoom >= 1.1
        // Fixed design-point size: the canvas is already scaled to the device by
        // its container (novaFrameScale), so labels must not re-apply a viewport
        // factor here — that double-scaling was the old 1024/768 formula's bug.
        let labelSize: CGFloat = 11

        for s in systems {
            let vis = visibility[s.id] ?? .unknown
            guard vis != .unknown else { continue }   // fog of war: not drawn at all
            let p = plot(s.x, s.y)
            guard visibleRect.contains(p) else { continue }
            let isCurrent = s.id == nav.currentSystemID
            let isDestination = s.id == nav.destinationID
            let hopIndex = nav.route.firstIndex(of: s.id)
            let onRoute = hopIndex != nil
            let isKnownDetail = vis == .explored || vis == .chartered
            let hopAffordable = hopIndex.map { $0 < nav.availableJumps } ?? true

            // The system marker: a hollow ring (EV Nova draws systems as circle
            // outlines, not solid discs), coloured by state — current is amber,
            // on-route hops are green/red by affordability, otherwise the
            // player's *relationship* to the system's government (blue friendly /
            // yellow neutral / red wanted / grey pirate·uninhabited), dim grey if
            // only seen-as-adjacent (unconfirmed allegiance). The current system
            // also gets a solid centre pip so "you are here" still reads at a
            // glance under the blinking crosshair.
            let markColor: Color = isCurrent ? amber
                : onRoute ? (hopAffordable ? routeGreen : routeWarn)
                : isKnownDetail ? relationColor(for: s, game: game)
                : adjacentGrey
            let r: CGFloat = isCurrent || isDestination ? 5 : 4
            let ring = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            ctx.stroke(ring, with: .color(markColor), lineWidth: 1.4)
            if isCurrent {
                let pipR: CGFloat = 1.8
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - pipR, y: p.y - pipR, width: pipR * 2, height: pipR * 2)),
                         with: .color(amber))
            }

            // Destination ring: green if the whole course is affordable right
            // now, red if fuel will run out before you get there.
            if isDestination {
                let ringColor = nav.route.count <= nav.availableJumps ? routeGreen : routeWarn
                let ring = Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16))
                ctx.stroke(ring, with: .color(ringColor), lineWidth: 1.2)
            }

            // Blinking crosshair brackets over the current system, EV-style.
            if isCurrent && blinkOn {
                ctx.stroke(crosshair(at: p, arm: 9, gap: 5), with: .color(amber), lineWidth: 1.3)
            }

            // Names: everything when zoomed in; only the load-bearing ones when
            // out. Unvisited/uncharted systems show as "Unexplored" — no name
            // leak from adjacency alone.
            if showLabels || isCurrent || isDestination {
                let name = isKnownDetail ? s.name : "Unexplored"
                let color: Color = isCurrent ? amber
                    : onRoute ? (hopAffordable ? routeGreen : routeWarn)
                    : isKnownDetail ? (neighborIDs.contains(s.id) ? .white.opacity(0.9) : .white.opacity(0.7))
                    : .white.opacity(0.4)
                let weight: Font.Weight = isCurrent || isDestination ? .bold : .regular
                ctx.draw(
                    Text(name).font(.custom(NovaFontRole.hud.family, size: labelSize).weight(weight))
                        .foregroundStyle(color),
                    at: CGPoint(x: p.x, y: p.y + r + 9)
                )
            }
        }

        // Mission-destination arrows: EV Nova marks each system a currently-
        // accepted mission wants you to visit with a bobbing orange arrow. Drawn
        // last so it sits over the dots/labels. A mission destination is always
        // marked regardless of fog of war — the game reveals where a mission
        // sends you so you can navigate there. The arrow bobs with the blink tick.
        let bob: CGFloat = blinkOn ? 0 : 3
        for destID in missionDestinations {
            guard let s = byID[destID] else { continue }
            let p = plot(s.x, s.y)
            guard visibleRect.contains(p) else { continue }
            drawMissionArrow(ctx: &ctx, at: p, bob: bob)
        }

        // Multiplayer presence markers — drawn last (over the dots/labels/arrows),
        // like a mission destination. A friend's system is always marked, even
        // through fog of war, so you can see where they are (same rationale as the
        // mission arrow). Offset to the right so the mission arrow (above) and the
        // system label (below) stay clear.
        for (sysID, players) in playerMarkers {
            guard let s = byID[sysID] else { continue }
            let p = plot(s.x, s.y)
            guard visibleRect.contains(p) else { continue }
            drawPlayerMarkers(ctx: &ctx, at: p, players: players)
        }
    }

    /// A downward-pointing orange arrow hovering just above a system, the EV Nova
    /// "your mission wants you here" marker. Anchored so its tip sits a few points
    /// above the star dot; `bob` nudges it up/down for a subtle pulse.
    private func drawMissionArrow(ctx: inout GraphicsContext, at p: CGPoint, bob: CGFloat) {
        let tipY = p.y - 12 + bob          // arrow tip, above the dot
        let headW: CGFloat = 7             // half-width of the arrowhead
        let headH: CGFloat = 9             // arrowhead height
        let shaftH: CGFloat = 9            // shaft length above the head
        let shaftW: CGFloat = 2.4          // half-width of the shaft

        var head = Path()
        head.move(to: CGPoint(x: p.x, y: tipY))                       // tip
        head.addLine(to: CGPoint(x: p.x - headW, y: tipY - headH))    // upper-left
        head.addLine(to: CGPoint(x: p.x + headW, y: tipY - headH))    // upper-right
        head.closeSubpath()

        let shaft = Path(CGRect(x: p.x - shaftW, y: tipY - headH - shaftH,
                                width: shaftW * 2, height: shaftH + 1))

        // A soft dark outline first so the arrow reads over bright nebulae/dots.
        ctx.stroke(head, with: .color(.black.opacity(0.6)), lineWidth: 2.4)
        ctx.stroke(shaft, with: .color(.black.opacity(0.6)), lineWidth: 2.4)
        ctx.fill(head, with: .color(missionOrange))
        ctx.fill(shaft, with: .color(missionOrange))
    }

    /// A stack of coloured pips + names to the right of a system, one per player
    /// present there. Each name gets a cheap dark drop-shadow so it reads over
    /// bright nebulae and territory glow.
    private func drawPlayerMarkers(ctx: inout GraphicsContext, at p: CGPoint,
                                   players: [PlayerMapMarker]) {
        let dotR: CGFloat = 3
        let rowH: CGFloat = 12
        let startY = p.y - CGFloat(players.count - 1) * rowH / 2
        for (i, player) in players.enumerated() {
            let cy = startY + CGFloat(i) * rowH
            let cx = p.x + 9
            let color = Self.playerColor(for: player.id)

            let dot = Path(ellipseIn: CGRect(x: cx - dotR, y: cy - dotR,
                                             width: dotR * 2, height: dotR * 2))
            ctx.stroke(dot, with: .color(.black.opacity(0.7)), lineWidth: 1.5)
            ctx.fill(dot, with: .color(color))

            var label = ctx.resolve(Text(player.name).font(.system(size: 9, weight: .bold)))
            let tx = cx + dotR + 4
            label.shading = .color(.black.opacity(0.75))
            ctx.draw(label, at: CGPoint(x: tx + 0.7, y: cy + 0.7), anchor: .leading)
            label.shading = .color(color)
            ctx.draw(label, at: CGPoint(x: tx, y: cy), anchor: .leading)
        }
    }

    /// A stable, distinct colour per player id. Avoids mission orange so a friend
    /// pip is never mistaken for a mission destination.
    static func playerColor(for id: String) -> Color {
        let palette: [Color] = [.cyan, .green, .yellow, .pink, .mint, .purple, .teal, .blue]
        var hash = 5381
        for byte in id.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }

    /// Four corner brackets around a point (the classic map cursor).
    private func crosshair(at p: CGPoint, arm: CGFloat, gap: CGFloat) -> Path {
        var path = Path()
        for sx in [CGFloat(-1), 1] {
            for sy in [CGFloat(-1), 1] {
                let corner = CGPoint(x: p.x + sx * (gap + arm), y: p.y + sy * (gap + arm))
                path.move(to: CGPoint(x: corner.x - sx * arm * 0.7, y: corner.y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y - sy * arm * 0.7))
            }
        }
        return path
    }

    // MARK: Interaction

    private func handleTap(at location: CGPoint, viewSize: CGSize) {
        guard let cur = nav.current else { return }
        let center = CGPoint(x: viewSize.width / 2 + pan.width,
                             y: viewSize.height / 2 + pan.height)

        // Gate mode: a tap picks the nearest gate destination and jumps through
        // it, rather than plotting a hyperspace course.
        if let gs = gateSelection {
            var pick: (gate: Int, sys: Int, dist: CGFloat)?
            for dest in gs.destinations {
                guard let s = nav.game?.system(dest.systemID) else { continue }
                let p = CGPoint(x: center.x + CGFloat(s.x - cur.x) * zoom,
                                y: center.y + CGFloat(s.y - cur.y) * zoom)
                let d = hypot(p.x - location.x, p.y - location.y)
                if d < (pick?.dist ?? 24) { pick = (dest.gateSpobID, dest.systemID, d) }
            }
            if let pick { gs.onSelect(pick.gate, pick.sys) }
            return
        }

        let explored = pilot.state.exploredSystems
        let charted = pilot.chartedSystems
        let adjacent = nav.adjacentToKnown(explored: explored, charted: charted)
        var best: (id: Int, dist: CGFloat)?
        for s in nav.systems() {
            // Story-hidden systems can't be targeted at all.
            guard !hiddenSystems.contains(s.id) else { continue }
            // Fog of war: only known systems are selectable.
            guard nav.visibility(of: s.id, explored: explored, adjacent: adjacent, charted: charted) != .unknown else { continue }
            let p = CGPoint(x: center.x + CGFloat(s.x - cur.x) * zoom,
                            y: center.y + CGFloat(s.y - cur.y) * zoom)
            let d = hypot(p.x - location.x, p.y - location.y)
            if d < (best?.dist ?? 18) { best = (s.id, d) }
        }
        guard let hit = best else { return }
        if hit.id == nav.currentSystemID {
            nav.clearCourse()
        } else {
            nav.plotCourse(to: hit.id)
        }
    }

    private func setZoom(_ value: CGFloat) {
        let clamped = min(maxZoom, max(minZoom, value))
        // Keep the point at the view centre fixed while zooming.
        let factor = clamped / zoom
        pan.width *= factor
        pan.height *= factor
        zoom = clamped
    }

    /// Recentre the map on `system` — used by "Nearest System" and by
    /// `SystemFinderView`'s "Named System" picker. Keeps the current zoom;
    /// only pans, the same way dragging would.
    private func centerOn(_ system: SystRes) {
        guard let cur = nav.current else { return }
        pan.width = -CGFloat(system.x - cur.x) * zoom
        pan.height = -CGFloat(system.y - cur.y) * zoom
    }

    /// "Nearest System" (DITL #2000 idx7): the real dialog gives no more
    /// precise a definition than its label, so this picks the closest system
    /// (straight-line, in map units) the player currently knows about —
    /// explored, chartered, or merely glimpsed-as-adjacent — and both plots a
    /// course to it and pans the view there, same as tapping it directly.
    private func findNearestSystem() {
        guard let cur = nav.current else { return }
        let explored = pilot.state.exploredSystems
        let charted = pilot.chartedSystems
        let adjacent = nav.adjacentToKnown(explored: explored, charted: charted)
        let nearest = nav.systems()
            .filter { s in
                s.id != cur.id
                    && nav.visibility(of: s.id, explored: explored, adjacent: adjacent, charted: charted) != .unknown
            }
            .min { a, b in
                hypot(Double(a.x - cur.x), Double(a.y - cur.y)) < hypot(Double(b.x - cur.x), Double(b.y - cur.y))
            }
        guard let nearest else { return }
        nav.plotCourse(to: nearest.id)
        centerOn(nearest)
    }

    // MARK: Chrome — authentic (DITL #2000 "Map", drawn on PICT #8509)

    /// PICT #8509 "Map" in `Nova Files/Nova Graphics 3.rez` — the real
    /// backdrop/chrome art for DLOG #2000 (`novaswift-extract list "data/EV Nova/
    /// Nova Files/Nova Graphics 3.rez" PICT` confirms the id + name). Decoding
    /// it also gives the frame's true pixel size, 601×513, which for this
    /// dialog matches the DLOG's own printed bounds (unlike some other dialogs
    /// where that field is stale — see the ground-truth tool notes).
    private static let frameID = 8509

    /// Verified rects from `novaswift-extract ditl "data/EV Nova/Nova.rez" 2000`
    /// (left, top, width, height), top-left anchored in the 601×513 frame.
    /// idx6, a disabled 32×32 item at (518,537)-(550,569), falls entirely
    /// outside the 513-tall frame — an off-screen/unused control, not part of
    /// the visible chrome, so it has no entry here.
    private enum Item {
        static let canvas   = (left: 9,   top: 8,   w: 458, h: 420)  // idx2 — starmap
        static let panel    = (left: 474, top: 8,   w: 120, h: 429)  // idx5 — system info
        static let routeBar = (left: 8,   top: 436, w: 586, h: 42)   // idx1 — course/fuel
        static let zoomOut  = (left: 408, top: 483, w: 25,  h: 25)   // idx3
        static let zoomIn   = (left: 438, top: 483, w: 25,  h: 25)   // idx4
        static let nearest  = (left: 155, top: 483, w: 120, h: 25)   // idx7 — "Nearest System"
        static let named    = (left: 11,  top: 483, w: 130, h: 25)   // idx8 — "Named System"
        static let clear    = (left: 288, top: 483, w: 99,  h: 25)   // idx9 — "Clear Route"
        static let done     = (left: 483, top: 483, w: 99,  h: 25)   // idx0 — "Done"
    }

    /// DITL rect → `NovaSpace` offset (see the coordinate-convention doc comment
    /// on `NovaSpace`): children are positioned as an offset from the frame's
    /// own centre, top-left anchored.
    private func cx(_ item: (left: Int, top: Int, w: Int, h: Int), _ nw: CGFloat) -> CGFloat { CGFloat(item.left) - nw / 2 }
    private func cy(_ item: (left: Int, top: Int, w: Int, h: Int), _ nh: CGFloat) -> CGFloat { CGFloat(item.top) - nh / 2 }

    private func buttonLabel(_ index1: Int, fallback: String) -> String {
        graphics?.buttonLabel(index1, fallback: fallback) ?? fallback
    }

    private func authenticChrome(frame: CGImage) -> some View {
        let nw = CGFloat(frame.width), nh = CGFloat(frame.height)
        let space = NovaSpace(width: nw, height: nh)
        return GeometryReader { geo in
            let scale = novaFrameScale(frame: CGSize(width: nw, height: nh), viewport: geo.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: frame, scale: 1).interpolation(.high).resizable()
                    .frame(width: nw, height: nh)

                mapCanvas
                    .frame(width: CGFloat(Item.canvas.w), height: CGFloat(Item.canvas.h))
                    .clipped()
                    .novaPlace(space, cx(Item.canvas, nw), cy(Item.canvas, nh))

                sidePanel
                    .frame(width: CGFloat(Item.panel.w), height: CGFloat(Item.panel.h), alignment: .top)
                    .clipped()
                    .novaPlace(space, cx(Item.panel, nw), cy(Item.panel, nh))

                // A live tick so the fuel-dependent course readout / JUMP
                // button reflect fuel regenerating while the map is open.
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    routeBar
                        .frame(width: CGFloat(Item.routeBar.w), height: CGFloat(Item.routeBar.h))
                        .novaPlace(space, cx(Item.routeBar, nw), cy(Item.routeBar, nh))
                }

                bottomButtons(space: space, nw: nw, nh: nh)

                // Relation key, tucked into the star-map's lower-left corner so
                // the dot colours are readable. Bottom-anchored inside a fixed
                // box whose floor sits 4px above the canvas's bottom edge — the
                // legend's height varies (gate rows appear only in systems with
                // gates), and the old top-anchored placement let the tall
                // variant spill out of the canvas onto the route bar.
                relationLegend
                    .frame(height: 116, alignment: .bottomLeading)
                    .novaPlace(space, CGFloat(Item.canvas.left) + 4 - nw / 2,
                               CGFloat(Item.canvas.top + Item.canvas.h) - 120 - nh / 2)
            }
            .frame(width: nw, height: nh, alignment: .topLeading)
            .scaleEffect(scale)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    /// A compact key for the relation dot colours.
    private var relationLegend: some View {
        VStack(alignment: .leading, spacing: 2) {
            legendRow(relFriendly, "Friendly")
            legendRow(relNeutral, "Neutral")
            legendRow(relEnemy, "Wanted")
            legendRow(relPirate, "Pirate")
            legendRow(relUninhabited, "Uninhabited")
            if !gateLinks.isEmpty {
                Divider().overlay(.white.opacity(0.2)).frame(width: 60)
                legendLine(gateHyper, "Hypergate")
                legendLine(gateWormhole, "Wormhole")
            }
        }
        .padding(5)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
    }

    private func legendRow(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            // A hollow ring, matching how systems are drawn on the map itself.
            Circle().strokeBorder(c, lineWidth: 1.2).frame(width: 7, height: 7)
            NovaText(label, size: 9, color: .white.opacity(0.85))
        }
    }

    private func legendLine(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(c).frame(width: 6, height: 2)
            NovaText(label, size: 9, color: .white.opacity(0.85))
        }
    }

    /// The system-info panel (idx5): name, controlling government, and any
    /// stellar objects' services — for the plotted destination if there is
    /// one, else the current system. Respects the same fog-of-war the starmap
    /// itself draws under: an unknown/merely-adjacent system shows no detail.
    @ViewBuilder
    private var sidePanel: some View {
        if let cur = nav.current, let game = nav.game {
            let infoID = nav.destinationID ?? nav.currentSystemID
            if let sys = nav.system(infoID) {
                let explored = pilot.state.exploredSystems
                let charted = pilot.chartedSystems
                let adjacent = nav.adjacentToKnown(explored: explored, charted: charted)
                let vis = nav.visibility(of: infoID, explored: explored, adjacent: adjacent, charted: charted)
                let known = vis == .explored || vis == .chartered
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        NovaText(known ? sys.name : "Unexplored", size: 13,
                                 color: sys.id == cur.id ? amber : .white, width: 104, weight: .bold)
                        if known {
                            NovaText(game.govt(sys.government)?.name ?? "Independent", size: 11,
                                     color: govtMapColor(sys.government, game: game), width: 104)
                            Divider().overlay(.white.opacity(0.25))
                            ForEach(sys.spobs, id: \.self) { spobID in
                                if let spob = game.spob(spobID) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        NovaText(spob.name, size: 11, color: .white.opacity(0.9),
                                                 width: 104, weight: .semibold)
                                        NovaText(spobServices(spob), size: 11, color: Color(white: 0.6),
                                                 width: 104)
                                    }
                                }
                            }
                        } else {
                            NovaText("No data on file.", size: 11, color: Color(white: 0.6), width: 104)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    /// Service tags for a stellar object, from the already-decoded `spöb`
    /// flags (`NovaEconomy.swift`) — no new field decoding.
    private func spobServices(_ spob: SpobRes) -> String {
        var tags: [String] = []
        if spob.hasBar { tags.append("Bar") }
        if spob.hasOutfitter { tags.append("Outfitter") }
        if spob.hasShipyard { tags.append("Shipyard") }
        if spob.hasCommodityExchange { tags.append("Trade") }
        return tags.isEmpty ? "—" : tags.joined(separator: " · ")
    }

    /// The full-width course/fuel bar (idx1) — same content and logic as
    /// before this workstream, just filling the real dialog's status-bar rect
    /// instead of a floating capsule.
    @ViewBuilder
    private var routeBar: some View {
        HStack {
            if let destID = nav.destinationID, let dest = nav.system(destID) {
                let hops = nav.nextJumpHopCount
                let canGo = nav.canAfford(hops: hops)
                let explored = pilot.state.exploredSystems
                let charted = pilot.chartedSystems
                let destKnown = nav.visibility(of: destID, explored: explored,
                                               adjacent: nav.adjacentToKnown(explored: explored, charted: charted),
                                               charted: charted)
                    != .adjacent
                let destName = destKnown ? dest.name : "Unexplored"
                // Frame-pixel Geneva (like all in-frame text), not `.novaFont`
                // chrome roles — the route bar lives inside the scaled map
                // frame, where the roles' 13-15pt sizes render oversized.
                VStack(alignment: .leading, spacing: 2) {
                    NovaText("COURSE: \(destName) — \(nav.route.count) JUMP\(nav.route.count == 1 ? "" : "S")",
                             size: 11, color: nav.route.count <= nav.availableJumps ? routeGreen : routeWarn,
                             weight: .semibold)
                    NovaText("FUEL: \(Int(nav.currentFuel))/\(Int(nav.shipMaxFuel))  (\(nav.availableJumps) jump\(nav.availableJumps == 1 ? "" : "s"))",
                             size: 10, color: Color(white: 0.65))
                        .monospacedDigit()
                }
                Spacer()
                Button(action: onJump) {
                    NovaText(canGo ? (hops > 1 ? "JUMP ×\(hops)" : "JUMP") : "NO FUEL",
                             size: 11, color: canGo ? routeGreen : routeWarn, weight: .bold)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background((canGo ? routeGreen : routeWarn).opacity(0.18), in: Capsule())
                        .overlay(Capsule().strokeBorder((canGo ? routeGreen : routeWarn).opacity(0.6)))
                }
                .buttonStyle(.plain)
                .disabled(!canGo)
            } else {
                NovaText("Click a system to plot a course · drag to pan · pinch or +/− to zoom",
                         size: 10, color: Color(white: 0.65))
                Spacer()
            }
        }
        .padding(.horizontal, 12)
    }

    /// The bottom button row: Named System / Nearest System / Clear Route /
    /// zoom −+ / Done, at their DITL rects (idx8, idx7, idx9, idx3, idx4,
    /// idx0). The three-slice art + labels come from `SpaceportGraphics`
    /// (`STR# 150` "button labels"); "Nearest System" / "Named System" have no
    /// matching entry in that table (the real dialog's `dïtl` items are all
    /// custom-drawn `userItem`s with no stored text), so those two use literal
    /// EV Nova UI text instead of a `buttonLabel` lookup.
    @ViewBuilder
    private func bottomButtons(space: NovaSpace, nw: CGFloat, nh: CGFloat) -> some View {
        if let graphics {
            NovaButton(graphics: graphics, title: buttonLabel(SpaceportLabel.done, fallback: "Done"),
                       width: CGFloat(Item.done.w - 26), action: onClose)
                .novaPlace(space, cx(Item.done, nw), cy(Item.done, nh))
            NovaButton(graphics: graphics, title: buttonLabel(49, fallback: "Clear Route"),
                       width: CGFloat(Item.clear.w - 26)) { nav.clearCourse() }
                .novaPlace(space, cx(Item.clear, nw), cy(Item.clear, nh))
            NovaButton(graphics: graphics, title: "Nearest System",
                       width: CGFloat(Item.nearest.w - 26), action: findNearestSystem)
                .novaPlace(space, cx(Item.nearest, nw), cy(Item.nearest, nh))
            NovaButton(graphics: graphics, title: "Named System",
                       width: CGFloat(Item.named.w - 26)) { showingFinder = true }
                .novaPlace(space, cx(Item.named, nw), cy(Item.named, nh))
            // idx3/idx4 (25×25) — the authentic button art at its minimum
            // 26×25 geometry with −/+ glyphs, not a translucent system chip.
            NovaIconButton(graphics: graphics, systemName: "minus") { setZoom(zoom / 1.4) }
                .novaPlace(space, cx(Item.zoomOut, nw), cy(Item.zoomOut, nh))
            NovaIconButton(graphics: graphics, systemName: "plus") { setZoom(zoom * 1.4) }
                .novaPlace(space, cx(Item.zoomIn, nw), cy(Item.zoomIn, nh))
        }
    }

    // MARK: Chrome — fallback (no Map PICT resolved)

    private var legacyChrome: some View {
        VStack {
            HStack {
                Text("GALAXY MAP").novaFont(.heading, weight: .bold)
                    .foregroundStyle(amber)
                Spacer()
                zoomButton("minus.magnifyingglass") { setZoom(zoom / 1.4) }
                zoomButton("plus.magnifyingglass") { setZoom(zoom * 1.4) }
                zoomButton("scope") { pan = .zero; zoom = GalaxyMapView.defaultZoom }
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold))
                        .padding(8).background(.ultraThinMaterial, in: Circle())
                }.buttonStyle(.plain)
            }
            Spacer()
            // No backdrop art in this fallback, so `routeBar` gets its own
            // legibility background here (the authentic path already sits on
            // the real bar art from PICT #8509).
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                routeBar
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.5), in: Capsule())
            }
        }
        .padding(14)
    }

    private func zoomButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.subheadline)
                .padding(8).background(.ultraThinMaterial, in: Circle())
        }.buttonStyle(.plain)
    }

    // MARK: Chrome — full-screen (Enhanced / Nova Swift)

    /// The map filling the whole screen, its controls floating over it on
    /// top/bottom gradient scrims (and the side panel / legend on their own
    /// translucent cards) so everything stays legible against the starfield.
    /// Reuses the same `mapCanvas`, `routeBar`, `sidePanel` and `relationLegend`
    /// the authentic chrome uses — only the container differs.
    private var fullscreenChrome: some View {
        ZStack {
            mapCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar: title, zoom / recenter, Done.
                HStack(spacing: 12) {
                    Text("GALAXY MAP").novaFont(.heading, weight: .bold).foregroundStyle(amber)
                    Spacer()
                    overlayIcon("minus.magnifyingglass") { setZoom(zoom / 1.4) }
                    overlayIcon("plus.magnifyingglass") { setZoom(zoom * 1.4) }
                    overlayIcon("scope") { pan = .zero; zoom = GalaxyMapView.defaultZoom }
                    overlayButton("Done", tint: amber, action: onClose)
                }
                .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 26)
                .background(scrim(top: true))

                Spacer()

                // Bottom: live course/fuel bar + route actions.
                VStack(alignment: .leading, spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in routeBar }
                    HStack(spacing: 12) {
                        overlayButton("Named System") { showingFinder = true }
                        overlayButton("Nearest System", action: findNearestSystem)
                        overlayButton("Clear Route") { nav.clearCourse() }
                        Spacer()
                    }
                }
                .padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 18)
                .background(scrim(top: false))
            }
            .ignoresSafeArea(edges: .horizontal)

            // System-info panel, floating top-right on its own card.
            HStack(alignment: .top) {
                Spacer()
                sidePanel
                    .frame(width: 160, alignment: .top)
                    .padding(10)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    // The floating hyperspace-map border (cölr.floatingMap).
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.floatingMap))
                    .padding(.top, 92).padding(.trailing, 20)
            }

            // Relation-colour key, floating bottom-left just above the route bar.
            VStack {
                Spacer()
                HStack {
                    relationLegend.padding(.leading, 22).padding(.bottom, 112)
                    Spacer()
                }
            }
        }
    }

    /// A top- or bottom-anchored black gradient behind the overlaid controls, so
    /// text/buttons stay readable over a bright nebula or dense starfield.
    private func scrim(top: Bool) -> some View {
        LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0.0)],
                       startPoint: top ? .top : .bottom,
                       endPoint: top ? .bottom : .top)
            .allowsHitTesting(false)
    }

    /// A pill text button for the overlaid map controls (Done / Named / Nearest /
    /// Clear), in the map's amber theme with a translucent backing.
    private func overlayButton(_ title: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        let c = tint ?? amber
        return Button(action: action) {
            Text(title).novaFont(.body, weight: .semibold).foregroundStyle(c)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(c.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(c.opacity(0.5)))
        }.buttonStyle(.plain)
    }

    /// A round icon button (zoom −/+, recenter) matching `overlayButton`'s look.
    private func overlayIcon(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.subheadline.weight(.semibold)).foregroundStyle(amber)
                .frame(width: 34, height: 34)
                .background(amber.opacity(0.14), in: Circle())
                .overlay(Circle().strokeBorder(amber.opacity(0.5)))
        }.buttonStyle(.plain)
    }
}
