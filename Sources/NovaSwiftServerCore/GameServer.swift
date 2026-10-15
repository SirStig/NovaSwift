import Foundation
import NovaSwiftNet
import NovaSwiftENet

/// The game side of the dedicated server: an ENet host (peer 1) with the handshake gate, a `NetSession` that carries
/// rules, chat and the plug-in manifest, LAN beacons / `NSQ1` status replies, and the moderation the admin panel and
/// console drive. There is no world simulation: players in the same star system sync with each other directly.
public final class GameServer {
    public static let version = ServerVersion.current

    public enum RunState: Equatable {
        case stopped
        case running
        case failed(String)
    }

    public struct Player: Equatable {
        public var id: Int
        public var name: String
        public var ip: String
        public var pingMs: Int
        public var systemID: Int?
        public var joinedAt: Date
    }

    public struct Stats: Equatable {
        public var bytesSent: UInt64 = 0
        public var bytesReceived: UInt64 = 0
        public var outBytesPerSec: Double = 0
        public var inBytesPerSec: Double = 0
        public var peakPlayers = 0
        public var totalJoins = 0
        public var refusals = 0
        public var abuseKicks = 0
    }

    public let store: ConfigStore
    public let log: ServerLog
    public let plugins: PluginManager
    public let audit: AuditLog
    public private(set) var state: RunState = .stopped
    public private(set) var startedAt: Date?
    public private(set) var manifest: PluginManager.Manifest

    /// Everything touching ENet and the session runs on this queue.
    private let queue = DispatchQueue(label: "novaswift.server.core")
    private var host: ENetHostTransport?
    private var session: NetSession?
    private let lan = LANBeaconService()
    private var joinTimes: [Int: Date] = [:]
    private let moderation = ModerationCenter()
    private let inspector = RelayInspector()
    private var names: [Int: String] = [:]
    private var ips: [Int: String] = [:]
    private var stats = Stats()
    private var statsTimer: DispatchSourceTimer?
    private var lastSample = (Date(), UInt64(0), UInt64(0))
    private var createdCapacity = 0
    private let statsLock = NSLock()
    private var recentRefusals: [String] = []
    /// Fired (on the core queue) when a player joins or leaves, for the console.
    public var onRosterChange: (() -> Void)?

    public var config: ServerConfig { store.config }

    public init(store: ConfigStore, log: ServerLog, plugins: PluginManager, audit: AuditLog = AuditLog()) {
        self.store = store; self.log = log; self.plugins = plugins; self.audit = audit
        manifest = plugins.manifest(enabled: store.config.enabledPlugins)
    }

    // MARK: Lifecycle

    /// Open the game port. Throws a plain-language `ServerError` when it can't.
    public func start() throws {
        try queue.sync { try startLocked() }
    }

    private func startLocked() throws {
        guard host == nil else { return }
        let cfg = store.config
        manifest = plugins.manifest(enabled: cfg.enabledPlugins)
        let h = ENetHostTransport(config: hostConfig(cfg))
        h.bannedIPs = Set(cfg.bans.keys)
        h.onEvent = { [weak self] e in self?.handle(e) }
        wireModeration(h)
        applyModeration(cfg)
        do { try h.start() } catch ENetHostTransport.HostError.cannotBind(let p) {
            let e = ServerError.portInUse(p)
            state = .failed(e.message)
            throw e
        }
        let s = NetSession(transport: h, rules: cfg.sessionRules)
        s.providesRules = true
        // Messages the relay delivers to the server's own session that break the rules count against the sender.
        s.onMisbehavior = { [weak self, weak h] peer, why, strikes in
            guard strikes >= 25, let id = Int(peer) else { return }
            h?.reportAbuse(id, "kept sending invalid messages (\(why))")
            self?.log.warn("Kicked #\(id): kept sending invalid messages (\(why)).")
        }
        s.localPluginManifest = manifest.all.gameplayOnly
        s.broadcastRules(cfg.sessionRules)
        host = h; session = s
        createdCapacity = cfg.maxPlayers
        startedAt = Date()
        state = .running
        statsLock.lock(); stats = Stats(); statsLock.unlock()
        h.startPumping(interval: 0.01, queue: queue)
        lan.broadcastBeacons = cfg.lanAnnounce
        let ok = lan.startAnnouncing(gamePort: cfg.port, provider: { [weak h] in
            h?.beacon() ?? ServerBeacon(name: "NovaSwift", players: 0, max: 0)
        })
        if !ok { log.warn(lan.lastError.isEmpty ? "Server pinging is off." : lan.lastError + " The server still works, but won't answer pings in the server list.") }
        startStatsTimer()
        log.info("Server \"\(cfg.name)\" is open on UDP port \(cfg.port) (\(cfg.maxPlayers) slots, rules: \(CrossPlayProtocol.presetName(cfg.sessionRules)), \(manifest.requirements.plugins.count) required plug-in(s)).")
        if !manifest.missing.isEmpty { log.warn("Plug-ins enabled but not installed yet: \(manifest.missing.joined(separator: ", ")).") }
    }

    public func stop() {
        queue.sync {
            statsTimer?.cancel(); statsTimer = nil
            lan.stopAnnouncing()
            host?.disconnect()
            host = nil; session = nil
            joinTimes.removeAll(); names.removeAll(); ips.removeAll()
            if state == .running { state = .stopped }
            startedAt = nil
        }
    }

    /// Close and reopen the game port (port or capacity changed). Connected players are dropped and can rejoin.
    public func restartNetwork() throws {
        stop()
        try start()
    }

    private func hostConfig(_ cfg: ServerConfig) -> ENetHostTransport.Config {
        var c = ENetHostTransport.Config(
            port: cfg.port, maxPlayers: cfg.maxPlayers, serverName: cfg.name, hostName: "[Server]",
            password: cfg.password, gameVersion: CrossPlayProtocol.appVersion,
            manifestJSON: ENetTransport.manifestJSON(manifest.all),
            rulesJSON: CrossPlayProtocol.rulesJSON(cfg.sessionRules), rulesName: CrossPlayProtocol.presetName(cfg.sessionRules),
            requirements: manifest.requirements, loopbackOnly: false, dedicated: true)
        c.bindAddress = cfg.bindAddress
        c.maxConnectionsPerIP = cfg.maxConnectionsPerIP
        return c
    }

    // MARK: Moderation wiring

    private func applyModeration(_ cfg: ServerConfig) {
        moderation.config = ModerationCenter.Config(voteKick: cfg.voteKick, voteKickPercent: cfg.voteKickPercent,
                                                    wordFilter: cfg.wordFilter, mutes: cfg.mutes)
    }

    private func wireModeration(_ h: ENetHostTransport) {
        let now: () -> Double = { ProcessInfo.processInfo.systemUptime }
        inspector.context = { [weak self] id in
            guard let self, let n = self.names[id] else { return nil }
            return RelayInspector.Context(name: n, ip: self.ips[id] ?? "")
        }
        inspector.chat = { [weak self] id, ctx, text in self?.vetChat(id: id, name: ctx.name, ip: ctx.ip, text: text, now: now()) }
        inspector.command = { [weak self] id, ctx, text in self?.runCommand(id: id, name: ctx.name, text: text, now: now()) }
        inspector.violation = { [weak h, weak self] id, what in
            // Forged identities and host-only messages are never legitimate: count them hard.
            self?.violationCounts[id, default: 0] += 1
            if (self?.violationCounts[id] ?? 0) >= 10 { h?.reportAbuse(id, what); self?.violationCounts[id] = 0 }
        }
        h.relayFilter = { [weak self] id, payload in self?.inspector.inspect(from: id, payload: payload) }
        h.chatFilter = { [weak self] id, name, ip, text in self?.vetChat(id: id, name: name, ip: ip, text: text, now: now()) }
        h.onCommand = { [weak self] id, name, _, text in self?.runCommand(id: id, name: name, text: text, now: now()) }
        h.joinGate = { [weak self] ip, name in
            guard let self else { return nil }
            let cfg = self.store.config
            if cfg.allowlistMode, !cfg.allowlist.keys.contains(where: { IPAddressTools.matches(entry: $0, ip: ip) }) {
                return ("allowlist", "This server is invite-only. Ask the admin to allow your address (\(ip)).")
            }
            return nil
        }
    }

    private var violationCounts: [Int: Int] = [:]

    private func vetChat(id: Int, name: String, ip: String, text: String, now: Double) -> String? {
        if moderation.isMuted(id: id, name: name, ip: ip) { return nil }   // muted players can talk to the void
        return moderation.vet(id: id, text: text, now: now)
    }

    private func runCommand(id: Int, name: String, text: String, now: Double) {
        let roster = (host?.clients ?? []).map { (id: $0.id, name: $0.name) }
        switch moderation.command(text, from: id, players: roster, now: now) {
        case .nothing: break
        case .reply(let line): sendChat(line, to: String(id))
        case .kick(let target, let reason):
            let who = names[target] ?? "#\(target)"
            log.info("Vote-kick passed against \(who) (started by \(name)).")
            audit.record(actor: "vote", "votekick", "\(who) removed")
            session?.kick(String(target), ban: false)
            host?.kick(target, reason: reason, ban: false)
            announce("\(who) was removed by a vote.", except: nil)
        case .report(let target, _, let detail, let reply):
            let who = names[target] ?? "#\(target)"
            log.warn("\(name) reported \(who)\(detail.isEmpty ? "" : ": " + detail)")
            sendChat(reply, to: String(id))
            if moderation.noteReport(target: target, reporter: id, now: now) >= 3 {
                host?.reportAbuse(target, "was reported by other players", countsTowardBan: false)
            }
        }
    }

    private func announce(_ text: String, except: Int?) {
        for c in host?.clients ?? [] where c.id != except { sendChat(text, to: String(c.id)) }
    }

    // MARK: Live settings

    public struct ApplyReport: Equatable {
        public var applied: [String] = []
        public var restartedNetwork = false
        public var needsRestart: [String] = []
        /// Set when the new settings couldn't be applied (e.g. the new port is taken); the server is stopped then.
        public var error: String?
    }

    /// Push a changed config into the running server: everything except the admin panel's own port/bind is live.
    public func apply(old: ServerConfig, new: ServerConfig) -> ApplyReport {
        var report = ApplyReport()
        if old.adminPort != new.adminPort { report.needsRestart.append("The admin panel port changes after you restart the server.") }
        if old.adminBind != new.adminBind { report.needsRestart.append("The admin panel address changes after you restart the server.") }
        manifest = plugins.manifest(enabled: new.enabledPlugins)
        guard state == .running else { return report }
        let capacityGrew = new.maxPlayers > createdCapacity
        if old.port != new.port || old.bindAddress != new.bindAddress || capacityGrew {
            do { try restartNetwork(); report.restartedNetwork = true
                 log.info("Game port settings changed: the server was restarted. Connected players need to rejoin.")
            } catch {
                let msg = (error as? ServerError)?.message ?? error.localizedDescription
                log.error("Couldn't reopen the game port: \(msg)")
                report.error = msg
            }
            return report
        }
        queue.sync {
            guard let host, let session else { return }
            manifest = plugins.manifest(enabled: new.enabledPlugins)
            let rules = new.sessionRules
            host.reconfigure {
                $0.serverName = new.name; $0.password = new.password; $0.maxPlayers = new.maxPlayers
                $0.manifestJSON = ENetTransport.manifestJSON(manifest.all)
                $0.rulesJSON = CrossPlayProtocol.rulesJSON(rules); $0.rulesName = CrossPlayProtocol.presetName(rules)
                $0.requirements = manifest.requirements
            }
            host.bannedIPs = Set(new.bans.keys)
            host.reconfigure { $0.maxConnectionsPerIP = new.maxConnectionsPerIP }
            applyModeration(new)
            session.localPluginManifest = manifest.all.gameplayOnly
            if session.sessionRules != rules { session.broadcastRules(rules); report.applied.append("Rules updated for everyone online.") }
            lan.broadcastBeacons = new.lanAnnounce
        }
        report.applied.append("Settings applied.")
        return report
    }

    /// Re-hash the plug-ins and push them live (after install / enable / disable).
    public func refreshPlugins() {
        let cfg = store.config
        queue.sync {
            manifest = plugins.manifest(enabled: cfg.enabledPlugins)
            guard let host, let session else { return }
            host.reconfigure {
                $0.manifestJSON = ENetTransport.manifestJSON(manifest.all)
                $0.requirements = manifest.requirements
            }
            session.localPluginManifest = manifest.all.gameplayOnly
        }
    }

    // MARK: Events

    private func handle(_ e: ENetHostTransport.Event) {
        switch e {
        case .hosting: break
        case .peerJoined(let id, let name):
            joinTimes[id] = Date()
            names[id] = name
            ips[id] = host?.clients.first { $0.id == id }?.ip ?? ""
            statsLock.lock()
            stats.totalJoins += 1
            stats.peakPlayers = max(stats.peakPlayers, host?.clients.count ?? 0)
            statsLock.unlock()
            let ip = host?.clients.first { $0.id == id }?.ip ?? "?"
            log.info("\(name) joined (id \(id), \(ip)). Players: \(host?.clients.count ?? 0)/\(store.config.maxPlayers).")
            sendMOTD(to: id)
            if store.config.announceJoins { announce("\(name) joined.", except: id) }
            onRosterChange?()
        case .peerLeft(let id, let name, let reason):
            joinTimes[id] = nil; names[id] = nil; ips[id] = nil; violationCounts[id] = nil
            moderation.forget(id: id)
            if store.config.announceJoins { announce("\(name) left.", except: id) }
            log.info("\(name) left (\(reason)). Players: \(host?.clients.count ?? 0)/\(store.config.maxPlayers).")
            onRosterChange?()
        case .refused(let code, let message, let ip):
            statsLock.lock(); stats.refusals += 1; statsLock.unlock()
            log.warn("A join from \(ip) was refused (\(code)): \(message)")
            recentRefusals.append("\(ip): \(Self.refusalExplanation(code))")
            if recentRefusals.count > 20 { recentRefusals.removeFirst() }
        case .chat(_, let name, let text):
            log.info("<\(name)> \(text)")
        case .abuse(_, let name, let ip, let reason, let banned):
            statsLock.lock(); stats.abuseKicks += 1; statsLock.unlock()
            log.warn("\(name.isEmpty ? "A connection" : name) (\(ip)) \(reason)\(banned ? " - address blocked for a while" : "").")
            audit.record(actor: "server", banned ? "tempban" : "abuse-kick", "\(ip) \(reason)")
        case .report(let reporter, let target, let reason, let detail):
            let who = reporter == 0 ? "?" : (names[reporter] ?? "#\(reporter)")
            if target == 0 {
                log.warn("\(who) reports invalid data from another peer (\(reason)): \(detail)")
            } else {
                let t = names[target] ?? "#\(target)"
                log.warn("\(who) reported \(t) (\(reason))\(detail.isEmpty ? "" : ": " + detail)")
                let now = ProcessInfo.processInfo.systemUptime
                var kick = moderation.noteReport(target: target, reporter: reporter, now: now) >= 3
                if reason == "invalid",
                   moderation.noteInvalidReport(target: target, reporter: reporter, now: now,
                                                online: host?.clients.count ?? 0) { kick = true }
                // A kick driven by reports never feeds the address temp-ban (only the server's own flood/limit kicks do).
                if kick { host?.reportAbuse(target, "was reported by other players", countsTowardBan: false) }
            }
        case .versionNote(_, let name, let theirs, let ours):
            log.info("\(name) runs NovaSwift \(theirs) (server \(ours)); same protocol, playing anyway.")
        }
    }

    static func refusalExplanation(_ code: String) -> String {
        switch code {
        case "password": return "wrong or missing password"
        case "full": return "server was full"
        case "plugins": return "their plug-ins didn't match the server's"
        case "banned": return "banned"
        case "proto": return "different multiplayer protocol version"
        default: return code
        }
    }

    public var refusals: [String] { queue.sync { recentRefusals } }

    private func sendMOTD(to id: Int) {
        let motd = store.config.motd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !motd.isEmpty else { return }
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.sendChat(motd, to: String(id))
        }
    }

    private func sendChat(_ text: String, to peer: String?) {
        guard let host else { return }
        let msg = ChatMessage(playerID: "1", senderName: "[Server]", text: text)
        guard let data = try? NetCodec.encode(.chat(msg)) else { return }
        if let peer { host.send(data, to: peer, channel: .reliable) } else { host.broadcast(data, channel: .reliable) }
    }

    // MARK: Queries

    public func players() -> [Player] {
        queue.sync {
            guard let host else { return [] }
            return host.clients.map { c in
                Player(id: c.id, name: c.name, ip: c.ip, pingMs: c.rttMilliseconds,
                       systemID: session?.presence[String(c.id)]?.currentSystemID, joinedAt: joinTimes[c.id] ?? Date())
            }
        }
    }

    public func snapshot() -> Stats {
        statsLock.lock(); defer { statsLock.unlock() }
        var s = stats
        s.bytesSent = host?.bytesSent ?? 0; s.bytesReceived = host?.bytesReceived ?? 0
        return s
    }

    public var uptime: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    public var playerCount: Int { queue.sync { host?.clients.count ?? 0 } }

    private func startStatsTimer() {
        lastSample = (Date(), 0, 0)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self, let host = self.host else { return }
            let now = Date()
            let dt = max(0.1, now.timeIntervalSince(self.lastSample.0))
            let s = host.bytesSent, r = host.bytesReceived
            self.statsLock.lock()
            self.stats.outBytesPerSec = Double(s &- self.lastSample.1) / dt
            self.stats.inBytesPerSec = Double(r &- self.lastSample.2) / dt
            self.statsLock.unlock()
            self.lastSample = (now, s, r)
        }
        t.resume()
        statsTimer = t
    }

    // MARK: Moderation

    /// Find a connected player by numeric id or (case-insensitive) name.
    public func findPlayer(_ key: String) -> Player? {
        let list = players()
        if let id = Int(key), let p = list.first(where: { $0.id == id }) { return p }
        return list.first { $0.name.lowercased() == key.lowercased() }
            ?? list.first { $0.name.lowercased().hasPrefix(key.lowercased()) }
    }

    @discardableResult
    public func kick(_ id: Int, reason: String = "Removed by the server admin.", ban: Bool = false, actor: String = "console") -> Bool {
        let player = players().first { $0.id == id }
        guard let player else { return false }
        if ban && !player.ip.isEmpty {
            try? store.update { $0.bans[IPAddressTools.groupKey(player.ip)] = "\(player.name) (banned \(Self.dateOnly(Date())))" }
        }
        let ok: Bool = queue.sync {
            session?.kick(String(id), ban: ban)
            return host?.kick(id, reason: reason, ban: ban) ?? false
        }
        log.info("\(ban ? "Banned" : "Kicked") \(player.name) (\(player.ip)).")
        audit.record(actor: actor, ban ? "ban" : "kick", "\(player.name) (\(player.ip)) \(reason)")
        return ok
    }

    public func ban(ip: String, note: String, actor: String = "console") {
        guard NetworkTools.isIP(ip) else { return }
        let ip = IPAddressTools.groupKey(ip)          // IPv4: the address; IPv6: its /64 ("2001:db8:1:2::/64")
        audit.record(actor: actor, "ban-ip", "\(ip) \(note)")
        try? store.update { $0.bans[ip] = note.isEmpty ? "banned \(Self.dateOnly(Date()))" : note }
        queue.sync { host?.bannedIPs = Set(store.config.bans.keys) }
        for p in players() where IPAddressTools.matches(entry: ip, ip: p.ip) { kick(p.id, reason: "Banned by the server admin.", ban: false) }
        log.info("Banned \(ip).")
    }

    public func unban(ip: String, actor: String = "console") {
        audit.record(actor: actor, "unban-ip", ip)
        try? store.update { cfg in cfg.bans = cfg.bans.filter { !IPAddressTools.matches(entry: $0.key, ip: ip) } }   // an IPv6 address lifts its whole /64
        queue.sync { host?.bannedIPs = Set(store.config.bans.keys) }
        log.info("Unbanned \(ip).")
    }

    // MARK: Mutes, allowlist, temporary blocks

    /// Mute a connected player (by id or name): their chat is dropped for everyone, and it persists by address and name.
    @discardableResult
    public func mute(_ key: String, note: String = "", actor: String = "console") -> Player? {
        guard let p = findPlayer(key) else { return nil }
        let stamp = note.isEmpty ? "muted \(Self.dateOnly(Date())) - \(p.name)" : note
        try? store.update { c in
            if !p.ip.isEmpty { c.mutes["ip:\(p.ip)"] = stamp }
            c.mutes["name:\(p.name.lowercased())"] = stamp
        }
        queue.sync { applyModeration(store.config) }
        audit.record(actor: actor, "mute", "\(p.name) (\(p.ip))")
        log.info("Muted \(p.name).")
        sendChat("You have been muted by the server admin.", to: String(p.id))
        return p
    }

    /// Lift a mute by player name, address, or the raw "ip:..." / "name:..." key.
    @discardableResult
    public func unmute(_ key: String, actor: String = "console") -> Bool {
        let k = key.trimmingCharacters(in: .whitespaces)
        let lower = k.lowercased()
        var hit = false
        // A connected player's name also lifts the address entry that was added with it.
        let extra: [String] = findPlayer(k).map { ["ip:\($0.ip)".lowercased(), "name:\($0.name.lowercased())"] } ?? []
        try? store.update { c in
            for existing in c.mutes.keys where extra.contains(existing.lowercased()) || existing.lowercased() == lower || existing.lowercased() == "ip:" + lower || existing.lowercased() == "name:" + lower {
                c.mutes[existing] = nil; hit = true
            }
        }
        queue.sync { applyModeration(store.config) }
        if hit { audit.record(actor: actor, "unmute", k); log.info("Unmuted \(k).") }
        return hit
    }

    public func allow(ip: String, note: String = "", actor: String = "console") {
        guard NetworkTools.isIP(ip) else { return }
        let ip = IPAddressTools.groupKey(ip)          // IPv6 entries cover the whole /64
        try? store.update { $0.allowlist[ip] = note.isEmpty ? "added \(Self.dateOnly(Date()))" : note }
        audit.record(actor: actor, "allow", ip)
    }

    public func disallow(ip: String, actor: String = "console") {
        try? store.update { cfg in cfg.allowlist = cfg.allowlist.filter { !IPAddressTools.matches(entry: $0.key, ip: ip) } }
        audit.record(actor: actor, "disallow", ip)
    }

    /// Addresses blocked for a while after abuse, with seconds left.
    public var tempBans: [String: Double] { queue.sync { host?.tempBans ?? [:] } }
    public func clearTempBan(_ ip: String, actor: String = "console") {
        queue.sync { host?.clearTempBan(ip) }
        audit.record(actor: actor, "clear-tempban", ip)
    }

    /// Server-wide announcement shown in everyone's chat as "[Server]".
    public func say(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        queue.sync { sendChat(String(t.prefix(240)), to: nil) }
        log.info("<[Server]> \(t)")
    }

    public func message(player id: Int, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        queue.sync { sendChat(String(t.prefix(240)), to: String(id)) }
    }

    /// The `NSB1` beacon exactly as the server list sees it.
    public func beacon() -> ServerBeacon? { host?.beacon() }

    static func dateOnly(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: d)
    }
}

/// An error with a message a person can act on.
public struct ServerError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    public static func portInUse(_ port: Int) -> ServerError {
        ServerError("Port \(port) is already in use - is another NovaSwift server (or a game you are hosting) already running? Close it, or pick a different port in Settings.")
    }
}

public enum ServerVersion {
    /// The server program's own version (release tag `server-v<version>`).
    public static let current = "1.0.0-beta.1"
    public static let releasesAPI = URL(string: "https://api.github.com/repos/SirStig/NovaSwift/releases?per_page=30")!
    public static let releasesPage = URL(string: "https://github.com/SirStig/NovaSwift/releases")!
    public static let tagPrefix = "server-v"
}
