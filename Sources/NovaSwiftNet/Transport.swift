import Foundation

/// A joinable lobby someone is hosting on the network (or, later, online), as
/// surfaced to the lobby-list UI. `id` is the host's player id, which a joiner
/// uses to connect to exactly that host — so two unrelated groups on the same
/// network never get merged.
public struct LobbyDescriptor: Identifiable, Equatable, Sendable {
    public var id: String            // host player id
    public var name: String          // lobby display name
    public var hostName: String      // host's pilot name
    /// How many players are in the lobby right now (host + connected joiners), as
    /// advertised by the host. At least 1 (the host). Live-ish: the host
    /// re-advertises it as peers connect/leave, so a browser sees it change.
    public var playerCount: Int
    /// How many plug-ins the host has enabled — shown in the lobby list.
    public var pluginCount: Int
    /// A short fingerprint of the host's enabled-plug-in set (`PluginManifest.
    /// signature`). A browser compares it to its own to hint "compatible?" before
    /// connecting; the authoritative check happens over the full manifest on join.
    public var pluginSignature: String
    public init(id: String, name: String, hostName: String, playerCount: Int = 1,
                pluginCount: Int = 0, pluginSignature: String = "") {
        self.id = id; self.name = name; self.hostName = hostName
        self.playerCount = playerCount
        self.pluginCount = pluginCount
        self.pluginSignature = pluginSignature
    }
}

/// Stable identifier for a peer within a session.
///
/// Convention across `NovaSwiftNet`: **the peer id *is* the player id.** For
/// GameKit this is the `gamePlayerID`, for Multipeer a stable display-name id,
/// for `LoopbackTransport` a caller-supplied string. Backends that expose a
/// different transport-level handle map it to the player id during their own
/// connection handshake before handing bytes to `NetSession`.
public typealias PeerID = String

/// Delivery guarantee for a message. Reliable for handshake / presence / events /
/// trade; unreliable for high-rate input and world snapshots.
public enum NetChannel: Sendable {
    case reliable
    case unreliable
}

/// Receives transport-level events. Callbacks are delivered on the transport's
/// own delivery context — synchronous and in-order for `LoopbackTransport`;
/// real backends deliver on their session/delegate queue.
public protocol TransportDelegate: AnyObject {
    func transport(_ transport: Transport, didReceive data: Data, from peer: PeerID)
    func transport(_ transport: Transport, peerDidConnect peer: PeerID)
    func transport(_ transport: Transport, peerDidDisconnect peer: PeerID)
}

/// Backend-agnostic message pipe between peers. Concrete backends planned:
/// `LoopbackTransport` (in-process tests), `MultipeerTransport` (LAN),
/// `GameKitTransport` (internet via Game Center). Nothing above this protocol
/// knows which backend is in use.
public protocol Transport: AnyObject {
    var localPeerID: PeerID { get }
    var connectedPeers: [PeerID] { get }
    var delegate: TransportDelegate? { get set }

    /// Send to a single peer.
    func send(_ data: Data, to peer: PeerID, channel: NetChannel)
    /// Send to every connected peer.
    func broadcast(_ data: Data, channel: NetChannel)
    /// Leave the session.
    func disconnect()
}

public extension Transport {
    /// Default fan-out; backends with a native "send to all" may override.
    func broadcast(_ data: Data, channel: NetChannel) {
        for peer in connectedPeers { send(data, to: peer, channel: channel) }
    }
}
