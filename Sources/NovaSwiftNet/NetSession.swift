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
    /// Fired when a packet from `peer` can't be decoded as a `NetMessage` - the
    /// signature of a peer running an incompatible protocol version. Purely
    /// additive; the packet is still dropped exactly as before.
    public var onDecodeFailure: ((PeerID) -> Void)?
    /// A peer sent something this session refuses (spoofed identity, host-only message from a non-host, out-of-range
    /// values, flooding). `strikes` counts those within 30 s. The app forwards it to the server as a report; the host
    /// may kick at a threshold.
    public var onMisbehavior: ((PeerID, String, Int) -> Void)?
    /// Players the local user blocked: their chat is dropped (and the UI should hide them). Local only.
    public private(set) var blockedPeers: Set<PeerID> = []
    public func block(_ peer: PeerID) { blockedPeers.insert(peer) }
    public func unblock(_ peer: PeerID) { blockedPeers.remove(peer) }
    private var misbehavior = MisbehaviorTracker()
    private var chatBuckets: [PeerID: TokenBucket] = [:]
    private var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// Test hook: replace the clock rate limits use.
    public func setClock(_ c: @escaping () -> Double) { clock = c }
    /// Messages dropped as invalid since the session started.
    public private(set) var rejectedCount = 0

    private func reject(_ peer: PeerID, _ reason: String) {
        rejectedCount += 1
        let n = misbehavior.strike(peer, now: clock())
        onMisbehavior?(peer, reason, n)
    }

    /// The peer id that owns host-only decisions (rules, kicks), when the transport has one.
    private var hostID: PeerID? { transport.hostPeerID }
    private func isHost(_ peer: PeerID) -> Bool { hostID.map { $0 == peer } ?? true }

    /// Authority of the local player's system (smallest id among the co-located players, including us); nil when alone.
    public func systemAuthorityID() -> PeerID? {
        let others = coLocatedPlayers().map(\.playerID)
        return others.isEmpty ? nil : ([localPlayerID] + others).min()
    }

    /// Players this session (as host) has banned — their presence is refused and a
    /// rejoin is ignored until the session ends.
    public private(set) var bannedIDs: Set<String> = []

    /// Whether this node owns the session rules (the host). When true, a peer that
    /// connects *after* the rules were set is sent the current rules immediately —
    /// without this, a late joiner keeps its seed rules forever (the host's
    /// `broadcastRules` at start reaches nobody, since no peer is connected yet).
    /// Must stay false on guests so they never overwrite the host's rules with
    /// their own seed. Set by the app when it hosts.
    public var providesRules = false

    /// This node's enabled-plug-in manifest, sent to each peer on connect so both
    /// sides can verify they share the same content. `nil` (or `.empty`) = stock
    /// game. Set by the app before the session starts.
    public var localPluginManifest: PluginManifest?
    /// Every peer's received plug-in manifest, keyed by player id. The app diffs a
    /// joiner against the host to decide whether they can play together.
    public private(set) var peerManifests: [String: PluginManifest] = [:]
    /// Fired when a peer's plug-in manifest arrives (peer == its player id).
    public var onPluginManifest: ((PluginManifest, PeerID) -> Void)?

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
        lastPresenceSentAt = clock()
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
        let trimmed = CrossPlayProtocol.cleanChat(text)
        guard !trimmed.isEmpty else { return }
        let message = ChatMessage(playerID: localPlayerID,
                                  senderName: localDisplayName, text: trimmed)
        appendChat(message)
        broadcast(.chat(message))
    }

    /// Most chat lines kept in `chatLog` (oldest dropped first) so a long-lived session or server can't grow without bound.
    public static let maxChatLog = 200

    private func appendChat(_ message: ChatMessage) {
        chatLog.append(message)
        if chatLog.count > Self.maxChatLog { chatLog.removeFirst(chatLog.count - Self.maxChatLog) }
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

    /// Presence heartbeat: while any traffic is flowing, re-send our presence (reliable) at most this often. A
    /// reliable presence/rules packet the relay once refused or lost then heals itself instead of leaving a ghost.
    public static let presenceHeartbeatInterval = 5.0
    private var lastPresenceSentAt = 0.0

    /// Re-announce the local presence if it's been `presenceHeartbeatInterval` since the last announcement. Driven by
    /// incoming traffic (every peer heartbeats, so the chain keeps itself alive) and callable from a host's timer.
    public func presenceHeartbeat() {
        let now = clock()
        guard let mine = presence[localPlayerID], now - lastPresenceSentAt >= Self.presenceHeartbeatInterval else { return }
        lastPresenceSentAt = now
        broadcast(.presence(mine))
    }

    public func transport(_ transport: Transport, didReceive data: Data, from peer: PeerID) {
        defer { presenceHeartbeat() }
        guard data.count <= NetLimits.maxData else { reject(peer, "oversized message"); return }
        guard let message = try? NetCodec.decode(data) else {
            onDecodeFailure?(peer)
            reject(peer, "undecodable message")
            return
        }
        switch message {
        case .presence(let raw):
            // A peer may only announce itself: presence for another id would let it move other players around.
            guard raw.playerID == peer, NetValidation.valid(raw) else { reject(peer, "spoofed or invalid presence"); return }
            let p = NetValidation.sanitized(raw)
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
            guard isHost(peer), NetValidation.valid(rules) else { reject(peer, "session rules from a non-host"); return }
            if rules != sessionRules {
                sessionRules = rules
                onRulesChanged?(rules)
            }

        case .chat(let chat):
            // The sender id and name are ours to fill in, never the sender's word: no speaking as someone else, as
            // "[Server]", or with control characters. Spam is dropped, blocked players are muted locally.
            guard chat.playerID == peer else { reject(peer, "chat with a forged sender"); return }
            var bucket = chatBuckets[peer] ?? TokenBucket(burst: NetLimits.chatBurst, perSecond: NetLimits.chatPerSecond, now: clock())
            let allowed = bucket.take(now: clock())
            chatBuckets[peer] = bucket
            guard allowed else { reject(peer, "chat flooding"); return }
            guard !blockedPeers.contains(peer) else { return }
            let text = CrossPlayProtocol.cleanChat(chat.text)
            guard !text.isEmpty else { return }
            // The relay server's own lines ("[Server]") keep their label; everyone else gets the name their presence
            // announced (brackets and staff look-alikes removed).
            let name: String
            if hostID == peer, presence[peer] == nil {
                name = CrossPlayProtocol.cleanName(chat.senderName, fallback: "Server")
            } else {
                name = (presence[peer]?.name).map { CrossPlayProtocol.cleanPlayerName($0, fallback: "Pilot") }
                    ?? CrossPlayProtocol.cleanPlayerName(chat.senderName, fallback: "Pilot")
            }
            appendChat(ChatMessage(playerID: peer, senderName: name, text: text))

        case .ncb(let update):
            // Story bits only ever come from the authority of the system we share, and only plausible bit numbers.
            guard let authority = systemAuthorityID(), authority == peer, authority != localPlayerID else {
                reject(peer, "story bits from a peer that is not this system's authority"); return
            }
            let bits = NetValidation.sanitizedNCB(update.setBits)
            if bits.count != update.setBits.count { rejectedCount += 1 }
            if !bits.isEmpty { onNCB?(bits, peer) }

        case .kick(let targetID):
            // Sent to us — the host removed us from the lobby. Only the host can do that.
            guard isHost(peer) else { reject(peer, "kick from a non-host"); return }
            if targetID == localPlayerID { onKicked?() }

        case .trade(let signal):
            guard presence[peer] != nil else { reject(peer, "trade from an unknown player"); return }
            switch signal {
            case .offer(let o):
                guard NetValidation.valid(o) else { reject(peer, "implausible trade offer"); return }
                onTrade?(.offer(TradeRules.sanitized(o)), peer)
            case .invite(let n):
                onTrade?(.invite(fromName: CrossPlayProtocol.cleanPlayerName(n, fallback: presence[peer]?.name ?? "Player")), peer)
            default: onTrade?(signal, peer)
            }

        case .pluginManifest(let manifest):
            guard NetValidation.valid(manifest) else { reject(peer, "oversized plug-in manifest"); return }
            peerManifests[peer] = manifest
            onPluginManifest?(manifest, peer)

        case .input(let frame):
            guard NetValidation.valid(frame) else { reject(peer, "implausible input"); return }
            onInput?(frame, peer)

        case .snapshot(let snapshot):
            guard snapshot.ships.count <= NetValidation.maxShips * 4 else { reject(peer, "oversized snapshot"); return }
            onSnapshot?(snapshot, peer)
        }
    }

    public func transport(_ transport: Transport, peerDidConnect peer: PeerID) {
        // Push our presence to the newcomer and ask it to announce its own.
        if let mine = presence[localPlayerID] {
            send(.presence(mine), to: peer)
        }
        send(.presenceRequest, to: peer)
        // Host: the newcomer wasn't connected when we set the rules, so send them
        // now — otherwise it stays on its seed rules (e.g. no real PvP damage).
        if providesRules {
            send(.sessionRules(sessionRules), to: peer)
        }
        // Announce our plug-in set so the newcomer (and we) can verify compatibility.
        if let manifest = localPluginManifest {
            send(.pluginManifest(manifest), to: peer)
        }
    }

    public func transport(_ transport: Transport, peerDidDisconnect peer: PeerID) {
        peerManifests.removeValue(forKey: peer)
        chatBuckets.removeValue(forKey: peer)
        misbehavior.forget(peer)
        // peer id == player id, so drop that player's presence.
        if presence.removeValue(forKey: peer) != nil {
            onPresenceChanged?(self)
        }
    }
}
