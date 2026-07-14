import NovaSwiftEngine
import NovaSwiftNet

/// Drives Layer-2 per-system simulation sync between one local `World` and the
/// co-located peers, on top of a `NetSession`. It is deliberately transport- and
/// loop-agnostic: the app calls the role-appropriate methods from its game loop
/// and does the actual `NetSession.sendInput`/`broadcastSnapshot` — this type only
/// maps engine state ⇄ wire types and owns the small amount of per-system state
/// (the client's authority-id → local-mirror-id map, and the authority's freshest
/// input per client).
///
/// Roles (a system's authority is chosen from presence app-side):
/// - **Authority** owns the live `World`. Each frame: `applyInputs(to:)` before
///   `world.step` so co-located friends' ships move under the inputs they sent,
///   then `snapshot(of:tick:)` after the step to broadcast.
/// - **Client** predicts its own ship locally and mirrors everyone else. Feed
///   received snapshots to `apply(_:to:authorityPeer:)`, and send
///   `input(from:tick:seq:)` each frame.
///
/// Scope of this slice: **player ships** (the "come help me" core). NPC/projectile
/// sync rides the same snapshot channel and is layered on next. See
/// `docs/MULTIPLAYER.md` → "Layer 2".
public final class SystemSyncCoordinator {
    public let localPlayerID: String

    /// Client side: authority entity id → our local mirror ship's entity id, for
    /// every remote player we've injected into the local `World`. Reset when the
    /// local player changes system (a fresh `World` invalidates all mirrors).
    private var mirrorIDByAuthorityID: [Int: Int] = [:]

    /// Authority side: the freshest input each client has sent, plus the highest
    /// `seq` seen from it so stale/out-of-order unreliable frames are dropped.
    private var latestInput: [String: NetIntent] = [:]
    private var highestSeq: [String: UInt32] = [:]

    public init(localPlayerID: String) {
        self.localPlayerID = localPlayerID
    }

    /// Drop all per-system state. Call on a local system change or role change —
    /// the old `World`'s entity ids and the old authority's ids no longer apply.
    public func reset() {
        mirrorIDByAuthorityID.removeAll()
        latestInput.removeAll()
        highestSeq.removeAll()
    }

    // MARK: - Authority side

    /// Record a client's input (wire `NetSession.onInput` to this). Keeps only the
    /// freshest frame per client by `seq`, so a late/duplicate unreliable packet
    /// can't rewind a client's control.
    public func receiveInput(_ frame: InputFrame, from client: String) {
        if let seen = highestSeq[client], frame.seq <= seen { return }
        highestSeq[client] = frame.seq
        latestInput[client] = frame.intent
    }

    /// Publish each client's freshest input into `world.remoteIntents`, keyed by the
    /// mirror ship whose `remotePlayer.peerID` is that client. Call **before**
    /// `world.step`. A client with no ship yet (not injected) is skipped; a ship
    /// with no fresh input keeps coasting (handled in the engine as an empty intent).
    public func applyInputs(to world: World) {
        guard !latestInput.isEmpty else { return }
        for ship in world.remotePlayerShips {
            guard let peer = ship.remotePlayer?.peerID,
                  let intent = latestInput[peer] else { continue }
            world.remoteIntents[ship.entityID] = intent.engineIntent
        }
    }

    /// Build the snapshot to broadcast to clients. Call **after** `world.step`.
    public func snapshot(of world: World, tick: UInt32, ackInputSeq: UInt32 = 0) -> WorldSnapshot {
        WorldSnapshot.build(from: world, localPlayerID: localPlayerID,
                            tick: tick, ackInputSeq: ackInputSeq)
    }

    // MARK: - Client side

    /// This frame's input to send to the authority (from the local player's intent).
    public func input(from intent: ControlIntent, tick: UInt32, seq: UInt32) -> InputFrame {
        InputFrame(tick: tick, seq: seq, intent: NetIntent(intent))
    }

    /// Reconcile a received snapshot into the local `World`: inject a mirror ship
    /// for every remote player we haven't seen, update the ones we have, and remove
    /// mirrors for players who left the authority's system. Our **own** ship
    /// (`playerID == localPlayerID`) is skipped — we predict it locally. NPCs are
    /// not mirrored in this slice.
    ///
    /// `makeMirror` builds the local `Ship` for a newly-appeared remote player from
    /// its wire state — the app supplies it so it can size the hull/sprite from the
    /// player's `shipTypeHint`; a default is provided for headless use/tests.
    @discardableResult
    public func apply(_ snapshot: WorldSnapshot, to world: World, authorityPeer: String,
                      makeMirror: (ShipNetState) -> Ship = SystemSyncCoordinator.defaultMirror)
        -> (injected: [Int], removed: [Int])
    {
        var seenAuthorityIDs = Set<Int>()
        var injected: [Int] = []

        for state in snapshot.ships {
            guard let owner = state.playerID else { continue }   // NPC — deferred
            guard owner != localPlayerID else { continue }       // my own ship — predicted locally
            seenAuthorityIDs.insert(state.id)

            if let localID = mirrorIDByAuthorityID[state.id], let ship = world.ship(id: localID) {
                updateMirror(ship, from: state)
            } else {
                let ship = makeMirror(state)
                let localID = world.spawnRemotePlayer(
                    ship, info: RemotePlayerInfo(peerID: owner, name: state.name),
                    arrival: .populate)
                mirrorIDByAuthorityID[state.id] = localID
                injected.append(localID)
            }
        }

        // Players who dropped out of the authority's system: remove their mirrors.
        var removed: [Int] = []
        for (authorityID, localID) in mirrorIDByAuthorityID where !seenAuthorityIDs.contains(authorityID) {
            world.removeShip(entityID: localID)
            mirrorIDByAuthorityID[authorityID] = nil
            removed.append(localID)
        }
        return (injected, removed)
    }

    /// Snap a mirror ship to its latest networked state. Position/velocity/angle are
    /// set directly; between snapshots the engine coasts the ship on that velocity
    /// (empty intent, no brain) — simple dead-reckoning until the next snapshot.
    private func updateMirror(_ ship: Ship, from state: ShipNetState) {
        ship.position = Vec2(state.x, state.y)
        ship.velocity = Vec2(state.vx, state.vy)
        ship.angle = state.angle
        ship.shield = state.shield
        ship.armor = state.armor
    }

    /// Default mirror hull for headless use: generous stats so the dead-reckoning
    /// speed clamp is inert (we set velocity from the wire). The app overrides this
    /// to build a properly-sized/sprited hull from the player's `shipTypeHint`.
    public static func defaultMirror(_ state: ShipNetState) -> Ship {
        let stats = ShipStats(maxSpeed: 1_000_000, acceleration: 0, turnRate: 0)
        let ship = Ship(name: state.name, stats: stats,
                        position: Vec2(state.x, state.y), angle: state.angle)
        ship.velocity = Vec2(state.vx, state.vy)
        ship.shield = state.shield
        ship.armor = state.armor
        return ship
    }
}
