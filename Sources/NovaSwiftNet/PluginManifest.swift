import Foundation

/// One enabled plug-in as it appears in a session's compatibility manifest. The
/// `contentHash` is a hash of the plug-in's resource bytes (computed by the app
/// from the on-disk files), so two players "match" on a plug-in only when they
/// have the *same version* of it, not merely the same name.
public struct PluginRequirement: Codable, Equatable, Hashable, Sendable {
    public let id: String            // stable plug-in id (folder / file name)
    public let name: String          // display name, for the mismatch UI
    public let contentHash: String   // hash of the plug-in's bytes (version identity)

    public init(id: String, name: String, contentHash: String) {
        self.id = id
        self.name = name
        self.contentHash = contentHash
    }
}

/// The set of enabled plug-ins a session is running, exchanged when a player
/// joins so both sides can verify they share the same content. A mismatched set
/// would silently desync the shared galaxy (a ship / outfit / system id means
/// different things on each side), so a joiner whose manifest differs from the
/// host's is blocked with an explaining diff. See `docs/MULTIPLAYER.md`.
public struct PluginManifest: Codable, Equatable, Sendable {
    /// Enabled plug-ins, always sorted by id so equality and the signature are
    /// order-independent.
    public let plugins: [PluginRequirement]

    public init(_ plugins: [PluginRequirement]) {
        self.plugins = plugins.sorted { $0.id < $1.id }
    }

    /// No plug-ins — the stock game. Two stock players are always compatible.
    public static let empty = PluginManifest([])

    public var isEmpty: Bool { plugins.isEmpty }
    public var count: Int { plugins.count }

    /// A short, deterministic, cross-device-stable fingerprint of the whole set
    /// (id + content hash of each plug-in). Used for the cheap "compatible?" hint
    /// in the lobby list and as the Game Center `playerGroup` bucket. FNV-1a (not
    /// `Hasher`, which is per-process randomized, nor a crypto hash — this stays a
    /// zero-dependency value type) over the already-sorted entries.
    public var signature: String { String(fnvHash, radix: 16) }

    /// A non-negative 31-bit integer form of `signature`, for Game Center's
    /// `GKMatchRequest.playerGroup` (auto-match only pairs equal groups).
    public var groupID: Int { Int(fnvHash & 0x7fff_ffff) }

    private var fnvHash: UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ s: String) {
            for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            h = (h ^ 0x1f) &* 0x0000_0100_0000_01b3   // field separator
        }
        for p in plugins { mix(p.id); mix(p.contentHash) }   // plugins is sorted
        return h
    }

    /// Exact-match compatibility: same enabled plug-ins, same versions.
    public func isCompatible(with other: PluginManifest) -> Bool { plugins == other.plugins }

    /// What's wrong with *this* (the joiner's) manifest relative to `host` — the
    /// three actions the joiner must take to become compatible.
    public func mismatch(against host: PluginManifest) -> PluginMismatch {
        let mineByID = Dictionary(plugins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let hostIDs = Set(host.plugins.map(\.id))
        var missing: [PluginRequirement] = []       // host has it, joiner lacks → install + enable
        var wrongVersion: [PluginRequirement] = []   // both have the id, different content
        for hp in host.plugins {
            if let mine = mineByID[hp.id] {
                if mine.contentHash != hp.contentHash { wrongVersion.append(hp) }
            } else {
                missing.append(hp)
            }
        }
        let extra = plugins.filter { !hostIDs.contains($0.id) }   // joiner has it, host doesn't → disable
        return PluginMismatch(missing: missing, extra: extra, wrongVersion: wrongVersion)
    }
}

/// The joiner-facing diff between its plug-ins and the host's: what to install,
/// disable, or fix the version of. Empty on every axis ⇒ compatible.
public struct PluginMismatch: Equatable, Sendable {
    /// Host runs these; the joiner must install + enable them.
    public var missing: [PluginRequirement]
    /// The joiner has these enabled but the host doesn't; the joiner must disable them.
    public var extra: [PluginRequirement]
    /// Both have the plug-in but at different content/versions; the joiner needs the host's.
    public var wrongVersion: [PluginRequirement]

    public init(missing: [PluginRequirement], extra: [PluginRequirement],
                wrongVersion: [PluginRequirement]) {
        self.missing = missing
        self.extra = extra
        self.wrongVersion = wrongVersion
    }

    public var isCompatible: Bool { missing.isEmpty && extra.isEmpty && wrongVersion.isEmpty }
}
