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
    /// Keyed by the owning **playerID** (not the authority's entity id) so a mirror
    /// survives an authority handoff — the new authority reports the same players by
    /// id, so their ships update in place instead of blinking out and respawning.
    private var playerMirrorID: [String: Int] = [:]
    /// Client side: authority entity id → our local mirror id, for every **NPC**
    /// mirrored from the authority's snapshot (shared world / co-op combat).
    private var npcMirrorIDByAuthorityID: [Int: Int] = [:]
    /// Client side: one-shot effects (explosions) from applied snapshots, waiting to
    /// be replayed into the world *after* its step (step clears events). Drained by
    /// `flushEffects`.
    private var pendingEffects: [EffectNetState] = []

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
        playerMirrorID.removeAll()
        npcMirrorIDByAuthorityID.removeAll()
        latestInput.removeAll()
        highestSeq.removeAll()
        clientShipID.removeAll()
        pendingEffects.removeAll()
    }

    /// Drop only the **NPC** mirrors + NPC-side state, keeping player mirrors. Used
    /// on an authority handoff (same system, new host): NPC entity ids are the old
    /// authority's and no longer valid, but players are keyed by stable id so their
    /// ships carry through the switch without blinking.
    public func resetForAuthorityChange() {
        npcMirrorIDByAuthorityID.removeAll()
        latestInput.removeAll()
        highestSeq.removeAll()
        clientShipID.removeAll()
        pendingEffects.removeAll()
    }

    /// Replay one-shot effects (explosions) from applied snapshots into the world,
    /// then clear them. Call **after** `world.step` (which clears the frame's
    /// events) and before the scene drains — so a client sees the authority's booms.
    public func flushEffects(into world: World) {
        guard !pendingEffects.isEmpty else { return }
        for e in pendingEffects {
            world.emitVisualExplosion(at: Vec2(e.x, e.y), radius: e.radius, boomID: e.boomID)
        }
        pendingEffects.removeAll(keepingCapacity: true)
    }

    // MARK: - Authority handoff

    /// Promote the world we were mirroring (as a client) into one we now own (as the
    /// new authority) — a **seamless handoff**: nothing is torn down and respawned.
    /// The co-located friends' `remotePlayer` ships become the client ships we drive
    /// from their inputs; the `networkMirror` NPCs are handed back so the app can
    /// re-attach AI brains, keeping the same cast rather than re-rolling it. Call
    /// this instead of `reset()` when transitioning client → authority.
    ///
    /// Returns the NPC ships to promote (the app clears `networkMirror` + attaches a
    /// brain on each).
    @discardableResult
    public func promoteToAuthority(world: World) -> [Ship] {
        // Adopt co-located players as the clients we now simulate.
        clientShipID.removeAll()
        for ship in world.remotePlayerShips {
            if let peer = ship.remotePlayer?.peerID { clientShipID[peer] = ship.entityID }
        }
        // Hand back the NPC mirrors for promotion; drop the client-side maps.
        let npcs = world.npcs.filter { $0.networkMirror }
        playerMirrorID.removeAll()
        npcMirrorIDByAuthorityID.removeAll()
        pendingEffects.removeAll()
        return npcs
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
    ///   damage the authority's sim deals to us actually lands, and blend/snap our
    ///   predicted transform toward the authority's report (`reconcileOwnShip`) so
    ///   the two independent sims can't drift apart unbounded;
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
        var seenPlayerIDs = Set<String>()
        var seenNPCIDs = Set<Int>()
        var injected: [Int] = []
        var ownAuthorityID: Int?   // our ship's entity id in the authority's world

        for state in snapshot.ships {
            if state.playerID == localPlayerID {
                // Our own ship: predicted locally, but health is authoritative.
                ownAuthorityID = state.id
                world.player.shield = state.shield
                world.player.armor = state.armor
                reconcileOwnShip(world.player, authoritative: state)
                continue
            }
            if let owner = state.playerID {
                // Another player — keyed by stable playerID so it survives a handoff.
                seenPlayerIDs.insert(owner)
                if let localID = playerMirrorID[owner], let ship = world.ship(id: localID) {
                    updateMirror(ship, from: state)
                } else {
                    let localID = world.spawnRemotePlayer(
                        makeMirror(state), info: RemotePlayerInfo(peerID: owner, name: state.name),
                        arrival: .populate)
                    playerMirrorID[owner] = localID
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
        for (owner, localID) in playerMirrorID where !seenPlayerIDs.contains(owner) {
            world.removeShip(entityID: localID)
            playerMirrorID[owner] = nil
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

        // Same for beams (also skip our own — the authority welds ours to our
        // predicted ship, but we draw those from our own local beam already).
        world.clearVisualBeams()
        for beam in snapshot.beams where beam.shooterID != ownAuthorityID {
            let color = beam.color.flatMap { c -> (r: Double, g: Double, b: Double)? in
                c.count == 3 ? (c[0], c[1], c[2]) : nil
            }
            let coronaColor = beam.coronaColor.flatMap { c -> (r: Double, g: Double, b: Double)? in
                c.count == 3 ? (c[0], c[1], c[2]) : nil
            }
            world.spawnVisualBeam(shooterID: beam.shooterID, weaponID: beam.weaponID,
                                  from: Vec2(beam.fromX, beam.fromY), to: Vec2(beam.toX, beam.toY),
                                  hit: beam.hit, width: beam.width, color: color,
                                  coronaColor: coronaColor, coronaFalloff: beam.coronaFalloff)
        }

        // Buffer one-shot effects; the app flushes them into the world after its
        // step (events are cleared at the start of `step`, so we can't emit now).
        pendingEffects.append(contentsOf: snapshot.effects)
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

    /// Small per-snapshot blend factor for the own-ship convergence correction.
    private static let ownShipBlendFactor = 0.15
    /// Divergence (world units) beyond which we snap instead of blending — a gap
    /// this big means the two sims have genuinely desynced (e.g. differing
    /// per-device `gameSpeed`, a dropped input) rather than ordinary float drift,
    /// so smoothing it out over many frames would just look like sliding.
    private static let ownShipSnapDistance = 400.0

    /// Correct our own predicted ship toward the authority's report of it. We don't
    /// keep an input-seq history to replay (no true client-side reconciliation
    /// yet — see docs/MULTIPLAYER.md), so this is a convergence correction: each
    /// snapshot nudges position/velocity a fraction of the way toward the
    /// authoritative value. Without this, the two sims run independent, unsynced
    /// physics steps (different `dt` sequences, possibly different per-device
    /// `gameSpeed`) with nothing ever pulling them back together, so any tiny
    /// per-frame difference compounds forever.
    private func reconcileOwnShip(_ ship: Ship, authoritative state: ShipNetState) {
        let authoritativePosition = Vec2(state.x, state.y)
        let authoritativeVelocity = Vec2(state.vx, state.vy)
        let error = (authoritativePosition - ship.position).length
        guard error > 0.01 else { return }
        if error > Self.ownShipSnapDistance {
            ship.position = authoritativePosition
            ship.velocity = authoritativeVelocity
            ship.angle = state.angle
        } else {
            ship.position = ship.position + (authoritativePosition - ship.position) * Self.ownShipBlendFactor
            ship.velocity = ship.velocity + (authoritativeVelocity - ship.velocity) * Self.ownShipBlendFactor
        }
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
