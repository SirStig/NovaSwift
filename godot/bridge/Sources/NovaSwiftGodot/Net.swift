// Plain-Swift multiplayer glue for the bridge (`// MARK: Multiplayer` in NovaWorld.swift).
//
// `@Godot` registers only what is declared inside the class body, so the callables
// (net_begin, net_receive, ...) live in NovaWorld and delegate to `NetBridge` here.
//
// No game logic: this runs the SAME `NetSession` + `SystemSyncDriver` the Apple app
// runs (Sources/NovaSwiftNet, Sources/NovaSwiftSync). GDScript owns the sockets
// (ENet) and pumps bytes through an `ExternalTransport`. See docs/MULTIPLAYER.md ->
// "Godot (LAN / IP / dedicated server)".

import Foundation
import NovaSwiftEngine
import NovaSwiftKit
import NovaSwiftNet
import NovaSwiftSync

final class NetBridge {
    let transport: ExternalTransport
    let session: NetSession
    let driver: SystemSyncDriver
    let isHost: Bool
    let displayName: String
    /// The guest's host: Godot's multiplayer server peer id.
    static let serverPeerID = 1

    private(set) var closed = false
    private(set) var localManifest: PluginManifest
    private var events: [[String: Any]] = []
    private var errors: [String] = []
    private var knownPresence: [String: PlayerPresence] = [:]
    private var announcedSystem: Int?
    private var announcedShip: Int?
    private var worldToken: ObjectIdentifier?
    private var reportedMismatch: Set<String> = []

    init(localPeerID: Int, displayName: String, isHost: Bool, rules: SessionRules, manifest: PluginManifest) {
        transport = ExternalTransport(localPeerID: localPeerID)
        session = NetSession(transport: transport, rules: rules)
        driver = SystemSyncDriver(session: session, localSystemID: -1)
        self.isHost = isHost
        self.displayName = displayName
        localManifest = manifest
        session.providesRules = isHost
        session.localPluginManifest = manifest
        wire()
    }

    // MARK: Wiring

    private func wire() {
        session.onChat = { [weak self] m in
            guard let self else { return }
            self.push(["type": "chat", "id": Self.id(m.playerID), "name": m.senderName, "text": m.text,
                       "local": m.playerID == self.session.localPlayerID])
        }
        session.onPresenceChanged = { [weak self] _ in self?.diffPresence() }
        session.onRulesChanged = { [weak self] r in
            self?.push(["type": "rules_changed", "rules": Self.rulesObject(r)])
        }
        session.onInput = { [weak self] f, peer in self?.driver.receiveInput(f, from: peer) }
        session.onSnapshot = { [weak self] s, peer in self?.driver.receiveSnapshot(s, from: peer) }
        session.onNCB = { [weak self] bits, peer in
            self?.push(["type": "ncb_bits", "id": Self.id(peer), "bits": bits])
        }
        session.onKicked = { [weak self] in
            self?.push(["type": "kicked"])
            self?.close()
        }
        session.onTrade = { [weak self] signal, peer in self?.handleTrade(signal, from: peer) }
        session.onPluginManifest = { [weak self] m, peer in self?.handleManifest(m, from: peer) }
        session.onDecodeFailure = { [weak self] peer in
            guard let self, self.reportedMismatch.insert("v" + peer).inserted else { return }
            self.push(["type": "version_mismatch", "id": Self.id(peer),
                       "message": "Peer \(peer) sent data this build can't decode - different NovaSwift version."])
        }
    }

    private func handleTrade(_ signal: TradeSignal, from peer: String) {
        switch signal {
        case .invite(let name):
            // No trade UI in the Godot frontend yet: surface it and decline politely.
            push(["type": "trade", "kind": "invite", "id": Self.id(peer), "name": name])
            session.sendTrade(.decline, to: peer)
        case .decline: push(["type": "trade", "kind": "decline", "id": Self.id(peer)])
        case .cancel: push(["type": "trade", "kind": "cancel", "id": Self.id(peer)])
        case .accept(let a): push(["type": "trade", "kind": "accept", "id": Self.id(peer), "accepted": a])
        case .offer(let o):
            push(["type": "trade", "kind": "offer", "id": Self.id(peer), "credits": o.credits,
                  "cargo": o.cargo.map { ["id": $0.key, "tons": $0.value] },
                  "outfits": o.outfits.map { ["id": $0.key, "count": $0.value] }])
        }
    }

    /// Same policy as the Apple app: the host drops a joiner whose plug-ins differ; a
    /// guest checks the host (Godot server = peer 1) and leaves if it can't play there.
    private func handleManifest(_ m: PluginManifest, from peer: String) {
        if isHost {
            guard !m.isCompatible(with: localManifest) else { return }
            let mm = m.mismatch(against: localManifest)   // joiner's manifest vs ours
            push(Self.mismatchEvent(mm, peer: peer, asHost: true,
                                    name: session.presence[peer]?.name ?? peer))
            session.kick(peer)
        } else if peer == String(Self.serverPeerID) {
            let mm = localManifest.mismatch(against: m)
            guard !mm.isCompatible else { return }
            push(Self.mismatchEvent(mm, peer: peer, asHost: false, name: "host"))
            close()
        }
    }

    private static func mismatchEvent(_ mm: PluginMismatch, peer: String, asHost: Bool, name: String) -> [String: Any] {
        func rows(_ r: [PluginRequirement]) -> [[String: String]] { r.map { ["id": $0.id, "name": $0.name] } }
        return ["type": "plugin_mismatch", "id": id(peer), "name": name, "as_host": asHost,
                "missing": rows(mm.missing), "extra": rows(mm.extra), "wrong_version": rows(mm.wrongVersion)]
    }

    private func diffPresence() {
        let now = session.presence
        for (pid, p) in now where knownPresence[pid] == nil && pid != session.localPlayerID {
            push(["type": "player_joined", "id": Self.id(pid), "name": p.name])
        }
        for (pid, p) in knownPresence where now[pid] == nil && pid != session.localPlayerID {
            push(["type": "player_left", "id": Self.id(pid), "name": p.name])
        }
        knownPresence = now
    }

    // MARK: Lifecycle

    func close() {
        guard !closed else { return }
        closed = true
        driver.reset()
        transport.disconnect()
    }

    func push(_ e: [String: Any]) {
        events.append(e)
        if events.count > 512 { events.removeFirst(events.count - 512) }
    }

    func note(_ error: String) {
        errors.append(error)
        if errors.count > 32 { errors.removeFirst(errors.count - 32) }
    }

    func drainEvents() -> [[String: Any]] { let e = events; events.removeAll(); return e }

    // MARK: Sim hooks (called from NovaWorld.step)

    /// Once per `step()` call: announce a changed system / hull and re-key mirrors if
    /// the world instance was rebuilt.
    func prepare(world: World, systemID: Int?, shipType: Int?) {
        guard !closed else { return }
        if let systemID, systemID != announcedSystem || shipType != announcedShip {
            announcedSystem = systemID
            announcedShip = shipType
            driver.setLocalSystem(systemID)
            session.updateLocalPresence(name: displayName, systemID: systemID, shipTypeHint: shipType)
        }
        let token = ObjectIdentifier(world)
        if worldToken != token {
            if worldToken != nil { driver.forceResync() }
            worldToken = token
        }
    }

    func preStep(_ world: World) { if !closed { driver.syncPreStep(world: world) } }
    func postStep(_ world: World) { if !closed { driver.syncPostStep(world: world) } }

    // MARK: Pumps

    func outgoing() -> [(to: Int, reliable: Bool, data: [UInt8])] { transport.drainOutgoing() }

    // MARK: JSON

    static func id(_ s: String) -> Int { Int(s) ?? -1 }

    static func rulesObject(_ r: SessionRules) -> [String: Any] {
        ["pvp_damage_real": r.pvpDamageReal, "death_real": r.deathReal, "friendly_fire": r.friendlyFire,
         "allow_pvp": r.allowPvP, "allow_trade": r.allowTrade, "carry_encounter": r.carryEncounter,
         "game_speed_multiplier": r.gameSpeedMultiplier]
    }

    /// Lenient: starts from `base`, accepts `{"preset":"safe"|"full"}` and any subset of
    /// the snake_case (or Swift camelCase) keys of `rulesObject`. nil = unparseable.
    static func parseRules(_ json: String, base: SessionRules) -> SessionRules? {
        let t = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return base }
        guard let d = t.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var r = base
        if let p = o["preset"] as? String { r = (p == "safe") ? .safe : (p == "full" || p == "fullStakes") ? .fullStakes : r }
        func b(_ a: String, _ c: String) -> Bool? { (o[a] as? Bool) ?? (o[c] as? Bool) }
        if let v = b("pvp_damage_real", "pvpDamageReal") { r.pvpDamageReal = v }
        if let v = b("death_real", "deathReal") { r.deathReal = v }
        if let v = b("friendly_fire", "friendlyFire") { r.friendlyFire = v }
        if let v = b("allow_pvp", "allowPvP") { r.allowPvP = v }
        if let v = b("allow_trade", "allowTrade") { r.allowTrade = v }
        if let v = b("carry_encounter", "carryEncounter") { r.carryEncounter = v }
        if let v = (o["game_speed_multiplier"] as? Double) ?? (o["gameSpeedMultiplier"] as? Double) {
            r.gameSpeedMultiplier = v
        }
        return r
    }

    func stateObject(currentSystem: Int?) -> [String: Any] {
        let mine = session.presence[session.localPlayerID]?.currentSystemID
        let authority = driver.currentAuthorityID
        var players: [[String: Any]] = []
        for p in session.presence.values.sorted(by: { Self.id($0.playerID) < Self.id($1.playerID) }) {
            players.append(["id": Self.id(p.playerID), "name": p.name, "system_id": p.currentSystemID,
                            "ship": p.shipTypeHint ?? -1,
                            "in_my_system": mine != nil && p.currentSystemID == mine,
                            "is_authority": authority == p.playerID])
        }
        let errs = errors; errors.removeAll()
        return ["active": !closed, "is_host": isHost, "local_id": Self.id(session.localPlayerID),
                "players": players, "authority_id": authority.map(Self.id) ?? -1,
                "syncing": driver.isSyncingSystem, "rules": Self.rulesObject(session.sessionRules),
                "errors": errs]
    }

    static func inactiveState() -> [String: Any] {
        ["active": false, "is_host": false, "local_id": -1, "players": [], "authority_id": -1,
         "syncing": false, "rules": rulesObject(.safe), "errors": []]
    }

    static func json(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "null" }
        return s
    }

    // MARK: Plug-in manifest

    private static var hashCache: [String: String] = [:]

    /// The enabled plug-ins as a `PluginManifest` (content hashes cached per file stamp).
    static func currentManifest() -> PluginManifest {
        let fm = FileManager.default
        let reqs = PluginRuntime.shared.plugins.filter(\.isEnabled).map { b -> PluginRequirement in
            var stamp = b.id
            for u in b.allFileURLs.sorted(by: { $0.path < $1.path }) {
                let a = try? fm.attributesOfItem(atPath: u.path)
                stamp += "|\(u.path):\((a?[.size] as? Int) ?? 0):\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            }
            let h = hashCache[stamp] ?? { let v = GameLibrary.contentHash(of: b); hashCache[stamp] = v; return v }()
            return PluginRequirement(id: b.id, name: b.name, contentHash: h)
        }
        return PluginManifest(reqs)
    }

    static func manifestJSON(_ m: PluginManifest) -> String {
        json(["plugins": m.plugins.map { ["id": $0.id, "name": $0.name, "contentHash": $0.contentHash] },
              "signature": m.signature, "count": m.count])
    }
}
