import Foundation
import NovaSwiftNet
import NovaSwiftENet
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ServerOptions: Equatable {
    public var dataDir: String?
    public var noBrowser = false
    public var forceOpenBrowser = false
    public var noStdin = false
    public var port: Int?
    public var adminPort: Int?
    public var resetAdminPassword = false
    public var showHelp = false
    public var showVersion = false
    public var quiet = false
    public var errors: [String] = []

    public init() {}

    public static func parse(_ args: [String]) -> ServerOptions {
        var o = ServerOptions()
        var i = 0
        func value(_ name: String) -> String? {
            guard i + 1 < args.count else { o.errors.append("\(name) needs a value."); return nil }
            i += 1; return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--data", "--dir": o.dataDir = value(a)
            case "--no-browser": o.noBrowser = true
            case "--open": o.forceOpenBrowser = true
            case "--no-stdin": o.noStdin = true
            case "--port": if let v = value(a) { if let n = Int(v) { o.port = n } else { o.errors.append("--port needs a number.") } }
            case "--admin-port": if let v = value(a) { if let n = Int(v) { o.adminPort = n } else { o.errors.append("--admin-port needs a number.") } }
            case "--reset-admin-password": o.resetAdminPassword = true
            case "--help", "-h": o.showHelp = true
            case "--version", "-v": o.showVersion = true
            case "--quiet": o.quiet = true
            default: o.errors.append("Unknown option \(a). Try --help.")
            }
            i += 1
        }
        return o
    }

    public static let helpText = """
    NovaSwift Dedicated Server \(ServerVersion.current)

    Just run it: it creates server.cfg, opens a first-run setup page in your browser (or prints the address),
    and prints the admin password once. You do not need EV Nova or the game installed.

    Options (all optional):
      --data DIR              Where server.cfg, plugins/ and logs/ live (default: next to this program)
      --port N                Game port, UDP (default 53735; N+1 answers server-list pings)
      --admin-port N          Web admin panel port, TCP (default 53737)
      --no-browser            Don't open the browser (headless / service)
      --no-stdin              Don't read console commands (Docker, systemd)
      --reset-admin-password  Make a new admin password, print it and exit
      --version, --help

    Console commands while it runs: help, status, players, kick <id|name> [reason], ban <id|name>,
    unban <ip>, say <text>, rules [safe|full], plugins, quit
    """
}

/// Wires the server together: config, plug-ins, game server, admin panel, console, updates.
public final class ServerApp {
    public let options: ServerOptions
    public let store: ConfigStore
    public let log = ServerLog()
    public let plugins: PluginManager
    public let server: GameServer
    public let admin: AdminService
    public let updates: UpdateChecker
    public let audit: AuditLog
    private let publicIPLookup = DispatchGroup()
    public private(set) var http: HTTPServer?
    /// Set only when this run generated the admin password (first start or `--reset-admin-password`).
    public private(set) var generatedPassword: String?
    private var signalSources: [DispatchSourceSignal] = []
    private var updateTimer: DispatchSourceTimer?
    public var onExit: (() -> Void)?

    public init(options: ServerOptions, paths: ServerPaths? = nil) throws {
        self.options = options
        let p = paths ?? ServerPaths.resolve(explicit: options.dataDir)
        do { store = try ConfigStore(paths: p) } catch {
            throw ServerError("Can't use \(p.root.path) as the server folder (\(error.localizedDescription)). Pick another with --data FOLDER.")
        }
        log.attachFile(p.logFile)
        log.echoToConsole = !options.quiet
        if let port = options.port { try? store.update { $0.port = port } }
        if let ap = options.adminPort { try? store.update { $0.adminPort = ap } }
        if store.config.adminPasswordHash.isEmpty || options.resetAdminPassword {
            let pw = AdminPassword.generate()
            try? store.update { $0.adminPasswordHash = AdminPassword.hash(pw) }
            generatedPassword = pw
        }
        plugins = PluginManager(paths: p, log: log)
        audit = AuditLog(file: p.logsDir.appendingPathComponent("audit.log"))
        server = GameServer(store: store, log: log, plugins: plugins, audit: audit)
        updates = UpdateChecker(log: log)
        admin = AdminService(server: server, updates: updates)
    }

    /// Where the admin panel actually listens this run (the saved setting unless overridden by the environment).
    public private(set) var effectiveAdminBind = "127.0.0.1"

    public var adminURL: String { "http://localhost:\(store.config.adminPort)" }

    /// Start everything and return (non-blocking).
    public func start() throws {
        let cfg = store.config
        for w in store.warnings { log.warn("server.cfg: \(w)") }
        let problems = cfg.problems()
        for pr in problems { log.warn("server.cfg: \(pr)") }

        // The admin panel first: if the game port is busy you still need the panel to fix it.
        // NOVASWIFT_ADMIN_BIND overrides the saved address for this run only (a container must listen on 0.0.0.0 inside
        // while Docker publishes the port on the host's 127.0.0.1 only).
        var bind = cfg.adminBind
        if let e = ProcessInfo.processInfo.environment["NOVASWIFT_ADMIN_BIND"], ["0.0.0.0", "127.0.0.1"].contains(e) { bind = e }
        effectiveAdminBind = bind
        let h = HTTPServer(bind: bind, port: cfg.adminPort) { [admin] req in admin.handle(req) }
        h.uploadPaths = ["/api/plugins/upload"]
        h.tempDirectory = store.paths.cacheDir
        do { try h.start() } catch HTTPServer.StartError.inUse(let p) {
            throw ServerError("Port \(p) (the admin panel) is already in use - is another NovaSwift server running? Stop it, or start this one with --admin-port <another number>.")
        } catch HTTPServer.StartError.failed(let m) { throw ServerError(m) }
        http = h
        admin.onShutdown = { [weak self] in self?.shutdown() }

        plugins.refreshCatalog { [weak self] in self?.installMissingPlugins() }
        do { try server.start() } catch let e as ServerError {
            log.error(e.message)
            log.error("The admin panel is still running at \(adminURL) - open Settings to change the port.")
        }
        if bind != "127.0.0.1" && !PlatformTools.isContainer {
            log.warn("The admin panel is reachable from other computers over plain HTTP (no encryption). Use a long password, don't open port \(cfg.adminPort) in your firewall unless you must, or set the admin address to 127.0.0.1 and use an SSH tunnel.")
        }
        // Look up the public address in the background (short timeouts) for the dashboard and the start-up banner.
        publicIPLookup.enter()
        DispatchQueue.global().async { [admin, publicIPLookup] in
            admin.setPublicIP(NetworkTools.publicIP(timeout: 2))
            publicIPLookup.leave()
        }
        if cfg.upnp { DispatchQueue.global().async { [admin] in admin.tryUPnPNow() } }
        startUpdateChecks()
    }

    /// Download catalog plug-ins that are enabled but not installed yet (first run from an existing server.cfg, Docker).
    func installMissingPlugins() {
        var pending = 0
        for id in store.config.enabledPlugins where !plugins.isInstalled(id) {
            guard plugins.catalogEntry(id) != nil else { log.warn("Plug-in \"\(id)\" is enabled but isn't installed and isn't in the catalog. Add the file in the panel."); continue }
            pending += 1
            plugins.install(catalogID: id) { [weak self] _ in self?.server.refreshPlugins() }
        }
        if pending > 0 { log.info("Downloading \(pending) plug-in(s) the server needs...") }
    }

    private func startUpdateChecks() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())   // default QoS: libdispatch never needs to change thread priority (EACCES log noise under systemd)
        t.schedule(deadline: .now() + 20, repeating: 12 * 3600)
        t.setEventHandler { [weak self] in
            guard let self, self.store.config.checkForUpdates else { return }
            let info = self.updates.check()
            if info.available, self.store.config.autoUpdate {
                let r = self.updates.apply()
                self.log.info(r.message)
                if r.ok, PlatformTools.isSupervised { self.log.info("Restarting to use the new version..."); self.shutdown() }
            }
        }
        t.resume()
        updateTimer = t
    }

    // MARK: Banner / blocking run

    public func bannerText() -> String {
        let cfg = store.config
        return Self.banner(cfg: cfg, join: admin.joinAddresses(), adminURL: adminURL, adminLocalOnly: effectiveAdminBind == "127.0.0.1",
                           dataFolder: store.paths.root.path, password: generatedPassword, setupCode: admin.setupCode)
    }

    /// The start-up banner. `join` is what players type: the public address when it is known, else a placeholder with the
    /// LAN address labelled as such (a private address is useless to players on the internet).
    static func banner(cfg: ServerConfig, join: (public: String?, lan: String?), adminURL: String, adminLocalOnly: Bool,
                       dataFolder: String, password: String?, setupCode: String?) -> String {
        let joinLine: String
        if let pub = join.public {
            joinLine = CrossPlayAddress(host: pub, port: cfg.port).formatted
        } else {
            joinLine = "your public IP\(cfg.port == CrossPlayProtocol.defaultPort ? "" : ":\(cfg.port)")"
                + (join.lan.map { "   (LAN: \(CrossPlayAddress(host: $0, port: cfg.port).formatted))" } ?? "")
        }
        var s = """

        ============================================================
          NovaSwift Dedicated Server \(ServerVersion.current)
        ============================================================
          Server name  : \(cfg.name)
          Players join : \(joinLine)   (UDP \(cfg.port), \(cfg.maxPlayers) slots)
          Admin panel  : \(adminURL)\(adminLocalOnly ? "   (this computer only)" : "")
          Data folder  : \(dataFolder)

        """
        if let pw = password {
            s += """
              ADMIN PASSWORD (shown only this once - write it down):

                  \(pw)

              Lost it later?  run with --reset-admin-password

            """
        }
        if let code = setupCode {
            s += "  First-time setup: \(adminURL)/?setup=\(code)\n"
        }
        s += "  Type 'help' for console commands, Ctrl-C to stop.\n============================================================\n"
        return s
    }

    /// Print the banner, open the browser on first run, install signal handlers and block until shutdown.
    public func run() -> Never {
        do { try start() } catch {
            FileHandle.standardError.write(Data("\n\((error as? ServerError)?.message ?? error.localizedDescription)\n".utf8))
            exit(1)
        }
        _ = publicIPLookup.wait(timeout: .now() + 3)   // the banner shows the public address when the lookup is quick
        print(bannerText())
        if !options.noBrowser, let code = admin.setupCode ?? (options.forceOpenBrowser ? "" : nil), PlatformTools.hasDesktop {
            PlatformTools.openBrowser(code.isEmpty ? adminURL : "\(adminURL)/?setup=\(code)")
        }
        installSignalHandlers()
        if !options.noStdin { startConsole() }
        dispatchMain()
    }

    func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.shutdown() }
            src.resume()
            signalSources.append(src)
        }
    }

    public func shutdown() {
        log.info("Shutting down...")
        server.say("The server is shutting down.")
        Thread.sleep(forTimeInterval: 0.3)
        server.stop()
        http?.stop()
        onExit?()
        exit(0)
    }

    private func startConsole() {
        let t = Thread { [weak self] in
            while let line = readLine() {
                guard let self else { return }
                let out = ConsoleCommands.run(line, app: self)
                if !out.isEmpty { print(out) }
            }
            // stdin closed (service, Docker without -it): keep serving.
        }
        t.name = "novaswift.console"
        t.start()
    }
}

extension AdminService {

    /// Remember the public IP (looked up in the background at start).
    public func setPublicIP(_ ip: String?) { setCachedPublicIP(ip) }
}

/// Console commands: status, players, kick, ban, unban, say, rules, plugins, quit, help.
public enum ConsoleCommands {
    public static func run(_ line: String, app: ServerApp) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts[0].lowercased()
        let rest = parts.count > 1 ? parts[1] : ""
        let server = app.server
        switch cmd {
        case "help", "?":
            return """
            status                  server name, uptime, players, address
            players                 who is connected (id, name, ping, address)
            kick <id|name> [why]    remove a player
            ban <id|name>           remove a player and block their address
            unban <ip>              lift a ban
            say <text>              announce to everyone in chat
            rules [safe|full]       show the rules, or switch preset
            mute <id|name>          hide a player's chat from everyone
            unmute <name|ip>        lift a mute
            allow <ip> / disallow <ip>   invite-only list (used when allowlist_mode is on)
            tempbans                addresses blocked for a while after abuse
            audit                   recent admin actions
            plugins                 required and optional plug-ins
            quit                    stop the server
            """
        case "status":
            let cfg = app.store.config
            let (host, _) = app.admin.bestAddress()
            return "\(cfg.name) - \(server.state == .running ? "running" : "NOT running"), up \(duration(server.uptime)), players \(server.playerCount)/\(cfg.maxPlayers), rules \(CrossPlayProtocol.presetName(cfg.sessionRules)), join at \(CrossPlayAddress(host: host, port: cfg.port).formatted), admin \(app.adminURL)"
        case "players":
            let list = server.players()
            if list.isEmpty { return "No players online." }
            return list.map { "\($0.id)\t\($0.name)\t\($0.pingMs >= 0 ? "\($0.pingMs) ms" : "-")\t\($0.ip)" }.joined(separator: "\n")
        case "kick", "ban":
            let words = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = words.first, let p = server.findPlayer(key) else { return "No player matches \"\(rest)\". Use 'players' to see ids." }
            let why = words.count > 1 ? words[1] : ""
            server.kick(p.id, reason: why.isEmpty ? "Removed by the server admin." : why, ban: cmd == "ban")
            return "\(cmd == "ban" ? "Banned" : "Kicked") \(p.name)."
        case "unban":
            guard NetworkTools.octets(rest.trimmingCharacters(in: .whitespaces)) != nil else { return "Usage: unban <ip address>" }
            server.unban(ip: rest.trimmingCharacters(in: .whitespaces)); return "Unbanned \(rest)."
        case "say":
            guard !rest.isEmpty else { return "Usage: say <text>" }
            server.say(rest); return ""
        case "rules":
            let arg = rest.lowercased().trimmingCharacters(in: .whitespaces)
            if arg == "safe" || arg == "full" {
                let old = app.store.config
                try? app.store.update { $0.rulesPreset = arg }
                _ = server.apply(old: old, new: app.store.config)
                return "Rules are now \(arg) for everyone online."
            }
            let r = app.store.config.sessionRules
            return "Preset: \(CrossPlayProtocol.presetName(r)). PvP \(r.allowPvP ? "on" : "off"), real damage \(r.pvpDamageReal ? "on" : "off"), permadeath \(r.deathReal ? "on" : "off"), friendly fire \(r.friendlyFire ? "on" : "off"), trading \(r.allowTrade ? "on" : "off"), speed \(r.gameSpeedMultiplier)x. Change with: rules safe|full"
        case "mute":
            guard let p = server.mute(rest) else { return "No player matches \"\(rest)\". Use 'players' to see ids." }
            return "Muted \(p.name)."
        case "unmute":
            return server.unmute(rest) ? "Unmuted \(rest)." : "Nobody is muted as \"\(rest)\"."
        case "allow":
            guard NetworkTools.octets(rest.trimmingCharacters(in: .whitespaces)) != nil else { return "Usage: allow <ip address>" }
            server.allow(ip: rest.trimmingCharacters(in: .whitespaces)); return "Allowed \(rest)."
        case "disallow":
            server.disallow(ip: rest.trimmingCharacters(in: .whitespaces)); return "Removed \(rest) from the allowlist."
        case "tempbans":
            let t = server.tempBans
            return t.isEmpty ? "No addresses are blocked right now." : t.sorted { $0.key < $1.key }.map { "\($0.key)\t\(Int($0.value)) s left" }.joined(separator: "\n")
        case "audit":
            let e = app.audit.entries(limit: 20)
            return e.isEmpty ? "Nothing recorded yet." : e.map { "\($0.actor) \($0.action) \($0.detail)" }.joined(separator: "\n")
        case "plugins":
            let m = server.manifest
            var out = "Required: " + (m.requirements.plugins.isEmpty ? "none (stock game)" : m.requirements.plugins.map(\.name).joined(separator: ", "))
            if !m.all.cosmetic.isEmpty { out += "\nOptional (art/sound only): " + m.all.cosmetic.map(\.name).joined(separator: ", ") }
            if !m.missing.isEmpty { out += "\nNot installed yet: " + m.missing.joined(separator: ", ") }
            return out
        case "quit", "exit", "stop":
            app.shutdown(); return ""
        default:
            return "Unknown command \"\(cmd)\". Type 'help'."
        }
    }

    static func duration(_ s: TimeInterval) -> String {
        let t = Int(s)
        if t >= 86400 { return "\(t / 86400)d \(t % 86400 / 3600)h" }
        if t >= 3600 { return "\(t / 3600)h \(t % 3600 / 60)m" }
        return "\(t / 60)m \(t % 60)s"
    }
}

public enum NovaSwiftServerCore {
    public static var protocolNumber: Int { CrossPlayProtocol.version }
}
