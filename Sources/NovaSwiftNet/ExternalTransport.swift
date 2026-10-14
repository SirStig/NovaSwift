import Foundation

/// A `Transport` whose bytes are pumped by the **host frontend** instead of by an
/// OS networking stack. The Godot desktop build owns the sockets (ENet: LAN,
/// direct IP:port, player-hosted dedicated servers) and shuttles opaque byte
/// packets in and out of this object once per frame:
///
/// - inbound:  `receive(from:data:)`, `peerConnected(id:name:)`, `peerDisconnected(id:)`
/// - outbound: `drainOutgoing()` (everything `NetSession` sent since the last drain)
///
/// Peer ids: the frontend speaks **integers** (ENet / Godot multiplayer peer ids);
/// `NetSession` speaks `PeerID = String` where "the peer id *is* the player id".
/// The mapping is `String(intID)` both ways, so a player id on the wire is the
/// decimal peer id. `localPeerID` is therefore `String(localID)`.
///
/// Semantics match the other backends:
/// - `send(_:to:channel:)` targets one peer; `broadcast` targets every
///   *currently connected* peer. A broadcast is queued as ONE entry with
///   `to == -1` (the frontend fans it out - e.g. `multiplayer_peer.set_target_peer(0)`);
///   it is only queued if at least one peer is connected, like `connectedPeers`
///   being empty makes the default fan-out a no-op.
/// - `.reliable` / `.unreliable` map to the `reliable` flag (ENet reliable vs
///   unreliable-sequenced channel). Order is preserved within the queue.
/// - The delegate is called synchronously from `receive` / `peerConnected` /
///   `peerDisconnected`, on whatever thread the frontend pumps from (Godot's main
///   thread). Nothing here is thread-safe on its own beyond a lock around the
///   queues; pump from one thread.
public final class ExternalTransport: Transport {
    /// One queued outbound packet.
    public struct Outgoing: Equatable {
        /// Destination peer id; `-1` = every connected peer.
        public var to: Int
        public var reliable: Bool
        public var data: [UInt8]
        public init(to: Int, reliable: Bool, data: [UInt8]) {
            self.to = to; self.reliable = reliable; self.data = data
        }
    }

    public static let broadcastTarget = -1

    public let localID: Int
    public let localPeerID: PeerID
    public weak var delegate: TransportDelegate?

    private let lock = NSLock()
    private var peers: [Int: String] = [:]      // connected peer id -> display name hint
    private var queue: [Outgoing] = []
    private var disconnected = false
    /// Safety cap: if the frontend stops draining, drop the OLDEST unreliable
    /// packets first (stale snapshots / inputs are worthless) instead of growing
    /// without bound. Reliable packets are never dropped.
    public var maxQueuedPackets = 4096

    public init(localPeerID: Int) {
        self.localID = localPeerID
        self.localPeerID = String(localPeerID)
    }

    // MARK: Transport

    public var connectedPeers: [PeerID] {
        lock.lock(); defer { lock.unlock() }
        return peers.keys.sorted().map(String.init)
    }

    /// The display-name hint the frontend supplied for a connected peer.
    public func peerName(_ id: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return peers[id]
    }

    public func send(_ data: Data, to peer: PeerID, channel: NetChannel) {
        guard let id = Int(peer) else { return }
        enqueue(Outgoing(to: id, reliable: channel == .reliable, data: [UInt8](data)))
    }

    public func broadcast(_ data: Data, channel: NetChannel) {
        lock.lock()
        let any = !peers.isEmpty && !disconnected
        lock.unlock()
        guard any else { return }
        enqueue(Outgoing(to: Self.broadcastTarget, reliable: channel == .reliable, data: [UInt8](data)))
    }

    public func disconnect() {
        lock.lock()
        disconnected = true
        peers.removeAll()
        lock.unlock()
    }

    private func enqueue(_ packet: Outgoing) {
        lock.lock(); defer { lock.unlock() }
        guard !disconnected else { return }
        queue.append(packet)
        if queue.count > maxQueuedPackets {
            let overflow = queue.count - maxQueuedPackets
            var dropped = 0
            queue.removeAll { p in
                if dropped < overflow, !p.reliable { dropped += 1; return true }
                return false
            }
        }
    }

    // MARK: Frontend pump

    /// Everything `NetSession` wants sent, oldest first; clears the queue. Safe to
    /// call after `disconnect()` to flush a final packet (e.g. a kick).
    public func drainOutgoing() -> [(to: Int, reliable: Bool, data: [UInt8])] {
        lock.lock()
        let out = queue
        queue.removeAll(keepingCapacity: true)
        lock.unlock()
        return out.map { ($0.to, $0.reliable, $0.data) }
    }

    /// Bytes arrived from `peer` (a connected peer id).
    public func receive(from peer: Int, data: [UInt8]) {
        delegate?.transport(self, didReceive: Data(data), from: String(peer))
    }

    /// The frontend's networking layer reports a peer is now reachable. Idempotent.
    public func peerConnected(id: Int, name: String) {
        guard id != localID else { return }
        lock.lock()
        let isNew = peers.updateValue(name, forKey: id) == nil
        let live = !disconnected
        lock.unlock()
        if isNew && live { delegate?.transport(self, peerDidConnect: String(id)) }
    }

    /// The peer went away. Idempotent.
    public func peerDisconnected(id: Int) {
        lock.lock()
        let had = peers.removeValue(forKey: id) != nil
        lock.unlock()
        if had { delegate?.transport(self, peerDidDisconnect: String(id)) }
    }
}
