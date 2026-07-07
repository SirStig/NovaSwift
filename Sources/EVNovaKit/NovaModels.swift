import Foundation

// Typed decoders for EV Nova resource *bodies*. Field offsets are the on-disk
// byte layout (big-endian), cross-checked against NovaJS `novaparse` and the
// EV Nova Bible. All multi-byte fields are big-endian (classic Mac / QuickDraw).

// MARK: Little byte helpers (big-endian, bounds-safe)

@inline(__always) private func i16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    let v = (Int(d[base]) << 8) | Int(d[base + 1])
    return v >= 0x8000 ? v - 0x10000 : v
}

@inline(__always) private func u16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    return (Int(d[base]) << 8) | Int(d[base + 1])
}

@inline(__always) private func u32(_ d: Data, _ off: Int) -> UInt32 {
    guard off >= 0, off + 4 <= d.count else { return 0 }
    let b = d.startIndex + off
    return (UInt32(d[b]) << 24) | (UInt32(d[b + 1]) << 16) | (UInt32(d[b + 2]) << 8) | UInt32(d[b + 3])
}

// MARK: spïn — sprite descriptor (which rlëD, and its tile grid)

public struct SpinRes {
    public let id: Int
    public let spriteID: Int   // → rlëD / rlë8 resource id
    public let maskID: Int
    public let tileWidth: Int
    public let tileHeight: Int
    public let tilesAcross: Int
    public let tilesDown: Int

    public init(_ r: Resource) {
        id = r.id
        let d = r.data
        spriteID = i16(d, 0)
        maskID = i16(d, 2)
        tileWidth = i16(d, 4)
        tileHeight = i16(d, 6)
        tilesAcross = i16(d, 8)
        tilesDown = i16(d, 10)
    }
}

// MARK: shän — ship animation (references the base sprite among others)

public struct ShanRes {
    public let id: Int
    public let baseSpriteID: Int   // → spïn id for the hull sprite
    public let baseSetCount: Int   // rotation frames per set
    public let baseWidth: Int
    public let baseHeight: Int

    public init(_ r: Resource) {
        id = r.id
        let d = r.data
        baseSpriteID = i16(d, 0)
        baseSetCount = i16(d, 4)
        baseWidth = i16(d, 6)
        baseHeight = i16(d, 8)
    }
}

// MARK: shïp — ship type & stats

public struct ShipRes {
    public let id: Int
    public let name: String
    public let cargoSpace: Int
    public let shield: Int
    public let acceleration: Int
    public let speed: Int          // max speed
    public let turnRate: Int
    public let armor: Int
    public let shieldRecharge: Int
    public let armorRecharge: Int
    public let mass: Int
    public let energyRecharge: Int

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Ship \(r.id)" : r.name
        let d = r.data
        cargoSpace = i16(d, 0)
        shield = i16(d, 2)
        acceleration = i16(d, 4)
        speed = i16(d, 6)
        turnRate = i16(d, 8)
        armor = i16(d, 14)
        shieldRecharge = i16(d, 16)
        armorRecharge = i16(d, 54)
        mass = i16(d, 62)
        energyRecharge = i16(d, 94)
    }
}

// MARK: sÿst — star system (map position, hyperspace links, stellar objects)

public struct SystRes {
    public let id: Int
    public let name: String
    public let x: Int
    public let y: Int
    public let links: [Int]  // ids of connected systems
    public let spobs: [Int]  // ids of stellar objects in this system

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "System \(r.id)" : r.name
        let d = r.data
        x = i16(d, 0)
        y = i16(d, 2)
        links = (0..<16).map { i16(d, 4 + $0 * 2) }.filter { $0 >= 128 }
        spobs = (0..<16).map { i16(d, 36 + $0 * 2) }.filter { $0 >= 128 }
    }
}

// MARK: spöb — stellar object (planet / station placed in a system)

public struct SpobRes {
    public let id: Int
    public let name: String
    public let x: Int
    public let y: Int
    public let graphicSpinID: Int  // → spïn id for the planet sprite
    public let flags: UInt32
    public let techLevel: Int
    public let government: Int
    public let landingPictID: Int

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Planet \(r.id)" : r.name
        let d = r.data
        x = i16(d, 0)
        y = i16(d, 2)
        // Graphic field 0..63 maps to spïn ids 2000+, with one skipped at 2058.
        var g = i16(d, 4) + 2000
        if g > 2058 { g -= 1 }
        graphicSpinID = g
        flags = u32(d, 6)
        techLevel = i16(d, 12)
        government = i16(d, 20)
        landingPictID = u16(d, 24)
    }
}

// MARK: High-level accessor over a resolved ResourceCollection

/// Typed, indexed view of a merged `ResourceCollection`. Decodes resource bodies
/// on demand and resolves cross-references (e.g. a ship → its sprite).
public struct NovaGame {
    public let resources: ResourceCollection
    public init(_ resources: ResourceCollection) { self.resources = resources }

    public func ship(_ id: Int) -> ShipRes? { resources.resource(NovaType.ship, id).map(ShipRes.init) }
    public func ships() -> [ShipRes] { resources.resources(of: NovaType.ship).map(ShipRes.init) }
    public func spin(_ id: Int) -> SpinRes? { resources.resource(NovaType.spin, id).map(SpinRes.init) }
    public func shan(_ id: Int) -> ShanRes? { resources.resource(NovaType.shan, id).map(ShanRes.init) }
    public func system(_ id: Int) -> SystRes? { resources.resource(NovaType.syst, id).map(SystRes.init) }
    public func systems() -> [SystRes] { resources.resources(of: NovaType.syst).map(SystRes.init) }
    public func spob(_ id: Int) -> SpobRes? { resources.resource(NovaType.spob, id).map(SpobRes.init) }

    /// Resolve a ship's base hull sprite: shïp id → shän (same id) → rlëD.
    ///
    /// For **ships**, the shän's base-image id references the `rlëD` directly (the
    /// spïn indirection is used for planets / weapons / asteroids, not hulls). We
    /// therefore try the direct `rlëD` first and only fall back through spïn if the
    /// data numbers it that way.
    public func shipSpriteData(_ shipID: Int) -> (spin: SpinRes?, rleD: Data)? {
        guard let shan = shan(shipID) else { return nil }
        if let rle = resources.resource(NovaType.rleD, shan.baseSpriteID)?.data {
            return (nil, rle)
        }
        if let spin = spin(shan.baseSpriteID),
           let rle = resources.resource(NovaType.rleD, spin.spriteID)?.data {
            return (spin, rle)
        }
        return nil
    }

    /// Decode a ship's base hull sprite sheet, if available.
    public func shipSprite(_ shipID: Int) -> SpriteSheet? {
        guard let (_, rle) = shipSpriteData(shipID) else { return nil }
        return try? RLED.decode(rle)
    }

    // MARK: Stellar objects

    /// Resolve a stellar object's sprite: spöb.graphic → spïn → rlëD.
    /// (Some stellars use PICT, which isn't decoded yet — those return nil.)
    public func spobSprite(_ spobID: Int) -> SpriteSheet? {
        guard let spob = spob(spobID) else { return nil }
        if let spin = spin(spob.graphicSpinID),
           let rle = resources.resource(NovaType.rleD, spin.spriteID)?.data {
            return try? RLED.decode(rle)
        }
        if let rle = resources.resource(NovaType.rleD, spob.graphicSpinID)?.data {
            return try? RLED.decode(rle)
        }
        return nil
    }

    /// A reasonable starting system when the pilot's start isn't known: the most
    /// populated system (most stellar objects), so there's something to see.
    public func startingSystem() -> SystRes? {
        systems().filter { !$0.spobs.isEmpty }.max { $0.spobs.count < $1.spobs.count }
    }

    /// The stellar objects of a system, decoded, with sprites where available.
    public func stellarObjects(in systemID: Int) -> [(spob: SpobRes, sprite: SpriteSheet?)] {
        guard let system = system(systemID) else { return [] }
        return system.spobs.compactMap { id in
            guard let s = spob(id) else { return nil }
            return (s, spobSprite(id))
        }
    }
}
