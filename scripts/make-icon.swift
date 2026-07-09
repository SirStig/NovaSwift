#!/usr/bin/env swift
// Draws the app's ORIGINAL icon (a stylized interceptor banking across a
// ringed planet) to a 1024x1024 PNG. No EV Nova artwork is used — this is
// our own mark, safe to ship. Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}
let s = CGFloat(size)

// Flip to top-left origin so coordinates match the SwiftUI AppMark.
ctx.translateBy(x: 0, y: s)
ctx.scaleBy(x: 1, y: -1)
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

// ---- Background: deep space, cool navy with a warm nebula glow ----
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.035, green: 0.045, blue: 0.09, alpha: 1),
    CGColor(red: 0.01, green: 0.012, blue: 0.03, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: P(0.15, 0.05), end: P(0.85, 1.0),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

let glow = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.95, green: 0.5, blue: 0.2, alpha: 0.18),
    CGColor(red: 0.45, green: 0.25, blue: 0.55, alpha: 0.06),
    CGColor(red: 0.45, green: 0.25, blue: 0.55, alpha: 0)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawRadialGradient(glow, startCenter: P(0.58, 0.46), startRadius: 0,
                       endCenter: P(0.58, 0.46), endRadius: 0.5 * s, options: [])

// Stars — crisp pinpoints, varied size/opacity.
let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (0.16, 0.20, 0.006, 0.9), (0.86, 0.18, 0.005, 0.7), (0.20, 0.82, 0.005, 0.8),
    (0.88, 0.62, 0.007, 0.9), (0.10, 0.55, 0.004, 0.6), (0.78, 0.86, 0.004, 0.6),
    (0.46, 0.10, 0.004, 0.5), (0.92, 0.36, 0.004, 0.5)
]
for (x, y, r, a) in stars {
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: a))
    ctx.fillEllipse(in: CGRect(x: x * s - r * s / 2, y: y * s - r * s / 2, width: r * s, height: r * s))
}

// ---- Ring + planet with real, seamless depth ----
let planetCenter = CGPoint(x: 0.44 * s, y: 0.56 * s)
let planetR = CGFloat(0.195) * s
let planetRect = CGRect(x: planetCenter.x - planetR, y: planetCenter.y - planetR,
                        width: planetR * 2, height: planetR * 2)

let ringCenter = CGPoint(x: 0.5 * s, y: 0.58 * s)
let ringRX = CGFloat(0.36) * s
let ringRY = CGFloat(0.095) * s
let ringTilt = CGFloat(-16) * .pi / 180

// Point on the tilted ring ellipse for parameter t in [0, 1). `depth` is
// sin(angle): positive on the near side (drawn in front of the planet),
// negative on the far side (drawn behind it).
func ringPoint(_ t: CGFloat) -> (pt: CGPoint, depth: CGFloat) {
    let a = t * 2 * .pi
    let ex = cos(a) * ringRX, ey = sin(a) * ringRY
    let rx = ex * cos(ringTilt) - ey * sin(ringTilt)
    let ry = ex * sin(ringTilt) + ey * cos(ringTilt)
    return (CGPoint(x: ringCenter.x + rx, y: ringCenter.y + ry), sin(a))
}

let dimColor = (r: CGFloat(0.62), g: CGFloat(0.44), b: CGFloat(0.24))
let brightColor = (r: CGFloat(1.0), g: CGFloat(0.76), b: CGFloat(0.38))
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

// Draws the ring in bands, each one continuous multi-point stroke so the
// depth gradient reads smoothly with no seam where near meets far.
func drawRingSegments(under: Bool) {
    let bands = 20
    let subSteps = 10
    for b in 0..<bands {
        let bt0 = CGFloat(b) / CGFloat(bands)
        let bt1 = CGFloat(b + 1) / CGFloat(bands)
        let (_, dMid) = ringPoint((bt0 + bt1) / 2)
        if !under && dMid < -0.06 { continue }
        let f = (dMid + 1) / 2
        let mixF = under ? f * 0.85 : f
        let color = CGColor(red: lerp(dimColor.r, brightColor.r, mixF),
                            green: lerp(dimColor.g, brightColor.g, mixF),
                            blue: lerp(dimColor.b, brightColor.b, mixF),
                            alpha: under ? 0.6 : 1.0)
        let width = lerp(0.014, 0.023, f) * s
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        for step in 0...subSteps {
            let t = bt0 + (bt1 - bt0) * CGFloat(step) / CGFloat(subSteps)
            let (pt, _) = ringPoint(t)
            if step == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
        }
        ctx.strokePath()
    }
}

drawRingSegments(under: true)

// Planet — single smooth radial gradient, offset highlight for a sphere feel.
ctx.saveGState()
ctx.addEllipse(in: planetRect)
ctx.clip()
let planetGrad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.62, green: 0.74, blue: 0.97, alpha: 1),
    CGColor(red: 0.42, green: 0.53, blue: 0.88, alpha: 1),
    CGColor(red: 0.22, green: 0.30, blue: 0.66, alpha: 1),
    CGColor(red: 0.07, green: 0.09, blue: 0.26, alpha: 1)] as CFArray, locations: [0, 0.35, 0.7, 1])!
ctx.drawRadialGradient(planetGrad,
                       startCenter: CGPoint(x: planetCenter.x - 0.05 * s, y: planetCenter.y - 0.05 * s), startRadius: 0,
                       endCenter: CGPoint(x: planetCenter.x + 0.03 * s, y: planetCenter.y + 0.03 * s), endRadius: planetR * 1.55,
                       options: [])
ctx.restoreGState()

drawRingSegments(under: false)

// ---- Ship: interceptor silhouette, banking across the scene ----
ctx.saveGState()
let shipCenter = P(0.665, 0.335)
let shipScale = 0.205 * s
let shipAngle = CGFloat(34) * .pi / 180
ctx.translateBy(x: shipCenter.x, y: shipCenter.y)
ctx.rotate(by: shipAngle)

func L(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * shipScale, y: y * shipScale) }

// Engine glow — small, centered on the tail, mostly hidden by the hull.
ctx.saveGState()
let engineGlow = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1.0, green: 0.78, blue: 0.4, alpha: 0.9),
    CGColor(red: 1.0, green: 0.5, blue: 0.2, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(engineGlow, startCenter: L(0, 0.52), startRadius: 0,
                       endCenter: L(0, 0.52), endRadius: 0.16 * shipScale, options: [])
ctx.restoreGState()

// Hull: bold delta/dart silhouette (nose up), single tail notch — reads
// cleanly at any size, unlike a shape with many fine concave details.
var hull = CGMutablePath()
hull.move(to: L(0, -1.05))          // nose
hull.addLine(to: L(0.16, -0.30))    // right shoulder
hull.addLine(to: L(0.82, 0.62))     // right wingtip
hull.addLine(to: L(0.20, 0.30))     // right tail notch
hull.addLine(to: L(0, 0.50))        // tail center
hull.addLine(to: L(-0.20, 0.30))    // left tail notch
hull.addLine(to: L(-0.82, 0.62))    // left wingtip
hull.addLine(to: L(-0.16, -0.30))   // left shoulder
hull.closeSubpath()

// Crisp fill, no drop shadow (a shadow behind a concave hull bleeds an ugly
// dark wedge onto the planet).
ctx.saveGState()
ctx.addPath(hull)
ctx.clip()
let hullGrad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1),
    CGColor(red: 0.70, green: 0.79, blue: 0.95, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hullGrad, start: L(0, -1.05), end: L(0, 0.62), options: [])
ctx.restoreGState()

// Thin dark edge so the ship separates cleanly from bright backgrounds.
ctx.addPath(hull)
ctx.setStrokeColor(CGColor(red: 0.10, green: 0.12, blue: 0.22, alpha: 0.35))
ctx.setLineWidth(0.006 * shipScale)
ctx.strokePath()

// Centerline crease for a touch of dimensionality at large sizes.
ctx.setStrokeColor(CGColor(red: 0.32, green: 0.40, blue: 0.58, alpha: 0.55))
ctx.setLineWidth(0.008 * shipScale)
ctx.beginPath()
ctx.move(to: L(0, -1.0))
ctx.addLine(to: L(0, 0.46))
ctx.strokePath()

// Cockpit glint.
ctx.setFillColor(CGColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 0.9))
ctx.fillEllipse(in: CGRect(x: L(0, -0.55).x - 0.05 * shipScale, y: L(0, -0.55).y - 0.09 * shipScale,
                           width: 0.10 * shipScale, height: 0.18 * shipScale))

ctx.restoreGState()

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(size)x\(size))")
