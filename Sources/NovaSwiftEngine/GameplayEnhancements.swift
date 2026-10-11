import Foundation

/// NovaSwift behaviours the original game doesn't have. Default gameplay
/// matches the original exactly, quirks included; anything the port invented
/// survives only as one of these opt-in toggles, all off by default (see
/// docs/reverse-engineering/FIDELITY_PLAN.md §3).
///
/// Adding a toggle is a stored `Bool` plus one `catalog` row: coding and the
/// Settings ▸ Enhancements list are both driven by the catalog, and a saved
/// blob that lacks a key decodes it as off. Keys a saved blob carries that the
/// catalog no longer lists (toggles since removed) are ignored.
public struct GameplayEnhancements: Codable, Equatable, Sendable {

    /// Plug-ins start disabled, load in the launcher's drag order, and are
    /// discovered recursively. Off: every installed plug-in loads, in
    /// case-insensitive alphabetical order, the later one winning (UI-16).
    public var manualPluginOrder = false

    /// Escorts and fleet members holding formation fly the port's driftless
    /// model instead of their hull's momentum (FL-11).
    public var formationFlying = false

    /// Land anywhere within `radius + 70` of a body below 130 px/s, with no
    /// clearance step (FL-12).
    public var forgivingLanding = false

    /// The port's quick jump: turn to the exit with no braking, a 0.45 s burst
    /// at 4 × top speed and a 0.14 s flash; a fast-jump outfit skips the turn
    /// too, and ModType 22 shortens it (FL-04, FL-06).
    public var quickHyperjump = false

    /// Save on every jump, on a timer, on backgrounding and after combat
    /// events, keeping the in-flight position. The original saves only for a
    /// new pilot, on leaving a spaceport and after a Strict Play pod (UI-01).
    public var frequentAutosave = false

    /// Tap a system to plot the fewest-jumps course to it (through unexplored
    /// systems too, with no hop limit), plus the map's "Nearest System" button.
    /// The original has no pathfinding: a click arms one linked system and
    /// Shift+click builds a route hop by hop, up to 31 (UI-05).
    public var autoRoutePlotting = false

    /// The ship-target cycle runs nearest first, wraps, and stops at 3000 px; R
    /// targets the nearest ship. The original cycles in arrival order with no
    /// wrap or range limit, and R picks the nearest ship attacking you (UI-07).
    public var nearestFirstTargeting = false

    /// The port's key layout: Return fires secondaries (sidestepping macOS's
    /// Control-arrow shortcuts), Shift is the afterburner, P pauses, I opens
    /// ship info and X orders escorts evasive (UI-15). Applies when the key
    /// bindings are reset to defaults.
    public var modernKeyBindings = false

    /// Camera shake on nearby explosions and impacts. The original never
    /// shakes the view; still suppressed by "Reduce flashing & motion".
    public var screenShake = false

    public init() {}

    /// One toggle as the Settings screen lists it.
    public struct Entry: Sendable {
        /// Stable coding key; never rename once shipped.
        public let key: String
        public let keyPath: WritableKeyPath<GameplayEnhancements, Bool> & Sendable
        public let title: String
        /// One line: what the toggle keeps, and what the original does instead.
        public let replaces: String
    }

    public static let catalog: [Entry] = [
        Entry(key: "manualPluginOrder", keyPath: \.manualPluginOrder,
              title: "Manual plug-in order",
              replaces: "Pick which plug-ins load and in what order. The original loads every installed plug-in, alphabetically."),
        Entry(key: "formationFlying", keyPath: \.formationFlying,
              title: "Tight formations",
              replaces: "Escorts and fleet wings hold formation precisely. In the original they fly their own hull's momentum."),
        Entry(key: "forgivingLanding", keyPath: \.forgivingLanding,
              title: "Forgiving landing",
              replaces: "Land from a wider circle around a planet at a higher speed. The original needs you almost stopped over it."),
        Entry(key: "quickHyperjump", keyPath: \.quickHyperjump,
              title: "Quick hyperjump",
              replaces: "Jump after a short turn and burst. The original brakes to a stop, then spins up for the length of its warp-up sound."),
        Entry(key: "frequentAutosave", keyPath: \.frequentAutosave,
              title: "Frequent autosave",
              replaces: "Save on every jump, every few minutes and when the app goes to the background. The original saves only when you leave a spaceport, so dying or quitting in flight rolls you back."),
        Entry(key: "autoRoutePlotting", keyPath: \.autoRoutePlotting,
              title: "Automatic route plotting",
              replaces: "Tap any system on the map to plot the shortest course there. In the original you click a neighbouring system, and Shift-click to add each further jump yourself."),
        Entry(key: "nearestFirstTargeting", keyPath: \.nearestFirstTargeting,
              title: "Nearest-first targeting",
              replaces: "Target cycling starts with the closest ship and wraps around. In the original it goes in arrival order, ends at No Target, and reaches every ship in the system."),
        Entry(key: "modernKeyBindings", keyPath: \.modernKeyBindings,
              title: "Modern key layout",
              replaces: "Return fires secondaries, Shift is the afterburner and P pauses, applied when you reset the keys. The original layout uses Control, Z and P for Player Info."),
        Entry(key: "screenShake", keyPath: \.screenShake,
              title: "Screen shake",
              replaces: "The view shakes when something blows up nearby. The original never moves the camera."),
    ]

    public var enabledCount: Int { Self.catalog.filter { self[keyPath: $0.keyPath] }.count }

    // MARK: Coding (catalog-driven; missing keys → off)

    private struct Key: CodingKey {
        var stringValue: String
        init(_ s: String) { stringValue = s }
        init?(stringValue s: String) { stringValue = s }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        for entry in Self.catalog {
            self[keyPath: entry.keyPath] = (try? c.decodeIfPresent(Bool.self, forKey: Key(entry.key))) ?? nil ?? false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for entry in Self.catalog {
            try c.encode(self[keyPath: entry.keyPath], forKey: Key(entry.key))
        }
    }
}
