#if canImport(GameKit)
import Foundation
import GameKit

/// Internet `Transport` backed by Game Center (`GKMatch`) — Apple runs the
/// matchmaking + relay, so there's no server to host and it works over the
/// internet (the only "host nothing, plays online" path; see `docs/MULTIPLAYER.md`).
///
/// This wraps an **already-created** `GKMatch`: authentication
/// (`GKLocalPlayer.authenticate`) and matchmaking (a `GKMatchmakerViewController`
/// or `GKMatchmaker.findMatch`, plus invite handling) are the app's job — it hands
/// the resulting match here. Then bytes flow exactly like every other transport.
///
/// Peer id == `gamePlayerID` (stable per player per game), honouring the
/// project-wide `PeerID == playerID` convention.
///
/// App requirements (not package config): the **Game Center** capability/
/// entitlement and an App Store Connect app record. Without them `GKMatch`
/// can't be created, so this transport is inert until that setup exists.
///
/// Threading: `GKMatchDelegate` callbacks arrive on the main queue; this marshals
/// every `TransportDelegate` call onto `callbackQueue` (main by default) so
/// `NetSession` sees single-threaded access, same as `MultipeerTransport`.
public final class GameKitTransport: NSObject, Transport {
    public let localPeerID: PeerID
    public weak var delegate: TransportDelegate?

    private let match: GKMatch
    private let callbackQueue: DispatchQueue
    /// gamePlayerID → GKPlayer, for addressing a single peer in `send`.
    private var playersByID: [PeerID: GKPlayer] = [:]

    /// Wrap a connected/associated `GKMatch`. The local player must already be
    /// authenticated (its `gamePlayerID` is used as `localPeerID`).
    public init(match: GKMatch, callbackQueue: DispatchQueue = .main) {
        self.match = match
        self.callbackQueue = callbackQueue
        self.localPeerID = GKLocalPlayer.local.gamePlayerID
        super.init()
        for player in match.players { playersByID[player.gamePlayerID] = player }
        match.delegate = self
    }

    public var connectedPeers: [PeerID] { match.players.map(\.gamePlayerID) }

    /// The live match, for GameKit calls that must act on it directly — notably
    /// `GKMatchmaker.addPlayers(to:matchRequest:)` when a host invites another
    /// player into a session that's already running.
    public var gkMatch: GKMatch { match }

    public func send(_ data: Data, to peer: PeerID, channel: NetChannel) {
        guard let player = playersByID[peer] ?? match.players.first(where: { $0.gamePlayerID == peer })
        else { return }
        do {
            try match.send(data, to: [player], dataMode: sendMode(channel))
        } catch {
            NSLog("GameKitTransport.send to \(peer) failed: \(error)")
        }
    }

    public func broadcast(_ data: Data, channel: NetChannel) {
        guard !match.players.isEmpty else { return }
        do {
            try match.sendData(toAllPlayers: data, with: sendMode(channel))
        } catch {
            NSLog("GameKitTransport.broadcast failed: \(error)")
        }
    }

    public func disconnect() {
        match.delegate = nil
        match.disconnect()
    }

    /// `GKMatch`'s `.unreliable` mode is unreliable in practice over the
    /// Game Center relay: unlike `MultipeerTransport` (real UDP on the LAN
    /// link), it can silently stop delivering packets after the initial
    /// burst, which manifested as "sync once, then never again" over
    /// internet play. Route everything through `.reliable` here; the
    /// bandwidth/latency cost is worth the correctness.
    private func sendMode(_ channel: NetChannel) -> GKMatch.SendDataMode {
        _ = channel
        return .reliable
    }
}

extension GameKitTransport: GKMatchDelegate {
    public func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        let peer = player.gamePlayerID
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.transport(self, didReceive: data, from: peer)
        }
    }

    public func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        let peer = player.gamePlayerID
        callbackQueue.async { [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                self.playersByID[peer] = player
                self.delegate?.transport(self, peerDidConnect: peer)
            case .disconnected:
                self.playersByID[peer] = nil
                self.delegate?.transport(self, peerDidDisconnect: peer)
            default:
                break
            }
        }
    }

    public func match(_ match: GKMatch, didFailWithError error: Error?) {
        // A whole-match failure disconnects everyone; surface each remaining peer
        // as a drop so `NetSession` cleans up presence/mirrors.
        let peers = match.players.map(\.gamePlayerID)
        callbackQueue.async { [weak self] in
            guard let self else { return }
            for peer in peers { self.delegate?.transport(self, peerDidDisconnect: peer) }
        }
    }
}
#endif
