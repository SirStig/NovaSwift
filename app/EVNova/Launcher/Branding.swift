import SwiftUI

/// The app's original vector mark — a stylized starship banking over a ringed
/// planet against a starfield. Drawn from scratch (no EV Nova artwork is used),
/// so it is safe to ship. The same geometry is rasterised for the app icon by
/// `scripts/make-icon.swift`, keeping the icon and in-app logo identical.
struct AppMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            Canvas { ctx, _ in AppMark.draw(in: &ctx, size: s) }
        }
    }

    /// Shared drawing routine (unit-scaled to `size`).
    static func draw(in ctx: inout GraphicsContext, size s: CGFloat) {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

        // Warm nebula glow behind the planet.
        let glow = Path(ellipseIn: CGRect(x: 0.08 * s, y: 0.08 * s, width: 0.84 * s, height: 0.84 * s))
        ctx.fill(glow, with: .radialGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.15).opacity(0.38),
                              Color(red: 0.7, green: 0.15, blue: 0.35).opacity(0.12),
                              .clear]),
            center: p(0.5, 0.5), startRadius: 0, endRadius: 0.45 * s))

        // Planet.
        let planet = Path(ellipseIn: CGRect(x: 0.30 * s, y: 0.34 * s, width: 0.34 * s, height: 0.34 * s))
        ctx.fill(planet, with: .linearGradient(
            Gradient(colors: [Color(red: 0.30, green: 0.45, blue: 0.85),
                              Color(red: 0.10, green: 0.12, blue: 0.35)]),
            startPoint: p(0.30, 0.34), endPoint: p(0.64, 0.68)))

        // Ring (an ellipse stroke, tilted).
        var ring = Path()
        ring.addEllipse(in: CGRect(x: 0.18 * s, y: 0.44 * s, width: 0.64 * s, height: 0.20 * s))
        ctx.drawLayer { layer in
            layer.translateBy(x: 0.5 * s, y: 0.54 * s)
            layer.rotate(by: .degrees(-18))
            layer.translateBy(x: -0.5 * s, y: -0.54 * s)
            layer.stroke(ring, with: .color(Color(red: 1.0, green: 0.68, blue: 0.25).opacity(0.9)), lineWidth: 0.028 * s)
        }

        // Starship — a swept arrow banking upper-right.
        var ship = Path()
        ship.move(to: p(0.70, 0.24))
        ship.addLine(to: p(0.52, 0.44))
        ship.addLine(to: p(0.60, 0.44))
        ship.addLine(to: p(0.46, 0.60))
        ship.addLine(to: p(0.66, 0.42))
        ship.addLine(to: p(0.58, 0.42))
        ship.closeSubpath()
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: Color(red: 1.0, green: 0.6, blue: 0.2).opacity(0.85), radius: 0.025 * s))
            layer.fill(ship, with: .color(.white))
        }

        // A couple of stars.
        for (sx, sy, sr) in [(0.22, 0.24, 0.012), (0.78, 0.72, 0.010), (0.28, 0.74, 0.008)] {
            ctx.fill(Path(ellipseIn: CGRect(x: CGFloat(sx) * s, y: CGFloat(sy) * s,
                                            width: CGFloat(sr) * s, height: CGFloat(sr) * s)),
                     with: .color(.white.opacity(0.9)))
        }
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    AppMark().frame(width: 64, height: 64)
                    Text("EV Nova").font(.largeTitle.bold())
                    Text("an unofficial port").font(.subheadline).foregroundStyle(.secondary)
                }
                Divider()
                Text("A non-commercial, fan-made port of EV Nova to Apple platforms. Not affiliated with or endorsed by Ambrosia Software, ATMOS, or the original authors.")
                Text("Game data is not included. You supply your own legally-obtained EV Nova data via Import Data. Community plug-ins are the property of their respective authors.")
                    .foregroundStyle(.secondary)
                Text("Built on the open reimplementation work of the Escape Velocity community.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("About")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
