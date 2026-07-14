#if canImport(MultipeerConnectivity)
import Foundation
import MultipeerConnectivity

/// LAN / same-network `Transport` backed by MultipeerConnectivity (Bonjour, no
/// infrastructure). Unlike an open mesh, it's **lobby-scoped**: a host advertises
/// one named lobby and a joiner connects to a *specific* host by id, so separate
/// groups on the same network stay separate.
///
/// `displayName` carries the player id, so `PeerID == playerID` holds. Discovery
/// info advertises the lobby name + host pilot name for `MultipeerLobbyBrowser`.
///
/// App requirements: iOS 14+ needs `NSLocalNetworkUsageDescription` +
/// `NSBonjourServices` for `_<serviceType>._tcp`/`_udp`.
public final class MultipeerTransport: NSObject, Transport {
    /// Whether this transport hosts a lobby or joins one.
    public enum Mode: Equatable {
        /// Advertise a named lobby and accept joiners.
        case host(lobbyName: String, hostName: String)
        /// Join the lobby hosted by the player with this id.
        case join(hostID: String)
    }

    public let localPeerID: PeerID
    public weak var delegate: TransportDelegate?

    private let mode: Mode
    private let myPeer: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser?
    private let browser: MCNearbyServiceBrowser?
    private let callbackQueue: DispatchQueue

    public init(playerID: PeerID, mode: Mode,
                serviceType: String = "novaswift-mp",
                callbackQueue: DispatchQueue = .main) {
        self.localPeerID = playerID
        self.mode = mode
        self.myPeer = MCPeerID(displayName: playerID)
        self.session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
        switch mode {
        case let .host(lobbyName, hostName):
            self.advertiser = MCNearbyServiceAdvertiser(
                peer: myPeer,
                discoveryInfo: [DiscoveryKey.lobby: lobbyName, DiscoveryKey.host: hostName],
                serviceType: serviceType)
            self.browser = nil
        case .join:
            self.advertiser = nil
            self.browser = MCNearbyServiceBrowser(peer: myPeer, serviceType: serviceType)
        }
        self.callbackQueue = callbackQueue
        super.init()
        session.delegate = self
        advertiser?.delegate = self
        browser?.delegate = self
    }

    /// Begin hosting (advertise) or joining (browse for the target host). Call
    /// after `delegate` is set.
    public func start() {
        advertiser?.startAdvertisingPeer()
        browser?.startBrowsingForPeers()
    }

    public var connectedPeers: [PeerID] { session.connectedPeers.map(\.displayName) }

    public func send(_ data: Data, to peer: PeerID, channel: NetChannel) {
        guard let mc = session.connectedPeers.first(where: { $0.displayName == peer }) else { return }
        try? session.send(data, toPeers: [mc], with: sendMode(channel))
    }

    public func broadcast(_ data: Data, channel: NetChannel) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        try? session.send(data, toPeers: peers, with: sendMode(channel))
    }

    public func disconnect() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
    }

    private func sendMode(_ channel: NetChannel) -> MCSessionSendDataMode {
        channel == .reliable ? .reliable : .unreliable
    }
}

/// Keys for the Multipeer discovery-info dictionary.
enum DiscoveryKey {
    static let lobby = "lobby"
    static let host = "host"
}

extension MultipeerTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        callbackQueue.async { [weak self] in
            guard let self else { return }
            switch state {
            case .connected:    self.delegate?.transport(self, peerDidConnect: name)
            case .notConnected: self.delegate?.transport(self, peerDidDisconnect: name)
            case .connecting:   break
            @unknown default:   break
            }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let name = peerID.displayName
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.transport(self, didReceive: data, from: name)
        }
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?,
                           invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Host: accept anyone who invites (moderation — kick/ban — is at the
        // `NetSession` layer once connected).
        invitationHandler(true, session)
    }
}

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        // Join: invite only the specific host we're joining — never a general mesh.
        guard case let .join(hostID) = mode, peerID.displayName == hostID else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}

/// Browses the local network for advertised NovaSwift lobbies and keeps a live
/// list — the "lobby list" the join UI shows. It only lists; joining a chosen
/// lobby spins up a `MultipeerTransport(.join)` for that host id.
public final class MultipeerLobbyBrowser: NSObject {
    private let browser: MCNearbyServiceBrowser
    private let callbackQueue: DispatchQueue
    /// Fired (on `callbackQueue`) whenever the discovered-lobby set changes.
    public var onLobbiesChanged: (([LobbyDescriptor]) -> Void)?

    private var found: [String: LobbyDescriptor] = [:]   // hostID → lobby

    public init(playerID: PeerID, serviceType: String = "novaswift-mp",
                callbackQueue: DispatchQueue = .main) {
        self.browser = MCNearbyServiceBrowser(peer: MCPeerID(displayName: playerID),
                                              serviceType: serviceType)
        self.callbackQueue = callbackQueue
        super.init()
        browser.delegate = self
    }

    public func start() { browser.startBrowsingForPeers() }
    public func stop() { browser.stopBrowsingForPeers() }

    public var lobbies: [LobbyDescriptor] {
        found.values.sorted { $0.name < $1.name }
    }

    private func publish() {
        let list = lobbies
        callbackQueue.async { [weak self] in self?.onLobbiesChanged?(list) }
    }
}

extension MultipeerLobbyBrowser: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        let name = info?[DiscoveryKey.lobby] ?? "Lobby"
        let host = info?[DiscoveryKey.host] ?? peerID.displayName
        found[peerID.displayName] = LobbyDescriptor(id: peerID.displayName, name: name, hostName: host)
        publish()
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        if found.removeValue(forKey: peerID.displayName) != nil { publish() }
    }
}
#endif
