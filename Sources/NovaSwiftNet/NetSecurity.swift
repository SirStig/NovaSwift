import Foundation

// Security primitives shared by the dedicated server, the ENet host, and every client (Apple and, by mirror, Godot).
// See docs/SECURITY.md for the threat model.

// MARK: - Token bucket

/// A refilling allowance: `burst` tokens at most, `perSecond` added continuously. Not thread-safe; callers lock.
public struct TokenBucket: Sendable {
    public var tokens: Double
    public var last: Double
    public let burst: Double
    public let perSecond: Double

    public init(burst: Double, perSecond: Double, now: Double) {
        self.burst = burst; self.perSecond = perSecond; tokens = burst; last = now
    }

    /// Spend `cost` if available.
    public mutating func take(_ cost: Double = 1, now: Double) -> Bool {
        tokens = min(burst, tokens + max(0, now - last) * perSecond)
        last = now
        if tokens >= cost { tokens -= cost; return true }
        return false
    }
}

// MARK: - NSQ1 anti-amplification

/// Decides whether (and how big) an `NSQ1` status query may be answered. A UDP reply to a spoofed source is the
/// classic reflection attack, so the rules are: the request must be padded (a reply can never be larger than the
/// request, so there is no amplification), every source IP has a token bucket, the table of sources is bounded, and
/// the old 4-byte request (an unpadded request = a 60x amplifier) gets only a ~30-byte "upgrade" notice, at most once per 5 s
/// per IP and 20 per second overall. Thread-safe.
public final class QueryGuard: @unchecked Sendable {
    public enum Kind: Equatable, Sendable { case invalid, legacy, padded }
    public enum Decision: Equatable, Sendable {
        case drop
        /// Answer with at most `maxBytes` (the full beacon, trimmed to the compact form with `"truncated":true` if needed).
        case reply(maxBytes: Int)
        /// A bare legacy 4-byte query: answer only `QueryGuard.upgradeNotice`.
        case upgradeNotice
    }

    /// Version bytes accepted on a padded request: 2 (this build) and 1 (the status prober that checks the public list).
    public static let queryVersion: UInt8 = 2
    static let acceptedVersions: Set<UInt8> = [1, 2]
    /// What a bare "NSQ1" gets: a tiny notice (no amplification) telling old clients to update.
    public static let upgradeNotice = Data((CrossPlayProtocol.beaconMagic + #"{"proto":\#(CrossPlayProtocol.version),"upgrade":true}"#).utf8)
    /// Size of the request this build sends (fits one Ethernet MTU with IP+UDP headers).
    public static let requestSize = 1200
    public static let minPaddedRequest = 512
    public static let maxReply = 1200
    public static let maxSources = 4096

    private let lock = NSLock()
    private var buckets: [String: TokenBucket] = [:]
    private var legacyLast: [String: Double] = [:]
    private var legacyGlobal: TokenBucket
    private let burst: Double, refill: Double
    private let clock: () -> Double
    public private(set) var dropped = 0
    public private(set) var answered = 0

    public init(burst: Double = 5, refillPerSecond: Double = 2,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.burst = burst; self.refill = refillPerSecond; self.clock = clock
        legacyGlobal = TokenBucket(burst: 20, perSecond: 20, now: clock())
    }

    /// What kind of request is this?
    public static func classify(_ packet: Data) -> Kind {
        guard packet.count >= 4, packet.count <= 2048 else { return .invalid }
        let magic = Data(CrossPlayProtocol.queryMagic.utf8)
        guard packet.prefix(4) == magic else { return .invalid }
        if packet.count == 4 { return .legacy }
        guard packet.count >= minPaddedRequest, acceptedVersions.contains(packet[packet.startIndex + 4]) else { return .invalid }
        return .padded
    }

    public func decide(_ packet: Data, from ip: String) -> Decision {
        let kind = Self.classify(packet)
        guard kind != .invalid else { return .drop }
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        if buckets.count > Self.maxSources || legacyLast.count > Self.maxSources { prune(now) }
        switch kind {
        case .legacy:
            if let t = legacyLast[ip], now - t < 5 { dropped += 1; return .drop }
            guard legacyGlobal.take(now: now) else { dropped += 1; return .drop }
            legacyLast[ip] = now
            answered += 1
            return .upgradeNotice
        case .padded:
            var b = buckets[ip] ?? TokenBucket(burst: burst, perSecond: refill, now: now)
            let ok = b.take(now: now)
            // A bounded table: when it is full a new source is simply not served (an existing one keeps working).
            if buckets[ip] != nil || buckets.count < Self.maxSources { buckets[ip] = b }
            guard ok else { dropped += 1; return .drop }
            answered += 1
            return .reply(maxBytes: min(packet.count, Self.maxReply))
        case .invalid: return .drop
        }
    }

    private func prune(_ now: Double) {
        buckets = buckets.filter { now - $0.value.last < 30 }
        legacyLast = legacyLast.filter { now - $0.value < 30 }
        if buckets.count > Self.maxSources { buckets.removeAll() }
        if legacyLast.count > Self.maxSources { legacyLast.removeAll() }
    }
}

// MARK: - Packet limits

/// Size caps on the ENet wire (first byte = kind) so a hostile peer can't make the host allocate or parse huge things.
public enum NetLimits {
    public static let maxHello = 32 * 1024
    public static let maxData = 64 * 1024
    public static let maxSmallControl = 1024     // chat, ping, report
    public static let maxPacket = 128 * 1024     // ENet host maximumPacketSize
    public static let maxManifestEntries = PluginRequirements.maxEntries
    public static let maxFieldLength = 128
    /// Per connection: sustained packets/s, burst, sustained bytes/s, burst.
    public static let packetsPerSecond = 300.0, packetBurst = 600.0
    public static let bytesPerSecond = 512.0 * 1024, byteBurst = 1024.0 * 1024
    /// Rate-limit violations (dropped packets) in a window before the peer is kicked.
    public static let violationsToKick = 50
    public static let tempBanSeconds = 600.0
    public static let abuseKicksToTempBan = 3
    public static let defaultMaxConnectionsPerIP = 4
    public static let chatBurst = 4.0, chatPerSecond = 2.0
}

// MARK: - Receiver-side validation

/// Plausibility checks applied by a receiver to what other peers claim. A malicious authority or client can still lie
/// inside the limits (see docs/SECURITY.md) but cannot send values that would wreck the receiver's world.
public enum NetValidation {
    public static let maxCoordinate = 1_000_000.0
    public static let maxSpeed = 4_000.0
    public static let maxShips = 256, maxShots = 1024, maxBeams = 256, maxEffects = 256
    public static let maxStat = 1_000_000.0
    public static let maxSystemID = 100_000
    public static let maxNCBBit = 10_000
    public static let maxNCBBitsPerMessage = 64

    static func finite(_ v: Double, limit: Double) -> Bool { v.isFinite && abs(v) <= limit }

    public static func valid(_ s: ShipNetState) -> Bool {
        finite(s.x, limit: maxCoordinate) && finite(s.y, limit: maxCoordinate)
            && finite(s.vx, limit: maxSpeed) && finite(s.vy, limit: maxSpeed)
            && finite(s.angle, limit: 1_000) && finite(s.shield, limit: maxStat) && finite(s.armor, limit: maxStat)
            && s.shipTypeID >= -1 && s.shipTypeID <= 100_000 && s.government >= -1 && s.government <= 100_000
    }

    /// A copy of the snapshot with impossible entries removed and lists capped. `knownShipTypes` (when non-nil) drops
    /// ships whose hull isn't in the game data (-1 = unknown stays).
    public static func sanitized(_ snap: WorldSnapshot, knownShipTypes: Set<Int>? = nil) -> WorldSnapshot {
        var s = snap
        s.ships = Array(snap.ships.prefix(maxShips)).filter { ship in
            guard valid(ship) else { return false }
            if let known = knownShipTypes, ship.shipTypeID >= 0, !known.contains(ship.shipTypeID) { return false }
            return true
        }.map { ship in
            var c = ship
            c.name = CrossPlayProtocol.cleanName(ship.name, fallback: "Ship")
            return c
        }
        s.shots = Array(snap.shots.prefix(maxShots)).filter {
            finite($0.x, limit: maxCoordinate) && finite($0.y, limit: maxCoordinate) && finite($0.vx, limit: maxSpeed * 4)
                && finite($0.vy, limit: maxSpeed * 4) && finite($0.facing, limit: 1_000) && finite($0.life, limit: 3_600)
        }
        s.beams = Array(snap.beams.prefix(maxBeams)).filter {
            finite($0.fromX, limit: maxCoordinate) && finite($0.fromY, limit: maxCoordinate)
                && finite($0.toX, limit: maxCoordinate) && finite($0.toY, limit: maxCoordinate) && finite($0.width, limit: 1_000)
        }
        s.effects = Array(snap.effects.prefix(maxEffects)).filter {
            finite($0.x, limit: maxCoordinate) && finite($0.y, limit: maxCoordinate) && finite($0.radius, limit: 10_000)
        }
        return s
    }

    /// Teleport / speed check between two states of the same ship `dt` seconds apart.
    /// `maxSpeed * 3` leaves room for afterburners, hyperspace-assisted pushes and snapshot jitter.
    public static func plausibleMove(from a: ShipNetState, to b: ShipNetState, dt: Double) -> Bool {
        guard dt > 0, dt.isFinite else { return true }
        let d = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        return d <= max(200, maxSpeed * 3 * dt)
    }

    public static func valid(_ p: PlayerPresence) -> Bool {
        (0...maxSystemID).contains(p.currentSystemID) && p.playerID.count <= 40 && (p.shipTypeHint.map { (-1...100_000).contains($0) } ?? true)
    }

    public static func sanitized(_ p: PlayerPresence) -> PlayerPresence {
        var c = p
        c.name = CrossPlayProtocol.cleanPlayerName(p.name, fallback: "Pilot")
        return c
    }

    /// The control bits a peer may "earn" for us: in range, deduplicated, capped.
    public static func sanitizedNCB(_ bits: [Int]) -> [Int] {
        var seen = Set<Int>()
        return bits.prefix(maxNCBBitsPerMessage).filter { (0...maxNCBBit).contains($0) && seen.insert($0).inserted }
    }

    public static func valid(_ r: SessionRules) -> Bool {
        r.gameSpeedMultiplier.isFinite && (0.25...4.0).contains(r.gameSpeedMultiplier)
    }

    /// Reject oversized manifests (entries and string lengths).
    public static func valid(_ m: PluginManifest) -> Bool {
        m.plugins.count <= maxManifestEntriesForSession
            && m.plugins.allSatisfy { $0.id.count <= 128 && $0.name.count <= 128 && $0.contentHash.count <= 128 }
    }
    public static let maxManifestEntriesForSession = 256

    public static func valid(_ o: TradeOffer) -> Bool {
        o.cargo.count <= 64 && o.outfits.count <= 256
            && o.credits >= 0 && o.credits <= 2_000_000_000
            && o.cargo.values.allSatisfy { $0 <= 1_000_000 } && o.outfits.values.allSatisfy { $0 <= 100_000 }
    }

    public static func valid(_ i: InputFrame) -> Bool {
        (i.intent.desiredHeading.map { $0.isFinite && abs($0) <= 1_000 } ?? true) && i.intent.turnScale.isFinite && abs(i.intent.turnScale) <= 10
    }
}

/// Counts invalid messages per peer and reports when a peer crosses the line (`threshold` strikes within `window`).
public struct MisbehaviorTracker {
    public var threshold: Int
    public var window: Double
    private var strikes: [String: [Double]] = [:]
    public init(threshold: Int = 20, window: Double = 30) { self.threshold = threshold; self.window = window }

    /// Record a strike; returns the count within the window.
    public mutating func strike(_ peer: String, now: Double) -> Int {
        var list = (strikes[peer] ?? []).filter { now - $0 <= window }
        list.append(now)
        strikes[peer] = list
        if strikes.count > 512 { strikes = strikes.filter { ($0.value.last ?? 0) > now - window } }
        return list.count
    }
    public mutating func forget(_ peer: String) { strikes[peer] = nil }
}
