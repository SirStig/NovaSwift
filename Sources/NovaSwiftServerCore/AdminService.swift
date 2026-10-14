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
    private var failures: [String: (count: Int, until: Date)] = [:]
    /// One-time link that signs you in from this computer until the first-run wizard is done.
    public private(set) var setupCode: String?
    private var cachedPublicIP: (ip: String?, at: Date)?
    private var upnpResult: NetworkTools.UPnPResult?
    private var restartRequired: [String] = []
    public var onShutdown: (() -> Void)?

    public init(server: GameServer, updates: UpdateChecker) {
        self.server = server; store = server.store; log = server.log; plugins = server.plugins; self.updates = updates
        if !store.config.setupDone { setupCode = (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }
    }

    func setCachedPublicIP(_ ip: String?) { lock.lock(); cachedPublicIP = (ip, Date()); lock.unlock() }

    // MARK: Entry point

    public func handle(_ req: HTTPRequest) -> HTTPResponse {
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
        sessions[token] = Date().addingTimeInterval(7 * 86400)
        sessions = sessions.filter { $0.value > Date() }
        lock.unlock()
        var r = HTTPResponse.json(["ok": true])
        r.headers["Set-Cookie"] = "nsadmin=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(7 * 86400)"
        return r
    }

    private func throttled(_ ip: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        if let f = failures[ip], f.count >= 5, f.until > Date() { return Int(f.until.timeIntervalSinceNow.rounded(.up)) }
        return nil
    }

    private func noteFailure(_ ip: String) {
        lock.lock(); defer { lock.unlock() }
        var f = failures[ip] ?? (0, Date())
        if f.until < Date() && f.count >= 5 { f.count = 0 }
        f.count += 1; f.until = Date().addingTimeInterval(60)
        failures[ip] = f
    }

    // MARK: API router

    private func api(_ req: HTTPRequest) -> HTTPResponse {
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
                return newSession(req)
            }
            noteFailure(req.remoteIP)
            return .error("That password isn't right. The admin password was printed in the console the first time the server started.", status: 401)
        case ("POST", "setup-login"):
            let code = (req.json()["code"] as? String) ?? ""
            if let sc = setupCode, req.isLoopback, !code.isEmpty, code == sc { return newSession(req) }
            return .error("That setup link is no longer valid. Sign in with the admin password instead.", status: 401)
        default: break
        }
        guard isAuthed(req) else { return .error("Please sign in.", status: 401) }
        switch (req.method, route) {
        case ("POST", "logout"):
            if let t = req.cookies["nsadmin"] { lock.lock(); sessions[t] = nil; lock.unlock() }
            var r = HTTPResponse.json(["ok": true]); r.headers["Set-Cookie"] = "nsadmin=; Path=/; Max-Age=0"; return r
        case ("GET", "status"): return .json(statusJSON())
        case ("GET", "players"): return .json(["players": server.players().map(playerJSON)])
        case ("POST", "players/kick"):
            let b = req.json()
            guard let id = (b["id"] as? Int) ?? (b["id"] as? Double).map(Int.init) else { return .error("Which player?") }
            let ban = (b["ban"] as? Bool) ?? false
            let reason = ((b["reason"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let ok = server.kick(id, reason: reason.isEmpty ? (ban ? "Banned by the server admin." : "Removed by the server admin.") : reason, ban: ban)
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
            guard next.count >= 8 else { return .error("Pick a password with at least 8 characters.") }
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
            server.ban(ip: ip, note: (b["note"] as? String) ?? "")
            return .json(["ok": true])
        case ("POST", "bans/remove"):
            server.unban(ip: (req.json()["ip"] as? String) ?? "")
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
        return d
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
                "canAutoApply": i.assetURL != nil, "supervised": PlatformTools.isSupervised, "asset": PlatformTools.releaseAssetName]
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
