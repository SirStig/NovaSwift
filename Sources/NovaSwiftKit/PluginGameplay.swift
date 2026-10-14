import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Multiplayer plug-in classification: which plug-ins have to match between players and which are cosmetic.
///
/// A plug-in that only changes artwork, sound, music, movies, fonts or UI text can't desync a shared galaxy, so it
/// must not block a join. Anything that touches a gameplay type (ships, outfits, weapons, systems, planets,
/// governments, missions, crons, personalities, fleets, ... or a total conversion) is gameplay, and a plug-in with a
/// mix of both counts as gameplay. The session hash of a gameplay plug-in covers only its gameplay resources, so
/// two copies that differ in artwork alone still match.
///
/// This is THE implementation: the Apple app (`AppModel.currentPluginManifest`) and the Godot bridge both call it.
public enum PluginGameplay {
    /// Resource types that are presentation only. Everything not listed is gameplay (conservative).
    public static let cosmeticTypes: Set<String> = [
        "PICT", "cicn", "ppat", "PAT#", "PAT ", "clut", "icns", "ICON", "ICN#", "icl4", "icl8", "ics#", "ics4", "ics8", "crsr",
        "rlë8", "rlëD", "spïn", "snd ", "STR#", "STR ", "TEXT", "styl", "FONT", "NFNT", "MENU", "DLOG", "DITL", "dësc",
        "ïntf", "cölr", "vers", "sïft", "shän", "bööm",
    ]

    /// Whether a resource type affects the simulation (everything not known to be presentation-only does).
    public static func isGameplay(type: FourCharCode) -> Bool { !cosmeticTypes.contains(type.stringValue) }

    public struct Result: Equatable, Codable, Sendable {
        public var cosmetic: Bool
        /// SHA-256 hex of the gameplay resources (type, id, name, bytes; sorted); the whole-file hash when cosmetic.
        public var hash: String
        public init(cosmetic: Bool, hash: String) { self.cosmetic = cosmetic; self.hash = hash }
    }

    /// Classify and hash a bundle. A total conversion is always gameplay. Parses the bundle's files (cache the
    /// result by file stamp; this reads every container).
    public static func analyze(_ bundle: PluginBundle) -> Result {
        let whole = GameLibrary.contentHash(of: bundle)
        if bundle.isTotalConversion { return Result(cosmetic: false, hash: whole) }
        var gameplay: [Resource] = []
        for url in bundle.allFileURLs.sorted(by: { $0.path < $1.path }) {
            guard let col = try? ResourceFile.read(contentsOf: url) else { return Result(cosmetic: false, hash: whole) }
            for (type, byID) in col.byType where isGameplay(type: type) {
                gameplay.append(contentsOf: byID.values)
            }
        }
        if gameplay.isEmpty { return Result(cosmetic: true, hash: whole) }
        return Result(cosmetic: false, hash: hash(gameplay))
    }

    /// Order-independent hash of a resource list.
    public static func hash(_ resources: [Resource]) -> String {
        var h = SHA256()
        for r in resources.sorted(by: { ($0.type.rawValue, $0.id) < ($1.type.rawValue, $1.id) }) {
            h.update(data: Data("\(r.type.stringValue)#\(r.id)#\(r.name)#".utf8))
            h.update(data: r.data)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
