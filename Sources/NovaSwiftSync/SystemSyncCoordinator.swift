import Foundation
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
    /// Ships dropped from received snapshots as impossible (finite/range/hull checks): the driver reports a peer whose
    /// snapshots keep losing entries.
    public private(set) var rejectedEntries = 0
    /// `SessionRules.deathReal`: when false a snapshot can never put our own armor below 1 (death isn't real in this game).
    public var deathReal = true

    /// Authority side: the freshest input each client has sent, plus the highest
    /// `seq` seen from it so stale/out-of-order unreliable frames are dropped.
    private var latestInput: [String: NetIntent] = [:]
    private var highestSeq: [String: UInt32] = [:]
    /// Authority side: each client's newest reported pose, applied once to its ship on the next `applyInputs` (between
    /// frames the ship simulates from that client's intent).
    private var pendingPose: [String: ShipPose] = [:]
    /// Authority side: client playerID → local entity id of the mirror ship we
    /// inject for that co-located client and simulate from its inputs.
    private var clientShipID: [String: Int] = [:]
    /// Monotonic clock (seconds) for input staleness and loadout refresh. Tests replace it.
    public var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }

    /// Authority side: when each client's newest accepted input arrived (`clock()` time).
    private var lastInputAt: [String: Double] = [:]
    /// A client that sent nothing newer for this long is treated as releasing every control (coast, no fire) instead of
    /// replaying its last held keys forever.
    public static let staleInputSeconds = 0.5
    /// Authority side: each client's latest combat loadout, applied to its simulated copy. `loadoutDirty` marks one
    /// that arrived since the copy was last configured.
    private var pendingLoadout: [String: ShipLoadoutNet] = [:]
    private var loadoutDirty: Set<String> = []
    private var appliedLoadoutKey: [String: [Double]] = [:]
    /// Highest loadout `rev` applied per client, echoed in its snapshots (`ackLoadoutRev`).
    private var ackedLoadoutRev: [String: UInt32] = [:]
    /// A hull we failed to rebuild a copy into (type unknown to the game data), so we don't retry every frame.
    private var typeRebuildFailed: [String: Int] = [:]
    /// Each client's reported life generation (`InputFrame.lifeID`).
    private var clientLife: [String: UInt32] = [:]
    /// Clients whose simulated copy was destroyed and who have not reported a new life yet: no re-injection (that
    /// instant full-health respawn is what hid the death), and their snapshot entry stays `destroyed`.
    private struct DeathMark { var life: UInt32?; var at: Double; var lastType: Int; var name: String }
    private var deathPending: [String: DeathMark] = [:]
    /// Clients that told us they are landed: no ship in the world or snapshot until they launch.
    private var landedClients: Set<String> = []
    /// Kills credited to a client, resent in each of its snapshots until it acks them.
    private var pendingCredits: [String: [KillCreditNet]] = [:]
    private var creditSeq: [String: UInt32] = [:]
    private static let maxPendingCredits = 64

    // Client side.
    /// Our life generation: bumped whenever our ship starts over (respawn, world rebuild). Never reset to 0.
    private var lifeID: UInt32 = 1
    private var wasPlayerAlive = true
    private var loadoutRev: UInt32 = 0
    private var lastLoadoutKey: [Double]?
    private var lastLoadoutSentAt = -Double.infinity
    private var forceLoadout = true
    private var launchPending = false
    private var holdingHealth = false
    private var holdRev: UInt32?
    /// Seconds between loadout refreshes when nothing changed (covers a dropped unreliable frame / a new authority).
    public static let loadoutRefreshSeconds = 2.0
    /// The app/driver sets this while the local player is landed: snapshots must not touch our (just repaired) health.
    public var suspendHealthAdoption = false
    private var lastCreditSeq: UInt32 = 0
    private var pendingKillCredits: [KillCreditNet] = []

    public init(localPlayerID: String) {
        self.localPlayerID = localPlayerID
    }

    private func clearAuthorityState() {
        latestInput.removeAll()
        highestSeq.removeAll()
        pendingPose.removeAll()
        clientShipID.removeAll()
        lastInputAt.removeAll()
        pendingLoadout.removeAll()
        loadoutDirty.removeAll()
        appliedLoadoutKey.removeAll()
        ackedLoadoutRev.removeAll()
        typeRebuildFailed.removeAll()
        clientLife.removeAll()
        deathPending.removeAll()
        landedClients.removeAll()
        pendingCredits.removeAll()
        creditSeq.removeAll()
    }

    private func clearClientState() {
        pendingEffects.removeAll()
        pendingKillCredits.removeAll()
        lastCreditSeq = 0
        forceLoadout = true
        lastLoadoutKey = nil
        holdingHealth = false
        holdRev = nil
        launchPending = false
    }

    /// Drop all per-system state. Call on a local system change or role change —
    /// the old `World`'s entity ids and the old authority's ids no longer apply.
    public func reset() {
        playerMirrorID.removeAll()
        npcMirrorIDByAuthorityID.removeAll()
        clearAuthorityState()
        clearClientState()
        lifeID &+= 1           // a fresh world is a fresh life: lets an authority re-create a destroyed copy
        wasPlayerAlive = true
    }

    /// Drop only the **NPC** mirrors + NPC-side state, keeping player mirrors. Used
    /// on an authority handoff (same system, new host): NPC entity ids are the old
    /// authority's and no longer valid, but players are keyed by stable id so their
    /// ships carry through the switch without blinking.
    public func resetForAuthorityChange() {
        npcMirrorIDByAuthorityID.removeAll()
        clearAuthorityState()
        pendingEffects.removeAll()
        pendingKillCredits.removeAll()
        lastCreditSeq = 0
        forceLoadout = true     // the new authority has never seen our loadout
        lastLoadoutKey = nil
    }

    /// The local player just launched from a landing (called by the driver on the landed -> flying edge). The next input
    /// carries a fresh loadout, and snapshots may not touch our health until the authority confirms it built our copy
    /// from it - otherwise the pre-launch copy's health would undo the repair done on landing.
    public func beginLaunchHold() {
        launchPending = true
        holdingHealth = true
        holdRev = nil
        forceLoadout = true
    }

    /// The hull the authority should simulate for `client`: its reported loadout's, nil until one arrived.
    public func desiredShipType(for client: String) -> Int? {
        guard let t = pendingLoadout[client]?.shipTypeID, t >= 0 else { return nil }
        return t
    }

    /// Replay one-shot effects (explosions) from applied snapshots into the world,
    /// then clear them. Call **after** `world.step` (which clears the frame's
    /// events) and before the scene drains — so a client sees the authority's booms.
    public func flushEffects(into world: World) {
        if !pendingEffects.isEmpty {
            for e in pendingEffects {
                world.emitVisualExplosion(at: Vec2(e.x, e.y), radius: e.radius, boomID: e.boomID)
            }
            pendingEffects.removeAll(keepingCapacity: true)
        }
        // Kills the authority credited to us: replay as the engine's own player-kill bookkeeping (rating, legal
        // record, "destroy" mission goal), after the step like the effects above.
        if !pendingKillCredits.isEmpty {
            for c in pendingKillCredits {
                world.applyNetworkKillCredit(government: c.government, shipStrength: max(1, min(c.strength, 100_000)),
                                             missionID: c.missionID, disabled: c.disabled)
            }
            pendingKillCredits.removeAll(keepingCapacity: true)
        }
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
                            makeShip: (String, String) -> Ship = SystemSyncCoordinator.defaultClientShip,
                            typeOf: (String) -> Int? = { _ in nil })
        -> (injected: [Int], removed: [Int])
    {
        var present = Set<String>()
        var injected: [Int] = []
        var removed: [Int] = []
        noteDeaths(in: world)
        for client in clients {
            let id = client.id
            present.insert(id)
            // Landed: no ghost ship (in the world or the snapshot) until the client launches.
            if landedClients.contains(id) {
                if let localID = clientShipID[id] {
                    world.removeShip(entityID: localID)
                    clientShipID[id] = nil
                    removed.append(localID)
                }
                continue
            }
            // Destroyed: stay dead until the client reports a new life (or, for a build that doesn't report one, a
            // short cooldown) instead of re-injecting a fresh full-health copy the next frame.
            if let mark = deathPending[id] {
                let cleared: Bool
                if mark.life != nil || clientLife[id] != nil { cleared = clientLife[id] != mark.life }
                else { cleared = clock() - mark.at > 3 }
                guard cleared else {
                    if let localID = clientShipID[id], world.ship(id: localID) == nil { clientShipID[id] = nil }
                    continue
                }
                deathPending[id] = nil
            }
            let wanted = desiredShipType(for: id) ?? typeOf(id)
            if let localID = clientShipID[id], let existing = world.ship(id: localID) {
                // A wreck plays out its death sequence (noteDeaths marked it); a living copy of the wrong hull (the
                // client bought a ship) is rebuilt in place, keeping its pose.
                guard existing.isAlive, let wanted, wanted >= 0, existing.shipTypeID != wanted,
                      typeRebuildFailed[id] != wanted else { continue }
                let fresh = makeShip(id, client.name)
                guard fresh.shipTypeID == wanted else { typeRebuildFailed[id] = wanted; continue }
                fresh.position = existing.position
                fresh.velocity = existing.velocity
                fresh.angle = existing.angle
                world.removeShip(entityID: localID)
                removed.append(localID)
                let newID = world.spawnRemotePlayer(
                    fresh, info: RemotePlayerInfo(peerID: id, name: client.name), arrival: .populate)
                clientShipID[id] = newID
                injected.append(newID)
                configureCopy(fresh, for: id, world: world, fresh: false)
                continue
            }
            let ship = makeShip(id, client.name)
            let localID = world.spawnRemotePlayer(
                ship, info: RemotePlayerInfo(peerID: id, name: client.name),
                arrival: .populate)
            clientShipID[id] = localID
            injected.append(localID)
            configureCopy(ship, for: id, world: world, fresh: true)
        }
        for (clientID, localID) in clientShipID where !present.contains(clientID) {
            world.removeShip(entityID: localID)
            clientShipID[clientID] = nil
            removed.append(localID)
        }
        let known = Set(lastInputAt.keys).union(pendingLoadout.keys).union(deathPending.keys)
            .union(pendingCredits.keys).union(landedClients).union(latestInput.keys).union(pendingPose.keys)
        for clientID in known where !present.contains(clientID) {
            latestInput[clientID] = nil
            highestSeq[clientID] = nil
            pendingPose[clientID] = nil
            lastInputAt[clientID] = nil
            pendingLoadout[clientID] = nil
            loadoutDirty.remove(clientID)
            appliedLoadoutKey[clientID] = nil
            ackedLoadoutRev[clientID] = nil
            typeRebuildFailed[clientID] = nil
            clientLife[clientID] = nil
            deathPending[clientID] = nil
            landedClients.remove(clientID)
            pendingCredits[clientID] = nil
            creditSeq[clientID] = nil
        }
        return (injected, removed)
    }

    /// Mark clients whose simulated copy just died (while the wreck is still in the world, so it can't be missed).
    private func noteDeaths(in world: World) {
        for (client, localID) in clientShipID where deathPending[client] == nil {
            if let ship = world.ship(id: localID), !ship.isAlive {
                deathPending[client] = DeathMark(life: clientLife[client], at: clock(), lastType: ship.shipTypeID,
                                                 name: ship.remotePlayer?.name ?? client)
            }
        }
    }

    /// Make a client's copy match its reported loadout: health maxima and regen (the client owns those), the weapon
    /// set, and - only for a freshly created copy - the starting health the client had.
    private func configureCopy(_ ship: Ship, for client: String, world: World, fresh: Bool) {
        guard let l = pendingLoadout[client] else { return }
        loadoutDirty.remove(client)
        ship.maxShield = l.maxShield
        ship.maxArmor = l.maxArmor
        ship.shieldRechargePerSec = l.shieldRegenPerSec
        ship.armorRechargePerSec = l.armorRegenPerSec
        if fresh {
            ship.shield = min(max(0, l.shield ?? l.maxShield), l.maxShield)
            ship.armor = min(max(1, l.armor ?? l.maxArmor), l.maxArmor)
        } else {
            ship.shield = min(ship.shield, l.maxShield)
            ship.armor = min(ship.armor, l.maxArmor)
        }
        // Weapons: rebuild the mounts only when the fitted set changed (rebuilding resets cooldowns); otherwise just
        // follow the client's ammo count.
        let have = ship.weapons.flatMap { [Double($0.spec.id), Double($0.count)] }
        let want = l.weapons.flatMap { [Double($0.id), Double($0.count)] }
        if have != want, let galaxy = world.galaxy {
            ship.weapons = l.weapons.compactMap { w in
                guard let spec = galaxy.weaponSpec(w.id) else { return nil }
                return WeaponMount(spec: spec, ammo: spec.ammoPerShot > 0 ? max(0, w.ammo) : -1,
                                   count: max(1, min(w.count, 12)))
            }
        } else if have == want {
            for (mount, w) in zip(ship.weapons, l.weapons) where mount.ammo >= 0 && w.ammo >= 0 { mount.ammo = w.ammo }
        }
        appliedLoadoutKey[client] = l.stableKey
        if let rev = l.rev { ackedLoadoutRev[client] = rev }
    }

    /// Record a client's input (wire `NetSession.onInput` to this). Keeps only the
    /// freshest frame per client by `seq`, so a late/duplicate unreliable packet
    /// can't rewind a client's control.
    public func receiveInput(_ frame: InputFrame, from client: String) {
        if let seen = highestSeq[client], frame.seq <= seen { return }
        highestSeq[client] = frame.seq
        latestInput[client] = frame.intent
        lastInputAt[client] = clock()
        if let pose = frame.pose, NetValidation.valid(pose) { pendingPose[client] = pose }
        if let life = frame.lifeID { clientLife[client] = life }
        if frame.landed == true { landedClients.insert(client) } else { landedClients.remove(client) }
        if let l = frame.loadout, NetValidation.valid(l) {
            pendingLoadout[client] = l
            loadoutDirty.insert(client)
        }
        if let ack = frame.ackCreditSeq, var list = pendingCredits[client] {
            list.removeAll { $0.seq <= ack }
            pendingCredits[client] = list
        }
    }

    /// Publish each client's freshest input into `world.remoteIntents`, keyed by the
    /// mirror ship whose `remotePlayer.peerID` is that client, and move the ship to the
    /// pose the client last reported. Call **before** `world.step`. A client with no ship
    /// yet (not injected) is skipped; a ship with no fresh input keeps coasting (handled
    /// in the engine as an empty intent).
    ///
    /// The client owns its own movement: replaying only its relative turn/thrust keys
    /// from a hull we spawned at a guessed heading keeps that heading error forever (the
    /// friend's ship shows rotated, and pulling the client toward our copy bends its
    /// thrust and stops its jump brake from settling).
    public func applyInputs(to world: World) {
        guard !latestInput.isEmpty || !pendingPose.isEmpty || !loadoutDirty.isEmpty else { return }
        let now = clock()
        for ship in world.remotePlayerShips {
            guard let peer = ship.remotePlayer?.peerID else { continue }
            if let pose = pendingPose.removeValue(forKey: peer) {
                ship.position = Vec2(pose.x, pose.y)
                ship.velocity = Vec2(pose.vx, pose.vy)
                ship.angle = pose.angle
            }
            if loadoutDirty.contains(peer), ship.isAlive { configureCopy(ship, for: peer, world: world, fresh: false) }
            if let intent = latestInput[peer] {
                if let at = lastInputAt[peer], now - at > Self.staleInputSeconds {
                    world.remoteIntents[ship.entityID] = nil     // silent client: coast, no fire
                } else {
                    world.remoteIntents[ship.entityID] = intent.engineIntent
                }
            }
        }
    }

    /// Build the snapshot to send to clients. Call **after** `world.step`. Recipient-agnostic; use
    /// `snapshot(for:from:)` to add the parts that are per client.
    public func snapshot(of world: World, tick: UInt32, ackInputSeq: UInt32 = 0) -> WorldSnapshot {
        noteDeaths(in: world)
        var snap = WorldSnapshot.build(from: world, localPlayerID: localPlayerID,
                                       tick: tick, ackInputSeq: ackInputSeq)
        snap.clientPosesAuthoritative = true
        // A client whose copy is gone but whose death is still pending keeps a `destroyed` entry (armor 0), so the
        // client learns it died instead of the entry just vanishing. Entries are tagged with the client's life.
        for i in snap.ships.indices where snap.ships[i].destroyed == true {
            if let owner = snap.ships[i].playerID { snap.ships[i].life = deathPending[owner]?.life }
        }
        for (client, mark) in deathPending where !snap.ships.contains(where: { $0.playerID == client }) {
            snap.ships.append(ShipNetState(
                id: -1, playerID: client, shipTypeID: mark.lastType, name: mark.name,
                x: 0, y: 0, vx: 0, vy: 0, angle: 0, shield: 0, armor: 0, control: .remote,
                destroyed: true, life: mark.life))
        }
        // Kills a client's copy landed since the last frame, queued with a per-client sequence.
        for credit in world.drainRemoteKillCredits() where clientShipID[credit.peerID] != nil {
            let seq = (creditSeq[credit.peerID] ?? 0) &+ 1
            creditSeq[credit.peerID] = seq
            var list = pendingCredits[credit.peerID] ?? []
            list.append(KillCreditNet(seq: seq, shipTypeID: credit.shipTypeID, government: credit.government,
                                      missionID: credit.missionID, strength: credit.strength, disabled: credit.disabled))
            if list.count > Self.maxPendingCredits { list.removeFirst(list.count - Self.maxPendingCredits) }
            pendingCredits[credit.peerID] = list
        }
        return snap
    }

    /// `base` addressed to one client: its own kill credits, the loadout revision the authority has applied for it, and
    /// the newest input seq received from it.
    public func snapshot(for client: String, from base: WorldSnapshot) -> WorldSnapshot {
        var s = base
        s.ackInputSeq = highestSeq[client] ?? 0
        s.ackLoadoutRev = ackedLoadoutRev[client]
        if let c = pendingCredits[client], !c.isEmpty { s.credits = c }
        return s
    }

    // MARK: - Client side

    /// This frame's input to send to the authority (from the local player's intent),
    /// carrying our ship's predicted pose, and its combat loadout when that changed (plus a slow refresh).
    /// `landed` flags us as docked so the authority drops our ship from the shared world.
    public func input(from intent: ControlIntent, tick: UInt32, seq: UInt32, ship: Ship? = nil,
                      landed: Bool = false) -> InputFrame {
        let pose = ship.map {
            ShipPose(x: $0.position.x, y: $0.position.y, vx: $0.velocity.x, vy: $0.velocity.y, angle: wireAngle($0.angle))
        }
        var loadout: ShipLoadoutNet?
        if let ship, !landed {
            // Coming back to life (respawn, eject into a pod) starts a new life generation.
            let alive = ship.isAlive
            if alive && !wasPlayerAlive { lifeID &+= 1; forceLoadout = true }
            wasPlayerAlive = alive
            if alive { loadout = nextLoadout(for: ship) }
        }
        return InputFrame(tick: tick, seq: seq, intent: NetIntent(intent), pose: pose, loadout: loadout,
                          landed: landed ? true : nil, lifeID: lifeID,
                          ackCreditSeq: lastCreditSeq > 0 ? lastCreditSeq : nil)
    }

    private func nextLoadout(for ship: Ship) -> ShipLoadoutNet? {
        var l = ShipLoadoutNet(
            shipTypeID: ship.shipTypeID, maxShield: ship.maxShield, maxArmor: ship.maxArmor,
            shieldRegenPerSec: ship.shieldRechargePerSec, armorRegenPerSec: ship.armorRechargePerSec,
            weapons: ship.weapons.compactMap { m in
                m.spec.id >= 0 ? WeaponMountNet(id: m.spec.id, count: max(1, min(m.count, 100)),
                                                ammo: max(-1, min(m.ammo, 1_000_000))) : nil
            },
            shield: max(0, ship.shield), armor: max(0, ship.armor))
        let now = clock()
        let key = l.stableKey
        let changed = key != lastLoadoutKey
        guard changed || forceLoadout || now - lastLoadoutSentAt >= Self.loadoutRefreshSeconds else { return nil }
        if changed || forceLoadout { loadoutRev &+= 1 }
        l.rev = loadoutRev
        lastLoadoutKey = key
        lastLoadoutSentAt = now
        forceLoadout = false
        if launchPending { holdRev = loadoutRev; launchPending = false }
        return l
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
    public func apply(_ rawSnapshot: WorldSnapshot, to world: World, authorityPeer: String,
                      shipTypeKnown: ((Int) -> Bool)? = nil,
                      makeMirror: (ShipNetState) -> Ship = SystemSyncCoordinator.defaultMirror,
                      makeNPCMirror: (ShipNetState) -> Ship = SystemSyncCoordinator.defaultMirror)
        -> (injected: [Int], removed: [Int])
    {
        // Never trust the wire: drop non-finite / out-of-range ships, cap list sizes, and (when the game data is
        // known) ships whose hull doesn't exist. A bad entry is simply absent, as if the ship had left.
        var snapshot = NetValidation.sanitized(rawSnapshot)
        if let shipTypeKnown {
            snapshot.ships = snapshot.ships.filter { $0.shipTypeID < 0 || shipTypeKnown($0.shipTypeID) }
        }
        rejectedEntries += (rawSnapshot.ships.count - snapshot.ships.count)
        var seenPlayerIDs = Set<String>()
        var seenNPCIDs = Set<Int>()
        var injected: [Int] = []
        var ownAuthorityID: Int?   // our ship's entity id in the authority's world

        for state in snapshot.ships {
            if state.playerID == localPlayerID {
                // Our own ship: predicted locally, but health is authoritative.
                ownAuthorityID = state.id
                if state.destroyed == true {
                    // The authority destroyed our ship: run the normal local death (armor <= 0). A notice from an
                    // earlier life, or while we're landed / just launched, must not kill the current one; when death
                    // isn't real it can't kill us at all.
                    if deathReal, state.life == nil || state.life == lifeID, !holdingHealth,
                       !suspendHealthAdoption, world.player.isAlive {
                        world.player.shield = 0
                        world.player.armor = 0
                    }
                    continue
                }
                // After a launch (or while landed) the authority's copy of us predates the repair: don't adopt its
                // health until it confirms it rebuilt the copy from our fresh loadout.
                var adoptHealth = !suspendHealthAdoption
                if holdingHealth {
                    adoptHealth = false
                    if let need = holdRev {
                        if let ack = snapshot.ackLoadoutRev {
                            if ack >= need { holdingHealth = false; holdRev = nil; adoptHealth = !suspendHealthAdoption }
                        } else {
                            holdingHealth = false; holdRev = nil     // an authority that doesn't ack: resume next time
                        }
                    }
                }
                // Health is authoritative for damage, but a snapshot can't heal past our own maxima, and
                // when death isn't real it can't kill us.
                if adoptHealth {
                    world.player.shield = max(0, min(state.shield, world.player.maxShield))
                    world.player.armor = max(deathReal ? 0 : 1, min(state.armor, world.player.maxArmor))
                }
                // An authority that adopts our sent pose echoes it back a round trip late: converging toward
                // that would drag us backwards. Only older, input-replaying authorities need the correction.
                if snapshot.clientPosesAuthoritative != true {
                    reconcileOwnShip(world.player, authoritative: state)
                }
                continue
            }
            if let owner = state.playerID {
                // Another player — keyed by stable playerID so it survives a handoff. A destroyed one is simply
                // absent (its mirror is removed below).
                if state.destroyed == true { continue }
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
        // Kills the authority credits to us. Each is resent until we ack it (the channel is unreliable), so apply
        // each sequence number once.
        if let credits = snapshot.credits {
            for c in credits.sorted(by: { $0.seq < $1.seq }) where c.seq > lastCreditSeq {
                pendingKillCredits.append(c)
                lastCreditSeq = c.seq
            }
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

    /// Small per-snapshot blend factor for the own-ship convergence correction.
    private static let ownShipBlendFactor = 0.15
    /// Divergence (world units) beyond which we snap instead of blending — a gap
    /// this big means the two sims have genuinely desynced (e.g. differing
    /// per-device `gameSpeed`, a dropped input) rather than ordinary float drift,
    /// so smoothing it out over many frames would just look like sliding.
    private static let ownShipSnapDistance = 400.0
    private static let ownShipMaxCorrection = 60_000.0

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
        // An authority can't fling us across the galaxy: a "correction" far beyond any star system is ignored.
        guard error <= Self.ownShipMaxCorrection else { rejectedEntries += 1; return }
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
