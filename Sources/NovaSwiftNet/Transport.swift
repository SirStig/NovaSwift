import Foundation

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
