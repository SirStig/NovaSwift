import Foundation
import NovaSwiftNet
import NovaSwiftENet
import NovaSwiftPluginStore

/// The admin panel's HTTP API and its embedded pages. Every `/api/*` route except login needs a session cookie, and
/// every state-changing request must carry the `X-NS-Admin` header (browsers will not add it to a cross-site form).
public final class AdminService {
    public let server: GameServer
    public let store: ConfigStore
    public let log: ServerLog
    public let plugins: PluginManager
    public let updates: UpdateChecker

    private let lock = NSLock()
    private var sessions: [String: Date] = [:]
    private var failures: [String: (count: Int, until: Date, level: Int)] = [:]
    private var globalFailures: [Date] = []
    /// One-time link that signs you in from this computer until the first-run wizard is done.
    public private(set) var setupCode: String?
    private var cachedPublicIP: (ip: String?, at: Date)?
    private var upnpResult: NetworkTools.UPnPResult?
    private var restartRequired: [String] = []
    public var onShutdown: (() -> Void)?

    public var audit: AuditLog { server.audit }
    /// Extra host names the panel answers to (a reverse proxy's domain), besides localhost / IP literals / this machine.
    public var extraHosts: Set<String> = Set((ProcessInfo.processInfo.environment["NOVASWIFT_ADMIN_HOSTS"] ?? "")
        .lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })

    public init(server: GameServer, updates: UpdateChecker) {
        self.server = server; store = server.store; log = server.log; plugins = server.plugins; self.updates = updates
        if !store.config.setupDone { setupCode = (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }
    }

    /// The public address (when the lookup finished or one is set in Settings) and this computer's LAN address.
    public func joinAddresses() -> (public: String?, lan: String?) {
        let cfg = store.config
        lock.lock(); let cached = cachedPublicIP; lock.unlock()
        let pub = !cfg.publicAddress.isEmpty ? cfg.publicAddress : cached?.ip
        let lan = NetworkTools.localAddresses().first { $0.kind == "lan" }?.ip
        return (pub, lan)
    }

    func setCachedPublicIP(_ ip: String?) { lock.lock(); cachedPublicIP = (ip, Date()); lock.unlock() }

    // MARK: Entry point

    public func handle(_ req: HTTPRequest) -> HTTPResponse {
        if let refused = guardRequest(req) { return Self.secured(refused) }
        return Self.secured(route(req))
    }

    /// Security headers on every response. The panel loads one script and one stylesheet from itself and talks only
    /// to itself, so the policy can be strict.
    static func secured(_ r: HTTPResponse) -> HTTPResponse {
        var r = r
        r.headers["Content-Security-Policy"] = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
        r.headers["X-Frame-Options"] = "DENY"
        r.headers["X-Content-Type-Options"] = "nosniff"
        r.headers["Referrer-Policy"] = "no-referrer"
        r.headers["Cross-Origin-Opener-Policy"] = "same-origin"
        r.headers["Cross-Origin-Resource-Policy"] = "same-origin"
        r.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=(), payment=()"
        if r.headers["Cache-Control"] == nil { r.headers["Cache-Control"] = "no-store" }
        return r
    }

    /// DNS-rebinding and cross-site defence: the Host header must be one the panel knows (an IP literal, localhost, this
    /// machine, the configured public address), and a state-changing request carrying an Origin must be same-origin.
    func guardRequest(_ req: HTTPRequest) -> HTTPResponse? {
        if let host = req.headers["host"], !Self.hostAllowed(host, store: store, extra: extraHosts) {
            return .error("Unknown host name. Open the panel by its IP address, localhost, or an SSH tunnel.", status: 421)
        }
        if req.method != "GET" && req.method != "HEAD", let origin = req.headers["origin"] {
            let originHost = origin.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            if originHost.lowercased() != (req.headers["host"] ?? "").lowercased() {
                return .error("Cross-site request refused.", status: 403)
            }
        }
        return nil
    }

    static func hostAllowed(_ header: String, store: ConfigStore, extra: Set<String>) -> Bool {
        var h = header.lowercased()
        if h.hasPrefix("[") {                       // [::1]:53737
            return true                              // IP literal
        }
        if let colon = h.lastIndex(of: ":") { h = String(h[..<colon]) }
        if h.isEmpty || h == "localhost" || h.hasSuffix(".localhost") { return true }
        if NetworkTools.octets(h) != nil { return true }
        if h == ProcessInfo.processInfo.hostName.lowercased() { return true }
        let pub = store.config.publicAddress.lowercased()
        if !pub.isEmpty, h == pub { return true }
        return extra.contains(h)
    }

    private func route(_ req: HTTPRequest) -> HTTPResponse {
        if req.path.hasPrefix("/api/") { return api(req) }
        guard req.method == "GET" || req.method == "HEAD" else { return .error("Not found.", status: 404) }
        switch req.path {
        case "/", "/index.html": return .init(headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(AdminAssets.indexHTML.utf8))
        case "/app.css": return .init(headers: ["Content-Type": "text/css; charset=utf-8"], body: Data(AdminAssets.appCSS.utf8))
        case "/app.js": return .init(headers: ["Content-Type": "application/javascript; charset=utf-8"], body: Data(AdminAssets.appJS.utf8))
        case "/favicon.svg": return .init(headers: ["Content-Type": "image/svg+xml"], body: Data(AdminAssets.faviconSVG.utf8))
        case "/favicon.ico": return .init(status: 204)
        default: return .error("Not found.", status: 404)
        }
    }

    // MARK: Auth

    private func isAuthed(_ req: HTTPRequest) -> Bool {
        guard let token = req.cookies["nsadmin"] else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let exp = sessions[token], exp > Date() else { sessions[token] = nil; return false }
        return true
    }

    private func newSession(_ req: HTTPRequest) -> HTTPResponse {
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        lock.lock()
        sessions[token] = Date().addingTimeInterval(Self.sessionSeconds)
        sessions = sessions.filter { $0.value > Date() }
        if sessions.count > 64 { sessions = Dictionary(uniqueKeysWithValues: sessions.sorted { $0.value > $1.value }.prefix(64).map { ($0.key, $0.value) }) }
        lock.unlock()
        var r = HTTPResponse.json(["ok": true])
        r.headers["Set-Cookie"] = Self.cookie(token, maxAge: Int(Self.sessionSeconds), secure: Self.isHTTPS(req))
        return r
    }

    static let sessionSeconds: TimeInterval = 12 * 3600

    /// `HttpOnly; SameSite=Strict`, plus `Secure` when the request came over HTTPS (directly or via a local reverse proxy).
    static func cookie(_ token: String, maxAge: Int, secure: Bool) -> String {
        "nsadmin=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(maxAge)" + (secure ? "; Secure" : "")
    }

    /// The server speaks plain HTTP; HTTPS means a TLS-terminating proxy on this machine set X-Forwarded-Proto.
    static func isHTTPS(_ req: HTTPRequest) -> Bool {
        req.isLoopback && (req.headers["x-forwarded-proto"] ?? "").lowercased() == "https"
    }

    private func throttled(_ ip: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        if let f = failures[ip], f.count >= 5, f.until > Date() { return Int(f.until.timeIntervalSinceNow.rounded(.up)) }
        // Many wrong passwords from many addresses (a distributed guess): everyone but this computer waits.
        globalFailures = globalFailures.filter { Date().timeIntervalSince($0) < 60 }
        if globalFailures.count >= 60, ip != "127.0.0.1", ip != "::1" { return 30 }
        return nil
    }

    /// Five wrong passwords lock an address out; each repeat lock-out doubles the wait (1 min, 2, 4 ... up to an hour).
    private func noteFailure(_ ip: String) {
        lock.lock(); defer { lock.unlock() }
        var f = failures[ip] ?? (0, Date(), 0)
        if f.until < Date() && f.count >= 5 { f.count = 0 }
        f.count += 1
        if f.count >= 5 {
            f.until = Date().addingTimeInterval(min(3600, 60 * pow(2, Double(f.level))))
            f.level = min(f.level + 1, 6)
        } else {
            f.until = Date().addingTimeInterval(60)
        }
        failures[ip] = f
        globalFailures.append(Date())
        if failures.count > 2048 { failures = failures.filter { $0.value.until > Date() } }
    }

    private func clearFailures(_ ip: String) { lock.lock(); failures[ip] = nil; lock.unlock() }

    // MARK: API router

    static func sameSecret(_ a: String, _ b: String) -> Bool { AdminPassword.constantTimeEqual(Array(a.utf8), Array(b.utf8)) }

    /// Routes whose request bodies never go in the audit log (secrets).
    private static let secretRoutes: Set<String> = ["login", "setup-login", "admin-password"]

    private func api(_ req: HTTPRequest) -> HTTPResponse {
        let resp = apiRoute(req)
        let route = String(req.path.dropFirst(5))
        // Every state-changing action by a signed-in admin is recorded (who, what, from where), never secrets.
        if req.method != "GET", resp.status < 400, !Self.secretRoutes.contains(route), route != "logout" {
            var detail = ""
            if !req.body.isEmpty {
                let b = req.json()
                detail = b.keys.sorted().filter { !["password", "current", "new", "code"].contains($0) }
                    .map { k in "\(k)=\(String(describing: b[k] ?? "").prefix(60))" }.joined(separator: " ")
                if b["password"] != nil { detail += " password=(changed)" }
            }
            audit.record(actor: "admin@\(req.remoteIP)", route, detail)
        }
        if route == "admin-password", req.method == "POST", resp.status < 400 { audit.record(actor: "admin@\(req.remoteIP)", "admin-password", "changed") }
        return resp
    }

    private func apiRoute(_ req: HTTPRequest) -> HTTPResponse {
        let route = String(req.path.dropFirst(5))   // after "/api/"
        if req.method != "GET" && req.headers["x-ns-admin"] == nil {
            return .error("Missing X-NS-Admin header.", status: 403)
        }
        switch (req.method, route) {
        case ("GET", "session"):
            return .json(["authenticated": isAuthed(req), "setupDone": store.config.setupDone,
                          "setupLinkAvailable": setupCode != nil && req.isLoopback, "version": ServerVersion.current])
        case ("POST", "login"):
            if let wait = throttled(req.remoteIP) { return .error("Too many wrong passwords. Try again in \(wait) seconds.", status: 429) }
            let pw = (req.json()["password"] as? String) ?? ""
            if !store.config.adminPasswordHash.isEmpty, AdminPassword.verify(pw, against: store.config.adminPasswordHash) {
                clearFailures(req.remoteIP)
                audit.record(actor: "admin@\(req.remoteIP)", "login")
                return newSession(req)
            }
            noteFailure(req.remoteIP)
            audit.record(actor: "unknown@\(req.remoteIP)", "login-failed")
            return .error("That password isn't right. The admin password was printed in the console the first time the server started.", status: 401)
        case ("POST", "setup-login"):
            let code = (req.json()["code"] as? String) ?? ""
            if let sc = setupCode, req.isLoopback, !code.isEmpty, Self.sameSecret(code, sc) {
                audit.record(actor: "setup@\(req.remoteIP)", "setup-login")
                return newSession(req)
            }
            return .error("That setup link is no longer valid. Sign in with the admin password instead.", status: 401)
        default: break
        }
        guard isAuthed(req) else { return .error("Please sign in.", status: 401) }
        switch (req.method, route) {
        case ("POST", "logout"):
            if let t = req.cookies["nsadmin"] { lock.lock(); sessions[t] = nil; lock.unlock() }
            var r = HTTPResponse.json(["ok": true]); r.headers["Set-Cookie"] = Self.cookie("", maxAge: 0, secure: Self.isHTTPS(req)); return r
        case ("GET", "status"): return .json(statusJSON())
        case ("GET", "players"): return .json(["players": server.players().map(playerJSON)])
        case ("POST", "players/mute"):
            guard let id = Self.intValue(req.json()["id"]), let p = server.mute(String(id), actor: "admin@\(req.remoteIP)") else { return .error("That player has already left.", status: 404) }
            _ = p
            return .json(["ok": true])
        case ("POST", "players/unmute"):
            let actor = "admin@\(req.remoteIP)"
            if let id = Self.intValue(req.json()["id"]), let p = server.players().first(where: { $0.id == id }) {
                let a = server.unmute("ip:\(p.ip)", actor: actor), b = server.unmute("name:\(p.name.lowercased())", actor: actor)
                return a || b ? .json(["ok": true]) : .error("That player isn't muted.", status: 404)
            }
            let key = (req.json()["key"] as? String) ?? ""
            return server.unmute(key, actor: actor) ? .json(["ok": true]) : .error("That mute isn't in the list.", status: 404)
        case ("GET", "moderation"): return .json(moderationJSON())
        case ("POST", "allowlist/add"):
            let ip = ((req.json()["ip"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard NetworkTools.octets(ip) != nil else { return .error("That isn't an IPv4 address (like 203.0.113.7).") }
            server.allow(ip: ip, note: (req.json()["note"] as? String) ?? "", actor: "admin@\(req.remoteIP)")
            return .json(moderationJSON())
        case ("POST", "allowlist/remove"):
            server.disallow(ip: (req.json()["ip"] as? String) ?? "", actor: "admin@\(req.remoteIP)")
            return .json(moderationJSON())
        case ("POST", "tempbans/clear"):
            server.clearTempBan((req.json()["ip"] as? String) ?? "", actor: "admin@\(req.remoteIP)")
            return .json(moderationJSON())
        case ("GET", "audit"):
            let f = ISO8601DateFormatter()
            return .json(["entries": audit.entries(limit: 300).map { ["t": f.string(from: $0.time), "actor": $0.actor, "action": $0.action, "detail": $0.detail] }])
        case ("POST", "players/kick"):
            let b = req.json()
            guard let id = (b["id"] as? Int) ?? (b["id"] as? Double).map(Int.init) else { return .error("Which player?") }
            let ban = (b["ban"] as? Bool) ?? false
            let reason = ((b["reason"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let ok = server.kick(id, reason: reason.isEmpty ? (ban ? "Banned by the server admin." : "Removed by the server admin.") : reason, ban: ban, actor: "admin@\(req.remoteIP)")
            return ok ? .json(["ok": true]) : .error("That player has already left.", status: 404)
        case ("POST", "players/message"):
            let b = req.json()
            let text = (b["text"] as? String) ?? ""
            if let id = (b["id"] as? Int) { server.message(player: id, text) } else { server.say(text) }
            return .json(["ok": true])
        case ("GET", "settings"): return .json(settingsJSON())
        case ("POST", "settings"): return saveSettings(req.json())
        case ("POST", "setup/complete"):
            try? store.update { $0.setupDone = true }
            lock.lock(); setupCode = nil; lock.unlock()
            return .json(["ok": true])
        case ("POST", "admin-password"):
            let b = req.json()
            let current = (b["current"] as? String) ?? "", next = (b["new"] as? String) ?? ""
            guard AdminPassword.verify(current, against: store.config.adminPasswordHash) else { return .error("Your current password isn't right.", status: 403) }
            if let why = AdminPassword.strengthProblem(next, current: current) { return .error(why) }
            try? store.update { $0.adminPasswordHash = AdminPassword.hash(next) }
            lock.lock(); sessions.removeAll(); lock.unlock()
            log.info("The admin password was changed from the panel.")
            return newSession(req)
        case ("GET", "plugins"): return .json(pluginsJSON())
        case ("POST", "plugins/refresh"):
            plugins.refreshCatalog()
            return .json(["ok": true])
        case ("POST", "plugins/install"):
            guard let id = req.json()["id"] as? String else { return .error("Which plug-in?") }
            guard plugins.catalogEntry(id) != nil else { return .error("\"\(id)\" isn't in the plug-in catalog.", status: 404) }
            plugins.install(catalogID: id) { [weak self] ok in
                guard let self, ok else { return }
                if self.store.config.enabledPlugins.contains(id) { self.server.refreshPlugins() }
            }
            return .json(["ok": true])
        case ("POST", "plugins/enable"):
            let b = req.json()
            guard let id = b["id"] as? String else { return .error("Which plug-in?") }
            let on = (b["enabled"] as? Bool) ?? true
            let old = store.config
            try? store.update {
                $0.enabledPlugins.removeAll { $0 == id }
                if on { $0.enabledPlugins.append(id) }
            }
            if on && !plugins.isInstalled(id), plugins.catalogEntry(id) != nil {
                plugins.install(catalogID: id) { [weak self] _ in self?.server.refreshPlugins() }
            }
            _ = server.apply(old: old, new: store.config)
            return .json(pluginsJSON())
        case ("POST", "plugins/remove"):
            guard let id = req.json()["id"] as? String else { return .error("Which plug-in?") }
            let old = store.config
            try? store.update { $0.enabledPlugins.removeAll { $0 == id } }
            do { try plugins.remove(id) } catch { return .error("Couldn't delete it: \(error.localizedDescription)", status: 500) }
            _ = server.apply(old: old, new: store.config)
            return .json(pluginsJSON())
        case ("POST", "plugins/upload"):
            return upload(req)
        case ("GET", "public"): return .json(publicJSON())
        case ("GET", "network"): return .json(networkJSON())
        case ("POST", "network/upnp"):
            let cfg = store.config
            let r = NetworkTools.tryUPnP(ports: [cfg.port, CrossPlayProtocol.queryPort(forGamePort: cfg.port)])
            lock.lock(); upnpResult = r; lock.unlock()
            log.info("UPnP: \(r.message)")
            return .json(networkJSON())
        case ("POST", "network/publicip"):
            let ip = NetworkTools.publicIP()
            lock.lock(); cachedPublicIP = (ip, Date()); lock.unlock()
            return .json(networkJSON())
        case ("POST", "network/selftest"):
            let cfg = store.config
            let t0 = Date()
            let r = ServerStatusQuery.query(host: "127.0.0.1", gamePort: cfg.port, timeout: 2)
            return .json(["ok": r != nil, "ms": Int(Date().timeIntervalSince(t0) * 1000),
                          "message": r != nil ? "The server answers status queries on this computer (UDP \(CrossPlayProtocol.queryPort(forGamePort: cfg.port)))."
                                              : "The server did not answer a status query on this computer. Is the game port blocked by a firewall on this machine?"])
        case ("GET", "logs"):
            let after = Int(req.query["after"] ?? "0") ?? 0
            let lines = log.lines(after: after, limit: 400)
            return .json(["lines": lines.map { ["seq": $0.seq, "t": ServerLog.format($0), "level": $0.level.rawValue] }, "last": lines.last?.seq ?? after])
        case ("GET", "bans"): return .json(["bans": store.config.bans.sorted { $0.key < $1.key }.map { ["ip": $0.key, "note": $0.value] }])
        case ("POST", "bans/add"):
            let b = req.json()
            let ip = ((b["ip"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard NetworkTools.octets(ip) != nil else { return .error("That isn't an IPv4 address (like 203.0.113.7).") }
            server.ban(ip: ip, note: (b["note"] as? String) ?? "", actor: "admin@\(req.remoteIP)")
            return .json(["ok": true])
        case ("POST", "bans/remove"):
            server.unban(ip: (req.json()["ip"] as? String) ?? "", actor: "admin@\(req.remoteIP)")
            return .json(["ok": true])
        case ("GET", "update"): return .json(updateJSON())
        case ("POST", "update/check"):
            updates.check()
            return .json(updateJSON())
        case ("POST", "update/apply"):
            let r = updates.apply()
            return r.ok ? .json(["ok": true, "message": r.message]) : .error(r.message, status: 500)
        case ("POST", "autostart"):
            let on = (req.json()["enabled"] as? Bool) ?? false
            let r = PlatformTools.setAutostart(on, paths: store.paths)
            return r.ok ? .json(["ok": true, "message": r.message]) : .error(r.message, status: 500)
        case ("POST", "shutdown"):
            log.info("Shutdown requested from the admin panel.")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.onShutdown?() }
            return .json(["ok": true])
        default: return .error("Not found.", status: 404)
        }
    }

    // MARK: JSON builders

    private func playerJSON(_ p: GameServer.Player) -> [String: Any] {
        var d: [String: Any] = ["id": p.id, "name": p.name, "ip": p.ip, "pingMs": p.pingMs,
                                "joinedAt": ISO8601DateFormatter().string(from: p.joinedAt), "seconds": Int(Date().timeIntervalSince(p.joinedAt))]
        if let s = p.systemID { d["systemID"] = s }
        let mutes = store.config.mutes
        d["muted"] = mutes["ip:\(p.ip)"] != nil || mutes["name:\(p.name.lowercased())"] != nil
        return d
    }

    static func intValue(_ v: Any?) -> Int? { (v as? Int) ?? (v as? Double).map(Int.init) }

    func moderationJSON() -> [String: Any] {
        let c = store.config
        return [
            "mutes": c.mutes.sorted { $0.key < $1.key }.map { ["key": $0.key, "note": $0.value] },
            "allowlist": c.allowlist.sorted { $0.key < $1.key }.map { ["ip": $0.key, "note": $0.value] },
            "allowlistMode": c.allowlistMode,
            "tempBans": server.tempBans.sorted { $0.key < $1.key }.map { ["ip": $0.key, "seconds": Int($0.value)] },
        ]
    }

    func bestAddress() -> (host: String, source: String) {
        let cfg = store.config
        if !cfg.publicAddress.isEmpty { return (cfg.publicAddress, "set in Settings") }
        lock.lock(); let cached = cachedPublicIP; lock.unlock()
        if let ip = cached?.ip { return (ip, "your public address") }
        if let l = NetworkTools.localAddresses().first(where: { $0.kind == "lan" }) { return (l.ip, "this computer on your home network") }
        return ("localhost", "this computer")
    }

    func statusJSON() -> [String: Any] {
        let cfg = store.config
        let stats = server.snapshot()
        let (host, source) = bestAddress()
        let addr = CrossPlayAddress(host: host, port: cfg.port).formatted
        let m = server.manifest
        var stateText = "Running"
        var running = false
        switch server.state { case .running: running = true; case .stopped: stateText = "Stopped"; case .failed(let m): stateText = m }
        let upd = updates.current
        lock.lock(); let restart = restartRequired; lock.unlock()
        return [
            "name": cfg.name, "version": ServerVersion.current, "protocol": CrossPlayProtocol.version, "gameVersion": CrossPlayProtocol.appVersion,
            "running": running, "stateText": stateText, "uptime": Int(server.uptime),
            "players": server.playerCount, "maxPlayers": cfg.maxPlayers, "peakPlayers": stats.peakPlayers, "joins": stats.totalJoins, "refusals": stats.refusals,
            "bytesSent": stats.bytesSent, "bytesReceived": stats.bytesReceived, "outBps": Int(stats.outBytesPerSec), "inBps": Int(stats.inBytesPerSec),
            "address": addr, "addressSource": source, "gamePort": cfg.port, "queryPort": CrossPlayProtocol.queryPort(forGamePort: cfg.port),
            "rules": CrossPlayProtocol.presetName(cfg.sessionRules), "passwordSet": !cfg.password.isEmpty,
            "requiredPlugins": m.requirements.plugins.map { $0.name }, "optionalPlugins": m.all.cosmetic.map { $0.name }, "missingPlugins": m.missing,
            "adminExposed": cfg.adminBind != "127.0.0.1", "adminPort": cfg.adminPort, "setupDone": cfg.setupDone,
            "platform": "\(PlatformTools.platformName)-\(PlatformTools.archName)", "dataFolder": store.paths.root.path,
            "update": ["available": upd.available, "latest": upd.latest as Any, "url": upd.pageURL],
            "recentRefusals": Array(server.refusals.suffix(5)), "restartRequired": restart,
            "supervised": PlatformTools.isSupervised,
        ]
    }

    func settingsJSON() -> [String: Any] {
        let c = store.config
        return [
            "name": c.name, "description": c.description, "port": c.port, "maxPlayers": c.maxPlayers, "password": c.password, "motd": c.motd,
            "region": c.region, "regions": ServerConfig.regions, "lanAnnounce": c.lanAnnounce, "upnp": c.upnp,
            "rulesPreset": c.rulesPreset, "pvpDamageReal": c.pvpDamageReal, "deathReal": c.deathReal, "friendlyFire": c.friendlyFire,
            "allowPvP": c.allowPvP, "allowTrade": c.allowTrade, "gameSpeed": c.gameSpeed,
            "adminPort": c.adminPort, "adminBind": c.adminBind,
            "publicListed": c.publicListed, "publicAddress": c.publicAddress, "ownerName": c.ownerName, "ownerContact": c.ownerContact, "website": c.website,
            "checkForUpdates": c.checkForUpdates, "autoUpdate": c.autoUpdate,
            "voteKick": c.voteKick, "voteKickPercent": c.voteKickPercent, "allowlistMode": c.allowlistMode,
            "wordFilter": c.wordFilter.joined(separator: ", "), "maxConnectionsPerIP": c.maxConnectionsPerIP, "announceJoins": c.announceJoins,
            "autostart": autostartJSON(),
        ]
    }

    func autostartJSON() -> [String: Any] {
        let a = PlatformTools.autostartStatus(paths: store.paths)
        return ["supported": a.supported, "enabled": a.enabled, "method": a.method, "note": a.note]
    }

    private func saveSettings(_ b: [String: Any]) -> HTTPResponse {
        let old = store.config
        var new = old
        func s(_ k: String, _ set: (String) -> Void) { if let v = b[k] as? String { set(v.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        func i(_ k: String, _ set: (Int) -> Void) {
            if let v = b[k] as? Int { set(v) } else if let v = b[k] as? Double { set(Int(v)) } else if let v = b[k] as? String, let n = Int(v) { set(n) }
        }
        func bl(_ k: String, _ set: (Bool) -> Void) { if let v = b[k] as? Bool { set(v) } }
        s("name") { new.name = $0 }; s("description") { new.description = $0 }; i("port") { new.port = $0 }
        i("maxPlayers") { new.maxPlayers = $0 }
        if let pw = b["password"] as? String { new.password = pw }
        s("motd") { new.motd = $0 }; s("region") { new.region = $0.lowercased() }
        bl("lanAnnounce") { new.lanAnnounce = $0 }; bl("upnp") { new.upnp = $0 }
        s("rulesPreset") { new.rulesPreset = $0.lowercased() }
        bl("pvpDamageReal") { new.pvpDamageReal = $0 }; bl("deathReal") { new.deathReal = $0 }; bl("friendlyFire") { new.friendlyFire = $0 }
        bl("allowPvP") { new.allowPvP = $0 }; bl("allowTrade") { new.allowTrade = $0 }
        if let v = b["gameSpeed"] as? Double { new.gameSpeed = v } else if let v = b["gameSpeed"] as? Int { new.gameSpeed = Double(v) }
        i("adminPort") { new.adminPort = $0 }; s("adminBind") { new.adminBind = $0 }
        bl("publicListed") { new.publicListed = $0 }; s("publicAddress") { new.publicAddress = $0 }
        s("ownerName") { new.ownerName = $0 }; s("ownerContact") { new.ownerContact = $0 }; s("website") { new.website = $0 }
        bl("checkForUpdates") { new.checkForUpdates = $0 }; bl("autoUpdate") { new.autoUpdate = $0 }
        bl("voteKick") { new.voteKick = $0 }; bl("allowlistMode") { new.allowlistMode = $0 }; bl("announceJoins") { new.announceJoins = $0 }
        i("voteKickPercent") { new.voteKickPercent = $0 }; i("maxConnectionsPerIP") { new.maxConnectionsPerIP = $0 }
        if let w = b["wordFilter"] as? String { new.wordFilter = w.split(separator: ",").map { String($0) } }
        let problems = new.problems()
        if !problems.isEmpty { return .json(["error": problems.joined(separator: " "), "problems": problems], status: 400) }
        try? store.update { $0 = new }
        let report = server.apply(old: old, new: store.config)
        if !report.needsRestart.isEmpty { lock.lock(); restartRequired = Array(Set(restartRequired + report.needsRestart)); lock.unlock() }
        if let e = report.error { return .json(["error": e], status: 409) }
        if new.upnp && !old.upnp { DispatchQueue.global().async { [weak self] in self?.tryUPnPNow() } }
        return .json(["ok": true, "applied": report.applied, "restartedNetwork": report.restartedNetwork, "needsRestart": report.needsRestart,
                      "settings": settingsJSON()])
    }

    public func tryUPnPNow() {
        let cfg = store.config
        let r = NetworkTools.tryUPnP(ports: [cfg.port, CrossPlayProtocol.queryPort(forGamePort: cfg.port)])
        lock.lock(); upnpResult = r; lock.unlock()
        log.info("UPnP: \(r.message)")
    }

    func pluginsJSON() -> [String: Any] {
        let cfg = store.config
        let cat = plugins.catalog
        let installed = plugins.installed()
        let byID = Dictionary(installed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let jobs = Dictionary(plugins.activeJobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func jobJSON(_ id: String) -> Any {
            guard let j = jobs[id] else { return NSNull() }
            return ["state": j.state.rawValue, "progress": j.progress as Any, "message": j.message]
        }
        let catalogRows: [[String: Any]] = cat.entries.map { e in
            let inst = byID[e.id]
            return ["id": e.id, "name": e.name, "author": e.author, "version": e.version, "summary": e.summary, "tags": e.tags,
                    "totalConversion": e.isTotalConversion, "sizeBytes": e.sizeBytes as Any, "homepage": e.homepageURL?.absoluteString as Any,
                    "installed": inst != nil, "enabled": cfg.enabledPlugins.contains(e.id), "cosmetic": inst?.cosmetic as Any,
                    "job": jobJSON(e.id), "dependencies": e.dependencies, "popularity": e.popularity]
        }
        let catalogIDs = Set(cat.entries.map(\.id))
        let local: [[String: Any]] = installed.filter { !catalogIDs.contains($0.id) || !$0.fromCatalog }.map { p in
            ["id": p.id, "name": p.name, "totalConversion": p.isTotalConversion, "cosmetic": p.cosmetic, "enabled": cfg.enabledPlugins.contains(p.id),
             "sizeBytes": p.sizeBytes, "fromCatalog": p.fromCatalog, "hash": String(p.contentHash.prefix(12))]
        }
        let enabledRows: [[String: Any]] = cfg.enabledPlugins.map { id in
            let inst = byID[id]
            return ["id": id, "name": inst?.name ?? cat.entries.first { $0.id == id }?.name ?? id, "installed": inst != nil,
                    "role": inst == nil ? "pending" : (inst!.cosmetic ? "optional" : "required"), "fromCatalog": inst?.fromCatalog ?? catalogIDs.contains(id),
                    "job": jobJSON(id), "totalConversion": inst?.isTotalConversion ?? false]
        }
        return ["catalog": catalogRows, "local": local, "enabled": enabledRows, "catalogSource": cat.source, "catalogError": cat.error as Any,
                "signature": server.manifest.all.gameplayOnly.signature]
    }

    private func upload(_ req: HTTPRequest) -> HTTPResponse {
        let name = req.query["name"] ?? "plugin.zip"
        let file: URL
        var cleanup = false
        if let f = req.bodyFile { file = f } else {
            guard !req.body.isEmpty else { return .error("No file received.") }
            file = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)-\(PluginManager.sanitizeID(name))")
            do { try req.body.write(to: file) } catch { return .error("Couldn't save the upload: \(error.localizedDescription)", status: 500) }
            cleanup = true
        }
        defer { if cleanup { try? FileManager.default.removeItem(at: file) } }
        do {
            let id = try plugins.addLocal(file: file, originalName: name)
            let old = store.config
            try? store.update { if !$0.enabledPlugins.contains(id) { $0.enabledPlugins.append(id) } }
            _ = server.apply(old: old, new: store.config)
            var out = pluginsJSON()
            out["added"] = id
            out["note"] = "Added \"\(id)\". It isn't in the NovaSwift catalog, so players will have to get this file themselves - tell them where."
            return .json(out)
        } catch let e as PluginInstallError {
            return .error(e.errorDescription ?? "That file couldn't be installed.")
        } catch {
            return .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func publicJSON() -> [String: Any] {
        let cfg = store.config
        let (host, _) = bestAddress()
        let entry = PublicListing.entry(config: cfg, manifest: server.manifest, host: host)
        let text = PublicListing.pretty(entry)
        var checks: [[String: Any]] = []
        checks.append(["ok": !cfg.publicAddress.isEmpty, "text": "A public address is set (a DNS name or IP address players can reach).", "fix": "Set \"Public address\" below."])
        checks.append(["ok": !cfg.ownerName.isEmpty && !cfg.ownerContact.isEmpty, "text": "Owner name and a contact (Discord, email) are filled in.", "fix": "Fill in the owner fields below."])
        checks.append(["ok": !cfg.description.isEmpty, "text": "The server has a description.", "fix": "Add one in Settings."])
        checks.append(["ok": cfg.password.isEmpty, "text": "No password (listed servers should be joinable by anyone).", "fix": "Remove the password in Settings, or keep the server unlisted."])
        return ["listed": cfg.publicListed, "entry": text, "checks": checks,
                "readme": CrossPlayProtocol.directoryHelpURL.absoluteString,
                "editURL": "https://github.com/SirStig/NovaSwift-Plugins/edit/main/servers/servers.json",
                "directoryURL": "https://github.com/SirStig/NovaSwift-Plugins/tree/main/servers"]
    }

    func networkJSON() -> [String: Any] {
        let cfg = store.config
        lock.lock(); let pub = cachedPublicIP; let up = upnpResult; lock.unlock()
        let locals = NetworkTools.localAddresses()
        let cgnat = pub?.ip.map { NetworkTools.isCGNAT($0) } ?? false
        return [
            "gamePort": cfg.port, "queryPort": CrossPlayProtocol.queryPort(forGamePort: cfg.port), "protocol": "UDP",
            "local": locals.map { ["interface": $0.interface, "ip": $0.ip, "kind": $0.kind] },
            "publicIP": pub?.ip as Any, "publicChecked": pub != nil, "cgnat": cgnat,
            "upnp": up.map { ["ok": $0.ok, "message": $0.message, "externalIP": $0.externalIP as Any] } as Any,
            "tailscale": locals.first { $0.kind == "tailscale" }?.ip as Any,
            "adminBind": cfg.adminBind,
        ]
    }

    func updateJSON() -> [String: Any] {
        let i = updates.current
        return ["current": i.current, "latest": i.latest as Any, "available": i.available, "url": i.pageURL, "assetURL": i.assetURL as Any,
                "notes": i.notes, "error": i.error as Any, "checkedAt": i.checkedAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "canAutoApply": i.assetURL != nil && i.manifestURL != nil && i.signatureURL != nil, "signed": i.manifestURL != nil && i.signatureURL != nil, "supervised": PlatformTools.isSupervised, "asset": PlatformTools.releaseAssetName]
    }
}

/// The entry to paste into `servers/servers.json` of SirStig/NovaSwift-Plugins.
public enum PublicListing {
    public static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let joined = String(s).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "novaswift-server" : String(joined.prefix(48))
    }

    public static func entry(config c: ServerConfig, manifest m: PluginManager.Manifest, host: String, now: Date = Date()) -> [String: Any] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        var e: [String: Any] = [
            "id": slug(c.name), "name": c.name, "host": c.publicAddress.isEmpty ? host : c.publicAddress, "port": c.port,
            "region": c.region, "description": c.description,
            "owner": ["name": c.ownerName, "contact": c.ownerContact],
            "rules": CrossPlayProtocol.presetName(c.sessionRules),
            "plugins": m.requirements.plugins.map { ["id": $0.id, "name": $0.name, "contentHash": String($0.contentHash.prefix(PluginRequirements.wireHashLength))] },
            "maxPlayers": c.maxPlayers, "added": f.string(from: now),
        ]
        if !c.website.isEmpty { e["website"] = c.website }
        if let tc = m.requirements.totalConversion { e["totalConversion"] = tc; e["tcAddons"] = m.requirements.addOns }
        return e
    }

    public static func pretty(_ entry: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }
}
