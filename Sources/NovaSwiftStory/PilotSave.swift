import Foundation
import NovaSwiftKit

/// A saved pilot on disk: a versioned envelope around the `PlayerState` payload,
/// plus metadata for the pilot roster (name, timestamps, playtime) and a small
/// `snapshot` so the launcher can render the pilot list without re-resolving the
/// whole game. This is our own native `.evpilot` (JSON) format — not EV Nova's
/// obfuscated `.plt`. Because it is plain, structured Codable, the future in-app
/// pilot editor edits these types directly.
///
/// Decoding is resilient (missing keys fall back to defaults, mirroring
/// `GameSettings`), so adding fields never invalidates an existing save.
public struct PilotSave: Codable, Sendable, Identifiable {
    /// Bumped when the on-disk shape changes in a non-additive way.
    public static let currentFormatVersion = 1
    /// File extension for a single pilot save.
    public static let fileExtension = "evpilot"

    // MARK: Metadata
    public var formatVersion: Int
    public var id: UUID
    public var displayName: String
    public var scenarioName: String
    public var createdAt: Date
    public var updatedAt: Date
    public var playtimeSeconds: Double
    /// A coarse fingerprint of the data set (base + plug-ins) that produced this
    /// save, so the UI can warn when it's opened against a different data set.
    public var dataFingerprint: String

    // MARK: List snapshot (kept in sync on save)
    public var snapshot: Snapshot

    // MARK: Payload — the live pilot the engine reads/mutates.
    public var player: PlayerState

    /// Cheap-to-render summary of the pilot for list rows.
    public struct Snapshot: Codable, Sendable {
        public var shipName: String
        public var systemName: String
        public var credits: Int
        public var combatRating: Int
        public var ratingTitle: String

        public init(shipName: String = "", systemName: String = "", credits: Int = 0,
                    combatRating: Int = 0, ratingTitle: String = "") {
            self.shipName = shipName
            self.systemName = systemName
            self.credits = credits
            self.combatRating = combatRating
            self.ratingTitle = ratingTitle
        }
    }

    // MARK: Init

    public init(id: UUID = UUID(),
                displayName: String,
                scenarioName: String,
                player: PlayerState,
                snapshot: Snapshot,
                dataFingerprint: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                playtimeSeconds: Double = 0,
                formatVersion: Int = PilotSave.currentFormatVersion) {
        self.formatVersion = formatVersion
        self.id = id
        self.displayName = displayName
        self.scenarioName = scenarioName
        self.player = player
        self.snapshot = snapshot
        self.dataFingerprint = dataFingerprint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.playtimeSeconds = playtimeSeconds
    }

    /// Build a save from a freshly created (or updated) pilot, resolving the
    /// snapshot from the game so list rows read correctly.
    public init(id: UUID = UUID(),
                displayName: String,
                scenarioName: String,
                player: PlayerState,
                game: NovaGame?,
                dataFingerprint: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                playtimeSeconds: Double = 0) {
        self.init(id: id, displayName: displayName, scenarioName: scenarioName,
                  player: player, snapshot: PilotSave.snapshot(for: player, game: game),
                  dataFingerprint: dataFingerprint, createdAt: createdAt,
                  updatedAt: updatedAt, playtimeSeconds: playtimeSeconds)
    }

    /// Refresh the derived snapshot from the current payload (call before saving).
    public mutating func refreshSnapshot(game: NovaGame?) {
        snapshot = PilotSave.snapshot(for: player, game: game)
    }

    /// Resolve a list snapshot from a `PlayerState` against the game data.
    public static func snapshot(for player: PlayerState, game: NovaGame?) -> Snapshot {
        let shipName = !player.shipName.isEmpty ? player.shipName
            : (game?.ship(player.shipType)?.name ?? "")
        let systemName = game?.system(player.currentSystem)?.name ?? ""
        return Snapshot(shipName: shipName, systemName: systemName,
                        credits: player.credits, combatRating: player.combatRating,
                        ratingTitle: CombatRating.title(forRating: player.combatRating))
    }

    // MARK: Resilient decoding (missing keys → defaults)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion   = (try? c.decodeIfPresent(Int.self, forKey: .formatVersion)) ?? nil ?? 1
        id              = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil ?? UUID()
        displayName     = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil ?? "Captain"
        scenarioName    = (try? c.decodeIfPresent(String.self, forKey: .scenarioName)) ?? nil ?? ""
        createdAt       = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil ?? Date()
        updatedAt       = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil ?? Date()
        playtimeSeconds = (try? c.decodeIfPresent(Double.self, forKey: .playtimeSeconds)) ?? nil ?? 0
        dataFingerprint = (try? c.decodeIfPresent(String.self, forKey: .dataFingerprint)) ?? nil ?? ""
        snapshot        = (try? c.decodeIfPresent(Snapshot.self, forKey: .snapshot)) ?? nil ?? Snapshot()
        // The payload is required; a save without it is meaningless.
        player          = try c.decode(PlayerState.self, forKey: .player)
    }
}

/// EV Nova's combat-rating titles (Bible Appendix I), keyed off the pilot's
/// combat rating (sum of destroyed ships' `shïp.Strength`). All 11 documented
/// tiers, verbatim thresholds — see `docs/reverse-engineering/GOVERNMENT.md` §3.
public enum CombatRating {
    public static let titles = [
        "No Ability", "Little Ability", "Fair Ability", "Average Ability",
        "Good Ability", "Competent", "Very Competent", "Worthy of Note",
        "Dangerous", "Deadly", "Frightening",
    ]
    private static let thresholds = [0, 1, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600]

    public static func title(forRating rating: Int) -> String {
        var title = titles[0]
        for (i, t) in thresholds.enumerated() where rating >= t { title = titles[i] }
        return title
    }
}
