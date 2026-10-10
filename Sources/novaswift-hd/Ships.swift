import Foundation
import SceneKit
import simd

/// The demo pack's ships: original designs that fill the roles, footprints
/// and palette of three EV Nova hulls (a starter shuttle, a light courier, a
/// military destroyer) without copying any of them. Model space: nose +Z,
/// up +Y, ship's left = +X. Everything is modelled on the left side and
/// mirrored unless it's on the centre line.
enum ShipDesigns {
    /// An octagonal hull section at `z`: half-width `w`, half-height `h`,
    /// centred at height `y`, corners cut by `chamfer` (0…1).
    static func section(_ z: Float, w: Float, h: Float, y: Float = 0, x: Float = 0, chamfer: Float = 0.45) -> [V3] {
        let c = 1 - chamfer
        return [V3(x + w, y + h * c, z), V3(x + w * c, y + h, z), V3(x - w * c, y + h, z),
                V3(x - w, y + h * c, z), V3(x - w, y - h * c, z), V3(x - w * c, y - h, z),
                V3(x + w * c, y - h, z), V3(x + w, y - h * c, z)]
    }

    static func assemble(_ parts: [(Mesh, SCNMaterial, String)]) -> SCNNode {
        let root = SCNNode()
        for (mesh, mat, name) in parts where !mesh.isEmpty { root.addChildNode(mesh.node(mat, name: name)) }
        return root
    }

    // Shared palette: engine plasma, running lights, glass.
    static func plasma(_ k: MaterialKit) -> SCNMaterial { k.glow("engine", SIMD3(0.55, 0.78, 1.0)) }
    static func glass(_ k: MaterialKit) -> SCNMaterial {
        k.solid("glass", color: SIMD3(0.05, 0.12, 0.16), metalness: 0.1, roughness: 0.08, emission: SIMD3(0.04, 0.16, 0.2))
    }
    static func dark(_ k: MaterialKit) -> SCNMaterial {
        k.solid("dark", color: SIMD3(0.11, 0.11, 0.13), metalness: 0.8, roughness: 0.35)
    }

    // MARK: Skiff — a compact twin-pod shuttle

    static func skiff(_ k: MaterialKit) -> SCNNode {
        let hull = Mesh(), pods = Mesh(), dark = Mesh(), engine = Mesh(), canopy = Mesh(), accent = Mesh()
        let red = Mesh(), green = Mesh(), white = Mesh()
        hull.loft([
            section(-1.00, w: 0.42, h: 0.24, y: 0.00),
            section(-0.60, w: 0.50, h: 0.30, y: 0.02),
            section( 0.10, w: 0.50, h: 0.30, y: 0.04),
            section( 0.60, w: 0.40, h: 0.25, y: 0.02),
            section( 0.95, w: 0.24, h: 0.16, y: 0.00),
            section( 1.12, w: 0.09, h: 0.07, y: -0.02),
        ])
        // Left side; mirrored below.
        pods.cylinderZ(x: 0.66, y: -0.02, z0: -1.02, z1: -0.15, r0: 0.17, r1: 0.19)
        pods.cylinderZ(x: 0.66, y: -0.02, z0: -0.15, z1: 0.18, r0: 0.19, r1: 0.07)
        pods.slab([V2(0.44, -0.85), V2(0.44, -0.25), V2(0.62, -0.20), V2(0.62, -0.90)], y0: -0.07, y1: 0.03, bevel: 0.015)
        dark.cylinderZ(x: 0.66, y: -0.02, z0: -1.12, z1: -1.0, r0: 0.15, r1: 0.18, capStart: false, capEnd: false)
        engine.cylinderZ(x: 0.66, y: -0.02, z0: -1.08, z1: -1.06, r0: 0.13, r1: 0.13)
        pods.mirrorX(); dark.mirrorX(); engine.mirrorX()
        red.box(center: V3(0.66, 0.16, 0.05), size: V3(0.06, 0.04, 0.06))
        green.box(center: V3(-0.66, 0.16, 0.05), size: V3(0.06, 0.04, 0.06))
        // Centre line.
        canopy.dome(center: V3(0, 0.22, 0.42), scale: V3(0.27, 0.16, 0.40))
        accent.box(center: V3(0, 0.335, -0.35), size: V3(0.13, 0.02, 0.85))
        dark.box(center: V3(0, 0.0, -1.03), size: V3(0.5, 0.3, 0.06))
        white.box(center: V3(0, 0.30, -0.92), size: V3(0.05, 0.04, 0.05))

        let paint = MaterialKit.Paint(base: SIMD3(0.66, 0.68, 0.72), panelSize: 48, seed: 11)
        let podPaint = MaterialKit.Paint(base: SIMD3(0.48, 0.5, 0.55), panelSize: 40, seed: 12)
        return assemble([
            (hull, k.hull("skiff_hull", paint), "hull"),
            (pods, k.hull("skiff_pods", podPaint), "pods"),
            (dark, ShipDesigns.dark(k), "nozzles"),
            (engine, plasma(k), "engine"),
            (canopy, glass(k), "canopy"),
            (accent, k.solid("accent", color: SIMD3(0.82, 0.46, 0.14), metalness: 0.2, roughness: 0.5), "stripe"),
            (red, k.glow("light_red", SIMD3(1, 0.15, 0.1)), "light_red"),
            (green, k.glow("light_green", SIMD3(0.2, 1, 0.3)), "light_green"),
            (white, k.glow("light_white", SIMD3(1, 1, 1)), "light_white"),
        ])
    }

    // MARK: Courier — a swept-wing light freighter

    static func courier(_ k: MaterialKit) -> SCNNode {
        let hull = Mesh(), wings = Mesh(), spine = Mesh(), dark = Mesh(), engine = Mesh(), canopy = Mesh()
        let accent = Mesh(), red = Mesh(), green = Mesh(), white = Mesh()
        hull.loft([
            section(-1.60, w: 0.48, h: 0.28, y: 0.00),
            section(-1.00, w: 0.62, h: 0.34, y: 0.02),
            section( 0.00, w: 0.56, h: 0.32, y: 0.03),
            section( 0.90, w: 0.40, h: 0.26, y: 0.01),
            section( 1.50, w: 0.22, h: 0.15, y: -0.02),
            section( 1.85, w: 0.06, h: 0.05, y: -0.04),
        ])
        // Left wing, wingtip pod, fin, outer engine; mirrored below.
        wings.slab([V2(0.50, -0.15), V2(1.62, -0.95), V2(1.58, -1.35), V2(0.50, -1.15)], y0: -0.09, y1: 0.02, bevel: 0.02)
        wings.cylinderZ(x: 1.6, y: -0.03, z0: -1.5, z1: -0.75, r0: 0.07, r1: 0.06)
        wings.slabX([V2(-1.62, 0.25), V2(-0.98, 0.25), V2(-1.40, 0.74), V2(-1.62, 0.74)], x0: 0.31, x1: 0.37)
        accent.box(center: V3(1.02, 0.026, -0.86), size: V3(0.55, 0.01, 0.10))
        dark.cylinderZ(x: 0.30, y: 0.0, z0: -1.78, z1: -1.58, r0: 0.12, r1: 0.15, capStart: false, capEnd: false)
        engine.cylinderZ(x: 0.30, y: 0.0, z0: -1.74, z1: -1.72, r0: 0.11, r1: 0.11)
        wings.mirrorX(); accent.mirrorX(); dark.mirrorX(); engine.mirrorX()
        red.box(center: V3(1.6, -0.03, -0.72), size: V3(0.07, 0.06, 0.05))
        green.box(center: V3(-1.6, -0.03, -0.72), size: V3(0.07, 0.06, 0.05))
        // Centre line.
        dark.cylinderZ(x: 0, y: 0.02, z0: -1.80, z1: -1.58, r0: 0.14, r1: 0.17, capStart: false, capEnd: false)
        engine.cylinderZ(x: 0, y: 0.02, z0: -1.76, z1: -1.74, r0: 0.13, r1: 0.13)
        spine.box(center: V3(0, 0.40, -0.55), size: V3(0.32, 0.12, 1.30), bevel: 0.03)
        spine.box(center: V3(0, 0.36, 0.25), size: V3(0.20, 0.07, 0.40), bevel: 0.02)
        canopy.dome(center: V3(0, 0.26, 1.0), scale: V3(0.22, 0.12, 0.42))
        white.box(center: V3(0.34, 0.75, -1.5), size: V3(0.08, 0.04, 0.05))
        white.box(center: V3(-0.34, 0.75, -1.5), size: V3(0.08, 0.04, 0.05))

        let paint = MaterialKit.Paint(base: SIMD3(0.70, 0.71, 0.70), panelSize: 44, seed: 21)
        let wingPaint = MaterialKit.Paint(base: SIMD3(0.58, 0.6, 0.62), panelSize: 36, seed: 22)
        let spinePaint = MaterialKit.Paint(base: SIMD3(0.36, 0.38, 0.42), variation: 0.1, panelSize: 30, seed: 23)
        return assemble([
            (hull, k.hull("courier_hull", paint), "hull"),
            (wings, k.hull("courier_wings", wingPaint), "wings"),
            (spine, k.hull("courier_spine", spinePaint), "spine"),
            (dark, ShipDesigns.dark(k), "nozzles"),
            (engine, plasma(k), "engine"),
            (canopy, glass(k), "canopy"),
            (accent, k.solid("accent", color: SIMD3(0.14, 0.52, 0.58), metalness: 0.3, roughness: 0.45), "stripes"),
            (red, k.glow("light_red", SIMD3(1, 0.15, 0.1)), "light_red"),
            (green, k.glow("light_green", SIMD3(0.2, 1, 0.3)), "light_green"),
            (white, k.glow("light_white", SIMD3(1, 1, 1)), "light_white"),
        ])
    }

    // MARK: Destroyer — a broad armoured warship with outboard nacelles

    static func destroyer(_ k: MaterialKit) -> SCNNode {
        let hull = Mesh(), nacelles = Mesh(), deck = Mesh(), dark = Mesh(), engine = Mesh()
        let windows = Mesh(), lights = Mesh(), accent = Mesh()
        hull.loft([
            section(-2.00, w: 0.95, h: 0.42, y: 0.05, chamfer: 0.35),
            section(-1.00, w: 1.05, h: 0.48, y: 0.06, chamfer: 0.35),
            section( 0.80, w: 0.95, h: 0.42, y: 0.04, chamfer: 0.4),
            section( 1.80, w: 0.62, h: 0.30, y: 0.00, chamfer: 0.45),
            section( 2.45, w: 0.20, h: 0.14, y: -0.04, chamfer: 0.5),
        ])
        // Left nacelle, pylon, engines, lights, stripe; mirrored below.
        nacelles.loft([
            section(-2.20, w: 0.30, h: 0.30, y: -0.02, x: 1.38, chamfer: 0.5),
            section(-1.40, w: 0.34, h: 0.34, y: 0.00, x: 1.38, chamfer: 0.5),
            section( 0.30, w: 0.30, h: 0.30, y: 0.00, x: 1.38, chamfer: 0.5),
            section( 0.80, w: 0.12, h: 0.12, y: -0.02, x: 1.38, chamfer: 0.5),
        ])
        nacelles.slab([V2(0.95, -1.70), V2(0.95, -0.10), V2(1.15, -0.30), V2(1.15, -1.60)], y0: -0.10, y1: 0.16, bevel: 0.03)
        dark.cylinderZ(x: 1.38, y: -0.02, z0: -2.34, z1: -2.16, r0: 0.22, r1: 0.27, capStart: false, capEnd: false)
        engine.cylinderZ(x: 1.38, y: -0.02, z0: -2.30, z1: -2.28, r0: 0.21, r1: 0.21)
        dark.cylinderZ(x: 0.42, y: 0.05, z0: -2.14, z1: -1.96, r0: 0.18, r1: 0.22, capStart: false, capEnd: false)
        engine.cylinderZ(x: 0.42, y: 0.05, z0: -2.10, z1: -2.08, r0: 0.17, r1: 0.17)
        for z in stride(from: Float(-1.8), through: 0.4, by: 0.55) {
            lights.box(center: V3(1.38, 0.33, z), size: V3(0.04, 0.03, 0.07))
        }
        accent.box(center: V3(0.70, 0.475, 0.2), size: V3(0.18, 0.01, 1.3))
        nacelles.mirrorX(); dark.mirrorX(); engine.mirrorX(); lights.mirrorX(); accent.mirrorX()
        // Stepped superstructure and bridge on the centre line.
        deck.slab([V2(-0.74, -1.75), V2(-0.74, 0.90), V2(0.74, 0.90), V2(0.74, -1.75)], y0: 0.40, y1: 0.60, bevel: 0.05)
        deck.slab([V2(-0.50, -1.55), V2(-0.50, -0.10), V2(0.50, -0.10), V2(0.50, -1.55)], y0: 0.60, y1: 0.80, bevel: 0.04)
        deck.slab([V2(-0.28, -1.35), V2(-0.28, -0.62), V2(0.28, -0.62), V2(0.28, -1.35)], y0: 0.80, y1: 1.06, bevel: 0.04)
        windows.box(center: V3(0, 0.96, -0.615), size: V3(0.44, 0.045, 0.01))
        for (z, y) in [(Float(0.55), Float(0.60)), (Float(1.55), Float(0.32))] {
            dark.cylinderY(x: 0, z: z, y0: y, y1: y + 0.11, r: 0.22)
            dark.box(center: V3(0.08, y + 0.07, z + 0.36), size: V3(0.045, 0.045, 0.50))
            dark.box(center: V3(-0.08, y + 0.07, z + 0.36), size: V3(0.045, 0.045, 0.50))
        }
        dark.box(center: V3(0, 1.16, -1.1), size: V3(0.05, 0.2, 0.05))   // mast

        let paint = MaterialKit.Paint(base: SIMD3(0.46, 0.49, 0.54), panelSize: 32, seed: 31)
        let deckPaint = MaterialKit.Paint(base: SIMD3(0.30, 0.34, 0.42), variation: 0.09, panelSize: 28, seed: 32)
        let nacellePaint = MaterialKit.Paint(base: SIMD3(0.38, 0.40, 0.44), panelSize: 30, seed: 33)
        return assemble([
            (hull, k.hull("destroyer_hull", paint), "hull"),
            (nacelles, k.hull("destroyer_nacelles", nacellePaint), "nacelles"),
            (deck, k.hull("destroyer_deck", deckPaint), "deck"),
            (dark, ShipDesigns.dark(k), "fittings"),
            (engine, plasma(k), "engine"),
            (windows, k.glow("windows", SIMD3(0.5, 0.9, 1.0)), "windows"),
            (lights, k.glow("deck_lights", SIMD3(0.35, 0.6, 1.0)), "lights"),
            (accent, k.solid("accent", color: SIMD3(0.75, 0.72, 0.62), metalness: 0.2, roughness: 0.5), "stripes"),
        ])
    }
}
