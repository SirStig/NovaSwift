import SwiftUI
import NovaSwiftKit

/// A government's real map/territory color, shared across every UI that
/// color-codes by government (the galaxy map's regions, the Story Map's
/// storyline lanes, …) so the same government reads as the same color
/// everywhere. Built once per loaded game — cheap to keep around, no need to
/// rebuild per frame or per view.
///
/// Governments carry a real `gövt.mapColor`, but ~16 of the 68 base-game
/// governments leave it black (unset); those — and anything player-facing as
/// "independent" — fall back to a deterministic hue assigned by sorted
/// government id, so distinct factions still read apart even without an
/// authored color.
struct GovernmentPalette {
    private let game: NovaGame
    private let fallbackByGovernment: [Int: Color]

    /// Deliberately distinct from the galaxy map's amber (current-system
    /// marker) and route colors.
    private static let palette: [Color] = [
        Color(red: 0.35, green: 0.62, blue: 1.0),   // blue
        Color(red: 1.0, green: 0.4, blue: 0.4),     // red
        Color(red: 0.72, green: 0.48, blue: 1.0),   // purple
        Color(red: 0.3, green: 0.82, blue: 0.85),   // cyan
        Color(red: 1.0, green: 0.52, blue: 0.76),   // pink
        Color(red: 0.93, green: 0.84, blue: 0.35),  // gold
        Color(red: 0.28, green: 0.72, blue: 0.62),  // teal
        Color(red: 0.62, green: 0.6, blue: 0.95),   // lavender
    ]

    /// Independent/unresolved (`-1`, or no matching `gövt`) always renders this.
    static let independent = Color(white: 0.62)

    init(game: NovaGame) {
        self.game = game
        var map: [Int: Color] = [:]
        for (i, id) in game.govts().map(\.id).sorted().enumerated() {
            map[id] = Self.palette[i % Self.palette.count]
        }
        self.fallbackByGovernment = map
    }

    /// A deterministic per-government hue, ignoring any authored map color —
    /// used both as `color(for:)`'s fallback and by anything (like the Story
    /// Map's sidebar swatches) that just wants "a" distinct color per
    /// government rather than the authentic territory one.
    func fallbackColor(for government: Int) -> Color {
        guard government >= 0, let color = fallbackByGovernment[government] else { return Self.independent }
        return color
    }

    /// A government's authentic **territory** color — its real `gövt.mapColor`
    /// (Federation blue, Auroran red, the Pirate families' greys, …). Falls
    /// back to `fallbackColor` only when the data leaves it black (16 of the
    /// 68 base governments do).
    func color(for government: Int) -> Color {
        guard government >= 0 else { return Self.independent }
        if let mc = game.govt(government)?.mapColor, mc.r != 0 || mc.g != 0 || mc.b != 0 {
            return Color(red: Double(mc.r) / 255, green: Double(mc.g) / 255, blue: Double(mc.b) / 255)
        }
        return fallbackColor(for: government)
    }
}
