import SwiftUI
import EVNovaKit

/// The galaxy map, in the spirit of EV Nova's: systems plotted at their real
/// coordinates centered on the current system, hyperspace links as thin lines,
/// a blinking crosshair over your position, and click-to-plot-course — the
/// fewest-jumps route is drawn hop by hop, green where your current fuel can
/// still reach and warning-red past that. Systems you've never visited (or
/// aren't linked to one you have, or haven't charted with a map outfit) aren't
/// drawn at all — real fog of war. Drag to pan; pinch, +/- to zoom.
///
/// Chrome is rebuilt from the real "Map" dialog, DITL #2000 (`evnova-extract
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

    // Zoom is points-per-map-unit. Median link length in the data is ~37 units,
    // so 2.4 puts directly-linked systems ~90pt apart — a comfortable local view.
    @State private var zoom: CGFloat = GalaxyMapView.defaultZoom
    @State private var pan: CGSize = .zero
    @State private var dragLast: CGSize = .zero
    @State private var pinchStartZoom: CGFloat?
    /// Faction map colors, keyed by `gövt` id — built once per data load, since
    /// the resource format carries no color field of its own (see `rebuildGovtColors`).
    @State private var govtColors: [Int: Color] = [:]
    /// Built locally (not threaded in from `GameContainerView`, which this
    /// workstream doesn't touch) — cheap, and `SpaceportGraphics` already owns
    /// the PICT/button-slice/label decode+cache this chrome needs.
    @State private var graphics: SpaceportGraphics?
    @State private var showingFinder = false
    /// Decoded `nëbu` regions with their resolved artwork, built once per data
    /// load. Drawn behind the systems in map-space (`x,y,w,h` share the `syst`
    /// coordinate system), scaled by the current zoom.
    @State private var nebulae: [MapNebula] = []

    private struct MapNebula { let x, y, w, h: Int; let image: CGImage }

    static let defaultZoom: CGFloat = 2.4
    private let minZoom: CGFloat = 0.5    // whole galaxy (~945 units wide) in view
    private let maxZoom: CGFloat = 16     // a linked neighbor fills most of the screen

    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)
    private let routeGreen = Color(red: 0.3, green: 0.95, blue: 0.4)
    private let routeWarn = Color(red: 1.0, green: 0.4, blue: 0.32)
    private let adjacentGrey = Color(white: 0.42)
    private let independentColor = Color(white: 0.62)
    /// Deterministic per-faction palette: the `gövt` resource carries no color of
    /// its own, so distinct governments are assigned a distinct hue by sorted id.
    /// Kept visually apart from `amber` (current system) and the route colors.
    private static let factionPalette: [Color] = [
        Color(red: 0.35, green: 0.62, blue: 1.0),   // blue
        Color(red: 1.0, green: 0.4, blue: 0.4),     // red
        Color(red: 0.72, green: 0.48, blue: 1.0),   // purple
        Color(red: 0.3, green: 0.82, blue: 0.85),   // cyan
        Color(red: 1.0, green: 0.52, blue: 0.76),   // pink
        Color(red: 0.93, green: 0.84, blue: 0.35),  // gold
        Color(red: 0.28, green: 0.72, blue: 0.62),  // teal
        Color(red: 0.62, green: 0.6, blue: 0.95),   // lavender
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()

            if let graphics, let frame = graphics.pict(Self.frameID) {
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

    /// Sort known governments by id and assign each a distinct palette color.
    /// Independent/unresolved (`-1` or no matching `gövt`) always renders grey.
    private func rebuildGovtColors() {
        guard let game = nav.game else { return }
        let ids = game.govts().map(\.id).sorted()
        var map: [Int: Color] = [:]
        for (i, id) in ids.enumerated() {
            map[id] = Self.factionPalette[i % Self.factionPalette.count]
        }
        govtColors = map
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

    private func factionColor(for government: Int) -> Color {
        guard government >= 0, let color = govtColors[government] else { return independentColor }
        return color
    }

    /// A `NovaColor` (the `gövt` map/ship colour fields) as a SwiftUI `Color`.
    private func color(_ c: NovaColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    /// A government's authentic **territory** colour — its real `gövt.mapColor`
    /// (Federation blue, Auroran red, the Pirate families' greys, …). Falls back
    /// to the synthetic palette only when the data leaves it black (16 of the 68
    /// base governments do). Used for the background regions, *not* the dots.
    private func govtMapColor(_ government: Int, game: NovaGame) -> Color {
        guard government >= 0 else { return independentColor }
        if let mc = game.govt(government)?.mapColor, mc.r != 0 || mc.g != 0 || mc.b != 0 {
            return color(mc)
        }
        return factionColor(for: government)
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
        let standing = pilot.state.legalRecord[gov] ?? g.initialRecord
        if standing < 0 { return relEnemy }
        if standing > 0 || g.neverAttacksPlayer { return relFriendly }
        return relNeutral
    }

    // MARK: Drawing

    private func drawMap(ctx: inout GraphicsContext, size: CGSize, blinkOn: Bool) {
        let systems = nav.systems()
        guard let cur = nav.current, let game = nav.game else { return }
        var byID: [Int: SystRes] = [:]
        for s in systems { byID[s.id] = s }

        // Fog of war: what the player currently knows about each system.
        let explored = pilot.state.exploredSystems
        let mapRevealAll = pilot.ownsMapOutfit(game: game)
        let adjacent = nav.adjacentToExplored(explored)
        var visibility: [Int: SystemVisibility] = [:]
        for s in systems {
            visibility[s.id] = nav.visibility(of: s.id, explored: explored, adjacent: adjacent, mapRevealAll: mapRevealAll)
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

            // The dot: current is amber, on-route hops are green/red by
            // affordability, otherwise coloured by the player's *relationship* to
            // the system's government (blue friendly / yellow neutral / red
            // wanted / grey pirate·uninhabited), dim grey if only seen-as-adjacent
            // (unconfirmed allegiance).
            let r: CGFloat = isCurrent || isDestination ? 3.5 : (isKnownDetail ? 2.5 : 2.0)
            let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            if isCurrent {
                ctx.fill(dot, with: .color(amber))
            } else if onRoute {
                ctx.fill(dot, with: .color(hopAffordable ? routeGreen : routeWarn))
            } else if isKnownDetail {
                ctx.fill(dot, with: .color(relationColor(for: s, game: game)))
            } else {
                ctx.fill(dot, with: .color(adjacentGrey))
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
        guard let cur = nav.current, let game = nav.game else { return }
        let explored = pilot.state.exploredSystems
        let mapRevealAll = pilot.ownsMapOutfit(game: game)
        let adjacent = nav.adjacentToExplored(explored)
        let center = CGPoint(x: viewSize.width / 2 + pan.width,
                             y: viewSize.height / 2 + pan.height)
        var best: (id: Int, dist: CGFloat)?
        for s in nav.systems() {
            // Fog of war: only known systems are selectable.
            guard nav.visibility(of: s.id, explored: explored, adjacent: adjacent, mapRevealAll: mapRevealAll) != .unknown else { continue }
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
        guard let cur = nav.current, let game = nav.game else { return }
        let explored = pilot.state.exploredSystems
        let mapRevealAll = pilot.ownsMapOutfit(game: game)
        let adjacent = nav.adjacentToExplored(explored)
        let nearest = nav.systems()
            .filter { s in
                s.id != cur.id
                    && nav.visibility(of: s.id, explored: explored, adjacent: adjacent, mapRevealAll: mapRevealAll) != .unknown
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
    /// backdrop/chrome art for DLOG #2000 (`evnova-extract list "data/EV Nova/
    /// Nova Files/Nova Graphics 3.rez" PICT` confirms the id + name). Decoding
    /// it also gives the frame's true pixel size, 601×513, which for this
    /// dialog matches the DLOG's own printed bounds (unlike some other dialogs
    /// where that field is stale — see the ground-truth tool notes).
    private static let frameID = 8509

    /// Verified rects from `evnova-extract ditl "data/EV Nova/Nova.rez" 2000`
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
                // the dot colours are readable. (Positioned by eye — nudge with
                // the ⇧⌘D debug grid.)
                relationLegend
                    .novaPlace(space, CGFloat(Item.canvas.left) + 4 - nw / 2,
                               CGFloat(Item.canvas.top + Item.canvas.h) - 72 - nh / 2)
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
        }
        .padding(5)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
    }

    private func legendRow(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 6, height: 6)
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
                let adjacent = nav.adjacentToExplored(explored)
                let mapRevealAll = pilot.ownsMapOutfit(game: game)
                let vis = nav.visibility(of: infoID, explored: explored, adjacent: adjacent, mapRevealAll: mapRevealAll)
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
            if let destID = nav.destinationID, let dest = nav.system(destID), let game = nav.game {
                let hops = nav.nextJumpHopCount
                let canGo = nav.canAfford(hops: hops)
                let explored = pilot.state.exploredSystems
                let destKnown = nav.visibility(of: destID, explored: explored,
                                               adjacent: nav.adjacentToExplored(explored),
                                               mapRevealAll: pilot.ownsMapOutfit(game: game))
                    != .adjacent
                let destName = destKnown ? dest.name : "Unexplored"
                VStack(alignment: .leading, spacing: 2) {
                    Text("COURSE: \(destName) — \(nav.route.count) JUMP\(nav.route.count == 1 ? "" : "S")")
                        .novaFont(.hud, weight: .semibold)
                        .foregroundStyle(nav.route.count <= nav.availableJumps ? routeGreen : routeWarn)
                    Text("FUEL: \(Int(nav.currentFuel))/\(Int(nav.shipMaxFuel))  (\(nav.availableJumps) jump\(nav.availableJumps == 1 ? "" : "s"))")
                        .novaFont(.hud).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onJump) {
                    Text(canGo ? (hops > 1 ? "JUMP ×\(hops)" : "JUMP") : "NO FUEL")
                        .novaFont(.button, weight: .bold)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background((canGo ? routeGreen : routeWarn).opacity(0.18), in: Capsule())
                        .overlay(Capsule().strokeBorder((canGo ? routeGreen : routeWarn).opacity(0.6)))
                        .foregroundStyle(canGo ? routeGreen : routeWarn)
                }
                .buttonStyle(.plain)
                .disabled(!canGo)
            } else {
                Text("Click a system to plot a course · drag to pan · pinch or +/− to zoom")
                    .novaFont(.caption).foregroundStyle(.secondary)
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
        }
        zoomIconButton("minus") { setZoom(zoom / 1.4) }
            .novaPlace(space, cx(Item.zoomOut, nw), cy(Item.zoomOut, nh))
        zoomIconButton("plus") { setZoom(zoom * 1.4) }
            .novaPlace(space, cx(Item.zoomIn, nw), cy(Item.zoomIn, nh))
    }

    /// idx3/idx4 are 25×25 — too small for the three-slice button art (which
    /// has a fixed 25pt-tall, ≥26pt-wide geometry), so these stay simple icon
    /// buttons rather than `NovaButton`, sized to their real rects.
    private func zoomIconButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
                .frame(width: 25, height: 25)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain)
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
}
