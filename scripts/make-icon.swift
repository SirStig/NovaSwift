#!/usr/bin/env swift
// Draws the app's ORIGINAL icon (a stylized starship over a ringed planet) to a
// 1024×1024 PNG. No EV Nova artwork is used — this is our own mark, safe to ship.
// Usage: swift scripts/make-icon.swift <out.png>
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

// Background gradient (deep space — near-black navy).
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.02, green: 0.02, blue: 0.06, alpha: 1),
    CGColor(red: 0.06, green: 0.03, blue: 0.10, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: P(0, 0), end: P(1, 1),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Warm nebula glow (amber/magenta).
let glow = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 0.38),
    CGColor(red: 0.7, green: 0.15, blue: 0.35, alpha: 0.12),
    CGColor(red: 0.7, green: 0.15, blue: 0.35, alpha: 0)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawRadialGradient(glow, startCenter: P(0.5, 0.5), startRadius: 0,
                       endCenter: P(0.5, 0.5), endRadius: 0.45 * s, options: [])

// Stars.
for (x, y, r) in [(0.22, 0.24, 0.010), (0.78, 0.72, 0.009), (0.28, 0.74, 0.007),
                  (0.72, 0.26, 0.006), (0.5, 0.16, 0.006)] {
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    ctx.fillEllipse(in: CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s,
                               width: CGFloat(r) * s, height: CGFloat(r) * s))
}

// Planet (clipped gradient).
ctx.saveGState()
let planet = CGRect(x: 0.30 * s, y: 0.34 * s, width: 0.34 * s, height: 0.34 * s)
ctx.addEllipse(in: planet); ctx.clip()
let planetGrad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.30, green: 0.45, blue: 0.85, alpha: 1),
    CGColor(red: 0.10, green: 0.12, blue: 0.35, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(planetGrad, start: P(0.30, 0.34), end: P(0.64, 0.68),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// Ring (tilted ellipse stroke).
ctx.saveGState()
ctx.translateBy(x: 0.5 * s, y: 0.54 * s)
ctx.rotate(by: -18 * .pi / 180)
ctx.translateBy(x: -0.5 * s, y: -0.54 * s)
ctx.setStrokeColor(CGColor(red: 1.0, green: 0.68, blue: 0.25, alpha: 0.9))
ctx.setLineWidth(0.026 * s)
ctx.strokeEllipse(in: CGRect(x: 0.18 * s, y: 0.44 * s, width: 0.64 * s, height: 0.20 * s))
ctx.restoreGState()

// Starship (swept arrow), with a warm amber glow.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 0.025 * s,
              color: CGColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 0.95))
ctx.beginPath()
ctx.move(to: P(0.70, 0.24))
ctx.addLine(to: P(0.52, 0.44))
ctx.addLine(to: P(0.60, 0.44))
ctx.addLine(to: P(0.46, 0.60))
ctx.addLine(to: P(0.66, 0.42))
ctx.addLine(to: P(0.58, 0.42))
ctx.closePath()
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(size)x\(size))")
