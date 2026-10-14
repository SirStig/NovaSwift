import Foundation
import NovaSwiftNet
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Everything the admin can set, stored in one `server.cfg` (INI style, commented). The file is regenerated from
/// this struct whenever the panel saves, so hand edits are kept but your own comments are not.
public struct ServerConfig: Equatable {
    public static let defaultGamePort = CrossPlayProtocol.defaultPort
    public static let defaultAdminPort = 53737
    public static let regions = ServerDirectory.regions

    // [server]
    public var name = ""
    public var description = ""
    public var port = defaultGamePort
    public var maxPlayers = 8
    public var password = ""
    public var motd = ""
    public var region = "global"
    /// Answer LAN beacons / pings so the server shows up under "LAN" for people on the same network.
    public var lanAnnounce = true
    /// Ask the router to forward the game port (UPnP) on start.
    public var upnp = false

    // [rules]
    /// "safe", "full" or "custom".
    public var rulesPreset = "safe"
    public var pvpDamageReal = false
    public var deathReal = false
    public var friendlyFire = false
    public var allowPvP = true
    public var allowTrade = true
    public var gameSpeed = 1.0

    // [admin]
    public var adminPort = defaultAdminPort
    /// "0.0.0.0" (everyone who can reach the port) or "127.0.0.1" (this computer only).
    public var adminBind = "0.0.0.0"
    public var adminPasswordHash = ""
    /// The first-run wizard has been completed (or skipped).
    public var setupDone = false

    // [plugins]
    /// Enabled plug-in ids: catalog ids and the names of locally added folders. Gameplay ones are required of players;
    /// cosmetic-only ones are listed as optional automatically.
    public var enabledPlugins: [String] = []

    // [public]
    public var publicListed = false
    /// Public DNS name or IP players use to reach the server (for the directory entry).
    public var publicAddress = ""
    public var ownerName = ""
    public var ownerContact = ""
    public var website = ""

    // [updates]
    public var checkForUpdates = true
    public var autoUpdate = false

    // [bans]  ip -> note
    public var bans: [String: String] = [:]

    public init() {}

    /// Defaults for a brand-new install: a friendly generated name.
    public static func fresh(hostname: String = ServerConfig.machineName()) -> ServerConfig {
        var c = ServerConfig()
        c.name = defaultName(hostname: hostname)
        return c
    }

    /// "<host>'s NovaSwift server" when it fits the 24-character name limit, else shorter variants.
    public static func defaultName(hostname: String) -> String {
        let first = hostname.split(separator: ".").first.map(String.init) ?? hostname
        var h = first.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty || h.lowercased() == "localhost" { h = "My" }
        h = h.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        if let c = h.first, c.isLowercase { h = c.uppercased() + h.dropFirst() }
        for suffix in ["'s NovaSwift server", "'s NovaSwift", "'s server"] where h.count + suffix.count <= CrossPlayProtocol.maxNameLength {
            return h + suffix
        }
        let room = CrossPlayProtocol.maxNameLength - "'s server".count
        return String(h.prefix(room)).trimmingCharacters(in: .whitespaces) + "'s server"
    }

    public static func machineName() -> String { ProcessInfo.processInfo.hostName }

    // MARK: Rules

    public var sessionRules: SessionRules {
        switch rulesPreset {
        case "safe": var r = SessionRules.safe; r.gameSpeedMultiplier = gameSpeed; return r
        case "full": var r = SessionRules.fullStakes; r.gameSpeedMultiplier = gameSpeed; return r
        default:
            return SessionRules(pvpDamageReal: pvpDamageReal, deathReal: deathReal, friendlyFire: friendlyFire,
                                allowPvP: allowPvP, allowTrade: allowTrade, carryEncounter: deathReal,
                                gameSpeedMultiplier: gameSpeed)
        }
    }

    // MARK: Validation

    /// Plain-language problems; empty when the config can run. Values are clamped by `normalized()` first.
    public func problems() -> [String] {
        var out: [String] = []
        if !(1024...65534).contains(port) { out.append("The game port must be between 1024 and 65534 (it also uses the next port up for pings).") }
        if !(1024...65535).contains(adminPort) { out.append("The admin panel port must be between 1024 and 65535.") }
        if adminPort == port || adminPort == port + 1 { out.append("The admin panel port (\(adminPort)) clashes with the game ports (\(port) and \(port + 1)). Pick another one.") }
        if !(1...64).contains(maxPlayers) { out.append("Max players must be between 1 and 64.") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("The server needs a name.") }
        if !["safe", "full", "custom"].contains(rulesPreset) { out.append("Rules must be safe, full or custom.") }
        if !(0.25...4.0).contains(gameSpeed) { out.append("Game speed must be between 0.25 and 4.") }
        if !["0.0.0.0", "127.0.0.1"].contains(adminBind) { out.append("The admin bind address must be 0.0.0.0 (anyone who can reach it) or 127.0.0.1 (this computer only).") }
        return out
    }

    /// Clamp values into range so a typo never stops the server from starting.
    public func normalized() -> ServerConfig {
        var c = self
        c.name = CrossPlayProtocol.cleanName(c.name, fallback: ServerConfig.defaultName(hostname: ServerConfig.machineName()))
        c.description = String(c.description.filter { !$0.isNewline }.prefix(300))
        c.motd = String(c.motd.filter { !$0.isNewline }.prefix(200))
        c.maxPlayers = min(64, max(1, c.maxPlayers))
        if !(1024...65534).contains(c.port) { c.port = Self.defaultGamePort }
        if !(1024...65535).contains(c.adminPort) { c.adminPort = Self.defaultAdminPort }
        if !["safe", "full", "custom"].contains(c.rulesPreset) { c.rulesPreset = "safe" }
        c.gameSpeed = min(4.0, max(0.25, c.gameSpeed))
        if !["0.0.0.0", "127.0.0.1"].contains(c.adminBind) { c.adminBind = "0.0.0.0" }
        if !Self.regions.contains(c.region) { c.region = "global" }
        var seen = Set<String>()
        c.enabledPlugins = c.enabledPlugins.filter { !$0.isEmpty && seen.insert($0).inserted }
        return c
    }

    // MARK: Parse

    /// Parse INI text. Unknown keys and bad values are reported in `warnings` and skipped, never fatal.
    public static func parse(_ text: String) -> (config: ServerConfig, warnings: [String]) {
        var c = ServerConfig()
        var warnings: [String] = []
        var section = ""
        var lineNo = 0
        func bool(_ v: String, _ key: String) -> Bool? {
            switch v.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: warnings.append("\(key): expected true or false, got \"\(v)\" (ignored)"); return nil
            }
        }
        func int(_ v: String, _ key: String) -> Int? {
            if let i = Int(v) { return i }
            warnings.append("\(key): expected a number, got \"\(v)\" (ignored)"); return nil
        }
        for raw in text.components(separatedBy: .newlines) {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else { warnings.append("line \(lineNo): missing ] (ignored)"); continue }
                section = String(line[line.index(after: line.startIndex)..<close]).lowercased()
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { warnings.append("line \(lineNo): expected key = value (ignored)"); continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            let k = "\(section).\(key.lowercased())"
            switch k {
            case "server.name": c.name = value
            case "server.description": c.description = value
            case "server.port": if let i = int(value, k) { c.port = i }
            case "server.max_players": if let i = int(value, k) { c.maxPlayers = i }
            case "server.password": c.password = value
            case "server.motd": c.motd = value
            case "server.region": c.region = value.lowercased()
            case "server.lan_announce": if let b = bool(value, k) { c.lanAnnounce = b }
            case "server.upnp": if let b = bool(value, k) { c.upnp = b }
            case "rules.preset": c.rulesPreset = value.lowercased()
            case "rules.pvp_damage_real": if let b = bool(value, k) { c.pvpDamageReal = b }
            case "rules.death_real": if let b = bool(value, k) { c.deathReal = b }
            case "rules.friendly_fire": if let b = bool(value, k) { c.friendlyFire = b }
            case "rules.allow_pvp": if let b = bool(value, k) { c.allowPvP = b }
            case "rules.allow_trade": if let b = bool(value, k) { c.allowTrade = b }
            case "rules.game_speed":
                if let d = Double(value) { c.gameSpeed = d } else { warnings.append("\(k): expected a number (ignored)") }
            case "admin.port": if let i = int(value, k) { c.adminPort = i }
            case "admin.bind": c.adminBind = value
            case "admin.password_hash": c.adminPasswordHash = value
            case "admin.setup_done": if let b = bool(value, k) { c.setupDone = b }
            case "plugins.enabled":
                c.enabledPlugins = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "public.listed": if let b = bool(value, k) { c.publicListed = b }
            case "public.address": c.publicAddress = value
            case "public.owner": c.ownerName = value
            case "public.contact": c.ownerContact = value
            case "public.website": c.website = value
            case "updates.check": if let b = bool(value, k) { c.checkForUpdates = b }
            case "updates.auto_update": if let b = bool(value, k) { c.autoUpdate = b }
            default:
                if section == "bans" { c.bans[key] = value } else { warnings.append("\(k): unknown setting (ignored)") }
            }
        }
        return (c, warnings)
    }

    // MARK: Render

    /// The commented file. Passwords are written as typed (the file is as private as the folder it sits in).
    public func render() -> String {
        func b(_ v: Bool) -> String { v ? "true" : "false" }
        var s = """
        # NovaSwift Dedicated Server - server.cfg
        #
        # You normally never need to edit this file: use the web admin panel (the address is printed when the
        # server starts, usually http://localhost:\(adminPort)). The panel rewrites this file when you save.
        # Lines starting with # are comments. Restart the server after editing by hand.

        [server]
        # What players see in the server list.
        name = \(name)
        description = \(description)
        # UDP port players connect to. The next port up (\(port + 1)) answers "ping" queries for the server list.
        port = \(port)
        # Player slots. The server itself does not use one.
        max_players = \(maxPlayers)
        # Leave empty for an open server.
        password = \(password)
        # A short message shown in chat to every player who joins.
        motd = \(motd)
        # na-east, na-west, sa, eu, af, me, as, oc or global (shown in the public list).
        region = \(region)
        # Show up for people on the same network (LAN) and answer pings.
        lan_announce = \(b(lanAnnounce))
        # Ask your router to forward the port automatically (works on many home routers).
        upnp = \(b(upnp))

        [rules]
        # safe   = players can fight but nothing is lost for real (sparring).
        # full   = damage and death are real, friendly fire on.
        # custom = use the switches below.
        preset = \(rulesPreset)
        # Only used when preset = custom:
        pvp_damage_real = \(b(pvpDamageReal))
        death_real = \(b(deathReal))
        friendly_fire = \(b(friendlyFire))
        allow_pvp = \(b(allowPvP))
        allow_trade = \(b(allowTrade))
        # 1.0 is normal game speed (0.25 to 4).
        game_speed = \(gameSpeed)

        [admin]
        # The web admin panel. 127.0.0.1 = only this computer; 0.0.0.0 = anyone who can reach the port.
        port = \(adminPort)
        bind = \(adminBind)
        # Set from the panel (Settings > Admin password). Never put your plain password here.
        password_hash = \(adminPasswordHash)
        setup_done = \(b(setupDone))

        [plugins]
        # Plug-ins the server runs, by id (comma separated). Players must have the gameplay ones; art/sound-only
        # plug-ins are detected automatically and are optional. Manage them from the panel (Plug-ins).
        enabled = \(enabledPlugins.joined(separator: ", "))

        [public]
        # Publishing is always manual: the panel generates the entry for the public server list.
        listed = \(b(publicListed))
        # The DNS name or IP address players type to reach you (for the public list).
        address = \(publicAddress)
        owner = \(ownerName)
        contact = \(ownerContact)
        website = \(website)

        [updates]
        check = \(b(checkForUpdates))
        # Download and install new server versions by itself (restart needed). Off by default.
        auto_update = \(b(autoUpdate))

        [bans]
        # Banned IP addresses, one per line:  1.2.3.4 = reason
        """
        for (ip, note) in bans.sorted(by: { $0.key < $1.key }) { s += "\n\(ip) = \(note)" }
        return s + "\n"
    }
}

// MARK: - Admin password hashing

public enum AdminPassword {
    static let rounds = 20_000

    /// "sha256i$<rounds>$<salt hex>$<hash hex>": salted, iterated SHA-256 (no external KDF dependency).
    public static func hash(_ password: String, salt: [UInt8]? = nil) -> String {
        let salt = salt ?? (0..<16).map { _ in UInt8.random(in: 0...255) }
        return "sha256i$\(rounds)$\(hex(salt))$\(hex(derive(password, salt: salt, rounds: rounds)))"
    }

    public static func verify(_ password: String, against stored: String) -> Bool {
        let parts = stored.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "sha256i", let n = Int(parts[1]), n > 0, n <= 1_000_000,
              let salt = unhex(parts[2]), let want = unhex(parts[3]) else { return false }
        let got = derive(password, salt: salt, rounds: n)
        return constantTimeEqual(got, want)
    }

    /// A readable random password (no look-alike characters), e.g. "kqxt-9w4m-ph7z".
    public static func generate() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        func group() -> String { String((0..<4).map { _ in alphabet.randomElement()! }) }
        return "\(group())-\(group())-\(group())"
    }

    static func derive(_ password: String, salt: [UInt8], rounds: Int) -> [UInt8] {
        var h = Array(SHA256.hash(data: Data(salt + Array(password.utf8))))
        for _ in 1..<max(1, rounds) { h = Array(SHA256.hash(data: Data(h + salt))) }
        return h
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    static func unhex(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out: [UInt8] = []; var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let v = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(v); i = j
        }
        return out
    }
}

// MARK: - Where the files live

/// The server's folder: `server.cfg`, `plugins/`, `logs/`, `cache/`. Zero-config choice: the folder the program sits in
/// (so a download you unzip is fully portable) when it can write there, else the platform's data folder.
public struct ServerPaths: Equatable {
    public var root: URL
    public var configFile: URL { root.appendingPathComponent("server.cfg") }
    public var pluginsDir: URL { root.appendingPathComponent("plugins", isDirectory: true) }
    public var logsDir: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var cacheDir: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public var logFile: URL { logsDir.appendingPathComponent("server.log") }

    public init(root: URL) { self.root = root }

    public func create() throws {
        let fm = FileManager.default
        for d in [root, pluginsDir, logsDir, cacheDir] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    /// `--data DIR` > `NOVASWIFT_SERVER_DIR` > next to the program (if writable) > platform data directory.
    public static func resolve(explicit: String? = nil, executable: URL? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> ServerPaths {
        if let explicit, !explicit.isEmpty { return ServerPaths(root: URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)) }
        if let e = environment["NOVASWIFT_SERVER_DIR"], !e.isEmpty { return ServerPaths(root: URL(fileURLWithPath: e, isDirectory: true)) }
        let exe = executable ?? URL(fileURLWithPath: CommandLine.arguments.first ?? ".").resolvingSymlinksInPath()
        let beside = exe.deletingLastPathComponent()
        // A development build (.build/...) or a system path should not become the data folder.
        let looksLikeDevBuild = beside.path.contains("/.build/")
        if !looksLikeDevBuild, isWritableDirectory(beside), !beside.path.hasPrefix("/usr/bin"), !beside.path.hasPrefix("/usr/local/bin") {
            return ServerPaths(root: beside)
        }
        return ServerPaths(root: platformDataDirectory(environment: environment))
    }

    public static func platformDataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/NovaSwiftServer", isDirectory: true)
        #elseif os(Windows)
        if let a = environment["APPDATA"] { return URL(fileURLWithPath: a).appendingPathComponent("NovaSwiftServer", isDirectory: true) }
        return home.appendingPathComponent("NovaSwiftServer", isDirectory: true)
        #else
        if let x = environment["XDG_DATA_HOME"], !x.isEmpty { return URL(fileURLWithPath: x).appendingPathComponent("novaswift-server", isDirectory: true) }
        return home.appendingPathComponent(".local/share/novaswift-server", isDirectory: true)
        #endif
    }

    static func isWritableDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return FileManager.default.isWritableFile(atPath: url.path)
    }
}

/// Loads and saves `server.cfg`, creating it on first run.
public final class ConfigStore {
    public let paths: ServerPaths
    public private(set) var config: ServerConfig
    public private(set) var warnings: [String] = []
    /// True the first time the file did not exist.
    public private(set) var createdNew = false
    private let lock = NSLock()

    public init(paths: ServerPaths) throws {
        self.paths = paths
        try paths.create()
        if let text = try? String(contentsOf: paths.configFile, encoding: .utf8) {
            let (c, w) = ServerConfig.parse(text)
            config = c.normalized(); warnings = w
        } else {
            config = ServerConfig.fresh().normalized()
            createdNew = true
            try save()
        }
    }

    public func update(_ change: (inout ServerConfig) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var c = config
        change(&c)
        config = c.normalized()
        try writeLocked()
    }

    public func save() throws { lock.lock(); defer { lock.unlock() }; try writeLocked() }

    private func writeLocked() throws {
        let tmp = paths.configFile.appendingPathExtension("tmp")
        try config.render().write(to: tmp, atomically: false, encoding: .utf8)
        #if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        #endif
        if FileManager.default.fileExists(atPath: paths.configFile.path) { try? FileManager.default.removeItem(at: paths.configFile) }
        try FileManager.default.moveItem(at: tmp, to: paths.configFile)
    }
}
