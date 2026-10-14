import Foundation
import NovaSwiftEngine
import NovaSwiftKit
import NovaSwiftNet

/// The frontend-agnostic Layer-2 role logic: given a `NetSession`, decide whether
/// this node is the authority for its current system, and each frame (a) before
/// `world.step` inject/drive the co-op ships (authority) or adopt the authority's
/// snapshot (client), and (b) after the step broadcast a snapshot (authority) or
/// send input (client). Authority handoff, system-change resets and stakes
/// (`SessionRules`) application live here.
///
/// Extracted verbatim from the Apple app's `MultiplayerSession` so the Apple app
/// and the Godot bridge run the **same** logic; both call `syncPreStep` /
/// `syncPostStep` around their `world.step`. App-only concerns (published UI
/// state, NCB story propagation) hook in through the closures below.
public final class SystemSyncDriver {
    public let session: NetSession
    public let coordinator: SystemSyncCoordinator
    public var localPlayerID: String { session.localPlayerID }

    /// The local player's current system id, for co-location / authority queries.
    public private(set) var localSystemID: Int
    /// Client side: freshest snapshot from the current authority (latest-wins).
    private var latestSnapshot: (snapshot: WorldSnapshot, from: String)?
    private var netTick: UInt32 = 0
    private var inputSeq: UInt32 = 0
    /// Set when the system or authority role changed; next `syncPreStep` tears
    /// down stale mirrors and resets the coordinator before syncing afresh.
    private var needsResync = true
    private var lastAuthorityID: String?
    private var wasAuthority = false

    /// Called every pre-step frame in which this node is NOT the authority (solo
    /// or client). The Apple app uses it to re-seed its NCB baseline.
    public var onNotAuthority: (() -> Void)?
    /// Called after the authority broadcast its snapshot, with the co-located
    /// player ids (Apple: NCB story-bit propagation).
    public var onAuthorityPostStep: ((NetSession, [String]) -> Void)?

    public init(session: NetSession, localSystemID: Int) {
        self.session = session
        self.coordinator = SystemSyncCoordinator(localPlayerID: session.localPlayerID)
        self.localSystemID = localSystemID
    }

    // MARK: - Inbound hooks (wire to NetSession.onInput / onSnapshot)

    public func receiveInput(_ frame: InputFrame, from peer: String) {
        coordinator.receiveInput(frame, from: peer)
    }

    public func receiveSnapshot(_ snapshot: WorldSnapshot, from peer: String) {
        latestSnapshot = (snapshot, peer)
    }

    /// The local player moved to `systemID` (a fresh world): drop mirrors on the
    /// next pre-step. No-op if unchanged.
    public func setLocalSystem(_ systemID: Int) {
        if systemID != localSystemID {
            localSystemID = systemID
            needsResync = true
        }
    }

    // MARK: - Role logic

    /// Other players sharing the local player's current system.
    public func coLocatedIDs() -> [String] {
        guard localSystemID >= 0 else { return [] }
        return session.presence.values
            .filter { $0.currentSystemID == localSystemID && $0.playerID != localPlayerID }
            .map(\.playerID)
    }

    /// Authority for the local player's current system: smallest id among the
    /// co-located players. Nil when alone (single-player sim).
    public var currentAuthorityID: String? {
        let others = coLocatedIDs()
        guard !others.isEmpty else { return nil }
        return ([localPlayerID] + others).min()
    }

    /// Whether Layer-2 sync is engaged right now (>=2 players co-located).
    public var isSyncingSystem: Bool { currentAuthorityID != nil }

    private func fullClearMirrors(_ world: World) {
        let ids = world.npcs.filter { $0.remotePlayer != nil || $0.networkMirror }.map { $0.entityID }
        for id in ids { world.removeShip(entityID: id) }
        world.clearVisualProjectiles()
        world.clearVisualBeams()
        world.spawningPaused = false
        coordinator.reset()
        latestSnapshot = nil
    }

    private func promoteNPC(_ ship: Ship, in world: World) {
        ship.networkMirror = false
        let type: AIType = ship.weapons.isEmpty ? .braveTrader : .warship
        ship.brain = AIBrain(aiType: type, govt: ship.government)
    }

    private func handleAuthorityChange(to authority: String?, iAmAuthority: Bool, world: World) {
        latestSnapshot = nil
        if authority == nil {
            fullClearMirrors(world)                              // dropped back to solo
        } else if iAmAuthority && !wasAuthority {
            // Client -> new host: adopt the mirrored world instead of rebuilding it.
            let toPromote = coordinator.promoteToAuthority(world: world)
            for npc in toPromote { promoteNPC(npc, in: world) }
            world.clearVisualProjectiles(); world.clearVisualBeams()
            world.spawningPaused = false
        } else if !iAmAuthority && wasAuthority {
            // Host -> client (a smaller id joined): tear down our own world.
            fullClearMirrors(world)
        } else {
            // Client -> a different host: keep player mirrors, drop NPC mirrors.
            let npcIDs = world.npcs.filter { $0.networkMirror }.map { $0.entityID }
            for id in npcIDs { world.removeShip(entityID: id) }
            world.clearVisualProjectiles(); world.clearVisualBeams()
            coordinator.resetForAuthorityChange()
        }
    }

    /// Call each frame **before** `world.step`.
    public func syncPreStep(world: World) {
        let rules = session.sessionRules
        world.pvpAllowed = rules.allowPvP
        world.friendlyFireAllowed = rules.friendlyFire
        world.pvpDamageReal = rules.pvpDamageReal
        world.playerDeathReal = rules.deathReal

        let authority = currentAuthorityID
        let iAmAuthority = (authority == localPlayerID)
        if !iAmAuthority { onNotAuthority?() }

        if needsResync {
            fullClearMirrors(world)
            needsResync = false
            wasAuthority = iAmAuthority
            lastAuthorityID = authority
        } else if authority != lastAuthorityID {
            handleAuthorityChange(to: authority, iAmAuthority: iAmAuthority, world: world)
            wasAuthority = iAmAuthority
            lastAuthorityID = authority
        }
        guard let authority else { return }

        if authority == localPlayerID {
            let presence = session.presence
            let clients = coLocatedIDs().map { (id: $0, name: presence[$0]?.name ?? $0) }
            coordinator.syncClients(clients, into: world) { [weak self] id, name in
                self?.buildMirror(shipTypeID: presence[id]?.shipTypeHint ?? -1,
                                  government: world.player.government, name: name,
                                  world: world, at: world.player.position + Vec2(220, 0))
                    ?? SystemSyncCoordinator.defaultClientShip(id, name)
            }
            coordinator.applyInputs(to: world)
        } else if let (snapshot, from) = latestSnapshot, from == authority {
            if !world.spawningPaused {
                world.spawningPaused = true
                world.removeAINPCs()
            }
            coordinator.apply(
                snapshot, to: world, authorityPeer: from,
                makeMirror: { [weak self] state in
                    self?.buildMirror(shipTypeID: state.shipTypeID, government: world.player.government,
                                      name: state.name, world: world,
                                      at: Vec2(state.x, state.y), angle: state.angle)
                        ?? SystemSyncCoordinator.defaultMirror(state)
                },
                makeNPCMirror: { [weak self] state in
                    self?.buildMirror(shipTypeID: state.shipTypeID, government: state.government,
                                      name: state.name, world: world,
                                      at: Vec2(state.x, state.y), angle: state.angle)
                        ?? SystemSyncCoordinator.defaultMirror(state)
                })
            latestSnapshot = nil
        }
    }

    /// Call each frame **after** `world.step`.
    public func syncPostStep(world: World) {
        guard let authority = currentAuthorityID else { return }
        netTick &+= 1
        if authority == localPlayerID {
            session.broadcastSnapshot(coordinator.snapshot(of: world, tick: netTick))
            onAuthorityPostStep?(session, coLocatedIDs())
        } else {
            inputSeq &+= 1
            session.sendInput(coordinator.input(from: world.intent, tick: netTick, seq: inputSeq), to: authority)
            coordinator.flushEffects(into: world)
        }
    }

    /// Force a full mirror teardown on the next pre-step - the host rebuilt its
    /// `World` (launch / jump) so every entity id the coordinator knows is stale.
    public func forceResync() { needsResync = true }

    /// Stop-time reset (mirrors what leaving the session cleared in the app).
    public func reset() {
        latestSnapshot = nil
        lastAuthorityID = nil
        wasAuthority = false
        needsResync = false
        netTick = 0
        inputSeq = 0
    }

    private func buildMirror(shipTypeID: Int, government: Int, name: String, world: World,
                             at position: Vec2, angle: Double = 0) -> Ship? {
        guard shipTypeID >= 0,
              let ship = world.galaxy?.makeShip(shipTypeID, government: government,
                                                at: position, angle: angle)
        else { return nil }
        return ship
    }
}
