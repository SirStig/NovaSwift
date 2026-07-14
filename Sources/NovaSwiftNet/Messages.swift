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
    public var name: String
    public var x: Double
    public var y: Double
    public var vx: Double
    public var vy: Double
    public var angle: Double
    public var shield: Double
    public var armor: Double
    public var control: NetControlSource

    public init(id: Int, playerID: String? = nil, name: String, x: Double, y: Double,
                vx: Double, vy: Double, angle: Double, shield: Double, armor: Double,
                control: NetControlSource) {
        self.id = id; self.playerID = playerID; self.name = name
        self.x = x; self.y = y; self.vx = vx; self.vy = vy
        self.angle = angle; self.shield = shield; self.armor = armor
        self.control = control
    }
}

/// Authority → client, ~20 Hz. Wire type defined now; consumed starting in P1/P2.
/// Delta compression against `ackInputSeq` is a later optimization.
public struct WorldSnapshot: Codable, Equatable, Sendable {
    public var tick: UInt32
    public var ackInputSeq: UInt32
    public var ships: [ShipNetState]

    public init(tick: UInt32, ackInputSeq: UInt32, ships: [ShipNetState]) {
        self.tick = tick
        self.ackInputSeq = ackInputSeq
        self.ships = ships
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
