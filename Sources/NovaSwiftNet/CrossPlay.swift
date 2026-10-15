import Foundation

/// Constants and pure helpers shared by the Apple app and the Godot build for **cross-play** (Apple <-> Linux /
/// Windows / Steam Deck / dedicated servers over ENet). Everything here mirrors `godot/net/NetProto.gd`; see
/// docs/MULTIPLAYER.md, "Cross-play with the Apple app".
///
/// No sockets live here (those are in `NovaSwiftENet`), so this file is safe on every platform.
public enum CrossPlayProtocol {
    /// The network PROTOCOL version both frontends speak: HELLO `proto`, and the gate. Bumped ONLY on a
    /// wire-incompatible change (handshake, framing, NetSession message formats). Two builds with different app
    /// versions but the same protocol connect (the UI shows a small "different version" note). The Godot bridge
    /// reports this same constant; keep `godot/net/NetProto.gd` `PROTO` equal to it.
    public static let version = 1
    /// The app's release string (`godot/project.godot` `config/version`). Informational: sent in HELLO and
    /// beacons so the UI can say "different version", never gates a join. A unit test keeps it equal to the Godot
    /// project's so a release bumps both.
    public static let appVersion = "1.0.0-beta.1"
    /// Alias of `version` (older name).
    public static let wireProtocol = version
    public static let defaultPort = 53735
    /// UDP port LAN beacons go to / are heard on (and the query port of a default-port server).
    public static let lanPort = 53736
    public static let beaconMagic = "NSB1"
    public static let queryMagic = "NSQ1"
    public static let maxNameLength = 24
    /// Server names can be longer than pilot names (the public directory allows 40). `NetProto.MAX_SERVER_NAME`.
    public static let maxServerNameLength = 40
    public static let directoryURL = URL(string: "https://raw.githubusercontent.com/SirStig/NovaSwift-Plugins/main/servers/servers.json")!
    public static let directoryHelpURL = URL(string: "https://github.com/SirStig/NovaSwift-Plugins/blob/main/servers/README.md")!

    /// Where to send an `NSQ1` status query: 53736 for the default game port, otherwise game port + 1.
    public static func queryPort(forGamePort port: Int) -> Int {
        port == defaultPort ? lanPort : port + 1
    }

    /// Trim, strip control / zero-width / bidi characters, collapse whitespace, cap the length. Never empty
    /// (`NetProto.clean_name`).
    public static func cleanName(_ raw: String, fallback: String = "Pilot", maxLength: Int = maxNameLength) -> String {
        var out = collapseSpaces(stripInvisible(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count > maxLength {
            out = String(out.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out.isEmpty ? fallback : out
    }

    /// A player-chosen display name: `cleanName` plus no square brackets (BBCode) and no names that look like the
    /// server or staff (`isReservedName`), which fall back to `fallback`.
    public static func cleanPlayerName(_ raw: String, fallback: String = "Pilot") -> String {
        let noBrackets = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0 != "[" && $0 != "]" }))
        let n = cleanName(noBrackets, fallback: fallback)
        return isReservedName(n) ? fallback : n
    }

    /// Chat text from the wire: no control / invisible characters (newlines become spaces), collapsed, trimmed, at most
    /// `maxChatLength` characters. Empty string when nothing is left.
    public static func cleanChat(_ raw: String) -> String {
        let spaced = String(String.UnicodeScalarView(raw.unicodeScalars.map { ($0 == "\n" || $0 == "\r" || $0 == "\t") ? " " : $0 }))
        let t = collapseSpaces(stripInvisible(spaced)).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > maxChatLength ? String(t.prefix(maxChatLength)) : t
    }

    public static let maxChatLength = 200

    /// Names players may not take: the server's own voices and staff titles, including look-alikes ("S3rver",
    /// "Adm1n", "A d m i n", "[Server]").
    public static let reservedNames: Set<String> = [
        "server", "admin", "administrator", "moderator", "mod", "host", "system", "console", "novaswift",
        "staff", "gm", "operator", "sysop", "owner",
    ]

    public static func isReservedName(_ name: String) -> Bool {
        // Two readings of the ambiguous characters: 1 / ! / | as "l" (S3rver, Adm1n -> "admln") and as "i" ("admin").
        for ambiguous in ["l", "i"] {
            var norm = ""
            for u in name.lowercased().unicodeScalars {
                switch u {
                case "0": norm.append("o")
                case "1", "!", "|": norm.append(ambiguous)
                case "3": norm.append("e")
                case "4", "@": norm.append("a")
                case "5", "$": norm.append("s")
                case "7": norm.append("t")
                case "8": norm.append("b")
                default: if CharacterSet.alphanumerics.contains(u) { norm.unicodeScalars.append(u) }
                }
            }
            if reservedNames.contains(norm) { return true }
            if norm.hasPrefix("server") && norm.dropFirst(6).allSatisfy({ $0.isNumber }) { return true }
            if norm.hasPrefix("admin") && norm.dropFirst(5).allSatisfy({ $0.isNumber }) { return true }
        }
        return false
    }

    /// Scalars that are invisible, reorder text, or are controls: removed from every string that comes off the wire.
    public static func isInvisibleScalar(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        if v < 32 || v == 127 || (0x80...0x9F).contains(v) { return true }
        switch v {
        case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180E, 0x200B...0x200F, 0x202A...0x202E,
             0x2060...0x206F, 0x3164, 0xFE00...0xFE0F, 0xFEFF, 0xFFA0, 0xFFF9...0xFFFB, 0xE0000...0xE007F:
            return true
        default: return false
        }
    }

    static func stripInvisible(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !isInvisibleScalar($0) || $0 == "\n" || $0 == "\r" || $0 == "\t" }))
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
    }

    static func collapseSpaces(_ s: String) -> String {
        var out = ""; var lastSpace = false
        for ch in s {
            if ch.isWhitespace { if !lastSpace { out.append(" ") }; lastSpace = true } else { out.append(ch); lastSpace = false }
        }
        return out
    }

    /// `SessionRules` in the Godot bridge's lenient snake_case JSON (WELCOME `rules`, `net_begin` rules).
    public static func rulesJSON(_ r: SessionRules) -> String {
        let obj: [String: Any] = [
            "pvp_damage_real": r.pvpDamageReal, "death_real": r.deathReal, "friendly_fire": r.friendlyFire,
            "allow_pvp": r.allowPvP, "allow_trade": r.allowTrade, "carry_encounter": r.carryEncounter,
            "game_speed_multiplier": r.gameSpeedMultiplier,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// The label a beacon / directory row shows for a rules set: "safe", "full" or "custom"
    /// (`NetProto.preset_of`; game speed is ignored).
    public static func presetName(_ r: SessionRules) -> String {
        func same(_ p: SessionRules) -> Bool {
            r.pvpDamageReal == p.pvpDamageReal && r.deathReal == p.deathReal && r.friendlyFire == p.friendlyFire
                && r.allowPvP == p.allowPvP && r.allowTrade == p.allowTrade && r.carryEncounter == p.carryEncounter
        }
        if same(.safe) { return "safe" }
        if same(.fullStakes) { return "full" }
        return "custom"
    }
}

// MARK: - Address parsing

/// "host", "host:port", "1.2.3.4:5", "[::1]:5" (`NetProto.parse_address`).
public struct CrossPlayAddress: Equatable, Hashable, Codable, Sendable {
    public var host: String
    public var port: Int
    public init(host: String, port: Int = CrossPlayProtocol.defaultPort) { self.host = host; self.port = port }

    public enum ParseError: Error, Equatable, LocalizedError {
        case empty, badPort, badIPv6, junk
        public var errorDescription: String? {
            switch self {
            case .empty: return "Enter a server address, like 192.168.1.20 or play.example.com:53735."
            case .badPort: return "The port must be a number between 1 and 65535."
            case .badIPv6: return "Missing ] in the IPv6 address."
            case .junk: return "That doesn't look like a server address."
            }
        }
    }

    public static func parse(_ text: String, defaultPort: Int = CrossPlayProtocol.defaultPort) -> Result<CrossPlayAddress, ParseError> {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["nova://", "novaswift://", "udp://"] where s.hasPrefix(scheme) { s = String(s.dropFirst(scheme.count)) }
        if s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return .failure(.empty) }
        var host = s
        var port = defaultPort
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return .failure(.badIPv6) }
            host = String(s[s.index(after: s.startIndex)..<close])
            let rest = String(s[s.index(after: close)...])
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return .failure(.junk) }
                guard let p = parsePort(String(rest.dropFirst())) else { return .failure(.badPort) }
                port = p
            }
        } else if s.filter({ $0 == ":" }).count == 1, let i = s.lastIndex(of: ":") {
            host = String(s[..<i])
            guard let p = parsePort(String(s[s.index(after: i)...])) else { return .failure(.badPort) }
            port = p
        }
        if host.trimmingCharacters(in: .whitespaces).isEmpty || host.contains(" ") { return .failure(.junk) }
        return .success(CrossPlayAddress(host: host, port: port))
    }

    private static func parsePort(_ t: String) -> Int? {
        guard let n = Int(t.trimmingCharacters(in: .whitespaces)), (1...65535).contains(n) else { return nil }
        return n
    }

    /// "host" for the default port, "host:port" otherwise; IPv6 literals bracketed.
    public var formatted: String {
        let h = host.filter { $0 == ":" }.count >= 2 ? "[\(host)]" : host
        return port == CrossPlayProtocol.defaultPort ? h : "\(h):\(port)"
    }
}

// MARK: - Required plug-ins (advertised by servers)

/// The gameplay content a server requires, as advertised in beacons / `NSQ1` replies / directory entries: the
/// enabled gameplay plug-ins (id, name, content hash), the total conversion among them and its add-ons.
/// Cosmetic plug-ins (art / sound / UI text only, see `PluginGameplay`) are never listed. Hashes come from
/// `PluginGameplay`, the one implementation both the Apple app and the Godot bridge use. On the wire a hash may be
/// truncated to its first 16 hex characters (`hashesMatch`).
public struct PluginRequirements: Equatable, Codable, Sendable {
    public static let wireHashLength = 16
    /// Most plug-ins / add-ons read from one beacon, directory entry or manifest.
    public static let maxEntries = 64
    public var plugins: [PluginRequirement]
    /// Id of the enabled total conversion, if any.
    public var totalConversion: String?
    /// Ids of the add-ons switched on for that conversion, in load order.
    public var addOns: [String]

    public init(plugins: [PluginRequirement] = [], totalConversion: String? = nil, addOns: [String] = []) {
        self.plugins = plugins.filter { !$0.cosmetic }.sorted { $0.id < $1.id }
        self.totalConversion = totalConversion
        self.addOns = addOns
    }

    public var isEmpty: Bool { plugins.isEmpty && totalConversion == nil }
    public var manifest: PluginManifest { PluginManifest(plugins) }

    /// Hashes match when equal, or when either is unknown, or when the shorter (wire) form is a prefix.
    public static func hashesMatch(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return true }
        let n = min(a.count, b.count, wireHashLength)
        return a.prefix(n) == b.prefix(n)
    }

    /// Beacon fields (`sig`, `pcount`, `tc` always; `plugins`, `addons` only when `full`: the unicast reply).
    func fields(full: Bool) -> [String: Any] {
        var d: [String: Any] = ["sig": manifest.signature, "pcount": plugins.count, "tc": totalConversion ?? ""]
        if full {
            d["plugins"] = plugins.map { ["id": $0.id, "name": $0.name, "hash": String($0.contentHash.prefix(Self.wireHashLength))] }
            d["addons"] = addOns
        }
        return d
    }

    /// Lenient parse of the fields above (also accepts `contentHash`, as directory entries and handshake
    /// manifests spell it). nil when there is nothing.
    static func parse(_ o: [String: Any]) -> PluginRequirements? {
        func cap(_ v: Any?, _ n: Int) -> String { CrossPlayProtocol.cleanName((v as? String) ?? "", fallback: "", maxLength: n) }
        let tc = cap(o["tc"], 64).isEmpty ? nil : cap(o["tc"], 64)
        let addOns = ((o["addons"] as? [Any]) ?? []).prefix(maxEntries).compactMap { ($0 as? String).map { cap($0, 64) } }
        guard let list = o["plugins"] as? [[String: Any]] else { return tc == nil ? nil : PluginRequirements(totalConversion: tc, addOns: Array(addOns)) }
        let plugins = list.prefix(maxEntries).map {
            PluginRequirement(id: cap($0["id"], 64), name: cap($0["name"], 64).isEmpty ? cap($0["id"], 64) : cap($0["name"], 64),
                              contentHash: String((($0["hash"] as? String) ?? ($0["contentHash"] as? String) ?? "").prefix(80)))
        }
        return PluginRequirements(plugins: plugins, totalConversion: tc, addOns: Array(addOns))
    }
}

/// How the local install compares with a server's required content. Cosmetic plug-ins never appear.
public struct PluginCompatibility: Equatable, Sendable {
    /// Server requires these; we lack them (install + enable).
    public var missing: [PluginRequirement]
    /// We have these enabled (gameplay) and the server doesn't (disable for the session).
    public var extra: [PluginRequirement]
    /// Both have the id, different gameplay content (needs the server's version).
    public var wrongVersion: [PluginRequirement]
    /// The server runs this total conversion and we don't run it.
    public var wrongTotalConversion: String?
    /// We run a total conversion the server doesn't.
    public var extraTotalConversion: String?

    public var isCompatible: Bool {
        missing.isEmpty && extra.isEmpty && wrongVersion.isEmpty && wrongTotalConversion == nil && extraTotalConversion == nil
    }

    public static func evaluate(local: PluginRequirements, server: PluginRequirements) -> PluginCompatibility {
        let mine = Dictionary(local.plugins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let serverIDs = Set(server.plugins.map(\.id))
        var missing: [PluginRequirement] = [], wrong: [PluginRequirement] = []
        for r in server.plugins {
            if let m = mine[r.id] {
                if !PluginRequirements.hashesMatch(m.contentHash, r.contentHash) { wrong.append(r) }
            } else { missing.append(r) }
        }
        let extra = local.plugins.filter { !serverIDs.contains($0.id) }
        let wrongTC = server.totalConversion != local.totalConversion ? server.totalConversion : nil
        let extraTC = server.totalConversion != local.totalConversion && server.totalConversion == nil ? local.totalConversion : nil
        return PluginCompatibility(missing: missing, extra: extra, wrongVersion: wrong,
                                   wrongTotalConversion: wrongTC, extraTotalConversion: extraTC)
    }

    /// Per required plug-in: ✓ when the local install has it enabled at the same gameplay hash.
    public static func checklist(local: PluginRequirements, server: PluginRequirements) -> [(requirement: PluginRequirement, ok: Bool)] {
        let mine = Dictionary(local.plugins.map { ($0.id, $0.contentHash) }, uniquingKeysWith: { a, _ in a })
        return server.plugins.map { r in (r, mine[r.id].map { PluginRequirements.hashesMatch($0, r.contentHash) } ?? false) }
    }

    /// Cheap answer from a LAN beacon that carries only the signature: nil = unknown.
    public static func signatureHint(local: PluginRequirements, serverSignature: String) -> Bool? {
        serverSignature.isEmpty ? nil : serverSignature == local.manifest.signature
    }
}

// MARK: - Beacon / status query payload

/// The `NSB1` beacon: broadcast on the LAN by every hosting game and returned as the reply to an `NSQ1` query.
/// `NetProto.encode_beacon` / `decode_beacon`.
public struct ServerBeacon: Equatable, Sendable {
    public var name: String
    public var players: Int
    public var max: Int
    public var ver: String
    public var pw: Bool
    public var port: Int
    public var rules: String
    public var dedicated: Bool
    /// Required content (nil = the server did not say; an old build or a stock game).
    public var requirements: PluginRequirements?
    /// `sig` / `pcount`: the gameplay-plug-in signature and count a LAN broadcast carries without the list.
    public var pluginSignature: String
    public var pluginCount: Int?
    /// The sender's network protocol version (`CrossPlayProtocol.version`); nil from builds that don't say.
    public var proto: Int?
    /// The server uses DTLS (a newer Godot build); this Apple client can't speak it yet.
    public var encrypted: Bool

    public init(name: String, players: Int, max: Int, ver: String = CrossPlayProtocol.appVersion, pw: Bool = false,
                port: Int = CrossPlayProtocol.defaultPort, rules: String = "", dedicated: Bool = false,
                requirements: PluginRequirements? = nil, encrypted: Bool = false, proto: Int? = CrossPlayProtocol.version) {
        self.pluginSignature = requirements?.manifest.signature ?? ""
        self.pluginCount = requirements?.plugins.count
        self.proto = proto
        self.name = name; self.players = players; self.max = max; self.ver = ver; self.pw = pw
        self.port = port; self.rules = rules; self.dedicated = dedicated
        self.requirements = requirements; self.encrypted = encrypted
    }

    /// Speaks our network protocol (an unknown protocol is allowed: the handshake decides).
    public var isCompatible: Bool { (proto ?? CrossPlayProtocol.version) == CrossPlayProtocol.version }
    /// Same protocol but another app release: playable, worth a small note.
    public var isDifferentAppVersion: Bool { !ver.isEmpty && ver != CrossPlayProtocol.appVersion }

    /// `full: false` is the LAN broadcast form (signature + count only); the unicast `NSQ1` reply is `full`.
    public func encode(full: Bool = true, truncated: Bool = false) -> Data {
        var d: [String: Any] = [
            "name": CrossPlayProtocol.cleanName(name, fallback: "NovaSwift", maxLength: CrossPlayProtocol.maxServerNameLength), "players": players, "max": max, "ver": ver,
            "pw": pw, "port": port, "rules": rules, "dedicated": dedicated, "proto": CrossPlayProtocol.version,
        ]
        if truncated { d["truncated"] = true }
        if let requirements { d.merge(requirements.fields(full: full)) { a, _ in a } }
        var out = Data(CrossPlayProtocol.beaconMagic.utf8)
        out.append((try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data("{}".utf8))
        return out
    }

    /// nil when the packet is not a beacon / is malformed.
    public static func decode(_ packet: Data) -> ServerBeacon? {
        guard packet.count >= 6, packet.count <= 6144 else { return nil }
        let bytes = [UInt8](packet)
        guard String(decoding: bytes[0..<4], as: UTF8.self) == CrossPlayProtocol.beaconMagic,
              let obj = (try? JSONSerialization.jsonObject(with: Data(bytes[4...]))) as? [String: Any] else { return nil }
        func int(_ v: Any?) -> Int { Swift.max(-1, Swift.min(1_000_000, (v as? NSNumber)?.intValue ?? 0)) }
        func str(_ v: Any?, _ n: Int) -> String { String(CrossPlayProtocol.cleanName((v as? String) ?? "", fallback: "", maxLength: n)) }
        let port = int(obj["port"])
        guard (1...65535).contains(port) else { return nil }
        var b = ServerBeacon(
            name: CrossPlayProtocol.cleanName((obj["name"] as? String) ?? "", fallback: "Server", maxLength: CrossPlayProtocol.maxServerNameLength),
            players: Swift.max(0, int(obj["players"])), max: Swift.max(0, int(obj["max"])),
            ver: str(obj["ver"], 32), pw: (obj["pw"] as? Bool) ?? false, port: port,
            rules: str(obj["rules"], 16), dedicated: (obj["dedicated"] as? Bool) ?? false,
            requirements: PluginRequirements.parse(obj), encrypted: (obj["dtls"] as? Bool) ?? false,
            proto: (obj["proto"] as? NSNumber)?.intValue)
        b.pluginSignature = str(obj["sig"], 64)
        b.pluginCount = (obj["pcount"] as? NSNumber)?.intValue ?? b.requirements?.plugins.count
        return b
    }

    /// The status query this build sends: `NSQ1` + version byte 2 + 3 random bytes, zero-padded to
    /// `QueryGuard.requestSize` (1200) bytes. The padding is the anti-amplification rule: a server never answers with more
    /// bytes than it received, so a spoofed query can't be turned into a bigger reflected reply.
    public static var queryPacket: Data {
        var d = Data(CrossPlayProtocol.queryMagic.utf8)
        d.append(QueryGuard.queryVersion)
        for _ in 0..<3 { d.append(UInt8.random(in: 0...255)) }
        d.append(Data(count: QueryGuard.requestSize - d.count))
        return d
    }
    /// The pre-hardening 4-byte query. Still answered (compact reply, tightly rate limited) for old clients.
    public static var legacyQueryPacket: Data { Data(CrossPlayProtocol.queryMagic.utf8) }
    public static func isQuery(_ packet: Data) -> Bool { QueryGuard.classify(packet) != .invalid }

    /// `encode`, but never longer than `maxBytes`: the full reply when it fits, else the compact form (no plug-in list)
    /// with `"truncated":true` so the reader knows the list was left out.
    public func encode(maxBytes: Int) -> Data {
        let full = encode(full: true)
        if full.count <= maxBytes { return full }
        let compact = encode(full: false, truncated: true)
        return compact.count <= maxBytes ? compact : Data()
    }
}


// MARK: - Public directory (servers.json)

/// One entry of the community server list (`servers/servers.schema.json` in SirStig/NovaSwift-Plugins).
public struct DirectoryServer: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var region: String
    public var description: String
    public var ownerName: String
    public var contact: String
    public var rules: String
    public var plugins: [PluginRequirement]
    /// Optional extras (not in schema v1 yet): total conversion id and add-ons.
    public var totalConversion: String?
    public var addOns: [String] = []
    public var maxPlayers: Int
    public var added: String
    public var website: String?
    public var requirements: PluginRequirements { PluginRequirements(plugins: plugins, totalConversion: totalConversion, addOns: addOns) }

    public var address: CrossPlayAddress { CrossPlayAddress(host: host, port: port) }
    /// Stable key for a host:port pair (case-insensitive host).
    public var key: String { "\(host.lowercased()):\(port)" }
}

public enum ServerDirectory {
    public static let regions = ["na-east", "na-west", "sa", "eu", "af", "me", "as", "oc", "global"]
    public static let maxEntries = 500
    public static let maxBytes = 512 * 1024

    public static func regionTitle(_ r: String) -> String {
        switch r {
        case "na-east": return "North America (East)"
        case "na-west": return "North America (West)"
        case "sa": return "South America"
        case "eu": return "Europe"
        case "af": return "Africa"
        case "me": return "Middle East"
        case "as": return "Asia"
        case "oc": return "Oceania"
        case "global": return "Global"
        default: return r
        }
    }

    public enum ParseError: Error, Equatable { case notAServerList, tooLarge }

    /// Parse servers.json. Entries failing basic checks are skipped (as Godot's `ServerDirectory.parse`); a wrong
    /// top-level shape fails the whole file.
    public static func parse(_ data: Data) -> Result<[DirectoryServer], ParseError> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["servers"] as? [Any] else { return .failure(.notAServerList) }
        var out: [DirectoryServer] = []
        var seen = Set<String>()
        for item in list {
            guard let d = item as? [String: Any], out.count < maxEntries else { continue }
            let host = ((d["host"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let port = (d["port"] as? NSNumber)?.intValue ?? CrossPlayProtocol.defaultPort
            guard !host.isEmpty, !host.contains(" "), (1...65535).contains(port) else { continue }
            let key = "\(host.lowercased()):\(port)"
            guard seen.insert(key).inserted else { continue }
            let owner = d["owner"] as? [String: Any] ?? [:]
            let site = (d["website"] as? String) ?? ""
            let plugins: [PluginRequirement] = ((d["plugins"] as? [[String: Any]]) ?? []).map {
                PluginRequirement(id: ($0["id"] as? String) ?? "", name: ($0["name"] as? String) ?? ($0["id"] as? String) ?? "",
                                  contentHash: ($0["contentHash"] as? String) ?? "")
            }
            out.append(DirectoryServer(
                id: (d["id"] as? String) ?? key,
                name: CrossPlayProtocol.cleanName((d["name"] as? String) ?? host, fallback: host, maxLength: CrossPlayProtocol.maxServerNameLength),
                host: host, port: port, region: (d["region"] as? String) ?? "global",
                description: String(((d["description"] as? String) ?? "").prefix(300)),
                ownerName: (owner["name"] as? String) ?? "", contact: (owner["contact"] as? String) ?? "",
                rules: (d["rules"] as? String) ?? "", plugins: plugins,
                totalConversion: (d["tc"] as? String) ?? (d["totalConversion"] as? String),
                addOns: (d["addons"] as? [String]) ?? [],
                maxPlayers: (d["maxPlayers"] as? NSNumber)?.intValue ?? 0,
                added: (d["added"] as? String) ?? "", website: site.hasPrefix("https://") ? site : nil))
        }
        return .success(out)
    }
}

/// A directory / saved / LAN server joined with its live `NSQ1` answer: what the browser actually shows.
public struct ServerRow: Identifiable, Equatable, Sendable {
    public enum State: Int, Sendable { case online = 0, checking = 1, offline = 2 }
    public var id: String
    public var name: String
    public var address: CrossPlayAddress
    public var region: String
    public var description: String
    public var state: State
    public var pingMilliseconds: Int
    public var players: Int
    public var maxPlayers: Int
    public var version: String
    public var passwordProtected: Bool
    public var dedicated: Bool
    public var rules: String
    public var plugins: [PluginRequirement]
    /// What the server requires: the live answer when it gave one, else the directory entry's list.
    public var requirements: PluginRequirements?
    public var encrypted = false
    public var pluginSignature = ""
    public var pluginCount: Int?
    /// Playable together: online, same network protocol, not DTLS-only.
    public var differentAppVersion = false

    /// Online AND on the same game version as this build.
    public var isCompatible: Bool { state == .online && protocolOK && !encrypted }
    public var protocolOK = true
    public var isFull: Bool { state == .online && maxPlayers > 0 && players >= maxPlayers }

    /// `ServerDirectory.row_for`: directory entry + the live beacon (nil = no answer).
    public init(entry: DirectoryServer, live: ServerBeacon?, rtt: Int?, checking: Bool) {
        id = entry.key; name = entry.name; address = entry.address; region = entry.region
        description = entry.description; plugins = entry.plugins
        requirements = live?.requirements ?? (entry.requirements.isEmpty ? nil : entry.requirements)
        encrypted = live?.encrypted ?? false
        pluginSignature = live?.pluginSignature ?? ""; pluginCount = live?.pluginCount
        protocolOK = live?.isCompatible ?? true; differentAppVersion = live?.isDifferentAppVersion ?? false
        if let live {
            state = .online; pingMilliseconds = rtt ?? -1; players = live.players
            maxPlayers = live.max > 0 ? live.max : entry.maxPlayers
            version = live.ver; passwordProtected = live.pw; dedicated = live.dedicated
            rules = live.rules.isEmpty ? entry.rules : live.rules
        } else {
            state = checking ? .checking : .offline; pingMilliseconds = -1; players = 0
            maxPlayers = entry.maxPlayers; version = ""; passwordProtected = false; dedicated = false; rules = entry.rules
        }
    }

    /// A saved / recent / typed server (no directory metadata).
    public init(address: CrossPlayAddress, name: String, live: ServerBeacon?, rtt: Int?, checking: Bool) {
        id = "\(address.host.lowercased()):\(address.port)"; self.name = name; self.address = address
        region = ""; description = ""; plugins = []
        requirements = live?.requirements
        encrypted = live?.encrypted ?? false
        pluginSignature = live?.pluginSignature ?? ""; pluginCount = live?.pluginCount
        protocolOK = live?.isCompatible ?? true; differentAppVersion = live?.isDifferentAppVersion ?? false
        if let live {
            state = .online; pingMilliseconds = rtt ?? -1; players = live.players; maxPlayers = live.max
            version = live.ver; passwordProtected = live.pw; dedicated = live.dedicated; rules = live.rules
        } else {
            state = checking ? .checking : .offline; pingMilliseconds = -1; players = 0; maxPlayers = 0
            version = ""; passwordProtected = false; dedicated = false; rules = ""
        }
    }

    /// Online servers first by ping, then still-checking, then offline; ties by name (`ServerDirectory.sort_rows`).
    public static func sorted(_ rows: [ServerRow]) -> [ServerRow] {
        rows.sorted {
            if $0.state != $1.state { return $0.state.rawValue < $1.state.rawValue }
            if $0.state == .online, $0.pingMilliseconds != $1.pingMilliseconds { return $0.pingMilliseconds < $1.pingMilliseconds }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

public struct ServerFilter: Equatable, Sendable {
    public var compatibleOnly = false
    public var hasPlayers = false
    /// nil = any region.
    public var region: String?
    public init(compatibleOnly: Bool = false, hasPlayers: Bool = false, region: String? = nil) {
        self.compatibleOnly = compatibleOnly; self.hasPlayers = hasPlayers; self.region = region
    }
    public func apply(_ rows: [ServerRow]) -> [ServerRow] {
        rows.filter { r in
            if let region, !region.isEmpty, r.region != region { return false }
            if compatibleOnly, !r.isCompatible { return false }
            if hasPlayers, r.players < 1 { return false }
            return true
        }
    }
}

// MARK: - Saved + recent servers (UserDefaults)

public struct SavedServer: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var host: String
    public var port: Int
    /// Stored as typed, in the app's UserDefaults (Godot keeps it in settings.cfg too). Empty = none.
    public var password: String
    public var id: String { "\(host.lowercased()):\(port)" }
    public var address: CrossPlayAddress { CrossPlayAddress(host: host, port: port) }
    public init(name: String, host: String, port: Int, password: String = "") {
        self.name = CrossPlayProtocol.cleanName(name, fallback: host, maxLength: CrossPlayProtocol.maxServerNameLength); self.host = host; self.port = port; self.password = password
    }
}

/// Favourites (max 64) and recent addresses (max 8, newest first), mirroring `NetPrefs.gd`.
public final class SavedServersStore {
    public static let maxSaved = 64
    public static let maxRecent = 8
    private let defaults: UserDefaults
    private let savedKey: String, recentKey: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "novaswift.net") {
        self.defaults = defaults
        savedKey = keyPrefix + ".saved"; recentKey = keyPrefix + ".recent"
    }

    public var saved: [SavedServer] {
        guard let d = defaults.data(forKey: savedKey), let v = try? JSONDecoder().decode([SavedServer].self, from: d) else { return [] }
        return v
    }
    public var recent: [CrossPlayAddress] {
        guard let d = defaults.data(forKey: recentKey), let v = try? JSONDecoder().decode([CrossPlayAddress].self, from: d) else { return [] }
        return v
    }

    @discardableResult
    public func save(_ server: SavedServer) -> [SavedServer] {
        var list = saved
        if let i = list.firstIndex(where: { $0.id == server.id }) { list[i] = server }
        else if list.count < Self.maxSaved { list.append(server) }
        store(list, savedKey)
        return list
    }
    @discardableResult
    public func remove(host: String, port: Int) -> [SavedServer] {
        let id = "\(host.lowercased()):\(port)"
        let list = saved.filter { $0.id != id }
        store(list, savedKey)
        return list
    }
    public func isSaved(host: String, port: Int) -> Bool {
        let id = "\(host.lowercased()):\(port)"
        return saved.contains { $0.id == id }
    }
    @discardableResult
    public func addRecent(_ a: CrossPlayAddress) -> [CrossPlayAddress] {
        var list = recent.filter { !($0.host.lowercased() == a.host.lowercased() && $0.port == a.port) }
        list.insert(a, at: 0)
        list = Array(list.prefix(Self.maxRecent))
        store(list, recentKey)
        return list
    }
    public func clearRecent() { defaults.removeObject(forKey: recentKey) }

    private func store<T: Encodable>(_ v: T, _ key: String) {
        if let d = try? JSONEncoder().encode(v) { defaults.set(d, forKey: key) }
    }
}
