import Foundation

/// The always-on multiplayer backbone (Layer 1). Owns a `Transport`, the local
/// player's presence, and the shared presence table — every peer's
/// who-is-in-which-system view. It keeps that view current across joins, moves,
/// and drops, and answers co-location queries. Layer 2 (per-system simulation
/// sync) builds on top of this in P1/P2.
///
/// Threading: P0 assumes callbacks arrive on a single context (true for
/// `LoopbackTransport`). Real backends will marshal onto a chosen queue before
/// mutating the session.
///
/// See `docs/MULTIPLAYER.md`.
public final class NetSession: TransportDelegate {
    /// This player's id — equal to the transport peer id (see `PeerID`).
    public let localPlayerID: String
    private let transport: Transport

    /// playerID → latest presence, including the local player once announced.
    public private(set) var presence: [String: PlayerPresence] = [:]

    /// The rules for this session. Guests adopt the host's on receipt.
    public private(set) var sessionRules: SessionRules

    /// Session-wide chat history, oldest first — both received and locally sent
    /// messages, in arrival order. A UI can render this directly.
    public private(set) var chatLog: [ChatMessage] = []

    /// Fired whenever the presence table changes (peer moved / joined / left).
    public var onPresenceChanged: ((NetSession) -> Void)?
    /// Fired for every chat message appended to `chatLog` — sent or received.
    public var onChat: ((ChatMessage) -> Void)?
    /// Fired when the session rules change (host pushed new rules).
    public var onRulesChanged: ((SessionRules) -> Void)?
    /// Layer 2 — fired on the authority when a co-located client's `InputFrame`
    /// arrives (peer == that client's player id). The authority maps it to the
    /// right remote-player ship and publishes it into `World.remoteIntents`.
    public var onInput: ((InputFrame, PeerID) -> Void)?
    /// Layer 2 — fired on a client when the system authority's `WorldSnapshot`
    /// arrives (peer == the authority's player id). The client reconciles the
    /// snapshot's ships into its local `World` (inject/update remote players,
    /// interpolate). See `docs/MULTIPLAYER.md` → "Layer 2".
    public var onSnapshot: ((WorldSnapshot, PeerID) -> Void)?
    /// Co-op story — fired when another player's shared storyline set control bits
    /// (`NCBUpdate`). The app unions them into the local pilot's NCB vector
    /// (non-destructive). See `docs/MULTIPLAYER.md` → "Story / NCB split".
    public var onNCB: (([Int], PeerID) -> Void)?
    /// Fired on a player the host has kicked — the app tears its session down.
    public var onKicked: (() -> Void)?
    /// Fired for a trade handshake message from `peer` (invite/offer/accept/cancel).
    public var onTrade: ((TradeSignal, PeerID) -> Void)?

    /// Players this session (as host) has banned — their presence is refused and a
    /// rejoin is ignored until the session ends.
    public private(set) var bannedIDs: Set<String> = []

    public init(transport: Transport, rules: SessionRules = .fullStakes) {
        self.localPlayerID = transport.localPeerID
        self.transport = transport
        self.sessionRules = rules
        transport.delegate = self
    }

    // MARK: - Presence

    /// Set/replace the local player's presence and broadcast it. Call on spawn
    /// and on every system change.
    public func updateLocalPresence(name: String, systemID: Int, shipTypeHint: Int? = nil) {
        let mine = PlayerPresence(playerID: localPlayerID, name: name,
                                  currentSystemID: systemID, shipTypeHint: shipTypeHint)
        let changed = presence[localPlayerID] != mine
        presence[localPlayerID] = mine
        broadcast(.presence(mine))
        if changed { onPresenceChanged?(self) }
    }

    /// Players currently in a given system, optionally excluding one id.
    public func players(inSystem systemID: Int, excluding excludedID: String? = nil) -> [PlayerPresence] {
        presence.values
            .filter { $0.currentSystemID == systemID && $0.playerID != excludedID }
            .sorted { $0.playerID < $1.playerID }
    }

    /// Other players sharing the local player's current system. Empty until the
    /// local presence has been set. This is the co-location signal that engages
    /// Layer 2 sync for a system.
    public func coLocatedPlayers() -> [PlayerPresence] {
        guard let mine = presence[localPlayerID] else { return [] }
        return players(inSystem: mine.currentSystemID, excluding: localPlayerID)
    }

    // MARK: - Rules & chat

    /// Host pushes the session rules to all peers.
    public func broadcastRules(_ rules: SessionRules) {
        sessionRules = rules
        broadcast(.sessionRules(rules))
    }

    // MARK: - Moderation (host)

    /// Remove a player from the lobby (host action): tell them they're kicked and
    /// drop their presence locally. `ban` also blacklists the id so a rejoin is
    /// refused for the rest of the session.
    public func kick(_ playerID: String, ban: Bool = false) {
        guard playerID != localPlayerID else { return }
        if ban { bannedIDs.insert(playerID) }
        send(.kick(playerID), to: playerID)
        if presence.removeValue(forKey: playerID) != nil { onPresenceChanged?(self) }
    }

    /// Ban a player: kick them and refuse their presence for the rest of the session.
    public func ban(_ playerID: String) { kick(playerID, ban: true) }

    // MARK: - Trade

    /// Send a trade handshake message to a specific peer (reliable — trade state
    /// must not be lost).
    public func sendTrade(_ signal: TradeSignal, to peer: String) {
        send(.trade(signal), to: peer, channel: .reliable)
    }

    /// Whether a player is currently banned from this (host's) session.
    public func isBanned(_ playerID: String) -> Bool { bannedIDs.contains(playerID) }

    /// The name shown for the local player in chat — their presence name once
    /// announced, else their id.
    public var localDisplayName: String {
        presence[localPlayerID]?.name ?? localPlayerID
    }

    /// Send a session-wide chat message. Appears immediately in the local
    /// `chatLog` and is delivered to every connected peer. Blank text is ignored.
    public func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let message = ChatMessage(playerID: localPlayerID,
                                  senderName: localDisplayName, text: trimmed)
        appendChat(message)
        broadcast(.chat(message))
    }

    private func appendChat(_ message: ChatMessage) {
        chatLog.append(message)
        onChat?(message)
    }

    // MARK: - Layer 2 (per-system sim sync)

    /// Client → authority: this frame's control input. Sent on the **unreliable**
    /// channel — inputs are a high-rate stream where the freshest frame wins, so a
    /// dropped one is simply superseded by the next (`seq`/`tick` let the authority
    /// discard stale/out-of-order arrivals). `authority` is the peer id of the
    /// system's current authority (from presence / authority selection).
    public func sendInput(_ frame: InputFrame, to authority: PeerID) {
        send(.input(frame), to: authority, channel: .unreliable)
    }

    /// Authority → one client: the current world snapshot for the shared system,
    /// on the **unreliable** channel (latest-state-wins, same rationale as input).
    /// Send per co-located client so each can be delta'd against its own ack later.
    public func sendSnapshot(_ snapshot: WorldSnapshot, to client: PeerID) {
        send(.snapshot(snapshot), to: client, channel: .unreliable)
    }

    /// Authority → all co-located clients: broadcast one snapshot to everyone. A
    /// convenience over per-client `sendSnapshot` while snapshots aren't yet
    /// per-client delta-compressed.
    public func broadcastSnapshot(_ snapshot: WorldSnapshot) {
        broadcast(.snapshot(snapshot), channel: .unreliable)
    }

    /// Send earned control bits to one co-located participant, on the **reliable**
    /// channel — a lost story bit would desync progress, so unlike snapshots these
    /// must arrive. Sent per-participant (not broadcast) so only co-located players
    /// who shared the moment receive them.
    public func sendNCB(_ setBits: [Int], to peer: PeerID) {
        guard !setBits.isEmpty else { return }
        send(.ncb(NCBUpdate(setBits: setBits)), to: peer, channel: .reliable)
    }

    // MARK: - Send helpers

    private func broadcast(_ message: NetMessage, channel: NetChannel = .reliable) {
        guard let data = try? NetCodec.encode(message) else { return }
        transport.broadcast(data, channel: channel)
    }

    private func send(_ message: NetMessage, to peer: PeerID, channel: NetChannel = .reliable) {
        guard let data = try? NetCodec.encode(message) else { return }
        transport.send(data, to: peer, channel: channel)
    }

    // MARK: - TransportDelegate

    public func transport(_ transport: Transport, didReceive data: Data, from peer: PeerID) {
        guard let message = try? NetCodec.decode(data) else { return }
        switch message {
        case .presence(let p):
            guard !bannedIDs.contains(p.playerID) else { return }   // banned: ignore
            let changed = presence[p.playerID] != p
            presence[p.playerID] = p
            if changed { onPresenceChanged?(self) }

        case .presenceRequest:
            // A newcomer asked us to re-announce; reply directly so it converges.
            if let mine = presence[localPlayerID] {
                send(.presence(mine), to: peer)
            }

        case .sessionRules(let rules):
            if rules != sessionRules {
                sessionRules = rules
                onRulesChanged?(rules)
            }

        case .chat(let chat):
            appendChat(chat)

        case .ncb(let update):
            onNCB?(update.setBits, peer)

        case .kick(let targetID):
            // Sent to us — the host removed us from the lobby.
            if targetID == localPlayerID { onKicked?() }

        case .trade(let signal):
            onTrade?(signal, peer)

        case .input(let frame):
            onInput?(frame, peer)

        case .snapshot(let snapshot):
            onSnapshot?(snapshot, peer)
        }
    }

    public func transport(_ transport: Transport, peerDidConnect peer: PeerID) {
        // Push our presence to the newcomer and ask it to announce its own.
        if let mine = presence[localPlayerID] {
            send(.presence(mine), to: peer)
        }
        send(.presenceRequest, to: peer)
    }

    public func transport(_ transport: Transport, peerDidDisconnect peer: PeerID) {
        // peer id == player id, so drop that player's presence.
        if presence.removeValue(forKey: peer) != nil {
            onPresenceChanged?(self)
        }
    }
}
