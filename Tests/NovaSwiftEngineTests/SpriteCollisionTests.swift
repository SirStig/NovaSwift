import XCTest
@testable import NovaSwiftEngine
@testable import NovaSwiftKit

/// WP-17: direct shot contact reads the hull's opaque pixels
/// (`Ship_HandleSpritePairCollision` 0x004374f0), with the strict bounding
/// circle for hulls 32 px wide or less.
final class SpriteCollisionTests: XCTestCase {

    // MARK: Pure geometry

    private func solid(_ w: Int, _ h: Int, opaque: Bool) -> SpriteMaskSet {
        let words = (w + 63) >> 6
        var bits = [UInt64](repeating: 0, count: words * h)
        if opaque { for y in 0..<h { for x in 0..<w { bits[y * words + (x >> 6)] |= 1 << UInt64(x & 63) } } }
        return SpriteMaskSet(width: w, height: h, frameCount: 1, bits: bits)
    }

    func testHeadingFrameTruncates() {
        XCTAssertEqual(SpriteFrames.headingFrame(degrees: 0, frames: 36), 0)
        XCTAssertEqual(SpriteFrames.headingFrame(degrees: 9, frames: 36), 0)    // rounding would say 1
        XCTAssertEqual(SpriteFrames.headingFrame(degrees: 10, frames: 36), 1)
        XCTAssertEqual(SpriteFrames.headingFrame(angle: .pi / 2, frames: 36), 9)
        XCTAssertEqual(SpriteFrames.headingFrame(degrees: 359, frames: 36), 35)
        XCTAssertEqual(SpriteFrames.headingFrame(degrees: -1, frames: 36), 35)
    }

    /// A hull frame ≤ 32 px wide uses the circle even where it is transparent.
    func testNarrowHullUsesTheCircle() {
        let ship = ContactSprite.hull(solid(32, 32, opaque: false), frame: 0, at: Vec2())
        let shot = ContactSprite.shot(nil, frame: 0, at: Vec2(3, 3))
        XCTAssertTrue(SpriteContact.shotTouchesShip(ship: ship, shot: shot))
        let wide = ContactSprite.hull(solid(33, 33, opaque: false), frame: 0, at: Vec2())
        XCTAssertFalse(SpriteContact.shotTouchesShip(ship: wide, shot: shot))
    }

    /// The circle is strict: centres exactly the summed radii apart miss.
    func testCircleIsStrict() {
        let a = ContactSprite(mask: solid(20, 20, opaque: true), frame: 0, left: 0, top: 0)
        let touching = ContactSprite(mask: solid(20, 20, opaque: true), frame: 0, left: 20, top: 0)
        let inside = ContactSprite(mask: solid(20, 20, opaque: true), frame: 0, left: 19, top: 0)
        XCTAssertFalse(SpriteContact.circlesOverlap(a, touching))
        XCTAssertTrue(SpriteContact.circlesOverlap(a, inside))
    }

    // MARK: Stock data

    private func stockGalaxy() throws -> Galaxy {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        return Galaxy(game: NovaGame(try GameLibrary.merge(baseFiles: files)))
    }

    /// A stock hull wider than 32 px whose heading-0 frame has an opaque
    /// centre and a transparent pixel well inside its old round outline.
    private func cornerHull(_ galaxy: Galaxy) throws -> (id: Int, hull: Galaxy.HullCollisionMask, x: Int, y: Int) {
        for s in galaxy.game.ships() {
            guard let hull = galaxy.hullCollisionMask(s.id), hull.mask.width > 40 else { continue }
            let m = hull.mask
            guard m.isOpaque(frame: 0, x: m.width / 2, y: m.height / 2) else { continue }
            let r = Double(min(m.width, m.height)) / 2 * 0.8
            for y in 0..<m.height { for x in 0..<m.width where !m.isOpaque(frame: 0, x: x, y: y) {
                let dx = Double(x - m.width / 2) + 0.5, dy = Double(y - m.height / 2) + 0.5
                if (dx * dx + dy * dy).squareRoot() < r { return (s.id, hull, x, y) }
            } }
        }
        throw XCTSkip("no suitable stock hull")
    }

    /// The world point a single-pixel shot needs to land on hull pixel (x, y)
    /// of a ship at the origin.
    private func point(x: Int, y: Int, in m: SpriteMaskSet) -> Vec2 {
        Vec2(Double(x - m.width / 2) + 0.5, -(Double(y - m.height / 2) + 0.5))
    }

    private func world(_ galaxy: Galaxy, hull id: Int) throws -> (World, Ship) {
        let w = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                   position: Vec2(5000, 5000)))
        w.galaxy = galaxy
        w.diplomacy = galaxy.makeDiplomacy()
        let npc = try XCTUnwrap(galaxy.makeShip(id, at: Vec2(), angle: 0))
        w.addNPC(npc)
        return (w, npc)
    }

    private func shot(at p: Vec2, owner: Ship, spin: Int? = nil) -> Projectile {
        Projectile(position: p, velocity: Vec2(), life: 1, shieldDamage: 1, armorDamage: 1, blastRadius: 0,
                   ownerID: owner.entityID, ownerGovt: -1, homing: false, turnRate: 0, speed: 0,
                   targetID: nil, graphicSpinID: spin)
    }

    func testShotThroughATransparentCornerMisses() throws {
        let galaxy = try stockGalaxy()
        let (id, hull, cx, cy) = try cornerHull(galaxy)
        let (w, npc) = try world(galaxy, hull: id)
        let m = hull.mask
        let corner = shot(at: point(x: cx, y: cy, in: m), owner: w.player)
        XCTAssertNil(w.spriteContact(corner, from: corner.position, rawCalls: 1),
                     "hull \(id): the corner is inside the old circle but clear on the sprite")
        XCTAssertLessThan(corner.position.length, max(Double(m.width), Double(m.height)) / 2,
                          "the corner sits inside the round outline")
        let centre = shot(at: point(x: m.width / 2, y: m.height / 2, in: m), owner: w.player)
        XCTAssertTrue(w.spriteContact(centre, from: centre.position, rawCalls: 1) === npc)
    }

    func testCornerMissThroughAFullWorldStep() throws {
        let galaxy = try stockGalaxy()
        let (id, hull, cx, cy) = try cornerHull(galaxy)
        let (w, _) = try world(galaxy, hull: id)
        let corner = shot(at: point(x: cx, y: cy, in: hull.mask), owner: w.player)
        w.testInjectProjectile(corner)
        w.step(1.0 / 30.0)
        XCTAssertTrue(corner.alive, "hull \(id)")
    }

    /// A real shot graphic overlaps by its own opaque pixels too.
    func testRealShotSpriteHitsTheHull() throws {
        let galaxy = try stockGalaxy()
        let (id, hull, cx, cy) = try cornerHull(galaxy)
        let (w, npc) = try world(galaxy, hull: id)
        guard let weapon = galaxy.game.weapons().first(where: { !$0.isBeam
                && $0.graphicSpinID.flatMap { galaxy.shotCollisionMask(spinID: $0) }.map { $0.opaqueCount(frame: 0) > 0 } == true }),
              let spin = weapon.graphicSpinID
        else { throw XCTSkip("no stock shot graphic") }
        let m = hull.mask
        let s = shot(at: point(x: m.width / 2, y: m.height / 2, in: m), owner: w.player, spin: spin)
        XCTAssertTrue(w.spriteContact(s, from: s.position, rawCalls: 1) === npc)
        let far = shot(at: Vec2(Double(m.width), Double(m.height)), owner: w.player, spin: spin)
        XCTAssertNil(w.spriteContact(far, from: far.position, rawCalls: 1))
    }

    /// Mask contact cost: one broad-phase pass plus one pixel test per hit
    /// candidate, against a real hull with a real shot.
    func testMaskContactPerformance() throws {
        let galaxy = try stockGalaxy()
        let (_, hull, _, _) = try cornerHull(galaxy)
        guard let shotMask = galaxy.game.weapons().lazy.filter({ !$0.isBeam })
                .compactMap({ $0.graphicSpinID.flatMap { galaxy.shotCollisionMask(spinID: $0) } }).first
        else { throw XCTSkip("no stock shot graphic") }
        let ship = ContactSprite.hull(hull.mask, frame: hull.frame(angle: 0.7), at: Vec2())
        var hits = 0
        let n = 200_000
        let start = Date()
        for i in 0..<n {
            let p = Vec2(Double(i % 97) - 48, Double((i / 97) % 89) - 44)
            let s = ContactSprite.shot(shotMask, frame: 0, at: p)
            if SpriteContact.boundsOverlap(ship, s), SpriteContact.shotTouchesShip(ship: ship, shot: s) { hits += 1 }
        }
        let ns = Date().timeIntervalSince(start) / Double(n) * 1e9
        print("WP-17 mask contact: \(String(format: "%.0f", ns)) ns/test, \(hits)/\(n) hits, hull \(hull.mask.width)×\(hull.mask.height), shot \(shotMask.width)×\(shotMask.height)")
        XCTAssertGreaterThan(hits, 0)
    }
}
