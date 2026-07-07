import SwiftUI
import EVNovaKit

/// The galaxy map: systems plotted at their real coordinates, centered on the
/// current system, with hyperspace links. Directly-linked systems are cyan and
/// tappable to jump. Drag to pan; pinch (or +/–) to zoom.
struct GalaxyMapView: View {
    @ObservedObject var nav: NavigationModel
    var onClose: () -> Void

    @State private var pan: CGSize = .zero
    @State private var zoom: CGFloat = 0.09

    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)

    var body: some View {
        let systems = nav.systems()
        let neighborIDs = Set(nav.current?.links ?? [])
        let cx = nav.current?.x ?? 0
        let cy = nav.current?.y ?? 0

        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()

            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2 + pan.width,
                                     y: geo.size.height / 2 + pan.height)
                let plot: (Int, Int) -> CGPoint = { x, y in
                    CGPoint(x: center.x + CGFloat(x - cx) * zoom,
                            y: center.y + CGFloat(y - cy) * zoom)
                }

                Canvas { ctx, _ in
                    var byID: [Int: SystRes] = [:]
                    for s in systems { byID[s.id] = s }
                    // Links.
                    for s in systems {
                        let a = plot(s.x, s.y)
                        for link in s.links {
                            guard let n = byID[link], link > s.id else { continue }
                            var p = Path(); p.move(to: a); p.addLine(to: plot(n.x, n.y))
                            ctx.stroke(p, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                        }
                    }
                    // Non-interactive system dots.
                    for s in systems where s.id != nav.currentSystemID && !neighborIDs.contains(s.id) {
                        let p = plot(s.x, s.y)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x-2, y: p.y-2, width: 4, height: 4)),
                                 with: .color(.white.opacity(0.35)))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { pan.width += $0.translation.width - dragLast.width
                    pan.height += $0.translation.height - dragLast.height; dragLast = $0.translation }
                    .onEnded { _ in dragLast = .zero })

                // Neighbors (tappable) + current, drawn on top with labels.
                ForEach(nav.neighbors(), id: \.id) { s in
                    let p = plot(s.x, s.y)
                    Button { _ = nav.jump(to: s.id) } label: {
                        VStack(spacing: 3) {
                            Circle().fill(.cyan).frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white, lineWidth: 1))
                            Text(s.name).font(.system(size: 11, design: .monospaced).weight(.medium))
                                .foregroundStyle(.cyan)
                                .fixedSize()
                        }
                    }
                    .buttonStyle(.plain)
                    .position(x: p.x, y: p.y)
                }
                if let cur = nav.current {
                    let p = plot(cur.x, cur.y)
                    VStack(spacing: 3) {
                        Circle().fill(amber).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(amber.opacity(0.4), lineWidth: 6))
                        Text(cur.name).font(.system(size: 12, design: .monospaced).weight(.bold))
                            .foregroundStyle(amber).fixedSize()
                    }
                    .position(x: p.x, y: p.y)
                }
            }

            // Compact chrome.
            VStack {
                HStack {
                    Text("GALAXY MAP").font(.system(.subheadline, design: .monospaced).weight(.bold))
                        .foregroundStyle(amber)
                    Spacer()
                    zoomButton("minus.magnifyingglass") { zoom = max(0.03, zoom * 0.8) }
                    zoomButton("plus.magnifyingglass") { zoom = min(0.4, zoom * 1.25) }
                    zoomButton("scope") { pan = .zero }
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.subheadline.weight(.bold))
                            .padding(8).background(.ultraThinMaterial, in: Circle())
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("Tap a cyan (linked) system to jump • drag to pan")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

    @State private var dragLast: CGSize = .zero

    private func zoomButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.subheadline)
                .padding(8).background(.ultraThinMaterial, in: Circle())
        }.buttonStyle(.plain)
    }
}
