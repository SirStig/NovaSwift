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

        case .input, .snapshot:
            break  // Layer 2 — handled starting in P1/P2.
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
