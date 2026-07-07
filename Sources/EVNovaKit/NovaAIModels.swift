import Foundation

// Typed decoders for the resources that drive EV Nova's NPC AI: governments
// (`gövt`), dudes (`düde`, an AI ship archetype), fleets (`flët`), and weapons
// (`wëap`). Field offsets are the on-disk big-endian byte layout, taken from the
// EV Nova / ResForge `TMPL` templates and **verified against the real game data**
// (e.g. `gövt` 128 "Federation": Comms Name at @52; `düde` 128 ship-probabilities
// sum to exactly 100). See docs/DATA_FORMAT.md and docs/AI.md.

// MARK: Byte helpers (big-endian, bounds-safe)

@inline(__always) private func ai16(_ d: Data, _ off: Int) -> Int {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    let v = (Int(d[base]) << 8) | Int(d[base + 1])
    return v >= 0x8000 ? v - 0x10000 : v
}

@inline(__always) private func au16(_ d: Data, _ off: Int) -> UInt16 {
    guard off >= 0, off + 2 <= d.count else { return 0 }
    let base = d.startIndex + off
    return UInt16(d[base]) << 8 | UInt16(d[base + 1])
}

// MARK: gövt — government (diplomatic relations & behavior)

/// A government: its diplomatic stance (class membership, ally/enemy classes),
/// crime penalties, and behavior flags. Two governments are hostile when one's
/// `enemies` classes intersect the other's `classes`, or a xenophobe/attack flag
/// applies. See `Diplomacy` in EVNovaEngine.
public struct GovtRes {
    public let id: Int
    public let name: String

    public let voiceType: Int
    public let flags1: UInt16
    public let flags2: UInt16
    public let scanFine: Int
    public let crimeTolerance: Int
    public let smugglePenalty: Int
    public let disablePenalty: Int
    public let boardPenalty: Int
    public let killPenalty: Int
    public let shootPenalty: Int
    public let initialRecord: Int
    public let maxOdds: Int
    /// The classes this government belongs to (−1 slots stripped).
    public let classes: [Int]
    /// Classes this government is allied with.
    public let allies: [Int]
    /// Classes this government is hostile to.
    public let enemies: [Int]
    public let shipSpeedFactor: Int

    // Flags 1 (behavior)
    public var xenophobic: Bool       { flags1 & 0x0001 != 0 } // attacks everyone except allies
    public var nosy: Bool             { flags1 & 0x0002 != 0 } // attacks player where he's a criminal
    public var alwaysAttacksPlayer: Bool { flags1 & 0x0004 != 0 }
    public var immuneToPlayer: Bool   { flags1 & 0x0008 != 0 }
    public var warshipsRetreat: Bool  { flags1 & 0x0010 != 0 } // retreat below 25% shields
    public var neverAttacksPlayer: Bool { flags1 & 0x0040 != 0 }
    public var warshipsTakeBribes: Bool { flags1 & 0x0200 != 0 }
    public var plundersBeforeKilling: Bool { flags1 & 0x1000 != 0 }

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Govt \(r.id)" : r.name
        let d = r.data
        voiceType = ai16(d, 0)
        flags1 = au16(d, 2)
        flags2 = au16(d, 4)
        scanFine = ai16(d, 6)
        crimeTolerance = ai16(d, 8)
        smugglePenalty = ai16(d, 10)
        disablePenalty = ai16(d, 12)
        boardPenalty = ai16(d, 14)
        killPenalty = ai16(d, 16)
        shootPenalty = ai16(d, 18)
        initialRecord = ai16(d, 20)
        maxOdds = ai16(d, 22)
        classes = (0..<4).map { ai16(d, 24 + $0 * 2) }.filter { $0 != -1 }
        allies  = (0..<4).map { ai16(d, 32 + $0 * 2) }.filter { $0 != -1 }
        enemies = (0..<4).map { ai16(d, 40 + $0 * 2) }.filter { $0 != -1 }
        shipSpeedFactor = ai16(d, 48)
    }
}

// MARK: düde — an AI ship archetype (what actually gets spawned)

/// EV Nova's AI dispositions, from `düde`'s AI Type field. Higher-fidelity
/// behavior branches off these in the engine's `AIBrain`.
public enum AIType: Int, Sendable {
    case wimpyTrader = 1   // flees at the first sign of trouble
    case braveTrader = 2   // fights back if attacked, then flees when hurt
    case warship = 3       // seeks out and attacks hostiles
    case interceptor = 4   // aggressive warship; pursues relentlessly
    case unknown = 0

    public init(raw: Int) { self = AIType(rawValue: raw) ?? .unknown }
    public var isTrader: Bool { self == .wimpyTrader || self == .braveTrader }
    public var isWarship: Bool { self == .warship || self == .interceptor }
}

/// A "dude": an NPC archetype tying an AI disposition + government to a weighted
/// table of ship classes it can appear as. Spawning picks a ship by probability.
public struct DudeRes {
    public let id: Int
    public let name: String
    public let aiTypeRaw: Int
    public let govt: Int
    public let flags: UInt16
    /// (ship class id, spawn probability 0…100). Probabilities across the table
    /// sum to ~100 in real data.
    public let ships: [(shipID: Int, prob: Int)]

    public var aiType: AIType { AIType(raw: aiTypeRaw) }
    /// This dude may not damage or be damaged by the player (escort/ally scenery).
    public var cantHitPlayer: Bool { flags & 0x0100 != 0 }

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Dude \(r.id)" : r.name
        let d = r.data
        aiTypeRaw = ai16(d, 0)
        govt = ai16(d, 2)
        flags = au16(d, 4)
        var table: [(Int, Int)] = []
        for i in 0..<16 {
            let shipID = ai16(d, 8 + i * 2)
            let prob = ai16(d, 40 + i * 2)
            if shipID >= 128 && prob > 0 { table.append((shipID, prob)) }
        }
        ships = table
    }

    /// Pick a ship class from the weighted table using a value in 0..<total.
    /// Deterministic given `roll`, so spawning can use a seeded RNG.
    public func pickShip(roll: Int) -> Int? {
        guard !ships.isEmpty else { return nil }
        let total = ships.reduce(0) { $0 + $1.prob }
        guard total > 0 else { return ships.first?.shipID }
        var acc = 0
        let target = ((roll % total) + total) % total
        for entry in ships {
            acc += entry.prob
            if target < acc { return entry.shipID }
        }
        return ships.last?.shipID
    }
}

// MARK: flët — a fleet (flagship + weighted escorts, and where it appears)

/// A fleet: a lead ship plus escort ship classes with min/max counts, an
/// affiliation government, and a rule for which systems it populates.
public struct FleetRes {
    public let id: Int
    public let name: String
    public let leadShip: Int
    public let escorts: [(shipID: Int, min: Int, max: Int)]
    public let govt: Int
    /// −1 = any system; 128…2175 a specific `sÿst`; 10000+g govt g's systems, etc.
    public let linkSystem: Int

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Fleet \(r.id)" : r.name
        let d = r.data
        leadShip = ai16(d, 0)
        var e: [(Int, Int, Int)] = []
        for i in 0..<4 {
            let shipID = ai16(d, 2 + i * 2)
            let mn = ai16(d, 10 + i * 2)
            let mx = ai16(d, 18 + i * 2)
            if shipID >= 128 { e.append((shipID, max(0, mn), max(mn, mx))) }
        }
        escorts = e
        govt = ai16(d, 26)
        linkSystem = ai16(d, 28)
    }
}

// MARK: wëap — weapon (makes the AI's "attack" real)

/// EV Nova weapon guidance kinds we distinguish for simulation.
public enum WeaponGuidance: Int, Sendable {
    case unguided = -1
    case beam = 0
    case guided = 1
    case beamTurret = 3
    case turret = 4
    case freefallBomb = 5
    case rocket = 6
    case frontQuadrant = 7
    case rearQuadrant = 8
    case pointDefense = 9
    case pointDefenseBeam = 10
    case bay = 99
    case other = 1000

    public init(raw: Int) { self = WeaponGuidance(rawValue: raw) ?? .other }
}

/// A weapon type: damage, projectile behaviour, range and fire rate. Offsets are
/// from novaparse's verified `WeapResource`.
public struct WeapRes {
    public let id: Int
    public let name: String
    public let reload: Int          // frames between shots (lower = faster)
    public let duration: Int        // projectile lifetime in frames
    public let armorDamage: Int
    public let shieldDamage: Int
    public let guidanceRaw: Int
    public let speed: Int           // projectile speed (px per frame at 30 fps)
    public let ammoType: Int        // −1 = no ammo; ≥0 draws from that ammo
    public let accuracy: Int        // spread in degrees (0 = perfect)
    public let impact: Int
    public let proxRadius: Int
    public let blastRadius: Int
    public let beamLength: Int
    public let turnRate: Int        // for guided munitions
    public let maxAmmo: Int
    public let count: Int           // rounds consumed / fired per shot

    public var guidance: WeaponGuidance { WeaponGuidance(raw: guidanceRaw) }
    public var isBeam: Bool { guidance == .beam || guidance == .beamTurret || guidance == .pointDefenseBeam }
    public var isGuided: Bool {
        switch guidance { case .guided, .rocket, .frontQuadrant, .rearQuadrant: return true; default: return false }
    }
    public var isTurret: Bool { guidance == .turret || guidance == .beamTurret }
    /// Effective reach in world pixels. Beams use their length; projectiles use
    /// speed × lifetime (the game runs the projectile sim at 30 fps).
    public var range: Double {
        if isBeam { return Double(max(beamLength, 50)) }
        return Double(speed) * Double(max(duration, 1))
    }

    public init(_ r: Resource) {
        id = r.id
        name = r.name.isEmpty ? "Weapon \(r.id)" : r.name
        let d = r.data
        reload = ai16(d, 0)
        duration = ai16(d, 2)
        armorDamage = ai16(d, 4)
        shieldDamage = ai16(d, 6)
        guidanceRaw = ai16(d, 8)
        speed = ai16(d, 10)
        ammoType = ai16(d, 12)
        accuracy = abs(ai16(d, 16))
        impact = ai16(d, 20)
        proxRadius = ai16(d, 24)
        blastRadius = ai16(d, 26)
        beamLength = ai16(d, 48)
        turnRate = ai16(d, 106)
        maxAmmo = ai16(d, 108)
        count = ai16(d, 118)
    }
}
