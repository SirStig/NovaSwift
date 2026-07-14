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
    /// every remote **player** we've injected into the local `World`. Reset when the
    /// local player changes system (a fresh `World` invalidates all mirrors).
    private var mirrorIDByAuthorityID: [Int: Int] = [:]
    /// Client side: authority entity id → our local mirror id, for every **NPC**
    /// mirrored from the authority's snapshot (shared world / co-op combat).
    private var npcMirrorIDByAuthorityID: [Int: Int] = [:]

    /// Authority side: the freshest input each client has sent, plus the highest
    /// `seq` seen from it so stale/out-of-order unreliable frames are dropped.
    private var latestInput: [String: NetIntent] = [:]
    private var highestSeq: [String: UInt32] = [:]
    /// Authority side: client playerID → local entity id of the mirror ship we
    /// inject for that co-located client and simulate from its inputs.
    private var clientShipID: [String: Int] = [:]

    public init(localPlayerID: String) {
        self.localPlayerID = localPlayerID
    }

    /// Drop all per-system state. Call on a local system change or role change —
    /// the old `World`'s entity ids and the old authority's ids no longer apply.
    public func reset() {
        mirrorIDByAuthorityID.removeAll()
        npcMirrorIDByAuthorityID.removeAll()
        latestInput.removeAll()
        highestSeq.removeAll()
        clientShipID.removeAll()
    }

    // MARK: - Authority side

    /// Ensure the authority's `World` holds a driven mirror ship for every
    /// co-located client, and remove mirrors for clients who left. The population
    /// comes from **presence** (not a snapshot) — these ships are what
    /// `applyInputs` then steers from each client's streamed input, and what the
    /// broadcast snapshot reports back so everyone sees them. Call when the
    /// co-located set changes (and it's cheap to call every frame).
    ///
    /// `makeShip(clientID, name)` builds the hull — the app sizes/sprites it and
    /// positions it near the authority's player; the default is a headless combat
    /// hull at the origin.
    @discardableResult
    public func syncClients(_ clients: [(id: String, name: String)], into world: World,
                            makeShip: (String, String) -> Ship = SystemSyncCoordinator.defaultClientShip)
        -> (injected: [Int], removed: [Int])
    {
        var present = Set<String>()
        var injected: [Int] = []
        for client in clients {
            present.insert(client.id)
            if let localID = clientShipID[client.id], world.ship(id: localID) != nil { continue }
            let ship = makeShip(client.id, client.name)
            let localID = world.spawnRemotePlayer(
                ship, info: RemotePlayerInfo(peerID: client.id, name: client.name),
                arrival: .populate)
            clientShipID[client.id] = localID
            injected.append(localID)
        }
        var removed: [Int] = []
        for (clientID, localID) in clientShipID where !present.contains(clientID) {
            world.removeShip(entityID: localID)
            clientShipID[clientID] = nil
            latestInput[clientID] = nil
            highestSeq[clientID] = nil
            removed.append(localID)
        }
        return (injected, removed)
    }

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

    /// Reconcile a received snapshot into the local `World` — the shared co-op
    /// world. For each ship the authority reports:
    /// - **our own ship** (`playerID == localPlayerID`): we keep predicting its
    ///   position locally but adopt the authority's **health** (shield/armor), so
    ///   damage the authority's sim deals to us actually lands;
    /// - **another player**: inject/update a `remotePlayer` mirror (nameplate/blip);
    /// - **an NPC** (`playerID == nil`): inject/update a `networkMirror` mirror, so
    ///   both players see and fight the same ambient/AI ships.
    /// Mirrors for ships that dropped out of the snapshot are removed.
    ///
    /// `makeMirror` builds a player-mirror hull, `makeNPCMirror` an NPC-mirror hull,
    /// both from the wire state (the app sprites them from `state.shipTypeID`);
    /// defaults are provided for headless use/tests. The client's own spawner must
    /// be paused (`World.spawningPaused`) so it doesn't fight these injected NPCs.
    @discardableResult
    public func apply(_ snapshot: WorldSnapshot, to world: World, authorityPeer: String,
                      makeMirror: (ShipNetState) -> Ship = SystemSyncCoordinator.defaultMirror,
                      makeNPCMirror: (ShipNetState) -> Ship = SystemSyncCoordinator.defaultMirror)
        -> (injected: [Int], removed: [Int])
    {
        var seenPlayerIDs = Set<Int>()
        var seenNPCIDs = Set<Int>()
        var injected: [Int] = []
        var ownAuthorityID: Int?   // our ship's entity id in the authority's world

        for state in snapshot.ships {
            if state.playerID == localPlayerID {
                // Our own ship: predicted locally, but health is authoritative.
                ownAuthorityID = state.id
                world.player.shield = state.shield
                world.player.armor = state.armor
                continue
            }
            if let owner = state.playerID {
                // Another player.
                seenPlayerIDs.insert(state.id)
                if let localID = mirrorIDByAuthorityID[state.id], let ship = world.ship(id: localID) {
                    updateMirror(ship, from: state)
                } else {
                    let localID = world.spawnRemotePlayer(
                        makeMirror(state), info: RemotePlayerInfo(peerID: owner, name: state.name),
                        arrival: .populate)
                    mirrorIDByAuthorityID[state.id] = localID
                    injected.append(localID)
                }
            } else {
                // An NPC in the authority's world.
                seenNPCIDs.insert(state.id)
                if let localID = npcMirrorIDByAuthorityID[state.id], let ship = world.ship(id: localID) {
                    updateMirror(ship, from: state)
                } else {
                    let localID = world.spawnNetworkMirror(makeNPCMirror(state), arrival: .populate)
                    npcMirrorIDByAuthorityID[state.id] = localID
                    injected.append(localID)
                }
            }
        }

        // Anyone/anything that dropped out of the snapshot: remove its mirror.
        var removed: [Int] = []
        for (authorityID, localID) in mirrorIDByAuthorityID where !seenPlayerIDs.contains(authorityID) {
            world.removeShip(entityID: localID)
            mirrorIDByAuthorityID[authorityID] = nil
            removed.append(localID)
        }
        for (authorityID, localID) in npcMirrorIDByAuthorityID where !seenNPCIDs.contains(authorityID) {
            world.removeShip(entityID: localID)
            npcMirrorIDByAuthorityID[authorityID] = nil
            removed.append(localID)
        }

        // Re-seed the authority's in-flight shots as visual echoes (skip our own —
        // we already fired those locally). Replaced wholesale each snapshot; they
        // dead-reckon on their velocity in between.
        world.clearVisualProjectiles()
        for shot in snapshot.shots where shot.ownerID != ownAuthorityID {
            world.spawnVisualProjectile(
                position: Vec2(shot.x, shot.y), velocity: Vec2(shot.vx, shot.vy),
                facing: shot.facing, life: shot.life, ownerID: shot.ownerID,
                weaponID: shot.weaponID, graphicSpinID: shot.graphicSpinID,
                spinShots: shot.spinShots, translucentShots: shot.translucentShots)
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

    /// Default authority-side hull for a co-located client (headless use): a real
    /// combat hull so it responds to the client's inputs under the authority's
    /// simulation. The app overrides this to build the friend's actual hull from
    /// their `shipTypeHint` and place it beside the authority's player.
    public static func defaultClientShip(_ id: String, _ name: String) -> Ship {
        Ship(name: name, stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: .pi))
    }
}
