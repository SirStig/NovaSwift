import Foundation
import Combine
import NovaSwiftKit
import NovaSwiftNet
import NovaSwiftEngine
import NovaSwiftSync
import NovaSwiftENet
#if canImport(GameKit)
import GameKit
#endif
#if os(iOS)
import UIKit
#endif

/// App-level owner of a live multiplayer `NetSession` (from `NovaSwiftNet`),
/// bridged into SwiftUI as an `ObservableObject`. Hangs off `AppModel` so every
/// view reaches it via `model.session`.
///
/// P0 scope: local (same-Wi-Fi) sessions over `MultipeerTransport`, presence, and
/// session-wide chat. Game Center / join-code transports and Layer-2 simulation
/// sync land in later phases; the `NetSession` seam underneath already supports
/// them.
@MainActor
final class MultiplayerSession: ObservableObject {
    /// A session is running (advertising/browsing + connected or waiting).
    @Published private(set) var isActive = false
    /// Session-wide chat history, oldest-first (mirrors `NetSession.chatLog`).
    @Published private(set) var chatLog: [ChatMessage] = []
    /// Everyone's presence, keyed by player id (mirrors `NetSession.presence`).
    @Published private(set) var presence: [String: PlayerPresence] = [:]
    /// Unread chat count while the panel is closed (drives the badge).
    @Published private(set) var unreadCount = 0
    /// The agreed session rules.
    @Published private(set) var rules: SessionRules = .fullStakes
    /// The current lobby's display name (empty when not in a session).
    @Published private(set) var lobbyName = ""
    /// Whether this player hosts the current lobby (can set rules, kick/ban).
    @Published private(set) var isHost = false
    /// Local lobbies discovered while browsing (the "join" list). Empty unless
    /// `startBrowsingLocalLobbies` is active.
    @Published private(set) var localLobbies: [LobbyDescriptor] = []
    /// Set true briefly when the host kicked us, so the UI can explain the exit.
    @Published var wasKicked = false
    /// Non-nil when the last join attempt was refused because our enabled plug-ins
    /// don't match the host's — the UI shows what to install/disable, then clears it.
    @Published var pluginMismatch: PluginMismatch?
    /// The lobby name the `pluginMismatch` was for (for the explaining sheet).
    @Published private(set) var pluginMismatchLobbyName = ""
    /// Our own enabled-plug-in signature, published while browsing local lobbies so
    /// the list can flag compatibility before you try to join.
    @Published private(set) var localPluginSignature = ""

    // MARK: - Trade

    /// The live trade with another player, or nil. Drives the trade window overlay.
    @Published private(set) var trade: TradeState?
    /// A pending trade invite from another player awaiting our yes/no.
    @Published private(set) var incomingTradeInvite: TradeInvite?
    /// The app applies a committed trade to the pilot (remove `give`, add `receive`)
    /// and saves. Set by `AppModel`.
    var onTradeCommitted: ((_ give: TradeOffer, _ receive: TradeOffer) -> Void)?

    /// Live two-sided trade state.
    struct TradeState {
        let partnerID: String
        var partnerName: String
        var myOffer = TradeOffer()
        var theirOffer = TradeOffer()
        var myAccepted = false
        var theirAccepted = false
        /// Whether the partner has joined the window (acknowledged the invite).
        var partnerJoined: Bool
    }
    struct TradeInvite: Identifiable, Equatable {
        var id: String        // inviter player id
        var name: String
    }

    /// This player's id in the live session — always equal to the transport's peer
    /// id (`NetSession.localPlayerID`). Seeded with a per-launch id used for the
    /// Multipeer display name; replaced by the transport's own id when a session
    /// starts (e.g. Game Center's `gamePlayerID`). Distinct from the pilot's
    /// display name (two friends can share a name).
    private(set) var localPlayerID: String = "p-" + String(UUID().uuidString.prefix(8))

    /// Set by the chat UI so incoming messages don't count as unread while open.
    var chatVisible = false {
        didSet { if chatVisible { unreadCount = 0 } }
    }

    private var net: NetSession?
    private var transport: Transport?

    // MARK: - Cross-play (ENet) state

    /// Why the last ENet join/host attempt (or an established ENet session) ended badly. The hub shows it.
    struct ENetFailure: Equatable {
        /// REJECT code ("version", "proto", "password", "full", "plugins", "banned", "bad_request") or
        /// "timeout" / "disconnected" / "bind".
        var code: String
        var message: String
        /// For code "plugins": the server's manifest (REJECT detail), to build the "what do I need" diff.
        var serverManifestJSON: String?
    }
    @Published var enetFailure: ENetFailure?
    /// "Connecting to host:port…" while an ENet join is in flight.
    @Published private(set) var connectingTo: String?
    /// Host-side one-liners ("Bob couldn't join: plug-ins differ"), shown in the roster.
    @Published var hostNotice: String?
    /// Fired after a live session ends, however it ends (the app restores borrowed plug-ins here).
    var onSessionEnded: (() -> Void)?

    // MARK: - Auto-reconnect (ENet client sessions)

    /// Everything needed to rejoin the server we are in, kept in memory only while a cross-play session is live
    /// (the password is never written anywhere by this type; saved servers keep their own copy as before).
    /// The borrowed-plug-in state is deliberately NOT here: it lives in `AppModel.crossPlay.borrowedFrom`, and a
    /// reconnect never runs `stop()`, so it is never touched.
    struct RejoinTicket: Equatable {
        var address: CrossPlayAddress
        var password: String
        var displayName: String
        /// The lobby / server display name.
        var lobbyName: String
    }
    /// Where the auto-reconnect is. `.idle` = connected, never connected, or finished.
    enum ReconnectState: Equatable {
        case idle
        case reconnecting(attempt: Int, of: Int)
    }
    /// A connection that could not be restored after the retries ran out. Drives the "Reconnect" button.
    struct LostConnection: Equatable {
        var message: String
        var ticket: RejoinTicket
    }
    @Published private(set) var reconnectState: ReconnectState = .idle
    @Published private(set) var lostConnection: LostConnection?
    private var rejoinTicket: RejoinTicket?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectStartedAt = Date()
    private var reconnectAttemptsStarted = 0
    private var lastReconnectFailure: ENetFailure?
    /// Seconds to wait before each attempt: immediately, then 2 s, 5 s, 10 s, 15 s.
    private static let reconnectDelays: [TimeInterval] = [0, 2, 5, 10, 15]
    /// Stop starting new attempts after this long.
    private static let reconnectBudget: TimeInterval = 60
    /// ENet's idle timeout (`ENetTransport.Wire.idleTimeout`, internal there): a gap this long drops us server-side.
    private static let serverIdleTimeout: TimeInterval = 20
    /// Latest pilot facts, so a rejoin announces where the pilot is now, not where they were at the first join.
    private var localSystemID = -1
    private var localName = ""
    private var backgroundedAt: Date?
    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    private var enetClient: ENetTransport?
    /// Peers we already reported as sending invalid data this session (one report each).
    private var reportedInvalidPeers = Set<String>()
    /// Whether the local player is docked at a spaceport (mirrored into the sync driver).
    private var localLanded = false
    private var enetHost: ENetHostTransport?
    private var enetAnnouncer: LANBeaconService?
    private var pendingActivation: (name: String, systemID: Int, shipTypeID: Int?)?

    #if canImport(GameKit)
    /// The live Game Center match when this session is online, nil when it's local.
    /// Lets a host invite an approved player straight into the running session
    /// (`GameCenterManager.invite(playerID:into:)`).
    var gameCenterMatch: GKMatch? { (transport as? GameKitTransport)?.gkMatch }
    #endif

    // MARK: - Layer 2 (per-system sim sync)

    /// The shared (Apple + Godot) Layer-2 role/sync logic from `NovaSwiftSync`:
    /// authority selection, mirrors, handoff, snapshots/inputs. Lives as long as
    /// the session.
    private var driver: SystemSyncDriver?
    /// The local player's current hull type, announced so co-located peers can
    /// build a correctly-sprited mirror of this ship.
    private var localShipTypeID: Int = -1

    // MARK: - Co-op story (NCB) sync

    /// The app supplies the local pilot's current NCB vector; the authority diffs it
    /// each frame to find bits its storyline just set and shares them with
    /// co-located participants. Set by `AppModel`.
    var playerBitsProvider: (() -> Set<Int>)?
    /// The app supplies the local enabled-plug-in manifest so the session can
    /// advertise it and verify a joiner runs the same content. Set by `AppModel`.
    var pluginManifestProvider: (() -> PluginManifest)?
    /// The manifest captured at session start, diffed against a peer's on join.
    private var localManifest: PluginManifest = .empty
    /// The app unions bits earned in a partner's shared storyline into the local
    /// pilot (non-destructive). Set by `AppModel`.
    var onRemoteBitsEarned: ((Set<Int>) -> Void)?
    /// The authority's last-seen bit vector, to compute the "newly set" delta.
    /// Seeded from the pilot at session start so pre-existing bits never propagate
    /// (no passive inheritance).
    private var lastKnownBits: Set<Int> = []
    private var bitsInitialized = false

    #if canImport(MultipeerConnectivity)
    private var lobbyBrowser: MultipeerLobbyBrowser?
    #endif
    /// The host's id when we joined someone else's lobby (nil when we host).
    private var joinedHostID: String?

    // MARK: - Lobby lifecycle (local)

    /// **Host** a named local lobby others can discover + join. Tears down any
    /// existing session/browse. No-op without MultipeerConnectivity.
    func hostLocalLobby(lobbyName: String, displayName: String, systemID: Int,
                        shipTypeID: Int? = nil, rules: SessionRules = .fullStakes) {
        stop()
        pluginMismatch = nil
        #if canImport(MultipeerConnectivity)
        let name = lobbyName.isEmpty ? "\(displayName)'s Lobby" : lobbyName
        let manifest = pluginManifestProvider?() ?? .empty
        let mp = MultipeerTransport(playerID: localPlayerID,
                                    mode: .host(lobbyName: name, hostName: displayName),
                                    pluginCount: manifest.count, pluginSignature: manifest.signature)
        self.lobbyName = name
        isHost = true
        activate(transport: mp, displayName: displayName, systemID: systemID,
                 shipTypeID: shipTypeID, rules: rules)
        mp.start()
        #endif
    }

    /// **Join** a discovered local lobby. No-op without MultipeerConnectivity.
    func joinLocalLobby(_ lobby: LobbyDescriptor, displayName: String, systemID: Int,
                        shipTypeID: Int? = nil) {
        stop()
        pluginMismatch = nil
        #if canImport(MultipeerConnectivity)
        let mp = MultipeerTransport(playerID: localPlayerID, mode: .join(hostID: lobby.id))
        lobbyName = lobby.name
        isHost = false
        joinedHostID = lobby.id
        // Joiners adopt the host's rules on receipt (`onRulesChanged`); seed safe.
        activate(transport: mp, displayName: displayName, systemID: systemID,
                 shipTypeID: shipTypeID, rules: .safe, broadcastRules: false)
        mp.start()
        #endif
    }

    /// Start listing local lobbies to join. Updates `localLobbies`.
    func startBrowsingLocalLobbies() {
        #if canImport(MultipeerConnectivity)
        stopBrowsingLocalLobbies()
        // Publish our own plug-in signature so the list can flag which lobbies are
        // compatible before you connect.
        localPluginSignature = (pluginManifestProvider?() ?? .empty).signature
        let browser = MultipeerLobbyBrowser(playerID: localPlayerID)
        browser.onLobbiesChanged = { [weak self] lobbies in self?.localLobbies = lobbies }
        lobbyBrowser = browser
        browser.start()
        #endif
    }

    /// Stop listing local lobbies.
    func stopBrowsingLocalLobbies() {
        #if canImport(MultipeerConnectivity)
        lobbyBrowser?.stop()
        lobbyBrowser = nil
        localLobbies = []
        #endif
    }

    #if canImport(GameKit)
    /// Start an **internet** session over Game Center, wrapping an already-created
    /// `GKMatch`. Same session/sync machinery; only the transport differs.
    ///
    /// Layer-2 sim authority stays per-system and id-based (`currentAuthorityID`),
    /// independent of this. What "host" decides here is lobby ownership: who owns
    /// the rules, who moderates, and which side of the plug-in gate you take. A
    /// `GKMatch` doesn't distinguish a host, so `OnlineRole` establishes one — see
    /// its docs for why the rule must be one both peers compute identically.
    ///
    /// Exactly one peer must end up host: two hosts broadcast conflicting rules and
    /// mutually kick each other over plug-ins, while zero hosts means nobody
    /// broadcasts at all and everyone silently stays on seeded `.safe` rules.
    func startGameCenter(match: GKMatch, displayName: String, systemID: Int,
                         shipTypeID: Int? = nil, role: OnlineRole = .autoMatch,
                         lobbyName: String = "", rules: SessionRules = .fullStakes) {
        stop()
        pluginMismatch = nil
        let gk = GameKitTransport(match: match)
        let localID = gk.localPeerID
        let resolvedHostID: String
        switch role {
        case .hosting:
            resolvedHostID = localID
        case .guest(let hostID):
            resolvedHostID = hostID
        case .autoMatch:
            resolvedHostID = ([localID] + match.players.map(\.gamePlayerID)).min() ?? localID
        }
        let iAmHost = resolvedHostID == localID

        self.lobbyName = lobbyName.isEmpty ? "Online Lobby" : lobbyName
        isHost = iAmHost
        joinedHostID = iAmHost ? nil : resolvedHostID
        // Guests adopt the host's rules on receipt (`onRulesChanged`); seed safe so
        // a guest never briefly plays under full-stakes rules the host didn't set.
        activate(transport: gk, displayName: displayName, systemID: systemID,
                 shipTypeID: shipTypeID, rules: iAmHost ? rules : .safe,
                 broadcastRules: iAmHost)
    }
    #endif

    /// Shared session bring-up: wrap a transport in a `NetSession`, adopt the
    /// transport's peer id as our player id, wire callbacks + the sync coordinator,
    /// announce presence and (optionally, host-only) rules.
    private func activate(transport: Transport, displayName: String, systemID: Int,
                          shipTypeID: Int?, rules: SessionRules, broadcastRules: Bool = true) {
        if let shipTypeID { localShipTypeID = shipTypeID }
        localSystemID = systemID
        localName = displayName
        let session = NetSession(transport: transport, rules: rules)
        // The host owns the rules: it must (re)send them to every peer that connects
        // later, or a joiner keeps its seed `.safe` rules (no real PvP damage) even
        // when it becomes a system's sync authority. Guests never push rules.
        session.providesRules = broadcastRules
        // Plug-in compatibility: announce our set so host/joiner can verify a match.
        localManifest = pluginManifestProvider?() ?? .empty
        session.localPluginManifest = localManifest
        localPlayerID = session.localPlayerID     // the transport owns the peer id
        wire(session)
        self.transport = transport
        net = session
        configureTrade()
        let drv = SystemSyncDriver(session: session, localSystemID: systemID)
        drv.onNotAuthority = { [weak self] in self?.bitsInitialized = false }
        drv.onAuthorityPostStep = { [weak self] net, peers in self?.propagateEarnedBits(net: net, to: peers) }
        drv.isLocalPlayerLanded = localLanded
        driver = drv
        reportedInvalidPeers.removeAll()
        // A peer that keeps sending invalid data is reported to the relay server (which can remove it). `sendReport` is
        // thread-safe; it only queues. Only the ENet client has a server to tell.
        if let enet = transport as? ENetTransport {
            session.onMisbehavior = { peer, why, strikes in
                if strikes == 5, let id = Int(peer) { enet.sendReport(target: id, reason: "invalid", detail: why) }
            }
            drv.onInvalidMessage = { [weak self] peer, why in
                // Once per peer per session: a malformed-snapshot stream must not become a report flood
                // (the server counts distinct reporters, but our own repeats are pure noise).
                guard let self, let id = Int(peer), self.reportedInvalidPeers.insert(peer).inserted else { return }
                enet.sendReport(target: id, reason: "invalid", detail: why)
            }
        }
        self.rules = rules
        session.updateLocalPresence(name: displayName, systemID: systemID,
                                    shipTypeHint: localShipTypeID >= 0 ? localShipTypeID : nil)
        if broadcastRules { session.broadcastRules(rules) }
        isActive = true
        syncPresence()
    }

    /// Leave the session and clear all mirrored state.
    func stop() {
        let wasLive = isActive
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectState = .idle
        lostConnection = nil
        rejoinTicket = nil
        backgroundedAt = nil
        endBackgroundTask()
        enetClient?.onEvent = nil; enetHost?.onEvent = nil    // no callbacks (or re-entry) while we tear down
        enetClient?.stopPumping()
        enetHost?.stopPumping()
        enetAnnouncer?.stopAnnouncing()
        transport?.disconnect()
        enetClient?.disconnect()      // no-op when already closed
        enetClient = nil; enetHost = nil; enetAnnouncer = nil
        connectingTo = nil; pendingActivation = nil
        net = nil
        transport = nil
        driver?.reset()
        driver = nil
        reportedInvalidPeers.removeAll()
        lastKnownBits = []
        bitsInitialized = false
        isActive = false
        isHost = false
        joinedHostID = nil
        lobbyName = ""
        tradeCoord.reset()
        trade = nil
        incomingTradeInvite = nil
        chatLog = []
        presence = [:]
        unreadCount = 0
        if wasLive { onSessionEnded?() }
    }

    // MARK: - Cross-play: join / host over ENet

    /// **Join** a Godot player, a dedicated server or another Apple device by `host:port` over ENet. Asynchronous:
    /// watch `connectingTo` / `isActive` / `enetFailure`. Event callbacks run on the main queue.
    func joinENet(address: CrossPlayAddress, password: String, displayName: String, systemID: Int,
                  shipTypeID: Int?, label: String) {
        stop()
        pluginMismatch = nil
        enetFailure = nil
        wasKicked = false
        let manifest = pluginManifestProvider?() ?? .empty
        let t = ENetTransport(config: .init(host: address.host, port: address.port, displayName: displayName,
                                            password: password, gameVersion: CrossPlayProtocol.appVersion,
                                            manifestJSON: ENetTransport.manifestJSON(manifest)))
        enetClient = t
        lobbyName = label.isEmpty ? address.formatted : label
        isHost = false
        joinedHostID = String(ENetTransport.Wire.serverID)
        pendingActivation = (displayName, systemID, shipTypeID)
        rejoinTicket = RejoinTicket(address: address, password: password, displayName: displayName, lobbyName: lobbyName)
        t.onEvent = { [weak self, weak t] event in
            MainActor.assumeIsolated { if let self, let t { self.handleENet(event, from: t) } }
        }
        do {
            try t.connect()
        } catch {
            enetClient = nil
            rejoinTicket = nil
            enetFailure = ENetFailure(code: "bad_request", message: "Couldn't start connecting to \(address.formatted).", serverManifestJSON: nil)
            return
        }
        connectingTo = address.formatted
        t.startPumping(interval: 1.0 / 60.0, queue: .main)
    }

    private func handleENet(_ event: ENetTransport.Event, from t: ENetTransport) {
        guard t === enetClient else { return }
        // A reconnect attempt is in flight (reconnectState != .idle and we have not re-activated yet).
        let attempting = reconnectState != .idle && pendingActivation != nil
        switch event {
        case .connected(let serverName, _, _, _, _):
            guard let p = pendingActivation else { return }
            pendingActivation = nil
            connectingTo = nil
            if !serverName.isEmpty { lobbyName = serverName; rejoinTicket?.lobbyName = serverName }
            // Joiners adopt the host's rules over the wire (NetSession); seed safe.
            // On a reconnect this builds a fresh NetSession + sync driver (clean mirrors, new peer id) and
            // re-announces presence; the plug-in set was never changed, so nothing is reloaded.
            activate(transport: t, displayName: p.name, systemID: p.systemID, shipTypeID: p.shipTypeID,
                     rules: .safe, broadcastRules: false)
            if reconnectState != .idle {
                reconnectTask?.cancel(); reconnectTask = nil
                reconnectState = .idle
                lastReconnectFailure = nil
            }
        case .rejected(let code, let message):
            let manifest = t.rejectServerManifest
            let failure = ENetFailure(code: code, message: message, serverManifestJSON: manifest)
            // "full" can just be our dead slot still being held by the server; everything else is final.
            if attempting, code == "full" || code == "refused" { reconnectAttemptFailed(failure); return }
            if attempting { reconnectGiveUp(failure); return }
            endENetClient()
            enetFailure = failure
        case .kicked:
            stop()
            wasKicked = true
        case .timedOut(let message):
            if attempting {
                reconnectAttemptFailed(ENetFailure(code: "timeout", message: message, serverManifestJSON: nil))
            } else if isActive {
                beginReconnect(message: message, code: "timeout", from: t)       // the idle timeout: transport loss
            } else {
                endENetClient()
                enetFailure = ENetFailure(code: "timeout", message: message, serverManifestJSON: nil)
            }
        case .disconnected(let reason):
            guard t.state == .closed else { return }
            if attempting {
                reconnectAttemptFailed(ENetFailure(code: "disconnected", message: reason, serverManifestJSON: nil))
            } else if isActive {
                beginReconnect(message: reason, code: "disconnected", from: t)   // socket lost without a kick/refusal
            } else {
                endENetClient()
            }
        case .chat:
            break     // the in-session chat rides NetSession; this is the transport's fallback only
        }
    }

    // MARK: - Auto-reconnect

    /// The transport died under a live ENet client session (idle timeout / lost socket / app was suspended).
    /// Kicks, bans, refusals and Leave never get here. Keeps the flight scene, the pilot, the plug-in set and the
    /// sync driver; just drops everyone else, then retries with backoff.
    private func beginReconnect(message: String, code: String, from t: ENetTransport) {
        guard isActive, !isHost, reconnectState == .idle, rejoinTicket != nil, net != nil else {
            endENetClient()
            enetFailure = ENetFailure(code: code, message: message, serverManifestJSON: nil)
            return
        }
        // Retire the dead client (sends a polite ENet disconnect if it is somehow still open).
        let peers = t.inner.connectedPeers
        t.onEvent = nil
        t.stopPumping()
        t.disconnect()
        enetClient = nil
        pendingActivation = nil
        connectingTo = nil
        // Everyone else is gone from our point of view: the session's presence empties, so the driver's authority
        // becomes nil and it clears mirrors on the next pre-step (forceResync is belt and braces).
        for p in peers { net?.transport(t, peerDidDisconnect: p) }
        driver?.forceResync()
        // An in-flight trade cannot survive: the partner's id and our id both change.
        tradeCoord.reset()
        refreshTrade()
        tradeNotice = "Trade cancelled: connection lost."
        incomingTradeInvite = nil
        syncPresence()
        lastReconnectFailure = ENetFailure(code: code, message: message, serverManifestJSON: nil)
        reconnectStartedAt = Date()
        reconnectAttemptsStarted = 0
        reconnectState = .reconnecting(attempt: 0, of: Self.reconnectDelays.count)
        scheduleReconnectAttempt()
    }

    private func scheduleReconnectAttempt() {
        guard case .reconnecting = reconnectState else { return }
        let index = reconnectAttemptsStarted
        guard index < Self.reconnectDelays.count else {
            reconnectGiveUp(lastReconnectFailure ?? ENetFailure(code: "timeout", message: "The server stopped responding.", serverManifestJSON: nil))
            return
        }
        let delay = Self.reconnectDelays[index]
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            self.startReconnectAttempt()
        }
    }

    private func startReconnectAttempt() {
        guard case .reconnecting = reconnectState, let ticket = rejoinTicket else { return }
        if reconnectAttemptsStarted > 0, Date().timeIntervalSince(reconnectStartedAt) > Self.reconnectBudget {
            reconnectGiveUp(lastReconnectFailure ?? ENetFailure(code: "timeout", message: "The server stopped responding.", serverManifestJSON: nil))
            return
        }
        reconnectAttemptsStarted += 1
        reconnectState = .reconnecting(attempt: reconnectAttemptsStarted, of: Self.reconnectDelays.count)
        let manifest = pluginManifestProvider?() ?? .empty
        // A fresh transport picks a fresh random peer id: the server may still hold our old slot until it times out.
        let t = ENetTransport(config: .init(host: ticket.address.host, port: ticket.address.port, displayName: ticket.displayName,
                                            password: ticket.password, gameVersion: CrossPlayProtocol.appVersion,
                                            manifestJSON: ENetTransport.manifestJSON(manifest)))
        t.connectTimeout = 6
        enetClient = t
        pendingActivation = (localName.isEmpty ? ticket.displayName : localName, localSystemID,
                             localShipTypeID >= 0 ? localShipTypeID : nil)
        t.onEvent = { [weak self, weak t] event in
            MainActor.assumeIsolated { if let self, let t { self.handleENet(event, from: t) } }
        }
        do {
            try t.connect()
        } catch {
            discardAttemptClient()
            reconnectAttemptFailed(ENetFailure(code: "timeout", message: "Couldn't reach \(ticket.address.formatted).", serverManifestJSON: nil))
            return
        }
        t.startPumping(interval: 1.0 / 60.0, queue: .main)
    }

    private func discardAttemptClient() {
        enetClient?.onEvent = nil
        enetClient?.stopPumping()
        enetClient?.disconnect()
        enetClient = nil
        pendingActivation = nil
        connectingTo = nil
    }

    /// One attempt failed in a retryable way: wait for the next slot in the schedule.
    private func reconnectAttemptFailed(_ failure: ENetFailure) {
        lastReconnectFailure = failure
        discardAttemptClient()
        scheduleReconnectAttempt()
    }

    /// Out of retries (or a final refusal): the normal full teardown, which restores borrowed plug-ins, then the
    /// usual failure message plus a manual Reconnect offer (not for bans, wrong passwords, mismatches).
    private func reconnectGiveUp(_ failure: ENetFailure) {
        let ticket = rejoinTicket
        let retryableLater = !["banned", "password", "proto", "version", "plugins", "bad_request"].contains(failure.code)
        stop()
        enetFailure = ENetFailure(code: failure.code,
                                  message: retryableLater ? "Lost the connection to the server and couldn't get back in. \(failure.message)" : failure.message,
                                  serverManifestJSON: failure.serverManifestJSON)
        if retryableLater, let ticket { lostConnection = LostConnection(message: enetFailure?.message ?? failure.message, ticket: ticket) }
    }

    /// The Cancel button on the reconnecting banner: full teardown, usual message.
    func cancelReconnect() {
        guard reconnectState != .idle else { return }
        let ticket = rejoinTicket
        stop()
        enetFailure = ENetFailure(code: "disconnected", message: "Disconnected from the server.", serverManifestJSON: nil)
        if let ticket { lostConnection = LostConnection(message: "Disconnected from the server.", ticket: ticket) }
    }

    /// Hides the "connection lost" banner without reconnecting.
    func dismissLostConnection() { lostConnection = nil }

    // MARK: App lifecycle (iOS suspends the app; macOS just keeps going)

    /// Call when the app goes to the background. On iOS this asks for a short background task so a quick app
    /// switch keeps the main-queue ENet pump (and so the connection) alive for the ~25 s the system grants.
    func appDidEnterBackground() {
        guard isActive, enetClient != nil, reconnectState == .idle else { return }
        backgroundedAt = Date()
        #if os(iOS)
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NovaSwift.multiplayer") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        #endif
    }

    /// Call when the app is active again. If we were away long enough to be dropped (or the transport already
    /// closed) start reconnecting now instead of waiting for the next idle-timeout event.
    func appDidBecomeActive() {
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        #if os(iOS)
        // A live background task means the pump kept running the whole time: the connection is as good as ever.
        let keptAlive = backgroundTask != .invalid
        endBackgroundTask()
        #else
        let keptAlive = true      // desktop never suspends the pump
        #endif
        guard isActive, !isHost, reconnectState == .idle, let t = enetClient else { return }
        if t.state == .closed {
            beginReconnect(message: "The connection was lost while the app was in the background.", code: "timeout", from: t)
        } else if !keptAlive, away >= Self.serverIdleTimeout {
            beginReconnect(message: "The connection was lost while the app was in the background.", code: "timeout", from: t)
        }
    }

    private func endBackgroundTask() {
        #if os(iOS)
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        #endif
    }

    /// Tear down a client that failed or closed (keeps `enetFailure`).
    private func endENetClient() {
        let failure = enetFailure
        stop()
        enetFailure = failure
    }

    /// **Host** a game other devices join by `ip:port` over ENet: Godot players, dedicated-server style, other
    /// Apple devices. Throws when the port can't be bound. `announcer` broadcasts it on the LAN.
    func hostENet(lobbyName: String, displayName: String, systemID: Int, shipTypeID: Int?, rules: SessionRules,
                  port: Int, password: String, maxPlayers: Int, announcer: LANBeaconService?,
                  requirements: PluginRequirements) throws {
        stop()
        pluginMismatch = nil
        enetFailure = nil
        hostNotice = nil
        let name = lobbyName.isEmpty ? "\(displayName)'s Game" : lobbyName
        let manifest = pluginManifestProvider?() ?? .empty
        let cfg = ENetHostTransport.Config(
            port: port, maxPlayers: maxPlayers, serverName: name, hostName: displayName, password: password,
            gameVersion: CrossPlayProtocol.appVersion, manifestJSON: ENetTransport.manifestJSON(manifest),
            rulesJSON: CrossPlayProtocol.rulesJSON(rules), rulesName: CrossPlayProtocol.presetName(rules),
            requirements: requirements)
        let h = ENetHostTransport(config: cfg)
        try h.start()
        h.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handleENetHost(event) }
        }
        self.lobbyName = name
        isHost = true
        joinedHostID = nil
        enetHost = h
        activate(transport: h, displayName: displayName, systemID: systemID, shipTypeID: shipTypeID,
                 rules: rules, broadcastRules: true)
        h.startPumping(interval: 1.0 / 60.0, queue: .main)
        if let announcer {
            enetAnnouncer = announcer
            let fallback = ServerBeacon(name: name, players: 1, max: maxPlayers, port: port)
            _ = announcer.startAnnouncing(gamePort: port, provider: { [weak h] in h?.beacon() ?? fallback })
        }
    }

    private func handleENetHost(_ event: ENetHostTransport.Event) {
        switch event {
        case .refused(let code, _, _) where code == "plugins":
            hostNotice = "A player couldn't join: their gameplay plug-ins don't match yours."
        case .refused(let code, _, _) where code == "password":
            hostNotice = "A player was refused: wrong password."
        case .versionNote(_, let name, let theirs, _):
            hostNotice = "\(name) runs NovaSwift \(theirs) (you run \(CrossPlayProtocol.appVersion)). Same protocol, so they can play."
        case .peerJoined, .peerLeft:
            syncPresence()
        default: break
        }
    }

    // MARK: - Moderation (host) + roster

    /// Players in the session, sorted (host first, then by name) — the lobby roster.
    var players: [PlayerPresence] {
        presence.values.sorted {
            if $0.playerID == hostPlayerID { return true }
            if $1.playerID == hostPlayerID { return false }
            return $0.name < $1.name
        }
    }

    /// The host's player id: us when hosting, otherwise the lobby we joined.
    var hostPlayerID: String? { isHost ? localPlayerID : joinedHostID }

    /// Remove a player from the lobby (host only).
    func kick(_ playerID: String) {
        guard isHost else { return }
        net?.kick(playerID)
        if let id = Int(playerID) { enetHost?.kick(id) }
        syncPresence()
    }

    /// Ban a player from the lobby for the rest of the session (host only).
    func ban(_ playerID: String) {
        guard isHost else { return }
        net?.ban(playerID)
        if let id = Int(playerID) { enetHost?.kick(id, reason: "Banned by the host.", ban: true) }
        syncPresence()
    }

    /// Host-only: push updated session rules to everyone mid-lobby.
    func updateRules(_ newRules: SessionRules) {
        guard isHost else { return }
        rules = newRules
        net?.broadcastRules(newRules)
        enetHost?.updateRules(json: CrossPlayProtocol.rulesJSON(newRules), name: CrossPlayProtocol.presetName(newRules))
    }

    // MARK: - Trade API (used by the UI)

    // The state machine is `NovaSwiftNet.TradeCoordinator` (shared with the Godot bridge, so Apple <-> Godot trades
    // speak the same signals and apply the same rules); this class only mirrors it into `trade` / `incomingTradeInvite`.

    /// The pilot's holdings, for validating offers and swaps. Set by `AppModel`.
    var tradeHoldings: (() -> (credits: Int, cargo: [Int: Int], outfits: [Int: Int]))?
    /// A refusal / failure reason to show ("You don't have that much cargo.").
    @Published var tradeNotice: String?
    private let tradeCoord = TradeCoordinator()
    private var tradeMyName = "Captain"

    private func configureTrade() {
        tradeCoord.send = { [weak self] signal, peer in self?.net?.sendTrade(signal, to: peer) }
        tradeCoord.allowTrade = { [weak self] in self?.rules.allowTrade ?? false }
        tradeCoord.localName = { [weak self] in self?.tradeMyName ?? "Captain" }
        tradeCoord.partnerName = { [weak self] in self?.presence[$0]?.name }
        tradeCoord.isPresent = { [weak self] in self?.presence[$0] != nil }
        tradeCoord.offerCheck = { [weak self] offer in
            guard let h = self?.tradeHoldings?() else { return nil }
            return TradeRules.covers(offer, credits: h.credits, cargo: h.cargo, outfits: h.outfits) ? nil : "You don't have all of that to give."
        }
        tradeCoord.swapCheck = { [weak self] give, _ in
            guard let h = self?.tradeHoldings?() else { return nil }
            return TradeRules.covers(give, credits: h.credits, cargo: h.cargo, outfits: h.outfits) ? nil : "You no longer have everything you offered."
        }
        tradeCoord.commit = { [weak self] give, receive in self?.onTradeCommitted?(give, receive) }
        tradeCoord.onEvent = { [weak self] event in
            guard let self else { return }
            if case .failed(let why) = event { self.tradeNotice = why }
            self.refreshTrade()
        }
        tradeCoord.reset()
        refreshTrade()
    }

    private func refreshTrade() {
        if let l = tradeCoord.live {
            trade = TradeState(partnerID: l.partnerID, partnerName: l.partnerName, myOffer: l.myOffer,
                               theirOffer: l.theirOffer, myAccepted: l.myAccepted, theirAccepted: l.theirAccepted,
                               partnerJoined: l.partnerJoined)
        } else { trade = nil }
        incomingTradeInvite = tradeCoord.incoming.map { TradeInvite(id: $0.id, name: $0.name) }
    }

    /// Whether we can start a trade with `playerID` right now.
    func canTrade(with playerID: String) -> Bool {
        playerID != localPlayerID && tradeCoord.canTrade(with: playerID)
    }

    /// Invite another player to trade. Opens our (waiting) trade window.
    func inviteTrade(with playerID: String, myName: String) {
        guard canTrade(with: playerID) else { return }
        tradeMyName = myName
        tradeNotice = tradeCoord.invite(playerID)
    }

    func acceptTradeInvite() { tradeCoord.respond(accept: true) }
    func declineTradeInvite() { tradeCoord.respond(accept: false) }

    /// Replace our current offer (called live as the player edits it). Any change resets both acceptances.
    func updateMyOffer(_ offer: TradeOffer) { tradeNotice = tradeCoord.setOffer(offer) }

    /// Toggle our acceptance; when both sides accept, the trade commits.
    func setTradeAccepted(_ accepted: Bool) { tradeNotice = tradeCoord.setAccepted(accepted) }

    func cancelTrade() { tradeCoord.cancel() }

    private func handleTrade(_ signal: TradeSignal, from peer: String) { tradeCoord.handle(signal, from: peer) }

    /// Drop a live trade / invite if the other party has left the session.
    private func pruneTradeIfPartnerGone() {
        if let t = tradeCoord.live, presence[t.partnerID] == nil { tradeCoord.peerLeft(t.partnerID) }
        if let inv = tradeCoord.incoming, presence[inv.id] == nil { tradeCoord.peerLeft(inv.id) }
    }

    // MARK: - Presence / chat API (used by the app)

    /// Push the local player's location — call on spawn and every system jump.
    /// Safe to call when no session is active. `shipTypeID` (the player's current
    /// hull) rides along so co-located peers can sprite this ship's mirror.
    func updatePresence(systemID: Int, name: String, shipTypeID: Int? = nil) {
        if let shipTypeID { localShipTypeID = shipTypeID }
        localSystemID = systemID
        if !name.isEmpty { localName = name }
        driver?.setLocalSystem(systemID)   // new system ⇒ fresh world ⇒ drop mirrors
        net?.updateLocalPresence(name: name, systemID: systemID,
                                 shipTypeHint: localShipTypeID >= 0 ? localShipTypeID : nil)
        syncPresence()
    }

    func sendChat(_ text: String) {
        net?.sendChat(text)
        // `onChat` fires for locally-sent too, refreshing `chatLog`.
    }

    /// Other players currently in a given system — for galaxy-map markers.
    func players(inSystem systemID: Int) -> [PlayerPresence] {
        net?.players(inSystem: systemID, excluding: localPlayerID) ?? []
    }

    var localDisplayName: String { net?.localDisplayName ?? "" }

    // MARK: - Wiring

    /// Hide a player's chat for the rest of this session (local only; nobody is told).
    func blockPlayer(_ id: String) {
        net?.block(id)
        chatLog = chatLog.filter { $0.playerID != id }
    }

    /// Tell the relay server about a player (chat abuse). Needs a dedicated/ENet server; no-op for Game Center.
    func reportPlayer(_ id: String, reason: String = "abuse") {
        guard let enet = enetClient, let n = Int(id) else { return }
        enet.sendReport(target: n, reason: reason)
    }

    private func wire(_ session: NetSession) {
        session.onChat = { [weak self] message in
            guard let self else { return }
            self.chatLog = session.chatLog.filter { !session.blockedPeers.contains($0.playerID) }
            if !self.chatVisible && message.playerID != self.localPlayerID {
                self.unreadCount += 1
            }
        }
        session.onPresenceChanged = { [weak self] _ in self?.syncPresence() }
        session.onRulesChanged = { [weak self] rules in self?.rules = rules }
        // Layer 2: authority collects clients' inputs; client buffers the newest
        // snapshot for the next frame.
        session.onInput = { [weak self] frame, peer in self?.driver?.receiveInput(frame, from: peer) }
        session.onSnapshot = { [weak self] snapshot, peer in self?.driver?.receiveSnapshot(snapshot, from: peer) }
        // Co-op story: a partner's shared storyline earned bits — union them locally.
        session.onNCB = { [weak self] bits, _ in self?.onRemoteBitsEarned?(Set(bits)) }
        // The host kicked us: leave the session and let the UI explain.
        session.onKicked = { [weak self] in
            self?.stop()
            self?.wasKicked = true
        }
        // Trade handshakes from a partner.
        session.onTrade = { [weak self] signal, peer in self?.handleTrade(signal, from: peer) }
        // Plug-in compatibility: verify a peer's enabled-plug-in set on connect.
        session.onPluginManifest = { [weak self] manifest, peer in
            self?.handlePeerPluginManifest(manifest, from: peer)
        }
    }

    /// Enforce plug-in compatibility when a peer announces its set. As the **host**
    /// we drop a joiner whose plug-ins don't match (integrity — a mismatch would
    /// desync the shared world); as a **guest** we block ourselves against the host
    /// and surface exactly what to install/disable. Our own client always self-gates,
    /// so the host's kick is only a backstop for a modified client.
    private func handlePeerPluginManifest(_ manifest: PluginManifest, from peer: String) {
        if isHost {
            if !manifest.isCompatible(with: localManifest) {
                net?.kick(peer)
                if let id = Int(peer) { enetHost?.kick(id, reason: "Your plug-ins don't match the host's.") }   // drop the link too (else a ghost)
                syncPresence()
            }
        } else if peer == joinedHostID {
            let mismatch = localManifest.mismatch(against: manifest)
            if !mismatch.isCompatible {
                pluginMismatchLobbyName = lobbyName
                pluginMismatch = mismatch     // drives the explaining sheet
                stop()                        // leave — we can't play here as-is
            }
        }
    }

    private func syncPresence() {
        presence = net?.presence ?? [:]
        pruneTradeIfPartnerGone()
    }

    // MARK: - Layer 2 role logic + game-loop hooks

    /// Whether Layer-2 sync is engaged right now (≥2 players co-located).
    var isSyncingSystem: Bool { isActive && driver?.currentAuthorityID != nil }

    /// Called when the local player lands / launches. A landed player is not simulated, so the sync driver
    /// must not treat their stale world as live.
    func setLocalLanded(_ landed: Bool) {
        localLanded = landed
        driver?.isLocalPlayerLanded = landed
    }

    /// Called by the game scene each sim tick **before** `world.step`. A no-op in
    /// single-player or when the local player is alone in the system.
    func syncPreStep(world: World) {
        guard isActive, let driver, net != nil else { return }
        driver.syncPreStep(world: world)    // while reconnecting this runs solo: presence is empty, mirrors get cleared
    }

    /// Called by the game scene each sim tick **after** `world.step`. The authority
    /// broadcasts a fresh snapshot; a client sends its input. No-op when alone.
    func syncPostStep(world: World) {
        guard isActive, reconnectState == .idle, let driver, net != nil else { return }
        driver.syncPostStep(world: world)
    }

    /// Authority: share control bits its storyline set since last frame with the
    /// co-located participants (the shared world's story is the authority's, so its
    /// newly-set bits are what everyone earned together). Additions only — the merge
    /// on the receiving side is strictly non-destructive. The first call after a
    /// session starts just seeds the baseline, so a player's *pre-existing* bits
    /// never leak to a partner.
    private func propagateEarnedBits(net: NetSession, to peers: [String]) {
        guard let bits = playerBitsProvider?() else { return }
        if !bitsInitialized { lastKnownBits = bits; bitsInitialized = true; return }
        let added = bits.subtracting(lastKnownBits)
        lastKnownBits = bits
        guard !added.isEmpty, !peers.isEmpty else { return }
        let list = Array(added)
        for peer in peers { net.sendNCB(list, to: peer) }
    }
}
