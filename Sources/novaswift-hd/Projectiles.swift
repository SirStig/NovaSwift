import Foundation
import SceneKit
import simd

/// Procedural shots with a body: missiles, rockets and torpedoes, built from
/// the hard-surface kit and coloured from the classic sprite. Model space as
/// for ships: nose +Z, up +Y.
enum ProjectileMaker {
    enum Style: String { case missile, rocket, torpedo, hellhound }

    static func make(_ style: Style, body: SIMD3<Double>, accent: SIMD3<Double>, kit: MaterialKit) -> SCNScene {
        let shell = Mesh(), trim = Mesh(), fins = Mesh(), exhaust = Mesh()
        let seg = 16
        // Proportions per style: half-length 1, radius r.
        let r: Float = style == .torpedo ? 0.26 : style == .rocket ? 0.21 : 0.15
        let tail: Float = -1, noseStart: Float = style == .torpedo ? 0.55 : 0.45

        shell.cylinderZ(x: 0, y: 0, z0: tail + 0.08, z1: noseStart, r0: r, r1: r, segments: seg)
        // Ogive nose: a few tapering rings.
        let noseLen: Float = style == .torpedo ? 0.42 : 0.55
        let steps = 6
        var rings: [[V3]] = []
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let rr = max(r * sqrt(max(0, 1 - t * t)), 0.004)
            let z = noseStart + noseLen * t
            rings.append((0..<seg).map { k in
                let a = Float(k) / Float(seg) * 2 * .pi
                return V3(cos(a) * rr, sin(a) * rr, z)
            })
        }
        trim.loft(rings, capStart: false, capEnd: true)
        // A band just behind the nose, and the tail nozzle.
        trim.cylinderZ(x: 0, y: 0, z0: noseStart - 0.12, z1: noseStart - 0.05, r0: r * 1.06, r1: r * 1.06, segments: seg)
        trim.cylinderZ(x: 0, y: 0, z0: tail, z1: tail + 0.1, r0: r * 0.7, r1: r * 0.95, segments: seg)

        // Fins: four (missile, hellhound), short ones (rocket), none on torpedoes.
        if style != .torpedo {
            let span: Float = style == .rocket ? r * 1.6 : r * 2.4
            let root0: Float = tail + 0.12, root1: Float = style == .rocket ? tail + 0.38 : tail + 0.5
            for k in 0..<4 {
                let a = Float(k) * .pi / 2 + .pi / 4
                let dir = V3(cos(a), sin(a), 0), side = V3(-sin(a), cos(a), 0) * 0.012
                let inner0 = dir * r + V3(0, 0, root0), inner1 = dir * r + V3(0, 0, root1)
                let outer0 = dir * (r + span) + V3(0, 0, root0), outer1 = dir * (r + span) + V3(0, 0, root0 + 0.14)
                fins.part(center: dir * r + V3(0, 0, (root0 + root1) / 2)) {
                    fins.quad(inner0 + side, outer0 + side, outer1 + side, inner1 + side)
                    fins.quad(inner0 - side, inner1 - side, outer1 - side, outer0 - side)
                }
            }
            // Canards near the nose for missiles.
            if style == .missile || style == .hellhound {
                for k in 0..<4 {
                    let a = Float(k) * .pi / 2 + .pi / 4
                    let dir = V3(cos(a), sin(a), 0), side = V3(-sin(a), cos(a), 0) * 0.01
                    let z0 = noseStart - 0.32, z1 = noseStart - 0.16
                    fins.part(center: dir * r + V3(0, 0, (z0 + z1) / 2)) {
                        fins.quad(dir * r + V3(0, 0, z0) + side, dir * (r * 2) + V3(0, 0, z0 + 0.04) + side,
                                  dir * (r * 2) + V3(0, 0, z1) + side, dir * r + V3(0, 0, z1) + side)
                    }
                }
            }
        }
        // Exhaust: a glowing disc in the nozzle; the Hellhound trails a flame.
        exhaust.cylinderZ(x: 0, y: 0, z0: tail - 0.01, z1: tail + 0.02, r0: r * 0.62, r1: r * 0.62, segments: seg)
        if style == .hellhound {
            exhaust.cylinderZ(x: 0, y: 0, z0: tail - 0.55, z1: tail, r0: 0.01, r1: r * 0.7, segments: seg)
        }

        let bodyMat = kit.solid("body", color: body, metalness: 0.55, roughness: 0.38)
        let trimMat = kit.solid("trim", color: accent, metalness: 0.3, roughness: 0.45)
        let finMat = kit.solid("fins", color: body * 0.7, metalness: 0.5, roughness: 0.5)
        let glowColor: SIMD3<Double> = style == .hellhound ? SIMD3(1.0, 0.55, 0.15) : SIMD3(1.0, 0.75, 0.4)
        let scene = SCNScene()
        scene.rootNode.addChildNode(ShipDesigns.assemble([
            (shell, bodyMat, "body"), (trim, trimMat, "trim"), (fins, finMat, "fins"),
            (exhaust, kit.glow("engine", glowColor), "engine"),
        ]))
        return scene
    }
}
