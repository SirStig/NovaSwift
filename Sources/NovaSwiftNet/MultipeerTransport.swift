#if canImport(MultipeerConnectivity)
import Foundation
import MultipeerConnectivity

/// LAN / same-network `Transport` backed by MultipeerConnectivity (Bonjour over
/// Wi-Fi, peer-to-peer, no infrastructure). Fastest path to testing a live
/// session between two devices — no Game Center, no App Store Connect setup.
///
/// Peers auto-discover and auto-connect into a mesh (friends-only local play).
/// `displayName` carries the player id, so `PeerID == playerID` holds (the
/// project-wide convention in `Transport`).
///
/// App requirements (not package config): iOS 14+ needs
/// `NSLocalNetworkUsageDescription` and an `NSBonjourServices` entry for
/// `_<serviceType>._tcp` / `_udp` in Info.plist.
///
/// Threading: MultipeerConnectivity delivers on a private queue; this transport
/// marshals every `TransportDelegate` callback onto `callbackQueue` (main by
/// default) so `NetSession` sees single-threaded access.
public final class MultipeerTransport: NSObject, Transport {
    public let localPeerID: PeerID
    public weak var delegate: TransportDelegate?

    private let myPeer: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let callbackQueue: DispatchQueue

    /// - Parameters:
    ///   - playerID: stable id; also used as the Multipeer display name (≤63 chars).
    ///   - serviceType: Bonjour service type (1–15 chars, lowercase letters /
    ///     digits / hyphens). Two peers must share it to find each other.
    public init(playerID: PeerID,
                serviceType: String = "novaswift-mp",
                callbackQueue: DispatchQueue = .main) {
        self.localPeerID = playerID
        self.myPeer = MCPeerID(displayName: playerID)
        self.session = MCSession(peer: myPeer, securityIdentity: nil,
                                 encryptionPreference: .required)
        self.advertiser = MCNearbyServiceAdvertiser(peer: myPeer, discoveryInfo: nil,
                                                    serviceType: serviceType)
        self.browser = MCNearbyServiceBrowser(peer: myPeer, serviceType: serviceType)
        self.callbackQueue = callbackQueue
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    /// Begin advertising + browsing. Call after `delegate` is set.
    public func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    public var connectedPeers: [PeerID] {
        session.connectedPeers.map(\.displayName)
    }

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
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    private func sendMode(_ channel: NetChannel) -> MCSessionSendDataMode {
        channel == .reliable ? .reliable : .unreliable
    }
}

extension MultipeerTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        callbackQueue.async { [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                self.delegate?.transport(self, peerDidConnect: name)
            case .notConnected:
                self.delegate?.transport(self, peerDidDisconnect: name)
            case .connecting:
                break
            @unknown default:
                break
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

    // Unused streaming / resource transfer APIs.
    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?,
                           invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Friends-only local play: auto-accept.
        invitationHandler(true, session)
    }
}

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        // Both peers discover each other; to avoid a double-invite race only the
        // lexicographically-smaller id sends the invite — the other auto-accepts.
        guard myPeer.displayName < peerID.displayName else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
#endif
