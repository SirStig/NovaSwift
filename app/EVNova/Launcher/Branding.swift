import SwiftUI

/// The app's original vector mark — a stylized interceptor banking across a
/// ringed planet against a starfield. Drawn from scratch (no EV Nova artwork
/// is used), so it is safe to ship. The same geometry is rasterised for the
/// app icon by `scripts/make-icon.swift`, keeping the icon and in-app logo
/// identical.
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
        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

        // Warm nebula glow.
        let glow = Path(ellipseIn: CGRect(x: 0.08 * s, y: 0.08 * s, width: 0.84 * s, height: 0.84 * s))
        ctx.fill(glow, with: .radialGradient(
            Gradient(colors: [Color(red: 0.95, green: 0.5, blue: 0.2).opacity(0.18),
                              Color(red: 0.45, green: 0.25, blue: 0.55).opacity(0.06),
                              .clear]),
            center: p(0.58, 0.46), startRadius: 0, endRadius: 0.5 * s))

        for (sx, sy, sr, sa) in [(0.16, 0.20, 0.006, 0.9), (0.86, 0.18, 0.005, 0.7), (0.20, 0.82, 0.005, 0.8),
                                  (0.88, 0.62, 0.007, 0.9), (0.10, 0.55, 0.004, 0.6), (0.78, 0.86, 0.004, 0.6)] {
            ctx.fill(Path(ellipseIn: CGRect(x: CGFloat(sx) * s, y: CGFloat(sy) * s,
                                            width: CGFloat(sr) * s, height: CGFloat(sr) * s)),
                     with: .color(.white.opacity(sa)))
        }

        // ---- Ring + planet with real, seamless depth ----
        let planetCenter = p(0.44, 0.56)
        let planetR = 0.195 * s
        let planetRect = CGRect(x: planetCenter.x - planetR, y: planetCenter.y - planetR,
                                width: planetR * 2, height: planetR * 2)

        let ringCenter = p(0.5, 0.58)
        let ringRX = 0.36 * s, ringRY = 0.095 * s
        let ringTilt = -16.0 * .pi / 180

        func ringPoint(_ t: CGFloat) -> (pt: CGPoint, depth: CGFloat) {
            let a = t * 2 * .pi
            let ex = cos(a) * ringRX, ey = sin(a) * ringRY
            let rx = ex * cos(ringTilt) - ey * sin(ringTilt)
            let ry = ex * sin(ringTilt) + ey * cos(ringTilt)
            return (CGPoint(x: ringCenter.x + rx, y: ringCenter.y + ry), sin(a))
        }

        let dim = (r: 0.62, g: 0.44, b: 0.24)
        let bright = (r: 1.0, g: 0.76, b: 0.38)

        func drawRing(under: Bool) {
            let bands = 20, subSteps = 10
            for b in 0..<bands {
                let bt0 = CGFloat(b) / CGFloat(bands), bt1 = CGFloat(b + 1) / CGFloat(bands)
                let (_, dMid) = ringPoint((bt0 + bt1) / 2)
                if !under && dMid < -0.06 { continue }
                let f = (dMid + 1) / 2
                let mixF = under ? f * 0.85 : f
                let color = Color(red: lerp(dim.r, bright.r, mixF), green: lerp(dim.g, bright.g, mixF),
                                  blue: lerp(dim.b, bright.b, mixF)).opacity(under ? 0.6 : 1.0)
                let width = lerp(0.014, 0.023, f) * s
                var band = Path()
                for step in 0...subSteps {
                    let t = bt0 + (bt1 - bt0) * CGFloat(step) / CGFloat(subSteps)
                    let (pt, _) = ringPoint(t)
                    if step == 0 { band.move(to: pt) } else { band.addLine(to: pt) }
                }
                ctx.stroke(band, with: .color(color),
                          style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }

        drawRing(under: true)

        let planet = Path(ellipseIn: planetRect)
        ctx.fill(planet, with: .radialGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.62, green: 0.74, blue: 0.97), location: 0),
                .init(color: Color(red: 0.42, green: 0.53, blue: 0.88), location: 0.35),
                .init(color: Color(red: 0.22, green: 0.30, blue: 0.66), location: 0.7),
                .init(color: Color(red: 0.07, green: 0.09, blue: 0.26), location: 1)]),
            center: CGPoint(x: planetCenter.x + 0.03 * s, y: planetCenter.y + 0.03 * s),
            startRadius: 0, endRadius: planetR * 1.55))

        drawRing(under: false)

        // ---- Ship: interceptor silhouette, banking across the scene ----
        let shipCenter = p(0.665, 0.335)
        let shipScale = 0.205 * s
        let shipAngle = Angle.degrees(34)

        ctx.drawLayer { layer in
            layer.translateBy(x: shipCenter.x, y: shipCenter.y)
            layer.rotate(by: shipAngle)

            func L(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * shipScale, y: y * shipScale) }

            let engineGlow = Path(ellipseIn: CGRect(x: L(0, 0.52).x - 0.16 * shipScale, y: L(0, 0.52).y - 0.16 * shipScale,
                                                    width: 0.32 * shipScale, height: 0.32 * shipScale))
            layer.fill(engineGlow, with: .radialGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.78, blue: 0.4).opacity(0.9),
                                  Color(red: 1.0, green: 0.5, blue: 0.2).opacity(0)]),
                center: L(0, 0.52), startRadius: 0, endRadius: 0.16 * shipScale))

            var hull = Path()
            hull.move(to: L(0, -1.05))
            hull.addLine(to: L(0.16, -0.30))
            hull.addLine(to: L(0.82, 0.62))
            hull.addLine(to: L(0.20, 0.30))
            hull.addLine(to: L(0, 0.50))
            hull.addLine(to: L(-0.20, 0.30))
            hull.addLine(to: L(-0.82, 0.62))
            hull.addLine(to: L(-0.16, -0.30))
            hull.closeSubpath()

            layer.fill(hull, with: .linearGradient(
                Gradient(colors: [.white, Color(red: 0.70, green: 0.79, blue: 0.95)]),
                startPoint: L(0, -1.05), endPoint: L(0, 0.62)))
            layer.stroke(hull, with: .color(Color(red: 0.10, green: 0.12, blue: 0.22).opacity(0.35)),
                        lineWidth: 0.006 * shipScale)

            var crease = Path()
            crease.move(to: L(0, -1.0))
            crease.addLine(to: L(0, 0.46))
            layer.stroke(crease, with: .color(Color(red: 0.32, green: 0.40, blue: 0.58).opacity(0.55)),
                        lineWidth: 0.008 * shipScale)

            let cockpit = Path(ellipseIn: CGRect(x: L(0, -0.55).x - 0.05 * shipScale, y: L(0, -0.55).y - 0.09 * shipScale,
                                                 width: 0.10 * shipScale, height: 0.18 * shipScale))
            layer.fill(cockpit, with: .color(Color(red: 0.55, green: 0.85, blue: 1.0).opacity(0.9)))
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
