import SwiftUI
import EVNovaKit

/// The galaxy map: systems plotted at their real coordinates with hyperspace
/// links. The current system is highlighted; directly-linked systems are cyan
/// and tappable to jump there.
struct GalaxyMapView: View {
    @ObservedObject var nav: NavigationModel
    var onClose: () -> Void

    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)

    var body: some View {
        let systems = nav.systems()
        let bounds = Self.bounds(of: systems)
        let neighborIDs = Set(nav.current?.links ?? [])

        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            GeometryReader { geo in
                let plot = Self.plotter(bounds: bounds, size: geo.size, inset: 60)

                // Links + all system dots.
                Canvas { ctx, _ in
                    var byID: [Int: SystRes] = [:]
                    for s in systems { byID[s.id] = s }
                    for s in systems {
                        let a = plot(s.x, s.y)
                        for link in s.links {
                            guard let n = byID[link] else { continue }
                            var path = Path()
                            path.move(to: a); path.addLine(to: plot(n.x, n.y))
                            ctx.stroke(path, with: .color(.white.opacity(0.10)), lineWidth: 0.5)
                        }
                    }
                    for s in systems {
                        let p = plot(s.x, s.y)
                        let color: Color = s.id == nav.currentSystemID ? amber
                            : neighborIDs.contains(s.id) ? .cyan : .white.opacity(0.3)
                        let r: CGFloat = s.id == nav.currentSystemID ? 5 : 3
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r*2, height: r*2)),
                                 with: .color(color))
                    }
                }
                // Interactive neighbor nodes (tap to jump) + labels.
                ForEach(nav.neighbors(), id: \.id) { s in
                    let p = plot(s.x, s.y)
                    Button { _ = nav.jump(to: s.id) } label: {
                        VStack(spacing: 2) {
                            Circle().stroke(.cyan, lineWidth: 1.5).frame(width: 18, height: 18)
                            Text(s.name).font(.system(size: 10, design: .monospaced)).foregroundStyle(.cyan)
                        }
                    }
                    .buttonStyle(.plain)
                    .position(x: p.x, y: p.y)
                }
                // Current system label.
                if let cur = nav.current {
                    let p = plot(cur.x, cur.y)
                    Text(cur.name)
                        .font(.system(size: 11, design: .monospaced).weight(.bold))
                        .foregroundStyle(amber)
                        .position(x: p.x, y: p.y - 16)
                }
            }
            VStack {
                HStack {
                    Text("GALAXY MAP").font(.system(.headline, design: .monospaced)).foregroundStyle(amber)
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark").padding(8).background(.ultraThinMaterial, in: Circle())
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("Tap a cyan (linked) system to hyperspace jump.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private static func bounds(of systems: [SystRes]) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        let xs = systems.map(\.x), ys = systems.map(\.y)
        return (xs.min() ?? 0, xs.max() ?? 1, ys.min() ?? 0, ys.max() ?? 1)
    }

    /// Returns a function mapping system coordinates into the view rect.
    private static func plotter(bounds: (minX: Int, maxX: Int, minY: Int, maxY: Int),
                                size: CGSize, inset: CGFloat) -> (Int, Int) -> CGPoint {
        let w = max(1, CGFloat(bounds.maxX - bounds.minX))
        let h = max(1, CGFloat(bounds.maxY - bounds.minY))
        let sx = (size.width - inset * 2) / w
        let sy = (size.height - inset * 2) / h
        let s = min(sx, sy)
        return { x, y in
            CGPoint(x: inset + (CGFloat(x - bounds.minX)) * s,
                    y: inset + (CGFloat(y - bounds.minY)) * s)
        }
    }
}
