import Foundation

/// In-process switchboard that wires several `LoopbackTransport` peers together
/// so a full multi-peer session can be exercised in a unit test — no devices, no
/// Game Center entitlement, deterministic synchronous delivery.
///
/// Usage: create one `LoopbackNetwork`, create a `LoopbackTransport` per peer,
/// set each transport's `delegate`, then call `connect()` on each. Connection is
/// announced pairwise to every already-joined member.
public final class LoopbackNetwork {
    private var members: [PeerID: LoopbackTransport] = [:]

    public init() {}

    func connect(_ transport: LoopbackTransport) {
        let newcomer = transport.localPeerID
        guard members[newcomer] == nil else { return }
        // Register first, so data the existing peers push during their
        // peerDidConnect handler (e.g. presence) can route to the newcomer.
        members[newcomer] = transport
        // Announce the newcomer <-> each existing member, both directions.
        for (existingID, existing) in members where existingID != newcomer {
            existing.deliverConnect(newcomer)
            transport.deliverConnect(existingID)
        }
    }

    func disconnect(_ id: PeerID) {
        guard members.removeValue(forKey: id) != nil else { return }
        for (_, other) in members { other.deliverDisconnect(id) }
    }

    func route(_ data: Data, from: PeerID, to: PeerID) {
        members[to]?.deliverData(data, from: from)
    }

    func peers(excluding id: PeerID) -> [PeerID] {
        members.keys.filter { $0 != id }
    }
}

/// A `Transport` that routes through an in-process `LoopbackNetwork`. For tests
/// and local development only.
public final class LoopbackTransport: Transport {
    public let localPeerID: PeerID
    public weak var delegate: TransportDelegate?
    private let network: LoopbackNetwork

    public init(peerID: PeerID = UUID().uuidString, network: LoopbackNetwork) {
        self.localPeerID = peerID
        self.network = network
    }

    /// Join the switchboard. Call *after* `delegate` is set so connection
    /// callbacks land.
    public func connect() { network.connect(self) }

    public var connectedPeers: [PeerID] { network.peers(excluding: localPeerID) }

    public func send(_ data: Data, to peer: PeerID, channel: NetChannel) {
        network.route(data, from: localPeerID, to: peer)
    }

    public func broadcast(_ data: Data, channel: NetChannel) {
        for peer in connectedPeers { network.route(data, from: localPeerID, to: peer) }
    }

    public func disconnect() { network.disconnect(localPeerID) }

    // Delivery hooks invoked by the switchboard.
    func deliverData(_ data: Data, from peer: PeerID) {
        delegate?.transport(self, didReceive: data, from: peer)
    }
    func deliverConnect(_ peer: PeerID) {
        delegate?.transport(self, peerDidConnect: peer)
    }
    func deliverDisconnect(_ peer: PeerID) {
        delegate?.transport(self, peerDidDisconnect: peer)
    }
}
