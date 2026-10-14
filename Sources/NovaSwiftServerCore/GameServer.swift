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
    }

    public let store: ConfigStore
    public let log: ServerLog
    public let plugins: PluginManager
    public private(set) var state: RunState = .stopped
    public private(set) var startedAt: Date?
    public private(set) var manifest: PluginManager.Manifest

    /// Everything touching ENet and the session runs on this queue.
    private let queue = DispatchQueue(label: "novaswift.server.core")
    private var host: ENetHostTransport?
    private var session: NetSession?
    private let lan = LANBeaconService()
    private var joinTimes: [Int: Date] = [:]
    private var stats = Stats()
    private var statsTimer: DispatchSourceTimer?
    private var lastSample = (Date(), UInt64(0), UInt64(0))
    private var createdCapacity = 0
    private let statsLock = NSLock()
    private var recentRefusals: [String] = []
    /// Fired (on the core queue) when a player joins or leaves, for the console.
    public var onRosterChange: (() -> Void)?

    public var config: ServerConfig { store.config }

    public init(store: ConfigStore, log: ServerLog, plugins: PluginManager) {
        self.store = store; self.log = log; self.plugins = plugins
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
        do { try h.start() } catch ENetHostTransport.HostError.cannotBind(let p) {
            let e = ServerError.portInUse(p)
            state = .failed(e.message)
            throw e
        }
        let s = NetSession(transport: h, rules: cfg.sessionRules)
        s.providesRules = true
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
            joinTimes.removeAll()
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
        ENetHostTransport.Config(
            port: cfg.port, maxPlayers: cfg.maxPlayers, serverName: cfg.name, hostName: "[Server]",
            password: cfg.password, gameVersion: CrossPlayProtocol.appVersion,
            manifestJSON: ENetTransport.manifestJSON(manifest.all),
            rulesJSON: CrossPlayProtocol.rulesJSON(cfg.sessionRules), rulesName: CrossPlayProtocol.presetName(cfg.sessionRules),
            requirements: manifest.requirements, loopbackOnly: false, dedicated: true)
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
        if old.port != new.port || capacityGrew {
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
            statsLock.lock()
            stats.totalJoins += 1
            stats.peakPlayers = max(stats.peakPlayers, host?.clients.count ?? 0)
            statsLock.unlock()
            let ip = host?.clients.first { $0.id == id }?.ip ?? "?"
            log.info("\(name) joined (id \(id), \(ip)). Players: \(host?.clients.count ?? 0)/\(store.config.maxPlayers).")
            sendMOTD(to: id)
            onRosterChange?()
        case .peerLeft(let id, let name, let reason):
            joinTimes[id] = nil
            log.info("\(name) left (\(reason)). Players: \(host?.clients.count ?? 0)/\(store.config.maxPlayers).")
            onRosterChange?()
        case .refused(let code, let message, let ip):
            statsLock.lock(); stats.refusals += 1; statsLock.unlock()
            log.warn("A join from \(ip) was refused (\(code)): \(message)")
            recentRefusals.append("\(ip): \(Self.refusalExplanation(code))")
            if recentRefusals.count > 20 { recentRefusals.removeFirst() }
        case .chat(_, let name, let text):
            log.info("<\(name)> \(text)")
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
    public func kick(_ id: Int, reason: String = "Removed by the server admin.", ban: Bool = false) -> Bool {
        let player = players().first { $0.id == id }
        guard let player else { return false }
        if ban && !player.ip.isEmpty {
            try? store.update { $0.bans[player.ip] = "\(player.name) (banned \(Self.dateOnly(Date())))" }
        }
        let ok: Bool = queue.sync {
            session?.kick(String(id), ban: ban)
            return host?.kick(id, reason: reason, ban: ban) ?? false
        }
        log.info("\(ban ? "Banned" : "Kicked") \(player.name) (\(player.ip)).")
        return ok
    }

    public func ban(ip: String, note: String) {
        guard NetworkTools.octets(ip) != nil else { return }
        try? store.update { $0.bans[ip] = note.isEmpty ? "banned \(Self.dateOnly(Date()))" : note }
        queue.sync { host?.bannedIPs = Set(store.config.bans.keys) }
        for p in players() where p.ip == ip { kick(p.id, reason: "Banned by the server admin.", ban: false) }
        log.info("Banned \(ip).")
    }

    public func unban(ip: String) {
        try? store.update { $0.bans[ip] = nil }
        queue.sync { host?.bannedIPs = Set(store.config.bans.keys) }
        log.info("Unbanned \(ip).")
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
    public static let current = "0.1.0"
    public static let releasesAPI = URL(string: "https://api.github.com/repos/SirStig/NovaSwift/releases?per_page=30")!
    public static let releasesPage = URL(string: "https://github.com/SirStig/NovaSwift/releases")!
    public static let tagPrefix = "server-v"
}
