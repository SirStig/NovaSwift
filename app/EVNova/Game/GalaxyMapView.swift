import SwiftUI
import EVNovaKit

/// The galaxy map, in the spirit of EV Nova's: systems plotted at their real
/// coordinates centered on the current system, hyperspace links as thin lines,
/// a blinking crosshair over your position, and click-to-plot-course — the
/// fewest-jumps route is drawn hop by hop, green where your current fuel can
/// still reach and warning-red past that. Systems you've never visited (or
/// aren't linked to one you have, or haven't charted with a map outfit) aren't
/// drawn at all — real fog of war. Drag to pan; pinch, +/- to zoom.
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

            chrome
        }
        .novaResponsive()
        .onAppear { rebuildGovtColors() }
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

    private func factionColor(for government: Int) -> Color {
        guard government >= 0, let color = govtColors[government] else { return independentColor }
        return color
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
        let labelSize = NovaFontRole.hud.baseSize * min(min(size.width / 1024, size.height / 768), 2.2)

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
            // affordability, otherwise faction color if known, dim grey if only
            // seen-as-adjacent (unconfirmed allegiance).
            let r: CGFloat = isCurrent || isDestination ? 3.5 : (isKnownDetail ? 2.5 : 2.0)
            let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            if isCurrent {
                ctx.fill(dot, with: .color(amber))
            } else if onRoute {
                ctx.fill(dot, with: .color(hopAffordable ? routeGreen : routeWarn))
            } else if isKnownDetail {
                ctx.fill(dot, with: .color(factionColor(for: s.government)))
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

    // MARK: Chrome

    private var chrome: some View {
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
            // A live tick so the fuel-dependent course readout / JUMP button
            // reflect fuel regenerating in the background while the map is open.
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in courseBar }
        }
        .padding(14)
    }

    @ViewBuilder
    private var courseBar: some View {
        if let destID = nav.destinationID, let dest = nav.system(destID), let game = nav.game {
            let hops = nav.nextJumpHopCount
            let canGo = nav.canAfford(hops: hops)
            let explored = pilot.state.exploredSystems
            let destKnown = nav.visibility(of: destID, explored: explored,
                                           adjacent: nav.adjacentToExplored(explored),
                                           mapRevealAll: pilot.ownsMapOutfit(game: game))
                != .adjacent
            let destName = destKnown ? dest.name : "Unexplored"
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("COURSE: \(destName) — \(nav.route.count) JUMP\(nav.route.count == 1 ? "" : "S")")
                        .novaFont(.hud, weight: .semibold)
                        .foregroundStyle(nav.route.count <= nav.availableJumps ? routeGreen : routeWarn)
                    Text("FUEL: \(Int(nav.currentFuel))/\(Int(nav.shipMaxFuel))  (\(nav.availableJumps) jump\(nav.availableJumps == 1 ? "" : "s"))")
                        .novaFont(.hud).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
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
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
        } else {
            Text("Click a system to plot a course • drag to pan • pinch or +/− to zoom")
                .novaFont(.caption).foregroundStyle(.secondary)
        }
    }

    private func zoomButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.subheadline)
                .padding(8).background(.ultraThinMaterial, in: Circle())
        }.buttonStyle(.plain)
    }
}
