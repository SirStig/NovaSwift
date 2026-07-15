import Foundation
import Combine
import NovaSwiftKit
import NovaSwiftNet
import NovaSwiftEngine
import NovaSwiftSync
#if canImport(GameKit)
import GameKit
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

    // MARK: - Trade

    /// The live trade with another player, or nil. Drives the trade window overlay.
    @Published var trade: TradeState?
    /// A pending trade invite from another player awaiting our yes/no.
    @Published var incomingTradeInvite: TradeInvite?
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

    // MARK: - Layer 2 (per-system sim sync)

    /// Maps engine `World` state ⇄ wire snapshots/inputs and owns per-system sync
    /// state. Lives as long as the session; `reset()` on system/role change.
    private var coordinator: SystemSyncCoordinator?
    /// Client side: the freshest snapshot received from the current authority,
    /// applied on the next `syncPreStep`. Latest-wins (unreliable channel).
    private var latestSnapshot: (snapshot: WorldSnapshot, from: String)?
    /// The local player's current system id, for co-location / authority queries.
    private var localSystemID: Int = -1
    /// The local player's current hull type, announced so co-located peers can
    /// build a correctly-sprited mirror of this ship.
    private var localShipTypeID: Int = -1
    /// Monotonic counters for the wire (snapshot tick / input seq).
    private var netTick: UInt32 = 0
    private var inputSeq: UInt32 = 0
    /// Set when the system or authority role changed; the next `syncPreStep` tears
    /// down stale mirrors and resets the coordinator before syncing afresh.
    private var needsResync = false
    /// The authority id used on the previous frame, to detect role/authority change.
    private var lastAuthorityID: String?
    /// Whether we were the authority last frame — drives the handoff transition.
    private var wasAuthority = false

    // MARK: - Co-op story (NCB) sync

    /// The app supplies the local pilot's current NCB vector; the authority diffs it
    /// each frame to find bits its storyline just set and shares them with
    /// co-located participants. Set by `AppModel`.
    var playerBitsProvider: (() -> Set<Int>)?
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
        #if canImport(MultipeerConnectivity)
        let name = lobbyName.isEmpty ? "\(displayName)'s Lobby" : lobbyName
        let mp = MultipeerTransport(playerID: localPlayerID,
                                    mode: .host(lobbyName: name, hostName: displayName))
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
    /// `GKMatch`. Same session/sync machinery; only the transport differs. The
    /// Game Center match host isn't distinguished, so authority is by id (see
    /// `currentAuthorityID`).
    func startGameCenter(match: GKMatch, displayName: String, systemID: Int,
                         shipTypeID: Int? = nil, rules: SessionRules = .fullStakes) {
        stop()
        let gk = GameKitTransport(match: match)
        lobbyName = "Game Center"
        isHost = true
        activate(transport: gk, displayName: displayName, systemID: systemID,
                 shipTypeID: shipTypeID, rules: rules)
    }
    #endif

    /// Shared session bring-up: wrap a transport in a `NetSession`, adopt the
    /// transport's peer id as our player id, wire callbacks + the sync coordinator,
    /// announce presence and (optionally, host-only) rules.
    private func activate(transport: Transport, displayName: String, systemID: Int,
                          shipTypeID: Int?, rules: SessionRules, broadcastRules: Bool = true) {
        if let shipTypeID { localShipTypeID = shipTypeID }
        let session = NetSession(transport: transport, rules: rules)
        // The host owns the rules: it must (re)send them to every peer that connects
        // later, or a joiner keeps its seed `.safe` rules (no real PvP damage) even
        // when it becomes a system's sync authority. Guests never push rules.
        session.providesRules = broadcastRules
        localPlayerID = session.localPlayerID     // the transport owns the peer id
        wire(session)
        self.transport = transport
        net = session
        coordinator = SystemSyncCoordinator(localPlayerID: localPlayerID)
        localSystemID = systemID
        needsResync = true
        self.rules = rules
        session.updateLocalPresence(name: displayName, systemID: systemID,
                                    shipTypeHint: localShipTypeID >= 0 ? localShipTypeID : nil)
        if broadcastRules { session.broadcastRules(rules) }
        isActive = true
        syncPresence()
    }

    /// Leave the session and clear all mirrored state.
    func stop() {
        transport?.disconnect()
        net = nil
        transport = nil
        coordinator = nil
        latestSnapshot = nil
        lastAuthorityID = nil
        wasAuthority = false
        needsResync = false
        netTick = 0
        inputSeq = 0
        lastKnownBits = []
        bitsInitialized = false
        isActive = false
        isHost = false
        joinedHostID = nil
        lobbyName = ""
        trade = nil
        incomingTradeInvite = nil
        chatLog = []
        presence = [:]
        unreadCount = 0
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
        syncPresence()
    }

    /// Ban a player from the lobby for the rest of the session (host only).
    func ban(_ playerID: String) {
        guard isHost else { return }
        net?.ban(playerID)
        syncPresence()
    }

    /// Host-only: push updated session rules to everyone mid-lobby.
    func updateRules(_ newRules: SessionRules) {
        guard isHost else { return }
        rules = newRules
        net?.broadcastRules(newRules)
    }

    // MARK: - Trade API (used by the UI)

    /// Whether we can start a trade with `playerID` right now.
    func canTrade(with playerID: String) -> Bool {
        rules.allowTrade && trade == nil && playerID != localPlayerID && presence[playerID] != nil
    }

    /// Invite another player to trade. Opens our (waiting) trade window.
    func inviteTrade(with playerID: String, myName: String) {
        guard canTrade(with: playerID) else { return }
        let name = presence[playerID]?.name ?? "Player"
        trade = TradeState(partnerID: playerID, partnerName: name, partnerJoined: false)
        net?.sendTrade(.invite(fromName: myName), to: playerID)
    }

    /// Accept an incoming trade invite — opens the window and acks the inviter.
    func acceptTradeInvite() {
        guard let invite = incomingTradeInvite else { return }
        trade = TradeState(partnerID: invite.id, partnerName: invite.name, partnerJoined: true)
        net?.sendTrade(.offer(TradeOffer()), to: invite.id)   // ack + initial (empty) offer
        incomingTradeInvite = nil
    }

    /// Decline an incoming trade invite.
    func declineTradeInvite() {
        guard let invite = incomingTradeInvite else { return }
        net?.sendTrade(.decline, to: invite.id)
        incomingTradeInvite = nil
    }

    /// Replace our current offer (called live as the player edits it). Any change
    /// resets both sides' acceptance — the deal changed, so it must be re-confirmed.
    func updateMyOffer(_ offer: TradeOffer) {
        guard var t = trade else { return }
        t.myOffer = offer
        t.myAccepted = false
        t.theirAccepted = false
        trade = t
        net?.sendTrade(.offer(offer), to: t.partnerID)
    }

    /// Toggle our acceptance; when both sides accept, the trade commits.
    func setTradeAccepted(_ accepted: Bool) {
        guard var t = trade else { return }
        t.myAccepted = accepted
        trade = t
        net?.sendTrade(.accept(accepted), to: t.partnerID)
        commitTradeIfReady()
    }

    /// Cancel the live trade and tell the partner.
    func cancelTrade() {
        guard let t = trade else { return }
        net?.sendTrade(.cancel, to: t.partnerID)
        trade = nil
    }

    private func commitTradeIfReady() {
        guard let t = trade, t.myAccepted, t.theirAccepted else { return }
        onTradeCommitted?(t.myOffer, t.theirOffer)
        trade = nil
    }

    private func handleTrade(_ signal: TradeSignal, from peer: String) {
        switch signal {
        case .invite(let fromName):
            // Only when trading is allowed and we're free; else politely decline.
            if rules.allowTrade, trade == nil, incomingTradeInvite == nil {
                incomingTradeInvite = TradeInvite(id: peer, name: fromName)
            } else {
                net?.sendTrade(.decline, to: peer)
            }
        case .decline:
            if trade?.partnerID == peer { trade = nil }
        case .offer(let offer):
            guard var t = trade, t.partnerID == peer else { return }
            t.theirOffer = offer
            t.partnerJoined = true
            t.myAccepted = false        // the deal changed — re-confirm
            t.theirAccepted = false
            trade = t
        case .accept(let accepted):
            guard var t = trade, t.partnerID == peer else { return }
            t.theirAccepted = accepted
            trade = t
            commitTradeIfReady()
        case .cancel:
            if trade?.partnerID == peer { trade = nil }
            if incomingTradeInvite?.id == peer { incomingTradeInvite = nil }   // inviter withdrew
        }
    }

    /// Drop a live trade / invite if the other party has left the session.
    private func pruneTradeIfPartnerGone() {
        if let t = trade, presence[t.partnerID] == nil { trade = nil }
        if let inv = incomingTradeInvite, presence[inv.id] == nil { incomingTradeInvite = nil }
    }

    // MARK: - Presence / chat API (used by the app)

    /// Push the local player's location — call on spawn and every system jump.
    /// Safe to call when no session is active. `shipTypeID` (the player's current
    /// hull) rides along so co-located peers can sprite this ship's mirror.
    func updatePresence(systemID: Int, name: String, shipTypeID: Int? = nil) {
        if let shipTypeID { localShipTypeID = shipTypeID }
        if systemID != localSystemID {
            localSystemID = systemID
            needsResync = true          // new system ⇒ fresh world ⇒ drop mirrors
        }
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

    private func wire(_ session: NetSession) {
        session.onChat = { [weak self] message in
            guard let self else { return }
            self.chatLog = session.chatLog
            if !self.chatVisible && message.playerID != self.localPlayerID {
                self.unreadCount += 1
            }
        }
        session.onPresenceChanged = { [weak self] _ in self?.syncPresence() }
        session.onRulesChanged = { [weak self] rules in self?.rules = rules }
        // Layer 2: authority collects clients' inputs; client buffers the newest
        // snapshot for the next frame.
        session.onInput = { [weak self] frame, peer in self?.coordinator?.receiveInput(frame, from: peer) }
        session.onSnapshot = { [weak self] snapshot, peer in self?.latestSnapshot = (snapshot, peer) }
        // Co-op story: a partner's shared storyline earned bits — union them locally.
        session.onNCB = { [weak self] bits, _ in self?.onRemoteBitsEarned?(Set(bits)) }
        // The host kicked us: leave the session and let the UI explain.
        session.onKicked = { [weak self] in
            self?.stop()
            self?.wasKicked = true
        }
        // Trade handshakes from a partner.
        session.onTrade = { [weak self] signal, peer in self?.handleTrade(signal, from: peer) }
    }

    private func syncPresence() {
        presence = net?.presence ?? [:]
        pruneTradeIfPartnerGone()
    }

    // MARK: - Layer 2 role logic + game-loop hooks

    /// Other players sharing the local player's current system.
    private func coLocatedIDs() -> [String] {
        guard localSystemID >= 0 else { return [] }
        return presence.values
            .filter { $0.currentSystemID == localSystemID && $0.playerID != localPlayerID }
            .map(\.playerID)
    }

    /// Who is authority for the local player's current system: the co-located
    /// player with the smallest id (deterministic, no negotiation). Nil when the
    /// local player is alone — then there's no sync and the sim runs single-player.
    private var currentAuthorityID: String? {
        let others = coLocatedIDs()
        guard !others.isEmpty else { return nil }
        return ([localPlayerID] + others).min()
    }

    /// Whether Layer-2 sync is engaged right now (≥2 players co-located).
    var isSyncingSystem: Bool { isActive && currentAuthorityID != nil }

    /// Called by the game scene each frame **before** `world.step`. Injects/updates
    /// co-op ships and, on the authority, feeds clients' inputs into the world. A
    /// no-op in single-player or when the local player is alone in the system.
    /// Full teardown of every co-op mirror + visual echo, spawner resumed — used on
    /// a system change (fresh world) or when we drop back to solo.
    private func fullClearMirrors(_ world: World, _ coordinator: SystemSyncCoordinator) {
        let ids = world.npcs.filter { $0.remotePlayer != nil || $0.networkMirror }.map { $0.entityID }
        for id in ids { world.removeShip(entityID: id) }
        world.clearVisualProjectiles()
        world.clearVisualBeams()
        world.spawningPaused = false
        coordinator.reset()
        latestSnapshot = nil
    }

    /// Promote a mirrored NPC to a real, self-driving ship when we take over as
    /// authority — keeps the shared cast alive across a handoff instead of clearing
    /// and re-rolling it. It gets a plausible brain from its hull (armed ⇒ warship).
    private func promoteNPC(_ ship: Ship, in world: World) {
        ship.networkMirror = false
        let type: AIType = ship.weapons.isEmpty ? .braveTrader : .warship
        ship.brain = AIBrain(aiType: type, govt: ship.government)
    }

    /// Handle an authority change (host left / handoff) as seamlessly as the case
    /// allows. Player mirrors are keyed by stable id, so friends' ships carry
    /// through; only NPCs (whose ids are authority-specific) re-roll.
    private func handleAuthorityChange(to authority: String?, iAmAuthority: Bool,
                                       world: World, coordinator: SystemSyncCoordinator) {
        latestSnapshot = nil
        if authority == nil {
            fullClearMirrors(world, coordinator)                 // dropped back to solo
        } else if iAmAuthority && !wasAuthority {
            // Client → new host: adopt the mirrored world instead of rebuilding it.
            let toPromote = coordinator.promoteToAuthority(world: world)
            for npc in toPromote { promoteNPC(npc, in: world) }
            world.clearVisualProjectiles(); world.clearVisualBeams()   // we produce real ones now
            world.spawningPaused = false
        } else if !iAmAuthority && wasAuthority {
            // Host → client (rare — a smaller id joined): tear down our own world;
            // the client branch below repopulates as a mirror of the new host.
            fullClearMirrors(world, coordinator)
        } else {
            // Client → a *different* host: keep player mirrors (stable ids reconcile
            // in place — no blink), drop only the NPC mirrors (authority-specific ids).
            let npcIDs = world.npcs.filter { $0.networkMirror }.map { $0.entityID }
            for id in npcIDs { world.removeShip(entityID: id) }
            world.clearVisualProjectiles(); world.clearVisualBeams()
            coordinator.resetForAuthorityChange()                // spawner stays paused (still a client)
        }
    }

    func syncPreStep(world: World) {
        guard isActive, let coordinator, net != nil else { return }

        // Honor the session's stakes (host-set). Applied every frame so a
        // mid-session rules change takes effect immediately.
        world.pvpAllowed = rules.allowPvP
        world.friendlyFireAllowed = rules.friendlyFire
        world.pvpDamageReal = rules.pvpDamageReal
        world.playerDeathReal = rules.deathReal

        let authority = currentAuthorityID
        let iAmAuthority = (authority == localPlayerID)
        // Whenever we're not the story authority (solo or a client), re-seed the NCB
        // baseline so bits we earn *outside* a shared moment don't propagate when we
        // next become the authority — only bits earned while co-hosting are shared.
        if !iAmAuthority { bitsInitialized = false }

        if needsResync {
            // A fresh **system** (new world) → full reset from our own galaxy.
            fullClearMirrors(world, coordinator)
            needsResync = false
            wasAuthority = iAmAuthority
            lastAuthorityID = authority
        } else if authority != lastAuthorityID {
            // Authority **handoff** (same system, host left/changed) — handled
            // seamlessly where possible (see `handleAuthorityChange`).
            handleAuthorityChange(to: authority, iAmAuthority: iAmAuthority,
                                  world: world, coordinator: coordinator)
            wasAuthority = iAmAuthority
            lastAuthorityID = authority
        }
        guard let authority else { return }   // alone → single-player sim

        if authority == localPlayerID {
            // AUTHORITY: mirror co-located clients and drive them from their input.
            // We keep simulating our own world (spawner runs) — it's the canonical one.
            let clients = coLocatedIDs().map { (id: $0, name: presence[$0]?.name ?? $0) }
            coordinator.syncClients(clients, into: world) { [weak self] id, name in
                self?.buildMirror(shipTypeID: self?.presence[id]?.shipTypeHint ?? -1,
                                  government: world.player.government, name: name,
                                  world: world, at: world.player.position + Vec2(220, 0))
                    ?? SystemSyncCoordinator.defaultClientShip(id, name)
            }
            coordinator.applyInputs(to: world)
        } else if let (snapshot, from) = latestSnapshot, from == authority {
            // CLIENT: adopt the authority's world. Hand our own populated cast over
            // to theirs (pause our spawner + clear our AI once), then mirror theirs.
            if !world.spawningPaused {
                world.spawningPaused = true
                world.removeAINPCs()
            }
            coordinator.apply(
                snapshot, to: world, authorityPeer: from,
                makeMirror: { [weak self] state in
                    // A co-op partner — tint to our government so we read as allies.
                    self?.buildMirror(shipTypeID: state.shipTypeID, government: world.player.government,
                                      name: state.name, world: world,
                                      at: Vec2(state.x, state.y), angle: state.angle)
                        ?? SystemSyncCoordinator.defaultMirror(state)
                },
                makeNPCMirror: { [weak self] state in
                    // An NPC — keep its real government so hostiles still read hostile.
                    self?.buildMirror(shipTypeID: state.shipTypeID, government: state.government,
                                      name: state.name, world: world,
                                      at: Vec2(state.x, state.y), angle: state.angle)
                        ?? SystemSyncCoordinator.defaultMirror(state)
                })
            latestSnapshot = nil
        }
    }

    /// Called by the game scene each frame **after** `world.step`. The authority
    /// broadcasts a fresh snapshot; a client sends its input. No-op when alone.
    func syncPostStep(world: World) {
        guard isActive, let coordinator, let net, let authority = currentAuthorityID else { return }
        netTick &+= 1
        if authority == localPlayerID {
            net.broadcastSnapshot(coordinator.snapshot(of: world, tick: netTick))
            propagateEarnedBits(net: net, to: coLocatedIDs())
        } else {
            inputSeq &+= 1
            net.sendInput(coordinator.input(from: world.intent, tick: netTick, seq: inputSeq), to: authority)
            // Replay the authority's one-shot effects (explosions) now — after the
            // step cleared this frame's events, before the scene drains them.
            coordinator.flushEffects(into: world)
        }
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

    /// Build a co-op mirror hull from the loaded galaxy (correct sprite/size/
    /// weapons) at `government` — the local player's govt for a partner (reads as
    /// ally), the reported govt for an NPC (stays hostile if it was). Returns nil
    /// when the type can't be resolved so the coordinator's default hull is used.
    private func buildMirror(shipTypeID: Int, government: Int, name: String, world: World,
                             at position: Vec2, angle: Double = 0) -> Ship? {
        guard shipTypeID >= 0,
              let ship = world.galaxy?.makeShip(shipTypeID, government: government,
                                                at: position, angle: angle)
        else { return nil }
        return ship
    }
}
