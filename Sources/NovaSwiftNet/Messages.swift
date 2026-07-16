import Foundation

// MARK: - Layer 1: presence (always on)

/// A player's galaxy-level presence — the always-on Layer 1 broadcast. Cheap;
/// sent on each system change plus a slow heartbeat. Drives galaxy-map markers
/// and co-location detection. See `docs/MULTIPLAYER.md` → "Layer 1 — Presence".
public struct PlayerPresence: Codable, Equatable, Sendable {
    public var playerID: String
    public var name: String
    public var currentSystemID: Int
    public var shipTypeHint: Int?

    public init(playerID: String, name: String, currentSystemID: Int, shipTypeHint: Int? = nil) {
        self.playerID = playerID
        self.name = name
        self.currentSystemID = currentSystemID
        self.shipTypeHint = shipTypeHint
    }
}

// MARK: - Layer 2: per-system simulation sync (wire types; fully wired in P1/P2)

/// Engine-agnostic mirror of the sim's `ControlIntent`. The app maps this to/from
/// `NovaSwiftEngine.ControlIntent` at the boundary so the net layer keeps zero
/// engine dependency.
public struct NetIntent: Codable, Equatable, Sendable {
    public var turnLeft: Bool = false
    public var turnRight: Bool = false
    public var thrust: Bool = false
    public var reverse: Bool = false
    public var afterburner: Bool = false
    public var firePrimary: Bool = false
    public var fireSecondary: Bool = false
    public var desiredHeading: Double?
    public var turnScale: Double = 1

    public init() {}
}

/// Client → authority, ~30 Hz. Wire type defined now for a stable envelope;
/// consumed starting in P2.
public struct InputFrame: Codable, Equatable, Sendable {
    public var tick: UInt32
    public var seq: UInt32
    public var intent: NetIntent

    public init(tick: UInt32, seq: UInt32, intent: NetIntent) {
        self.tick = tick
        self.seq = seq
        self.intent = intent
    }
}

/// Who drives a ship in a snapshot. Nameplate + minimap colour key off this.
public enum NetControlSource: String, Codable, Sendable {
    case local   // the receiving client's own ship
    case remote  // another player
    case ai      // NPC
}

/// One ship in a `WorldSnapshot`. Minimal now; grows (ionization, cloak, target,
/// flags) in P2/P3.
public struct ShipNetState: Codable, Equatable, Sendable {
    /// The authority's entity id for this ship. Stable within one authority's
    /// world; a receiver keys its local mirror of this ship off `(authorityPeer,
    /// id)`. NOT the same across different authorities.
    public var id: Int
    /// The owning player's id for a player ship, or nil for an NPC. This is what
    /// lets a receiver pick out **its own** ship in a broadcast snapshot (match to
    /// its `localPlayerID`) regardless of the authority's local entity ids — so the
    /// `control` tag can be recipient-agnostic. See `WorldSnapshot` docs.
    public var playerID: String?
    /// The ship's hull type (`shïp` id), so a receiver builds a correctly-sprited
    /// mirror straight from the snapshot — needed for NPC mirrors (which have no
    /// presence entry to carry a hull hint) and handy for player ships too. -1 when
    /// unknown.
    public var shipTypeID: Int
    /// The ship's government/faction id, so a mirrored NPC keeps its real
    /// allegiance on the receiver (hostiles read hostile on the IFF radar, not as a
    /// co-op ally). `independentGovt`-equivalent default when unknown.
    public var government: Int
    public var name: String
    public var x: Double
    public var y: Double
    public var vx: Double
    public var vy: Double
    public var angle: Double
    public var shield: Double
    public var armor: Double
    public var control: NetControlSource

    public init(id: Int, playerID: String? = nil, shipTypeID: Int = -1, government: Int = 0,
                name: String, x: Double, y: Double, vx: Double, vy: Double, angle: Double,
                shield: Double, armor: Double, control: NetControlSource) {
        self.id = id; self.playerID = playerID; self.shipTypeID = shipTypeID
        self.government = government; self.name = name
        self.x = x; self.y = y; self.vx = vx; self.vy = vy
        self.angle = angle; self.shield = shield; self.armor = armor
        self.control = control
    }
}

/// One in-flight shot in a `WorldSnapshot` — just enough to draw it on a client
/// as a visual-only echo (no damage; that rides ship-health sync). The client
/// re-seeds these each snapshot and dead-reckons them on `velocity` between.
public struct ProjectileNetState: Codable, Equatable, Sendable {
    public var ownerID: Int          // authority entity that fired it (client skips its own)
    public var x: Double
    public var y: Double
    public var vx: Double
    public var vy: Double
    public var facing: Double
    public var life: Double
    public var weaponID: Int
    public var graphicSpinID: Int?
    public var spinShots: Bool
    public var translucentShots: Bool

    public init(ownerID: Int, x: Double, y: Double, vx: Double, vy: Double, facing: Double,
                life: Double, weaponID: Int, graphicSpinID: Int?, spinShots: Bool,
                translucentShots: Bool) {
        self.ownerID = ownerID
        self.x = x; self.y = y; self.vx = vx; self.vy = vy
        self.facing = facing; self.life = life; self.weaponID = weaponID
        self.graphicSpinID = graphicSpinID; self.spinShots = spinShots
        self.translucentShots = translucentShots
    }
}

/// One live beam segment in a `WorldSnapshot`, to echo on a client (visual only).
/// `color` is `[r,g,b]` (0…1) or nil to use the weapon's default styling.
public struct BeamNetState: Codable, Equatable, Sendable {
    public var shooterID: Int        // authority entity that fired it (client skips its own)
    public var weaponID: Int
    public var fromX: Double
    public var fromY: Double
    public var toX: Double
    public var toY: Double
    public var hit: Bool
    public var width: Double
    public var color: [Double]?
    /// The glow color/falloff this beam fades to away from its core `color` —
    /// without these a guest's echoed beam always renders as a flat generic
    /// bar instead of the weapon's real core→corona art. Defaulted so old
    /// snapshots (or a peer on a stale build) still decode.
    public var coronaColor: [Double]?
    public var coronaFalloff: Double

    public init(shooterID: Int, weaponID: Int, fromX: Double, fromY: Double, toX: Double,
                toY: Double, hit: Bool, width: Double, color: [Double]?,
                coronaColor: [Double]? = nil, coronaFalloff: Double = 0) {
        self.shooterID = shooterID; self.weaponID = weaponID
        self.fromX = fromX; self.fromY = fromY; self.toX = toX; self.toY = toY
        self.hit = hit; self.width = width; self.color = color
        self.coronaColor = coronaColor; self.coronaFalloff = coronaFalloff
    }

    private enum CodingKeys: String, CodingKey {
        case shooterID, weaponID, fromX, fromY, toX, toY, hit, width, color, coronaColor, coronaFalloff
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shooterID = try c.decode(Int.self, forKey: .shooterID)
        weaponID = try c.decode(Int.self, forKey: .weaponID)
        fromX = try c.decode(Double.self, forKey: .fromX)
        fromY = try c.decode(Double.self, forKey: .fromY)
        toX = try c.decode(Double.self, forKey: .toX)
        toY = try c.decode(Double.self, forKey: .toY)
        hit = try c.decode(Bool.self, forKey: .hit)
        width = try c.decode(Double.self, forKey: .width)
        color = try c.decodeIfPresent([Double].self, forKey: .color)
        coronaColor = try c.decodeIfPresent([Double].self, forKey: .coronaColor)
        coronaFalloff = try c.decodeIfPresent(Double.self, forKey: .coronaFalloff) ?? 0
    }
}

/// A one-shot visual effect that happened on the authority this frame (currently
/// explosions), to replay on clients. Unlike ship/shot/beam state (which is
/// re-seeded each snapshot), effects are transient one-offs — the client plays
/// each exactly once.
public struct EffectNetState: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var radius: Double
    public var boomID: Int?

    public init(x: Double, y: Double, radius: Double, boomID: Int?) {
        self.x = x; self.y = y; self.radius = radius; self.boomID = boomID
    }
}

/// Authority → client, ~20 Hz. Wire type defined now; consumed starting in P1/P2.
/// Delta compression against `ackInputSeq` is a later optimization.
public struct WorldSnapshot: Codable, Equatable, Sendable {
    public var tick: UInt32
    public var ackInputSeq: UInt32
    public var ships: [ShipNetState]
    /// Live shots to echo on clients (visual only). Defaulted empty so older call
    /// sites / ship-only snapshots stay valid.
    public var shots: [ProjectileNetState]
    /// Live beam segments to echo on clients (visual only). Defaulted empty.
    public var beams: [BeamNetState]
    /// One-shot effects (explosions) that fired this frame, replayed once. Defaulted.
    public var effects: [EffectNetState]

    public init(tick: UInt32, ackInputSeq: UInt32, ships: [ShipNetState],
                shots: [ProjectileNetState] = [], beams: [BeamNetState] = [],
                effects: [EffectNetState] = []) {
        self.tick = tick
        self.ackInputSeq = ackInputSeq
        self.ships = ships
        self.shots = shots
        self.beams = beams
        self.effects = effects
    }
}

/// Free-text chat between players in the session. Session-wide (delivered to all
/// connected peers over the reliable channel), independent of co-location — you
/// can message a friend before you've even met up. `senderName` is embedded so
/// old messages still render the author after they disconnect (their presence
/// entry is gone by then).
public struct ChatMessage: Codable, Equatable, Sendable {
    public var playerID: String
    public var senderName: String
    public var text: String

    public init(playerID: String, senderName: String, text: String) {
        self.playerID = playerID
        self.senderName = senderName
        self.text = text
    }
}

/// Co-op story sync: control bits the authority's storyline just **set** during
/// shared play, to union into each co-located participant's own NCB vector. Only
/// additions travel (the merge is strictly non-destructive — never clears a bit,
/// never passively copies a whole set), so players progress missions *together*
/// without ever overwriting what they've each done apart. See
/// `docs/MULTIPLAYER.md` → "Story / NCB split".
public struct NCBUpdate: Codable, Equatable, Sendable {
    public var setBits: [Int]
    public init(setBits: [Int]) { self.setBits = setBits }
}

// MARK: - Trade / item hand-off

/// One side's proposed contribution to a trade: credits plus item bundles keyed
/// by their game ids (`cargo` = commodity id → tons, `outfits` = oütf id → count).
/// Two players each build a `TradeOffer`; on mutual accept, each removes its own
/// offer from its save and adds the partner's. Gated by `SessionRules.allowTrade`.
public struct TradeOffer: Codable, Equatable, Sendable {
    public var credits: Int
    public var cargo: [Int: Int]
    public var outfits: [Int: Int]
    public init(credits: Int = 0, cargo: [Int: Int] = [:], outfits: [Int: Int] = [:]) {
        self.credits = credits; self.cargo = cargo; self.outfits = outfits
    }
    /// Nothing on the table.
    public var isEmpty: Bool { credits == 0 && cargo.isEmpty && outfits.isEmpty }
}

/// The trade handshake between two co-located players, all on the reliable channel.
public enum TradeSignal: Codable, Equatable, Sendable {
    /// A → B: "want to trade?" (carries A's pilot name for the prompt).
    case invite(fromName: String)
    /// B → A: declined the invite.
    case decline
    /// Either side's current offer — sent live as they add/remove items. Receiving
    /// a new offer clears the receiver's own acceptance (the deal changed).
    case offer(TradeOffer)
    /// Either side toggling their acceptance. Both accepted ⇒ commit.
    case accept(Bool)
    /// Either side cancelled — the trade closes on both.
    case cancel
}

// MARK: - Envelope

/// The tagged wire envelope. Swift synthesizes `Codable` as a single-key object
/// per case (e.g. `{"presence": {...}}`), which is fine for the JSON spine; a
/// binary/delta codec is a later optimization behind `NetCodec`.
public enum NetMessage: Codable, Equatable, Sendable {
    /// Layer 1 presence broadcast.
    case presence(PlayerPresence)
    /// A newly-connected peer asks others to re-announce their presence so it
    /// converges without waiting for the next heartbeat.
    case presenceRequest
    /// Host → peers: the agreed session rules.
    case sessionRules(SessionRules)
    /// Layer 2: client → authority input.
    case input(InputFrame)
    /// Layer 2: authority → client world snapshot.
    case snapshot(WorldSnapshot)
    /// Session chat.
    case chat(ChatMessage)
    /// Co-op story: control bits earned together, to union into the receiver's save.
    case ncb(NCBUpdate)
    /// Host → a player: you've been removed from the lobby (the id is the target,
    /// so it can confirm the kick is meant for it). A ban is a kick the host also
    /// remembers, refusing the id's presence thereafter.
    case kick(String)
    /// Peer-to-peer trade handshake (invite / offer / accept / cancel).
    case trade(TradeSignal)
    /// Sent on connect: the sender's enabled-plug-in set, so host and joiner can
    /// verify they're running the same content before playing together.
    case pluginManifest(PluginManifest)
}

/// Serialization boundary for `NetMessage`. JSON for the P0 spine — readable and
/// trivially testable. Swap the body for a compact binary encoder later without
/// touching call sites.
public enum NetCodec {
    public static func encode(_ message: NetMessage) throws -> Data {
        try JSONEncoder().encode(message)
    }
    public static func decode(_ data: Data) throws -> NetMessage {
        try JSONDecoder().decode(NetMessage.self, from: data)
    }
}
